## Daycare wire types, rule constants and the seeded RNG.
##
## Forked from `coworld-ctf/src/ctf/sim_types.nim`: the same split (consts +
## types + the version gate here, gameplay in `sim.nim`) and the same rule that
## FIELD ORDER IS SACRED — the replay frame encoding below is positional.
##
## Every sim quantity is an integer (chances are per-mille ints), so a seed
## reproduces a replay bit-exactly and no float ever enters sim state.

import std/[strutils, unicode]

const
  GameVersion* = "1"
    ## GV1 (daycare v1): the yard, the nine-step tick order, the standing-order
    ## kernel, mirrored consumption scoring and the `daycare.replay.v1` frame
    ## encoding. Bump this whenever a rule changes what a seed produces.

  ReplayProtocol* = "daycare.replay.v1"
  PlayerProtocol* = "daycare.player.v1"

  # ---- the yard -------------------------------------------------------------
  YardCols* = 24
  YardRows* = 14
  CellPx* = 48              ## board px per cell -> a 1152 x 672 board
  BoardW* = YardCols * CellPx
  BoardH* = YardRows * CellPx

  # ---- caps and rates (all integers) ---------------------------------------
  ## FOUR of these are REPAIRED values, not the design note's originals. The
  ## note's own instruction is "if a gate fails, repair constants in this order
  ## and re-run - no design bounce is needed", and its own warning is that the
  ## throughput table is "design targets derived from the constants, not
  ## measurements". `tests/test_feasibility.nim` is the enforcement; a sweep of
  ## the ladder's parameter space found exactly one region where all six gates
  ## hold on all four variants, and this is it:
  ##   (a) ticksPerTurn      48 -> 60   (rung 1)
  ##   (a) tallRegrowTicks   36 -> 24   (rung 2)
  ##   (c) fruitLifetime    120 -> 96
  ##   (d) shrubRegrowTicks 240 -> 480  (one step beyond the named 320; 320
  ##                                     alone left gate (b) at 0.82 on
  ##                                     daycare-fickle)
  ## `rewardOther` stays 1 - the note's last-resort rung was NOT needed - and so
  ## do basketCapacity 2, childShrubPickPermille 250/150 and the 6..9 switch
  ## window.
  DefaultTurns* = 15
  DefaultTicksPerTurn* = 60
  DefaultMoveCooldown* = 2
  DefaultCarryCap* = 1
  DefaultTallCapacity* = 3
  DefaultTallRegrowTicks* = 24
  DefaultShrubCapacity* = 1
  DefaultShrubRegrowTicks* = 480
  DefaultChildShrubPickPermille* = 250
  DefaultChildReachCooldownTicks* = 6
  DefaultFruitLifetime* = 96
  DefaultBasketCapacity* = 2
  DefaultRewardPreferred* = 3
  DefaultRewardOther* = 1
  DefaultShrubs* = 4

  TallInitialRipe* = 2
  ShrubInitialRipe* = 1
  ReachCoalesceTicks* = 8   ## one `reach` row per 8 ticks while a streak runs
  MaxReplayBytes* = 8 * 1024 * 1024

  # ---- reply caps (rune counts, never bytes) -------------------------------
  MaxHunchLen* = 80
  MaxNotesLen* = 240
  MaxErrorTextLen* = 200
  MaxPromptLen* = 4000

  # ---- decision cadence ----------------------------------------------------
  DefaultLlmTimeoutSeconds* = 18
  DefaultMinTurnSeconds* = 8
  DefaultMaxOutputTokens* = 600
  DefaultEpisodeTimeoutSeconds* = 1200
  DefaultPlayerConnectTimeoutSeconds* = 120
  DefaultShutdownGraceSeconds* = 20
  PlayBudgetFraction* = 0.6
    ## Share of the platform's episode timeout spent playing. An episode that
    ## outruns the timeout is discarded whole, so settle early instead.

  # ---- playback ------------------------------------------------------------
  TargetFps* = 24
  PlaybackSpeeds*: array[6, int] = [1, 2, 3, 4, 8, 16]
  BroadcastChromeSpriteId* = 4090
    ## Reserved 1x1 never-drawn sprite whose LABEL carries the broadcast chrome
    ## JSON. Paintbot's id, kept because `client/broadcast_core.js` ships
    ## byte-for-byte and reads `window.CTF_WIRE.chromeSpriteId`.
  ShotFxTicks* = 3          ## unused by daycare; kept so CTF_WIRE keeps shape
  TrailFalloff* = 2

  PreferenceSwitchFirstTurn* {.intdefine.} = 6
  PreferenceSwitchTurnSpan* {.intdefine.} = 4
    ## `daycare-fickle` draws its switch turn from `rngSecret`, uniformly in
    ## `PreferenceSwitchFirstTurn ..< + Span` — the note's 6..9, so the parent
    ## has time to be right, then wrong, then right again.

  SecretRngSalt* = 0x0DA9CA12
    ## `rngSecret = seededRng(seed xor SecretRngSalt)`. Nothing the parent can
    ## observe is drawn from it, and nothing the preference depends on is drawn
    ## from `rngLayout` — which is what makes "the parent cannot see it
    ## directly" true of the BYTES and not just of the prompt.

  PickRngSalt* = 0x0C0FFEE1
    ## `pickRng = seededRng(seed xor PickRngSalt)`: the child's shrub-pick coin.
    ## Its own stream off the SEED, never a draw from `rngSecret`, because a
    ## pick outcome IS something the parent observes — it lands in the `reach`
    ## event and in `reachFails` — and the rule above is that nothing the parent
    ## can observe is ever drawn from `rngSecret` (r1 review, N4).

type
  DaycareError* = object of CatchableError

  Fruit* = enum
    fApple = "apple"
    fBanana = "banana"

  Role* = enum
    rParent = "parent"
    rChild = "child"

  SourceKind* = enum
    skTall = "tall"
    skShrub = "shrub"

  ParentJob* = enum
    pjProvide = "provide"
    pjStock = "stock"
    pjWatch = "watch"
    pjIdle = "idle"

  ChildJob* = enum
    cjSeek = "seek"
    cjShow = "show"
    cjGraze = "graze"
    cjBeg = "beg"
    cjIdle = "idle"

  Action* = enum
    aMoveN = "move_n"
    aMoveS = "move_s"
    aMoveE = "move_e"
    aMoveW = "move_w"
    aPick = "pick"
    aDrop = "drop"
    aEat = "eat"
    aWait = "wait"

  OrderSource* = enum
    osScripted = "scripted"
    osLlm = "llm"
    osRetry = "retry"
    osFallback = "fallback"

  Order* = object
    ## One seat's standing order for a whole turn. `pjob` is read for a parent
    ## seat and `cjob` for a child seat; the other is ignored.
    pjob*: ParentJob
    cjob*: ChildJob
    fruit*: Fruit
    hasFruit*: bool
    guess*: Fruit
    hasGuess*: bool
    hunch*: string
    notes*: string
    source*: OrderSource
    latencyMs*: int

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    numAgents*: int
    seed*: int
    slot0Role*: Role
    turns*: int
    ticksPerTurn*: int
    moveCooldown*: int
    carryCap*: int
    shrubs*: int
    tallCapacity*: int
    tallRegrowTicks*: int
    shrubCapacity*: int
    shrubRegrowTicks*: int
    childShrubPickPermille*: int
    childReachCooldownTicks*: int
    fruitLifetime*: int
    basketCapacity*: int
    rewardPreferred*: int
    rewardOther*: int
    preferenceSwitch*: bool
    llmTimeoutSeconds*: int
    minTurnSeconds*: int
    maxOutputTokens*: int
    model*: string
    episodeTimeoutSeconds*: int
    playerConnectTimeoutSeconds*: int
    shutdownGraceSeconds*: int
    showPlayerLabels*: bool
    preferenceSwitchFirstTurn*: int
      ## The first turn `daycare-fickle` may switch on; the switch turn is drawn
      ## uniformly from `[this, this + PreferenceSwitchTurnSpan)`. Never set
      ## from a runtime config — the oracle sweeps it.
    forcePreference*: int
      ## test-only override: -1 unset, else ord(Fruit). Never set from a
      ## runtime config; `tests/test_feasibility.nim` gate (f) uses it.

  SourceState* = object
    ## FIELD ORDER IS SACRED: the replay's `config.sources` and per-frame `s`
    ## array are positional in this order.
    id*: string
    kind*: SourceKind
    fruit*: Fruit
    x*, y*: int
    ripe*: int
    regrow*: int            ## ticks accumulated toward the next ripe fruit
    capacity*: int
    regrowTicks*: int

  GroundFruit* = object
    x*, y*: int
    fruit*: Fruit
    ttl*: int               ## -1 on a mat cell: mat fruit never rots
    fromParent*: bool       ## provenance for results.delivered

  Cog* = object
    x*, y*: int
    carry*: int             ## -1 empty hand, else ord(Fruit)
    carryFromParent*: bool
    score*: int
    moveCd*: int
    fumbleCd*: int

  SpeciesCounters* = object
    ## The behaviour summary the OTHER seat reads. Computed by the sim so it is
    ## identical for every policy.
    adjacentTicks*: array[Fruit, int]
    reachAttempts*: array[Fruit, int]
    reachFails*: array[Fruit, int]
    groundPasses*: array[Fruit, int]
    ate*: array[Fruit, int]
    carriedTicks*: array[Fruit, int]
    delivered*: array[Fruit, int]
    stocked*: array[Fruit, int]
    wasted*: int
    cellsWalked*: int
    idleTicks*: int

  TurnRecord* = object
    turn*: int
    guess*: Fruit
    hasGuess*: bool
    childAte*: array[Fruit, int]
    delivered*: array[Fruit, int]
    score*: int

  Beat* = object
    t*: int
    kind*: string           ## turn | guess | switch | feast | gameover
    n*: int
    g*: string
    ok*: bool

  Frame* = object
    t*: int
    c*: seq[int]            ## 4 per cog: x, y, carryFruitId, score
    g*: seq[int]            ## 4 per ground fruit: x, y, fruitId, ttl
    s*: seq[int]            ## 2 per source: ripe, regrowIn (config order)
    b*: array[2, int]       ## mat counts [apple, banana]

  Rng* = object
    state*: uint64

proc cleanText*(text: string, limit: int): string =
  ## Text over the cap is cut at a RUNE boundary with the cut marked. A byte cut
  ## put invalid UTF-8 into a replay and only a strict parser found it
  ## (bullwhip, 2026-08-22), so EVERY string that reaches the replay goes
  ## through here: `hunch`, `notes` and LLM error text alike.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "\u2026"

proc cleanHunch*(text: string): string =
  ## Newlines in `hunch` become spaces: it is a one-line broadcast headline.
  cleanText(text.replace("\n", " ").replace("\r", " "), MaxHunchLen)

proc cleanNotes*(text: string): string =
  cleanText(text, MaxNotesLen)

proc fruitId*(f: Fruit): int = ord(f)

proc otherFruit*(f: Fruit): Fruit =
  if f == fApple: fBanana else: fApple

proc parseFruit*(text: string): Fruit =
  case text.strip().toLowerAscii()
  of "apple", "apples": fApple
  of "banana", "bananas": fBanana
  else: raise newException(DaycareError, "unknown fruit: " & text)

proc parseRole*(text: string): Role =
  case text.strip().toLowerAscii()
  of "parent": rParent
  of "child": rChild
  else: raise newException(DaycareError, "unknown role: " & text)

proc seededRng*(seed: int): Rng =
  ## xorshift64. Integer-only and platform-independent, so a seed reproduces
  ## a replay bit-exactly on every host and in wasm.
  var s = uint64(seed and 0x7FFF_FFFF) xor 0x9E3779B97F4A7C15'u64
  if s == 0'u64:
    s = 0x853C49E6748FEA9B'u64
  Rng(state: s)

proc nextU64*(rng: var Rng): uint64 =
  var x = rng.state
  x = x xor (x shl 13)
  x = x xor (x shr 7)
  x = x xor (x shl 17)
  rng.state = x
  x

proc rand*(rng: var Rng, n: int): int =
  ## Uniform in 0 ..< n.
  if n <= 1: return 0
  int(rng.nextU64() mod uint64(n))

proc chancePermille*(rng: var Rng, permille: int): bool =
  if permille <= 0: return false
  if permille >= 1000: return true
  rng.rand(1000) < permille

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    numAgents: 2,
    seed: 0,
    slot0Role: rParent,
    turns: DefaultTurns,
    ticksPerTurn: DefaultTicksPerTurn,
    moveCooldown: DefaultMoveCooldown,
    carryCap: DefaultCarryCap,
    shrubs: DefaultShrubs,
    tallCapacity: DefaultTallCapacity,
    tallRegrowTicks: DefaultTallRegrowTicks,
    shrubCapacity: DefaultShrubCapacity,
    shrubRegrowTicks: DefaultShrubRegrowTicks,
    childShrubPickPermille: DefaultChildShrubPickPermille,
    childReachCooldownTicks: DefaultChildReachCooldownTicks,
    fruitLifetime: DefaultFruitLifetime,
    basketCapacity: DefaultBasketCapacity,
    rewardPreferred: DefaultRewardPreferred,
    rewardOther: DefaultRewardOther,
    preferenceSwitch: false,
    llmTimeoutSeconds: DefaultLlmTimeoutSeconds,
    minTurnSeconds: DefaultMinTurnSeconds,
    maxOutputTokens: DefaultMaxOutputTokens,
    model: "claude-haiku-4-5",
    episodeTimeoutSeconds: DefaultEpisodeTimeoutSeconds,
    playerConnectTimeoutSeconds: DefaultPlayerConnectTimeoutSeconds,
    shutdownGraceSeconds: DefaultShutdownGraceSeconds,
    showPlayerLabels: true,
    preferenceSwitchFirstTurn: PreferenceSwitchFirstTurn,
    forcePreference: -1
  )

proc parScore*(config: GameConfig): int =
  ## `results.win[i] = scores[i] >= parScore`. Daycare is cooperative: there is
  ## no loser to declare, so the platform's boolean means "the pair beat par".
  2 * config.turns

proc totalTicks*(config: GameConfig): int =
  config.turns * config.ticksPerTurn

proc variantId*(config: GameConfig): string =
  ## The four shipped variants are distinguishable from their config alone, so
  ## no extra manifest key is needed (`config_schema` is
  ## `additionalProperties: false`).
  if config.slot0Role == rChild: "daycare-swapped"
  elif config.preferenceSwitch: "daycare-fickle"
  elif config.shrubs <= 2: "daycare-sparse"
  else: "daycare"
