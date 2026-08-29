## End-to-end plus STRICT UTF-8.
##
## Design note ## Tests, item 5: play a full scripted episode headless, write
## results.json and the replay, then re-read the replay BYTES.

import std/[strutils, unicode, os]
import helpers

echo "test_replay: a full episode writes a strictly valid UTF-8 replay"
for variant in AllVariants:
  let cfg = variantConfig(variant, 4)
  var sim = initSim(cfg, ["daycare-attentive", "daycare-caretaker"])
  var hedge = 0
  # Feed a seat a hunch and notes of MULTI-BYTE runes exactly at the 80/240
  # caps: this is the bullwhip byte-truncation bug, and the only thing that
  # catches it is a strict parser over the recorded bytes.
  let bigHunch = "\u00fc".repeat(MaxHunchLen)
  let bigNotes = "\u00e9".repeat(MaxNotesLen)
  let overHunch = "\u00fc".repeat(MaxHunchLen + 40)
  let overNotes = "\u00e9".repeat(MaxNotesLen + 120)
  for turn in 1 .. cfg.turns:
    sim.turn = turn
    for seat in 0 .. 1:
      var order = orderFor(sim, seat, prCareCare, hedge)
      if turn mod 2 == 0:
        order.hunch = bigHunch
        order.notes = bigNotes
      else:
        order.hunch = overHunch
        order.notes = overNotes
      sim.applyOrder(seat, order)
    sim.playTurn()
  sim.settle("complete", "turn_limit")

  let results = sim.resultsJson()
  let replay = replayJson(sim, results)
  let where = variant & ": "

  doAssert validateUtf8(replay) == -1,
    where & "the replay bytes are not strict UTF-8 (first bad byte at " &
    $validateUtf8(replay) & ")"
  doAssert replay.len < MaxReplayBytes,
    where & "the replay is " & $replay.len & " bytes"
  let doc = parseJson(replay)
  doAssert doc{"protocol"}.getStr() == "daycare.replay.v1"
  doAssert doc{"game"}.getStr() == "daycare"
  doAssert doc{"gameVersion"}.getStr() == GameVersion
  doAssert doc{"seed"}.getInt() == cfg.seed
  doAssert doc["names"].len == 2 and doc["policyNames"].len == 2
  doAssert doc["roles"].len == 2 and doc["colors"].len == 2

  let ticksPlayed = sim.tick
  let turnsPlayed = sim.turnsPlayed
  doAssert doc["frames"].len == ticksPlayed,
    where & $doc["frames"].len & " frames vs " & $ticksPlayed & " ticks"
  doAssert doc["series"]["score"].len == ticksPlayed
  doAssert doc["series"]["guessRight"].len == turnsPlayed
  doAssert doc["secret"]{"preference"}.getStr() in ["apple", "banana"]

  var kinds: seq[string]
  var turnEvents = 0
  var endEvents = 0
  for row in doc["events"]:
    let t = row{"t"}.getInt()
    doAssert t >= 0 and t <= ticksPlayed,
      where & "event tick " & $t & " outside 0.." & $ticksPlayed
    let k = row{"k"}.getStr()
    if k notin kinds: kinds.add k
    if k == "turn": inc turnEvents
    if k == "end": inc endEvents
    # Every recorded string is valid UTF-8 and inside its cap, on RUNES.
    for (field, cap) in [("hunch", MaxHunchLen), ("notes", MaxNotesLen)]:
      let node = row{field}
      if node.isNil or node.kind != JString: continue
      let text = node.getStr()
      doAssert validateUtf8(text) == -1,
        where & field & " is not valid UTF-8: " & text
      doAssert text.runeLen <= cap,
        where & field & " is " & $text.runeLen & " runes, cap " & $cap
  for want in ["pick", "reach", "drop", "eat", "order", "turn", "end"]:
    doAssert want in kinds, where & "no " & want & " event"
  doAssert turnEvents == cfg.turns, where & $turnEvents & " turn events"
  doAssert endEvents == 1, where & $endEvents & " end events"

  doAssert doc["results"]["scores"].len == 2
  doAssert doc["results"]["scores"][0].getInt() ==
    doc["results"]["scores"][1].getInt(), where & "the mirror broke"
  doAssert doc["results"]{"reason"}.getStr() in
    ["complete", "deadline", "forfeit"]
  doAssert doc["results"]{"ending"}.getStr() in
    ["turn_limit", "deadline", "forfeit"]

  # The frame encoding: 4 ints per cog, 4 per ground fruit, 2 per source.
  for frame in doc["frames"]:
    doAssert frame["c"].len == 8, where & "cog frame is " & $frame["c"].len
    doAssert frame["g"].len mod 4 == 0
    doAssert frame["s"].len == sim.yard.sources.len * 2
    doAssert frame["b"].len == 2

  # The replay is self-sufficient: it reloads with no server at all.
  var player = loadReplay(replay)
  doAssert player.frames.len == ticksPlayed
  doAssert player.turns == cfg.turns
  doAssert player.beats.len > 0
  doAssert player.names == sim.names
  doAssert player.preference == sim.preference
  let snap = player.snapshotAt(player.maxTick)
  doAssert snap.cols == 24 and snap.rows == 14
  doAssert snap.sourceRipe.len == sim.yard.sources.len

  # And it round-trips to disk as bytes, which is what COGAME_SAVE_REPLAY_URI
  # writes and what the browser fetches.
  let path = getTempDir() / ("daycare-" & variant & ".replay.json")
  writeFile(path, replay)
  let back = readFile(path)
  doAssert back == replay
  doAssert validateUtf8(back) == -1
  removeFile(path)
  echo "  ", variant, ": ", replay.len, " bytes, ", doc["events"].len,
    " events, ", ticksPlayed, " frames"

echo "test_replay: half speed is a replay-only crawl"
block:
  ## The fleet-wide 1/2x replay speed: command '5' selects the ReplayHalfSpeed
  ## sentinel, the chrome shows 0.5, and advance() spends one tick every OTHER
  ## frame (halfPhase parity). '-' floors at 1/2x; '+' climbs back out.
  var player = ReplayPlayer(maxTick: 100, playing: true, speed: 1)
  player.applyCommand("5")
  doAssert player.speed == ReplayHalfSpeed, "'5' must select 1/2x"
  doAssert player.displaySpeed() == 0.5,
    "the chrome speed at 1/2x is 0.5, got " & $player.displaySpeed()
  player.halfPhase = false
  player.advance(1)
  doAssert player.tick == 1, "the odd frame at 1/2x spends one tick"
  player.advance(1)
  doAssert player.tick == 1, "the even frame at 1/2x spends no tick"
  player.advance(10)
  doAssert player.tick == 6, "10 more frames advance 5 ticks at 1/2x"
  player.applyCommand("+")
  doAssert player.speed == 1, "'+' from 1/2x lands on 1x"
  player.applyCommand("-")
  doAssert player.speed == ReplayHalfSpeed, "'-' from 1x lands on 1/2x"
  player.applyCommand("-")
  doAssert player.speed == ReplayHalfSpeed, "1/2x is the floor"
  player.applyCommand("2")
  doAssert player.speed == 2 and player.displaySpeed() == 2.0,
    "the integer chips still work after 1/2x"

echo "test_replay: OK"
