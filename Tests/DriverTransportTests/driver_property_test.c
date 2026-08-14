#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <assert.h>
#include <stdio.h>
#include <unistd.h>

#include "../../Drivers/SystemAudioBridge/Shared/SystemAudioBridgeTransport.h"

extern void* SystemAudioBridge_Create(
    CFAllocatorRef allocator,
    CFUUIDRef requestedTypeUUID
);

int main(void) {
    AudioServerPlugInDriverRef driver = (AudioServerPlugInDriverRef)
        SystemAudioBridge_Create(NULL, kAudioServerPlugInTypeUUID);
    assert(driver != NULL);

    AudioObjectPropertyAddress infoAddress = {
        .mSelector = kAudioObjectPropertyCustomPropertyInfoList,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    assert((*driver)->HasProperty(driver, 3, getpid(), &infoAddress));

    UInt32 size = 0;
    assert((*driver)->GetPropertyDataSize(
        driver, 3, getpid(), &infoAddress, 0, NULL, &size
    ) == noErr);
    assert(size == sizeof(AudioServerPlugInCustomPropertyInfo));

    AudioServerPlugInCustomPropertyInfo info = {0};
    UInt32 returnedSize = 0;
    assert((*driver)->GetPropertyData(
        driver,
        3,
        getpid(),
        &infoAddress,
        0,
        NULL,
        sizeof(info),
        &returnedSize,
        &info
    ) == noErr);
    assert(returnedSize == sizeof(info));
    assert(info.mSelector == SABR_TRANSPORT_PROPERTY);
    assert(info.mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList);
    assert(info.mQualifierDataType == kAudioServerPlugInCustomPropertyDataTypeNone);

    AudioObjectPropertyAddress transportAddress = {
        .mSelector = SABR_TRANSPORT_PROPERTY,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    assert((*driver)->HasProperty(driver, 3, getpid(), &transportAddress));
    Boolean settable = false;
    assert((*driver)->IsPropertySettable(
        driver, 3, getpid(), &transportAddress, &settable
    ) == noErr);
    assert(settable);

    AudioObjectPropertyAddress hiddenAddress = {
        .mSelector = kAudioDevicePropertyIsHidden,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    UInt32 hidden = 0;
    returnedSize = 0;
    assert((*driver)->GetPropertyData(
        driver,
        3,
        getpid(),
        &hiddenAddress,
        0,
        NULL,
        sizeof(hidden),
        &returnedSize,
        &hidden
    ) == noErr);
    assert(returnedSize == sizeof(hidden));
    assert(hidden == 1);

    const void* presentationKeys[] = {
        CFSTR(SABR_TRANSPORT_KEY_COMMAND),
        CFSTR(SABR_TRANSPORT_KEY_DISPLAY_NAME),
        CFSTR(SABR_TRANSPORT_KEY_VISIBLE)
    };
    const void* presentationValues[] = {
        CFSTR(SABR_TRANSPORT_COMMAND_PRESENTATION),
        CFSTR("Headphones-EQ"),
        kCFBooleanTrue
    };
    CFPropertyListRef presentation = CFDictionaryCreate(
        kCFAllocatorDefault,
        presentationKeys,
        presentationValues,
        3,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    assert(presentation != NULL);
    assert((*driver)->SetPropertyData(
        driver,
        3,
        getpid(),
        &transportAddress,
        0,
        NULL,
        sizeof(presentation),
        &presentation
    ) == noErr);
    CFRelease(presentation);

    AudioObjectPropertyAddress nameAddress = {
        .mSelector = kAudioObjectPropertyName,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    CFStringRef name = NULL;
    returnedSize = 0;
    assert((*driver)->GetPropertyData(
        driver,
        3,
        getpid(),
        &nameAddress,
        0,
        NULL,
        sizeof(name),
        &returnedSize,
        &name
    ) == noErr);
    assert(name != NULL);
    assert(CFStringCompare(name, CFSTR("Headphones-EQ"), 0) == kCFCompareEqualTo);
    CFRelease(name);

    hidden = 1;
    returnedSize = 0;
    assert((*driver)->GetPropertyData(
        driver,
        3,
        getpid(),
        &hiddenAddress,
        0,
        NULL,
        sizeof(hidden),
        &returnedSize,
        &hidden
    ) == noErr);
    assert(hidden == 0);

    const void* keys[] = { CFSTR(SABR_TRANSPORT_KEY_COMMAND) };
    const void* values[] = { CFSTR(SABR_TRANSPORT_COMMAND_DISCONNECT) };
    CFPropertyListRef disconnect = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys,
        values,
        1,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    assert(disconnect != NULL);
    assert((*driver)->SetPropertyData(
        driver,
        3,
        getpid(),
        &transportAddress,
        0,
        NULL,
        sizeof(disconnect),
        &disconnect
    ) == noErr);
    CFRelease(disconnect);

    puts("System Audio Bridge Core Audio property tests passed");
    return 0;
}
