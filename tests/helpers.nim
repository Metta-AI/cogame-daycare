## Shared test helpers. Not a test itself: `nim r` on it compiles and exits.

import std/[json]
import daycare/[sim, scripted, replays, broadcast, global]
export sim, scripted, replays, broadcast, global, json

const AllVariants* = ["daycare", "daycare-sparse", "daycare-fickle",
  "daycare-swapped"]

proc variantConfig*(variant: string, seed: int): GameConfig =
  ## Exactly the four shipped variants' `game_config`, so a test drift from the
  ## manifest shows up as a failing test rather than a dead league episode.
  result = defaultGameConfig()
  result.seed = seed
  result.tokens = @["token-0", "token-1"]
  result.players = @[PlayerConfig(name: "Alder"), PlayerConfig(name: "Bramble")]
  case variant
  of "daycare":
    discard
  of "daycare-sparse":
    result.shrubs = 2
    result.childShrubPickPermille = 150
  of "daycare-fickle":
    result.preferenceSwitch = true
  of "daycare-swapped":
    result.slot0Role = rChild
  else:
    raise newException(DaycareError, "unknown variant: " & variant)
  doAssert result.variantId() == variant,
    "variantConfig(" & variant & ") derives " & result.variantId()

type
  Pairing* = enum
    prCareCare = "caretaker/caretaker"
    prStubbornParent = "stubborn parent"
    prStubbornChild = "stubborn child"
    prStubbornBoth = "stubborn/stubborn"
    prIdleParent = "idle parent (test only)"
    prHedgeParent = "hedge parent (test only)"

proc orderFor*(sim: Sim, seat: int, pairing: Pairing, hedge: var int): Order =
  ## The pairings the oracle needs. `idle` and `hedge` are TEST-ONLY parent
  ## orders for feasibility gates (d) and (e); `hedge` is the "stock both, let
  ## the child choose" parent, expressed with the shipped `stock` job.
  let isParent = sim.roleOf[seat] == rParent
  case pairing
  of prCareCare: scriptedOrder(sim, seat, skCaretaker)
  of prStubbornParent:
    scriptedOrder(sim, seat, if isParent: skStubborn else: skCaretaker)
  of prStubbornChild:
    scriptedOrder(sim, seat, if isParent: skCaretaker else: skStubborn)
  of prStubbornBoth: scriptedOrder(sim, seat, skStubborn)
  of prIdleParent:
    if isParent:
      Order(pjob: pjIdle, guess: fApple, hasGuess: true, source: osScripted,
        hunch: "not my problem")
    else:
      scriptedOrder(sim, seat, skCaretaker)
  of prHedgeParent:
    if isParent:
      let f = if hedge mod 2 == 0: fApple else: fBanana
      inc hedge
      Order(pjob: pjStock, fruit: f, hasFruit: true, guess: f, hasGuess: true,
        source: osScripted, hunch: "stocking both")
    else:
      scriptedOrder(sim, seat, skCaretaker)

proc playEpisode*(config: GameConfig, pairing = prCareCare): Sim =
  ## A whole headless episode, orders installed at each turn boundary exactly as
  ## the server's turn loop does it.
  result = initSim(config, ["daycare-attentive", "daycare-caretaker"])
  var hedge = 0
  for turn in 1 .. config.turns:
    result.turn = turn
    for seat in 0 .. 1:
      result.applyOrder(seat, orderFor(result, seat, pairing, hedge))
    result.playTurn()
  result.settle("complete", "turn_limit")

proc totalScore*(sim: Sim): int = sim.cogs[0].score

when isMainModule:
  discard
