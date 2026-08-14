#include "SystemAudioBridgeDriverTransport.h"

#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct SABRDriverMappedTransport {
    void* mapping;
    size_t mappingBytes;
    SABRTransportHeader* header;
    Float32* samples;
    SABRTransportConfiguration configuration;
} SABRDriverMappedTransport;

static _Atomic(SABRDriverMappedTransport*) gTransport = NULL;
static _Atomic uint32_t gActiveWriters = 0;

static Boolean sabr_dictionary_get_uint64(
    CFDictionaryRef dictionary,
    CFStringRef key,
    uint64_t* value
) {
    CFTypeRef object = CFDictionaryGetValue(dictionary, key);
    if (object == NULL || CFGetTypeID(object) != CFNumberGetTypeID()) { return false; }
    int64_t signedValue = 0;
    if (!CFNumberGetValue((CFNumberRef)object, kCFNumberSInt64Type, &signedValue) ||
        signedValue < 0) {
        return false;
    }
    *value = (uint64_t)signedValue;
    return true;
}

static void sabr_release_transport(SABRDriverMappedTransport* transport) {
    if (transport == NULL) { return; }
    while (atomic_load_explicit(&gActiveWriters, memory_order_acquire) != 0) {
        sched_yield();
    }
    munmap(transport->mapping, transport->mappingBytes);
    free(transport);
}

static void sabr_replace_transport(SABRDriverMappedTransport* replacement) {
    SABRDriverMappedTransport* previous = atomic_exchange_explicit(
        &gTransport,
        replacement,
        memory_order_acq_rel
    );
    sabr_release_transport(previous);
}

OSStatus sabr_driver_transport_connect(const SABRTransportConfiguration* configuration) {
    if (configuration == NULL || configuration->backingFilePath[0] == '\0') {
        sabr_driver_transport_disconnect();
        return noErr;
    }
    if (configuration->protocolVersion != SABR_TRANSPORT_PROTOCOL_VERSION ||
        configuration->direction != SABR_TRANSPORT_DIRECTION_OUTPUT ||
        configuration->streamID != 0 ||
        configuration->busIndex != 0 ||
        configuration->channelCapacity == 0 ||
        configuration->channelCapacity > SABR_TRANSPORT_MAX_CHANNELS ||
        configuration->frameCapacity == 0) {
        return kAudioHardwareIllegalOperationError;
    }

    const size_t requiredBytes = sabr_transport_region_bytes(
        configuration->channelCapacity,
        configuration->frameCapacity
    );
    if (requiredBytes == 0 || configuration->regionBytes != requiredBytes) {
        return kAudioHardwareBadPropertySizeError;
    }

    char name[SABR_TRANSPORT_SHM_NAME_CAPACITY];
    memcpy(name, configuration->backingFilePath, sizeof(name));
    name[sizeof(name) - 1] = '\0';
    if (strncmp(name, "/private/tmp/sabr.", 18) != 0) {
        return kAudioHardwareIllegalOperationError;
    }

    const int descriptor = open(name, O_RDWR | O_NOFOLLOW, 0);
    if (descriptor < 0) { return kAudioHardwareUnspecifiedError; }

    struct stat status;
    if (fstat(descriptor, &status) != 0 || status.st_size < 0 ||
        (uint64_t)status.st_size < configuration->regionBytes) {
        close(descriptor);
        return kAudioHardwareBadPropertySizeError;
    }

    void* mapping = mmap(NULL, requiredBytes, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0);
    close(descriptor);
    if (mapping == MAP_FAILED) { return kAudioHardwareUnspecifiedError; }

    SABRTransportHeader* header = (SABRTransportHeader*)mapping;
    if (header->magic != SABR_TRANSPORT_MAGIC ||
        header->protocolVersion != SABR_TRANSPORT_PROTOCOL_VERSION ||
        header->headerBytes != sizeof(SABRTransportHeader) ||
        header->direction != configuration->direction ||
        header->streamID != configuration->streamID ||
        header->busIndex != configuration->busIndex ||
        header->channelCapacity != configuration->channelCapacity ||
        header->frameCapacity != configuration->frameCapacity) {
        munmap(mapping, requiredBytes);
        return kAudioHardwareIllegalOperationError;
    }

    SABRDriverMappedTransport* transport = calloc(1, sizeof(*transport));
    if (transport == NULL) {
        munmap(mapping, requiredBytes);
        return kAudioHardwareUnspecifiedError;
    }
    transport->mapping = mapping;
    transport->mappingBytes = requiredBytes;
    transport->header = header;
    transport->samples = (Float32*)((uint8_t*)mapping + sizeof(SABRTransportHeader));
    transport->configuration = *configuration;

    sabr_replace_transport(transport);
    return noErr;
}

OSStatus sabr_driver_transport_connect_property_list(CFPropertyListRef propertyList) {
    if (propertyList == NULL || propertyList == kCFNull ||
        CFGetTypeID(propertyList) == CFNullGetTypeID()) {
        sabr_driver_transport_disconnect();
        return noErr;
    }
    if (CFGetTypeID(propertyList) != CFDictionaryGetTypeID()) {
        return kAudioHardwareIllegalOperationError;
    }

    CFDictionaryRef dictionary = (CFDictionaryRef)propertyList;
    CFTypeRef command = CFDictionaryGetValue(
        dictionary,
        CFSTR(SABR_TRANSPORT_KEY_COMMAND)
    );
    if (command != NULL && CFGetTypeID(command) == CFStringGetTypeID() &&
        CFStringCompare(
            (CFStringRef)command,
            CFSTR(SABR_TRANSPORT_COMMAND_DISCONNECT),
            0
        ) == kCFCompareEqualTo) {
        sabr_driver_transport_disconnect();
        return noErr;
    }

    SABRTransportConfiguration configuration;
    memset(&configuration, 0, sizeof(configuration));
    uint64_t value = 0;

#define SABR_READ_U32(field, key) \
    do { \
        if (!sabr_dictionary_get_uint64(dictionary, CFSTR(key), &value) || value > UINT32_MAX) { \
            return kAudioHardwareIllegalOperationError; \
        } \
        configuration.field = (uint32_t)value; \
    } while (0)

    SABR_READ_U32(protocolVersion, SABR_TRANSPORT_KEY_PROTOCOL_VERSION);
    SABR_READ_U32(direction, SABR_TRANSPORT_KEY_DIRECTION);
    SABR_READ_U32(streamID, SABR_TRANSPORT_KEY_STREAM_ID);
    SABR_READ_U32(busIndex, SABR_TRANSPORT_KEY_BUS_INDEX);
    SABR_READ_U32(channelCapacity, SABR_TRANSPORT_KEY_CHANNEL_CAPACITY);
    SABR_READ_U32(frameCapacity, SABR_TRANSPORT_KEY_FRAME_CAPACITY);
    SABR_READ_U32(flags, SABR_TRANSPORT_KEY_FLAGS);
#undef SABR_READ_U32

    if (!sabr_dictionary_get_uint64(
            dictionary,
            CFSTR(SABR_TRANSPORT_KEY_REGION_BYTES),
            &configuration.regionBytes)) {
        return kAudioHardwareIllegalOperationError;
    }

    CFTypeRef path = CFDictionaryGetValue(
        dictionary,
        CFSTR(SABR_TRANSPORT_KEY_BACKING_FILE_PATH)
    );
    if (path == NULL || CFGetTypeID(path) != CFStringGetTypeID() ||
        !CFStringGetCString(
            (CFStringRef)path,
            configuration.backingFilePath,
            sizeof(configuration.backingFilePath),
            kCFStringEncodingUTF8)) {
        return kAudioHardwareIllegalOperationError;
    }

    return sabr_driver_transport_connect(&configuration);
}

void sabr_driver_transport_disconnect(void) {
    sabr_replace_transport(NULL);
}

void sabr_driver_transport_get_configuration(SABRTransportConfiguration* configuration) {
    if (configuration == NULL) { return; }
    memset(configuration, 0, sizeof(*configuration));
    atomic_fetch_add_explicit(&gActiveWriters, 1, memory_order_acquire);
    SABRDriverMappedTransport* transport = atomic_load_explicit(&gTransport, memory_order_acquire);
    if (transport != NULL) { *configuration = transport->configuration; }
    atomic_fetch_sub_explicit(&gActiveWriters, 1, memory_order_release);
}

void sabr_driver_transport_write(
    const Float32* interleavedSamples,
    uint32_t frameCount,
    uint32_t channelCount,
    double sampleRate
) {
    if (interleavedSamples == NULL || frameCount == 0 || channelCount == 0) { return; }

    atomic_fetch_add_explicit(&gActiveWriters, 1, memory_order_acquire);
    SABRDriverMappedTransport* transport = atomic_load_explicit(&gTransport, memory_order_acquire);
    if (transport == NULL) {
        atomic_fetch_sub_explicit(&gActiveWriters, 1, memory_order_release);
        return;
    }

    SABRTransportHeader* header = transport->header;
    const uint32_t capacity = header->frameCapacity;
    const uint32_t channelCapacity = header->channelCapacity;
    if (channelCount > channelCapacity || frameCount > capacity) {
        atomic_fetch_add_explicit(&header->droppedFrames, frameCount, memory_order_relaxed);
        atomic_fetch_sub_explicit(&gActiveWriters, 1, memory_order_release);
        return;
    }

    const uint64_t writeFrame = atomic_load_explicit(&header->writeFrame, memory_order_relaxed);
    const uint64_t readFrame = atomic_load_explicit(&header->readFrame, memory_order_acquire);
    const uint64_t usedFrames = writeFrame >= readFrame ? writeFrame - readFrame : capacity;
    if (usedFrames > capacity || frameCount > capacity - usedFrames) {
        atomic_fetch_add_explicit(&header->droppedFrames, frameCount, memory_order_relaxed);
        atomic_fetch_sub_explicit(&gActiveWriters, 1, memory_order_release);
        return;
    }

    const uint32_t startFrame = (uint32_t)(writeFrame % capacity);
    const uint32_t firstFrames = frameCount < capacity - startFrame ? frameCount : capacity - startFrame;
    const uint32_t secondFrames = frameCount - firstFrames;
    if (channelCount == channelCapacity) {
        memcpy(
            transport->samples + ((size_t)startFrame * channelCapacity),
            interleavedSamples,
            (size_t)firstFrames * channelCount * sizeof(Float32)
        );
    } else {
        for (uint32_t sourceFrame = 0; sourceFrame < firstFrames; ++sourceFrame) {
            Float32* destination = transport->samples +
                ((size_t)(startFrame + sourceFrame) * channelCapacity);
            const Float32* source = interleavedSamples + ((size_t)sourceFrame * channelCount);
            memcpy(destination, source, (size_t)channelCount * sizeof(Float32));
            memset(destination + channelCount, 0,
                (size_t)(channelCapacity - channelCount) * sizeof(Float32));
        }
    }
    if (secondFrames > 0) {
        if (channelCount == channelCapacity) {
            memcpy(
                transport->samples,
                interleavedSamples + ((size_t)firstFrames * channelCount),
                (size_t)secondFrames * channelCount * sizeof(Float32)
            );
        } else {
            for (uint32_t frame = 0; frame < secondFrames; ++frame) {
                Float32* destination = transport->samples + ((size_t)frame * channelCapacity);
                const Float32* source = interleavedSamples +
                    ((size_t)(firstFrames + frame) * channelCount);
                memcpy(destination, source, (size_t)channelCount * sizeof(Float32));
                memset(destination + channelCount, 0,
                    (size_t)(channelCapacity - channelCount) * sizeof(Float32));
            }
        }
    }

    atomic_store_explicit(&header->activeChannels, channelCount, memory_order_relaxed);
    atomic_store_explicit(&header->sampleRateBits, sabr_double_to_bits(sampleRate), memory_order_relaxed);
    atomic_fetch_add_explicit(&header->sequence, 1, memory_order_relaxed);
    atomic_store_explicit(&header->writeFrame, writeFrame + frameCount, memory_order_release);
    atomic_fetch_sub_explicit(&gActiveWriters, 1, memory_order_release);
}
