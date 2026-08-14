#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h}"
OUTPUT="${TMPDIR:-/tmp}/SystemAudioBridge-transport-tests"
PROPERTY_OUTPUT="${TMPDIR:-/tmp}/SystemAudioBridge-property-tests"
CLANG="$(/usr/bin/xcrun --sdk macosx --find clang)"
SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"

"$CLANG" \
    -std=gnu11 \
    -Wall -Wextra -Werror \
    -isysroot "$SDK" \
    -mmacosx-version-min=13.0 \
    -I "$REPO_ROOT/Sources/SystemAudioBridgeC/include" \
    "$REPO_ROOT/Tests/DriverTransportTests/transport_test.c" \
    "$SCRIPT_DIR/Driver/SystemAudioBridgeDriverTransport.c" \
    -framework CoreAudio \
    -framework CoreFoundation \
    -o "$OUTPUT"

"$OUTPUT"

"$CLANG" \
    -std=gnu11 \
    -DkDevice_IsHidden=true \
    -isysroot "$SDK" \
    -mmacosx-version-min=13.0 \
    "$REPO_ROOT/Tests/DriverTransportTests/driver_property_test.c" \
    "$SCRIPT_DIR/Driver/SystemAudioBridge.c" \
    "$SCRIPT_DIR/Driver/SystemAudioBridgeDriverTransport.c" \
    -framework Accelerate \
    -framework CoreAudio \
    -framework CoreFoundation \
    -o "$PROPERTY_OUTPUT"

"$PROPERTY_OUTPUT"
