#!/bin/sh
# Build SpeedyFan.app from the Swift package.
set -e
cd "$(dirname "$0")"

# The bare Command Line Tools lack the SwiftUI macro plugins; prefer Xcode.
if [ -z "$DEVELOPER_DIR" ]; then
    for x in /Applications/Xcode.app /Applications/Xcode-beta.app; do
        if [ -d "$x" ]; then
            export DEVELOPER_DIR="$x/Contents/Developer"
            break
        fi
    done
fi

swift build -c release
BIN=$(swift build -c release --show-bin-path)

APP=SpeedyFan.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SpeedyFan" "$APP/Contents/MacOS/SpeedyFan"
cp "$BIN/fanctl" "$APP/Contents/Resources/fanctl"
cp Info.plist "$APP/Contents/Info.plist"

# App icon: regenerate with `swift tools/make-icon.swift` + iconutil if missing.
if [ ! -f AppIcon.icns ]; then
    swift tools/make-icon.swift
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
fi
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Built $APP — launch with: open $APP"
