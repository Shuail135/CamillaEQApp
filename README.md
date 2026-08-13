<p align="center">
  <img src="Sources/CamillaEQApp/icon.png" width="128" height="128" alt="CamillaEQApp duck icon">
</p>

<h1 align="center">CamillaEQApp</h1>

<p align="center">
  A native macOS app for system-wide parametric EQ with frequency, gain, and Q controls. Powered by CamillaDSP and BlackHole.
</p>

<p align="center">
  <img alt="Version 0.1.1" src="https://img.shields.io/badge/version-0.1.1-blue">
  <img alt="macOS 13 or newer" src="https://img.shields.io/badge/macOS-13%2B-black">
  <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-orange">
  <a href="LICENSE"><img alt="GPL 3.0 only" src="https://img.shields.io/badge/license-GPL--3.0--only-green"></a>
</p>

CamillaEQApp gives macOS a proper **system-wide parametric equalizer** with an easy-to-use app interface. Each EQ band gives you direct control over its **frequency**, **gain**, **Q (bandwidth)**, filter type, and on/off state, so you can make precise corrections instead of relying on a basic bass-and-treble control.

Your EQ applies to audio from the whole Mac. Choose your headphones, speakers, DAC, or audio interface; shape the sound visually or import an Equalizer APO preset; then turn on **System-wide EQ**. CamillaEQApp can remember separate settings for each output device and apply the correct profile automatically when you switch devices.


## What you can do

- **Use precise parametric EQ:** directly adjust frequency, gain, Q, filter type, and enabled state for every band.
- **Adjust sound in an app interface:** control up to 20 EQ bands visually and see the resulting frequency-response curve.
- **Import existing settings:** paste or import common Equalizer APO headphone and speaker presets.
- **Save settings for each device:** keep different profiles for headphones, speakers, DACs, and audio interfaces.
- **Switch automatically:** apply the correct profile when its output device is selected or connected.
- **See what is playing:** view a live frequency spectrum and input/output level meters.
- **Run quietly in the background:** reopen the app from its duck icon in the menu bar.
- **Start at login:** optionally launch CamillaEQApp when you sign in to your Mac.
- **Set up required components:** install CamillaDSP and BlackHole from the app's Setup page.

CamillaEQApp uses one active sound profile at a time. You can save as many profiles as you want, but your Mac's audio only passes through one EQ at once.

## How it works

CamillaEQApp safely sends your Mac's audio through the equalizer before it reaches your headphones or speakers:

```text
macOS applications
        │
        ▼
BlackHole 2ch ─────► live spectrum
        │
        ▼
CamillaDSP
        │
        ▼
Selected physical output
```

BlackHole carries the Mac's audio into CamillaEQApp, and CamillaDSP applies your EQ settings. CamillaEQApp manages this connection for you—you do not need to open CamillaDSP, CamillaGUI, Audio MIDI Setup, or Terminal during normal use.

When you turn EQ off, CamillaEQApp stops processing and returns audio to the physical output.

## Prerequisite

- MacOS 13 Ventura or newer.


During setup, macOS asks for **Audio Input** or **Microphone** permission. CamillaEQApp needs this permission to receive audio from BlackHole and draw the live spectrum; it does not use your Mac's built-in microphone for the EQ route.

Intel Mac users can build the app from source, but the current ready-made GitHub download is for Apple silicon. Windows and Linux are not supported.

## Install CamillaEQApp

### 1. Download the app

Open the repository's **Releases** page and download `CamillaEQApp-v0.1.1.dmg`.

### 2. Move it to Applications

Open the downloaded DMG, then drag `CamillaEQApp.app` into your Mac's **Applications** folder. You can eject the DMG afterward.

### 3. Open it for the first time

The current release is not notarized by Apple, so a normal double-click may be blocked:

1. Open the **Applications** folder in Finder.
2. Right-click `CamillaEQApp` and choose **Open**.
3. Select **Open** again in the confirmation window.

You normally need to do this only once.

### 4. Install the audio components

1. In CamillaEQApp, choose **Setup** in the sidebar.
2. Select **Install / Repair Everything**.
3. Enter your administrator password when macOS opens the BlackHole installer.
4. Restart your Mac if the app asks you to do so.
5. Reopen CamillaEQApp after restarting.

### 5. Create your first sound profile

1. Select **Add Output Profile** at the bottom of the sidebar.
2. Choose the headphones, speakers, DAC, or audio interface you want to use.
3. Adjust the graphical equalizer, paste an Equalizer APO preset, or import a `.txt` preset.
4. Leave the sample rate at `48 kHz` unless you know your device needs another value.
5. Save your changes and turn on **System-wide EQ**.
6. Allow Audio Input/Microphone access when macOS asks.

Start playback at a low volume. You should see movement in the level meters and live spectrum when everything is working.

### Which release file should I download?

| Download | Who it is for |
| --- | --- |
| `CamillaEQApp-v0.1.1.dmg` | Most users—open it and move the app to Applications. |
| `CamillaEQApp-v0.1.1-app.zip` | Users who prefer a ZIP containing only the app. |
| `CamillaEQApp-v0.1.1-build-folder.zip` | Developers who want the complete generated build folder. |
| `SHA256SUMS` | Advanced users who want to verify downloaded files. |

A Mac `.app` is actually a folder containing many files, so GitHub cannot offer it as one unwrapped download. The DMG is the simplest way to download it as a normal Mac application.

## Troubleshoot

- **The app will not open:** right-click it in Applications and choose **Open**.
- **BlackHole is missing after installation:** restart your Mac, then reopen CamillaEQApp.
- **There is no sound:** turn off System-wide EQ, confirm the physical output works normally, then reopen Setup and run **Install / Repair Everything**.
- **The spectrum does not move:** enable CamillaEQApp under **System Settings → Privacy & Security → Microphone**.
- **The duck menu-bar icon is hidden:** your menu bar may be full. Temporarily close another menu-bar app; when the duck appears, hold **Command** and drag it farther left.

## Equalizer APO syntax v1.0

Supported examples:

```text
Preamp: -5.0 dB
Filter 1: ON PK Fc 100 Hz Gain 2.0 dB Q 0.70
Filter 2: ON PEQ Fc 2500 Hz Gain -3.0 dB BW Oct 0.50
Filter 3: ON LS Fc 80 Hz Gain 1.5 dB Q 0.70
Filter 4: ON HS Fc 8000 Hz Gain -2.0 dB Q 0.70
Filter 5: ON HPQ Fc 25 Hz Q 0.70
Filter 6: ON NO Fc 8000 Hz Q 5.00
```

`Device:` is recognized but ignored because device selection belongs to CamillaEQApp profiles. `Channel:` produces a warning because version 0.1.1 applies filters to both stereo channels.

The complete Equalizer APO language is not supported. This release does not claim support for `Include`, `GraphicEQ`, convolution, conditional expressions, processing stages, or arbitrary channel routing.

## Build from source

Install Xcode or Xcode Command Line Tools with Swift 5.9 or newer, then run:

```bash
git clone YOUR_REPOSITORY_URL
cd CamillaEQApp
./build-app.sh
open dist/CamillaEQApp.app
```

The finished bundle is written to `dist/CamillaEQApp.app`. You can also open `Package.swift` directly in Xcode for development.

## Current limitations

- Stereo processing only.
- The automated release currently contains an Apple Silicon executable rather than a universal binary.
- Bluetooth, AirPods, aggregate-device, and sample-rate transitions may behave differently across hardware.
- CoreAudio routing is monitored once per second rather than through persistent property listeners.
- BlackHole installation remains a privileged system change and requires normal macOS approval.
- Releases are not yet Developer ID signed or notarized.
- CamillaEQApp does not detect or disable unrelated system-EQ applications.

## Roadmap

- Universal Apple Silicon and Intel release archives.
- Developer ID signing and notarization.
- Stable CoreAudio property listeners.
- Per-channel Equalizer APO `Channel:` support.
- Profile import and export.
- Better spectrum smoothing and hold controls.
- Menu-bar quick controls.

## Third-party software

CamillaEQApp downloads dependencies from their official upstream locations at setup time; they are not embedded in the application or release archive.

- [CamillaDSP](https://github.com/HEnquist/camilladsp) — GPL-3.0 or MPL-2.0 for the macOS build used here.
- [BlackHole](https://github.com/ExistentialAudio/BlackHole) — GPL-3.0.

See [THIRD_PARTY.md](THIRD_PARTY.md) for details. Review upstream terms again before changing how dependencies are acquired or distributed.

## Contributing

Issues and pull requests are welcome. When reporting an audio-routing problem, include your macOS version, Mac architecture, physical output device, selected sample rate, and the relevant CamillaEQApp log without private information.

## License

Copyright © 2026 CamillaEQApp contributors.

CamillaEQApp is free software licensed under the [GNU General Public License v3.0 only](LICENSE). It is provided without warranty; see the license for complete terms.
