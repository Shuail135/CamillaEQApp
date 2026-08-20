# Core Functions

- [ ] [DSP Architecture changes](#dsp-architecture)
- [ ] [Per-channel EQ/gain](#per-channel-eqgain)
- [ ] [Live config patching over WebSocket](#websocket)
- [ ] [Simple Bass / Mids / Treble controls](#simple-eq-controls)
- [ ] Auto-EQ
- [ ] [Meters / status](#meters--status)
- [ ] [Limiter + clipping detection](#limited--clipping)
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


***
# Changelogs
## CamiTune
### v0.2 
- [x] New custom audio driver(no longer require microphone permission)
- [x] Better visualize EQ edit in equalizer
- [x] New logic of profile switch and EQ activate
- [x] Select profiles in macos default audio selection
- [x] Separate PCM delivery of Spectrum Analyzer and Camilla
- [x] Spectrum Analyzer only active for the current activated profile
- [X] Implement drop/recover DSP pipeline
- [x] Adaptive clock/rate matching
- [x] CamillaDSP contribution patch to allow accepting Core Audio UID
- [x] Different view for each profile
- [ ] Better activate profile logics and interface

#### Knowns Bugs
- [x] Remove adding audio route as output device
- [x] Random crashes while removing audio devices
- [x] Fixes profile audio devices may stored even profile is deleted
- [x] Profile saving conflicts
- [x] Profile can have same name

## Equalizer APO syntax
### v1.0
- Presets using `BW Oct` are converted to the equivalent Q value
- Supported `PK` / `PEQ`, `LS` / `LSC`, `HS` / `HSC`, `LP` / `LPQ`, `HP` / `HPQ`, `NO`, and `AP`
- `Device: ` is recognized but ignored
- `Channel:` produces a warning because the current release applies filter to both stereo channels

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

***
### DSP Architecture

**From:**
- Profile(when saved) -> EqualizerAPO parsing -> YAML -> CamillaDSP

**To:**
-CamiTune UI -> ProcessingProfile -> ProcessingGraph -> CamillaDSP Compiler -> CamillaDSP

**Processing stages**
- gain
- equalizer
- convolution
- delay
- mixer
- loudness
- limiter
- compressor
- crossfeed

### Per-channel EQ/gain

**Channels with groups:**
Front
0.  L
1.  R
Center
2. C
Sunwoofer
3. LFE
Surround
4. Ls
5. Rs
Rear
6. Lrs
7. Rrs

##### Profile
> Gloval Processing
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
