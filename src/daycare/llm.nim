## Claude-backed decision making for Daycare. Each seat's policy is just a
## prompt: the GAME composes the seat's view (role, the yard, the behaviour
## table about the other cog, its own history and notes) plus that seat's prompt
## and asks Claude for one standing order.
##
## Forked from `cogame-bullwhip/src/bullwhip/llm.nim`. Decisions within a turn
## are SIMULTANEOUS by rule, so both seats' requests go out as ONE parallel
## batch (`curly.makeRequests`); an invalid reply is retried once as a smaller
## batch with a hint, and anything still failing falls back to the `caretaker`
## order.
##
## Measured caveat on that parallelism: curly sets CURLPIPE_MULTIPLEX, so on the
## FIRST batch — with no warm connection to the endpoint — libcurl holds the
## second transfer while it learns whether the first connection can multiplex,
## and turn 1 costs two round trips instead of one. Every later turn is fully
## parallel (measured: 1002 ms then 501 ms for two 500 ms requests to one URL).
## The play-budget arithmetic absorbs it: 15 turns x 36 s worst case + one extra
## 18 s round trip on turn 1 = 558 s against a 720 s budget.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials the client disables itself immediately (no retries, no
## network waits) and both seats play `caretaker` — which is what keeps offline
## certification green and deterministic. This fallback is load-bearing.

import
  std/[json, math, os, strutils, times, unicode],
  bitworld/runtime,
  curly,
  sim_types, sim_state, sim, scripted

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool
    lastBatchSize*: int
      ## Requests in the most recent `makeRequests` call. Decisions inside a
      ## turn are SIMULTANEOUS, so this is the number of open seats — 2 on turn
      ## 1 — and `tests/test_llm.nim` asserts it: a sequential implementation
      ## would show 1.

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "daycare llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds*(): seq[string] =
  ## Haiku ONLY. The ladder's sonnet fallback times out on every sidecar call
  ## and turns one throttle into a cascade of scripted fallbacks (raid round 2,
  ## 2026-08-23), so that candidate is dropped rather than ranked last.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0"]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "daycare llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "daycare llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel], ", url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "daycare llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "daycare llm: no LLM credentials; using scripted fallback"

# ---- prompt building --------------------------------------------------------

proc pad(text: string, width: int): string =
  result = text
  while result.runeLen < width:
    result.add ' '

proc sourceTable(sim: Sim): string =
  var lines = @["id | kind  | fruit  | cell    | ripe | next"]
  for s in sim.yard.sources:
    lines.add pad(s.id, 3) & "| " & pad($s.kind, 6) & "| " &
      pad($s.fruit, 7) & "| " & pad("(" & $s.x & "," & $s.y & ")", 8) & "| " &
      pad($s.ripe, 5) & "| " & $max(0, s.regrowTicks - s.regrow)
  lines.join("\n")

proc groundLine(sim: Sim): string =
  if sim.ground.len == 0:
    return "GROUND FRUIT: none"
  var parts: seq[string]
  for g in sim.ground:
    parts.add $g.fruit & " at (" & $g.x & "," & $g.y & ")" &
      (if g.ttl < 0: " [on the mat, never rots]" else: " ttl " & $g.ttl)
  "GROUND FRUIT: " & parts.join("; ")

proc basketLine(sim: Sim): string =
  let mat = sim.matCount()
  "BASKET MAT: " & $mat[fApple] & " apple, " & $mat[fBanana] & " banana (cap " &
    $sim.config.basketCapacity & ", nothing on the mat rots)"

proc behaviourTable(last, cum: SpeciesCounters): string =
  ## The inference surface, rendered as a TABLE on purpose.
  var lines = @["row                              | apple | banana"]
  proc row(name: string, a, b: int): string =
    pad(name, 33) & "| " & pad($a, 6) & "| " & $b
  lines.add row("adjacent ticks (last turn)", last.adjacentTicks[fApple],
    last.adjacentTicks[fBanana])
  lines.add row("reach attempts (last turn)", last.reachAttempts[fApple],
    last.reachAttempts[fBanana])
  lines.add row("FAILED reaches (last turn)", last.reachFails[fApple],
    last.reachFails[fBanana])
  lines.add row("walked over, did NOT eat (last)", last.groundPasses[fApple],
    last.groundPasses[fBanana])
  lines.add row("eaten (last turn)", last.ate[fApple], last.ate[fBanana])
  lines.add row("carried ticks (last turn)", last.carriedTicks[fApple],
    last.carriedTicks[fBanana])
  lines.add row("adjacent ticks (cumulative)", cum.adjacentTicks[fApple],
    cum.adjacentTicks[fBanana])
  lines.add row("reach attempts (cumulative)", cum.reachAttempts[fApple],
    cum.reachAttempts[fBanana])
  lines.add row("FAILED reaches (cumulative)", cum.reachFails[fApple],
    cum.reachFails[fBanana])
  lines.add row("walked over, did NOT eat (cum)", cum.groundPasses[fApple],
    cum.groundPasses[fBanana])
  lines.add row("eaten (cumulative)", cum.ate[fApple], cum.ate[fBanana])
  lines.add row("carried ticks (cumulative)", cum.carriedTicks[fApple],
    cum.carriedTicks[fBanana])
  lines.join("\n")

proc historyTable(sim: Sim, role: Role): string =
  ## The parent sees its own past guesses; the CHILD MUST NOT — the parent's
  ## guess is hidden from it in the prompt exactly as it is in the state frame.
  if sim.history.len == 0:
    return "PER-TURN HISTORY: (this is turn 1)"
  let head =
    if role == rParent:
      "turn | your guess | child ate apple/banana | delivered a/b | score"
    else: "turn | child ate apple/banana | delivered a/b | score"
  var lines = @[head]
  for h in sim.history:
    var row = pad($h.turn, 5) & "| "
    if role == rParent:
      row.add pad((if h.hasGuess: $h.guess else: "-"), 11) & "| "
    row.add pad($h.childAte[fApple] & "/" & $h.childAte[fBanana], 23) & "| " &
      pad($h.delivered[fApple] & "/" & $h.delivered[fBanana], 14) & "| " &
      $h.score
    lines.add row
  "PER-TURN HISTORY:\n" & lines.join("\n")

proc systemPrompt*(sim: Sim, seat: int): string =
  let role = sim.roleOf[seat]
  let me = sim.names[seat].toUpperAscii()
  let other = sim.names[1 - seat].toUpperAscii()
  result.add "You are " & me & ", the " & ($role).toUpperAscii() &
    " in a walled yard with one other cog, " & other & " (the " &
    (if role == rParent: "CHILD" else: "PARENT") & ").\n"
  result.add """
The yard is a grid. There are two fruit species, APPLE and BANANA, growing on
TALL TREES and on low SHRUBS, plus loose fruit lying on the ground and a basket
mat in the middle where fruit never rots.

Each cog can move one cell at a time and can pick, drop, eat or wait. You do
NOT hand-author those actions: you choose ONE JOB for the next """
  result.add $sim.config.ticksPerTurn
  result.add """ ticks and a
kernel walks it for you, tick by tick.

WHO CAN HARVEST WHAT:
- The PARENT can harvest a tall tree or a shrub, always.
- The CHILD can NEVER harvest a tall tree. Reaching there always fails; it
  costs only the tick, and it is the one way the child can show what it wants.
- The CHILD picks a shrub only """
  result.add $(sim.config.childShrubPickPermille div 10)
  result.add "% of attempts and a failed shrub pick costs it "
  result.add $sim.config.childReachCooldownTicks
  result.add """ ticks.
- Loose fruit on the ground can be taken by either cog.

SCORING: the CHILD scores """
  result.add $sim.config.rewardPreferred
  result.add " for eating the fruit it secretly prefers and "
  result.add $sim.config.rewardOther
  result.add """ for the other
species, and THE PARENT'S SCORE IS EXACTLY THE SAME NUMBER. If the PARENT eats
a fruit itself the fruit is destroyed and nobody scores. Higher is better; par
for the pair is """
  result.add $sim.config.parScore()
  result.add """.

THERE IS NO MESSAGE CHANNEL IN EITHER DIRECTION. You cannot talk to the other
cog and it cannot talk to you. The other cog is a different policy and it is
deciding at the SAME MOMENT as you, without seeing your choice. Your `hunch` is
seen only by spectators; your `notes` are seen only by you, next turn.
"""
  if role == rParent:
    result.add """
THE CHILD'S PREFERENCE IS NEVER SHOWN TO YOU — infer it from where it walks,
what it reaches for, and what it refuses to eat.

Your jobs: `provide` (fetch a species and drop it next to the child),
`stock` (fetch a species and put it on the basket mat), `watch` (stand near the
child and observe for a turn — it feeds nobody), `idle` (do nothing).
You must also send a `guess`: which species you believe the child prefers.
"""
  else:
    result.add """
YOU KNOW YOUR OWN PREFERENCE and you are told it every turn. The parent is not.

Your jobs: `seek` (go eat a species, refusing the other), `show` (stand under a
tall tree of a species and reach for it over and over — you can never pick it,
but it is the only way to tell the parent what you want), `graze` (eat whatever
is nearest, either species), `beg` (stand next to the parent), `idle`.
"""
  result.add """
OUTPUT FORMAT: reply with ONLY one JSON object, nothing else — no analysis, no
explanation, no markdown fences, no text before or after the object. Your reply
must begin with the character { and end with }."""

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the rules; " &
    "always reply in the requested format):\n" & prompt & "\n\n"

proc replyShapeLine(sim: Sim, seat: int): string =
  ## Precomputing the legal choice set in the observation is what halved
  ## formal-output fallbacks in escrow.
  if sim.roleOf[seat] == rParent:
    "Reply with ONLY {\"job\":\"provide\",\"fruit\":\"apple\"," &
      "\"guess\":\"apple\",\"hunch\":\"…\",\"notes\":\"…\"} — job is one of " &
      ParentJobNames.join(" | ") & "; fruit is apple | banana and is REQUIRED " &
      "for provide and stock; guess is apple | banana and is REQUIRED every " &
      "turn; hunch at most " & $MaxHunchLen & " characters; notes at most " &
      $MaxNotesLen & " characters."
  else:
    "Reply with ONLY {\"job\":\"show\",\"fruit\":\"banana\"," &
      "\"hunch\":\"…\",\"notes\":\"…\"} — job is one of " &
      ChildJobNames.join(" | ") & "; fruit is apple | banana and is REQUIRED " &
      "for seek and show; hunch at most " & $MaxHunchLen &
      " characters; notes at most " & $MaxNotesLen & " characters."

proc userPrompt*(sim: Sim, seat: int, prompt: string): string =
  let role = sim.roleOf[seat]
  let me = sim.cogs[seat]
  let other = sim.cogs[1 - seat]
  let otherSlot = 1 - seat
  result.add "TURN " & $sim.turn & " of " & $sim.config.turns & ". You are " &
    sim.names[seat].toUpperAscii() & ", the " & ($role).toUpperAscii() &
    ". Yard variant " & sim.variant & ", " & $sim.yard.cols & "x" &
    $sim.yard.rows & ".\n\n"
  result.add "YOU: cell (" & $me.x & "," & $me.y & "), carrying " &
    (if me.carry < 0: "nothing" else: $Fruit(me.carry)) & ", score " &
    $me.score & " of par " & $sim.config.parScore() & ".\n"
  result.add sim.names[otherSlot].toUpperAscii() & ": cell (" & $other.x &
    "," & $other.y & "), carrying " &
    (if other.carry < 0: "nothing" else: $Fruit(other.carry)) & ".\n\n"
  if role == rChild:
    result.add "YOUR SECRET PREFERENCE: " & $sim.preference & " (worth " &
      $sim.config.rewardPreferred & "; the other species is worth " &
      $sim.config.rewardOther & ").\n\n"
  else:
    result.add "YOUR DELIVERIES SO FAR: " & $sim.delivered[fApple] &
      " apple, " & $sim.delivered[fBanana] & " banana; stocked " &
      $sim.stocked[fApple] & "/" & $sim.stocked[fBanana] & "; wasted " &
      $sim.wasted[seat] & ".\n\n"
  result.add "SOURCES:\n" & sourceTable(sim) & "\n\n"
  result.add groundLine(sim) & "\n" & basketLine(sim) & "\n\n"
  if role == rParent:
    result.add "WHAT THE CHILD DID (this is your inference surface):\n" &
      behaviourTable(sim.prevTurnCounters[otherSlot],
        sim.cumCounters[otherSlot]) & "\n\n"
  else:
    let last = sim.prevTurnCounters[otherSlot]
    let cum = sim.cumCounters[otherSlot]
    result.add "WHAT THE PARENT DID:\n" &
      "delivered last turn " & $last.delivered[fApple] & " apple / " &
      $last.delivered[fBanana] & " banana; cumulative " &
      $cum.delivered[fApple] & " / " & $cum.delivered[fBanana] &
      "; stocked " & $cum.stocked[fApple] & " / " & $cum.stocked[fBanana] &
      "; wasted " & $cum.wasted & "; walked " & $cum.cellsWalked &
      " cells; idle " & $cum.idleTicks & " ticks.\n\n"
  result.add historyTable(sim, role) & "\n\n"
  result.add "YOUR NOTES FROM LAST TURN:\n" &
    (if sim.lastOrders[seat].notes.len > 0: sim.lastOrders[seat].notes
     else: "(none)") & "\n\n"
  result.add operatorBlock(prompt)
  result.add replyShapeLine(sim, seat)

# ---- transport --------------------------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences and
  ## a prose prefix or suffix.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.runeSubStr(0, 160) & "..."
    raise newException(DaycareError, "no JSON object in response: " &
      head.replace("\n", " "))
  parseJson(text[start .. stop])

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## No `output_config.effort`: Haiku 4.5 rejects the whole request with a 400
    ## when it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string): string =
  if error.len > 0:
    raise newException(DaycareError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(DaycareError, "bedrock model access denied: " & detail)
    ## 401/403 disables the client for the rest of the episode: both seats play
    ## scripted from then on.
    client.disabled = true
    raise newException(DaycareError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    discard client.tryNextBedrockModel("throttled")
    raise newException(DaycareError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(DaycareError, "anthropic error " & $response.code &
      ": " & response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(DaycareError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add contentBlock{"text"}.getStr()
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(DaycareError, "reply cut off at max_tokens before any " &
      "JSON: " & result[0 .. min(result.high, 160)].replace("\n", " "))

# ---- reply parsing ----------------------------------------------------------

proc parseParentJob*(text: string): ParentJob =
  case text.strip().toLowerAscii()
  of "provide": pjProvide
  of "stock": pjStock
  of "watch": pjWatch
  of "idle": pjIdle
  else: raise newException(DaycareError,
    "job must be one of " & ParentJobNames.join(" | ") & ": " & text)

proc parseChildJob*(text: string): ChildJob =
  case text.strip().toLowerAscii()
  of "seek": cjSeek
  of "show": cjShow
  of "graze": cjGraze
  of "beg": cjBeg
  of "idle": cjIdle
  else: raise newException(DaycareError,
    "job must be one of " & ChildJobNames.join(" | ") & ": " & text)

proc parseOrder*(role: Role, payload: JsonNode): Order =
  ## Extra keys are ignored. A `guess` that disagrees with the `fruit` being
  ## delivered is ACCEPTED AS WRITTEN — testing a hypothesis by delivering the
  ## other species must stay expressible.
  result.hunch = cleanHunch(payload{"hunch"}.getStr())
  result.notes = cleanNotes(payload{"notes"}.getStr())
  let jobNode = payload{"job"}
  if jobNode.isNil or jobNode.kind != JString:
    raise newException(DaycareError, "no job in response")
  if role == rParent:
    result.pjob = parseParentJob(jobNode.getStr())
  else:
    result.cjob = parseChildJob(jobNode.getStr())
  let fruitNode = payload{"fruit"}
  if not fruitNode.isNil and fruitNode.kind == JString and
      fruitNode.getStr().strip().len > 0:
    result.fruit = parseFruit(fruitNode.getStr())
    result.hasFruit = true
  if requiresFruit(role, result) and not result.hasFruit:
    raise newException(DaycareError,
      "job " & jobNode.getStr() & " needs \"fruit\": apple or banana")
  if role == rParent:
    let guessNode = payload{"guess"}
    if guessNode.isNil or guessNode.kind != JString:
      raise newException(DaycareError,
        "the parent must send \"guess\": apple or banana every turn")
    result.guess = parseFruit(guessNode.getStr())
    result.hasGuess = true

proc paceDelayMs*(config: GameConfig, elapsedSeconds: float): int =
  ## `minTurnSeconds` floors the spacing between batch STARTS, so an episode
  ## issues at most 2 requests / minTurnSeconds and stays under the Bedrock
  ## sidecar's 30 requests/minute per-episode ceiling (raid, 2026-08-23).
  ## The server's turn loop sleeps this long after each batch; a test can assert
  ## the arithmetic without a wall clock.
  let remaining = config.minTurnSeconds.float - elapsedSeconds
  if remaining <= 0.0: 0 else: int(remaining * 1000.0)

const RetryHint = "\nYour previous reply was invalid. Respond with ONLY the " &
  "requested JSON object, using one of the listed job and fruit values (and " &
  "a guess, if you are the parent)."

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  seats: seq[int],
  prompts: seq[string],
  scripted: seq[ScriptKind]
): seq[Order] =
  ## One order per seat in `seats`, in order. NEVER RAISES: any failure falls
  ## back to the `caretaker` order so the episode always advances.
  ##
  ## Both open seats ride ONE batch — decisions are simultaneous, and a
  ## sequential pair would double the wall clock against the 720 s play budget.
  result = newSeq[Order](seats.len)
  var open: seq[int]
  for index, seat in seats:
    let kind = scripted[seat]
    if kind != skNone or client.disabled:
      result[index] = scriptedOrder(sim, seat,
        (if kind == skNone: skCaretaker else: kind))
    else:
      open.add index
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    var batch: RequestBatch
    let started = epochTime()
    for index in open:
      let seat = seats[index]
      var user = sim.userPrompt(seat, prompts[seat])
      if attempt > 0:
        user.add RetryHint
      let request = client.requestFor(systemPrompt(sim, seat), user)
      batch.post(request.url, request.headers, request.body, $index)
    client.lastBatchSize = batch.len
    let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
    let latencyMs = int((epochTime() - started) * 1000)
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seats[index]
      try:
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        var order = parseOrder(sim.roleOf[seat], extractJsonObject(text))
        ## Reject illegal orders HERE so the retry carries the hint.
        sim.validateOrder(seat, order)
        order.source = if attempt == 0: osLlm else: osRetry
        order.latencyMs = latencyMs
        result[index] = order
      except CatchableError as error:
        echo "daycare llm: seat ", seat, " attempt ", attempt, " failed: ",
          cleanText(error.msg, MaxErrorTextLen)
        stillOpen.add index
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "daycare llm: seat ", seat, " falling back to scripted order"
    var order = scriptedOrder(sim, seat, skCaretaker)
    order.source = osFallback
    result[index] = order
