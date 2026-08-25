## The standing-order kernels: the deterministic machine that turns ONE order
## per 48-tick turn into the per-tick grid action stream for the whole turn.
##
## A seat does not hand-author 720 actions — no LLM can. The sim's policy
## interface is per-tick grid actions exactly as the idea says; the LLM chooses
## the JOB and the kernel walks the yard. 30 LLM calls per episode instead of
## 1440.

import sim_types, yard, sim_state

proc occupiedBy(sim: Sim, seat, cellIndex: int): bool =
  ## True when the OTHER cog stands on `cellIndex`.
  let other = 1 - seat
  sim.yard.idx(sim.cogs[other].x, sim.cogs[other].y) == cellIndex

proc hasGroundAt(sim: Sim, cellIndex: int): bool =
  let x = cellIndex mod sim.yard.cols
  let y = cellIndex div sim.yard.cols
  sim.groundAt(x, y) >= 0

proc dropOk(sim: Sim, seat, cellIndex: int): bool =
  ## A cell the parent may legally drop onto and stand on.
  if not sim.yard.walkable(cellIndex mod sim.yard.cols,
      cellIndex div sim.yard.cols):
    return false
  if sim.occupiedBy(seat, cellIndex):
    return false
  if sim.hasGroundAt(cellIndex):
    return false
  let x = cellIndex mod sim.yard.cols
  let y = cellIndex div sim.yard.cols
  if sim.yard.isMat(x, y) and sim.matTotal() >= sim.config.basketCapacity:
    return false
  true

proc filterDroppable(sim: Sim, seat: int, cells: seq[int]): seq[int] =
  for c in cells:
    if sim.dropOk(seat, c):
      result.add c

proc filterFree(sim: Sim, seat: int, cells: seq[int]): seq[int] =
  for c in cells:
    if not sim.occupiedBy(seat, c):
      result.add c

proc groundCellsOf(sim: Sim, seat: int, f: Fruit, anySpecies = false,
    excluded: seq[int] = @[]): seq[int] =
  for g in sim.ground:
    if anySpecies or g.fruit == f:
      let c = sim.yard.idx(g.x, g.y)
      if not sim.occupiedBy(seat, c) and c notin excluded:
        result.add c

proc sourceApproach(sim: Sim, seat: int, kind: SourceKind, f: Fruit,
    requireRipe: bool, anySpecies = false): seq[int] =
  ## The walkable cells from which a cog may `pick` one of these sources.
  for s in sim.yard.sources:
    if s.kind != kind: continue
    if not anySpecies and s.fruit != f: continue
    if requireRipe and s.ripe <= 0: continue
    for c in sim.yard.adjacentCells(s.x, s.y):
      if not sim.occupiedBy(seat, c):
        result.add c

proc stepOrAct(sim: Sim, seat: int, targets: seq[int], onArrival: Action,
    arrived: var bool): Action =
  let cog = sim.cogs[seat]
  let plan = sim.yard.planTo(cog.x, cog.y, targets)
  if not plan.reachable:
    arrived = false
    return aWait
  if plan.atTarget:
    arrived = true
    return onArrival
  arrived = false
  plan.step

proc dropTargetsNearChild(sim: Sim, seat: int): seq[int] =
  ## The drop target: the nearest cell with no fruit on it within Chebyshev
  ## distance 1 of the child, else within distance 2, else the child's own
  ## cell's nearest free neighbour.
  let child = sim.cogs[sim.childSeat]
  result = sim.filterDroppable(seat, sim.yard.cellsWithin(child.x, child.y, 1))
  if result.len > 0: return
  result = sim.filterDroppable(seat, sim.yard.cellsWithin(child.x, child.y, 2))
  if result.len > 0: return
  result = sim.filterDroppable(seat, sim.yard.adjacentCells(child.x, child.y))

proc sidestepAndDrop(sim: Sim, seat: int): Action =
  ## Hand holds the wrong species: drop in place when the cell is free, else
  ## step one cell (first legal of N, E, S, W) and drop there next tick.
  let cog = sim.cogs[seat]
  let here = sim.yard.idx(cog.x, cog.y)
  if not sim.hasGroundAt(here) and
      (not sim.yard.isMat(cog.x, cog.y) or
        sim.matTotal() < sim.config.basketCapacity):
    return aDrop
  for d in 0 .. 3:
    let nx = cog.x + DirDx[d]
    let ny = cog.y + DirDy[d]
    if sim.yard.walkable(nx, ny) and
        not sim.occupiedBy(seat, sim.yard.idx(nx, ny)):
      return DirAction[d]
  aWait

proc usableApproach(sim: Sim, seat: int, f: Fruit, excluded: seq[int],
    cells: seq[int]): seq[int] =
  ## `pick` ALWAYS takes the ground fruit under the cog's own feet first, so an
  ## approach cell that holds a fruit this job does not want is not an approach
  ## cell at all: standing there grabs the wrong fruit, and the cog then drops
  ## it, re-targets the cell from one step away and oscillates forever, feeding
  ## nobody. A cell holding a fruit of `f` is fine — taking it IS the job —
  ## unless it is in `excluded`, i.e. already where the job wanted it.
  for c in cells:
    let gi = sim.groundAt(c mod sim.yard.cols, c div sim.yard.cols)
    if gi < 0:
      result.add c
    elif sim.ground[gi].fruit == f and c notin excluded:
      result.add c

proc harvestAction(sim: Sim, seat: int, f: Fruit,
    excluded: seq[int] = @[]): Action =
  ## Hand empty: BFS to the nearest source of `f` the cog may harvest, in the
  ## order ground fruit -> tall tree -> shrub, and `pick` on arrival.
  ##
  ## `excluded` holds the cells where the fruit is ALREADY where this job wants
  ## it (beside the child for `provide`, on the mat for `stock`).
  var arrived = false
  var targets = sim.groundCellsOf(seat, f, excluded = excluded)
  if targets.len > 0:
    return sim.stepOrAct(seat, targets, aPick, arrived)
  targets = sim.usableApproach(seat, f, excluded,
    sim.sourceApproach(seat, skTall, f, requireRipe = true))
  if targets.len > 0:
    return sim.stepOrAct(seat, targets, aPick, arrived)
  targets = sim.usableApproach(seat, f, excluded,
    sim.sourceApproach(seat, skShrub, f, requireRipe = true))
  if targets.len > 0:
    return sim.stepOrAct(seat, targets, aPick, arrived)
  # Nothing to fetch. If the cog is parked ON a fruit (the one it just
  # delivered), step off so the child can stand on it and eat.
  if sim.groundAt(sim.cogs[seat].x, sim.cogs[seat].y) >= 0:
    for d in 0 .. 3:
      let nx = sim.cogs[seat].x + DirDx[d]
      let ny = sim.cogs[seat].y + DirDy[d]
      if sim.yard.walkable(nx, ny) and
          not sim.occupiedBy(seat, sim.yard.idx(nx, ny)):
        return DirAction[d]
  aWait

proc parentAction(sim: Sim, seat: int): Action =
  let order = sim.orders[seat]
  let cog = sim.cogs[seat]
  var arrived = false
  case order.pjob
  of pjProvide:
    let want = order.fruit
    if cog.carry == ord(want):
      let targets = sim.dropTargetsNearChild(seat)
      if targets.len == 0:
        return aWait
      return sim.stepOrAct(seat, targets, aDrop, arrived)
    if cog.carry < 0:
      let child = sim.cogs[sim.childSeat]
      return sim.harvestAction(seat, want,
        excluded = sim.yard.cellsWithin(child.x, child.y, 1))
    return sim.sidestepAndDrop(seat)
  of pjStock:
    let want = order.fruit
    if cog.carry == ord(want):
      var targets: seq[int]
      for c in sim.yard.basket:
        if sim.dropOk(seat, c):
          targets.add c
      if targets.len == 0:
        # The mat is full: drop on the nearest free cell adjacent to the mat.
        for c in sim.yard.basket:
          let bx = c mod sim.yard.cols
          let by = c div sim.yard.cols
          for n in sim.yard.adjacentCells(bx, by):
            if sim.dropOk(seat, n) and not sim.yard.isMat(
                n mod sim.yard.cols, n div sim.yard.cols):
              targets.add n
      if targets.len == 0:
        return aWait
      return sim.stepOrAct(seat, targets, aDrop, arrived)
    if cog.carry < 0:
      return sim.harvestAction(seat, want, excluded = sim.yard.basket)
    return sim.sidestepAndDrop(seat)
  of pjWatch:
    let child = sim.cogs[sim.childSeat]
    let targets =
      sim.filterFree(seat, sim.yard.cellsWithin(child.x, child.y, 2))
    if targets.len == 0:
      return aWait
    return sim.stepOrAct(seat, targets, aWait, arrived)
  of pjIdle:
    return aWait

proc childAction(sim: Sim, seat: int): Action =
  let order = sim.orders[seat]
  let cog = sim.cogs[seat]
  var arrived = false
  case order.cjob
  of cjSeek:
    let want = order.fruit
    if cog.carry >= 0:
      return aEat
    let here = sim.groundAt(cog.x, cog.y)
    if here >= 0 and sim.ground[here].fruit == want:
      return aEat
    # Note what `seek` does NOT do: it never eats a ground fruit of the OTHER
    # species. A child standing on an unwanted apple and refusing it is a
    # legal, deliberate and highly informative act.
    var targets = sim.groundCellsOf(seat, want)
    if targets.len > 0:
      return sim.stepOrAct(seat, targets, aEat, arrived)
    targets = sim.usableApproach(seat, want, @[],
      sim.sourceApproach(seat, skShrub, want, requireRipe = true))
    if targets.len > 0:
      return sim.stepOrAct(seat, targets, aPick, arrived)
    targets = sim.usableApproach(seat, want, @[],
      sim.sourceApproach(seat, skTall, want, requireRipe = false))
    if targets.len > 0:
      return sim.stepOrAct(seat, targets, aPick, arrived)
    return aWait
  of cjShow:
    # Pure signalling: it can never yield food. It exists because the idea's
    # channel is behaviour, and a child that can spend a turn shouting with its
    # body is what makes the parent's inference tractable.
    let targets = sim.usableApproach(seat, order.fruit, @[],
      sim.sourceApproach(seat, skTall, order.fruit, requireRipe = false))
    if targets.len == 0:
      return aWait
    return sim.stepOrAct(seat, targets, aPick, arrived)
  of cjGraze:
    if cog.carry >= 0:
      return aEat
    if sim.groundAt(cog.x, cog.y) >= 0:
      return aEat
    var targets = sim.groundCellsOf(seat, fApple, anySpecies = true)
    if targets.len > 0:
      return sim.stepOrAct(seat, targets, aEat, arrived)
    targets = sim.sourceApproach(seat, skShrub, fApple, requireRipe = true,
      anySpecies = true)
    if targets.len > 0:
      return sim.stepOrAct(seat, targets, aPick, arrived)
    return aWait
  of cjBeg:
    if sim.groundAt(cog.x, cog.y) >= 0:
      return aEat
    if cog.carry >= 0:
      return aEat
    let parent = sim.cogs[sim.parentSeat]
    let targets =
      sim.filterFree(seat, sim.yard.cellsWithin(parent.x, parent.y, 1))
    if targets.len == 0:
      return aWait
    return sim.stepOrAct(seat, targets, aWait, arrived)
  of cjIdle:
    return aWait

proc kernelAction*(sim: Sim, seat: int): Action =
  ## Step 2 of the tick order. A cog on a fumble cooldown emits `wait`; a move
  ## intent while the move cooldown runs degrades to `wait` (the move-cooldown
  ## gate is on MOVES only, so `pick` stays legal every tick — which is what
  ## makes the repeated futile reach visible).
  if sim.cogs[seat].fumbleCd > 0:
    return aWait
  let intent =
    if sim.roleOf[seat] == rParent: sim.parentAction(seat)
    else: sim.childAction(seat)
  if intent in {aMoveN, aMoveE, aMoveS, aMoveW} and sim.cogs[seat].moveCd > 0:
    return aWait
  intent
