# Third-party components

CamillaEQApp downloads dependencies from their official upstream releases at setup time and does not embed them in the application or GitHub release archive.

- [CamillaDSP](https://github.com/HEnquist/camilladsp): dual-licensed under GPL-3.0 and MPL-2.0 for the macOS build used here.
- [BlackHole](https://github.com/ExistentialAudio/BlackHole): GPL-3.0. Its upstream project states that integration into a non-GPLv3 application requires a separate license from Existential Audio.

CamillaEQApp is therefore distributed under GPL-3.0-only. Each downloaded component remains subject to its own upstream copyright and license terms. Recheck those terms before changing how dependencies are acquired or before bundling them with the app.
