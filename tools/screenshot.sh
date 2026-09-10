#!/bin/bash
#
# Renders docs/panel.png from the real PanelView with sample data.
#
#   ./tools/screenshot.sh [output.png]
#
# Done offscreen rather than with `screencapture` so the image is reproducible and does
# not depend on whatever happens to be behind the window.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$DIR/docs/panel.png}"
BIN="$(mktemp -d)/screenshot"

swiftc -O -o "$BIN" \
    "$DIR/tools/screenshot/main.swift" \
    $(ls "$DIR"/Sources/*.swift | grep -v "Sources/Main.swift")

"$BIN" "$OUT"
