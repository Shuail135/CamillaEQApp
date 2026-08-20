#include "SystemAudioBridgeClient.h"
#include "../../Drivers/SystemAudioBridge/Shared/SystemAudioBridgeTransport.h"

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

struct SABRClientTransport {
    int descriptor;
    void* mapping;
    size_t mappingBytes;
    SABRTransportHeader* header;
    Float32* samples;
    SABRTransportConfiguration configuration;
    Boolean isLinked;
};

static CFNumberRef sabr_number_create(uint64_t value) {
    int64_t signedValue = (int64_t)value;
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &signedValue);
}

static CFPropertyListRef sabr_client_transport_copy_property_list(
    const SABRTransportConfiguration* configuration
) {
    if (configuration == NULL) { return NULL; }
    CFMutableDictionaryRef dictionary = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    if (dictionary == NULL) { return NULL; }

#define SABR_SET_NUMBER(key, field) \
    do { \
        CFNumberRef number = sabr_number_create(configuration->field); \
        if (number == NULL) { CFRelease(dictionary); return NULL; } \
        CFDictionarySetValue(dictionary, CFSTR(key), number); \
        CFRelease(number); \
    } while (0)

    SABR_SET_NUMBER(SABR_TRANSPORT_KEY_PROTOCOL_VERSION, protocolVersion);
    SABR_SET_NUMBER(SABR_TRANSPORT_KEY_DIRECTION, direction);
    SABR_SET_NUMBER(SABR_TRANSPORT_KEY_STREAM_ID, streamID);
    SABR_SET_NUMBER(SABR_TRANSPORT_KEY_BUS_INDEX, busIndex);
    SABR_SET_NUMBER(SABR_TRANSPORT_KEY_CHANNEL_CAPACITY, channelCapacity);
    SABR_SET_NUMBER(SABR_TRANSPORT_KEY_FRAME_CAPACITY, frameCapacity);
    SABR_SET_NUMBER(SABR_TRANSPORT_KEY_FLAGS, flags);
    SABR_SET_NUMBER(SABR_TRANSPORT_KEY_REGION_BYTES, regionBytes);
#undef SABR_SET_NUMBER

    CFStringRef path = CFStringCreateWithCString(
        kCFAllocatorDefault,
        configuration->backingFilePath,
        kCFStringEncodingUTF8
    );
    if (path == NULL) { CFRelease(dictionary); return NULL; }
    CFDictionarySetValue(
        dictionary,
        CFSTR(SABR_TRANSPORT_KEY_BACKING_FILE_PATH),
        path
    );
    CFRelease(path);
    return dictionary;
}

SABRClientTransportRef sabr_client_transport_create(
    uint32_t channelCapacity,
    uint32_t frameCapacity
) {
    const size_t mappingBytes = sabr_transport_region_bytes(channelCapacity, frameCapacity);
    if (mappingBytes == 0) { return NULL; }

    SABRClientTransportRef transport = calloc(1, sizeof(*transport));
    if (transport == NULL) { return NULL; }
    transport->descriptor = -1;

    char pathTemplate[] = "/private/tmp/sabr.XXXXXX";
    const int descriptor = mkstemp(pathTemplate);
    if (descriptor < 0) {
        free(transport);
        return NULL;
    }
    if (strlen(pathTemplate) >= sizeof(transport->configuration.backingFilePath)) {
        close(descriptor);
        unlink(pathTemplate);
        free(transport);
        return NULL;
    }
    strcpy(transport->configuration.backingFilePath, pathTemplate);
    transport->descriptor = descriptor;
    transport->isLinked = true;
    if (fchmod(descriptor, 0666) != 0 || ftruncate(descriptor, (off_t)mappingBytes) != 0) {
        sabr_client_transport_destroy(transport);
        return NULL;
    }

    void* mapping = mmap(NULL, mappingBytes, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0);
    if (mapping == MAP_FAILED) {
        transport->mapping = NULL;
        sabr_client_transport_destroy(transport);
        return NULL;
    }
    transport->mapping = mapping;
    transport->mappingBytes = mappingBytes;
    transport->header = (SABRTransportHeader*)mapping;
    transport->samples = (Float32*)((uint8_t*)mapping + sizeof(SABRTransportHeader));

    memset(mapping, 0, mappingBytes);
    transport->header->magic = SABR_TRANSPORT_MAGIC;
    transport->header->protocolVersion = SABR_TRANSPORT_PROTOCOL_VERSION;
    transport->header->headerBytes = sizeof(SABRTransportHeader);
    transport->header->direction = SABR_TRANSPORT_DIRECTION_OUTPUT;
    transport->header->streamID = 0;
    transport->header->busIndex = 0;
    transport->header->channelCapacity = channelCapacity;
    transport->header->frameCapacity = frameCapacity;

    transport->configuration.protocolVersion = SABR_TRANSPORT_PROTOCOL_VERSION;
    transport->configuration.direction = SABR_TRANSPORT_DIRECTION_OUTPUT;
    transport->configuration.streamID = 0;
    transport->configuration.busIndex = 0;
    transport->configuration.channelCapacity = channelCapacity;
    transport->configuration.frameCapacity = frameCapacity;
    transport->configuration.regionBytes = mappingBytes;
    return transport;
}

OSStatus sabr_client_transport_connect(
    SABRClientTransportRef transport,
    AudioObjectID deviceObjectID
) {
    if (transport == NULL || transport->mapping == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    CFPropertyListRef propertyList = sabr_client_transport_copy_property_list(
        &transport->configuration
    );
    if (propertyList == NULL) { return kAudioHardwareUnspecifiedError; }
    AudioObjectPropertyAddress address = {
        .mSelector = SABR_TRANSPORT_PROPERTY,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    if (!AudioObjectHasProperty(deviceObjectID, &address)) {
        CFRelease(propertyList);
        return kAudioHardwareUnknownPropertyError;
    }
    const OSStatus result = AudioObjectSetPropertyData(
        deviceObjectID,
        &address,
        0,
        NULL,
        sizeof(propertyList),
        &propertyList
    );
    CFRelease(propertyList);
    if (result == noErr && transport->isLinked) {
        unlink(transport->configuration.backingFilePath);
        transport->isLinked = false;
    }
    return result;
}

OSStatus sabr_client_set_presentation(
    AudioObjectID deviceObjectID,
    const char* displayName,
    Boolean visible
) {
    if (displayName == NULL || displayName[0] == '\0') {
        return kAudioHardwareIllegalOperationError;
    }
    CFStringRef name = CFStringCreateWithCString(
        kCFAllocatorDefault,
        displayName,
        kCFStringEncodingUTF8
    );
    if (name == NULL) { return kAudioHardwareIllegalOperationError; }
    CFMutableDictionaryRef command = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    if (command == NULL) {
        CFRelease(name);
        return kAudioHardwareUnspecifiedError;
    }
    CFDictionarySetValue(
        command,
        CFSTR(SABR_TRANSPORT_KEY_COMMAND),
        CFSTR(SABR_TRANSPORT_COMMAND_PRESENTATION)
    );
    CFDictionarySetValue(command, CFSTR(SABR_TRANSPORT_KEY_DISPLAY_NAME), name);
    CFDictionarySetValue(
        command,
        CFSTR(SABR_TRANSPORT_KEY_VISIBLE),
        visible ? kCFBooleanTrue : kCFBooleanFalse
    );
    CFPropertyListRef propertyList = command;
    AudioObjectPropertyAddress address = {
        .mSelector = SABR_TRANSPORT_PROPERTY,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    const OSStatus result = AudioObjectSetPropertyData(
        deviceObjectID,
        &address,
        0,
        NULL,
        sizeof(propertyList),
        &propertyList
    );
    CFRelease(command);
    CFRelease(name);
    return result;
}

OSStatus sabr_client_set_profile_devices(
    AudioObjectID deviceObjectID,
    CFArrayRef profiles
) {
    if (profiles == NULL || CFGetTypeID(profiles) != CFArrayGetTypeID()) {
        return kAudioHardwareIllegalOperationError;
    }
    CFMutableDictionaryRef command = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    if (command == NULL) { return kAudioHardwareUnspecifiedError; }
    CFDictionarySetValue(
        command,
        CFSTR(SABR_TRANSPORT_KEY_COMMAND),
        CFSTR(SABR_TRANSPORT_COMMAND_PROFILE_DEVICES)
    );
    CFDictionarySetValue(command, CFSTR(SABR_TRANSPORT_KEY_PROFILES), profiles);
    CFPropertyListRef propertyList = command;
    AudioObjectPropertyAddress address = {
        .mSelector = SABR_TRANSPORT_PROPERTY,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    const OSStatus result = AudioObjectSetPropertyData(
        deviceObjectID,
        &address,
        0,
        NULL,
        sizeof(propertyList),
        &propertyList
    );
    CFRelease(command);
    return result;
}

void sabr_client_transport_disconnect(
    SABRClientTransportRef transport,
    AudioObjectID deviceObjectID
) {
    (void)transport;
    /*
     * CFNull is not a valid binary property-list value. Core Audio's proxy
     * attempts to serialize custom CFPropertyList properties as CFData and
     * crashes in CFDataGetBytePtr when handed kCFNull. Use an explicit,
     * serializable command dictionary instead.
     */
    CFMutableDictionaryRef command = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    if (command == NULL) { return; }
    CFDictionarySetValue(
        command,
        CFSTR(SABR_TRANSPORT_KEY_COMMAND),
        CFSTR(SABR_TRANSPORT_COMMAND_DISCONNECT)
    );
    CFPropertyListRef propertyList = command;
    AudioObjectPropertyAddress address = {
        .mSelector = SABR_TRANSPORT_PROPERTY,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    AudioObjectSetPropertyData(
        deviceObjectID,
        &address,
        0,
        NULL,
        sizeof(propertyList),
        &propertyList
    );
    CFRelease(command);
}

uint32_t sabr_client_transport_read(
    SABRClientTransportRef transport,
    Float32* interleavedDestination,
    uint32_t destinationChannelCapacity,
    uint32_t maximumFrames,
    uint32_t* activeChannels,
    double* sampleRate
) {
    if (transport == NULL || interleavedDestination == NULL || maximumFrames == 0) { return 0; }
    SABRTransportHeader* header = transport->header;
    uint32_t channels = atomic_load_explicit(&header->activeChannels, memory_order_relaxed);
    if (channels == 0 || channels > header->channelCapacity || channels > destinationChannelCapacity) {
        return 0;
    }

    const uint64_t readFrame = atomic_load_explicit(&header->readFrame, memory_order_relaxed);
    const uint64_t writeFrame = atomic_load_explicit(&header->writeFrame, memory_order_acquire);
    if (writeFrame <= readFrame) { return 0; }
    uint64_t available = writeFrame - readFrame;
    if (available > header->frameCapacity) {
        atomic_store_explicit(&header->readFrame, writeFrame, memory_order_release);
        atomic_fetch_add_explicit(&header->underrunCount, 1, memory_order_relaxed);
        return 0;
    }

    const uint32_t frameCount = (uint32_t)(available < maximumFrames ? available : maximumFrames);
    for (uint32_t frame = 0; frame < frameCount; ++frame) {
        const uint32_t sourceFrame = (uint32_t)((readFrame + frame) % header->frameCapacity);
        memcpy(
            interleavedDestination + ((size_t)frame * channels),
            transport->samples + ((size_t)sourceFrame * header->channelCapacity),
            (size_t)channels * sizeof(Float32)
        );
    }
    atomic_store_explicit(&header->readFrame, readFrame + frameCount, memory_order_release);
    if (activeChannels != NULL) { *activeChannels = channels; }
    if (sampleRate != NULL) {
        *sampleRate = sabr_bits_to_double(
            atomic_load_explicit(&header->sampleRateBits, memory_order_relaxed)
        );
    }
    return frameCount;
}

void sabr_client_transport_get_statistics(
    SABRClientTransportRef transport,
    SABRClientTransportStatistics* statistics
) {
    if (statistics == NULL) { return; }
    memset(statistics, 0, sizeof(*statistics));
    if (transport == NULL) { return; }
    SABRTransportHeader* header = transport->header;
    statistics->writeFrame = atomic_load_explicit(&header->writeFrame, memory_order_acquire);
    statistics->readFrame = atomic_load_explicit(&header->readFrame, memory_order_acquire);
    statistics->droppedFrames = atomic_load_explicit(&header->droppedFrames, memory_order_relaxed);
    statistics->underrunCount = atomic_load_explicit(&header->underrunCount, memory_order_relaxed);
    statistics->sequence = atomic_load_explicit(&header->sequence, memory_order_relaxed);
    statistics->activeChannels = atomic_load_explicit(&header->activeChannels, memory_order_relaxed);
    statistics->frameCapacity = header->frameCapacity;
    statistics->sampleRate = sabr_bits_to_double(
        atomic_load_explicit(&header->sampleRateBits, memory_order_relaxed)
    );
}

void sabr_client_transport_destroy(SABRClientTransportRef transport) {
    if (transport == NULL) { return; }
    if (transport->mapping != NULL && transport->mappingBytes > 0) {
        munmap(transport->mapping, transport->mappingBytes);
    }
    if (transport->descriptor >= 0) { close(transport->descriptor); }
    if (transport->isLinked) { unlink(transport->configuration.backingFilePath); }
    free(transport);
}

uint32_t sabr_client_transport_max_channels(void) {
    return SABR_TRANSPORT_MAX_CHANNELS;
}

uint32_t sabr_client_transport_default_frame_capacity(void) {
    return SABR_TRANSPORT_DEFAULT_FRAME_CAPACITY;
}

Boolean sabr_client_transport_is_supported(AudioObjectID deviceObjectID) {
    AudioObjectPropertyAddress address = {
        .mSelector = SABR_TRANSPORT_PROPERTY,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    if (!AudioObjectHasProperty(deviceObjectID, &address)) { return false; }
    Boolean settable = false;
    return AudioObjectIsPropertySettable(deviceObjectID, &address, &settable) == noErr &&
        settable;
}
