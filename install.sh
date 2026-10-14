#!/bin/bash
# Build touchbridge and install it as a per-user launch agent.
#   ./install.sh [options]   options are passed to the agent; see the header of touchbridge.swift
#   e.g. ./install.sh --one-finger-scroll --drag-apps=AssistiveControl,eqMac
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL=local.touchbridge
BIN="$DIR/bin/touchbridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/touchbridge.log"

"$DIR/build.sh"
"$BIN" "$@" --check >/dev/null || { echo "invalid options: $*" >&2; exit 2; }

ARGS="        <string>$BIN</string>"
for a in "$@"; do
    a="${a//&/&amp;}"; a="${a//</&lt;}"; a="${a//>/&gt;}"
    ARGS="$ARGS
        <string>$a</string>"
done

mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
$ARGS
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
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

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $LABEL; log: $LOG"
cat <<MSG

Grant both permissions in System Settings > Privacy & Security:
  Input Monitoring  the agent restarts itself once it is granted
  Accessibility     applied to the running agent within 2 s
If touchbridge is not listed, add $BIN with the + button.
MSG
