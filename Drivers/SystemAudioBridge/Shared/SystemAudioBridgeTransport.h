#ifndef SYSTEM_AUDIO_BRIDGE_TRANSPORT_H
#define SYSTEM_AUDIO_BRIDGE_TRANSPORT_H

#include <CoreAudio/CoreAudioTypes.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SABR_TRANSPORT_MAGIC UINT32_C(0x53414252) /* 'SABR' */
#define SABR_TRANSPORT_PROTOCOL_VERSION UINT32_C(1)
#define SABR_TRANSPORT_PROPERTY ((AudioObjectPropertySelector)UINT32_C(0x73616272)) /* 'sabr' */
#define SABR_TRANSPORT_SHM_NAME_CAPACITY 128
#define SABR_TRANSPORT_MAX_CHANNELS 32
#define SABR_TRANSPORT_DEFAULT_FRAME_CAPACITY 65536

#define SABR_TRANSPORT_KEY_PROTOCOL_VERSION "protocolVersion"
#define SABR_TRANSPORT_KEY_DIRECTION "direction"
#define SABR_TRANSPORT_KEY_STREAM_ID "streamID"
#define SABR_TRANSPORT_KEY_BUS_INDEX "busIndex"
#define SABR_TRANSPORT_KEY_CHANNEL_CAPACITY "channelCapacity"
#define SABR_TRANSPORT_KEY_FRAME_CAPACITY "frameCapacity"
#define SABR_TRANSPORT_KEY_FLAGS "flags"
#define SABR_TRANSPORT_KEY_REGION_BYTES "regionBytes"
#define SABR_TRANSPORT_KEY_BACKING_FILE_PATH "backingFilePath"
#define SABR_TRANSPORT_KEY_COMMAND "command"
#define SABR_TRANSPORT_KEY_DISPLAY_NAME "displayName"
#define SABR_TRANSPORT_KEY_VISIBLE "visible"
#define SABR_TRANSPORT_COMMAND_DISCONNECT "disconnect"
#define SABR_TRANSPORT_COMMAND_PRESENTATION "presentation"

typedef enum SABRTransportDirection {
    SABR_TRANSPORT_DIRECTION_OUTPUT = 1,
    SABR_TRANSPORT_DIRECTION_INPUT = 2
} SABRTransportDirection;

/*
 * Versioned value sent through SABR_TRANSPORT_PROPERTY. The currently shipped
 * driver accepts one output transport (stream 0, bus 0). Direction, stream and
 * bus are explicit so future input/microphone and multi-bus transports do not
 * require an incompatible control protocol.
 */
typedef struct SABRTransportConfiguration {
    uint32_t protocolVersion;
    uint32_t direction;
    uint32_t streamID;
    uint32_t busIndex;
    uint32_t channelCapacity;
    uint32_t frameCapacity;
    uint32_t flags;
    uint32_t reserved32;
    uint64_t regionBytes;
    char backingFilePath[SABR_TRANSPORT_SHM_NAME_CAPACITY];
} SABRTransportConfiguration;

/*
 * The header occupies exactly 128 bytes on supported macOS architectures.
 * PCM frames immediately follow it and are interleaved Float32. Indices are
 * monotonic frame counters; modulo frameCapacity selects the storage slot.
 */
typedef struct SABRTransportHeader {
    uint32_t magic;
    uint32_t protocolVersion;
    uint32_t headerBytes;
    uint32_t flags;

    uint32_t direction;
    uint32_t streamID;
    uint32_t busIndex;
    uint32_t channelCapacity;

    _Atomic uint32_t activeChannels;
    uint32_t frameCapacity;
    uint32_t reserved32[2];

    _Atomic uint64_t writeFrame;
    _Atomic uint64_t readFrame;
    _Atomic uint64_t droppedFrames;
    _Atomic uint64_t underrunCount;
    _Atomic uint64_t sequence;
    _Atomic uint64_t sampleRateBits;

    uint8_t reserved[32];
} SABRTransportHeader;

typedef struct SABRTransportStatistics {
    uint64_t writeFrame;
    uint64_t readFrame;
    uint64_t droppedFrames;
    uint64_t underrunCount;
    uint64_t sequence;
    uint32_t activeChannels;
    uint32_t frameCapacity;
    double sampleRate;
} SABRTransportStatistics;

static inline uint64_t sabr_double_to_bits(double value) {
    union { double value; uint64_t bits; } conversion = { .value = value };
    return conversion.bits;
}

static inline double sabr_bits_to_double(uint64_t bits) {
    union { double value; uint64_t bits; } conversion = { .bits = bits };
    return conversion.value;
}

static inline size_t sabr_transport_region_bytes(uint32_t channelCapacity, uint32_t frameCapacity) {
    if (channelCapacity == 0 || channelCapacity > SABR_TRANSPORT_MAX_CHANNELS || frameCapacity == 0) {
        return 0;
    }
    if ((size_t)frameCapacity > (SIZE_MAX - sizeof(SABRTransportHeader)) /
            ((size_t)channelCapacity * sizeof(Float32))) {
        return 0;
    }
    return sizeof(SABRTransportHeader) +
        ((size_t)frameCapacity * (size_t)channelCapacity * sizeof(Float32));
}

_Static_assert(sizeof(SABRTransportHeader) == 128, "Transport header layout changed");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "64-bit transport atomics must be lock-free");

#ifdef __cplusplus
}
#endif

#endif
