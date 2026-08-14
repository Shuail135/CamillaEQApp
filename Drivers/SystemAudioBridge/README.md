# System Audio Bridge

System Audio Bridge is an output-only Core Audio HAL device for macOS 13 and
later. It is DSP-agnostic: any companion application that implements the
versioned transport can consume its PCM stream. The current product profile
exposes one stereo transport endpoint. It is hidden under the generic
`System Audio Bridge` name while idle and can be made visible under an active
profile name by a companion app. It exposes no input stream and does not use
macOS Microphone privacy APIs. A companion app can also publish per-profile
Core Audio aggregate outputs as inactive selection entries.

The driver is deliberately small. It receives the final interleaved Float32
mix from Core Audio and copies it into a bounded shared ring. A companion
userspace process reads that ring and may analyze, record, route, or process
the frames with any suitable audio engine.

```text
macOS apps -> bridge carrying the active profile name
                              |
                              v
                    private mapped ring
                              |
                              v
                    companion audio process
                              |
                              v
                    physical output or sink
```

Calls and screen sharing apps can continue to use the real microphone as
their input. Because the virtual device is not an input device, another caller
cannot select it as a microphone and feed remote voices back into the call.

## Build and test

The scripts use Apple's command-line tools and target macOS 13 by default.

```sh
Drivers/SystemAudioBridge/test-transport.sh
Drivers/SystemAudioBridge/build-driver.sh
Drivers/SystemAudioBridge/package-driver.sh
```

Generated artifacts are written under `build/driver/`. The driver is ad-hoc
signed and the package is unsigned unless a release pipeline replaces those
development defaults with Developer ID signing and notarization.

For a local system test, build the package and then run:

```sh
Drivers/SystemAudioBridge/install-driver.sh
```

That operation asks for an administrator password, installs only
`/Library/Audio/Plug-Ins/HAL/SystemAudioBridge.driver`, and reloads Core Audio.
The corresponding removal script is `uninstall-driver.sh`. Neither operation
is run as part of a normal build or test.

## Extension contract

The shipped app remains stereo today, but the transport protocol reserves the
pieces needed for larger layouts:

- interleaved Float32 transport capacity up to 32 channels;
- explicit active-channel count independent of allocated capacity;
- versioned direction, stream ID, and bus index fields;
- monotonic 64-bit ring positions and observable drop/underrun counters;
- a driver build setting, for example `SABR_CHANNELS=6`.

Shipping a multichannel profile requires changing all three ends together:
the HAL device's channel count and labels, the client channel mapping, and the
processing engine's capture and playback channel counts. Merely building
the driver with six channels is useful for driver development, but the current
app intentionally rejects it rather than silently downmixing a user's audio.

Future microphone support should be a separate, explicit input stream or
device using `SABR_TRANSPORT_DIRECTION_INPUT`. It will also need its own ring
ownership rules, UI consent, channel layout, clocking tests, and a clear
privacy explanation. Do not advertise an input stream in the output-only
product build: doing so would bring the virtual device back into call-app
microphone lists and could reintroduce feedback.

## Real-time rules

The driver callback does not allocate, lock, open files, log, or call into the
app. File mapping and connection changes occur through a non-real-time custom
Core Audio property. If the app falls behind, the bounded writer counts and
drops new frames instead of blocking Core Audio.

See `UPSTREAM.md` for BlackHole provenance and licensing.
