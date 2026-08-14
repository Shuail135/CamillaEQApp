#!/bin/zsh
set -euo pipefail

TARGET="/Library/Audio/Plug-Ins/HAL/SystemAudioBridge.driver"

if [[ ! -d "$TARGET" ]]; then
    print "System Audio Bridge is not installed."
    exit 0
fi

print "Removing only $TARGET"
/usr/bin/sudo /bin/rm -rf "$TARGET"
/usr/bin/sudo /bin/launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || true
print "System Audio Bridge removed. Restart the Mac if it still appears in Sound settings."
