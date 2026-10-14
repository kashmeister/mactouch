#!/bin/bash
# Build MacTouch, copy it to ~/Applications and run it at login as a per-user launch agent.
#   ./install.sh [options]   options are saved as settings; see the header of MacTouch.swift
#   e.g. ./install.sh --one-finger-scroll --drag-apps=AssistiveControl,eqMac
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL=local.mactouch
APP="$HOME/Applications/MacTouch.app"
BIN="$APP/Contents/MacOS/MacTouch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/MacTouch.log"

"$DIR/build.sh"
"$DIR/build/MacTouch.app/Contents/MacOS/MacTouch" "$@" --check >/dev/null || { echo "invalid options: $*" >&2; exit 2; }

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# Earlier versions ran as local.touchbridge.
if launchctl bootout "gui/$(id -u)/local.touchbridge" 2>/dev/null; then echo "stopped old local.touchbridge"; fi
rm -f "$HOME/Library/LaunchAgents/local.touchbridge.plist"

mkdir -p "$HOME/Applications" "$(dirname "$PLIST")" "$(dirname "$LOG")"
rm -rf "$APP"
ditto "$DIR/build/MacTouch.app" "$APP"
if [ $# -gt 0 ]; then "$BIN" --save "$@"; fi

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
PLIST
plutil -lint -s "$PLIST"
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $APP as $LABEL; log: $LOG"
cat <<MSG

Grant both permissions in System Settings > Privacy & Security:
  Input Monitoring  picked up within about 25 s (MacTouch restarts until it is granted)
  Accessibility     applied to the running app within 2 s
If MacTouch is not listed, add $APP with the + button.
MSG
