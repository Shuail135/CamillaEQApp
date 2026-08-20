# CamillaDSP Core Audio UID contribution

`0001-coreaudio-accept-device-uid.patch` is based on CamillaDSP commit
`05e9cfcdf43c0dfe078ed3feb8af4c8bd701fd74` (v4.1.3 development tree).

The patch keeps the existing CoreAudio `device` configuration field. Its value
is matched against a persistent Core Audio UID first and a display name second,
so existing configurations remain valid. CoreAudio device discovery also
returns UID/display-name pairs through the existing websocket API.

Apply and build it in a CamillaDSP checkout:

```sh
git am /path/to/0001-coreaudio-accept-device-uid.patch
cargo build --release
```

CamiTune's release build applies this patch and bundles the resulting executable.
Setup copies that UID-capable build to
`~/Library/Application Support/CamiTune/bin/`; it does not install the
incompatible official binary. You can override the build input by setting
`CAMITUNE_CAMILLADSP_BINARY` to another executable containing the same patch.
