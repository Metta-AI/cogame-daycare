## The yard: one authored 24x14 grid per variant, its mirror, and the BFS the
## kernels walk.
##
## Heavily reduced fork of `coworld-ctf/src/ctf/arena.nim`. Daycare has ONE
## authored layout, so the terrain generator, `mapSpec`, the symmetry
## machinery, the validators, the pixel queries and `map_pool` are all deleted.
## What survives is the cell grid, the mirror reflection and the pathfinder.

import std/[algorithm]
import sim_types

type
  CellKind* = enum
    ckGrass
    ckFence
    ckMat
    ckTall
    ckShrub

  Yard* = object
    cols*, rows*: int
    mirrored*: bool
    cell*: seq[CellKind]
    sourceAt*: seq[int]     ## cell index -> index into `sources`, else -1
    sources*: seq[SourceState]
    basket*: seq[int]       ## the four mat cell indexes, (row, col) ascending
    spawns*: array[2, int]   ## cell index by ROLE: [parent, child]

const
  ## Authored, species-congruent by construction: the reflection x -> 23 - x
  ## maps the apple set exactly onto the banana set, trees and shrubs alike, so
  ## no species is nearer to anything than the other and a policy cannot infer
  ## the preference from the map. `tests/test_noleak.nim` asserts it.
  AppleTall*: array[4, (int, int)] = [(4, 2), (16, 2), (7, 11), (19, 11)]
  BananaTall*: array[4, (int, int)] = [(7, 2), (19, 2), (4, 11), (16, 11)]
  AppleShrub*: array[2, (int, int)] = [(9, 5), (14, 8)]
  BananaShrub*: array[2, (int, int)] = [(14, 5), (9, 8)]
  BasketCells*: array[4, (int, int)] = [(11, 6), (12, 6), (11, 7), (12, 7)]
  ParentSpawn* = (12, 9)
  ChildSpawn* = (11, 4)

  ## Neighbour expansion order. N, E, S, W — fixed, so BFS paths are unique and
  ## deterministic and a replay is reproducible from its seed.
  DirDx*: array[4, int] = [0, 1, 0, -1]
  DirDy*: array[4, int] = [-1, 0, 1, 0]
  DirAction*: array[4, Action] = [aMoveN, aMoveE, aMoveS, aMoveW]

proc idx*(yard: Yard, x, y: int): int = y * yard.cols + x

proc inBounds*(yard: Yard, x, y: int): bool =
  x >= 0 and y >= 0 and x < yard.cols and y < yard.rows

proc kindAt*(yard: Yard, x, y: int): CellKind =
  if not yard.inBounds(x, y): ckFence else: yard.cell[yard.idx(x, y)]

proc walkable*(yard: Yard, x, y: int): bool =
  ## Grass and mat only: fence, trees and shrubs are impassable.
  let k = yard.kindAt(x, y)
  k == ckGrass or k == ckMat

proc isMat*(yard: Yard, x, y: int): bool =
  yard.kindAt(x, y) == ckMat

proc sourceIndexAt*(yard: Yard, x, y: int): int =
  if not yard.inBounds(x, y): -1 else: yard.sourceAt[yard.idx(x, y)]

proc mirrorX(x: int, mirrored: bool): int =
  if mirrored: YardCols - 1 - x else: x

proc addSource(
  yard: var Yard,
  id: string,
  kind: SourceKind,
  fruit: Fruit,
  x, y: int,
  config: GameConfig
) =
  let capacity = if kind == skTall: config.tallCapacity else: config.shrubCapacity
  let regrowTicks =
    if kind == skTall: config.tallRegrowTicks else: config.shrubRegrowTicks
  let ripe0 = if kind == skTall: TallInitialRipe else: ShrubInitialRipe
  yard.sources.add SourceState(
    id: id,
    kind: kind,
    fruit: fruit,
    x: x,
    y: y,
    ripe: min(ripe0, capacity),
    regrow: 0,
    capacity: capacity,
    regrowTicks: regrowTicks
  )
  yard.cell[yard.idx(x, y)] = if kind == skTall: ckTall else: ckShrub
  yard.sourceAt[yard.idx(x, y)] = yard.sources.high

proc initYard*(config: GameConfig, mirrored: bool): Yard =
  ## The authored yard, optionally reflected. `mirrored` comes from
  ## `rngLayout`, never from `rngSecret`, so "apples live on the left" is not a
  ## learnable prior either.
  result.cols = YardCols
  result.rows = YardRows
  result.mirrored = mirrored
  result.cell = newSeq[CellKind](YardCols * YardRows)
  result.sourceAt = newSeq[int](YardCols * YardRows)
  for i in 0 ..< result.sourceAt.len:
    result.sourceAt[i] = -1
  for y in 0 ..< YardRows:
    for x in 0 ..< YardCols:
      result.cell[result.idx(x, y)] =
        if x == 0 or y == 0 or x == YardCols - 1 or y == YardRows - 1: ckFence
        else: ckGrass

  # The basket mat: four walkable cells in the middle. Fruit resting on a mat
  # cell does not rot; the mat holds at most basketCapacity fruit in total.
  for (bx, by) in BasketCells:
    let x = mirrorX(bx, mirrored)
    result.cell[result.idx(x, by)] = ckMat
  # (row, col) ascending, so "the first two cells" is well defined.
  var mats: seq[int]
  for y in 0 ..< YardRows:
    for x in 0 ..< YardCols:
      if result.cell[result.idx(x, y)] == ckMat:
        mats.add result.idx(x, y)
  result.basket = mats

  # Sources, in the fixed order tall trees then shrubs, each by (row, col).
  # Ids are stable across the mirror so the replay's `config.sources` order and
  # the per-frame `s` array agree.
  var talls: seq[(int, int, Fruit)]
  for (x, y) in AppleTall: talls.add (mirrorX(x, mirrored), y, fApple)
  for (x, y) in BananaTall: talls.add (mirrorX(x, mirrored), y, fBanana)
  talls.sort(proc (a, b: (int, int, Fruit)): int =
    if a[1] != b[1]: cmp(a[1], b[1]) else: cmp(a[0], b[0]))
  for i, t in talls:
    result.addSource("T" & $(i + 1), skTall, t[2], t[0], t[1], config)

  var shrubs: seq[(int, int, Fruit)]
  let sparse = config.shrubs <= 2
  for i, (x, y) in AppleShrub:
    if sparse and i > 0: break
    shrubs.add (mirrorX(x, mirrored), y, fApple)
  for i, (x, y) in BananaShrub:
    if sparse and i > 0: break
    shrubs.add (mirrorX(x, mirrored), y, fBanana)
  shrubs.sort(proc (a, b: (int, int, Fruit)): int =
    if a[1] != b[1]: cmp(a[1], b[1]) else: cmp(a[0], b[0]))
  for i, s in shrubs:
    result.addSource("S" & $(i + 1), skShrub, s[2], s[0], s[1], config)

  # THE SPAWNS DO NOT MIRROR. The reflection x -> 23 - x maps the apple source
  # set exactly onto the banana set, but it is an ISOMETRY: reflecting the
  # spawns with it leaves every distance unchanged, so it cannot remove a
  # species bias — and there IS one, because no cell of a 24-wide yard is
  # equidistant from the two sets (`da - db` is odd on every walkable cell).
  # Holding the spawns fixed while the sources reflect is what makes the mirror
  # bit swap WHICH SPECIES IS NEARER, so the bias cancels across seeds. That is
  # feasibility gate (f) ("fix the layout congruence, never the reward").
  result.spawns[ord(rParent)] = result.idx(ParentSpawn[0], ParentSpawn[1])
  result.spawns[ord(rChild)] = result.idx(ChildSpawn[0], ChildSpawn[1])

proc layoutHash*(yard: Yard): uint64 =
  ## A hash of everything a seat can observe about the yard. Identical whether
  ## the preference is forced to apple or banana — that is gate (c) of
  ## `tests/test_noleak.nim`.
  result = 0xcbf29ce484222325'u64
  for k in yard.cell:
    result = (result xor uint64(ord(k) + 1)) * 0x100000001b3'u64
  for s in yard.sources:
    for v in [ord(s.kind), ord(s.fruit), s.x, s.y, s.ripe, s.capacity,
        s.regrowTicks]:
      result = (result xor uint64(v + 1)) * 0x100000001b3'u64
  for c in yard.basket:
    result = (result xor uint64(c + 1)) * 0x100000001b3'u64
  for c in yard.spawns:
    result = (result xor uint64(c + 1)) * 0x100000001b3'u64

# ---------------------------------------------------------------------------
# BFS
# ---------------------------------------------------------------------------

type
  PathPlan* = object
    reachable*: bool
    atTarget*: bool
    step*: Action
    dist*: int

proc chebyshev*(ax, ay, bx, by: int): int =
  max(abs(ax - bx), abs(ay - by))

proc planTo*(yard: Yard, fromX, fromY: int, targets: openArray[int]): PathPlan =
  ## First step of the unique shortest path to the nearest target cell.
  ##
  ## BFS is over WALKABLE cells only — the other cog is not an obstacle for
  ## path planning, only for the move itself — with neighbour expansion in
  ## N, E, S, W order, so paths are unique and deterministic. Ties between
  ## equidistant targets break by (row, col) ascending.
  result.step = aWait
  if targets.len == 0:
    return
  var isTarget = newSeq[bool](yard.cell.len)
  for t in targets:
    if t >= 0 and t < isTarget.len:
      isTarget[t] = true
  let start = yard.idx(fromX, fromY)
  if isTarget[start]:
    result.reachable = true
    result.atTarget = true
    result.dist = 0
    return
  var
    dist = newSeq[int](yard.cell.len)
    firstStep = newSeq[int](yard.cell.len)
    queue = newSeqOfCap[int](yard.cell.len)
  for i in 0 ..< dist.len:
    dist[i] = -1
    firstStep[i] = -1
  dist[start] = 0
  queue.add start
  var head = 0
  var best = -1
  var bestDist = -1
  while head < queue.len:
    let cur = queue[head]
    inc head
    if bestDist >= 0 and dist[cur] >= bestDist:
      # Every cell of the level BEFORE the winning one has been expanded, so no
      # equidistant target can still be discovered; the tie-break is settled.
      break
    let cx = cur mod yard.cols
    let cy = cur div yard.cols
    for d in 0 .. 3:
      let nx = cx + DirDx[d]
      let ny = cy + DirDy[d]
      if not yard.walkable(nx, ny):
        continue
      let n = yard.idx(nx, ny)
      if dist[n] >= 0:
        continue
      dist[n] = dist[cur] + 1
      firstStep[n] = if cur == start: d else: firstStep[cur]
      queue.add n
      if isTarget[n]:
        if bestDist < 0 or dist[n] < bestDist or
            (dist[n] == bestDist and n < best):
          # `n < best` on the flat index IS (row, col) ascending.
          bestDist = dist[n]
          best = n
  if best < 0:
    return
  result.reachable = true
  result.dist = bestDist
  result.step = DirAction[firstStep[best]]

proc adjacentCells*(yard: Yard, x, y: int): seq[int] =
  ## The walkable cells orthogonally adjacent to (x, y), in N, E, S, W order.
  for d in 0 .. 3:
    let nx = x + DirDx[d]
    let ny = y + DirDy[d]
    if yard.walkable(nx, ny):
      result.add yard.idx(nx, ny)

proc cellsWithin*(yard: Yard, x, y, radius: int): seq[int] =
  ## Walkable cells within Chebyshev `radius` of (x, y), (row, col) ascending.
  for dy in -radius .. radius:
    for dx in -radius .. radius:
      let nx = x + dx
      let ny = y + dy
      if yard.walkable(nx, ny):
        result.add yard.idx(nx, ny)
  result.sort()
