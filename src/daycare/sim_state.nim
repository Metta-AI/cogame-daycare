## Sim state: the `Sim` object, the two deliberately separate RNG sub-streams,
## spawn placement, event emission, the behaviour accounting counters and
## `gameHash`.
##
## Fork of `coworld-ctf/src/ctf/sim_state.nim`.

import std/[json, strutils]
import sim_types, yard

type
  Sim* = object
    config*: GameConfig
    variant*: string
    yard*: Yard
    ground*: seq[GroundFruit]
    cogs*: array[2, Cog]
    roleOf*: array[2, Role]      ## slot -> role
    seatOf*: array[Role, int]    ## role -> slot
    names*: array[2, string]     ## in-game cog ALIAS by slot
    policyNames*: array[2, string] ## spectator-side policy names by slot
    colors*: array[2, string]

    preference*: Fruit
    switchTurn*: int             ## 0 = never (only daycare-fickle draws one)

    orders*: array[2, Order]     ## the standing order being walked
    lastOrders*: array[2, Order]

    turnCounters*: array[2, SpeciesCounters]  ## accumulating this turn
    prevTurnCounters*: array[2, SpeciesCounters] ## closed last turn
    cumCounters*: array[2, SpeciesCounters]

    tick*: int
    turn*: int                   ## the turn being played, 1-based
    turnsPlayed*: int
    done*: bool
    reason*: string              ## complete | deadline | forfeit
    ending*: string              ## turn_limit | deadline | forfeit

    guess*: Fruit
    hasGuess*: bool
    guessTurnsCorrect*: int

    childAte*: array[Fruit, int]
    delivered*: array[Fruit, int]
    stocked*: array[Fruit, int]
    wasted*: array[2, int]
    reaches*: array[2, int]

    events*: seq[JsonNode]
    frames*: seq[Frame]
    scoreSeries*: seq[array[3, int]]
    guessRightSeries*: seq[array[2, int]]
    beats*: seq[Beat]
    history*: seq[TurnRecord]

    reachStreakSrc*: array[2, string]  ## coalescing state per seat
    reachStreakTick*: array[2, int]
    reachStreakN*: array[2, int]

    rngLayout*: Rng
    rngSecret*: Rng
    pickRng*: Rng                ## seeded off the SEED, never rngSecret

proc emit*(sim: var Sim, row: JsonNode) =
  sim.events.add row

proc parentSeat*(sim: Sim): int = sim.seatOf[rParent]
proc childSeat*(sim: Sim): int = sim.seatOf[rChild]

proc groundAt*(sim: Sim, x, y: int): int =
  ## Index into `ground`, or -1.
  for i, g in sim.ground:
    if g.x == x and g.y == y:
      return i
  -1

proc matCount*(sim: Sim): array[Fruit, int] =
  for g in sim.ground:
    if sim.yard.isMat(g.x, g.y):
      inc result[g.fruit]

proc matTotal*(sim: Sim): int =
  let counts = sim.matCount()
  counts[fApple] + counts[fBanana]

proc initSim*(config: GameConfig, policyNames: array[2, string] = ["", ""]): Sim =
  ## Three RNG sub-streams, deliberately separate:
  ##   rngLayout = seededRng(seed)                    -> the mirror bit
  ##   rngSecret = seededRng(seed xor SecretRngSalt)  -> the preference and, in
  ##                                                     daycare-fickle, the
  ##                                                     switch turn
  ##   pickRng   = seededRng(seed xor PickRngSalt)    -> the child's shrub coin
  ## Nothing the parent can observe is ever drawn from rngSecret, and nothing
  ## the preference depends on is drawn from rngLayout. The shrub-pick coin is
  ## an OBSERVABLE — it lands in the `reach` event and in `reachFails` — so it
  ## gets its own stream off the seed rather than a draw from rngSecret (r1
  ## review, N4).
  result.config = config
  result.variant = config.variantId()
  result.rngLayout = seededRng(config.seed)
  result.rngSecret = seededRng(config.seed xor SecretRngSalt)

  let mirrored = result.rngLayout.rand(2) == 1
  result.yard = initYard(config, mirrored)

  result.preference =
    if config.forcePreference >= 0: Fruit(config.forcePreference)
    else: Fruit(result.rngSecret.rand(2))
  result.switchTurn =
    if config.preferenceSwitch:
      config.preferenceSwitchFirstTurn +
        result.rngSecret.rand(PreferenceSwitchTurnSpan)
    else: 0
  # Its own stream off the seed: no draw from rngSecret reaches it, so neither
  # the preference nor the switch draw can shift the pick sequence.
  result.pickRng = seededRng(config.seed xor PickRngSalt)

  result.roleOf[0] = config.slot0Role
  result.roleOf[1] = if config.slot0Role == rParent: rChild else: rParent
  result.seatOf[result.roleOf[0]] = 0
  result.seatOf[result.roleOf[1]] = 1

  # Aliases follow the ROLE, never the slot: Alder is always the parent and
  # Bramble always the child, whichever slot they sit in.
  for slot in 0 .. 1:
    if result.roleOf[slot] == rParent:
      result.names[slot] = "Alder"
      result.colors[slot] = "blue"
    else:
      result.names[slot] = "Bramble"
      result.colors[slot] = "yellow"
    result.policyNames[slot] =
      if policyNames[slot].len > 0: policyNames[slot]
      elif slot < config.players.len and config.players[slot].name.len > 0:
        config.players[slot].name
      else: result.names[slot]

  for slot in 0 .. 1:
    let cellIndex = result.yard.spawns[ord(result.roleOf[slot])]
    result.cogs[slot] = Cog(
      x: cellIndex mod result.yard.cols,
      y: cellIndex div result.yard.cols,
      carry: -1,
      score: 0
    )
  result.tick = 0
  result.turn = 0
  result.reason = ""
  result.ending = ""
  for seat in 0 .. 1:
    result.reachStreakTick[seat] = -1000

proc gameHash*(sim: Sim): uint64 =
  ## Everything a rule change could move. `tests/test_sim.nim` asserts the same
  ## seed and the same order script produce an identical hash after a full
  ## episode, twice in one process and across a fresh server.
  result = 0xcbf29ce484222325'u64
  proc mix(h: var uint64, v: int) =
    h = (h xor uint64(v + 1)) * 0x100000001b3'u64
  mix(result, int(sim.yard.layoutHash() and 0x7FFF_FFFF'u64))
  mix(result, sim.tick)
  mix(result, sim.turnsPlayed)
  mix(result, ord(sim.preference))
  mix(result, sim.switchTurn)
  mix(result, sim.guessTurnsCorrect)
  for seat in 0 .. 1:
    let c = sim.cogs[seat]
    for v in [c.x, c.y, c.carry, c.score, c.moveCd, c.fumbleCd]:
      mix(result, v)
    mix(result, sim.wasted[seat])
    mix(result, sim.reaches[seat])
  for f in Fruit:
    mix(result, sim.childAte[f])
    mix(result, sim.delivered[f])
    mix(result, sim.stocked[f])
  for s in sim.yard.sources:
    mix(result, s.ripe)
    mix(result, s.regrow)
  for g in sim.ground:
    for v in [g.x, g.y, ord(g.fruit), g.ttl]:
      mix(result, v)
  mix(result, sim.events.len)
  mix(result, sim.frames.len)

# ---------------------------------------------------------------------------
# behaviour accounting (step 8)
# ---------------------------------------------------------------------------

proc addCounters*(dst: var SpeciesCounters, src: SpeciesCounters) =
  for f in Fruit:
    dst.adjacentTicks[f] += src.adjacentTicks[f]
    dst.reachAttempts[f] += src.reachAttempts[f]
    dst.reachFails[f] += src.reachFails[f]
    dst.groundPasses[f] += src.groundPasses[f]
    dst.ate[f] += src.ate[f]
    dst.carriedTicks[f] += src.carriedTicks[f]
    dst.delivered[f] += src.delivered[f]
    dst.stocked[f] += src.stocked[f]
  dst.wasted += src.wasted
  dst.cellsWalked += src.cellsWalked
  dst.idleTicks += src.idleTicks

proc countersJson*(c: SpeciesCounters): JsonNode =
  %*{
    "adjacentTicks": {"apple": c.adjacentTicks[fApple],
                      "banana": c.adjacentTicks[fBanana]},
    "reachAttempts": {"apple": c.reachAttempts[fApple],
                      "banana": c.reachAttempts[fBanana]},
    "reachFails": {"apple": c.reachFails[fApple],
                   "banana": c.reachFails[fBanana]},
    "groundPasses": {"apple": c.groundPasses[fApple],
                     "banana": c.groundPasses[fBanana]},
    "ate": {"apple": c.ate[fApple], "banana": c.ate[fBanana]},
    "carriedTicks": {"apple": c.carriedTicks[fApple],
                     "banana": c.carriedTicks[fBanana]},
    "cellsWalked": c.cellsWalked,
    "idleTicks": c.idleTicks
  }

proc parentCountersJson*(c: SpeciesCounters): JsonNode =
  ## The shape the CHILD gets about the parent.
  %*{
    "delivered": {"apple": c.delivered[fApple], "banana": c.delivered[fBanana]},
    "stocked": {"apple": c.stocked[fApple], "banana": c.stocked[fBanana]},
    "adjacentTicks": {"apple": c.adjacentTicks[fApple],
                      "banana": c.adjacentTicks[fBanana]},
    "carriedTicks": {"apple": c.carriedTicks[fApple],
                     "banana": c.carriedTicks[fBanana]},
    "wasted": c.wasted,
    "cellsWalked": c.cellsWalked,
    "idleTicks": c.idleTicks
  }

proc jobName*(sim: Sim, seat: int): string =
  if sim.roleOf[seat] == rParent: $sim.orders[seat].pjob
  else: $sim.orders[seat].cjob

proc logLine*(sim: Sim, text: string) =
  echo "daycare: t", sim.tick, " ", text.strip()
