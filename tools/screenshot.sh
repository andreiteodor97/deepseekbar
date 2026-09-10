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

# Round the outer corners so the images read as macOS panels rather than rectangles.
python3 - "$OUT" <<'PY'
import sys
from pathlib import Path
from PIL import Image, ImageDraw

for path in sorted(Path(sys.argv[1]).glob("panel*.png")):
    image = Image.open(path).convert("RGBA")
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, image.width - 1, image.height - 1], radius=28, fill=255)
    rounded = Image.new("RGBA", image.size, (0, 0, 0, 0))
    rounded.paste(image, (0, 0), mask)
    rounded.save(path)
PY
