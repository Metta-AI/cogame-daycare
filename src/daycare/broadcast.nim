## The broadcast chrome frame: the JSON the starter's `client/chrome_common.js`
## and `client/replay_broadcast.html` read, smuggled as the label of sprite 4090.
##
## Fork of `coworld-ctf/src/ctf/broadcast.nim`: `BroadcastTracker` and
## `buildStateJson` keep their shape. `teams` becomes the two roles, `roster` the
## two cogs, `lead` the score series — all in the STARTER'S OWN shapes, so
## `ingestLeadSeries` / `renderMomentum` / `teamPolicies` need no change — plus
## the appended `secret` block, which is the whole broadcast premise.

import std/[json]
import sim_types, sim_state, sim, replays

type
  ChromeInput* = object
    phase*: string                ## lobby | playing | gameover
    tick*, maxTick*, startTick*: int
    turn*, turns*, ticksPerTurn*: int
    playing*, loop*, skipLulls*, fastForward*, enabled*: bool
    speed*, lobbySeconds*, hold*: int
    scores*: array[2, int]
    roles*: array[2, Role]
    names*: array[2, string]
    policyNames*: array[2, string]
    carrying*: array[2, bool]
    variant*: string
    par*: int
    preference*: Fruit
    guess*: Fruit
    hasGuess*: bool
    tape*: seq[int]
    rightTurns*: int
    leadPts*: seq[array[3, int]]
    beats*: seq[Beat]
    events*: seq[JsonNode]
    over*: JsonNode
    firstHud*: bool

  BroadcastTracker* = object
    ## Per-viewer: the full-match series and the beat timeline ride the FIRST
    ## HUD frame only (the chrome caches both), and `lastEventCount` makes each
    ## frame carry exactly the rows that fired since the previous one.
    firstHud*: bool
    lastEventCount*: int

proc initBroadcastTracker*(): BroadcastTracker =
  BroadcastTracker(firstHud: true, lastEventCount: 0)

proc teamKey*(role: Role): string =
  if role == rParent: "parent" else: "child"

proc buildStateJson*(input: ChromeInput): string =
  ## The starter's `teams` / `roster` / `lead` / `beats` / `over` plus the
  ## appended `secret` block. `teams[k].lives` is that seat's SCORE (the
  ## scorebug's `Lives` label is re-lettered `Score` in the page).
  var teams = newJObject()
  var roster = newJArray()
  for slot in 0 .. 1:
    let key = teamKey(input.roles[slot])
    let headline = if input.roles[slot] == rParent: "Parent" else: "Child"
    teams[key] = %*{
      "lives": input.scores[slot],
      "policies": [headline],
      "flag": "home",
      "carrier": -1
    }
    roster.add %*{
      "s": slot,
      "name": input.names[slot],
      "pol": input.policyNames[slot],
      "team": key,
      "lives": 0,
      "alive": true,
      "carry": input.carrying[slot],
      "k": 0, "d": 0, "a": 0,
      "pk": newJArray()
    }
  var state = %*{
    "ph": input.phase,
    "t": input.tick,
    "mx": max(1, input.maxTick),
    "st": input.startTick,
    "mt": max(1, input.maxTick - input.startTick),
    "sp": input.speed,
    "pl": input.playing,
    "en": input.enabled,
    "lp": input.loop,
    "sk": input.skipLulls,
    "ff": input.fastForward,
    "lob": input.lobbySeconds,
    "hold": input.hold,
    "pov": -1,
    "mm": -1,
    "teams": teams,
    "roster": roster,
    "turn": input.turn,
    "turns": input.turns,
    "ticksPerTurn": input.ticksPerTurn,
    "variant": input.variant,
    "par": input.par,
    "scores": [input.scores[0], input.scores[1]]
  }
  var secretTape = newJArray()
  for v in input.tape:
    secretTape.add %v
  state["secret"] = %*{
    "pref": $input.preference,
    "guess": (if input.hasGuess: $input.guess else: ""),
    "right": input.hasGuess and input.guess == input.preference,
    "tape": secretTape,
    "rightTurns": input.rightTurns
  }
  var events = newJArray()
  for row in input.events:
    events.add row
  state["events"] = events
  if input.firstHud:
    var pts = newJArray()
    for row in input.leadPts:
      pts.add %[row[0], row[1], row[2]]
    state["lead"] = %*{"teams": ["parent", "child"], "pts": pts}
    state["beats"] = beatsJson(input.beats)
    state["lulls"] = newJArray()
  if not input.over.isNil:
    state["over"] = input.over
  $state

proc liveChromeInput*(sim: Sim, tracker: var BroadcastTracker,
    lobbySeconds: int): ChromeInput =
  ## The live `/global` frame. Playback controls are inert on a live stream —
  ## `en: false` disables the transport bar, exactly as paintbot does.
  result.phase =
    if sim.done: "gameover"
    elif sim.turn == 0: "lobby"
    else: "playing"
  result.tick = sim.tick
  result.maxTick = sim.config.totalTicks()
  result.startTick = 0
  result.turn = max(1, sim.turn)
  result.turns = sim.config.turns
  result.ticksPerTurn = sim.config.ticksPerTurn
  result.playing = not sim.done
  result.enabled = false
  result.speed = 1
  result.lobbySeconds = lobbySeconds
  result.scores = [sim.cogs[0].score, sim.cogs[1].score]
  result.roles = sim.roleOf
  result.names = sim.names
  result.policyNames = sim.policyNames
  for slot in 0 .. 1:
    result.carrying[slot] = sim.cogs[slot].carry >= 0
  result.variant = sim.variant
  result.par = sim.config.parScore()
  result.preference = sim.preference
  result.guess = sim.guess
  result.hasGuess = sim.hasGuess
  result.rightTurns = sim.guessTurnsCorrect
  result.tape = newSeq[int](sim.config.turns)
  for i in 0 ..< sim.config.turns:
    result.tape[i] = -1
  for i, row in sim.guessRightSeries:
    if i < result.tape.len:
      result.tape[i] = row[1]
  result.firstHud = tracker.firstHud
  if tracker.firstHud:
    result.leadPts = sim.scoreSeries
    result.beats = sim.beats
    tracker.firstHud = false
  if sim.events.len > tracker.lastEventCount:
    for i in tracker.lastEventCount ..< sim.events.len:
      result.events.add sim.events[i]
    tracker.lastEventCount = sim.events.len
  if sim.done:
    result.over = %*{
      "draw": true,
      "reason": sim.reason,
      "ending": sim.ending,
      "scores": [sim.cogs[0].score, sim.cogs[1].score],
      "preference": $sim.preference,
      "par": sim.config.parScore(),
      "guessTurnsCorrect": sim.guessTurnsCorrect,
      "childAte": [sim.childAte[fApple], sim.childAte[fBanana]],
      "delivered": [sim.delivered[fApple], sim.delivered[fBanana]],
      "wasted": sim.wasted[0] + sim.wasted[1],
      "reaches": sim.reaches[0] + sim.reaches[1],
      "turns": sim.turnsPlayed,
      "teams": {
        teamKey(sim.roleOf[0]): {"lives": sim.cogs[0].score},
        teamKey(sim.roleOf[1]): {"lives": sim.cogs[1].score}
      }
    }

proc replayChromeInput*(player: ReplayPlayer, firstHud: bool): ChromeInput =
  ## The same frame, rebuilt from the recorded state at the playhead.
  let tick = player.tick
  result.phase = if tick >= player.maxTick: "gameover" else: "playing"
  result.tick = tick
  result.maxTick = player.maxTick
  result.startTick = 0
  result.turn = player.turnAt(tick)
  result.turns = player.turns
  result.ticksPerTurn = player.ticksPerTurn
  result.playing = player.playing
  result.enabled = true
  result.loop = player.loop
  result.skipLulls = player.skip
  result.fastForward = player.speed > 1
  result.speed = player.speed
  result.scores = player.scoresAt(tick)
  result.roles = player.roles
  result.names = player.names
  result.policyNames = player.policyNames
  let snap = player.snapshotAt(tick)
  for slot in 0 .. 1:
    result.carrying[slot] = snap.cogCarry[slot] >= 0
  result.variant = player.variant
  result.par = player.par
  result.preference = player.preferenceAt(tick)
  let g = player.guessAt(tick)
  result.hasGuess = g.has
  result.guess = g.guess
  result.tape = player.tapeAt(tick)
  result.rightTurns = player.rightTurnsAt(tick)
  result.firstHud = firstHud
  if firstHud:
    result.leadPts = player.scoreSeries
    result.beats = player.beats
  if tick < player.eventsByTick.len:
    result.events = player.eventsByTick[tick]
  if tick >= player.maxTick and not player.results.isNil:
    result.over = %*{
      "draw": true,
      "reason": player.results{"reason"}.getStr(),
      "ending": player.results{"ending"}.getStr(),
      "scores": player.results{"scores"},
      "preference": player.results{"preference"}.getStr(),
      "par": player.par,
      "guessTurnsCorrect": player.results{"guess_turns_correct"}.getInt(),
      "childAte": player.results{"child_ate"},
      "delivered": player.results{"delivered"},
      "wasted": player.results{"wasted"},
      "reaches": player.results{"reaches"},
      "turns": player.results{"turns"}.getInt(),
      "teams": {
        teamKey(player.roles[0]): {"lives": result.scores[0]},
        teamKey(player.roles[1]): {"lives": result.scores[1]}
      }
    }
