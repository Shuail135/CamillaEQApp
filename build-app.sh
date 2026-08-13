#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="CamillaEQApp"
APP_VERSION="0.1.1"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
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

# Build a true multi-resolution macOS icon. Constructing the ICNS container
# directly avoids iconutil failures seen with standalone Command Line Tools.
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for SIZE in 16 32 64 128 256 512 1024; do
    /usr/bin/sips -z "$SIZE" "$SIZE" "$ICON_SOURCE" \
        --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
done
/usr/bin/env LC_ALL=C /usr/bin/perl -e '
    binmode STDOUT;
    my @entries;
    while (@ARGV) {
        my $type = shift @ARGV;
        my $path = shift @ARGV;
        open my $fh, "<", $path or die "$path: $!";
        binmode $fh;
        local $/;
        my $data = <$fh>;
        close $fh;
        push @entries, $type . pack("N", length($data) + 8) . $data;
    }
    my $body = join("", @entries);
    print "icns", pack("N", length($body) + 8), $body;
' \
    icp4 "$ICONSET/icon_16x16.png" \
    icp5 "$ICONSET/icon_32x32.png" \
    icp6 "$ICONSET/icon_64x64.png" \
    ic07 "$ICONSET/icon_128x128.png" \
    ic08 "$ICONSET/icon_256x256.png" \
    ic09 "$ICONSET/icon_512x512.png" \
    ic10 "$ICONSET/icon_1024x1024.png" \
    > "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
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
