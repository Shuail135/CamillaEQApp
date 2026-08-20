#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="CamiTune"
APP_VERSION="${APP_VERSION:-0.2.1}"
# GitHub Actions exposes the pushed tag through these variables. A release tag
# such as v0.1.2 therefore produces an app whose bundle version is 0.1.2
# without requiring a manual source edit for every patch release.
if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
    if [[ "${GITHUB_REF_NAME:-}" =~ '^v([0-9]+\.[0-9]+\.[0-9]+)$' ]]; then
        APP_VERSION="${GITHUB_REF_NAME#v}"
    else
        echo "ERROR: Release tags must use the format vMAJOR.MINOR.PATCH (for example v0.1.2)."
        exit 1
    fi
fi
# A changing build number prevents Finder and Login Items from reusing icon
# metadata cached for an older ad-hoc build with the same public version.
BUILD_NUMBER="${BUILD_NUMBER:-$(/bin/date -u +%Y%m%d%H%M%S)}"
BUNDLE_ID="local.camilla.app"
DIST="$PWD/dist"
APP="$DIST/$APP_NAME.app"
BIN_OUT="$DIST/$APP_NAME"
SOURCES=(Sources/CamiTune/*.swift)
ICON_SOURCE="Sources/CamiTune/icon.png"
MIN_MACOS="13.0"
BUNDLED_DRIVER="$PWD/build/driver/CamillaAudio.driver"
CAMILLADSP_REV="05e9cfcdf43c0dfe078ed3feb8af4c8bd701fd74"
CAMILLADSP_PATCH="$PWD/Contributions/CamillaDSP/0001-coreaudio-accept-device-uid.patch"
CAMILLADSP_BUILD_ROOT="$PWD/build/camilladsp"
CAMILLADSP_SOURCE="$CAMILLADSP_BUILD_ROOT/source"
CAMILLADSP_BUNDLED_BINARY="$CAMILLADSP_BUILD_ROOT/camilladsp"
CAMILLADSP_BUILD_STAMP="$CAMILLADSP_BUILD_ROOT/build-key"

mkdir -p "$DIST"

echo "Building $APP_NAME…"

# Use this exact direct-compiler build path with both standalone Command Line
# Tools and full Xcode. This keeps local and GitHub release artifacts identical
# in structure and avoids a runtime dependency on a SwiftPM resource bundle.
if ! SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path 2>/dev/null)" ||
   ! SWIFTC="$(/usr/bin/xcrun --sdk macosx --find swiftc 2>/dev/null)" ||
   ! CLANG="$(/usr/bin/xcrun --sdk macosx --find clang 2>/dev/null)"; then
    echo "ERROR: Apple developer tools are not installed or selected."
    echo "Run: xcode-select --install"
    exit 1
fi

ARCH="$(/usr/bin/uname -m)"
case "$ARCH" in
    arm64|x86_64) ;;
    *)
        echo "ERROR: Unsupported Mac architecture: $ARCH"
        exit 1
        ;;
esac

TARGET="${ARCH}-apple-macosx${MIN_MACOS}"
TRANSPORT_INCLUDE="Sources/SystemAudioBridgeC/include"
TRANSPORT_OBJECT="$DIST/SystemAudioBridgeClient.o"

echo "Using direct compiler build path."
echo "Swift compiler: $SWIFTC"
echo "Target: $TARGET"

"$CLANG" \
    -std=gnu11 \
    -O2 \
    -isysroot "$SDK" \
    -mmacosx-version-min="$MIN_MACOS" \
    -I "$TRANSPORT_INCLUDE" \
    -c Sources/SystemAudioBridgeC/SystemAudioBridgeClient.c \
    -o "$TRANSPORT_OBJECT"

"$SWIFTC" \
    -O \
    -swift-version 5 \
    -parse-as-library \
    -sdk "$SDK" \
    -target "$TARGET" \
    -module-cache-path "$DIST/ModuleCache" \
    -I "$TRANSPORT_INCLUDE" \
    "${SOURCES[@]}" \
    "$TRANSPORT_OBJECT" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Accelerate \
    -framework AudioToolbox \
    -framework CoreAudio \
    -framework CoreImage \
    -framework UniformTypeIdentifiers \
    -framework UserNotifications \
    -framework ServiceManagement \
    -o "$BIN_OUT"

BIN="$BIN_OUT"

echo "Building bundled System Audio Bridge driver…"
SABR_CHANNELS=2 SABR_MIN_MACOS="$MIN_MACOS" Drivers/SystemAudioBridge/build-driver.sh

echo "Building UID-capable CamillaDSP…"
if [[ -n "${CAMITUNE_CAMILLADSP_BINARY:-}" ]]; then
    if [[ ! -x "$CAMITUNE_CAMILLADSP_BINARY" ]]; then
        echo "ERROR: CAMITUNE_CAMILLADSP_BINARY is not executable: $CAMITUNE_CAMILLADSP_BINARY"
        exit 1
    fi
    CAMILLADSP_INPUT_HASH="$(/usr/bin/shasum -a 256 "$CAMITUNE_CAMILLADSP_BINARY" | /usr/bin/awk '{print $1}')"
    CAMILLADSP_BUILD_KEY="override-${ARCH}-${CAMILLADSP_INPUT_HASH}"
else
    CAMILLADSP_PATCH_HASH="$(/usr/bin/shasum -a 256 "$CAMILLADSP_PATCH" | /usr/bin/awk '{print $1}')"
    CAMILLADSP_BUILD_KEY="source-${ARCH}-${CAMILLADSP_REV}-${CAMILLADSP_PATCH_HASH}"
fi

CURRENT_CAMILLA_BUILD_KEY="$(/bin/cat "$CAMILLADSP_BUILD_STAMP" 2>/dev/null || true)"
if [[ -x "$CAMILLADSP_BUNDLED_BINARY" && "$CURRENT_CAMILLA_BUILD_KEY" == "$CAMILLADSP_BUILD_KEY" ]]; then
    echo "Reusing cached UID-capable CamillaDSP."
else
    mkdir -p "$CAMILLADSP_BUILD_ROOT"
    if [[ -n "${CAMITUNE_CAMILLADSP_BINARY:-}" ]]; then
        cp "$CAMITUNE_CAMILLADSP_BINARY" "$CAMILLADSP_BUNDLED_BINARY"
    else
        if ! command -v cargo >/dev/null 2>&1; then
            echo "ERROR: Rust/Cargo is required because the cached CamillaDSP build is missing or outdated."
            echo "Install Rust from https://rustup.rs, or set CAMITUNE_CAMILLADSP_BINARY to a patched executable."
            exit 1
        fi
        rm -rf "$CAMILLADSP_SOURCE"
        mkdir -p "$CAMILLADSP_SOURCE"
        git -C "$CAMILLADSP_SOURCE" init -q
        git -C "$CAMILLADSP_SOURCE" remote add origin https://github.com/HEnquist/camilladsp.git
        git -C "$CAMILLADSP_SOURCE" fetch --depth 1 origin "$CAMILLADSP_REV"
        git -C "$CAMILLADSP_SOURCE" checkout -q --detach FETCH_HEAD
        git -C "$CAMILLADSP_SOURCE" apply "$CAMILLADSP_PATCH"
        cargo build --release --manifest-path "$CAMILLADSP_SOURCE/Cargo.toml"
        cp "$CAMILLADSP_SOURCE/target/release/camilladsp" "$CAMILLADSP_BUNDLED_BINARY"
    fi
    echo "$CAMILLADSP_BUILD_KEY" > "$CAMILLADSP_BUILD_STAMP"
fi
chmod +x "$CAMILLADSP_BUNDLED_BINARY"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Drivers" "$APP/Contents/Resources/CamillaDSP"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ICON_SOURCE" "$APP/Contents/Resources/icon.png"
cp LICENSE THIRD_PARTY.md "$APP/Contents/Resources/"
/usr/bin/ditto "$BUNDLED_DRIVER" "$APP/Contents/Resources/Drivers/CamillaAudio.driver"
cp "$CAMILLADSP_BUNDLED_BINARY" "$APP/Contents/Resources/CamillaDSP/camilladsp"
chmod +x "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/Resources/CamillaDSP/camilladsp"

# Build the standard macOS iconset, including every Retina representation.
ICONSET="$DIST/AppIcon.iconset"
ICON_CACHE="$DIST/AppIcon.icns"
if [[ ! -s "$ICON_CACHE" || "$ICON_SOURCE" -nt "$ICON_CACHE" ]]; then
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    make_icon() {
        local pixels="$1"
        local filename="$2"
        /usr/bin/sips -z "$pixels" "$pixels" "$ICON_SOURCE" \
            --out "$ICONSET/$filename" >/dev/null
    }
    make_icon 16 icon_16x16.png
    make_icon 32 icon_16x16@2x.png
    make_icon 32 icon_32x32.png
    make_icon 64 icon_32x32@2x.png
    make_icon 128 icon_128x128.png
    make_icon 256 icon_128x128@2x.png
    make_icon 256 icon_256x256.png
    make_icon 512 icon_256x256@2x.png
    make_icon 512 icon_512x512.png
    make_icon 1024 icon_512x512@2x.png
    /usr/bin/iconutil -c icns "$ICONSET" -o "$ICON_CACHE"
    rm -rf "$ICONSET"
fi
cp "$ICON_CACHE" "$APP/Contents/Resources/AppIcon.icns"
if [[ ! -s "$APP/Contents/Resources/AppIcon.icns" ]]; then
    echo "ERROR: Failed to build AppIcon.icns."
    exit 1
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 CamiTune contributors. Licensed under GPL-3.0-only.</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

/usr/bin/codesign --force --deep --sign - "$APP"

echo
echo "Built: $APP"
echo "Open it with: open '$APP'"
