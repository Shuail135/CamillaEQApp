# Core Functions

- [x] [DSP Architecture changes](#dsp-architecture)
- [x] [Per-channel EQ/gain](#per-channel-eqgain)
- [x] [Live config patching over WebSocket](#websocket)
- [x] [Simple Bass / Mids / Treble controls](#simple-eq-controls)
- [x] [Device-Correction](#Device-Correction)
- [x] [Meters / status](#meters--status)
- [x] [Limiter + clipping detection](#limited--clipping)
- [ ] [FIR / convolution](#fir--convolution)
- [ ] [Profile import / export](#profile-import--export)
- [ ] [Headphone crossfeed](#headphone-crossfeed)
- [ ] [Loudness Compensation](#loudness-compensation)
- [ ] [Per-channel delay](#per-channel-delay)
- [ ] [Per-app volume](#per-app-volume)
- [ ] [Menu-bar quick controls](#menu-bar-quick-controls)
- [ ] [Microphone EQ](#microphone-eq)
- [ ] [Full multichannel](#full-multichannel)
- [ ] [Full mixer/routing UI](#full-mixerrouting-ui)
- [ ] [Compressor](#compressor)
- [ ] Noise gate / RACE
- [ ] VST/AUv3 Support
- [ ] Remote Control


***
# Changelogs
## CamiTune
### v0.2 
- New custom audio driver(no longer require microphone permission)
- Better visualize EQ edit in equalizer
- New logic of profile switch and EQ activate
- Select profiles in macos default audio selection
- Separate PCM delivery of Spectrum Analyzer and Camilla
- Spectrum Analyzer only active for the current activated profile
- Implement drop/recover DSP pipeline
- Adaptive clock/rate matching
- CamillaDSP contribution patch to allow accepting Core Audio UID
- Different view for each profile
- Better activate profile logics and interface

### v0.3
- [x] DSP architecture rework
- [x] Per channel eq
- [x] Websocket
- [x] Simple eq(bass/mid/treble) control
- [x] Device Correction v1.0
- [x] Automatic Headroom
- [x] Meters / status
- [x] Limiter+clipping detection
- [x] Equalizer APO syntax v2.0

**Bug fixes:**
- [x] cannot reduce equalizer band number after expanded
- [x] equalizer band wouldn't auto organize from frequency
- [x] equalizer bar's label is not absolute accurate

## Equalizer APO syntax
### v1.0
- Presets using `BW Oct` are converted to the equivalent Q value
- Supported `PK` / `PEQ`, `LS` / `LSC`, `HS` / `HSC`, `LP` / `LPQ`, `HP` / `HPQ`, `NO`, and `AP`
- `Device: ` is recognized but ignored
- `Channel:` produces a warning because the current release applies filter to both stereo channels

### v2.0
- fixed-slope LS/HS 6dB and 12dB
- LSC/HSC x dB
- Accepts attached units such as 100Hz, -3dB, decimal commas, and localized frequency separators.
- Completely invalid or empty files still show an error.

### Future(in progress)
- `Channel: `, `GraphicEQ: `, `Include: `, `Copy: `, `Delay: `, `Convolution: `
- `BP`, `LS 6dB`, `LS 12dB`, `HS 6dB`, `HS 12dB`
- Generic `IIR Coefficients`
- `If/ElseIf/Else/EndIf`, expressions
- `Stage: `

## System Audio Bridge 
### v0.1.1
- CamiTune's output-only Core Audio HAL device
- derived from Blackhole, customized as it will not use the real microphone as the input
- no collide with an installed BlackHole device

### v0.2.1
- UID implemented

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
- discovers the bridge by the exact System Audio Bridge UID and berifies that the SABR custom property is supported
- then it creates public aggregate output selectors with deterministic profile-derived UIDs and collision-safe profile names. 
- The public device name is derived from the profile name, and it will only be published when profile activeted

## Device Correction



### v0.1 (in progress)
- Global Channel Correction
- Local CSV measurement/custom-target import
- native conservative and exact policies
- native PEQ optimization
- target/EQ-value preview, and a draft-only handoff into the normal editable global EQ
- Online search uses one result per complete device/configuration name.
- Tuning switch, nozzle, pad, ANC, and other measured variants remain separate entries.
- Squiglink, AutoEq, and other cataloged measurements are resolved behind the result, deduplicated, grouped by compatible rig, normalized, and combined into a confidence-weighted consensus before CamiTune calculates its own correction.
- Independent evidence is counted by laboratory/unit rather than reference count.
- Exact and Recommended modes both retain confidence as optimizer priority only.
- The native fitter supports shelves and jointly refines all selected filters.
- Structured identities, source snapshots, and a versioned persistent response cache make calculations reproducible.

 **Targets:**
- [x] Flat diagnostic target
- [x] JM-1 / PopAvg-DF with adjustable tilt and rig-specific transfer
- [x] Harman In-Ear 2019 v2
- [x] IEF Preference 2025 (711 and B&K 5128 variants)
- [x] IEF Neutral 2023
- [x] Diffuse Field Reference (KEMAR/711 and B&K 5128 variants)
- [x] Etymotic target
- [x] Custom CSV
- [x] Device Match

***
### DSP Architecture

**From:**
- Profile(when saved) -> EqualizerAPO parsing -> YAML -> CamillaDSP

**To:**
- CamiTune UI -> ProcessingProfile -> ProcessingGraph -> CamillaDSP Compiler -> CamillaDSP

**Architecture invariants for future stages**
- `ProcessingProfile` is the only persisted DSP model. Every schema change must
  include an explicit migration and preserve stable stage/filter identities.
- Reserved semantic IDs identify controls such as User preamp and automatic
  headroom; stage array position must never be used as semantic identity.
- `ProcessingGraph` validates and orders runtime processing. UI and importers do
  not emit CamillaDSP configuration directly.
- The compiler is the only CamillaDSP-specific layer. A new processor must add
  persisted coding, graph validation, backend compilation, graph-diff behavior,
  and migration/round-trip/runtime-patch tests together.
- Automatic headroom covers every response-raising stage except the intentional
  User preamp. It remains runtime-derived and is never persisted as user gain.
- Meters, FFT, clipping animation, and other visual telemetry are
  presentation-gated; the active audio route itself must never depend on a view.

**Processing stages**
- [x] gain
- [x] equalizer
- [ ] convolution
- [ ] delay
- [ ] mixer
- [ ] loudness
- [x] limiter
- [ ] compressor
- [ ] crossfeed

### Per-channel EQ/gain

**Channels with groups:**
Front
0.  L
1.  R
Center
2. C
Subwoofer
3. LFE
Surround
4. Ls
5. Rs
Rear
6. Lrs
7. Rrs

##### Profile
> Global Processing
> 	Preamp
> 	Global Filter
> Channels
> 	Channel 0:
> 		Gain
> 		Filters
> 	Channel 1:
> 		Gain
> 		Filters ...

- Separate channel index and semantic role
- and create camilladsp pipeline

### Websocket
- change it to using CamillaDSP's runtime configuration API
- not needed to generate entire YAML everytime
- User moves EQ points -> ProcessingGraph -> calculate configuration diff -> CamillaDSP WebSocket -> live audio update

**CamillaDSP Controller: **
- applyGraph
- pathStage
- setVolume
- setMute
- fetchMeters
- fetchDiagnostics

### Simple EQ Controls
- 3 knobs under the equalizer
- adjust the graphic equalizer bar

### Meters /  Status
- AudioRuntimeMonitor
	- Levels
	- Clipping
	- DSP load
	- Buffer level
	- Rate adjustment
	- Engine state
- Separate the route, aka SABR-> PCM Router to go to 3 separated, Spectrum Analyzer, CamillaDSP, Meters/Status

### Limited + Clipping
- connect pipeline with limiter filter and WebSocket commands

### FIR / Convolution
- Input -> PEQ -> FIR -> Limiter -> Output
Allows:
- Headphone correction
- Room correction
- Custom impulse reponses
- Linear-phase EQ
- REW-generated corrections
- Crossovers

### Profile import / export
- Create ProfileName.camitune
	- Containing;
	- manifest.json
	- profile.json
	- Assets/ 
		- and the wav


### Headphone crossfeed
- Don't expose Mixer A, Delay B, Lowpass C, Gain D unless advance mode
- complies;
	- Crossfeed Amount:
	- Delay:
	- Frequency: 
- Separate it with RACE

### Loudness Compensation
- figure out way to considers the autoritative volume level first

### Per-channel delay
- should be very easy

### Per-app volume
- separate each app to each client stream
- then mix then global DSP
- Implement;
	- Client identity
	- PID
	- bundle ID
	- stream lifecycle
	- buffer ownership
	- per-app volume
	- per-app mute
	- per-app bypass
	- per-app eq

### Menu-bar quick controls
- Control per-app volume

### Microphone EQ
- Make a new audio driver
- Physical microphone -> Mic Engine -> ProcessingGraph -> CamillaDSP -> CamiTune Virtual Microphone -> Output
- Reuse
	- ProcessingGraph
	- Filter models
	- CamillaDSPCompiler
	- meters
	- profile system
- Separate
	- InputAudioRuntime
	- OutputAudioRuntime
- Gain -> High-pass -> EQ -> Noise gate -> Compressor -> limiter -> Virtual microphone

### Full multichannel
- Channel-layout discover -> N-channel SABR reader -> ProcessingGraph -> Mixer -> per-channel DSP -> CamillaDSP -> N-channel physical output
- 5.1
- 7.1

### Full mixer/routing UI
- downmix
- upmix
- crossfeed
- crossovers
- channel swapping
- mono
- bass routing

### Compressor
- in advanced settings
