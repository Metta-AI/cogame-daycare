## The Daycare game server: the Coworld game contract.
##
## Fork of `coworld-ctf/src/ctf/server.nim`'s route / artifact / shutdown
## skeleton, with bullwhip's JSON player protocol in place of paintbot's binary
## seat channel.
##
## Routes, kept EXACTLY because hosted certification probes these before the
## player pods start (lantern, 2026-08-23):
##   GET /healthz                     200 ok, until shutdownGraceSeconds after
##                                    the artifacts are written
##   GET /client/player?slot=&token=  the seat's HTML shell; it never opens the
##                                    player socket
##   WS  /player?slot=&token=         the seat socket; a bad token is refused
##                                    with a close, never a hang
##   GET /client/global               the broadcast client (spliced)
##   WS  /global                      live spectator: the sprite protocol plus
##                                    the chrome label

import
  std/[json, locks, os, sets, strutils, tables, times, unicode],
  bitworld/runtime,
  bitworld/spriteprotocol,
  curly,
  mummy,
  mummy/routers,
  sim_types, yard, sim_state, sim, scripted, llm, replays, broadcast, global,
  wire_constants

const
  EmbeddedBroadcastHtml = spliceWireConstants(
      staticRead("../../client/replay_broadcast.html")
    )
    .replace("<!-- CHROME_COMMON -->",
      "<script>" & staticRead("../../client/chrome_common.js") & "</script>")
    .replace("<!-- BROADCAST_CORE -->",
      "<script>" & staticRead("../../client/broadcast_core.js") & "</script>")
  EmbeddedPlayerHtml = staticRead("../../client/player.html")

  ## The chrome's own display face. `client/replay_broadcast.html` ships
  ## verbatim and its @font-face asks for ./font.ttf relative to the page, so
  ## the page's own directory has to answer.
  EmbeddedFont = staticRead("../../data/font.ttf")

  ## The loading curtain the inherited #lockerroom markup asks for, embedded
  ## rather than read from disk: the image ships one directory tree and a
  ## missing asset must be a compile error, not a broken curtain.
  LockerArt: array[21, (string, string)] = [
    ("bg.jpg", staticRead("../../client/art/lockerroom/bg.jpg")),
    ("blue_1.webp", staticRead("../../client/art/lockerroom/blue_1.webp")),
    ("blue_2.webp", staticRead("../../client/art/lockerroom/blue_2.webp")),
    ("blue_3.webp", staticRead("../../client/art/lockerroom/blue_3.webp")),
    ("blue_5.webp", staticRead("../../client/art/lockerroom/blue_5.webp")),
    ("blue_6.webp", staticRead("../../client/art/lockerroom/blue_6.webp")),
    ("green_1.webp", staticRead("../../client/art/lockerroom/green_1.webp")),
    ("green_2.webp", staticRead("../../client/art/lockerroom/green_2.webp")),
    ("green_3.webp", staticRead("../../client/art/lockerroom/green_3.webp")),
    ("green_5.webp", staticRead("../../client/art/lockerroom/green_5.webp")),
    ("green_6.webp", staticRead("../../client/art/lockerroom/green_6.webp")),
    ("red_1.webp", staticRead("../../client/art/lockerroom/red_1.webp")),
    ("red_2.webp", staticRead("../../client/art/lockerroom/red_2.webp")),
    ("red_3.webp", staticRead("../../client/art/lockerroom/red_3.webp")),
    ("red_5.webp", staticRead("../../client/art/lockerroom/red_5.webp")),
    ("red_6.webp", staticRead("../../client/art/lockerroom/red_6.webp")),
    ("yellow_1.webp", staticRead("../../client/art/lockerroom/yellow_1.webp")),
    ("yellow_2.webp", staticRead("../../client/art/lockerroom/yellow_2.webp")),
    ("yellow_3.webp", staticRead("../../client/art/lockerroom/yellow_3.webp")),
    ("yellow_5.webp", staticRead("../../client/art/lockerroom/yellow_5.webp")),
    ("yellow_6.webp", staticRead("../../client/art/lockerroom/yellow_6.webp")),
  ]

type
  GameState = object
    config: GameConfig
    sim: Sim
    prompts: seq[string]
    scripted: seq[ScriptKind]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    viewers: Table[WebSocket, ViewerState]
    trackers: Table[WebSocket, BroadcastTracker]
    started: bool
    finished: bool
    servingUntil: float   ## /healthz and /global keep answering until this

var
  stateLock: Lock
  state: GameState
  gameServer: Server

initLock(stateLock)

# ---------------------------------------------------------------------------
# broadcast
# ---------------------------------------------------------------------------

proc liveSnapshot(sim: Sim): BoardSnapshot =
  result.cols = sim.yard.cols
  result.rows = sim.yard.rows
  result.cell = CellPx
  result.tick = sim.tick
  result.showLabels = sim.config.showPlayerLabels
  result.kinds = newSeq[int](sim.yard.cell.len)
  for i, k in sim.yard.cell:
    result.kinds[i] = ord(k)
  for s in sim.yard.sources:
    result.sourceKind.add ord(s.kind)
    result.sourceFruit.add ord(s.fruit)
    result.sourceX.add s.x
    result.sourceY.add s.y
    result.sourceRipe.add s.ripe
  for g in sim.ground:
    result.groundX.add g.x
    result.groundY.add g.y
    result.groundFruit.add ord(g.fruit)
    result.groundTtl.add g.ttl
  for seat in 0 .. 1:
    result.cogX[seat] = sim.cogs[seat].x
    result.cogY[seat] = sim.cogs[seat].y
    result.cogCarry[seat] = sim.cogs[seat].carry
    result.cogRole[seat] = ord(sim.roleOf[seat])
    result.names[seat] = sim.names[seat]
  for back in 0 ..< ReachCoalesceTicks:
    let t = sim.tick - back
    if t < 0: continue
    for row in sim.events:
      if row{"t"}.getInt() != t: continue
      let seat = row{"seat"}.getInt(-1)
      if seat < 0 or seat > 1: continue
      case row{"k"}.getStr()
      of "reach": result.reaching[seat] = true
      of "waste":
        if back < 4: result.wasting[seat] = true
      of "eat":
        if back < 4: result.eating[seat] = true
      else: discard

proc broadcastLocked(gs: var GameState) =
  ## Spectators get the sprite packet plus the chrome label; players get the
  ## redacted per-seat state frame.
  let snap = liveSnapshot(gs.sim)
  for socket in gs.globalSockets:
    var view = gs.viewers.getOrDefault(socket, initViewerState())
    var tracker = gs.trackers.getOrDefault(socket, initBroadcastTracker())
    let chrome = buildStateJson(liveChromeInput(gs.sim, tracker, 0))
    let packet = buildViewerPacket(view, snap, chrome)
    gs.viewers[socket] = view
    gs.trackers[socket] = tracker
    socket.send(blobFromBytes(packet), BinaryMessage)
  for slot, socket in gs.playerSockets:
    socket.send($gs.sim.playerStateJson(slot))

# ---------------------------------------------------------------------------
# artifacts and shutdown
# ---------------------------------------------------------------------------

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  var grace = DefaultShutdownGraceSeconds
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    grace = state.config.shutdownGraceSeconds
    results = state.sim.resultsJson()
    replayData = replayJson(state.sim, results)

    ## Final frames go to the players BEFORE the artifacts are written: the
    ## hosted worker tears player pods down as soon as results.json exists.
    ## The `final` frame carries NO `preference` field — the child already knows
    ## it and the parent must never learn it, not even at the buzzer.
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "names": [state.sim.names[0], state.sim.names[1]],
      "roles": results["roles"],
      "turns": results["turns"],
      "reason": results["reason"],
      "ending": results["ending"]
    }
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastLocked()

  sleep(500)
  echo "daycare: writing results and replay"
  writeArtifact(runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD")
  writeArtifact(runtimeConfig.replayUri, replayData,
    "application/octet-stream", "COGAME_SAVE_REPLAY_METHOD")

  ## Hosted certification pings the global websocket AFTER the player pods
  ## start, and a short episode may already have exited (lantern 0.1.3): keep
  ## /healthz and /global answering for a bounded grace, then quit.
  withLock stateLock:
    state.servingUntil = epochTime() + grace.float
  echo "daycare: episode complete; serving /healthz and /global for ",
    grace, "s"
  sleep(grace * 1000)
  echo "daycare: shutting down"
  quit(0)

# ---------------------------------------------------------------------------
# the turn loop
# ---------------------------------------------------------------------------

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = epochTime()
    let connectDeadline =
      gameStart + config.playerConnectTimeoutSeconds.float

    while epochTime() < connectDeadline:
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= 2
      if allConnected:
        break
      sleep(200)

    ## Both sockets are up; give the prompt frames a bounded moment to land.
    ## The player sends its prompt on connect AND again after `welcome`, so a
    ## seat whose prompt has not arrived yet would silently play `caretaker` for
    ## turn 1. Bounded, so a seat that never sends one costs at most this.
    let promptDeadline = epochTime() + 2.0
    while epochTime() < promptDeadline:
      var pending = false
      withLock stateLock:
        for slot in 0 .. 1:
          if state.playerSockets.hasKey(slot) and
              state.prompts[slot].len == 0 and state.scripted[slot] == skNone:
            pending = true
      if not pending:
        break
      sleep(50)

    var connected = 0
    withLock stateLock:
      state.started = true
      connected = state.playerSockets.len
      echo "daycare: starting with ", connected, "/2 players connected"
      state.broadcastLocked()

    if connected == 0:
      ## No seat present at all -> forfeit. A MISSING seat does not end the
      ## episode: it plays `caretaker` and the game runs.
      echo "daycare: no player connected within ",
        config.playerConnectTimeoutSeconds, "s; forfeit"
      withLock stateLock:
        state.sim.forfeit()
        state.broadcastLocked()
      finishEpisode(runtimeConfig)
      return

    let client = newLlmClient(config)

    ## The game container is NOT given COWORLD_TIMEOUT_SECONDS (only the worker
    ## sidecar is), so when the env is silent assume the configured platform
    ## default rather than playing open-ended.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    var timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    if timeoutSeconds <= 0.0:
      timeoutSeconds = config.episodeTimeoutSeconds.float
    let playDeadline =
      if timeoutSeconds > 0.0: gameStart + timeoutSeconds * PlayBudgetFraction
      else: 0.0
    echo "daycare: episode timeout ", timeoutSeconds.int, "s (",
      (if hostedTimeout.len > 0: "from env" else: "assumed"),
      "); playing until ", (timeoutSeconds * PlayBudgetFraction).int, "s"

    for turn in 1 .. config.turns:
      var simCopy: Sim
      var prompts: seq[string]
      var scriptedKinds: seq[ScriptKind]
      withLock stateLock:
        if playDeadline > 0.0 and epochTime() > playDeadline:
          echo "daycare: episode deadline reached after ",
            state.sim.turnsPlayed, "/", config.turns, " turns; ending early"
          state.sim.endEarly()
          state.broadcastLocked()
          break
        state.sim.turn = turn
        simCopy = state.sim
        prompts = state.prompts
        scriptedKinds = state.scripted
        ## A seat whose socket died mid-episode plays `caretaker` for every
        ## remaining turn; the episode never blocks on a socket.
        for slot in 0 .. 1:
          if not state.playerSockets.hasKey(slot) and
              scriptedKinds[slot] == skNone:
            scriptedKinds[slot] = skCaretaker

      let batchStart = epochTime()
      let orders = client.decideAll(simCopy, @[0, 1], prompts, scriptedKinds)

      withLock stateLock:
        for slot in 0 .. 1:
          var order = orders[slot]
          try:
            state.sim.applyOrder(slot, order)
          except CatchableError as error:
            echo "daycare: order rejected (", error.msg,
              "); using the caretaker order"
            var fallback = scriptedOrder(state.sim, slot, skCaretaker)
            fallback.source = osFallback
            state.sim.applyOrder(slot, fallback)
          echo "daycare: turn ", turn, " ", state.sim.names[slot], " (",
            state.sim.roleOf[slot], ") ", state.sim.jobName(slot),
            (if order.hasFruit: " " & $order.fruit else: ""),
            " source=", order.source,
            " at ", (epochTime() - gameStart).int, "s"
        state.sim.playTurn()
        state.broadcastLocked()

      ## `minTurnSeconds` floors the spacing between batch STARTS, so the
      ## episode stays under the Bedrock sidecar's 30 requests/minute
      ## per-episode ceiling (raid, 2026-08-23).
      let pause = paceDelayMs(config, epochTime() - batchStart)
      if pause > 0:
        sleep(pause)

    withLock stateLock:
      if not state.sim.done:
        state.sim.settle("complete", "turn_limit")
      state.broadcastLocked()
    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

# ---------------------------------------------------------------------------
# routes
# ---------------------------------------------------------------------------

proc respondHtml(request: Request, body: string) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html; charset=utf-8"
  request.respond(200, headers, body)

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc globalUpgrade(request: Request) {.gcsafe.}

proc globalPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    ## The inherited `websocketAddress()` in client/broadcast_core.js maps a
    ## client page path to ITSELF unless it ends in /client/replay, so the
    ## broadcast page served at /client/global opens its spectator socket at
    ## /client/global too. Answer both on one route: an Upgrade request is the
    ## live stream, anything else is the page. (chrome_common.js and
    ## broadcast_core.js ship byte-for-byte, so the mapping is not editable
    ## there.)
    if request.headers["Upgrade"].toLowerAscii() == "websocket":
      globalUpgrade(request)
      return
    respondHtml(request, EmbeddedBroadcastHtml)

proc fontHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    var headers: HttpHeaders
    headers["Content-Type"] = "font/ttf"
    headers["Cache-Control"] = "public, max-age=86400"
    request.respond(200, headers, EmbeddedFont)

proc lockerArtHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    for (asset, bytes) in LockerArt:
      if asset != name: continue
      var headers: HttpHeaders
      headers["Content-Type"] =
        if name.endsWith(".webp"): "image/webp"
        elif name.endsWith(".jpg"): "image/jpeg"
        else: "application/octet-stream"
      headers["Cache-Control"] = "public, max-age=3600"
      request.respond(200, headers, bytes)
      return
    request.respond(404)

proc playerPageHandler(request: Request) {.gcsafe.} =
  ## The seat's shell. It NEVER opens the player socket — the certifier fetches
  ## this page before the player pods start and a page that grabbed the slot
  ## would fail the contract check.
  {.gcsafe.}:
    respondHtml(request, EmbeddedPlayerHtml)

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      echo "daycare: player slot ", slot, " connected (",
        state.playerSockets.len, "/2)"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": PlayerProtocol,
        "slot": slot,
        "role": $state.sim.roleOf[slot],
        "name": state.sim.names[slot],
        "turns": state.config.turns,
        "ticksPerTurn": state.config.ticksPerTurn,
        "variant": state.sim.variant
      })

proc globalUpgrade(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      state.viewers[websocket] = initViewerState()
      state.trackers[websocket] = initBroadcastTracker()
      let snap = liveSnapshot(state.sim)
      var view = state.viewers[websocket]
      var tracker = state.trackers[websocket]
      let chrome = buildStateJson(liveChromeInput(state.sim, tracker, 0))
      let packet = buildViewerPacket(view, snap, chrome)
      state.viewers[websocket] = view
      state.trackers[websocket] = tracker
      websocket.send(blobFromBytes(packet), BinaryMessage)

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application; the certifier pings
      ## /global to check the game is alive, so an unanswered ping fails
      ## certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() != "prompt":
          echo "daycare: ignoring player frame of type ",
            payload{"type"}.getStr()
          return
        var prompt = payload{"prompt"}.getStr()
        if prompt.runeLen > MaxPromptLen:
          prompt = prompt.runeSubStr(0, MaxPromptLen)
        let node = payload{"scripted"}
        let kind =
          if node.isNil: skNone
          elif node.kind == JBool:
            (if node.getBool(): skCaretaker else: skNone)
          else: parseScriptKind(node.getStr())
        withLock stateLock:
          state.prompts[slot] = prompt
          state.scripted[slot] = kind
        echo "daycare: slot ", slot, " delivered a prompt (", prompt.len,
          " chars", (if kind != skNone: ", scripted " & $kind else: ""), ")"
      except CatchableError as error:
        echo "daycare: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)
        state.viewers.del(websocket)
        state.trackers.del(websocket)

proc buildRouter(): Router =
  ## `/client/*` pages are registered BEFORE any catch-all so the certifier's
  ## HTTP contract check finds real pages on both.
  result.get("/healthz", healthzHandler)
  result.get("/client/global", globalPageHandler)
  result.get("/client/player", playerPageHandler)
  result.get("/client/font.ttf", fontHandler)
  result.get("/client/art/lockerroom/@name", lockerArtHandler)
  result.get("/global", globalUpgrade)
  result.get("/player", playerUpgradeHandler)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len < 2 or config.players.len < 2:
    raise newException(DaycareError, "daycare needs 2 tokens and 2 players")
  var policyNames: array[2, string]
  for slot in 0 .. 1:
    policyNames[slot] = config.players[slot].name
  state.config = config
  state.sim = initSim(config, policyNames)
  state.prompts = newSeq[string](2)
  state.scripted = newSeq[ScriptKind](2)
  state.servingUntil = 0

  let router = buildRouter()
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "daycare: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
