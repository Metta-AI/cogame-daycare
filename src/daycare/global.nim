## The `/global` sprite-protocol emitter and the wasm viewer packet builder.
##
## Heavily reduced fork of `coworld-ctf/src/ctf/global.nim`: the sprite-protocol
## emitter, layer/object pooling, the chrome `TextMessage` smuggling and
## `boardRenderScaleFor` are kept. Fog-of-war/FOV, the first-person PiP, rig art,
## the gun/grenade/spray/shield/barrier families, endzone bakes, perks and
## handicaps are DELETED — Daycare has none of them.
##
## The board background is emitted as horizontal BANDS, exactly as paintbot does
## it: the full 1152x672 yard is ~3.1 MB of RGBA and a single sprite-protocol
## message that large exceeds the hosted replay's 1 MiB WebSocket frame limit,
## so the viewer would close with 1009 and never load a frame. Band object ids
## sit at 40.. and z at -32768, which is the window
## `client/broadcast_core.js` caches as the static prefix (STATIC_BAND_MIN_ID).

import std/[algorithm, tables]
import bitworld/spriteprotocol
import sim_types, yard, art

const
  MapLayerId* = 0
  MapLayerType* = 0
  ZoomableLayerFlag* = 1

  MapBandSpriteBase* = 30
  MapBandObjectBase* = 40
  MapBandHeight* = 192
  StaticBandZ* = -32768

  ArtSpriteBase* = 600      ## one sprite per ArtKey: 600 .. 600+ord(high)
  LabelSpriteBase* = 700

  SourceObjectBase* = 200
  GroundObjectBase* = 300
  CogObjectBase* = 400
  LabelObjectBase* = 404
  FxObjectBase* = 410

  MaxGroundObjects* = 60
  FruitBlinkTicks* = 24     ## ground fruit blinks in its last 24 ticks of ttl

type
  BoardSnapshot* = object
    ## Everything the board draws, and nothing else. Both the live sim and the
    ## replay player produce one of these, so the native `/global` stream and
    ## the wasm bundle run the SAME renderer.
    cols*, rows*, cell*: int
    kinds*: seq[int]                    ## CellKind per cell, row-major
    sourceKind*: seq[int]
    sourceFruit*: seq[int]
    sourceX*: seq[int]
    sourceY*: seq[int]
    sourceRipe*: seq[int]
    groundX*: seq[int]
    groundY*: seq[int]
    groundFruit*: seq[int]
    groundTtl*: seq[int]
    cogX*: array[2, int]
    cogY*: array[2, int]
    cogCarry*: array[2, int]
    cogRole*: array[2, int]             ## ord(Role)
    reaching*: array[2, bool]
    wasting*: array[2, bool]
    eating*: array[2, bool]
    names*: array[2, string]
    showLabels*: bool
    tick*: int

  SpriteDef = object
    id: int
    width, height: int
    label: string

  ViewerState* = object
    ## Per-viewer emission state: which sprite defs this viewer has already
    ## received and which object ids are live, so a frame is a delta and a
    ## vanished ground fruit is deleted rather than left on the board.
    defs: Table[int, SpriteDef]
    live: seq[int]
    inited: bool

proc initViewerState*(): ViewerState =
  ViewerState(defs: initTable[int, SpriteDef](), live: @[], inited: false)

proc boardRenderScaleFor*(cols, rows: int): int =
  ## Paintbot supersamples big boards; Daycare's yard is authored at 48 board px
  ## per cell and ALWAYS fits the frame, so it emits at native scale.
  1

proc artSpriteId(key: ArtKey): int = ArtSpriteBase + ord(key)

proc ensureArtSprite(view: var ViewerState, packet: var seq[uint8],
    key: ArtKey) =
  let id = artSpriteId(key)
  if view.defs.hasKey(id):
    return
  let bmp = art(key)
  packet.addSprite(id, bmp.width, bmp.height, bmp.pixels, $key)
  view.defs[id] = SpriteDef(id: id, width: bmp.width, height: bmp.height,
    label: $key)

proc ensureLabelSprite(view: var ViewerState, packet: var seq[uint8],
    seat: int, name: string) =
  let id = LabelSpriteBase + seat
  if view.defs.hasKey(id) and view.defs[id].label == name:
    return
  let bmp = textSprite(name, 2, 242, 232, 216)
  packet.addSprite(id, bmp.width, bmp.height, bmp.pixels, name)
  view.defs[id] = SpriteDef(id: id, width: bmp.width, height: bmp.height,
    label: name)

proc bakeBackground(snap: BoardSnapshot): Bitmap =
  ## Grass yard inside a wooden fence, with the woven basket mat and a beaten
  ## path patch around it. Baked ONCE per viewer and shipped as static bands.
  let w = snap.cols * snap.cell
  let h = snap.rows * snap.cell
  result = newBitmap(w, h)
  let grass = art(akGrass)
  let pathTile = art(akPath)
  let mat = art(akMat)
  let fenceH = art(akFenceH)
  let fenceV = art(akFenceV)
  let corner = art(akFenceCorner)
  var matCells: seq[int]
  for i, k in snap.kinds:
    if k == ord(ckMat):
      matCells.add i
  for y in 0 ..< snap.rows:
    for x in 0 ..< snap.cols:
      let i = y * snap.cols + x
      let px = x * snap.cell
      let py = y * snap.cell
      var nearMat = false
      for m in matCells:
        let mx = m mod snap.cols
        let my = m div snap.cols
        if chebyshev(x, y, mx, my) <= 1:
          nearMat = true
          break
      case CellKind(snap.kinds[i])
      of ckFence:
        let isCornerCell =
          (x == 0 or x == snap.cols - 1) and (y == 0 or y == snap.rows - 1)
        if isCornerCell: result.blit(corner, px, py)
        elif y == 0 or y == snap.rows - 1: result.blit(fenceH, px, py)
        else: result.blit(fenceV, px, py)
      of ckMat:
        result.blit(mat, px, py)
      else:
        if nearMat: result.blit(pathTile, px, py)
        else: result.blit(grass, px, py)

proc emitBands(view: var ViewerState, packet: var seq[uint8],
    snap: BoardSnapshot) =
  let baked = bakeBackground(snap)
  var band = 0
  var y = 0
  while y < baked.height:
    let height = min(MapBandHeight, baked.height - y)
    let crop = baked.crop(0, y, baked.width, height)
    let spriteId = MapBandSpriteBase + band
    packet.addSprite(spriteId, crop.width, crop.height, crop.pixels,
      "yard band " & $band)
    view.defs[spriteId] = SpriteDef(id: spriteId, width: crop.width,
      height: crop.height, label: "yard band " & $band)
    packet.addObject(MapBandObjectBase + band, 0, y, StaticBandZ, MapLayerId,
      spriteId)
    view.live.add MapBandObjectBase + band
    inc band
    y += height

proc buildViewerPacket*(view: var ViewerState, snap: BoardSnapshot,
    chromeJson: string): seq[uint8] =
  ## One sprite-protocol packet: the board as objects on the zoomable map layer,
  ## plus the broadcast chrome smuggled as the label of the reserved 1x1 sprite
  ## 4090 (paintbot's binary channel — the ONLY one that survives a hosted
  ## replay).
  var packet: seq[uint8]
  var nextLive: seq[int]
  if not view.inited:
    view.inited = true
    packet.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
    packet.addViewport(MapLayerId, snap.cols * snap.cell, snap.rows * snap.cell)
    view.emitBands(packet, snap)
  for band in 0 ..< 8:
    if MapBandObjectBase + band in view.live:
      nextLive.add MapBandObjectBase + band

  # sources
  for i in 0 ..< snap.sourceKind.len:
    let f = Fruit(snap.sourceFruit[i])
    let isTall = snap.sourceKind[i] == ord(skTall)
    let key = if isTall: treeArt(f, snap.sourceRipe[i])
              else: shrubArt(f, snap.sourceRipe[i])
    view.ensureArtSprite(packet, key)
    let bmp = art(key)
    let px = snap.sourceX[i] * snap.cell + (snap.cell - bmp.width) div 2
    let py = (snap.sourceY[i] + 1) * snap.cell - bmp.height
    let objectId = SourceObjectBase + i
    packet.addObject(objectId, px, py, snap.sourceY[i] * 4 + 1, MapLayerId,
      artSpriteId(key))
    nextLive.add objectId

  # ground fruit; blinks in its last FruitBlinkTicks of ttl
  var slot = 0
  for i in 0 ..< snap.groundX.len:
    if slot >= MaxGroundObjects: break
    let ttl = snap.groundTtl[i]
    if ttl >= 0 and ttl <= FruitBlinkTicks and (snap.tick div 3) mod 2 == 1:
      continue
    let key = fruitArt(Fruit(snap.groundFruit[i]))
    view.ensureArtSprite(packet, key)
    let bmp = art(key)
    let px = snap.groundX[i] * snap.cell + (snap.cell - bmp.width) div 2
    let py = snap.groundY[i] * snap.cell + snap.cell - bmp.height - 6
    let objectId = GroundObjectBase + slot
    packet.addObject(objectId, px, py, snap.groundY[i] * 4, MapLayerId,
      artSpriteId(key))
    nextLive.add objectId
    inc slot

  # the two cogs: the parent as a 40 px adult body, the child as a 28 px body
  for seat in 0 .. 1:
    let isParent = snap.cogRole[seat] == ord(rParent)
    let carry = snap.cogCarry[seat]
    let key =
      if isParent:
        if carry == ord(fApple): akParentCarryApple
        elif carry == ord(fBanana): akParentCarryBanana
        else: akParentFront
      else:
        if snap.reaching[seat]: akChildReach
        elif carry == ord(fApple): akChildCarryApple
        elif carry == ord(fBanana): akChildCarryBanana
        else: akChildFront
    view.ensureArtSprite(packet, key)
    let bmp = art(key)
    let drawn = if isParent: 40 else: 28
    let scale = drawn * 100 div max(1, bmp.height)
    let width = max(1, bmp.width * scale div 100)
    let px = snap.cogX[seat] * snap.cell + (snap.cell - width) div 2
    let py = (snap.cogY[seat] + 1) * snap.cell - drawn - 4
    let objectId = CogObjectBase + seat
    # The scaled body rides its own sprite id so the wire carries the drawn
    # size (the compositor is an integer blitter and never resamples).
    let scaledId = artSpriteId(key) + 100 * (seat + 1)
    if not view.defs.hasKey(scaledId):
      let small = bmp.scaled(width, drawn)
      packet.addSprite(scaledId, small.width, small.height, small.pixels,
        $key & " x" & $drawn)
      view.defs[scaledId] = SpriteDef(id: scaledId, width: small.width,
        height: small.height, label: $key & " x" & $drawn)
    packet.addObject(objectId, px, py, snap.cogY[seat] * 4 + 2, MapLayerId,
      scaledId)
    nextLive.add objectId

    if snap.showLabels:
      view.ensureLabelSprite(packet, seat, snap.names[seat])
      let label = view.defs[LabelSpriteBase + seat]
      packet.addObject(LabelObjectBase + seat,
        snap.cogX[seat] * snap.cell + (snap.cell - label.width) div 2,
        (snap.cogY[seat] + 1) * snap.cell - 4,
        snap.cogY[seat] * 4 + 3, MapLayerId, LabelSpriteBase + seat)
      nextLive.add LabelObjectBase + seat

    # A child reach plays the arms-up frame with a short grey "..." puff over
    # the canopy: the signal the parent is supposed to read.
    if snap.reaching[seat]:
      view.ensureArtSprite(packet, akReachPuff)
      let puff = art(akReachPuff)
      packet.addObject(FxObjectBase + seat,
        snap.cogX[seat] * snap.cell + (snap.cell - puff.width) div 2,
        snap.cogY[seat] * snap.cell - puff.height - 2,
        1000, MapLayerId, artSpriteId(akReachPuff))
      nextLive.add FxObjectBase + seat
    if snap.wasting[seat]:
      view.ensureArtSprite(packet, akWasteCloud)
      let cloud = art(akWasteCloud)
      packet.addObject(FxObjectBase + 2 + seat,
        snap.cogX[seat] * snap.cell + (snap.cell - cloud.width) div 2,
        snap.cogY[seat] * snap.cell - cloud.height,
        1001, MapLayerId, artSpriteId(akWasteCloud))
      nextLive.add FxObjectBase + 2 + seat
    if snap.eating[seat]:
      view.ensureArtSprite(packet, akEatSparkle)
      let spark = art(akEatSparkle)
      packet.addObject(FxObjectBase + 4 + seat,
        snap.cogX[seat] * snap.cell + (snap.cell - spark.width) div 2,
        snap.cogY[seat] * snap.cell - spark.height div 2,
        1002, MapLayerId, artSpriteId(akEatSparkle))
      nextLive.add FxObjectBase + 4 + seat

  # Delete whatever went away, so a rotted fruit or a finished puff leaves the
  # board instead of sticking.
  for objectId in view.live:
    if objectId notin nextLive:
      packet.addDeleteObject(objectId)
  view.live = nextLive
  view.live.sort()

  # The broadcast chrome. Never a drawable sprite: broadcast_core.js routes the
  # label of sprite 4090 straight to onText.
  packet.addSprite(BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0], chromeJson)
  packet
