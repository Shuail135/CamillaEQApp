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
#define SABR_TRANSPORT_PROTOCOL_VERSION UINT32_C(3)
#define SABR_TRANSPORT_PROPERTY ((AudioObjectPropertySelector)UINT32_C(0x73616272)) /* 'sabr' */
#define SABR_TRANSPORT_SHM_NAME_CAPACITY 128
#define SABR_TRANSPORT_MAX_CHANNELS 32
#define SABR_TRANSPORT_DEFAULT_FRAME_CAPACITY 65536
#define SABR_TRANSPORT_PACKET_CAPACITY 1024
#define SABR_TRANSPORT_CLIENT_CAPACITY 64
#define SABR_TRANSPORT_BUNDLE_ID_CAPACITY 256

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
#define SABR_TRANSPORT_KEY_PROFILES "profiles"
#define SABR_TRANSPORT_KEY_DEVICE_UID "deviceUID"
#define SABR_TRANSPORT_COMMAND_DISCONNECT "disconnect"
#define SABR_TRANSPORT_COMMAND_PRESENTATION "presentation"
#define SABR_TRANSPORT_COMMAND_PROFILE_DEVICES "profileDevices"

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
 * Version 3 carries client-tagged blocks and a Core Audio channel-layout tag
 * per packet. The mapped layout is header, client registry, packet
 * descriptors, then interleaved Float32 sample storage. Frame and packet
 * positions are monotonic counters.
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
    _Atomic uint32_t activeChannelLayoutTag;
    uint32_t reserved32;

    _Atomic uint64_t writeFrame;
    _Atomic uint64_t readFrame;
    _Atomic uint64_t droppedFrames;
    _Atomic uint64_t underrunCount;
    _Atomic uint64_t sequence;
    _Atomic uint64_t sampleRateBits;

    _Atomic uint64_t writePacket;
    _Atomic uint64_t readPacket;
    _Atomic uint64_t droppedPackets;
    uint32_t packetCapacity;
    uint32_t clientCapacity;
    _Atomic uint64_t clientGeneration;

    uint8_t reserved[56];
} SABRTransportHeader;

typedef enum SABRClientState {
    SABR_CLIENT_STATE_EMPTY = 0,
    SABR_CLIENT_STATE_ACTIVE = 1,
    SABR_CLIENT_STATE_INACTIVE = 2
} SABRClientState;

typedef struct SABRTransportClient {
    _Atomic uint32_t state;
    uint32_t clientID;
    int32_t processID;
    uint32_t reserved32;
    uint64_t generation;
    char bundleID[SABR_TRANSPORT_BUNDLE_ID_CAPACITY];
} SABRTransportClient;

typedef struct SABRTransportPacket {
    uint64_t startFrame;
    uint64_t cycleCounter;
    uint64_t sampleTimeBits;
    uint32_t clientID;
    int32_t processID;
    uint32_t frameCount;
    uint32_t channelCount;
    uint32_t channelLayoutTag;
    uint32_t flags;
    uint8_t reserved[16];
} SABRTransportPacket;

typedef struct SABRTransportStatistics {
    uint64_t writeFrame;
    uint64_t readFrame;
    uint64_t droppedFrames;
    uint64_t underrunCount;
    uint64_t sequence;
    uint32_t activeChannels;
    uint32_t activeChannelLayoutTag;
    uint32_t frameCapacity;
    double sampleRate;
    uint64_t writePacket;
    uint64_t readPacket;
    uint64_t droppedPackets;
    uint64_t clientGeneration;
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
        ((size_t)SABR_TRANSPORT_CLIENT_CAPACITY * sizeof(SABRTransportClient)) +
        ((size_t)SABR_TRANSPORT_PACKET_CAPACITY * sizeof(SABRTransportPacket)) +
        ((size_t)frameCapacity * (size_t)channelCapacity * sizeof(Float32));
}

static inline SABRTransportClient* sabr_transport_clients(SABRTransportHeader* header) {
    return (SABRTransportClient*)((uint8_t*)header + sizeof(SABRTransportHeader));
}

static inline SABRTransportPacket* sabr_transport_packets(SABRTransportHeader* header) {
    return (SABRTransportPacket*)(
        (uint8_t*)sabr_transport_clients(header) +
        ((size_t)SABR_TRANSPORT_CLIENT_CAPACITY * sizeof(SABRTransportClient))
    );
}

static inline Float32* sabr_transport_samples(SABRTransportHeader* header) {
    return (Float32*)(
        (uint8_t*)sabr_transport_packets(header) +
        ((size_t)SABR_TRANSPORT_PACKET_CAPACITY * sizeof(SABRTransportPacket))
    );
}

_Static_assert(sizeof(SABRTransportHeader) == 192, "Transport header layout changed");
_Static_assert(sizeof(SABRTransportPacket) == 64, "Transport packet layout changed");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "64-bit transport atomics must be lock-free");

#ifdef __cplusplus
}
#endif

#endif
