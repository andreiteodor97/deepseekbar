#!/bin/bash
#
# Compiles DeepSeekBar.app into build/.
#
#   ./build.sh            compile
#   ./build.sh --install  compile, then copy to ~/Applications
#
# The compiler is invoked directly rather than through an Xcode project: the app is a
# handful of Swift files with no dependencies, so a project file would only be
# something else to keep in sync.

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(cat "$DIR/VERSION" | tr -d '[:space:]')"
APP="$DIR/build/DeepSeekBar.app"
BUNDLE_ID="com.andreiteodor.deepseekbar"
ICONSET="$DIR/build/AppIcon.iconset"
ARCH="$(uname -m)"

echo "==> DeepSeekBar $VERSION ($ARCH)"

# The whale glyph is generated from the official logo, so regenerate it whenever the
# tracer or the source asset changes.
if [ ! -f "$DIR/Sources/WhaleGlyph.swift" ] || [ "$DIR/tools/trace_whale.py" -nt "$DIR/Sources/WhaleGlyph.swift" ]; then
    echo "==> Tracing whale logo"
    python3 "$DIR/tools/trace_whale.py"
fi

echo "==> Compiling $(ls "$DIR"/Sources/*.swift | wc -l | tr -d ' ') source files"
rm -rf "$APP" "$ICONSET"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# shellcheck disable=SC2046
swiftc \
    -O -whole-module-optimization \
    -framework AppKit -framework SwiftUI -framework WebKit -framework ServiceManagement \
    -o "$APP/Contents/MacOS/DeepSeekBar" \
    $(ls "$DIR"/Sources/*.swift)

echo "==> Rendering app icon"
mkdir -p "$ICONSET"
for name in icon_16x16 icon_16x16@2x icon_32x32 icon_32x32@2x \
            icon_128x128 icon_128x128@2x icon_256x256 \
            icon_256x256@2x icon_512x512 icon_512x512@2x; do
    : > "$ICONSET/$name.png"
done
swiftc -O -o "$DIR/build/gen-icon" "$DIR/tools/gen-icon.swift" "$DIR/Sources/WhaleGlyph.swift" "$DIR/Sources/Pricing.swift"
"$DIR/build/gen-icon" "$ICONSET" > /dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>DeepSeekBar</string>
    <key>CFBundleDisplayName</key>
    <string>DeepSeekBar</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>DeepSeekBar</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT licensed. DeepSeekBar is an unofficial client and is not affiliated with DeepSeek.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: gives the app a stable identity so macOS stops re-asking for
# permissions, and keeps the bundle valid for `spctl`-aware tooling.
if ! codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1; then
    echo "   note: ad-hoc codesign unavailable; the app still runs locally"
fi

echo "==> Built $(du -sh "$APP" | cut -f1) bundle at build/DeepSeekBar.app"

if [ "${1:-}" = "--install" ]; then
    echo "==> Installing to ~/Applications"
    pkill -f "DeepSeekBar.app/Contents/MacOS/DeepSeekBar" 2>/dev/null || true
    sleep 0.4
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/DeepSeekBar.app"
    cp -R "$APP" "$HOME/Applications/DeepSeekBar.app"
    echo "==> Launching"
    open "$HOME/Applications/DeepSeekBar.app"
fi
