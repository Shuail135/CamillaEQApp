#ifndef SYSTEM_AUDIO_BRIDGE_CLIENT_H
#define SYSTEM_AUDIO_BRIDGE_CLIENT_H

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SABRClientTransport* SABRClientTransportRef;

#define SABR_CLIENT_BUNDLE_ID_CAPACITY 256

typedef struct SABRClientAudioPacketInfo {
    uint32_t clientID;
    int32_t processID;
    uint64_t cycleCounter;
    double sampleTime;
    uint32_t frameCount;
    uint32_t channelCount;
    uint32_t channelLayoutTag;
    double sampleRate;
} SABRClientAudioPacketInfo;

typedef struct SABRClientIdentity {
    uint32_t clientID;
    int32_t processID;
    Boolean isActive;
    uint64_t generation;
    char bundleID[SABR_CLIENT_BUNDLE_ID_CAPACITY];
} SABRClientIdentity;

typedef struct SABRClientTransportStatistics {
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
} SABRClientTransportStatistics;

SABRClientTransportRef sabr_client_transport_create(
    uint32_t channelCapacity,
    uint32_t frameCapacity
);

OSStatus sabr_client_transport_connect(
    SABRClientTransportRef transport,
    AudioObjectID deviceObjectID
);

OSStatus sabr_client_set_presentation(
    AudioObjectID deviceObjectID,
    const char* displayName,
    Boolean visible
);

OSStatus sabr_client_set_profile_devices(
    AudioObjectID deviceObjectID,
    CFArrayRef profiles
);

void sabr_client_transport_disconnect(
    SABRClientTransportRef transport,
    AudioObjectID deviceObjectID
);

uint32_t sabr_client_transport_read(
    SABRClientTransportRef transport,
    Float32* interleavedDestination,
    uint32_t destinationChannelCapacity,
    uint32_t maximumFrames,
    uint32_t* activeChannels,
    double* sampleRate
);

uint32_t sabr_client_transport_read_packet(
    SABRClientTransportRef transport,
    Float32* interleavedDestination,
    uint32_t destinationChannelCapacity,
    uint32_t maximumFrames,
    SABRClientAudioPacketInfo* packetInfo
);

uint32_t sabr_client_transport_copy_clients(
    SABRClientTransportRef transport,
    SABRClientIdentity* destination,
    uint32_t destinationCapacity
);

void sabr_client_transport_get_statistics(
    SABRClientTransportRef transport,
    SABRClientTransportStatistics* statistics
);

void sabr_client_transport_destroy(SABRClientTransportRef transport);

uint32_t sabr_client_transport_max_channels(void);
uint32_t sabr_client_transport_default_frame_capacity(void);
uint32_t sabr_client_transport_max_clients(void);
Boolean sabr_client_transport_is_supported(AudioObjectID deviceObjectID);

#ifdef __cplusplus
}
#endif

#endif
