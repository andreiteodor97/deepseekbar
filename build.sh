#!/bin/bash
#
# Builds DeepSeekBar.app and installs it to ~/Applications.
#
#   ./build.sh          build + install (does not restart a running copy)
#   ./build.sh --run    build + install + relaunch
#
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/DeepSeekBar.app"
SOURCES=("$DIR"/Sources/*.swift)
ICONSET="$DIR/build/AppIcon.iconset"

echo "==> Compiling ${#SOURCES[@]} source files"
rm -rf "$APP" "$ICONSET"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The whale glyph is generated from the official logo; regenerate it when the tracer
# or the source asset is newer.
if [ ! -f "$DIR/Sources/WhaleGlyph.swift" ] || [ "$DIR/tools/trace_whale.py" -nt "$DIR/Sources/WhaleGlyph.swift" ]; then
    echo "==> Tracing whale logo"
    python3 "$DIR/tools/trace_whale.py"
fi

swiftc \
    -O -whole-module-optimization \
    -framework AppKit -framework SwiftUI -framework ServiceManagement \
    -o "$APP/Contents/MacOS/DeepSeekBar" \
    "${SOURCES[@]}"

echo "==> Rendering app icon"
mkdir -p "$ICONSET"
for name in icon_16x16 icon_16x16@2x icon_32x32 icon_32x32@2x \
            icon_128x128 icon_128x128@2x icon_256x256 \
            icon_256x256@2x icon_512x512 icon_512x512@2x; do
    : > "$ICONSET/$name.png"
done
swiftc -O -o "$DIR/build/gen-icon" "$DIR/tools/gen-icon.swift" "$DIR/Sources/WhaleGlyph.swift" "$DIR/Sources/Pricing.swift"
"$DIR/build/gen-icon" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>DeepSeekBar</string>
    <key>CFBundleDisplayName</key>
    <string>DeepSeekBar</string>
    <key>CFBundleIdentifier</key>
    <string>local.deepseekbar</string>
    <key>CFBundleExecutable</key>
    <string>DeepSeekBar</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>2.0</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: gives the app a stable identity so keychain access does not
# re-prompt on every rebuild.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "   (codesign unavailable; continuing)"

echo "==> Installing to ~/Applications"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/DeepSeekBar.app"
cp -R "$APP" "$HOME/Applications/DeepSeekBar.app"

if [ "${1:-}" = "--run" ]; then
    echo "==> Relaunching"
    pkill -f "DeepSeekBar.app/Contents/MacOS/DeepSeekBar" 2>/dev/null || true
    sleep 0.5
    open "$HOME/Applications/DeepSeekBar.app"
fi

echo "Done: ~/Applications/DeepSeekBar.app"
