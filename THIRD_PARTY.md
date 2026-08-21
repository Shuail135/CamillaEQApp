# Third-party components

CamiTune builds CamillaDSP from its official upstream source with the repository's Core Audio UID patch and includes the resulting executable in the app bundle. The app bundle also includes the source-built System Audio Bridge HAL driver so users do not need a separate loopback download.

- [CamillaDSP](https://github.com/HEnquist/camilladsp): dual-licensed under GPL-3.0 and MPL-2.0 for the macOS build used here.
- System Audio Bridge is a modified, output-only derivative of [BlackHole](https://github.com/ExistentialAudio/BlackHole) revision `ffcb74433fbcf8c8ca5c736677c1a4864384dc09`, Copyright (C) 2019 Existential Audio Inc., licensed under GPL-3.0. Modifications add the System Audio Bridge identity and a private, versioned app transport.
- Device Correction target samples are derived from [AutoEq](https://github.com/jaakkopasanen/AutoEq) and [PublicGraphTool](https://github.com/HarutoHiroki/PublicGraphTool), both under their MIT licenses. Full attribution and license texts are bundled in `DeviceCorrectionTargets/NOTICE.md`.

CamiTune is therefore distributed under GPL-3.0-only. Each component remains subject to its upstream copyright and license terms. Recheck those terms before changing how dependencies are acquired or bundled.
