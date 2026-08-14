#!/bin/zsh
set -euo pipefail

TARGETS=(
    /Library/Audio/Plug-Ins/HAL/CamillaAudio.driver
    /Library/Audio/Plug-Ins/HAL/CamillaEQAudio.driver
    /Library/Audio/Plug-Ins/HAL/CamillaAudioBridge.driver
    /Library/Audio/Plug-Ins/HAL/SystemAudioBridge.driver
)

# Let CamiTune restore the physical output and destroy its temporary profile
# selectors before the HAL bundle disappears.
/usr/bin/osascript -e 'tell application id "local.camilla.app" to quit' 2>/dev/null || true
/bin/sleep 1

installed_targets=()
for target in "${TARGETS[@]}"; do
    [[ -d "$target" ]] && installed_targets+=("$target")
done

if (( ${#installed_targets[@]} == 0 )); then
    print "System Audio Bridge is not installed."
    exit 0
fi

print "Removing Camilla Audio driver bundles"
/usr/bin/sudo /bin/rm -rf "${installed_targets[@]}"
/usr/bin/sudo /bin/launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || true
print "Camilla Audio driver removed. Restart the Mac if an audio device still appears in Sound settings."
