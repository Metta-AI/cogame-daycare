#!/usr/bin/env python3
"""Key, split and pad the nano-banana cog sheet into the two role kits.

Input:  scripts/art/source/cogs_sheet.png -- one `gemini-2.5-flash-image`
        ("nano-banana") render of THREE Softmax cogs on a flat #00FF00 backdrop:
        LEFT the PARENT (tall, blue, wicker fruit basket), MIDDLE the CHILD
        (small, yellow), RIGHT the CHILD REACHING (same cog, both arms overhead).
        The prompt and the reference part are recorded in scripts/art/README.md.

Output: data/cog_parent_front.png, data/cog_child_front.png,
        data/cog_child_reach.png -- transparent, trimmed, padded square PNGs.

Gemini returns no alpha and the "pure green" comes back as *some* green with a
tinted edge, so the backdrop colour is the MEDIAN of the border (corners
sometimes carry a smudge) and the key is a flood fill from the border, which is
what keeps green pixels INSIDE a character alive.

Run:  python3 scripts/art/split_cog_sheet.py
"""

from __future__ import annotations

import pathlib
import statistics
import sys
from collections import deque

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[2]
SHEET = ROOT / "scripts" / "art" / "source" / "cogs_sheet.png"
OUT_DIR = ROOT / "data"
# Left to right in the sheet.
PARTS = ["cog_parent_front", "cog_child_front", "cog_child_reach"]
# One canvas size for every kit so the renderer can scale by role, not by file.
CANVAS = 128
TOLERANCE = 60


def border_colour(image: Image.Image) -> tuple[int, int, int]:
    w, h = image.size
    px = image.load()
    samples = []
    for x in range(0, w, max(1, w // 64)):
        samples.append(px[x, 0])
        samples.append(px[x, h - 1])
    for y in range(0, h, max(1, h // 64)):
        samples.append(px[0, y])
        samples.append(px[w - 1, y])
    return tuple(
        int(statistics.median([s[i] for s in samples])) for i in range(3)
    )


def key_backdrop(image: Image.Image) -> Image.Image:
    """Flood-fill the backdrop from every border pixel and make it transparent."""
    rgba = image.convert("RGBA")
    w, h = rgba.size
    px = rgba.load()
    key = border_colour(image)

    def matches(c) -> bool:
        return (
            abs(c[0] - key[0]) <= TOLERANCE
            and abs(c[1] - key[1]) <= TOLERANCE
            and abs(c[2] - key[2]) <= TOLERANCE
        )

    seen = bytearray(w * h)
    queue: deque[tuple[int, int]] = deque()
    for x in range(w):
        for y in (0, h - 1):
            if matches(px[x, y]):
                queue.append((x, y))
                seen[y * w + x] = 1
    for y in range(h):
        for x in (0, w - 1):
            if matches(px[x, y]):
                queue.append((x, y))
                seen[y * w + x] = 1
    while queue:
        x, y = queue.popleft()
        px[x, y] = (0, 0, 0, 0)
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h and not seen[ny * w + nx]:
                if matches(px[nx, ny]):
                    seen[ny * w + nx] = 1
                    queue.append((nx, ny))
    return rgba


def columns_with_ink(image: Image.Image) -> list[bool]:
    w, h = image.size
    px = image.load()
    out = []
    for x in range(w):
        ink = False
        for y in range(h):
            if px[x, y][3] > 24:
                ink = True
                break
        out.append(ink)
    return out


def split_row(image: Image.Image, count: int) -> list[Image.Image]:
    ink = columns_with_ink(image)
    spans: list[tuple[int, int]] = []
    start = None
    for x, has in enumerate(ink):
        if has and start is None:
            start = x
        elif not has and start is not None:
            spans.append((start, x))
            start = None
    if start is not None:
        spans.append((start, len(ink)))
    # Merge the thin gaps a raised arm can open inside one character.
    merged: list[list[int]] = []
    for a, b in spans:
        if merged and a - merged[-1][1] < image.size[0] // 40:
            merged[-1][1] = b
        else:
            merged.append([a, b])
    if len(merged) != count:
        # Keep the `count` widest spans, left to right.
        merged.sort(key=lambda s: s[1] - s[0], reverse=True)
        merged = sorted(merged[:count], key=lambda s: s[0])
    if len(merged) != count:
        raise SystemExit(f"found {len(merged)} characters in the sheet, want {count}")
    return [image.crop((a, 0, b, image.size[1])) for a, b in merged]


def pad_square(image: Image.Image, size: int) -> Image.Image:
    box = image.getbbox()
    if box:
        image = image.crop(box)
    w, h = image.size
    side = max(w, h)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    # Bottom-anchored: the renderer plants a cog on its feet.
    canvas.paste(image, ((side - w) // 2, side - h))
    return canvas.resize((size, size), Image.LANCZOS)


def main() -> int:
    if not SHEET.exists():
        raise SystemExit(f"missing sheet: {SHEET}")
    sheet = Image.open(SHEET)
    keyed = key_backdrop(sheet)
    parts = split_row(keyed, len(PARTS))
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for name, part in zip(PARTS, parts):
        out = OUT_DIR / f"{name}.png"
        pad_square(part, CANVAS).save(out)
        print(f"wrote {out.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
