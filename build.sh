#!/bin/bash
# Compile build/MacTouch.app and sign it ad hoc.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/MacTouch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/MacTouch" MacTouch.swift
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>local.mactouch</string>
    <key>CFBundleName</key>
    <string>MacTouch</string>
    <key>CFBundleExecutable</key>
    <string>MacTouch</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>3.0.3</string>
    <key>CFBundleVersion</key>
    <string>3.0.3</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST
# An identifier-based designated requirement (instead of the default per-build cdhash) keeps the
# Input Monitoring and Accessibility grants valid across rebuilds.
codesign --force --sign - --identifier local.mactouch \
    --requirements '=designated => identifier "local.mactouch"' "$APP"
echo "built $APP"
