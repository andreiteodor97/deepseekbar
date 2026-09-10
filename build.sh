#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/DeepSeekBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/DeepSeekBar" "$DIR/src/main.swift"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>DeepSeekBar</string>
    <key>CFBundleIdentifier</key>
    <string>local.deepseekbar</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>DeepSeekBar</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/DeepSeekBar.app"
cp -R "$APP" "$HOME/Applications/DeepSeekBar.app"
echo "Built and installed to ~/Applications/DeepSeekBar.app"
