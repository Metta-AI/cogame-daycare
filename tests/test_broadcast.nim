## The chrome frame, and the page the chrome lives in.
##
## Design note ## Tests, item 8.

import std/[json, os, sets, strutils, unicode]
import bitworld/spriteprotocol
import helpers

let root = currentSourcePath().parentDir().parentDir()

echo "test_broadcast: teams, roster and lead are the STARTER'S shapes"
for variant in AllVariants:
  let sim = playEpisode(variantConfig(variant, 7))
  var tracker = initBroadcastTracker()
  let first = parseJson(buildStateJson(liveChromeInput(sim, tracker, 0)))
  let where = variant & ": "

  # teams: exactly parent and child, each carrying the headline the starter's
  # own teamName() path reads, and `lives` = that seat's SCORE (the scorebug's
  # Lives label is re-lettered Score in the page).
  var keys: seq[string]
  for key, _ in first["teams"]:
    keys.add key
  doAssert keys.len == 2, where & $keys
  doAssert "parent" in keys and "child" in keys, where & $keys
  doAssert first["teams"]["parent"]["policies"].to(seq[string]) == @["Parent"]
  doAssert first["teams"]["child"]["policies"].to(seq[string]) == @["Child"]
  for slot in 0 .. 1:
    let key = teamKey(sim.roleOf[slot])
    doAssert first["teams"][key]["lives"].getInt() == sim.cogs[slot].score,
      where & key & " lives is not the score"

  # roster: two entries, the ALIAS in `name` and the POLICY name in `pol` —
  # two name spaces, both, not either.
  doAssert first["roster"].len == 2, where & $first["roster"].len
  for entry in first["roster"]:
    let slot = entry["s"].getInt()
    doAssert entry["name"].getStr() == sim.names[slot], where & "alias"
    doAssert entry["pol"].getStr() == sim.policyNames[slot], where & "policy"
    doAssert entry["team"].getStr() == teamKey(sim.roleOf[slot])
    doAssert entry.hasKey("alive") and entry.hasKey("lives")
    doAssert entry["pk"].kind == JArray
  # Aliases follow the ROLE, never the slot: Alder is always the parent.
  doAssert sim.names[sim.parentSeat] == "Alder", where & $sim.names
  doAssert sim.names[sim.childSeat] == "Bramble", where & $sim.names
  if variant == "daycare-swapped":
    doAssert sim.roleOf[0] == rChild, where & "slot0Role was ignored"
  doAssert sim.policyNames[0] != sim.names[0], where & "policy == alias"

  # lead: {teams, pts} with [t, parent, child] rows — the shape
  # chrome_common.js's ingestLeadSeries / renderMomentum expect, unchanged.
  doAssert first["lead"]["teams"].to(seq[string]) == @["parent", "child"]
  doAssert first["lead"]["pts"].len == sim.tick, where & "lead length"
  for row in first["lead"]["pts"]:
    doAssert row.len == 3, where & "lead row " & $row
  doAssert first["lead"]["pts"][0][0].getInt() == 0
  doAssert first.hasKey("beats") and first.hasKey("lulls")

  # The full-match series and the beat timeline ride the FIRST hud frame only.
  let second = parseJson(buildStateJson(liveChromeInput(sim, tracker, 0)))
  doAssert not second.hasKey("lead"), where & "lead re-sent"
  doAssert not second.hasKey("beats"), where & "beats re-sent"

  # secret: the whole broadcast premise.
  let secret = first["secret"]
  for key in ["pref", "guess", "right", "tape", "rightTurns"]:
    doAssert secret.hasKey(key), where & "secret has no " & key
  doAssert secret["pref"].getStr() == $sim.preference
  doAssert secret["tape"].len == sim.config.turns,
    where & "tape is " & $secret["tape"].len & " chips, want " &
    $sim.config.turns
  doAssert secret["rightTurns"].getInt() == sim.guessTurnsCorrect
  doAssert secret["right"].getBool() == (sim.guess == sim.preference)
  for chip in secret["tape"]:
    doAssert chip.getInt() in [-1, 0, 1], where & "tape chip " & $chip

  # beats: ONLY the five declared kinds, and every one inside the replay.
  const Declared = ["turn", "guess", "switch", "feast", "gameover"]
  var kinds: HashSet[string]
  for beat in first["beats"]:
    let kind = beat["k"].getStr()
    doAssert kind in Declared, where & "undeclared beat kind " & kind
    kinds.incl kind
    doAssert beat["t"].getInt() >= 0 and beat["t"].getInt() < sim.tick,
      where & "beat at tick " & $beat["t"] & " outside 0.." & $(sim.tick - 1)
  doAssert "turn" in kinds and "gameover" in kinds and "guess" in kinds,
    where & $kinds
  if variant == "daycare-fickle":
    doAssert "switch" in kinds, where & "no switch beat"
  else:
    doAssert "switch" notin kinds, where & "a switch beat outside fickle"

  # over: present on the terminal frame, with the ending in words.
  doAssert first.hasKey("over"), where & "no over on the terminal frame"
  doAssert first["over"]["ending"].getStr() == "turn_limit"
  doAssert first["over"]["reason"].getStr() == "complete"
  doAssert first["over"]["preference"].getStr() == $sim.preference
  doAssert first["over"]["par"].getInt() == sim.config.parScore()

  # The clock is spelled out from these, never T4.
  doAssert first["turns"].getInt() == sim.config.turns
  doAssert first["mx"].getInt() == sim.config.totalTicks()

echo "test_broadcast: a mid-episode frame carries only this tick's events, " &
  "and every recorded string is inside its cap"
block:
  let cfg = variantConfig("daycare", 12)
  var sim = initSim(cfg, ["daycare-attentive", "daycare-caretaker"])
  var tracker = initBroadcastTracker()
  var hedge = 0
  var totalEvents = 0
  for turn in 1 .. cfg.turns:
    sim.turn = turn
    for seat in 0 .. 1:
      var order = orderFor(sim, seat, prCareCare, hedge)
      order.hunch = "\u00fc".repeat(MaxHunchLen + 30)
      order.notes = "\u00e9".repeat(MaxNotesLen + 30)
      sim.applyOrder(seat, order)
    for tick in 1 .. cfg.ticksPerTurn:
      sim.stepTick()
      let frame = parseJson(buildStateJson(liveChromeInput(sim, tracker, 0)))
      totalEvents += frame["events"].len
      for row in frame["events"]:
        for field, cap in {"hunch": MaxHunchLen, "notes": MaxNotesLen}.items:
          let node = row{field}
          if node.isNil or node.kind != JString: continue
          doAssert node.getStr().runeLen <= cap,
            field & " is " & $node.getStr().runeLen & " runes"
          doAssert validateUtf8(node.getStr()) == -1, field & " is not UTF-8"
      doAssert frame["t"].getInt() == sim.tick
    sim.closeTurn()
  sim.settle("complete", "turn_limit")
  doAssert totalEvents > 0
  doAssert totalEvents <= sim.events.len

echo "test_broadcast: the replay rebuilds the same chrome from recorded state"
block:
  let sim = playEpisode(variantConfig("daycare-fickle", 5))
  var player = loadReplay(replayJson(sim, sim.resultsJson()))
  let first = parseJson(buildStateJson(replayChromeInput(player, true)))
  doAssert first["roster"].len == 2
  doAssert first["lead"]["pts"].len == sim.tick
  doAssert first["secret"]["tape"].len == sim.config.turns
  doAssert first["en"].getBool(), "the transport must be live on a replay"
  # In daycare-fickle the reveal changes exactly when the preference does.
  let before = player.preferenceAt(0)
  let after = player.preferenceAt(player.maxTick)
  doAssert before != after, "the fickle reveal never changed"
  player.tick = player.maxTick
  let last = parseJson(buildStateJson(replayChromeInput(player, false)))
  doAssert last["ph"].getStr() == "gameover"
  doAssert last.hasKey("over")
  doAssert last["over"]["ending"].getStr() == "turn_limit"
  doAssert last["secret"]["pref"].getStr() == $after
  # The endcard's tally line is the PAIR's totals, not a per-slot array: an
  # array reaches the DOM as "0,3 reaches".
  doAssert last["over"]["wasted"].kind == JInt, $last["over"]["wasted"]
  doAssert last["over"]["reaches"].kind == JInt, $last["over"]["reaches"]
  doAssert last["over"]["reaches"].getInt() == sim.reaches[0] + sim.reaches[1]
  # Every seek is an array index, and it dismisses nothing by re-simulating.
  player.applyCommand("s:0")
  doAssert player.tick == 0
  let seeked = parseJson(buildStateJson(replayChromeInput(player, false)))
  doAssert seeked["t"].getInt() == 0
  doAssert seeked["ph"].getStr() == "playing"
  doAssert not seeked.hasKey("over"), "the endcard survived a seek to 0"

echo "test_broadcast: the board packet is a valid sprite-protocol stream"
block:
  let sim = playEpisode(variantConfig("daycare", 2))
  var player = loadReplay(replayJson(sim, sim.resultsJson()))
  var view = initViewerState()
  for tick in [0, 1, 100, 500, player.maxTick]:
    player.tick = tick
    let chrome = buildStateJson(replayChromeInput(player, tick == 0))
    let packet = buildViewerPacket(view, player.snapshotAt(tick), chrome)
    doAssert packet.len > 0
    # The chrome rides the LABEL of the reserved 1x1 sprite; the label is a u16
    # length on the wire, so it must fit.
    doAssert chrome.len < 65_536,
      "the chrome label is " & $chrome.len & " bytes; the wire caps it at 65535"
    var sawChrome = false
    var sawBand = false
    for message in parseSpritePacket(packet):
      if message.kind == spkSprite:
        if message.sprite.id == BroadcastChromeSpriteId:
          sawChrome = true
          doAssert message.sprite.label == chrome
          doAssert message.sprite.width == 1 and message.sprite.height == 1
      elif message.kind == spkObject:
        if message.objectDef.id in MapBandObjectBase ..< MapBandObjectBase + 8:
          sawBand = true
          doAssert message.objectDef.z == StaticBandZ
    doAssert sawChrome, "no chrome sprite at tick " & $tick
    if tick == 0:
      doAssert sawBand, "no static map band on the first packet"

echo "test_broadcast: scope-duplication — no game-block function shadows a " &
  "chrome alias"
block:
  # A game-block `function markBeat` is HOISTED over the chrome alias block's
  # `var markBeat = C.markBeat` and silently kills every scrubber beat (tandem,
  # 2026-08-23). This walks the actual page.
  const IdentChars = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '$'}

  proc identBefore(text: string, at: int): string =
    ## The identifier immediately left of `at`, skipping whitespace.
    var i = at - 1
    while i >= 0 and text[i] in {' ', '\t'}: dec i
    var last = i
    while i >= 0 and text[i] in IdentChars: dec i
    if last <= i: return ""
    text[i + 1 .. last]

  proc identAfter(text: string, at: int): string =
    var i = at
    while i < text.len and text[i] in {' ', '\t'}: inc i
    var first = i
    while i < text.len and text[i] in IdentChars: inc i
    if i <= first: return ""
    text[first ..< i]

  proc scriptBlocks(page: string): seq[string] =
    var i = 0
    while true:
      let open = page.find("<script>", i)
      if open < 0: break
      let close = page.find("</script>", open)
      if close < 0: break
      result.add page[open + len("<script>") ..< close]
      i = close + len("</script>")

  let page = readFile(root / "client" / "replay_broadcast.html")
  # Every name the starter's own alias block binds from the chrome:
  #   var markBeat = C.markBeat, renderTransport = C.renderTransport, ...
  var aliases: HashSet[string]
  var scan = 0
  while true:
    let at = page.find("= C.", scan)
    if at < 0: break
    let name = identBefore(page, at)
    if name.len > 0: aliases.incl name
    scan = at + 4
  doAssert aliases.len > 20, "found only " & $aliases.len & " chrome aliases"
  doAssert "markBeat" in aliases
  doAssert "renderTransport" in aliases

  # The appended game block is the FIRST <script> in the page (it wraps
  # window.ChromeCommon, so it must run before the starter's own IIFE).
  let blocks = scriptBlocks(page)
  doAssert blocks.len == 2, $blocks.len & " script blocks"
  let gameBlock = blocks[0]
  doAssert "DAYCARE additions to the inherited coworld-ctf chrome" in gameBlock
  var declared: HashSet[string]
  scan = 0
  while true:
    let at = gameBlock.find("function ", scan)
    if at < 0: break
    let name = identAfter(gameBlock, at + len("function "))
    if name.len > 0: declared.incl name
    scan = at + len("function ")
  doAssert declared.len > 5, $declared
  for name in declared:
    doAssert name notin aliases,
      "the game block declares `function " & name & "`, which the chrome " &
      "alias block also binds: hoisting would shadow it"
  doAssert "buildCareBeats" in declared,
    "the game block's beat builder must be buildCareBeats"
  doAssert "markBeat" notin declared

echo "test_broadcast: the page is the starter's page, minus exactly the " &
  "removed elements, plus the game block"
block:
  let page = readFile(root / "client" / "replay_broadcast.html")
  # Removed: #viewpanel and its children, #fpv and its children, #povBadge,
  # #mmwarn -- markup, CSS and the JS branches that touched them.
  for gone in ["viewpanel", "minimap", "zoombar", "zoom-slider", "zoom-read",
      "povBadge", "mmwarn", "fpv-canvas", "fpv-hud", "fpv-map", "fpv-grip",
      "renderPov", "renderFpv", "renderMismatch", "syncViewUi",
      "ingestFpMap"]:
    doAssert gone notin page, "the page still mentions " & gone
  # Kept: everything else the design note lists.
  for kept in ["stage", "viewport", "board", "chrome", "scorebug", "plates-l",
      "plates-r", "clock", "clock-time", "clock-caption", "tick-clock",
      "bannerlane", "killfeed", "grain", "lightpool", "speedchips",
      "ffwd-chip", "ffwd-mini", "win-chip", "transport", "btn-restart",
      "btn-back", "btn-play", "btn-fwd", "btn-skip", "btn-end", "btn-loop",
      "btn-spoilers", "scrub", "momentum", "scrub-fill", "lulls", "scrub-win",
      "scrub-head", "endcard", "ec-headline", "ec-how", "ec-teams",
      "ec-wincond", "ec-replay", "status", "lockerroom"]:
    doAssert "\"" & kept & "\"" in page or "'" & kept & "'" in page or
      "id=\"" & kept & "\"" in page or "#" & kept in page,
      "the page lost " & kept
  # The two re-lettered literals, and only those two.
  doAssert ">Score<" in page, "the Lives label was not re-lettered"
  doAssert "lives-label\">Lives<" notin page
  doAssert ">SCORE<" in page, "the momentum label was not re-lettered"
  doAssert "LIVES LEAD" notin page
  # The curtain must not swallow transport clicks (ecos, 2026-08-23).
  doAssert "#lockerroom { pointer-events: none; }" in page
  # The scorebug must stay legible at 360 px.
  doAssert "min-width: 3.2em" in page
  doAssert "@media (max-width: 640px)" in page
  # Beat CSS for EVERY kind the game emits.
  for kind in ["turn", "guess", "switch", "feast", "gameover"]:
    doAssert ".beat-marker." & kind in page,
      "no beat-marker CSS for " & kind
  # No overlay in the transport band: the appended layer is clipped to the
  # board region between --topband and --band.
  doAssert "inset: var(--topband, 0px) 0 var(--band, 0px) 0" in page
  # chrome_common.js ships byte-for-byte, so the wire global keeps its name.
  let chromeCommon = readFile(root / "client" / "chrome_common.js")
  doAssert "window.ChromeCommon" in chromeCommon
  doAssert "window.CTF_WIRE" in chromeCommon
  doAssert "daycare" notin chromeCommon.toLowerAscii(),
    "chrome_common.js was edited; it must ship byte-for-byte"
  let core = readFile(root / "client" / "broadcast_core.js")
  doAssert "daycare" notin core.toLowerAscii(),
    "broadcast_core.js was edited; the board draw lives in Nim, not here"

echo "test_broadcast: the static bundle's shell and link flags are a MATCHED " &
  "pair, from one starter"
block:
  let worker = readFile(root / "replay-viewer" / "static_replay_worker.js")
  let shell = readFile(root / "replay-viewer" / "static_replay.js")
  let flags = readFile(root / "replay-viewer" / "config.nims")
  # Paintbot-lineage shells wait for Module.onRuntimeInitialized, so the link
  # flags must NOT be MODULARIZE/EXPORT_NAME. A mixture throws nothing, logs
  # nothing and hangs on "Loading replay..." forever (cogame-lantern).
  doAssert "Module.onRuntimeInitialized" in worker
  doAssert "MODULARIZE" notin flags
  doAssert "EXPORT_NAME" notin flags
  doAssert "ALLOW_MEMORY_GROWTH" in flags
  doAssert "ABORTING_MALLOC=1" in flags
  doAssert "FILESYSTEM=1" in flags
  doAssert "ENVIRONMENT=web,worker,node" in flags
  doAssert "EXPORTED_RUNTIME_METHODS=HEAPU8" in flags
  doAssert "--preload-file" in flags
  doAssert "--mm:arc" in flags
  doAssert "--exceptions:goto" in flags
  doAssert "useMalloc" in flags
  for fn in ["_daycare_load_replay", "_daycare_frame", "_daycare_input",
      "_daycare_packet_ptr", "_daycare_packet_len", "_daycare_error_ptr",
      "_daycare_error_len", "_daycare_stage_ptr", "_daycare_stage_len"]:
    doAssert fn in flags, fn & " is not exported"
  doAssert "_ctf_" notin flags
  doAssert "mismatch_tick" notin flags,
    "Daycare records state; there is no re-simulation to mismatch"
  doAssert "importScripts('./wire_constants.js', './broadcast_core.js', " &
    "'./daycare_replay.js');" in worker
  # The two signals viewer_smoke.mjs and phase 60's viewer-check.yml read.
  doAssert "data-replay-loaded" in shell
  doAssert "setAttribute('data-replay-error'" in shell
  # The bundle is declared static; there is no /client/replay pod anywhere.
  let server = readFile(root / "src" / "daycare" / "server.nim")
  doAssert "\"/client/replay\"" notin server,
    "a /client/replay live-viewer route is a bug: the replay is a STATIC " &
    "bundle, never a pod"
  doAssert "/client/global" in server
  doAssert "/client/player" in server
  doAssert "/healthz" in server

echo "test_broadcast: OK"
