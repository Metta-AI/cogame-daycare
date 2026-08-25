#!/usr/bin/env python3
"""Deterministic yard art for Daycare (Pillow, committed output).

Renders everything the board needs EXCEPT the two character kits: the cog
bodies (`data/cog_parent_front.png`, `data/cog_child_front.png`,
`data/cog_child_reach.png`) are nano-banana renders of the Softmax cog and are
owned by `scripts/art/split_cog_sheet.py`. This script no longer owns those
three files; it only composites the `_carry_apple` / `_carry_banana` variants on
top of them, and it needs them to exist first.

Everything here is a pure function of the constants below -- no RNG, no time,
no network -- so `git diff` after a re-run is empty unless the art changed.

Run:  python3 scripts/art/split_cog_sheet.py && python3 scripts/art/gen_daycare_art.py
"""

from __future__ import annotations

import math
import pathlib
import sys

from PIL import Image, ImageDraw, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parents[2]
DATA = ROOT / "data"
LOCKER = ROOT / "client" / "art" / "lockerroom"

CELL = 48
TREE_H = 77          # 1.6 cells: "too tall" has to be legible at a glance
SHRUB_H = 34         # knee-high
FRUIT = 20

GRASS_A = (104, 158, 74)
GRASS_B = (95, 148, 68)
GRASS_C = (118, 172, 84)
PATH_A = (176, 154, 112)
PATH_B = (162, 140, 100)
FENCE_WOOD = (140, 100, 62)
FENCE_DARK = (104, 72, 44)
FENCE_LIGHT = (172, 130, 86)
MAT_A = (198, 168, 112)
MAT_B = (168, 138, 88)
TRUNK = (112, 78, 50)
TRUNK_DARK = (84, 56, 34)
CANOPY = (58, 118, 60)
CANOPY_LIGHT = (78, 146, 74)
CANOPY_DARK = (40, 92, 46)
SHRUB_GREEN = (86, 138, 72)
SHRUB_DARK = (60, 104, 54)
APPLE = (206, 62, 54)
APPLE_DARK = (156, 40, 36)
BANANA = (226, 190, 66)
BANANA_DARK = (176, 142, 40)
INK = (30, 24, 18)
PUFF = (188, 186, 180)
SPARK = (255, 240, 168)


def new(w: int, h: int) -> Image.Image:
    return Image.new("RGBA", (w, h), (0, 0, 0, 0))


# ---------------------------------------------------------------------------
# floor, fence, mat
# ---------------------------------------------------------------------------

def grass_tile() -> Image.Image:
    img = Image.new("RGBA", (CELL, CELL), GRASS_A + (255,))
    d = ImageDraw.Draw(img)
    # A fixed hash pattern: the same tile every run, no RNG.
    for y in range(CELL):
        for x in range(CELL):
            h = (x * 7 + y * 13 + ((x * y) % 11)) % 17
            if h == 0:
                d.point((x, y), GRASS_B + (255,))
            elif h == 5:
                d.point((x, y), GRASS_C + (255,))
    for i in range(6):
        bx = 4 + (i * 9) % (CELL - 8)
        by = 6 + (i * 17) % (CELL - 10)
        d.line([(bx, by + 5), (bx + 1, by)], fill=GRASS_C + (255,))
        d.line([(bx + 3, by + 5), (bx + 2, by + 1)], fill=GRASS_B + (255,))
    return img


def path_tile() -> Image.Image:
    img = Image.new("RGBA", (CELL, CELL), PATH_A + (255,))
    d = ImageDraw.Draw(img)
    for y in range(CELL):
        for x in range(CELL):
            if (x * 5 + y * 3) % 13 == 0:
                d.point((x, y), PATH_B + (255,))
    return img


def fence_tile(vertical: bool) -> Image.Image:
    img = grass_tile()
    d = ImageDraw.Draw(img)
    if vertical:
        d.rectangle([CELL // 2 - 5, 0, CELL // 2 + 4, CELL - 1], fill=FENCE_WOOD + (255,))
        d.rectangle([CELL // 2 - 5, 0, CELL // 2 - 3, CELL - 1], fill=FENCE_LIGHT + (255,))
        d.rectangle([CELL // 2 + 2, 0, CELL // 2 + 4, CELL - 1], fill=FENCE_DARK + (255,))
        for y in (10, 34):
            d.rectangle([CELL // 2 - 9, y, CELL // 2 + 8, y + 5], fill=FENCE_WOOD + (255,))
            d.line([(CELL // 2 - 9, y), (CELL // 2 + 8, y)], fill=FENCE_LIGHT + (255,))
    else:
        d.rectangle([0, CELL // 2 - 5, CELL - 1, CELL // 2 + 4], fill=FENCE_WOOD + (255,))
        d.rectangle([0, CELL // 2 - 5, CELL - 1, CELL // 2 - 3], fill=FENCE_LIGHT + (255,))
        d.rectangle([0, CELL // 2 + 2, CELL - 1, CELL // 2 + 4], fill=FENCE_DARK + (255,))
        for x in (10, 34):
            d.rectangle([x, CELL // 2 - 9, x + 5, CELL // 2 + 8], fill=FENCE_WOOD + (255,))
            d.line([(x, CELL // 2 - 9), (x, CELL // 2 + 8)], fill=FENCE_LIGHT + (255,))
    return img


def fence_corner() -> Image.Image:
    img = grass_tile()
    d = ImageDraw.Draw(img)
    d.rectangle([CELL // 2 - 6, CELL // 2 - 6, CELL // 2 + 5, CELL // 2 + 5],
                fill=FENCE_WOOD + (255,))
    d.rectangle([CELL // 2 - 6, CELL // 2 - 6, CELL // 2 + 5, CELL // 2 - 4],
                fill=FENCE_LIGHT + (255,))
    d.rectangle([0, CELL // 2 - 5, CELL - 1, CELL // 2 + 4], fill=FENCE_WOOD + (255,))
    d.rectangle([CELL // 2 - 5, 0, CELL // 2 + 4, CELL - 1], fill=FENCE_WOOD + (255,))
    return img


def mat_tile() -> Image.Image:
    """The basket mat: a woven mat the fruit rests on. Mat fruit never rots."""
    img = grass_tile()
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([2, 6, CELL - 3, CELL - 3], radius=5, fill=MAT_A + (255,),
                        outline=INK + (110,))
    for i in range(4, CELL - 4, 6):
        d.line([(3, 7 + i * 0), (CELL - 4, 7)], fill=MAT_B + (255,))
    for y in range(9, CELL - 4, 5):
        d.line([(3, y), (CELL - 4, y)], fill=MAT_B + (255,))
    for x in range(5, CELL - 4, 5):
        d.line([(x, 7), (x, CELL - 4)], fill=MAT_B + (160,))
    return img


# ---------------------------------------------------------------------------
# fruit: readable by SHAPE, not only colour (round vs crescent), so the guess
# stays legible in greyscale
# ---------------------------------------------------------------------------

def apple_sprite(size: int = FRUIT) -> Image.Image:
    img = new(size, size)
    d = ImageDraw.Draw(img)
    r = size * 0.40
    cx, cy = size / 2, size * 0.58
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=APPLE + (255,), outline=INK + (200,))
    d.ellipse([cx - r * 0.55, cy - r * 0.75, cx - r * 0.05, cy - r * 0.25],
              fill=(240, 140, 130, 190))
    d.line([(cx, cy - r), (cx + 1, size * 0.10)], fill=TRUNK_DARK + (255,), width=2)
    d.polygon([(cx + 1, size * 0.16), (cx + r, size * 0.06), (cx + r * 0.5, size * 0.26)],
              fill=CANOPY + (255,))
    return img


def banana_sprite(size: int = FRUIT) -> Image.Image:
    img = new(size, size)
    d = ImageDraw.Draw(img)
    outer = []
    inner = []
    for step in range(19):
        t = math.pi * (0.15 + 0.70 * step / 18)
        rx, ry = size * 0.42, size * 0.42
        cx, cy = size / 2, size * 0.72
        outer.append((cx + rx * math.cos(t), cy - ry * math.sin(t)))
        inner.append((cx + rx * 0.62 * math.cos(t), cy - ry * 0.62 * math.sin(t)))
    d.polygon(outer + inner[::-1], fill=BANANA + (255,), outline=INK + (200,))
    d.line(outer[2:16], fill=BANANA_DARK + (200,), width=1)
    return img


def fruit_sprite(species: str, size: int = FRUIT) -> Image.Image:
    return apple_sprite(size) if species == "apple" else banana_sprite(size)


# ---------------------------------------------------------------------------
# sources
# ---------------------------------------------------------------------------

def tall_tree(species: str, ripe: int) -> Image.Image:
    """Drawn 1.6 cells high so "too tall for the child" reads at a glance, with
    a small ripe-fruit cluster in the canopy that doubles as the count pip."""
    img = new(CELL, TREE_H)
    d = ImageDraw.Draw(img)
    base = TREE_H - 2
    d.rectangle([CELL // 2 - 5, base - 26, CELL // 2 + 4, base], fill=TRUNK + (255,))
    d.rectangle([CELL // 2 + 2, base - 26, CELL // 2 + 4, base], fill=TRUNK_DARK + (255,))
    d.line([(CELL // 2 - 4, base - 18), (CELL // 2 - 12, base - 28)],
           fill=TRUNK + (255,), width=3)
    d.line([(CELL // 2 + 4, base - 20), (CELL // 2 + 13, base - 30)],
           fill=TRUNK + (255,), width=3)
    top = base - 26
    d.ellipse([2, top - 40, CELL - 3, top + 8], fill=CANOPY + (255,))
    d.ellipse([6, top - 44, CELL - 12, top - 6], fill=CANOPY_LIGHT + (255,))
    d.ellipse([12, top - 22, CELL - 4, top + 6], fill=CANOPY_DARK + (200,))
    spots = [(CELL // 2 - 10, top - 16), (CELL // 2 + 6, top - 24),
             (CELL // 2 - 1, top - 4)]
    for i in range(min(3, max(0, ripe))):
        f = fruit_sprite(species, 15)
        img.alpha_composite(f, (spots[i][0], spots[i][1]))
    # ground shadow so the trunk sits on the grass instead of floating
    shadow = new(CELL, TREE_H)
    ImageDraw.Draw(shadow).ellipse([CELL // 2 - 14, base - 6, CELL // 2 + 13, base + 2],
                                   fill=(20, 30, 16, 90))
    return Image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(1.2)), img)


def shrub(species: str, ripe: int) -> Image.Image:
    """Knee-high, with at most one berry: either cog can try a shrub."""
    img = new(CELL, SHRUB_H)
    d = ImageDraw.Draw(img)
    base = SHRUB_H - 2
    ImageDraw.Draw(img).ellipse([8, base - 4, CELL - 9, base + 1], fill=(20, 30, 16, 80))
    d.ellipse([4, base - 22, CELL - 5, base], fill=SHRUB_GREEN + (255,))
    d.ellipse([9, base - 24, CELL - 14, base - 8], fill=(104, 158, 84, 255))
    d.ellipse([16, base - 12, CELL - 6, base - 1], fill=SHRUB_DARK + (220,))
    if ripe > 0:
        img.alpha_composite(fruit_sprite(species, 14), (CELL // 2 - 7, base - 20))
    return img


# ---------------------------------------------------------------------------
# fx
# ---------------------------------------------------------------------------

def puff_sprite() -> Image.Image:
    """The grey "..." puff over the canopy when the child reaches and fails --
    the single most important thing on screen."""
    img = new(30, 22)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 2, 29, 19], radius=8, fill=(238, 236, 230, 225),
                        outline=(90, 86, 78, 200))
    for i, x in enumerate((8, 14, 20)):
        d.ellipse([x - 2, 9, x + 1, 12], fill=PUFF + (255,))
    return img


def sparkle_sprite() -> Image.Image:
    img = new(20, 20)
    d = ImageDraw.Draw(img)
    for a in range(0, 360, 45):
        t = math.radians(a)
        d.line([(10, 10), (10 + 9 * math.cos(t), 10 + 9 * math.sin(t))],
               fill=SPARK + (230,), width=2)
    d.ellipse([6, 6, 13, 13], fill=(255, 255, 220, 255))
    return img


def waste_cloud() -> Image.Image:
    img = new(30, 24)
    d = ImageDraw.Draw(img)
    for cx, cy, r in ((9, 14, 8), (17, 11, 9), (23, 15, 7)):
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(120, 118, 112, 190))
    return img


# ---------------------------------------------------------------------------
# carry variants over the nano-banana bodies
# ---------------------------------------------------------------------------

def carry_variant(body: Image.Image, species: str) -> Image.Image:
    """The carried fruit drawn as a sprite OVER THE HEAD of the nano-banana
    body, so the same render serves every carry state."""
    out = body.copy()
    size = max(20, body.size[0] // 4)
    fruit = fruit_sprite(species, size)
    out.alpha_composite(fruit, ((body.size[0] - size) // 2, 0))
    return out


# ---------------------------------------------------------------------------
# loading curtain (the #lockerroom markup the starter chrome ships)
# ---------------------------------------------------------------------------

def yard_backdrop() -> Image.Image:
    """A sunny yard for #lk-bg, at the plate size the chrome's % geometry
    assumes (992x926)."""
    w, h = 992, 926
    img = Image.new("RGB", (w, h), (150, 205, 240))
    d = ImageDraw.Draw(img)
    for y in range(0, 560):
        k = y / 560
        d.line([(0, y), (w, y)],
               fill=(int(150 + 60 * k), int(205 + 30 * k), int(240 - 30 * k)))
    d.ellipse([760, 60, 940, 240], fill=(255, 240, 170))
    for cx, cy, r in ((160, 150, 70), (240, 130, 90), (330, 160, 60),
                      (600, 110, 60), (680, 130, 80)):
        d.ellipse([cx - r, cy - r * 0.7, cx + r, cy + r * 0.7], fill=(250, 250, 252))
    d.rectangle([0, 540, w, h], fill=(112, 168, 80))
    for i in range(0, w, 7):
        d.line([(i, 545 + (i % 13)), (i, h)], fill=(100, 154, 72))
    for x in (60, 300, 700, 900):
        tree = tall_tree("apple" if x < 500 else "banana", 3).resize((150, 240),
                                                                    Image.LANCZOS)
        img.paste(tree.convert("RGB"), (x, 330), tree)
    d.rectangle([0, 520, w, 548], fill=FENCE_WOOD)
    for x in range(0, w, 64):
        d.rectangle([x, 486, x + 16, 560], fill=FENCE_LIGHT)
    return img


def locker_poses(body: Image.Image) -> list[Image.Image]:
    """Five deterministic poses per bot for the loading carousel, cut from the
    nano-banana body: the starter's #lockerroom markup asks for <bot>_<f>.webp
    with f in 1,2,3,5,6."""
    out = []
    for i, (scale, angle) in enumerate(
            ((1.0, 0), (0.96, -6), (0.92, 7), (1.02, -3), (0.98, 4))):
        side = int(body.size[0] * scale)
        posed = body.resize((side, side), Image.LANCZOS).rotate(
            angle, resample=Image.BICUBIC, expand=True)
        out.append(posed)
    return out


def main() -> int:
    DATA.mkdir(parents=True, exist_ok=True)
    LOCKER.mkdir(parents=True, exist_ok=True)

    written = []

    def save(image: Image.Image, name: str, folder: pathlib.Path = DATA) -> None:
        path = folder / name
        image.save(path)
        written.append(path.relative_to(ROOT))

    save(grass_tile(), "grass.png")
    save(path_tile(), "path.png")
    save(fence_tile(False), "fence_h.png")
    save(fence_tile(True), "fence_v.png")
    save(fence_corner(), "fence_corner.png")
    save(mat_tile(), "mat.png")

    for species in ("apple", "banana"):
        save(fruit_sprite(species), f"fruit_{species}.png")
        save(tall_tree(species, 3), f"tree_{species}_full.png")
        save(tall_tree(species, 1), f"tree_{species}_picked.png")
        save(tall_tree(species, 0), f"tree_{species}_bare.png")
        save(shrub(species, 1), f"shrub_{species}_ripe.png")
        save(shrub(species, 0), f"shrub_{species}_bare.png")

    save(puff_sprite(), "reach_puff.png")
    save(sparkle_sprite(), "eat_sparkle.png")
    save(waste_cloud(), "waste_cloud.png")

    for role in ("parent", "child"):
        body_path = DATA / f"cog_{role}_front.png"
        if not body_path.exists():
            raise SystemExit(
                f"missing {body_path.relative_to(ROOT)} -- run "
                "scripts/art/split_cog_sheet.py first (the cog bodies are "
                "nano-banana renders, not procedural rigs)")
        body = Image.open(body_path).convert("RGBA")
        for species in ("apple", "banana"):
            save(carry_variant(body, species), f"cog_{role}_carry_{species}.png")

    # The loading curtain. `bg.jpg` is a sunny yard; the four carousels are cut
    # from the two nano-banana kits (parent art for blue/red, child art for
    # green/yellow), so the curtain shows THIS game's cogs.
    yard_backdrop().save(LOCKER / "bg.jpg", quality=88)
    written.append((LOCKER / "bg.jpg").relative_to(ROOT))
    kits = {
        "blue": Image.open(DATA / "cog_parent_front.png").convert("RGBA"),
        "red": Image.open(DATA / "cog_parent_carry_apple.png").convert("RGBA"),
        "green": Image.open(DATA / "cog_child_front.png").convert("RGBA"),
        "yellow": Image.open(DATA / "cog_child_reach.png").convert("RGBA"),
    }
    for bot, body in kits.items():
        for frame, posed in zip((1, 2, 3, 5, 6), locker_poses(body)):
            path = LOCKER / f"{bot}_{frame}.webp"
            posed.save(path, "WEBP", quality=90)
            written.append(path.relative_to(ROOT))

    for path in written:
        print(f"wrote {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
