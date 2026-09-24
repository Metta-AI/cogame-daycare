## The decision layer.
##
## Design note ## Tests, item 6. Reply parsing (fenced, prose-prefixed,
## role-crossed, missing fields, hypothesis-testing guesses), and a STUBBED
## TRANSPORT that times out, 429s, 403s or returns junk -- driven through the
## real `curly.makeRequests` path by pointing the Bedrock sidecar endpoint at a
## local mummy server, so the batching, the retry and the fallback are the
## shipped code and not a mock of it.

import std/[atomics, json, os, strformat, strutils, times, unicode]
import mummy, mummy/routers
import helpers
import daycare/llm

# ---------------------------------------------------------------------------
# reply parsing
# ---------------------------------------------------------------------------

echo "test_llm: extractJsonObject tolerates fences and prose"
block:
  let fenced = "```json\n{\"job\":\"provide\",\"fruit\":\"apple\"," &
    "\"guess\":\"apple\"}\n```"
  doAssert extractJsonObject(fenced){"job"}.getStr() == "provide"
  let prose = "Sure! Here is my order for this turn:\n" &
    "{\"job\":\"show\",\"fruit\":\"banana\"}\nLet me know if you want more."
  doAssert extractJsonObject(prose){"job"}.getStr() == "show"
  let trailing = "{\"job\":\"idle\"} — I will just watch."
  doAssert extractJsonObject(trailing){"job"}.getStr() == "idle"
  var raised = false
  try:
    discard extractJsonObject("I am afraid I cannot help with that.")
  except DaycareError:
    raised = true
  doAssert raised, "prose with no object parsed"

echo "test_llm: a parent reply carrying a CHILD-only job is invalid"
block:
  for job in ["seek", "show", "graze", "beg"]:
    var raised = false
    try:
      discard parseOrder(rParent, parseJson(
        "{\"job\":\"" & job & "\",\"fruit\":\"apple\",\"guess\":\"apple\"}"))
    except DaycareError:
      raised = true
    doAssert raised, "the parent was allowed the child job " & job
  for job in ["provide", "stock", "watch"]:
    var raised = false
    try:
      discard parseOrder(rChild, parseJson(
        "{\"job\":\"" & job & "\",\"fruit\":\"apple\"}"))
    except DaycareError:
      raised = true
    doAssert raised, "the child was allowed the parent job " & job

echo "test_llm: a parent reply missing `guess` is invalid"
block:
  var raised = false
  try:
    discard parseOrder(rParent,
      parseJson("{\"job\":\"provide\",\"fruit\":\"apple\"}"))
  except DaycareError:
    raised = true
  doAssert raised
  # ... and `idle` still needs one: the guess is required EVERY turn.
  raised = false
  try:
    discard parseOrder(rParent, parseJson("{\"job\":\"idle\"}"))
  except DaycareError:
    raised = true
  doAssert raised

echo "test_llm: `provide` without a fruit is invalid; `watch` does not need one"
block:
  var raised = false
  try:
    discard parseOrder(rParent,
      parseJson("{\"job\":\"provide\",\"guess\":\"banana\"}"))
  except DaycareError:
    raised = true
  doAssert raised
  let watch = parseOrder(rParent,
    parseJson("{\"job\":\"watch\",\"guess\":\"banana\"}"))
  doAssert watch.pjob == pjWatch and watch.hasGuess and not watch.hasFruit
  raised = false
  try:
    discard parseOrder(rChild, parseJson("{\"job\":\"seek\"}"))
  except DaycareError:
    raised = true
  doAssert raised
  let graze = parseOrder(rChild, parseJson("{\"job\":\"graze\"}"))
  doAssert graze.cjob == cjGraze

echo "test_llm: a guess that DISAGREES with the delivered fruit is accepted"
block:
  let order = parseOrder(rParent, parseJson(
    "{\"job\":\"provide\",\"fruit\":\"apple\",\"guess\":\"banana\"," &
    "\"hunch\":\"testing whether it refuses apples\"}"))
  doAssert order.fruit == fApple and order.guess == fBanana,
    "hypothesis-testing by delivering the other species must stay expressible"

echo "test_llm: hunch and notes are truncated on RUNE boundaries"
block:
  let hunch = "\u00fc".repeat(MaxHunchLen + 50)
  let notes = "\u4e2d".repeat(MaxNotesLen + 50)
  let order = parseOrder(rChild, %*{
    "job": "show", "fruit": "banana", "hunch": hunch, "notes": notes})
  doAssert order.hunch.runeLen <= MaxHunchLen, $order.hunch.runeLen
  doAssert order.notes.runeLen <= MaxNotesLen, $order.notes.runeLen
  doAssert validateUtf8(order.hunch) == -1
  doAssert validateUtf8(order.notes) == -1
  # Newlines in a hunch become spaces: it is a one-line broadcast headline.
  let multi = parseOrder(rChild,
    %*{"job": "show", "fruit": "banana", "hunch": "line one\nline two"})
  doAssert "\n" notin multi.hunch

echo "test_llm: extra keys are ignored"
block:
  let order = parseOrder(rParent, parseJson(
    "{\"job\":\"stock\",\"fruit\":\"banana\",\"guess\":\"banana\"," &
    "\"confidence\":0.9,\"plan\":[1,2,3]}"))
  doAssert order.pjob == pjStock

echo "test_llm: minTurnSeconds floors the spacing between batch starts"
block:
  var cfg = variantConfig("daycare", 1)
  doAssert cfg.minTurnSeconds == 8
  doAssert paceDelayMs(cfg, 0.0) == 8000
  doAssert paceDelayMs(cfg, 6.0) == 2000
  doAssert paceDelayMs(cfg, 8.0) == 0
  doAssert paceDelayMs(cfg, 30.0) == 0
  # 2 requests per 8 s = 15 requests per minute, under the sidecar's 30 rpm.
  doAssert 2 * 60 div cfg.minTurnSeconds <= 30
  cfg.minTurnSeconds = 0
  doAssert paceDelayMs(cfg, 0.0) == 0

echo "test_llm: with no credentials the client disables itself and both " &
  "seats play the caretaker order"
block:
  for key in ["AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "AWS_BEARER_TOKEN_BEDROCK",
      "ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY_URI"]:
    delEnv(key)
  let cfg = variantConfig("daycare", 3)
  var sim = initSim(cfg)
  sim.turn = 1
  let client = newLlmClient(cfg)
  doAssert client.disabled
  let orders = client.decideAll(sim, @[0, 1], @["", ""], @[skNone, skNone])
  doAssert orders.len == 2
  for seat in 0 .. 1:
    var hedge = 0
    doAssert orders[seat] == orderFor(sim, seat, prCareCare, hedge),
      "seat " & $seat & " did not fall back to the caretaker order"

# ---------------------------------------------------------------------------
# the stubbed transport
# ---------------------------------------------------------------------------

type StubMode = enum
  smJunk, smThrottled, smForbidden, smSlow, smValid, smValidThenInvalid,
  smParallelProbe

var stubMode: Atomic[int]
var stubHits: Atomic[int]
var stubConcurrent: Atomic[int]
var stubPeak: Atomic[int]

const ParallelProbeMs = 500

const ValidParentReply = """{"job":"provide","fruit":"banana","guess":"banana","hunch":"it only reaches for bananas","notes":"turn 1"}"""
const ValidChildReply = """{"job":"show","fruit":"banana","hunch":"standing under my tree","notes":"turn 1"}"""

proc anthropicBody(text: string): string =
  $ %*{"content": [{"type": "text", "text": text}],
       "stop_reason": "end_turn"}

proc stubHandler(request: Request) {.gcsafe.} =
  discard stubHits.fetchAdd(1)
  let live = stubConcurrent.fetchAdd(1) + 1
  if live > stubPeak.load():
    stubPeak.store(live)
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  let mode = StubMode(stubMode.load())
  case mode
  of smJunk:
    sleep(60)
    request.respond(200, headers, anthropicBody(
      "I would rather describe the yard than answer in JSON."))
  of smThrottled:
    sleep(60)
    request.respond(429, headers, """{"message":"too many requests"}""")
  of smForbidden:
    sleep(60)
    request.respond(403, headers, """{"message":"forbidden"}""")
  of smSlow:
    sleep(2500)
    request.respond(200, headers, anthropicBody(ValidParentReply))
  of smParallelProbe:
    # Long enough that "both in flight" and "one after the other" are a clean
    # 2x apart on the wall clock.
    sleep(ParallelProbeMs)
    let isParent = "THE CHILD'S PREFERENCE IS NEVER SHOWN TO YOU" in request.body
    request.respond(200, headers, anthropicBody(
      if isParent: ValidParentReply else: ValidChildReply))
  of smValid, smValidThenInvalid:
    sleep(60)
    let body = request.body
    # The system prompt names the role, so the stub can answer per role exactly
    # as a model would.
    let reply =
      if "THE CHILD'S PREFERENCE IS NEVER SHOWN TO YOU" in body:
        ValidParentReply
      else: ValidChildReply
    if mode == smValidThenInvalid and "previous reply was invalid" notin body:
      request.respond(200, headers, anthropicBody("no json here"))
    else:
      request.respond(200, headers, anthropicBody(reply))
  discard stubConcurrent.fetchAdd(-1)

var stubServer: Server
var stubThread: Thread[int]

proc serveStub(port: int) {.thread.} =
  var router: Router
  router.post("/**", stubHandler)
  router.get("/**", stubHandler)
  stubServer = newServer(router)
  stubServer.serve(Port(port))

const StubPort = 18731
stubMode.store(ord(smValid))
createThread(stubThread, serveStub, StubPort)
sleep(400)

putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "http://127.0.0.1:" & $StubPort)
putEnv("AWS_BEARER_TOKEN_BEDROCK", "stub-token")

proc stubbedRun(mode: StubMode, llmTimeout = 2): tuple[orders: seq[Order],
    hits: int, peak: int, disabled: bool, ms: int, batch: int] =
  stubMode.store(ord(mode))
  stubHits.store(0)
  stubPeak.store(0)
  stubConcurrent.store(0)
  var cfg = variantConfig("daycare", 5)
  cfg.llmTimeoutSeconds = llmTimeout
  var sim = initSim(cfg)
  sim.turn = 1
  let client = newLlmClient(cfg)
  doAssert not client.disabled, "the stub transport did not come up"
  let started = epochTime()
  let orders = client.decideAll(sim, @[0, 1],
    @["be legible", "be legible"], @[skNone, skNone])
  let ms = int((epochTime() - started) * 1000.0)
  (orders, stubHits.load(), stubPeak.load(), client.disabled, ms,
   client.lastBatchSize)

echo "test_llm: BOTH open seats ride ONE parallel batch per turn"
block:
  let run = stubbedRun(smValid)
  doAssert run.orders.len == 2
  doAssert run.hits == 2,
    &"the stub saw {run.hits} requests for 2 open seats on turn 1"
  doAssert run.batch == 2,
    &"RequestBatch.len is {run.batch}, want 2 (both open seats in ONE batch)"
  for order in run.orders:
    doAssert order.source == osLlm, $order.source
  var cfg = variantConfig("daycare", 5)
  let sim = initSim(cfg)
  doAssert run.orders[sim.parentSeat].pjob == pjProvide
  doAssert run.orders[sim.parentSeat].hasGuess
  doAssert run.orders[sim.childSeat].cjob == cjShow

echo "test_llm: the batch is issued in PARALLEL, not one seat after the other"
block:
  # One client per EPISODE, exactly as src/daycare/server.nim creates it, and
  # two turns through it. curly sets CURLPIPE_MULTIPLEX, so the very first batch
  # to a cold endpoint holds the second transfer while libcurl learns whether
  # the connection can multiplex: turn 1 legitimately costs two round trips and
  # every turn after it costs ONE. Measure the warm case, which is 14 of 15
  # turns, against two requests each held open for ParallelProbeMs.
  stubMode.store(ord(smParallelProbe))
  stubHits.store(0)
  var cfg = variantConfig("daycare", 5)
  cfg.llmTimeoutSeconds = 20
  var sim = initSim(cfg)
  sim.turn = 1
  let client = newLlmClient(cfg)
  doAssert not client.disabled
  var elapsed: array[2, int]
  for turn in 0 .. 1:
    let started = epochTime()
    let orders = client.decideAll(sim, @[0, 1], @["", ""], @[skNone, skNone])
    elapsed[turn] = int((epochTime() - started) * 1000.0)
    doAssert orders.len == 2
    doAssert client.lastBatchSize == 2,
      &"RequestBatch.len is {client.lastBatchSize}, want 2"
    for order in orders:
      doAssert order.source == osLlm, $order.source
  doAssert stubHits.load() == 4, &"{stubHits.load()} requests over two turns"
  doAssert elapsed[1] < ParallelProbeMs * 2 - 100,
    &"a warm batch took {elapsed[1]} ms for two {ParallelProbeMs} ms " &
    "requests: the seats were queried SEQUENTIALLY, which doubles the wall " &
    "clock against the 720 s play budget"

echo "test_llm: junk, 429, 403 and a timeout all fall back to the caretaker " &
  "order, never raise, and are recorded as source=fallback"
block:
  for mode in [smJunk, smThrottled, smForbidden, smSlow]:
    let run = stubbedRun(mode, llmTimeout = 1)
    doAssert run.orders.len == 2, $mode
    var cfg = variantConfig("daycare", 5)
    var sim = initSim(cfg)
    sim.turn = 1
    for seat in 0 .. 1:
      var hedge = 0
      var expected = orderFor(sim, seat, prCareCare, hedge)
      expected.source = osFallback
      doAssert run.orders[seat].source == osFallback,
        &"{mode} seat {seat} source is {run.orders[seat].source}"
      doAssert run.orders[seat].pjob == expected.pjob and
        run.orders[seat].cjob == expected.cjob and
        run.orders[seat].fruit == expected.fruit and
        run.orders[seat].guess == expected.guess,
        &"{mode} seat {seat} is not the caretaker order"
      # And the fallback order is legal for its role, so the episode advances.
      sim.validateOrder(seat, run.orders[seat])
    if mode == smForbidden:
      doAssert run.disabled,
        "a 403 must disable the client for the rest of the episode"
    if mode in {smJunk, smThrottled}:
      doAssert run.hits == 4,
        &"{mode}: {run.hits} requests — an invalid reply is retried ONCE, " &
        "as one smaller batch"

echo "test_llm: an invalid first reply is retried once WITH THE HINT and the " &
  "retry is recorded as source=retry"
block:
  let run = stubbedRun(smValidThenInvalid)
  doAssert run.hits == 4, &"{run.hits} requests"
  for seat in 0 .. 1:
    doAssert run.orders[seat].source == osRetry,
      &"seat {seat} source is {run.orders[seat].source}"

stubServer.close()
delEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
delEnv("AWS_BEARER_TOKEN_BEDROCK")

echo "test_llm: the transport ladder is haiku-only"
block:
  delEnv("BEDROCK_MODEL")
  let models = bedrockModelIds()
  doAssert models.len == 1, $models
  doAssert "haiku" in models[0], models[0]
  putEnv("BEDROCK_MODEL", "us.anthropic.pinned-v1:0")
  doAssert bedrockModelIds() == @["us.anthropic.pinned-v1:0"]
  delEnv("BEDROCK_MODEL")

echo "test_llm: OK"
