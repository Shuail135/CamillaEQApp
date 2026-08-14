# Changes from BlackHole to System Audio Bridge

This document describes how the BlackHole-derived Core Audio driver in this
repository was changed into **System Audio Bridge**. It is both an engineering
record and a guide for maintainers who may later move the driver into its own
repository.

This is a description of the current fork, not a substitute for source-control
history. The authoritative upstream baseline is BlackHole revision
`ffcb74433fbcf8c8ca5c736677c1a4864384dc09`.

## 1. Provenance and license

The main HAL implementation,
[`Driver/SystemAudioBridge.c`](Driver/SystemAudioBridge.c), is derived from
[BlackHole](https://github.com/ExistentialAudio/BlackHole) by Existential Audio
Inc. The upstream code and this modified version are licensed under GPL-3.0.

The new transport, client, tests, build scripts, and integration code are also
distributed under this repository's GPL-3.0-only license. The upstream
copyright notice and provenance must remain with redistributed source and
binaries. See [`UPSTREAM.md`](UPSTREAM.md), the repository `LICENSE`, and
`THIRD_PARTY.md`.

## 2. High-level change

BlackHole provided the HAL foundation used to publish a virtual Core Audio
device. This fork turns that foundation into a product-specific, output-only
bridge with a private app transport:

```text
macOS applications
        |
        v
System Audio Bridge HAL output device
        |
        | interleaved Float32 PCM
        v
versioned shared-memory ring
        |
        v
CamiTune (or another compatible companion process)
        |
        v
DSP / analysis / recording / physical audio sink
```

The driver does **not** apply EQ. It publishes the final Core Audio output mix
to a companion userspace process. CamiTune currently passes those frames to
CamillaDSP and then to a selected physical output.

## 3. Summary of modifications

| Area | System Audio Bridge behavior |
| --- | --- |
| Product identity | Uses a new name, bundle ID, device UID, model UID, factory UUID, executable, and package ID. |
| Device topology | Provides one output transport, hidden while idle and profile-named while active, with no input device or input stream. |
| App transport | Adds a versioned custom Core Audio property and a memory-mapped PCM ring. |
| Real-time delivery | Copies the HAL `WriteMix` buffer into a non-blocking bounded ring. |
| Channel design | Ships as stereo but can be built from 2 through 32 channels. |
| Future protocol space | Reserves direction, stream, bus, flags, and channel-capacity fields. |
| Privacy behavior | Does not appear as a microphone and does not use microphone privacy APIs. |
| Build target | Defaults to macOS 13.0 or newer. |
| Packaging | Builds a standalone `.driver`, optional `.pkg`, and an app-bundled driver. |
| Installation | Installs into the system HAL directory with administrator approval and reloads Core Audio. |
| Validation | Adds transport, cross-process, property-discovery, stereo, and multichannel tests. |

## 4. Driver identity changes

The fork has its own Core Audio identity so it can be distributed independently
and does not collide with an installed BlackHole device.

| Identifier | Current value |
| --- | --- |
| Display name | `System Audio Bridge` |
| Driver bundle | `CamillaAudio.driver` |
| Executable | `CamillaAudio` |
| Bundle identifier | `local.camillaaudio.driver` |
| Device UID | `local.systemaudiobridge.device` |
| Model UID | `local.systemaudiobridge.model` |
| Factory UUID | `609B2F3F-8802-4D37-A42E-89499DDA191C` |
| Package identifier | `local.camillaaudio.driver.pkg` |
| Factory symbol | `SystemAudioBridge_Create` |
| Current driver version | `0.1.0` |

The installed bundle uses the reusable `CamillaAudio` filename while
the device and transport remain `System Audio Bridge`. The transport can still
be consumed by other DSP or audio applications.

Renaming only the display string is not sufficient. Any future fork or
side-by-side copy must use a unique bundle ID, device UID, model UID, factory
UUID, package ID, and transport identity to avoid Core Audio cache and device
collisions.

## 5. Output-only topology

The shipping build sets:

```text
kDevice_HasInput=false
kDevice_HasOutput=true
kDevice2_HasInput=false
kDevice2_HasOutput=false
```

Consequently, the driver publishes one output transport stream and no input
stream. While idle it is hidden under the generic name. Public Core Audio
aggregate devices provide inactive profile selectors; while active, the real
device adopts the selected profile name and the selector is removed. Some inherited
input-related implementation remains behind compile-time conditions in the HAL
source, but it is not included in the product topology.

This decision is important for calls and screen sharing:

- System Audio Bridge cannot be selected as a call microphone.
- Remote call audio cannot return through a virtual microphone provided by this
  driver because no such microphone exists.
- CamiTune does not request macOS Microphone permission for this path.
- A real microphone remains independent and can still be selected by call apps.

Output-only topology prevents one common feedback route. It cannot prevent
acoustic echo from speakers into a physical microphone, nor can it control how
a third-party application implements system-audio sharing.

## 6. New app-driver transport

The major functional addition is a direct transport from the HAL driver to a
companion application. The transport is implemented by:

- [`Shared/SystemAudioBridgeTransport.h`](Shared/SystemAudioBridgeTransport.h):
  shared protocol and memory layout.
- [`Driver/SystemAudioBridgeDriverTransport.c`](Driver/SystemAudioBridgeDriverTransport.c):
  driver-side connection validation and ring writer.
- `Sources/SystemAudioBridgeC/SystemAudioBridgeClient.c`: app-side mapping,
  Core Audio property calls, ring reader, and statistics.
- `Sources/CamiTune/SystemAudioBridgeTransport.swift`: Swift lifecycle,
  worker thread, CamillaDSP feed, spectrum feed, and UI statistics.

### 6.1 Custom Core Audio property

The driver advertises selector `sabr` (`0x73616272`) through
`kAudioObjectPropertyCustomPropertyInfoList`. Its data type is declared as
`kAudioServerPlugInCustomPropertyDataTypeCFPropertyList`, allowing Core Audio to
marshal the configuration across the HAL process boundary.

The connection value is a dictionary containing:

| Key | Purpose |
| --- | --- |
| `protocolVersion` | Rejects incompatible layouts or semantics. |
| `direction` | Currently output; reserves an explicit future input direction. |
| `streamID` | Currently `0`; reserved for multiple streams. |
| `busIndex` | Currently `0`; reserved for multiple buses. |
| `channelCapacity` | Maximum channels allocated in the mapping. |
| `frameCapacity` | Number of PCM frames in the bounded ring. |
| `flags` | Reserved capability/behavior bits. |
| `regionBytes` | Exact expected mapping size. |
| `backingFilePath` | Temporary file used to establish the shared mapping. |

Presentation uses a serializable dictionary containing the `presentation`
command, a display name, and a visibility Boolean. This lets the stable HAL
device become the active profile endpoint with its own master volume and mute
controls, then return to a hidden generic identity while idle.

Disconnect uses a serializable dictionary containing
`{"command": "disconnect"}`. An earlier implementation used `kCFNull`; on
macOS 13, Core Audio attempted to handle that custom property as serialized
`CFData` and crashed in `CFDataGetBytePtr` during application shutdown. The
explicit dictionary avoids that proxy failure.

### 6.2 Shared-memory layout

Protocol version 1 uses a 128-byte `SABRTransportHeader` followed immediately
by interleaved `Float32` PCM frames. The header contains:

- magic value `SABR` (`0x53414252`);
- protocol and header versions;
- direction, stream ID, and bus index;
- channel capacity and current active-channel count;
- frame capacity;
- monotonic 64-bit read and write frame positions;
- dropped-frame and underrun counters;
- a sequence counter; and
- the current sample rate stored as its 64-bit floating-point bit pattern.

Compile-time assertions require the header to remain exactly 128 bytes and
require lock-free 64-bit atomics on supported architectures. A protocol version
change is required if a future modification is not compatible with this layout.

### 6.3 Connection lifecycle

1. The companion app creates a randomized `/private/tmp/sabr.XXXXXX` file.
2. It sizes the file for the header and PCM capacity, maps it read/write, and
   initializes the header.
3. It sends the validated configuration dictionary to the virtual device's
   `sabr` property.
4. The driver validates protocol fields, direction, stream, bus, channel and
   frame limits, exact region size, path prefix, file access/size, and the
   mapped header.
5. The driver opens with `O_NOFOLLOW`, maps the same region, and closes its file
   descriptor.
6. After a successful connection, the app unlinks the temporary pathname. The
   already-open mappings remain valid without leaving a discoverable file for
   the lifetime of the stream.
7. On shutdown, the app waits for its reader thread, sends the disconnect
   command, unmaps its region, and closes the descriptor.
8. The driver atomically removes and releases its mapping.

The temporary file is set to mode `0666` so the separate Core Audio process can
open it. The randomized name, sticky temporary directory, short pathname
lifetime, `O_NOFOLLOW`, strict prefix and size checks, and post-connect unlink
reduce exposure. This is local IPC, not a cryptographically authenticated
channel; changing that trust model would require a different handoff mechanism.

## 7. Real-time audio behavior

The inherited HAL `WriteMix` callback receives macOS's final interleaved output
mix. The fork adds a call to `sabr_driver_transport_write` with that buffer,
frame count, configured channel count, and sample rate.

The real-time callback does not:

- wait for CamiTune;
- perform socket or pipe I/O;
- open files or create mappings;
- allocate the transport; or
- call into Swift or CamillaDSP.

The writer uses atomic frame positions and bounded preallocated memory. When
there is insufficient room, it increments `droppedFrames` and drops the new
frames instead of blocking Core Audio. Ring wrapping is handled as one or two
copies. If the active channel count is smaller than the allocated capacity,
unused channel slots are zero-filled.

The app-side worker reads at most 2,048 frames at a time. It validates the
reported channel count, feeds valid frames to the DSP input and spectrum
analyzer, polls with a short delay when no frames are available, and publishes
transport statistics approximately twice per second.

## 8. Channel and sample-rate changes

The distributed app currently builds a stereo device. The driver build accepts:

```sh
SABR_CHANNELS=2 Drivers/SystemAudioBridge/build-driver.sh
SABR_CHANNELS=6 Drivers/SystemAudioBridge/build-driver.sh
```

Accepted build-time channel counts are 2 through 32. The shared protocol has a
32-channel maximum and separates allocated capacity from the active channel
count. The current CamiTune pipeline intentionally expects two active
channels and reports a mismatch instead of silently changing channel layouts.

The HAL advertises these sample rates:

```text
8,000; 16,000; 24,000; 44,100; 48,000; 88,200; 96,000;
176,400; 192,000; 352,800; 384,000; 705,600; 768,000 Hz
```

Multichannel support is therefore present at the driver and protocol level but
is not yet an end-to-end multichannel CamiTune feature. Shipping it requires
coordinated channel layouts in the HAL device, app reader, CamillaDSP capture,
DSP pipeline, and physical playback device.

## 9. App integration changes

CamiTune no longer depends on an installed BlackHole device. It discovers
the bridge by the exact System Audio Bridge UID and verifies that the `sabr`
custom property is supported. It creates public aggregate output selectors
with deterministic profile-derived UIDs and collision-safe profile names. The
generic endpoint does not appear in the normal macOS device list.

The public device name is derived from the profile name. If the profile name
matches its physical output name, `-EQ` is appended. If several profiles still
resolve to the same name, each receives a stable six-character profile-ID
suffix. The full profile UUID is used in the aggregate UID, so duplicate names
cannot overlap or select the wrong profile.

A profile selector is published only when at least one visibility rule holds:

- "Automatically activate when [profile name] is selected" is enabled;
- physical-output automatic activation is enabled and that physical output is
  currently the macOS default; or
- the profile selector is already the macOS default and must not be destroyed
  underneath Core Audio.

The aggregate exists only to make an inactive profile selectable. Once the app
activates that profile, the real bridge takes the same display name, becomes the
macOS default output, exposes its master volume and mute controls, and the
aggregate selector is destroyed. This avoids both a generic bridge entry and a
duplicate profile-name entry during normal operation.

When system-wide EQ is enabled, the app:

1. verifies the driver and selected physical output;
2. configures compatible sample rates;
3. starts CamillaDSP and its input sink;
4. creates and connects the shared transport;
5. gives the real bridge the active profile name and changes the macOS default
   output to that device; and
6. forwards bridge frames through CamillaDSP to the physical device.

When EQ is disabled or the app quits, the app stops meters and audio workers,
disconnects the driver transport, stops CamillaDSP, and restores the prior or
profile output when possible.

Old saved application profiles are migrated on decode. Legacy activation keys
are rewritten with profile-device terminology, and a saved routing-device
identity from the older integration is replaced by the System Audio Bridge UID
and name. That compatibility decoder does not make the old driver a runtime
routing option.

## 10. Build, signing, packaging, and installation

The fork adds standalone scripts rather than relying on the upstream product's
packaging:

- `build-driver.sh` compiles the C HAL bundle, injects channel/version metadata,
  ad-hoc signs it, verifies the signature, and checks the exported factory.
- `package-driver.sh` creates an optional installer package rooted at
  `/Library/Audio/Plug-Ins/HAL/CamillaAudio.driver`.
- `install-driver.sh` builds/installs the package with administrator approval.
- `uninstall-driver.sh` removes only the System Audio Bridge bundle and reloads
  Core Audio.
- `build-app.sh` embeds a freshly built driver under the application resources.

The in-app installer verifies the bundled driver's signature, requests macOS
administrator authorization, replaces the destination bundle, sets
`root:wheel` ownership, removes group/other write permission and quarantine
metadata, and reloads `coreaudiod`. It also removes the obsolete pre-release
bundle names `CamillaEQAudio.driver`, `CamillaAudioBridge.driver`, and
`SystemAudioBridge.driver`.

Local builds are ad-hoc signed. A production distribution can replace that with
Developer ID signing and notarization. The lack of a paid Developer ID does not
change the audio topology, but users should expect macOS Gatekeeper warnings for
downloaded ad-hoc-signed builds.

## 11. Tests added for the fork

Run:

```sh
Drivers/SystemAudioBridge/test-transport.sh
```

The native tests cover:

- stereo round trips;
- multichannel round trips;
- full-buffer drop behavior;
- cross-process mapped-memory operation;
- property-list type and disconnect validation;
- Core Audio custom-property discovery;
- property settable/data-type declarations;
- dynamic profile name and hidden/visible presentation changes; and
- the driver factory/property path.

The normal application build also compiles and embeds the driver, checks its
factory export, and verifies its code signature.

## 12. What remains inherited

System Audio Bridge still uses the BlackHole-derived AudioServerPlugIn/HAL
foundation, including its Core Audio object model, timing and zero timestamp
machinery, stream/property dispatch, volume and mute controls, sample-rate
configuration, and internal ring-buffer structure. The fork did not replace the
HAL implementation with a new DriverKit or AudioDriverKit architecture.

Some source branches and object IDs for input or a second device remain for
compile-time structure and possible future development. The shipping flags keep
those endpoints disabled. Their presence in C source does not mean macOS sees an
input device or second active device.

## 13. Current limitations

- Only one driver transport can be connected at a time.
- Only output direction, stream `0`, and bus `0` are accepted.
- The app ships and validates a stereo end-to-end pipeline.
- The driver does not process, equalize, mix, or play audio by itself.
- Several independently named profile aggregates can coexist, but they share
  the one hidden transport and only one profile/DSP pipeline can be active.
- Duplicating the HAL bundle is still unsafe without unique bundle, factory,
  model, device, and transport identities.

## 14. Future compatibility rules

When extending the driver:

1. Preserve output-only defaults unless an input endpoint is an explicit,
   reviewed product feature.
2. Increment `SABR_TRANSPORT_PROTOCOL_VERSION` for incompatible shared-memory
   or command semantics.
3. Keep real-time callbacks bounded and free of blocking work.
4. Validate every cross-process size, type, path, channel, stream, and version.
5. Give additional devices unique UIDs and independent transport state.
6. Update driver, C client, Swift client, DSP configuration, tests, and this
   document together.
7. Preserve GPL notices and the exact upstream provenance.

## 15. File map

| File | Role |
| --- | --- |
| `Driver/SystemAudioBridge.c` | BlackHole-derived HAL implementation plus output-mix publication and custom property. |
| `Driver/SystemAudioBridgeDriverTransport.c` | Mapping validation, connection ownership, bounded real-time writer. |
| `Driver/SystemAudioBridgeDriverTransport.h` | Driver transport API. |
| `Shared/SystemAudioBridgeTransport.h` | Versioned shared ABI and ring layout. |
| `Driver/Info.plist` | Bundle identity and AudioServerPlugIn factory metadata. |
| `build-driver.sh` | Configurable driver build and ad-hoc signing. |
| `package-driver.sh` | Installer-package construction. |
| `Installer/postinstall` | Permissions, obsolete-bundle cleanup, Core Audio reload. |
| `test-transport.sh` | Native transport and HAL property tests. |
| `UPSTREAM.md` | Concise upstream revision and licensing record. |
