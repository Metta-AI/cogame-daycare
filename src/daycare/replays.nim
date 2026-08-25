## `daycare.replay.v1`: strict UTF-8 JSON, one document, self-sufficient.
##
## Rewritten rather than forked: paintbot records INPUTS and re-simulates on
## playback (`replays.nim` + `replay_runtime.nim`); Daycare records STATE, so
## playback never re-simulates, a seek is an array index, and there is no
## native/wasm divergence to chase — which is also why `#mmwarn` and
## `ctf_mismatch_tick` are dropped.

import std/[json, strutils]
import bitworld/spriteprotocol
import sim_types, yard, sim_state, sim, global

proc frameJson(frame: Frame): JsonNode =
  var c = newJArray()
  for v in frame.c: c.add %v
  var g = newJArray()
  for v in frame.g: g.add %v
  var s = newJArray()
  for v in frame.s: s.add %v
  %*{"t": frame.t, "c": c, "g": g, "s": s,
     "b": [frame.b[0], frame.b[1]]}

proc configJson*(sim: Sim): JsonNode =
  var fence = newJArray()
  for y in 0 ..< sim.yard.rows:
    for x in 0 ..< sim.yard.cols:
      if sim.yard.kindAt(x, y) == ckFence:
        fence.add %[x, y]
  var sources = newJArray()
  for s in sim.yard.sources:
    sources.add %*{"id": s.id, "kind": $s.kind, "fruit": $s.fruit,
                   "cell": [s.x, s.y], "capacity": s.capacity,
                   "regrowTicks": s.regrowTicks}
  var basket = newJArray()
  for c in sim.yard.basket:
    basket.add %[c mod sim.yard.cols, c div sim.yard.cols]
  var spawns = newJArray()
  for role in [rParent, rChild]:
    let c = sim.yard.spawns[ord(role)]
    spawns.add %[c mod sim.yard.cols, c div sim.yard.cols]
  %*{
    "variant": sim.variant,
    "cols": sim.yard.cols, "rows": sim.yard.rows, "cell": CellPx,
    "mirrored": sim.yard.mirrored,
    "turns": sim.config.turns, "ticksPerTurn": sim.config.ticksPerTurn,
    "parScore": sim.config.parScore(),
    "fence": fence, "sources": sources,
    "basket": basket, "basketCapacity": sim.config.basketCapacity,
    "spawns": spawns,
    "tallCapacity": sim.config.tallCapacity,
    "tallRegrowTicks": sim.config.tallRegrowTicks,
    "shrubCapacity": sim.config.shrubCapacity,
    "shrubRegrowTicks": sim.config.shrubRegrowTicks,
    "childShrubPickPermille": sim.config.childShrubPickPermille,
    "childReachCooldownTicks": sim.config.childReachCooldownTicks,
    "fruitLifetime": sim.config.fruitLifetime,
    "moveCooldown": sim.config.moveCooldown,
    "carryCap": sim.config.carryCap,
    "rewardPreferred": sim.config.rewardPreferred,
    "rewardOther": sim.config.rewardOther,
    "slot0Role": $sim.config.slot0Role
  }

proc beatsJson*(beats: openArray[Beat]): JsonNode =
  result = newJArray()
  for b in beats:
    var row = %*{"t": b.t, "k": b.kind}
    if b.kind == "turn" or b.kind == "feast":
      row["n"] = %b.n
    if b.g.len > 0:
      row["g"] = %b.g
    if b.kind == "guess":
      row["ok"] = %b.ok
    result.add row

proc replayJson*(sim: Sim, results: JsonNode): string =
  ## Self-sufficient by construction: aliases, policy names, roles, body
  ## colours, the full yard geometry, every rule constant, the seed, THE CHILD'S
  ## SECRET PREFERENCE and its switch turn, per-tick state, the score and guess
  ## series, the beat timeline, every event and the final results. The viewer
  ## contacts no server except S3 for the `.replay` file.
  ##
  ## The `secret` block is written AFTER the episode, so no player process can
  ## ever read it.
  var frames = newJArray()
  for frame in sim.frames:
    frames.add frameJson(frame)
  var score = newJArray()
  for row in sim.scoreSeries:
    score.add %[row[0], row[1], row[2]]
  var guessRight = newJArray()
  for row in sim.guessRightSeries:
    guessRight.add %[row[0], row[1]]
  var events = newJArray()
  for row in sim.events:
    events.add row
  $ %*{
    "protocol": ReplayProtocol,
    "game": "daycare",
    "gameVersion": GameVersion,
    "seed": sim.config.seed,
    "names": [sim.names[0], sim.names[1]],
    "policyNames": [sim.policyNames[0], sim.policyNames[1]],
    "roles": [$sim.roleOf[0], $sim.roleOf[1]],
    "colors": [sim.colors[0], sim.colors[1]],
    "config": sim.configJson(),
    "secret": {"preference": $sim.preference, "switchTurn": sim.switchTurn},
    "frames": frames,
    "series": {"score": score, "guessRight": guessRight},
    "beats": beatsJson(sim.beats),
    "events": events,
    "results": results
  }

# ---------------------------------------------------------------------------
# playback
# ---------------------------------------------------------------------------

type
  ReplayPlayer* = object
    doc*: JsonNode
    frames*: seq[Frame]
    eventsByTick*: seq[seq[JsonNode]]
    kinds*: seq[int]
    sourceKind*, sourceFruit*, sourceX*, sourceY*: seq[int]
    cols*, rows*, cell*: int
    turns*, ticksPerTurn*: int
    names*, policyNames*: array[2, string]
    roles*: array[2, Role]
    variant*: string
    par*: int
    preference*: Fruit
    switchTurn*: int
    guessTape*: seq[int]
    guessSeries*: seq[array[2, int]]
    scoreSeries*: seq[array[3, int]]
    beats*: seq[Beat]
    results*: JsonNode
    showLabels*: bool

    tick*: int
    maxTick*: int
    playing*: bool
    loop*: bool
    skip*: bool
    speed*: int
    firstHud*: bool

proc parseFrame(node: JsonNode): Frame =
  result.t = node{"t"}.getInt()
  for v in node{"c"}: result.c.add v.getInt()
  for v in node{"g"}: result.g.add v.getInt()
  for v in node{"s"}: result.s.add v.getInt()
  let b = node{"b"}
  if not b.isNil and b.len >= 2:
    result.b = [b[0].getInt(), b[1].getInt()]

proc loadReplay*(data: string): ReplayPlayer =
  ## Parses the replay JSON and hydrates the frame array. Raises on anything
  ## unreadable so the shell can report `data-replay-error`.
  let doc = parseJson(data)
  if doc{"protocol"}.getStr() != ReplayProtocol:
    raise newException(DaycareError,
      "not a " & ReplayProtocol & " replay: " & doc{"protocol"}.getStr())
  result.doc = doc
  let config = doc["config"]
  result.cols = config{"cols"}.getInt(YardCols)
  result.rows = config{"rows"}.getInt(YardRows)
  result.cell = config{"cell"}.getInt(CellPx)
  result.turns = config{"turns"}.getInt(DefaultTurns)
  result.ticksPerTurn = config{"ticksPerTurn"}.getInt(DefaultTicksPerTurn)
  result.par = config{"parScore"}.getInt(2 * result.turns)
  result.variant = config{"variant"}.getStr("daycare")
  result.showLabels = true

  result.kinds = newSeq[int](result.cols * result.rows)
  for y in 0 ..< result.rows:
    for x in 0 ..< result.cols:
      result.kinds[y * result.cols + x] = ord(ckGrass)
  for cell in config{"fence"}:
    result.kinds[cell[1].getInt() * result.cols + cell[0].getInt()] =
      ord(ckFence)
  for cell in config{"basket"}:
    result.kinds[cell[1].getInt() * result.cols + cell[0].getInt()] = ord(ckMat)
  for s in config{"sources"}:
    let kind = if s{"kind"}.getStr() == $skTall: skTall else: skShrub
    let x = s["cell"][0].getInt()
    let y = s["cell"][1].getInt()
    result.sourceKind.add ord(kind)
    result.sourceFruit.add ord(parseFruit(s{"fruit"}.getStr()))
    result.sourceX.add x
    result.sourceY.add y
    result.kinds[y * result.cols + x] =
      if kind == skTall: ord(ckTall) else: ord(ckShrub)

  for i in 0 .. 1:
    result.names[i] = doc["names"][i].getStr()
    result.policyNames[i] =
      if doc{"policyNames"}.isNil: doc["names"][i].getStr()
      else: doc["policyNames"][i].getStr()
    result.roles[i] = parseRole(doc["roles"][i].getStr())

  let secret = doc{"secret"}
  result.preference =
    if secret.isNil: fApple else: parseFruit(secret{"preference"}.getStr("apple"))
  result.switchTurn = if secret.isNil: 0 else: secret{"switchTurn"}.getInt()

  for node in doc["frames"]:
    result.frames.add parseFrame(node)
  result.maxTick = max(0, result.frames.len - 1)
  result.eventsByTick = newSeq[seq[JsonNode]](result.frames.len + 1)
  for row in doc{"events"}:
    let t = row{"t"}.getInt()
    if t >= 0 and t < result.eventsByTick.len:
      result.eventsByTick[t].add row
  for row in doc{"series"}{"score"}:
    result.scoreSeries.add [row[0].getInt(), row[1].getInt(), row[2].getInt()]
  for row in doc{"series"}{"guessRight"}:
    result.guessSeries.add [row[0].getInt(), row[1].getInt()]
  for row in doc{"beats"}:
    result.beats.add Beat(t: row{"t"}.getInt(), kind: row{"k"}.getStr(),
      n: row{"n"}.getInt(), g: row{"g"}.getStr(), ok: row{"ok"}.getBool())
  result.results = doc{"results"}
  result.tick = 0
  result.playing = true
  result.speed = 1
  result.firstHud = true

proc parentSlot*(player: ReplayPlayer): int =
  if player.roles[0] == rParent: 0 else: 1

proc childSlot*(player: ReplayPlayer): int = 1 - player.parentSlot()

proc turnAt*(player: ReplayPlayer, tick: int): int =
  min(player.turns, tick div max(1, player.ticksPerTurn) + 1)

proc preferenceAt*(player: ReplayPlayer, tick: int): Fruit =
  ## In `daycare-fickle` the spectator reveal changes exactly when the
  ## preference does, so the panel reads the preference AT THE PLAYHEAD.
  ## `secret.preference` is the value at the END of the episode.
  if player.switchTurn <= 0:
    return player.preference
  let switchedAt = player.switchTurn * player.ticksPerTurn
  if tick >= switchedAt: player.preference
  else: otherFruit(player.preference)

proc guessAt*(player: ReplayPlayer, tick: int): tuple[has: bool, guess: Fruit] =
  result = (false, fApple)
  for t in countdown(min(tick, player.eventsByTick.high), 0):
    for row in player.eventsByTick[t]:
      if row{"k"}.getStr() == "guess":
        return (true, parseFruit(row{"guess"}.getStr()))
      if row{"k"}.getStr() == "order" and row{"guess"}.getStr().len > 0:
        return (true, parseFruit(row{"guess"}.getStr()))

proc snapshotAt*(player: ReplayPlayer, tick: int): BoardSnapshot =
  let index = max(0, min(tick, player.frames.high))
  let frame = player.frames[index]
  result.cols = player.cols
  result.rows = player.rows
  result.cell = player.cell
  result.kinds = player.kinds
  result.sourceKind = player.sourceKind
  result.sourceFruit = player.sourceFruit
  result.sourceX = player.sourceX
  result.sourceY = player.sourceY
  result.tick = index
  result.showLabels = player.showLabels
  for i in 0 ..< player.sourceKind.len:
    result.sourceRipe.add (if i * 2 < frame.s.len: frame.s[i * 2] else: 0)
  var i = 0
  while i + 3 < frame.g.len:
    result.groundX.add frame.g[i]
    result.groundY.add frame.g[i + 1]
    result.groundFruit.add frame.g[i + 2]
    result.groundTtl.add frame.g[i + 3]
    i += 4
  for seat in 0 .. 1:
    result.cogX[seat] = frame.c[seat * 4]
    result.cogY[seat] = frame.c[seat * 4 + 1]
    result.cogCarry[seat] = frame.c[seat * 4 + 2]
    result.cogRole[seat] = ord(player.roles[seat])
    result.names[seat] = player.names[seat]
  # FX from the recorded events: a reach holds the arms-up frame for the whole
  # coalescing window, so the signal reads instead of flickering for one tick.
  for back in 0 ..< ReachCoalesceTicks:
    let t = index - back
    if t < 0 or t >= player.eventsByTick.len: continue
    for row in player.eventsByTick[t]:
      let seat = row{"seat"}.getInt(-1)
      if seat < 0 or seat > 1: continue
      case row{"k"}.getStr()
      of "reach": result.reaching[seat] = true
      of "waste":
        if back < 4: result.wasting[seat] = true
      of "eat":
        if back < 4: result.eating[seat] = true
      else: discard

proc scoresAt*(player: ReplayPlayer, tick: int): array[2, int] =
  let index = max(0, min(tick, player.frames.high))
  if player.frames.len == 0:
    return [0, 0]
  [player.frames[index].c[3], player.frames[index].c[7]]

proc tapeAt*(player: ReplayPlayer, tick: int): seq[int] =
  ## 15 chips, one per turn: 1 correct, 0 wrong, -1 not yet reached.
  result = newSeq[int](player.turns)
  for i in 0 ..< player.turns:
    result[i] = -1
  for i, row in player.guessSeries:
    if i >= player.turns: break
    if row[0] <= tick:
      result[i] = row[1]

proc rightTurnsAt*(player: ReplayPlayer, tick: int): int =
  for row in player.guessSeries:
    if row[0] <= tick and row[1] == 1:
      inc result

proc applyCommand*(player: var ReplayPlayer, text: string) =
  ## The transport commands the starter chrome sends over the sprite client
  ## channel. `s:<tick>` seeks; every seek also dismisses the endcard, which is
  ## the chrome's own behaviour.
  if text.len == 0:
    return
  if text.startsWith("s:"):
    try:
      player.tick = max(0, min(player.maxTick, parseInt(text[2 .. ^1])))
    except ValueError:
      discard
    return
  if text.startsWith("v:"):
    return                              # no POV lens in Daycare
  for ch in text:
    case ch
    of ' ': player.playing = not player.playing
    of ',': player.tick = 0
    of 'b': player.tick = max(0, player.tick - 1)
    of '.': player.tick = min(player.maxTick, player.tick + 5 * TargetFps)
    of 'e': player.tick = player.maxTick
    of 'r': player.loop = not player.loop
    of 'f': player.skip = not player.skip
    of '1': player.speed = 1
    of '2': player.speed = 2
    of '3': player.speed = 3
    of '4': player.speed = 4
    of '8': player.speed = 8
    of '6': player.speed = 16
    else: discard

proc advance*(player: var ReplayPlayer, frames: int) =
  if not player.playing:
    return
  for _ in 1 .. max(1, frames):
    if player.tick >= player.maxTick:
      if player.loop: player.tick = 0
      else: return
    else:
      player.tick = min(player.maxTick, player.tick + player.speed)

proc applyViewerMessage*(player: var ReplayPlayer, blob: string) =
  ## One client->server sprite-protocol blob from the chrome's transport bar.
  ## `broadcast_core.js`'s `sendCommand` packs the command as a chat message, so
  ## the whole transport arrives here as printable ASCII.
  let text = readSpriteInputText(blob)
  if text.len > 0:
    player.applyCommand(text)
