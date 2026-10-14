#!/bin/bash
# Stop and remove MacTouch and its launch agent. Settings, source tree and log are left in place.
set -euo pipefail
LABEL=local.mactouch
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "stopped $LABEL" || true
rm -f "$PLIST"
rm -rf "$HOME/Applications/MacTouch.app"
echo "removed $PLIST and ~/Applications/MacTouch.app"
echo "Settings remain in the defaults domain local.mactouch; 'defaults delete local.mactouch' removes them."
echo "Remove the MacTouch entries under System Settings > Privacy & Security >"
echo "Accessibility and Input Monitoring by hand; macOS offers no command for unbundled apps."
