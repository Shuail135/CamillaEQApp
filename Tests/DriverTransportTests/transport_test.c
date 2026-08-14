#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

/* Include the client implementation so this white-box test can hand the
 * generated connection configuration to the driver-side transport. */
#include "../../Sources/SystemAudioBridgeC/SystemAudioBridgeClient.c"
#include "../../Drivers/SystemAudioBridge/Driver/SystemAudioBridgeDriverTransport.h"

static void assert_samples_equal(const Float32* actual, const Float32* expected, size_t count) {
    for (size_t index = 0; index < count; ++index) {
        assert(fabsf(actual[index] - expected[index]) < 0.000001f);
    }
}

static void test_stereo_round_trip(void) {
    SABRClientTransportRef client = sabr_client_transport_create(8, 64);
    if (client == NULL) { perror("sabr_client_transport_create"); }
    assert(client != NULL);
    CFPropertyListRef propertyList = sabr_client_transport_copy_property_list(
        &client->configuration
    );
    assert(propertyList != NULL);
    assert(sabr_driver_transport_connect_property_list(propertyList) == noErr);
    CFRelease(propertyList);

    const Float32 input[] = {
        0.1f, -0.1f,
        0.2f, -0.2f,
        0.3f, -0.3f,
        0.4f, -0.4f
    };
    sabr_driver_transport_write(input, 4, 2, 48000.0);

    Float32 output[8] = {0};
    uint32_t channels = 0;
    double sampleRate = 0;
    assert(sabr_client_transport_read(client, output, 8, 4, &channels, &sampleRate) == 4);
    assert(channels == 2);
    assert(sampleRate == 48000.0);
    assert_samples_equal(output, input, 8);

    sabr_driver_transport_disconnect();
    sabr_client_transport_destroy(client);
}

static void test_multichannel_round_trip(void) {
    SABRClientTransportRef client = sabr_client_transport_create(8, 64);
    assert(client != NULL);
    assert(sabr_driver_transport_connect(&client->configuration) == noErr);

    Float32 input[18];
    for (size_t index = 0; index < 18; ++index) { input[index] = (Float32)index / 20.0f; }
    sabr_driver_transport_write(input, 3, 6, 96000.0);

    Float32 output[18] = {0};
    uint32_t channels = 0;
    double sampleRate = 0;
    assert(sabr_client_transport_read(client, output, 8, 3, &channels, &sampleRate) == 3);
    assert(channels == 6);
    assert(sampleRate == 96000.0);
    assert_samples_equal(output, input, 18);

    sabr_driver_transport_disconnect();
    sabr_client_transport_destroy(client);
}

static void test_full_buffer_drops_new_frames(void) {
    SABRClientTransportRef client = sabr_client_transport_create(2, 8);
    assert(client != NULL);
    assert(sabr_driver_transport_connect(&client->configuration) == noErr);

    Float32 full[16] = {0};
    const Float32 extra[2] = {1, -1};
    sabr_driver_transport_write(full, 8, 2, 44100.0);
    sabr_driver_transport_write(extra, 1, 2, 44100.0);

    SABRClientTransportStatistics statistics;
    sabr_client_transport_get_statistics(client, &statistics);
    assert(statistics.droppedFrames == 1);
    assert(statistics.writeFrame == 8);

    sabr_driver_transport_disconnect();
    sabr_client_transport_destroy(client);
}

static void test_cross_process_round_trip(void) {
    SABRClientTransportRef client = sabr_client_transport_create(8, 64);
    assert(client != NULL);

    const pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        const Float32 input[] = {0.25f, -0.25f, 0.5f, -0.5f};
        if (sabr_driver_transport_connect(&client->configuration) != noErr) { _exit(2); }
        sabr_driver_transport_write(input, 2, 2, 48000.0);
        sabr_driver_transport_disconnect();
        _exit(0);
    }

    int childStatus = 0;
    assert(waitpid(child, &childStatus, 0) == child);
    assert(WIFEXITED(childStatus));
    assert(WEXITSTATUS(childStatus) == 0);

    const Float32 expected[] = {0.25f, -0.25f, 0.5f, -0.5f};
    Float32 output[4] = {0};
    uint32_t channels = 0;
    double sampleRate = 0;
    assert(sabr_client_transport_read(client, output, 8, 2, &channels, &sampleRate) == 2);
    assert(channels == 2);
    assert(sampleRate == 48000.0);
    assert_samples_equal(output, expected, 4);

    sabr_client_transport_destroy(client);
}

static void test_property_list_validation(void) {
    assert(sabr_driver_transport_connect_property_list(CFSTR("not a dictionary")) ==
        kAudioHardwareIllegalOperationError);
    assert(sabr_driver_transport_connect_property_list(kCFNull) == noErr);

    const void* keys[] = { CFSTR(SABR_TRANSPORT_KEY_COMMAND) };
    const void* values[] = { CFSTR(SABR_TRANSPORT_COMMAND_DISCONNECT) };
    CFDictionaryRef disconnect = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys,
        values,
        1,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    assert(disconnect != NULL);
    assert(sabr_driver_transport_connect_property_list(disconnect) == noErr);
    CFRelease(disconnect);
}

int main(void) {
    test_stereo_round_trip();
    test_multichannel_round_trip();
    test_full_buffer_drops_new_frames();
    test_cross_process_round_trip();
    test_property_list_validation();
    puts("System Audio Bridge transport tests passed");
    return 0;
}
