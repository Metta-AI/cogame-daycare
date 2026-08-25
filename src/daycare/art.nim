## Board art, embedded.
##
## Every sprite is `staticRead` + `pixie.decodeImage`, NOT a runtime file read:
## the same module is compiled to wasm for the static replay bundle, where there
## is no filesystem to resolve `data/` against, and a missing asset must be a
## compile error rather than a blank board in a hosted replay.
##
## The two cog bodies are nano-banana renders of the Softmax cog
## (`scripts/art/source/cogs_sheet.png` -> `scripts/art/split_cog_sheet.py`);
## everything else is the deterministic Pillow art in
## `scripts/art/gen_daycare_art.py`.

import std/[tables]
import pixie
import sim_types

const
  GrassPng = staticRead("../../data/grass.png")
  PathPng = staticRead("../../data/path.png")
  FenceHPng = staticRead("../../data/fence_h.png")
  FenceVPng = staticRead("../../data/fence_v.png")
  FenceCornerPng = staticRead("../../data/fence_corner.png")
  MatPng = staticRead("../../data/mat.png")
  FruitApplePng = staticRead("../../data/fruit_apple.png")
  FruitBananaPng = staticRead("../../data/fruit_banana.png")
  TreeAppleFullPng = staticRead("../../data/tree_apple_full.png")
  TreeApplePickedPng = staticRead("../../data/tree_apple_picked.png")
  TreeAppleBarePng = staticRead("../../data/tree_apple_bare.png")
  TreeBananaFullPng = staticRead("../../data/tree_banana_full.png")
  TreeBananaPickedPng = staticRead("../../data/tree_banana_picked.png")
  TreeBananaBarePng = staticRead("../../data/tree_banana_bare.png")
  ShrubAppleRipePng = staticRead("../../data/shrub_apple_ripe.png")
  ShrubAppleBarePng = staticRead("../../data/shrub_apple_bare.png")
  ShrubBananaRipePng = staticRead("../../data/shrub_banana_ripe.png")
  ShrubBananaBarePng = staticRead("../../data/shrub_banana_bare.png")
  ReachPuffPng = staticRead("../../data/reach_puff.png")
  EatSparklePng = staticRead("../../data/eat_sparkle.png")
  WasteCloudPng = staticRead("../../data/waste_cloud.png")
  CogParentFrontPng = staticRead("../../data/cog_parent_front.png")
  CogParentCarryApplePng = staticRead("../../data/cog_parent_carry_apple.png")
  CogParentCarryBananaPng = staticRead("../../data/cog_parent_carry_banana.png")
  CogChildFrontPng = staticRead("../../data/cog_child_front.png")
  CogChildCarryApplePng = staticRead("../../data/cog_child_carry_apple.png")
  CogChildCarryBananaPng = staticRead("../../data/cog_child_carry_banana.png")
  CogChildReachPng = staticRead("../../data/cog_child_reach.png")

type
  Bitmap* = object
    ## Straight-alpha RGBA, the Sprite v1 wire format (pixie stores
    ## premultiplied, so every decode is converted once here).
    width*, height*: int
    pixels*: seq[uint8]

  ArtKey* = enum
    akGrass, akPath, akFenceH, akFenceV, akFenceCorner, akMat,
    akFruitApple, akFruitBanana,
    akTreeAppleFull, akTreeApplePicked, akTreeAppleBare,
    akTreeBananaFull, akTreeBananaPicked, akTreeBananaBare,
    akShrubAppleRipe, akShrubAppleBare, akShrubBananaRipe, akShrubBananaBare,
    akReachPuff, akEatSparkle, akWasteCloud,
    akParentFront, akParentCarryApple, akParentCarryBanana,
    akChildFront, akChildCarryApple, akChildCarryBanana, akChildReach

const ArtBytes: array[ArtKey, string] = [
  GrassPng, PathPng, FenceHPng, FenceVPng, FenceCornerPng, MatPng,
  FruitApplePng, FruitBananaPng,
  TreeAppleFullPng, TreeApplePickedPng, TreeAppleBarePng,
  TreeBananaFullPng, TreeBananaPickedPng, TreeBananaBarePng,
  ShrubAppleRipePng, ShrubAppleBarePng, ShrubBananaRipePng, ShrubBananaBarePng,
  ReachPuffPng, EatSparklePng, WasteCloudPng,
  CogParentFrontPng, CogParentCarryApplePng, CogParentCarryBananaPng,
  CogChildFrontPng, CogChildCarryApplePng, CogChildCarryBananaPng,
  CogChildReachPng
]

var artCache: Table[ArtKey, Bitmap]

proc toStraightRgba(image: Image): Bitmap =
  result.width = image.width
  result.height = image.height
  result.pixels = newSeq[uint8](image.width * image.height * 4)
  for i in 0 ..< image.width * image.height:
    let c = image.data[i].rgba()
    result.pixels[i * 4] = c.r
    result.pixels[i * 4 + 1] = c.g
    result.pixels[i * 4 + 2] = c.b
    result.pixels[i * 4 + 3] = c.a

proc art*(key: ArtKey): Bitmap =
  if key notin artCache:
    artCache[key] = toStraightRgba(decodeImage(ArtBytes[key]))
  artCache[key]

proc newBitmap*(width, height: int): Bitmap =
  Bitmap(width: width, height: height,
    pixels: newSeq[uint8](width * height * 4))

proc blit*(dst: var Bitmap, src: Bitmap, atX, atY: int) =
  ## Straight-alpha source-over. Deterministic integer maths: the same board
  ## bakes byte-identically native and in wasm.
  for y in 0 ..< src.height:
    let dy = atY + y
    if dy < 0 or dy >= dst.height: continue
    for x in 0 ..< src.width:
      let dx = atX + x
      if dx < 0 or dx >= dst.width: continue
      let s = (y * src.width + x) * 4
      let sa = int(src.pixels[s + 3])
      if sa == 0: continue
      let d = (dy * dst.width + dx) * 4
      if sa == 255:
        dst.pixels[d] = src.pixels[s]
        dst.pixels[d + 1] = src.pixels[s + 1]
        dst.pixels[d + 2] = src.pixels[s + 2]
        dst.pixels[d + 3] = 255
        continue
      let da = int(dst.pixels[d + 3])
      let outA = sa + da * (255 - sa) div 255
      if outA == 0:
        continue
      for c in 0 .. 2:
        let sv = int(src.pixels[s + c]) * sa
        let dv = int(dst.pixels[d + c]) * da * (255 - sa) div 255
        dst.pixels[d + c] = uint8((sv + dv) div outA)
      dst.pixels[d + 3] = uint8(outA)

proc scaled*(src: Bitmap, width, height: int): Bitmap =
  ## Nearest-neighbour integer resample. The board draws pixelated, so this is
  ## the same filter the compositor uses.
  result = newBitmap(width, height)
  if src.width == 0 or src.height == 0: return
  for y in 0 ..< height:
    let sy = y * src.height div height
    for x in 0 ..< width:
      let sx = x * src.width div width
      let s = (sy * src.width + sx) * 4
      let d = (y * width + x) * 4
      for c in 0 .. 3:
        result.pixels[d + c] = src.pixels[s + c]

proc crop*(src: Bitmap, x, y, width, height: int): Bitmap =
  result = newBitmap(width, height)
  for row in 0 ..< height:
    let sy = y + row
    if sy < 0 or sy >= src.height: continue
    for col in 0 ..< width:
      let sx = x + col
      if sx < 0 or sx >= src.width: continue
      let s = (sy * src.width + sx) * 4
      let d = (row * width + col) * 4
      for c in 0 .. 3:
        result.pixels[d + c] = src.pixels[s + c]

# ---------------------------------------------------------------------------
# A 3x5 pixel font, for the alias under a cog's feet. Hand-rolled rather than
# pulled from bitworld/pixelfonts so the wasm bundle needs no preloaded font
# file: a missing font would be a blank label in a hosted replay.
# ---------------------------------------------------------------------------

const Glyphs: array[27, array[5, uint8]] = [
  [0b010'u8, 0b101, 0b111, 0b101, 0b101],  # A
  [0b110'u8, 0b101, 0b110, 0b101, 0b110],  # B
  [0b011'u8, 0b100, 0b100, 0b100, 0b011],  # C
  [0b110'u8, 0b101, 0b101, 0b101, 0b110],  # D
  [0b111'u8, 0b100, 0b110, 0b100, 0b111],  # E
  [0b111'u8, 0b100, 0b110, 0b100, 0b100],  # F
  [0b011'u8, 0b100, 0b101, 0b101, 0b011],  # G
  [0b101'u8, 0b101, 0b111, 0b101, 0b101],  # H
  [0b111'u8, 0b010, 0b010, 0b010, 0b111],  # I
  [0b001'u8, 0b001, 0b001, 0b101, 0b010],  # J
  [0b101'u8, 0b101, 0b110, 0b101, 0b101],  # K
  [0b100'u8, 0b100, 0b100, 0b100, 0b111],  # L
  [0b101'u8, 0b111, 0b111, 0b101, 0b101],  # M
  [0b110'u8, 0b101, 0b101, 0b101, 0b101],  # N
  [0b010'u8, 0b101, 0b101, 0b101, 0b010],  # O
  [0b110'u8, 0b101, 0b110, 0b100, 0b100],  # P
  [0b010'u8, 0b101, 0b101, 0b111, 0b011],  # Q
  [0b110'u8, 0b101, 0b110, 0b101, 0b101],  # R
  [0b011'u8, 0b100, 0b010, 0b001, 0b110],  # S
  [0b111'u8, 0b010, 0b010, 0b010, 0b010],  # T
  [0b101'u8, 0b101, 0b101, 0b101, 0b111],  # U
  [0b101'u8, 0b101, 0b101, 0b101, 0b010],  # V
  [0b101'u8, 0b101, 0b111, 0b111, 0b101],  # W
  [0b101'u8, 0b101, 0b010, 0b101, 0b101],  # X
  [0b101'u8, 0b101, 0b010, 0b010, 0b010],  # Y
  [0b111'u8, 0b001, 0b010, 0b100, 0b111],  # Z
  [0b000'u8, 0b000, 0b000, 0b000, 0b000]   # space / unknown
]

proc glyphIndex(ch: char): int =
  if ch >= 'A' and ch <= 'Z': ord(ch) - ord('A')
  elif ch >= 'a' and ch <= 'z': ord(ch) - ord('a')
  else: 26

proc textSprite*(text: string, scale: int, r, g, b: uint8): Bitmap =
  ## A pill-backed 3x5 label. Used for the alias under a cog's feet, which is
  ## the only text the BOARD draws — every other string lives in the DOM chrome,
  ## so `viewer_smoke.mjs --strict-text-bounds` has nothing to catch here.
  let padX = 2 * scale
  let padY = 2 * scale
  let advance = 4 * scale
  let width = padX * 2 + max(1, text.len) * advance - scale
  let height = padY * 2 + 5 * scale
  result = newBitmap(width, height)
  for y in 0 ..< height:
    for x in 0 ..< width:
      let d = (y * width + x) * 4
      result.pixels[d] = 18
      result.pixels[d + 1] = 14
      result.pixels[d + 2] = 10
      result.pixels[d + 3] = 170
  for i, ch in text:
    let rows = Glyphs[glyphIndex(ch)]
    for row in 0 ..< 5:
      for col in 0 ..< 3:
        if (rows[row] and (1'u8 shl (2 - col))) == 0: continue
        for sy in 0 ..< scale:
          for sx in 0 ..< scale:
            let px = padX + i * advance + col * scale + sx
            let py = padY + row * scale + sy
            if px >= width or py >= height: continue
            let d = (py * width + px) * 4
            result.pixels[d] = r
            result.pixels[d + 1] = g
            result.pixels[d + 2] = b
            result.pixels[d + 3] = 255

proc treeArt*(f: Fruit, ripe: int): ArtKey =
  if f == fApple:
    if ripe >= 2: akTreeAppleFull
    elif ripe == 1: akTreeApplePicked
    else: akTreeAppleBare
  else:
    if ripe >= 2: akTreeBananaFull
    elif ripe == 1: akTreeBananaPicked
    else: akTreeBananaBare

proc shrubArt*(f: Fruit, ripe: int): ArtKey =
  if f == fApple:
    if ripe > 0: akShrubAppleRipe else: akShrubAppleBare
  else:
    if ripe > 0: akShrubBananaRipe else: akShrubBananaBare

proc fruitArt*(f: Fruit): ArtKey =
  if f == fApple: akFruitApple else: akFruitBanana
