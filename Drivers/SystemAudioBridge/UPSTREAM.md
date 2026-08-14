# System Audio Bridge driver provenance

`Driver/SystemAudioBridge.c` is derived from BlackHole by Existential Audio Inc.,
revision `ffcb74433fbcf8c8ca5c736677c1a4864384dc09`, and is distributed under
GPL-3.0. The source was renamed and modified to provide an output-only device
and a private, versioned shared-memory transport for companion applications.

- Upstream: https://github.com/ExistentialAudio/BlackHole
- Upstream license: GPL-3.0

The added transport and integration files are also distributed under this
repository's GPL-3.0-only license.

For a detailed engineering description of the fork, see
[`BLACKHOLE_CHANGES.md`](BLACKHOLE_CHANGES.md).
