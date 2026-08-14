#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h}"
BUILD_ROOT="${SABR_BUILD_ROOT:-$REPO_ROOT/build/driver}"
PACKAGE_ROOT="$BUILD_ROOT/package-root"
SCRIPTS_ROOT="$BUILD_ROOT/package-scripts"
DRIVER="$BUILD_ROOT/SystemAudioBridge.driver"
PACKAGE="$BUILD_ROOT/SystemAudioBridge-${SABR_DRIVER_VERSION:-0.1.0}.pkg"

"$SCRIPT_DIR/build-driver.sh"

/bin/rm -rf "$PACKAGE_ROOT" "$SCRIPTS_ROOT"
/bin/mkdir -p "$PACKAGE_ROOT/Library/Audio/Plug-Ins/HAL" "$SCRIPTS_ROOT"
/usr/bin/ditto "$DRIVER" "$PACKAGE_ROOT/Library/Audio/Plug-Ins/HAL/SystemAudioBridge.driver"
/bin/cp "$SCRIPT_DIR/Installer/postinstall" "$SCRIPTS_ROOT/postinstall"
/bin/chmod 755 "$SCRIPTS_ROOT/postinstall"

/usr/bin/pkgbuild \
    --root "$PACKAGE_ROOT" \
    --scripts "$SCRIPTS_ROOT" \
    --identifier local.systemaudiobridge.driver.pkg \
    --version "${SABR_DRIVER_VERSION:-0.1.0}" \
    --install-location / \
    "$PACKAGE"

print "Built $PACKAGE"
