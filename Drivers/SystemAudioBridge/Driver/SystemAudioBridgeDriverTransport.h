#ifndef SYSTEM_AUDIO_BRIDGE_DRIVER_TRANSPORT_H
#define SYSTEM_AUDIO_BRIDGE_DRIVER_TRANSPORT_H

#include <CoreFoundation/CoreFoundation.h>
#include "../Shared/SystemAudioBridgeTransport.h"

#ifdef __cplusplus
extern "C" {
#endif

OSStatus sabr_driver_transport_connect(const SABRTransportConfiguration* configuration);
OSStatus sabr_driver_transport_connect_property_list(CFPropertyListRef propertyList);
void sabr_driver_transport_disconnect(void);
void sabr_driver_transport_write(
    const Float32* interleavedSamples,
    uint32_t frameCount,
    uint32_t channelCount,
    double sampleRate
);
void sabr_driver_transport_get_configuration(SABRTransportConfiguration* configuration);

#ifdef __cplusplus
}
#endif

#endif
