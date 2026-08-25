## The gameplay core: the nine numbered steps of one tick, the turn boundary,
## scoring, the per-seat observation and `results.json`.
##
## Fork of `coworld-ctf/src/ctf/sim.nim`: this module imports and RE-EXPORTS the
## split modules, so `import daycare/sim` still sees everything.

import std/[json]
import sim_types, yard, sim_state, events, kernel, sim_config
export sim_types, yard, sim_state, events, kernel, sim_config

const
  ParentJobNames* = [$pjProvide, $pjStock, $pjWatch, $pjIdle]
  ChildJobNames* = [$cjSeek, $cjShow, $cjGraze, $cjBeg, $cjIdle]
  FruitNames* = [$fApple, $fBanana]

proc namedFruit(sim: Sim, seat: int): tuple[named: bool, f: Fruit] =
  let order = sim.orders[seat]
  if sim.roleOf[seat] == rParent:
    if order.pjob in {pjProvide, pjStock} and order.hasFruit:
      return (true, order.fruit)
  else:
    if order.cjob in {cjSeek, cjShow} and order.hasFruit:
      return (true, order.fruit)
  (false, fApple)

proc requiresFruit*(role: Role, order: Order): bool =
  if role == rParent: order.pjob in {pjProvide, pjStock}
  else: order.cjob in {cjSeek, cjShow}

proc validateOrder*(sim: Sim, seat: int, order: Order) =
  ## Every field either baseline emits is inside its declared enum for its role
  ## BY CONSTRUCTION; this is the assertion that makes that true of an LLM reply
  ## too, and the retry hint is built from the failure.
  let role = sim.roleOf[seat]
  if requiresFruit(role, order) and not order.hasFruit:
    raise newException(DaycareError,
      "job " & (if role == rParent: $order.pjob else: $order.cjob) &
      " needs a fruit")
  if role == rParent and not order.hasGuess:
    raise newException(DaycareError, "the parent must send a guess every turn")

proc boundaryTick*(sim: Sim): int =
  ## The last RECORDED tick. Turn-boundary rows (`turn`, `guess`, `switch`,
  ## `feast`, `gameover`, the guess series) are stamped here rather than at
  ## `sim.tick`, which is one past the last frame: a beat past the last frame
  ## places its scrubber marker beyond 100% and the guess tape's final chip
  ## would never light.
  max(0, sim.tick - 1)

proc applyOrder*(sim: var Sim, seat: int, order0: Order) =
  ## Install a seat's standing order for the turn about to be played.
  ## Decisions are SIMULTANEOUS: neither seat sees the other's order.
  var order = order0
  order.hunch = cleanHunch(order.hunch)
  order.notes = cleanNotes(order.notes)
  sim.validateOrder(seat, order)
  sim.orders[seat] = order
  sim.lastOrders[seat] = order
  let role = sim.roleOf[seat]
  sim.emit orderRow(
    sim.tick, seat, sim.turn, role,
    (if role == rParent: $order.pjob else: $order.cjob),
    (if order.hasFruit: $order.fruit else: ""),
    (if role == rParent and order.hasGuess: $order.guess else: ""),
    order.source, order.hunch, order.notes, order.latencyMs)
  if role == rParent and order.hasGuess:
    let changed = (not sim.hasGuess) or sim.guess != order.guess
    sim.guess = order.guess
    sim.hasGuess = true
    if changed:
      let correct = sim.guess == sim.preference
      sim.emit guessRow(sim.boundaryTick, sim.turn, sim.guess, correct)
      sim.beats.add Beat(t: sim.boundaryTick, kind: "guess", g: $sim.guess,
        ok: correct)

# ---------------------------------------------------------------------------
# one tick, nine steps
# ---------------------------------------------------------------------------

proc emitReach(sim: var Sim, seat: int, source: SourceState) =
  ## Coalesced reach rows: the first failure at a source emits immediately, then
  ## at most one row per ReachCoalesceTicks while the streak continues.
  inc sim.reaches[seat]
  inc sim.reachStreakN[seat]
  if sim.reachStreakSrc[seat] != source.id or
      sim.tick - sim.reachStreakTick[seat] >= ReachCoalesceTicks:
    sim.emit reachRow(sim.tick, seat, source.fruit, source.id, source.kind,
      sim.reachStreakN[seat])
    sim.reachStreakSrc[seat] = source.id
    sim.reachStreakTick[seat] = sim.tick
    sim.reachStreakN[seat] = 0

proc resolvePick*(sim: var Sim, seat: int) =
  var cog = sim.cogs[seat]
  if cog.carry >= 0:
    return                        # a full hand degrades `pick` to `wait`
  let here = sim.groundAt(cog.x, cog.y)
  if here >= 0:
    # Ground fruit on the cog's own cell: always succeeds, for both roles.
    let g = sim.ground[here]
    sim.ground.delete(here)
    cog.carry = ord(g.fruit)
    cog.carryFromParent = g.fromParent
    sim.cogs[seat] = cog
    sim.emit pickRow(sim.tick, seat, g.fruit, "", "ground", g.x, g.y)
    return
  let (named, wanted) = sim.namedFruit(seat)
  var chosen = -1
  for d in 0 .. 3:
    let si = sim.yard.sourceIndexAt(cog.x + DirDx[d], cog.y + DirDy[d])
    if si < 0: continue
    if sim.yard.sources[si].ripe < 1: continue
    if named and sim.yard.sources[si].fruit != wanted: continue
    chosen = si
    break
  if chosen < 0:
    return                        # nothing to reach for: degrades to `wait`
  let source = sim.yard.sources[chosen]
  inc sim.turnCounters[seat].reachAttempts[source.fruit]
  if sim.roleOf[seat] == rChild:
    if source.kind == skTall:
      # The child may NEVER harvest a tall tree. The futile reach is the game's
      # whole signalling surface and must stay cheap: it costs the tick only.
      inc sim.turnCounters[seat].reachFails[source.fruit]
      sim.emitReach(seat, source)
      return
    if not sim.pickRng.chancePermille(sim.config.childShrubPickPermille):
      inc sim.turnCounters[seat].reachFails[source.fruit]
      sim.emitReach(seat, source)
      cog.fumbleCd = sim.config.childReachCooldownTicks + 1
      sim.cogs[seat] = cog
      return
  dec sim.yard.sources[chosen].ripe
  cog.carry = ord(source.fruit)
  cog.carryFromParent = false
  sim.cogs[seat] = cog
  sim.emit pickRow(sim.tick, seat, source.fruit, source.id, $source.kind,
    source.x, source.y)

proc resolveDrop*(sim: var Sim, seat: int) =
  var cog = sim.cogs[seat]
  if cog.carry < 0:
    return
  if sim.groundAt(cog.x, cog.y) >= 0:
    return
  let onMat = sim.yard.isMat(cog.x, cog.y)
  if onMat and sim.matTotal() >= sim.config.basketCapacity:
    return
  let f = Fruit(cog.carry)
  let child = sim.cogs[sim.childSeat]
  sim.ground.add GroundFruit(
    x: cog.x, y: cog.y, fruit: f,
    ttl: (if onMat: -1 else: sim.config.fruitLifetime),
    fromParent: sim.roleOf[seat] == rParent
  )
  cog.carry = -1
  cog.carryFromParent = false
  sim.cogs[seat] = cog
  let near =
    if onMat: "basket"
    elif seat != sim.childSeat and chebyshev(cog.x, cog.y, child.x, child.y) <= 1:
      "child"
    else: "floor"
  sim.emit dropRow(sim.tick, seat, f, cog.x, cog.y, near)
  if sim.roleOf[seat] == rParent and onMat:
    inc sim.stocked[f]
    inc sim.turnCounters[seat].stocked[f]

proc resolveEat*(sim: var Sim, seat: int) =
  var cog = sim.cogs[seat]
  var f: Fruit
  var fromParent = false
  var ok = false
  if cog.carry >= 0:
    f = Fruit(cog.carry)
    fromParent = cog.carryFromParent
    cog.carry = -1
    cog.carryFromParent = false
    ok = true
  else:
    let here = sim.groundAt(cog.x, cog.y)
    if here >= 0:
      f = sim.ground[here].fruit
      fromParent = sim.ground[here].fromParent
      sim.ground.delete(here)
      ok = true
  if not ok:
    return
  sim.cogs[seat] = cog
  if sim.roleOf[seat] == rChild:
    let preferred = f == sim.preference
    let pts =
      if preferred: sim.config.rewardPreferred else: sim.config.rewardOther
    # Credited to BOTH seats: the parent is rewarded THROUGH the child being
    # fed, for every meal, whoever picked it.
    sim.cogs[0].score += pts
    sim.cogs[1].score += pts
    inc sim.childAte[f]
    inc sim.turnCounters[seat].ate[f]
    if fromParent:
      inc sim.delivered[f]
      inc sim.turnCounters[sim.parentSeat].delivered[f]
    sim.emit eatRow(sim.tick, seat, f, preferred, pts)
  else:
    # A parent that eats destroys the fruit for 0. Never rewarded — it exists
    # so the naive "food is good, eat food" failure mode stays legible.
    inc sim.wasted[seat]
    inc sim.turnCounters[seat].wasted
    sim.emit wasteRow(sim.tick, seat, f, cog.x, cog.y)

proc resolveMove*(sim: var Sim, seat: int, action: Action) =
  var cog = sim.cogs[seat]
  let d =
    case action
    of aMoveN: 0
    of aMoveE: 1
    of aMoveS: 2
    of aMoveW: 3
    else: -1
  if d < 0:
    return
  let nx = cog.x + DirDx[d]
  let ny = cog.y + DirDy[d]
  if not sim.yard.walkable(nx, ny):
    return                        # illegal move degrades to `wait`
  let other = sim.cogs[1 - seat]
  if other.x == nx and other.y == ny:
    return                        # against the LIVE board: the lower slot wins
  cog.x = nx
  cog.y = ny
  cog.moveCd = sim.config.moveCooldown
  sim.cogs[seat] = cog
  inc sim.turnCounters[seat].cellsWalked

proc recordFrame(sim: var Sim) =
  var frame = Frame(t: sim.tick)
  for seat in 0 .. 1:
    let c = sim.cogs[seat]
    frame.c.add c.x
    frame.c.add c.y
    frame.c.add c.carry
    frame.c.add c.score
  for g in sim.ground:
    frame.g.add g.x
    frame.g.add g.y
    frame.g.add ord(g.fruit)
    frame.g.add g.ttl
  for s in sim.yard.sources:
    frame.s.add s.ripe
    frame.s.add max(0, s.regrowTicks - s.regrow)
  let mat = sim.matCount()
  frame.b = [mat[fApple], mat[fBanana]]
  sim.frames.add frame
  sim.scoreSeries.add [sim.tick, sim.cogs[0].score, sim.cogs[1].score]

proc stepTick*(sim: var Sim) =
  ## The nine numbered steps, in this order. Within a step, seats resolve in
  ## ascending slot order and sources in the fixed order tall trees then shrubs,
  ## each by (row, col) — which is `yard.sources` order.

  # 1. Regrow.
  for i in 0 ..< sim.yard.sources.len:
    if sim.yard.sources[i].ripe >= sim.yard.sources[i].capacity:
      continue
    inc sim.yard.sources[i].regrow
    if sim.yard.sources[i].regrow >= sim.yard.sources[i].regrowTicks:
      inc sim.yard.sources[i].ripe
      sim.yard.sources[i].regrow = 0
      sim.emit ripenRow(sim.tick, sim.yard.sources[i].id,
        sim.yard.sources[i].fruit)

  # 2. Kernel intent.
  var actions: array[2, Action]
  for seat in 0 .. 1:
    actions[seat] = sim.kernelAction(seat)

  # 3. `pick` resolves.
  for seat in 0 .. 1:
    if actions[seat] == aPick:
      sim.resolvePick(seat)

  # 4. `drop` resolves.
  for seat in 0 .. 1:
    if actions[seat] == aDrop:
      sim.resolveDrop(seat)

  # 5. `eat` resolves.
  var ateThisTick: array[2, bool]
  for seat in 0 .. 1:
    if actions[seat] == aEat:
      let before = sim.childAte[fApple] + sim.childAte[fBanana] +
        sim.wasted[0] + sim.wasted[1]
      sim.resolveEat(seat)
      ateThisTick[seat] = (sim.childAte[fApple] + sim.childAte[fBanana] +
        sim.wasted[0] + sim.wasted[1]) != before

  # 6. Moves resolve.
  for seat in 0 .. 1:
    sim.resolveMove(seat, actions[seat])

  # 7. Ground fruit ages.
  var survivors: seq[GroundFruit]
  for g in sim.ground:
    if g.ttl > 0:
      var next = g
      dec next.ttl
      if next.ttl == 0:
        sim.emit rotRow(sim.tick, g.fruit, g.x, g.y)
        continue
      survivors.add next
    else:
      survivors.add g             # mat fruit (ttl == -1) never rots
  sim.ground = survivors

  # 8. Behaviour accounting.
  for seat in 0 .. 1:
    let cog = sim.cogs[seat]
    var adjacent: array[Fruit, bool]
    for d in 0 .. 3:
      let si = sim.yard.sourceIndexAt(cog.x + DirDx[d], cog.y + DirDy[d])
      if si >= 0:
        adjacent[sim.yard.sources[si].fruit] = true
    for f in Fruit:
      if adjacent[f]:
        inc sim.turnCounters[seat].adjacentTicks[f]
    if cog.carry >= 0:
      inc sim.turnCounters[seat].carriedTicks[Fruit(cog.carry)]
    let here = sim.groundAt(cog.x, cog.y)
    if here >= 0 and not ateThisTick[seat]:
      inc sim.turnCounters[seat].groundPasses[sim.ground[here].fruit]
    if actions[seat] == aWait:
      inc sim.turnCounters[seat].idleTicks
    if sim.cogs[seat].moveCd > 0:
      dec sim.cogs[seat].moveCd
    if sim.cogs[seat].fumbleCd > 0:
      dec sim.cogs[seat].fumbleCd

  # 9. Record. The frame is stamped with the 0-BASED tick index the events of
  # this tick already carry, so `frames[i].t == i` and a seek is an array index.
  sim.recordFrame()
  inc sim.tick

proc closeTurn*(sim: var Sim) =
  ## At a turn boundary: close the accounting, emit `turn`, apply the fickle
  ## preference switch, and record the beat timeline row.
  sim.turnsPlayed = sim.turn
  let guessRight = sim.hasGuess and sim.guess == sim.preference
  if guessRight:
    inc sim.guessTurnsCorrect
  sim.guessRightSeries.add [sim.boundaryTick, (if guessRight: 1 else: 0)]

  var reaches: array[Fruit, int]
  for f in Fruit:
    reaches[f] = sim.turnCounters[sim.childSeat].reachFails[f] +
      sim.turnCounters[sim.parentSeat].reachFails[f]
  sim.emit turnRow(sim.boundaryTick, sim.turn, [sim.cogs[0].score, sim.cogs[1].score],
    (if sim.hasGuess: $sim.guess else: ""), guessRight,
    sim.turnCounters[sim.childSeat].ate,
    sim.turnCounters[sim.parentSeat].delivered, reaches)
  sim.beats.add Beat(t: sim.boundaryTick, kind: "turn", n: sim.turn)
  if sim.turnCounters[sim.childSeat].ate[sim.preference] >= 2:
    # `feast`: a turn in which the child ate >= 2 preferred fruit.
    sim.beats.add Beat(t: sim.boundaryTick, kind: "feast",
      n: sim.turnCounters[sim.childSeat].ate[sim.preference])

  sim.history.add TurnRecord(
    turn: sim.turn,
    guess: sim.guess,
    hasGuess: sim.hasGuess,
    childAte: sim.turnCounters[sim.childSeat].ate,
    delivered: sim.turnCounters[sim.parentSeat].delivered,
    score: sim.cogs[0].score
  )

  for seat in 0 .. 1:
    sim.prevTurnCounters[seat] = sim.turnCounters[seat]
    sim.cumCounters[seat].addCounters(sim.turnCounters[seat])
    sim.turnCounters[seat] = SpeciesCounters()

  if sim.config.preferenceSwitch and sim.switchTurn > 0 and
      sim.turn == sim.switchTurn:
    let before = sim.preference
    sim.preference = otherFruit(sim.preference)
    sim.emit switchRow(sim.boundaryTick, sim.turn, before, sim.preference)
    sim.beats.add Beat(t: sim.boundaryTick, kind: "switch",
      g: $sim.preference)

proc settle*(sim: var Sim, reason, ending: string) =
  if sim.done:
    return
  sim.done = true
  sim.reason = reason
  sim.ending = ending
  sim.beats.add Beat(t: sim.boundaryTick, kind: "gameover")
  sim.emit endRow(sim.boundaryTick, reason, ending,
    [sim.cogs[0].score, sim.cogs[1].score], sim.preference,
    sim.guessTurnsCorrect, sim.turnsPlayed)

proc endEarly*(sim: var Sim) =
  ## The play deadline fired between turns: score what was played and settle.
  sim.settle("deadline", "deadline")

proc forfeit*(sim: var Sim) =
  ## No seat connected within playerConnectTimeoutSeconds. All zero; results and
  ## the replay are still written.
  sim.cogs[0].score = 0
  sim.cogs[1].score = 0
  sim.settle("forfeit", "forfeit")

proc playTurn*(sim: var Sim) =
  for _ in 1 .. sim.config.ticksPerTurn:
    sim.stepTick()
  sim.closeTurn()

# ---------------------------------------------------------------------------
# the per-seat observation
# ---------------------------------------------------------------------------

proc sourcesJson(sim: Sim): JsonNode =
  result = newJArray()
  for s in sim.yard.sources:
    result.add %*{
      "id": s.id, "kind": $s.kind, "fruit": $s.fruit,
      "cell": [s.x, s.y], "ripe": s.ripe,
      "nextRipeIn": max(0, s.regrowTicks - s.regrow)
    }

proc groundJson(sim: Sim): JsonNode =
  result = newJArray()
  for g in sim.ground:
    result.add %*{"cell": [g.x, g.y], "fruit": $g.fruit, "ttl": g.ttl}

proc basketJson(sim: Sim): JsonNode =
  var cells = newJArray()
  for c in sim.yard.basket:
    cells.add %[c mod sim.yard.cols, c div sim.yard.cols]
  let mat = sim.matCount()
  %*{"cells": cells, "apple": mat[fApple], "banana": mat[fBanana],
     "capacity": sim.config.basketCapacity}

proc historyJson(sim: Sim, role: Role): JsonNode =
  ## The parent gets its own past guesses; the CHILD MUST NOT — the parent's
  ## guess, past or pending, is hidden from it (test_noleak gate (b)).
  result = newJArray()
  for h in sim.history:
    var row = %*{
      "turn": h.turn,
      "childAte": {"apple": h.childAte[fApple], "banana": h.childAte[fBanana]},
      "delivered": {"apple": h.delivered[fApple],
                    "banana": h.delivered[fBanana]},
      "score": h.score
    }
    if role == rParent:
      row["guess"] = %(if h.hasGuess: $h.guess else: "")
    result.add row

proc lastOrderJson(sim: Sim, seat: int): JsonNode =
  let order = sim.lastOrders[seat]
  let role = sim.roleOf[seat]
  result = %*{
    "job": (if role == rParent: $order.pjob else: $order.cjob),
    "source": $order.source
  }
  if order.hasFruit:
    result["fruit"] = %($order.fruit)
  if role == rParent and order.hasGuess:
    result["guess"] = %($order.guess)

proc reachRuleText(sim: Sim): string =
  "you may harvest tall trees and shrubs; the child may NEVER harvest a tall " &
    "tree and picks a shrub only " &
    $(sim.config.childShrubPickPermille div 10) &
    "% of attempts (this variant)"

proc playerStateJson*(sim: Sim, slot: int): JsonNode =
  ## The `state` frame. Every number in it is visible to that seat; NOTHING
  ## else is. `tests/test_noleak.nim` asserts the parent's frame carries neither
  ## the preference nor the child's `hunch`/`notes`, and the child's frame
  ## carries neither the parent's `guess` nor its `hunch`/`notes`.
  let role = sim.roleOf[slot]
  let me = sim.cogs[slot]
  let otherSlot = 1 - slot
  let other = sim.cogs[otherSlot]
  result = %*{
    "type": "state",
    "protocol": PlayerProtocol,
    "slot": slot,
    "role": $role,
    "name": sim.names[slot],
    "turn": sim.turn,
    "turns": sim.config.turns,
    "ticksPerTurn": sim.config.ticksPerTurn,
    "tick": sim.tick,
    "yard": {"cols": sim.yard.cols, "rows": sim.yard.rows,
             "variant": sim.variant, "mirrored": sim.yard.mirrored},
    "sources": sim.sourcesJson(),
    "ground": sim.groundJson(),
    "basket": sim.basketJson(),
    "history": sim.historyJson(role),
    "notes": sim.lastOrders[slot].notes,
    "done": sim.done
  }
  var you = %*{
    "cell": [me.x, me.y],
    "carrying": (if me.carry < 0: newJNull() else: %($Fruit(me.carry))),
    "score": me.score,
    "par": sim.config.parScore(),
    "lastOrder": sim.lastOrderJson(slot)
  }
  if role == rParent:
    you["delivered"] = %*{"apple": sim.delivered[fApple],
                          "banana": sim.delivered[fBanana]}
    you["stocked"] = %*{"apple": sim.stocked[fApple],
                        "banana": sim.stocked[fBanana]}
    you["wasted"] = %sim.wasted[slot]
    result["you"] = you
    result["child"] = %*{
      "alias": sim.names[otherSlot],
      "cell": [other.x, other.y],
      "carrying": (if other.carry < 0: newJNull()
                   else: %($Fruit(other.carry))),
      "score": other.score,
      "lastTurn": countersJson(sim.prevTurnCounters[otherSlot]),
      "cumulative": countersJson(sim.cumCounters[otherSlot])
    }
    result["rules"] = %*{
      "reach": sim.reachRuleText(),
      "reward": "the child scores " & $sim.config.rewardPreferred &
        " for eating the fruit it prefers and " & $sim.config.rewardOther &
        " for the other; YOUR SCORE IS THE SAME NUMBER",
      "wasted": "if you eat a fruit yourself it is destroyed and nobody scores",
      "carryCap": sim.config.carryCap,
      "moveCooldown": sim.config.moveCooldown,
      "fruitLifetime": sim.config.fruitLifetime,
      "basketNoRot": true,
      "channel": "there is NO message channel: you cannot talk to the child " &
        "and it cannot talk to you",
      "hidden": "the child's preference is not shown to you anywhere"
    }
  else:
    # Visible to the child: everything above PLUS its own preference and the
    # two reward values. Hidden: the parent's guess, order, hunch and notes.
    you["preference"] = %($sim.preference)
    you["rewardPreferred"] = %sim.config.rewardPreferred
    you["rewardOther"] = %sim.config.rewardOther
    you["ate"] = %*{"apple": sim.childAte[fApple],
                    "banana": sim.childAte[fBanana]}
    you["reachFails"] = %*{
      "apple": sim.cumCounters[slot].reachFails[fApple],
      "banana": sim.cumCounters[slot].reachFails[fBanana]}
    you["shrubPickChancePermille"] = %sim.config.childShrubPickPermille
    you["reachCooldownTicks"] = %sim.config.childReachCooldownTicks
    result["you"] = you
    result["parent"] = %*{
      "alias": sim.names[otherSlot],
      "cell": [other.x, other.y],
      "carrying": (if other.carry < 0: newJNull()
                   else: %($Fruit(other.carry))),
      "score": other.score,
      "lastTurn": parentCountersJson(sim.prevTurnCounters[otherSlot]),
      "cumulative": parentCountersJson(sim.cumCounters[otherSlot])
    }
    result["rules"] = %*{
      "reach": "you may NEVER harvest a tall tree; a shrub works only " &
        $(sim.config.childShrubPickPermille div 10) & "% of attempts, and a " &
        "failed shrub pick costs you " &
        $sim.config.childReachCooldownTicks & " ticks",
      "reward": "you score " & $sim.config.rewardPreferred &
        " for eating the fruit you prefer and " & $sim.config.rewardOther &
        " for the other; the parent's score is exactly the same number",
      "carryCap": sim.config.carryCap,
      "moveCooldown": sim.config.moveCooldown,
      "fruitLifetime": sim.config.fruitLifetime,
      "basketNoRot": true,
      "channel": "there is NO message channel: you cannot talk to the " &
        "parent and it cannot talk to you",
      "hidden": "the parent cannot see what you prefer; it can only watch you"
    }

proc resultsJson*(sim: Sim): JsonNode =
  ## Arrays indexed by SLOT, always length 2, except `child_ate` and
  ## `delivered` which are indexed [apple, banana].
  let par = sim.config.parScore()
  %*{
    "names": [sim.policyNames[0], sim.policyNames[1]],
    "aliases": [sim.names[0], sim.names[1]],
    "roles": [$sim.roleOf[0], $sim.roleOf[1]],
    "scores": [sim.cogs[0].score, sim.cogs[1].score],
    "win": [sim.cogs[0].score >= par, sim.cogs[1].score >= par],
    "preference": $sim.preference,
    "child_ate": [sim.childAte[fApple], sim.childAte[fBanana]],
    "delivered": [sim.delivered[fApple], sim.delivered[fBanana]],
    "wasted": [sim.wasted[0], sim.wasted[1]],
    "reaches": [sim.reaches[0], sim.reaches[1]],
    "guess_turns_correct": sim.guessTurnsCorrect,
    "turns": sim.turnsPlayed,
    "par": par,
    "reason": sim.reason,
    "ending": sim.ending
  }
