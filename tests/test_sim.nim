## Sim units: the reach table, the nine-step tick order, scoring, regrow,
## cooldowns, collisions, BFS determinism, the fickle switch and `gameHash`
## reproducibility.
##
## Design note ## Tests, item 1.


import helpers

proc unitConfig(): GameConfig =
  result = variantConfig("daycare", 11)
  result.turns = 2
  result.minTurnSeconds = 0

proc place(sim: var Sim, seat, x, y: int) =
  sim.cogs[seat].x = x
  sim.cogs[seat].y = y
  sim.cogs[seat].moveCd = 0
  sim.cogs[seat].fumbleCd = 0

proc sourceIndex(sim: Sim, kind: SourceKind, f: Fruit): int =
  for i, s in sim.yard.sources:
    if s.kind == kind and s.fruit == f:
      return i
  -1

proc adjacentCell(sim: Sim, i: int): (int, int) =
  let cells = sim.yard.adjacentCells(sim.yard.sources[i].x,
    sim.yard.sources[i].y)
  doAssert cells.len > 0
  (cells[0] mod sim.yard.cols, cells[0] div sim.yard.cols)

proc clearOrders(sim: var Sim) =
  for seat in 0 .. 1:
    sim.orders[seat] = Order(source: osScripted)
    if sim.roleOf[seat] == rParent:
      sim.orders[seat].pjob = pjIdle
    else:
      sim.orders[seat].cjob = cjIdle

proc setOrder(sim: var Sim, seat: int, job: ParentJob, f: Fruit) =
  sim.orders[seat] = Order(pjob: job, fruit: f, hasFruit: true, guess: f,
    hasGuess: true, source: osScripted)

proc setChildOrder(sim: var Sim, seat: int, job: ChildJob, f: Fruit) =
  sim.orders[seat] = Order(cjob: job, fruit: f, hasFruit: true,
    source: osScripted)

proc eventsAt(sim: Sim, tick: int, kind: string): int =
  for row in sim.events:
    if row{"t"}.getInt() == tick and row{"k"}.getStr() == kind:
      inc result

# ---------------------------------------------------------------------------
echo "test_sim: the shipped constants are the constants the design ships"
block:
  let cfg = defaultGameConfig()
  doAssert cfg.turns == 15, $cfg.turns
  doAssert cfg.ticksPerTurn == DefaultTicksPerTurn
  doAssert cfg.moveCooldown == 2
  doAssert cfg.carryCap == 1
  doAssert cfg.tallCapacity == 3
  doAssert cfg.shrubCapacity == 1
  doAssert cfg.childShrubPickPermille == 250
  doAssert cfg.childReachCooldownTicks == 6
  doAssert cfg.basketCapacity == 2
  doAssert cfg.rewardPreferred == 3
  doAssert cfg.parScore() == 2 * cfg.turns
  doAssert cfg.totalTicks() == cfg.turns * cfg.ticksPerTurn

echo "test_sim: the yard is the authored yard"
block:
  for variant in AllVariants:
    let sim = initSim(variantConfig(variant, 3))
    doAssert sim.yard.cols == 24 and sim.yard.rows == 14
    var talls = 0
    var shrubs = 0
    for s in sim.yard.sources:
      if s.kind == skTall: inc talls else: inc shrubs
    doAssert talls == 8, $talls
    doAssert shrubs == (if variant == "daycare-sparse": 2 else: 4), $shrubs
    doAssert sim.yard.basket.len == 4
    # the full border ring is impassable fence
    for x in 0 ..< sim.yard.cols:
      doAssert sim.yard.kindAt(x, 0) == ckFence
      doAssert sim.yard.kindAt(x, sim.yard.rows - 1) == ckFence
    for y in 0 ..< sim.yard.rows:
      doAssert sim.yard.kindAt(0, y) == ckFence
      doAssert sim.yard.kindAt(sim.yard.cols - 1, y) == ckFence
    # trees, shrubs and fence are impassable
    for s in sim.yard.sources:
      doAssert not sim.yard.walkable(s.x, s.y), s.id

echo "test_sim: the parent may harvest a tall tree, always"
block:
  var sim = initSim(unitConfig())
  let parent = sim.parentSeat
  let ti = sim.sourceIndex(skTall, fApple)
  let (x, y) = sim.adjacentCell(ti)
  for attempt in 1 .. 20:
    sim.clearOrders()
    sim.yard.sources[ti].ripe = 3
    sim.cogs[parent].carry = -1
    sim.place(parent, x, y)
    sim.place(1 - parent, 1, 1)
    sim.setOrder(parent, pjProvide, fApple)
    let before = sim.tick
    sim.stepTick()
    doAssert sim.cogs[parent].carry == ord(fApple),
      "parent tall pick failed on attempt " & $attempt
    doAssert sim.eventsAt(before, "pick") == 1

echo "test_sim: the child may NEVER harvest a tall tree, and every attempt " &
  "emits a reach"
block:
  var sim = initSim(unitConfig())
  let child = sim.childSeat
  let ti = sim.sourceIndex(skTall, fBanana)
  let (x, y) = sim.adjacentCell(ti)
  var reaches = 0
  for attempt in 1 .. 40:
    sim.clearOrders()
    sim.yard.sources[ti].ripe = 3
    sim.cogs[child].carry = -1
    sim.place(child, x, y)
    sim.place(1 - child, 1, 1)
    sim.setChildOrder(child, cjShow, fBanana)
    sim.stepTick()
    doAssert sim.cogs[child].carry == -1, "the child picked a tall tree"
    doAssert sim.yard.sources[ti].ripe == 3, "the tall tree lost a fruit"
  for row in sim.events:
    if row{"k"}.getStr() == "reach":
      inc reaches
      doAssert row{"seat"}.getInt() == child
      doAssert row{"kind"}.getStr() == $skTall
  doAssert reaches > 0, "no reach events"
  doAssert sim.cumCounters[child].reachFails[fBanana] +
    sim.turnCounters[child].reachFails[fBanana] == 40

echo "test_sim: a child reach at a BARE tall tree still emits a reach"
block:
  # r1 review N6: with an empty canopy the adjacent-source scan skipped the tree
  # entirely, so the tick degraded to `wait` with no `reach`, no reachAttempts
  # and no reachFails — the signalling surface went silent exactly while the
  # child was trying hardest. The note is explicit: the child's tall-tree pick
  # ALWAYS fails and emits `reach`.
  var sim = initSim(unitConfig())
  let child = sim.childSeat
  let ti = sim.sourceIndex(skTall, fBanana)
  let (x, y) = sim.adjacentCell(ti)
  const Attempts = 12
  var firstRows = 0
  for attempt in 1 .. Attempts:
    sim.clearOrders()
    sim.yard.sources[ti].ripe = 0
    sim.yard.sources[ti].regrow = 0     # never ripens during the test
    sim.cogs[child].carry = -1
    sim.place(child, x, y)
    sim.place(1 - child, 1, 1)
    sim.setChildOrder(child, cjShow, fBanana)
    let before = sim.tick
    sim.stepTick()
    doAssert sim.cogs[child].carry == -1, "the child picked a bare tall tree"
    if attempt == 1:
      firstRows = sim.eventsAt(before, "reach")
  doAssert firstRows == 1, "a bare canopy emitted no reach row"
  doAssert sim.cumCounters[child].reachFails[fBanana] +
    sim.turnCounters[child].reachFails[fBanana] == Attempts,
    "a bare canopy was not counted as a failed reach"
  doAssert sim.cumCounters[child].reachAttempts[fBanana] +
    sim.turnCounters[child].reachAttempts[fBanana] == Attempts

  # The boundary: the parent CAN harvest, so an empty canopy is nothing to
  # reach for and its pick still degrades silently to `wait`.
  var psim = initSim(unitConfig())
  let parent = psim.parentSeat
  let pti = psim.sourceIndex(skTall, fApple)
  let (px, py) = psim.adjacentCell(pti)
  psim.clearOrders()
  psim.setOrder(parent, pjProvide, fApple)
  psim.yard.sources[pti].ripe = 0
  psim.cogs[parent].carry = -1
  psim.place(parent, px, py)
  psim.place(1 - parent, 1, 1)
  let eventsBefore = psim.events.len
  psim.resolvePick(parent)
  doAssert psim.cogs[parent].carry == -1
  doAssert psim.events.len == eventsBefore,
    "a bare canopy emitted an event for the parent"
  doAssert psim.cumCounters[parent].reachFails[fApple] +
    psim.turnCounters[parent].reachFails[fApple] == 0
  doAssert psim.cumCounters[parent].reachAttempts[fApple] +
    psim.turnCounters[parent].reachAttempts[fApple] == 0

echo "test_sim: the child's shrub pick succeeds at exactly " &
  "childShrubPickPermille (10 000 seeded attempts, +/-1 %)"
block:
  var cfg = unitConfig()
  cfg.childReachCooldownTicks = 0   # isolate the chance from the fumble
  var sim = initSim(cfg)
  let child = sim.childSeat
  let si = sim.sourceIndex(skShrub, fApple)
  let (x, y) = sim.adjacentCell(si)
  var picks = 0
  const Attempts = 10_000
  for attempt in 1 .. Attempts:
    sim.clearOrders()
    sim.yard.sources[si].ripe = 1
    sim.cogs[child].carry = -1
    sim.place(child, x, y)
    sim.place(1 - child, 1, 1)
    sim.setChildOrder(child, cjSeek, fApple)
    sim.stepTick()
    if sim.cogs[child].carry == ord(fApple):
      inc picks
  let permille = picks * 1000 div Attempts
  doAssert abs(permille - cfg.childShrubPickPermille) <= 10,
    "shrub pick rate " & $permille & " permille, want " &
    $cfg.childShrubPickPermille & " +/-10"

echo "test_sim: a failed shrub pick starts a 6-tick fumble in which every " &
  "action degrades to wait"
block:
  var sim = initSim(unitConfig())
  let child = sim.childSeat
  let si = sim.sourceIndex(skShrub, fApple)
  let (x, y) = sim.adjacentCell(si)
  var fumbled = false
  for attempt in 1 .. 200:
    sim.clearOrders()
    sim.yard.sources[si].ripe = 1
    sim.cogs[child].carry = -1
    sim.place(child, x, y)
    sim.place(1 - child, 1, 1)
    sim.setChildOrder(child, cjSeek, fApple)
    sim.stepTick()
    if sim.cogs[child].carry == -1 and sim.cogs[child].fumbleCd > 0:
      fumbled = true
      doAssert sim.cogs[child].fumbleCd == sim.config.childReachCooldownTicks,
        "fumble counter is " & $sim.cogs[child].fumbleCd
      # Every action degrades to wait for the whole cooldown.
      for i in 1 .. sim.config.childReachCooldownTicks:
        doAssert kernelAction(sim, child) == aWait,
          "the fumbling child acted on cooldown tick " & $i
        sim.stepTick()
      doAssert sim.cogs[child].fumbleCd == 0
      break
  doAssert fumbled, "no shrub pick ever failed in 200 attempts"

echo "test_sim: ground pickup always succeeds, for both roles; carryCap is 1"
block:
  for role in [rParent, rChild]:
    var sim = initSim(unitConfig())
    let seat = sim.seatOf[role]
    sim.clearOrders()
    sim.place(seat, 6, 6)
    sim.place(1 - seat, 1, 1)
    sim.cogs[seat].carry = -1
    sim.ground = @[GroundFruit(x: 6, y: 6, fruit: fBanana, ttl: 100)]
    if role == rParent: sim.setOrder(seat, pjProvide, fBanana)
    else: sim.setChildOrder(seat, cjSeek, fBanana)
    let intent = kernelAction(sim, seat)
    doAssert intent in {aPick, aEat}, $intent
    sim.resolvePick(seat)
    if role == rParent:
      doAssert sim.cogs[seat].carry == ord(fBanana)
      doAssert sim.ground.len == 0
      # carryCap 1: a second pick degrades to wait
      sim.ground = @[GroundFruit(x: 6, y: 6, fruit: fApple, ttl: 100)]
      sim.resolvePick(seat)
      doAssert sim.cogs[seat].carry == ord(fBanana), "carryCap broken"
      doAssert sim.ground.len == 1

echo "test_sim: drop is refused onto an occupied cell and onto a full mat"
block:
  var sim = initSim(unitConfig())
  let parent = sim.parentSeat
  sim.clearOrders()
  sim.place(parent, 6, 6)
  sim.place(1 - parent, 1, 1)
  sim.cogs[parent].carry = ord(fApple)
  sim.ground = @[GroundFruit(x: 6, y: 6, fruit: fBanana, ttl: 100)]
  sim.resolveDrop(parent)
  doAssert sim.cogs[parent].carry == ord(fApple), "dropped onto ground fruit"
  # a full mat
  sim.ground = @[]
  let matCells = sim.yard.basket
  for i in 0 ..< sim.config.basketCapacity:
    let c = matCells[i]
    sim.ground.add GroundFruit(x: c mod sim.yard.cols,
      y: c div sim.yard.cols, fruit: fApple, ttl: -1)
  let free = matCells[sim.config.basketCapacity]
  sim.place(parent, free mod sim.yard.cols, free div sim.yard.cols)
  sim.resolveDrop(parent)
  doAssert sim.cogs[parent].carry == ord(fApple), "dropped onto a full mat"

echo "test_sim: mat fruit never rots; floor fruit rots at exactly fruitLifetime"
block:
  var sim = initSim(unitConfig())
  sim.clearOrders()
  sim.place(0, 2, 2)
  sim.place(1, 21, 11)
  let mat = sim.yard.basket[0]
  sim.ground = @[
    GroundFruit(x: mat mod sim.yard.cols, y: mat div sim.yard.cols,
      fruit: fApple, ttl: -1),
    GroundFruit(x: 6, y: 6, fruit: fBanana, ttl: sim.config.fruitLifetime)
  ]
  for i in 1 .. sim.config.fruitLifetime - 1:
    sim.stepTick()
    doAssert sim.ground.len == 2, "fruit vanished early at tick " & $i
  sim.stepTick()
  doAssert sim.ground.len == 1, "floor fruit did not rot on time"
  doAssert sim.ground[0].ttl == -1, "the mat fruit rotted"
  var rots = 0
  for row in sim.events:
    if row{"k"}.getStr() == "rot": inc rots
  doAssert rots == 1, $rots

echo "test_sim: eat scores rewardPreferred / rewardOther for the child and " &
  "credits BOTH seats; a parent that eats wastes the fruit for 0"
block:
  var cfg = unitConfig()
  cfg.rewardOther = 1     # exercise both branches regardless of the shipped default
  var sim = initSim(cfg)
  let child = sim.childSeat
  let parent = sim.parentSeat
  let pref = sim.preference
  sim.clearOrders()
  sim.place(child, 6, 6)
  sim.place(parent, 18, 6)
  sim.cogs[child].carry = ord(pref)
  sim.resolveEat(child)
  doAssert sim.cogs[0].score == cfg.rewardPreferred
  doAssert sim.cogs[1].score == cfg.rewardPreferred, "the mirror is broken"
  sim.cogs[child].carry = ord(otherFruit(pref))
  sim.resolveEat(child)
  doAssert sim.cogs[0].score == cfg.rewardPreferred + cfg.rewardOther
  doAssert sim.cogs[0].score == sim.cogs[1].score
  let before = sim.cogs[0].score
  sim.cogs[parent].carry = ord(pref)
  sim.resolveEat(parent)
  doAssert sim.cogs[0].score == before, "a parent meal scored"
  doAssert sim.wasted[parent] == 1
  var wastes = 0
  for row in sim.events:
    if row{"k"}.getStr() == "waste": inc wastes
  doAssert wastes == 1

echo "test_sim: regrow lands at exactly tallRegrowTicks / shrubRegrowTicks " &
  "and is capped at capacity"
block:
  var sim = initSim(unitConfig())
  sim.clearOrders()
  sim.place(0, 2, 2)
  sim.place(1, 21, 11)
  let ti = sim.sourceIndex(skTall, fApple)
  let si = sim.sourceIndex(skShrub, fBanana)
  sim.yard.sources[ti].ripe = 0
  sim.yard.sources[ti].regrow = 0
  sim.yard.sources[si].ripe = 0
  sim.yard.sources[si].regrow = 0
  for i in 1 ..< sim.config.tallRegrowTicks:
    sim.stepTick()
    doAssert sim.yard.sources[ti].ripe == 0, "tall tree ripened early at " & $i
  sim.stepTick()
  doAssert sim.yard.sources[ti].ripe == 1
  for i in 1 .. sim.config.shrubRegrowTicks * 2:
    sim.stepTick()
  doAssert sim.yard.sources[ti].ripe == sim.config.tallCapacity,
    "tall tree exceeded or missed its cap: " & $sim.yard.sources[ti].ripe
  doAssert sim.yard.sources[si].ripe == sim.config.shrubCapacity,
    "shrub exceeded or missed its cap: " & $sim.yard.sources[si].ripe

echo "test_sim: a move is legal only every moveCooldown ticks"
block:
  var sim = initSim(unitConfig())
  let parent = sim.parentSeat
  sim.clearOrders()
  sim.place(parent, 12, 6)
  sim.place(1 - parent, 2, 2)
  sim.setOrder(parent, pjProvide, fApple)
  # A `provide` with an empty hand walks toward the nearest apple source, so the
  # kernel emits a move every tick it is allowed one and `wait` in between.
  var moves = 0
  var waits = 0
  const Ticks = 24
  for i in 1 .. Ticks:
    let action = kernelAction(sim, parent)
    if action in {aMoveN, aMoveE, aMoveS, aMoveW}: inc moves
    elif action == aWait: inc waits
    sim.stepTick()
  doAssert moves == Ticks div sim.config.moveCooldown,
    "the parent moved " & $moves & " times in " & $Ticks & " ticks"
  doAssert waits >= Ticks - moves - 2, $waits
  doAssert sim.turnCounters[parent].cellsWalked == moves,
    "cellsWalked " & $sim.turnCounters[parent].cellsWalked & " vs " & $moves

echo "test_sim: two cogs cannot share a cell and the lower slot wins"
block:
  var sim = initSim(unitConfig())
  sim.clearOrders()
  sim.place(0, 6, 6)
  sim.place(1, 8, 6)
  sim.resolveMove(0, aMoveE)     # slot 0 -> (7,6)
  sim.resolveMove(1, aMoveW)     # slot 1 wants (7,6): refused
  doAssert (sim.cogs[0].x, sim.cogs[0].y) == (7, 6)
  doAssert (sim.cogs[1].x, sim.cogs[1].y) == (8, 6),
    "the higher slot took the lower slot's cell"

echo "test_sim: fence, trees and shrubs are impassable"
block:
  var sim = initSim(unitConfig())
  sim.clearOrders()
  sim.place(0, 1, 1)
  sim.place(1, 21, 11)
  sim.resolveMove(0, aMoveW)
  doAssert (sim.cogs[0].x, sim.cogs[0].y) == (1, 1), "walked into the fence"
  let ti = sim.sourceIndex(skTall, fApple)
  let source = sim.yard.sources[ti]
  sim.place(0, source.x, source.y + 1)
  sim.resolveMove(0, aMoveN)
  doAssert (sim.cogs[0].x, sim.cogs[0].y) == (source.x, source.y + 1),
    "walked into a tall tree"

echo "test_sim: BFS is deterministic"
block:
  let sim = initSim(unitConfig())
  let targets = sim.yard.adjacentCells(sim.yard.sources[0].x,
    sim.yard.sources[0].y)
  let a = sim.yard.planTo(6, 6, targets)
  let b = sim.yard.planTo(6, 6, targets)
  doAssert a.step == b.step and a.dist == b.dist and a.reachable == b.reachable
  doAssert a.reachable

echo "test_sim: the daycare-fickle switch fires exactly once, at a turn " &
  "boundary in the drawn range"
block:
  for seed in 1 .. 12:
    let sim = playEpisode(variantConfig("daycare-fickle", seed))
    doAssert sim.switchTurn >= PreferenceSwitchFirstTurn
    doAssert sim.switchTurn <
      PreferenceSwitchFirstTurn + PreferenceSwitchTurnSpan
    var switches = 0
    for row in sim.events:
      if row{"k"}.getStr() != "switch": continue
      inc switches
      doAssert row{"turn"}.getInt() == sim.switchTurn
      doAssert (row{"t"}.getInt() + 1) mod sim.config.ticksPerTurn == 0,
        "the switch did not land on a turn boundary: " & $row
    doAssert switches == 1, $switches & " switch events on seed " & $seed
  for variant in ["daycare", "daycare-sparse", "daycare-swapped"]:
    let sim = playEpisode(variantConfig(variant, 4))
    doAssert sim.switchTurn == 0
    for row in sim.events:
      doAssert row{"k"}.getStr() != "switch", variant & " switched"

echo "test_sim: the same seed and the same order script give an identical " &
  "gameHash, twice in one process and across a fresh sim"
block:
  for variant in AllVariants:
    let cfg = variantConfig(variant, 5)
    let a = playEpisode(cfg)
    let b = playEpisode(cfg)
    doAssert a.gameHash() == b.gameHash(),
      variant & ": gameHash diverged in one process"
    # "across a fresh server": a config rebuilt from scratch, nothing shared.
    let fresh = playEpisode(variantConfig(variant, 5))
    doAssert a.gameHash() == fresh.gameHash(),
      variant & ": gameHash diverged across a fresh sim"
    doAssert a.tick == cfg.totalTicks()
    doAssert a.reason == "complete" and a.ending == "turn_limit"

echo "test_sim: every action a kernel emits is one of the eight vocabulary " &
  "values, and no state ever goes negative"
block:
  for variant in AllVariants:
    var sim = initSim(variantConfig(variant, 9))
    for turn in 1 .. sim.config.turns:
      sim.turn = turn
      var hedge = 0
      for seat in 0 .. 1:
        sim.applyOrder(seat, orderFor(sim, seat, prCareCare, hedge))
      for tick in 1 .. sim.config.ticksPerTurn:
        for seat in 0 .. 1:
          let action = kernelAction(sim, seat)
          doAssert action in {aMoveN, aMoveS, aMoveE, aMoveW, aPick, aDrop,
            aEat, aWait}, $action
        sim.stepTick()
        for seat in 0 .. 1:
          doAssert sim.cogs[seat].score >= 0
          doAssert sim.cogs[seat].carry >= -1 and sim.cogs[seat].carry <= 1
          doAssert sim.yard.walkable(sim.cogs[seat].x, sim.cogs[seat].y)
        for s in sim.yard.sources:
          doAssert s.ripe >= 0 and s.ripe <= s.capacity
        for g in sim.ground:
          doAssert g.ttl == -1 or g.ttl > 0
        doAssert sim.matTotal() <= sim.config.basketCapacity
      sim.closeTurn()

echo "test_sim: OK"
