#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="CamillaEQApp"
APP_VERSION="${APP_VERSION:-0.1.1}"
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
BUNDLE_ID="local.camillaeq.app"
DIST="$PWD/dist"
APP="$DIST/$APP_NAME.app"
BIN_OUT="$DIST/$APP_NAME"
SOURCES=(Sources/CamillaEQApp/*.swift)
ICON_SOURCE="Sources/CamillaEQApp/icon.png"
MIN_MACOS="13.0"
RESOURCE_BUNDLE=""

mkdir -p "$DIST"

echo "Building $APP_NAME…"

DEV_DIR="$(/usr/bin/xcode-select -p 2>/dev/null || true)"

if [[ -z "$DEV_DIR" ]]; then
    echo "ERROR: Apple developer tools are not installed."
    echo "Run: xcode-select --install"
    exit 1
fi

# SwiftPM currently asks xcrun for an Xcode PlatformPath.  The standalone
# Command Line Tools installation has the macOS SDK but no Xcode .platform
# directory, so compile this dependency-free app directly with swiftc.
if [[ "$DEV_DIR" == "/Library/Developer/CommandLineTools"* ]]; then
    echo "Using standalone Command Line Tools build path."

    SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
    SWIFTC="$(/usr/bin/xcrun --find swiftc)"
    ARCH="$(/usr/bin/uname -m)"

    case "$ARCH" in
        arm64|x86_64) ;;
        *)
            echo "ERROR: Unsupported Mac architecture: $ARCH"
            exit 1
            ;;
    esac

    TARGET="${ARCH}-apple-macosx${MIN_MACOS}"

    "$SWIFTC" \
        -O \
        -parse-as-library \
        -sdk "$SDK" \
        -target "$TARGET" \
        "${SOURCES[@]}" \
        -framework SwiftUI \
        -framework AppKit \
        -framework AVFoundation \
        -framework Accelerate \
        -framework AudioToolbox \
        -framework CoreAudio \
        -framework UniformTypeIdentifiers \
        -framework UserNotifications \
        -framework ServiceManagement \
        -o "$BIN_OUT"

    BIN="$BIN_OUT"
else
    echo "Using Xcode/SwiftPM build path: $DEV_DIR"
    /usr/bin/env swift build -c release
    BIN_DIR="$(/usr/bin/env swift build -c release --show-bin-path)"
    BIN="$BIN_DIR/$APP_NAME"
    RESOURCE_BUNDLE="$BIN_DIR/${APP_NAME}_${APP_NAME}.bundle"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ICON_SOURCE" "$APP/Contents/Resources/icon.png"
cp LICENSE THIRD_PARTY.md "$APP/Contents/Resources/"
if [[ -n "$RESOURCE_BUNDLE" && -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
fi
chmod +x "$APP/Contents/MacOS/$APP_NAME"

# Build the standard macOS iconset, including every Retina representation.
ICONSET="$DIST/AppIcon.iconset"
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
/usr/bin/iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
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
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 CamillaEQApp contributors. Licensed under GPL-3.0-only.</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>NSMicrophoneUsageDescription</key><string>CamillaEQApp uses audio-input access to receive system audio from the BlackHole virtual device and display the live frequency spectrum.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

/usr/bin/codesign --force --deep --sign - "$APP"

echo
echo "Built: $APP"
echo "Open it with: open '$APP'"
