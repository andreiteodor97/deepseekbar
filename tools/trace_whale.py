#!/usr/bin/env python3
"""Trace the official DeepSeek whale logo into a resolution-independent SwiftUI path.

Rasterising the logo would go mushy at the 16pt menu-bar size, so instead we pull the
silhouette out of the PNG, isolate the outline and the eye, smooth both, and emit a
single even-odd SwiftUI `Path` in a normalised 16x16 design space.

Run:  python3 tools/trace_whale.py
Reads:  tools/deepseek-logo.png   (the official asset, cropped to the whale)
Writes: Sources/WhaleGlyph.swift
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
LOGO = Path(__file__).resolve().parent / "deepseek-logo.png"
OUT = ROOT / "Sources" / "WhaleGlyph.swift"

VIEWBOX = 16.0
ALPHA_THRESHOLD = 128
SIMPLIFY_EPSILON = 0.022       # normalised units — tuned down until it looks identical
SMOOTH_PASSES = 4              # Chaikin corner-cutting passes
MIN_CONTOUR_AREA = 0.030       # normalised area²; drops specks from the trace


# ---------------------------------------------------------------- contour tracing

def load_alpha(path: Path) -> tuple[list[list[bool]], int, int]:
    img = Image.open(path).convert("RGBA")
    # The whale is the leftmost glyph in the lockup; the wordmark starts after a gap.
    w, h = img.size
    alpha = img.split()[3]
    cols = [any(alpha.getpixel((x, y)) > ALPHA_THRESHOLD for y in range(h)) for x in range(w)]

    runs: list[tuple[int, int]] = []
    start = None
    for x, occupied in enumerate(cols):
        if occupied and start is None:
            start = x
        elif not occupied and start is not None:
            runs.append((start, x - 1))
            start = None
    if start is not None:
        runs.append((start, w - 1))
    if not runs:
        raise SystemExit("no opaque pixels found in logo")

    x0, x1 = runs[0]

    # Tight vertical bounds within the whale's own columns. Scanning the whole width
    # would include the taller letters of the wordmark that follows it.
    rows = [any(alpha.getpixel((x, y)) > ALPHA_THRESHOLD for x in range(x0, x1 + 1)) for y in range(h)]
    ys = [y for y, occ in enumerate(rows) if occ]
    y0, y1 = ys[0], ys[-1]
    if (x1 - x0 + 1) / max(1, (y1 - y0 + 1)) > 3.0:
        raise SystemExit(
            f"trimmed region is {x1 - x0 + 1}x{y1 - y0 + 1} — that is the whole lockup, "
            "not the whale mark"
        )

    grid = [[alpha.getpixel((x0 + x, y0 + y)) > ALPHA_THRESHOLD for x in range(x1 - x0 + 1)]
            for y in range(y1 - y0 + 1)]
    return grid, x1 - x0 + 1, y1 - y0 + 1


NEIGHBOURS = [(-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0)]


def trace_all(grid: list[list[bool]], gw: int, gh: int) -> list[list[tuple[float, float]]]:
    """Moore-neighbour boundary tracing over the filled region, then over each hole."""
    padded = [[False] * (gw + 2)] + [[False] + row + [False] for row in grid] + [[False] * (gw + 2)]
    pw, ph = gw + 2, gh + 2

    def at(x: int, y: int) -> bool:
        return 0 <= x < pw and 0 <= y < ph and padded[y][x]

    filled = sum(1 for row in grid for v in row if v)
    if filled == 0:
        raise SystemExit("empty silhouette")

    # The silhouette plus every enclosed hole: each gets an outer boundary, and the
    # even-odd fill rule turns the holes into cut-outs (whale eye, belly detail).
    components = _components(padded, pw, ph)
    components.sort(key=len, reverse=True)
    if not components:
        raise SystemExit("no components")

    body = components[0]
    body_set = set(body)

    contours: list[list[tuple[float, float]]] = []
    for comp in components:
        hull = _outer_boundary(comp)
        if hull:
            contours.append(_douglas_peucker(hull, SIMPLIFY_EPSILON * VIEWBOX))

    # Holes inside the body: 8-connected background regions fully enclosed by the body.
    for hole in _holes(padded, pw, ph, body_set):
        hull = _outer_boundary(hole)
        if hull:
            contours.append(_douglas_peucker(hull, SIMPLIFY_EPSILON * VIEWBOX))

    # Drop specks, then normalise areas so the filter is resolution independent.
    span = float(max(gw, gh))
    keep = []
    for c in contours:
        if len(c) < 3:
            continue
        area = abs(_signed_area(c)) / (span * span)
        if area >= MIN_CONTOUR_AREA:
            keep.append(c)
    return keep


def _signed_area(points) -> float:
    total = 0.0
    n = len(points)
    for i in range(n):
        x0, y0 = points[i]
        x1, y1 = points[(i + 1) % n]
        total += x0 * y1 - x1 * y0
    return total / 2.0


def _components(padded, pw, ph) -> list[list[tuple[int, int]]]:
    """8-connected foreground components."""
    seen = [[False] * pw for _ in range(ph)]
    out: list[list[tuple[int, int]]] = []
    for y in range(ph):
        for x in range(pw):
            if not padded[y][x] or seen[y][x]:
                continue
            stack = [(x, y)]
            seen[y][x] = True
            comp: list[tuple[int, int]] = []
            while stack:
                cx, cy = stack.pop()
                comp.append((cx, cy))
                for dx, dy in NEIGHBOURS:
                    nx, ny = cx + dx, cy + dy
                    if 0 <= nx < pw and 0 <= ny < ph and padded[ny][nx] and not seen[ny][nx]:
                        seen[ny][nx] = True
                        stack.append((nx, ny))
            out.append(comp)
    return out


def _holes(padded, pw, ph, body_set: set[tuple[int, int]]) -> list[list[tuple[int, int]]]:
    """Background components not reachable from the border = enclosed holes."""
    seen = [[False] * pw for _ in range(ph)]
    stack = []
    for x in range(pw):
        for y in (0, ph - 1):
            if not padded[y][x]:
                stack.append((x, y))
                seen[y][x] = True
    for y in range(ph):
        for x in (0, pw - 1):
            if not padded[y][x] and not seen[y][x]:
                stack.append((x, y))
                seen[y][x] = True
    while stack:
        cx, cy = stack.pop()
        for dx, dy in NEIGHBOURS:
            nx, ny = cx + dx, cy + dy
            if 0 <= nx < pw and 0 <= ny < ph and not padded[ny][nx] and not seen[ny][nx]:
                seen[ny][nx] = True
                stack.append((nx, ny))

    holes: list[list[tuple[int, int]]] = []
    for y in range(ph):
        for x in range(pw):
            if padded[y][x] or seen[y][x]:
                continue
            # Flood this hole.
            comp: list[tuple[int, int]] = []
            st = [(x, y)]
            seen[y][x] = True
            while st:
                cx, cy = st.pop()
                comp.append((cx, cy))
                for dx, dy in NEIGHBOURS:
                    nx, ny = cx + dx, cy + dy
                    if 0 <= nx < pw and 0 <= ny < ph and not padded[ny][nx] and not seen[ny][nx]:
                        seen[ny][nx] = True
                        st.append((nx, ny))
            if len(comp) >= 3:
                holes.append(comp)
    return holes


def _outer_boundary(cells: list[tuple[int, int]]) -> list[tuple[float, float]]:
    """Moore-neighbour tracing around a set of cells, in cell-centre coordinates."""
    cellset = set(cells)
    start = min(cells, key=lambda c: (c[1], c[0]))  # topmost, then leftmost
    boundary: list[tuple[int, int]] = []
    # Clockwise neighbour order starting from "west".
    order = [(-1, 0), (-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1)]
    current = start
    backtrack = (start[0] - 1, start[1])
    for _ in range(8 * len(cells) + 16):
        boundary.append(current)
        start_index = order.index((backtrack[0] - current[0], backtrack[1] - current[1])) if \
            (backtrack[0] - current[0], backtrack[1] - current[1]) in order else 0
        found = False
        for k in range(1, 9):
            idx = (start_index + k) % 8
            dx, dy = order[idx]
            cand = (current[0] + dx, current[1] + dy)
            if cand in cellset:
                backtrack = (current[0] + order[(idx - 1) % 8][0], current[1] + order[(idx - 1) % 8][1])
                current = cand
                found = True
                break
        if not found:
            break
        if current == start and len(boundary) > 2:
            break
    return [(float(x), float(y)) for x, y in boundary]


# ---------------------------------------------------------------- geometry clean-up

def _douglas_peucker(points: list[tuple[float, float]], eps: float) -> list[tuple[float, float]]:
    if len(points) < 3:
        return points

    def perp(p, a, b) -> float:
        if a == b:
            return math.hypot(p[0] - a[0], p[1] - a[1])
        num = abs((b[0] - a[0]) * (a[1] - p[1]) - (a[0] - p[0]) * (b[1] - a[1]))
        return num / math.hypot(b[0] - a[0], b[1] - a[1])

    dmax, index = 0.0, 0
    for i in range(1, len(points) - 1):
        d = perp(points[i], points[0], points[-1])
        if d > dmax:
            dmax, index = d, i
    if dmax > eps:
        left = _douglas_peucker(points[:index + 1], eps)
        right = _douglas_peucker(points[index:], eps)
        return left[:-1] + right
    return [points[0], points[-1]]


def _chaikin(points: list[tuple[float, float]], passes: int) -> list[tuple[float, float]]:
    pts = points
    for _ in range(passes):
        out: list[tuple[float, float]] = []
        n = len(pts)
        for i in range(n):
            x0, y0 = pts[i]
            x1, y1 = pts[(i + 1) % n]
            out.append((0.75 * x0 + 0.25 * x1, 0.75 * y0 + 0.25 * y1))
            out.append((0.25 * x0 + 0.75 * x1, 0.25 * y0 + 0.75 * y1))
        pts = out
    return pts


def normalise(contours, gw: int, gh: int):
    """Fit into the 16x16 viewBox preserving aspect ratio, centred."""
    xs = [p[0] for c in contours for p in c]
    ys = [p[1] for c in contours for p in c]
    minx, maxx, miny, maxy = min(xs), max(xs), min(ys), max(ys)
    w = max(maxx - minx, 1e-6)
    h = max(maxy - miny, 1e-6)
    scale = VIEWBOX / max(w, h)
    offx = (VIEWBOX - w * scale) / 2.0
    offy = (VIEWBOX - h * scale) / 2.0
    return [[(round((x - minx) * scale + offx, 3), round((y - miny) * scale + offy, 3)) for x, y in c]
            for c in contours]


# ---------------------------------------------------------------- code emission

def emit(contours) -> str:
    lines: list[str] = []
    for contour in contours:
        pts = _chaikin(contour, SMOOTH_PASSES)
        n = len(pts)
        if n < 3:
            continue
        lines.append(f"        path.move(to: p({pts[0][0]}, {pts[0][1]}))")
        for i in range(1, n):
            x1, y1 = pts[i]
            x2, y2 = pts[(i + 1) % n]
            mx, my = (x1 + x2) / 2.0, (y1 + y2) / 2.0
            lines.append(f"        path.addQuadCurve(to: p({round(mx, 3)}, {round(my, 3)}), "
                         f"control: p({x1}, {y1}))")
        # Close back onto the start point.
        lines.append("        path.closeSubpath()")
        lines.append("")
    return "\n".join(lines).rstrip()


HEADER = '''import SwiftUI

// GENERATED FILE — do not edit by hand.
// Produced by tools/trace_whale.py from tools/deepseek-logo.png (the official mark).
//
// The whale is traced as real vector contours rather than a downscaled bitmap: a
// bitmap turns to mush at the 16pt menu-bar size, while these paths stay crisp at
// any scale and tint themselves like a native template image. The eye is a separate
// subpath, so the even-odd fill rule turns it into a cut-out.

/// The DeepSeek whale, as a resolution-independent shape.
struct WhaleGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / @@VIEWBOX@@
        let sy = rect.height / @@VIEWBOX@@
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        var path = Path()

@@BODY@@

        return path
    }
}

/// The whale, tintable and template-like.
struct WhaleMark: View {
    var size: CGFloat = 16
    var color: Color = .primary

    var body: some View {
        WhaleGlyphShape()
            .fill(color, style: FillStyle(eoFill: true))
            .frame(width: size, height: size)
            .accessibilityLabel("DeepSeek")
    }
}

/// The whale reversed out of a rounded brand tile.
struct WhaleTile: View {
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(
                LinearGradient(colors: [Color(hex: 0x6E86FF), Color(hex: 0x3D5AFE)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .overlay(WhaleMark(size: size * 0.68, color: .white).offset(y: size * 0.01))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .frame(width: size, height: size)
            .shadow(color: Color(hex: 0x3D5AFE).opacity(0.35), radius: size * 0.14, y: size * 0.06)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Palette

enum Palette {
    static let brand = Color(hex: 0x4D6BFE)
    static let peak = Color(hex: 0xFF9F0A)
    static let cheap = Color(hex: 0x32D74B)
    static let warning = Color(hex: 0xFF453A)

    static func mode(_ m: PricingMode) -> Color { m == .peak ? peak : cheap }

    static let cardStroke = Color.primary.opacity(0.07)
    static let cardFill = Color.primary.opacity(0.045)
}
'''


def main() -> int:
    if not LOGO.exists():
        print(f"missing logo asset: {LOGO}", file=sys.stderr)
        return 1
    grid, gw, gh = load_alpha(LOGO)
    contours = trace_all(grid, gw, gh)
    contours = [c for c in contours if len(c) >= 3]
    contours.sort(key=len, reverse=True)
    contours = normalise(contours, gw, gh)
    body = emit(contours)
    source = (HEADER
              .replace("@@VIEWBOX@@", f"{VIEWBOX:.1f}")
              .replace("@@BODY@@", body))
    OUT.write_text(source)
    print(f"traced {len(contours)} contour(s) from {gw}x{gh} source -> {OUT}")
    for i, c in enumerate(contours):
        print(f"  contour {i}: {len(c)} points after simplify")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
