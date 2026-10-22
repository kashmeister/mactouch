#!/bin/bash
# Compile build/MacTouch.app and sign it ad hoc.
#   ./build.sh                    for this Mac's architecture
#   ./build.sh --arch=x86_64      for Intel Macs (or arm64; universal for both, at twice the size)
set -euo pipefail
cd "$(dirname "$0")"
APP=build/MacTouch.app
MIN_MACOS=13.0
ARCH=$(uname -m)
for a in "$@"; do
    case "$a" in
        --arch=*) ARCH=${a#--arch=} ;;
        *) echo "usage: ./build.sh [--arch=arm64|x86_64|universal]" >&2; exit 2 ;;
    esac
done
case "$ARCH" in
    arm64 | x86_64) ARCHS=$ARCH ;;
    universal) ARCHS="arm64 x86_64" ;;
    *) echo "unknown architecture $ARCH: use arm64, x86_64 or universal" >&2; exit 2 ;;
esac
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchAgents"
SLICES=()
for a in $ARCHS; do
    swiftc -O -swift-version 5 -target "$a-apple-macos$MIN_MACOS" -o "build/MacTouch-$a" Sources/*.swift
    SLICES+=("build/MacTouch-$a")
done
lipo -create -output "$APP/Contents/MacOS/MacTouch" "${SLICES[@]}"
rm -f "${SLICES[@]}"
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
    <string>3.3.0</string>
    <key>CFBundleVersion</key>
    <string>3.3.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_MACOS</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST
# The launch agent behind Start at Login in the menu (registered with SMAppService; see
# Sources/LoginItem.swift). install.sh and Homebrew start MacTouch with agents of their own.
cat > "$APP/Contents/Library/LaunchAgents/local.mactouch.agent.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.mactouch.agent</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/MacTouch</string>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>local.mactouch</string>
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
</dict>
</plist>
PLIST
# An identifier-based designated requirement (instead of the default per-build cdhash) keeps the
# Input Monitoring and Accessibility grants valid across rebuilds.
codesign --force --sign - --identifier local.mactouch \
    --requirements '=designated => identifier "local.mactouch"' "$APP"
echo "built $APP ($ARCH)"
