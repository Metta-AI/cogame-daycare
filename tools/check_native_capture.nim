## Native reconstruction + bounded mixed HTTP/parser/apply/writer component.
import std/[base64, json, os, strutils, tables]
import daycare/[sim, llm, replays, prompts, training_capture, scripted]

const LocalPrompt = staticRead("../src/daycare_player.nim").split("\"\"\"")[1][1 .. ^1]

proc ownOrder(sim: Sim, slot: int): JsonNode =
  for index in countdown(sim.events.high, 0):
    let event = sim.events[index]
    if event{"k"}.getStr() == "order" and event{"seat"}.getInt(-1) == slot and
        event{"turn"}.getInt() == sim.turn:
      return copy(event)
  raise newException(ValueError, "authoritative order missing")

proc reconstruct(root: string) =
  let input = parseJson(readFile(root / "config.json"))
  var config = defaultGameConfig()
  config.update($input)
  var sim = initSim(config)
  let selection = promptSelection(input)
  let replay = parseJson(readFile(root / "replay.json"))
  let http = parseJson(readFile(root / "http.json"))
  var decisions: seq[JsonNode]
  for line in lines(root / "trajectory.jsonl"):
    let row = parseJson(line)
    if row{"event_type"}.getStr() == "decision": decisions.add(row)
  doAssert decisions.len == config.turns * 2
  for turn in 1 .. config.turns:
    sim.turn = turn
    var selected: array[2, JsonNode]
    var pending: array[2, Order]
    for slot in 0 .. 1:
      let row = decisions[(turn - 1) * 2 + slot]
      selected[slot] = row
      let view = sim.playerStateJson(slot)
      for key, value in view:
        doAssert row["observation"][key] == value, "native private view " & key
      let attempt = row["attempts"][0]
      doAssert attempt["request"]["system"].getStr() == systemPrompt(sim, slot, selection)
      doAssert attempt["request"]["messages"][0]["content"].getStr() == sim.userPrompt(slot, LocalPrompt)
      doAssert attempt["decoder"]["max_tokens"].getInt() == config.maxOutputTokens
      doAssert attempt["latency_ms"].kind == JNull
      var wire = newJNull()
      for candidate in http:
        let request = parseJson(decode(candidate["request_b64"].getStr()))
        if candidate["slot"].getInt() == slot and
            request["messages"][0]["content"].getStr().startsWith("TURN " & $turn & " "):
          wire = candidate
      doAssert wire.kind == JObject
      doAssert parseJson(decode(wire["request_b64"].getStr())) == attempt["request"]
      doAssert wire["intended_response_b64"] == attempt["response_body_b64"]
      doAssert wire["call_id"] == attempt["platform_call_id"]
      doAssert decode(wire["intended_response_b64"].getStr()) == attempt["raw_response"].getStr()
      var order = parseOrder(sim.roleOf[slot], extractJsonObject(wire["text"].getStr()))
      order.source = osLlm
      for event in replay["events"]:
        if event{"k"}.getStr() == "order" and event{"turn"}.getInt() == turn and event{"seat"}.getInt() == slot:
          order.latencyMs = event["latencyMs"].getInt()
      pending[slot] = order
    for slot in 0 .. 1: sim.applyOrder(slot, pending[slot])
    for slot in 0 .. 1:
      let row = selected[slot]
      doAssert row["executed_action"] == orderJson(sim.roleOf[slot], sim.lastOrders[slot])
      doAssert row["observation"]["native_execution"]["own_order_event"] == sim.ownOrder(slot)
      doAssert row["action_status"].getStr() == "accepted"
      let observation = $row["observation"]
      doAssert ("private-note-seat-" & $(1-slot)) notin observation
      if slot == 0: doAssert "YOUR SECRET PREFERENCE" notin $row["attempts"][0]["prompt"]
    sim.playTurn()
  sim.settle("complete", "turn_limit")
  let expected = parseJson(sim.replayJson(sim.resultsJson()))
  doAssert expected["frames"] == replay["frames"]
  doAssert expected["series"] == replay["series"]
  doAssert expected["beats"] == replay["beats"]
  doAssert sim.resultsJson() == replay["results"]
  echo "PASS independent native reconstruction: all views/prompts/requests/receipts/actions/events/900frames/results"

proc component(configPath: string) =
  var config = defaultGameConfig()
  config.update(readFile(configPath))
  var sim = initSim(config)
  let selection = promptSelection(parseJson(readFile(configPath)))
  let client = newLlmClient(config)
  let capture = newRuntimeCapture(config, "", "")
  doAssert capture != nil
  client.capture = capture
  for turn in 1 .. 10:
    sim.turn = turn
    let orders = client.decideAll(sim, @[0, 1], @[LocalPrompt, LocalPrompt],
      @[skNone, skNone], selection)
    for slot in 0 .. 1: sim.applyOrder(slot, orders[slot])
    for slot in 0 .. 1:
      let installed = sim.lastOrders[slot]
      capture.applied(client.captured[slot], slot,
        orderJson(sim.roleOf[slot], installed), sim.ownOrder(slot),
        $installed.source, sim.nativeStateHash(slot))
    sim.playTurn()
  # Actual initialized native state, not a completed strategic episode.
  doAssert not sim.done and sim.turnsPlayed == 10
  capture.finishCapture(sim.resultsJson())
  echo "PASS partial native HTTP/parser/apply/writer component;10/15turns, no complete episode"

proc auditFamilies(destination: string) =
  var groups = initCountTable[string]()
  var actualLayouts = initCountTable[string]()
  var conditions = initCountTable[string]()
  var examples = newJArray()
  for seed in 0 ..< 256:
    for sparse in [false, true]:
      var config = defaultGameConfig()
      config.seed = seed
      config.shrubs = if sparse: 2 else: 4
      let expected = identities(config).family
      for role in [rParent, rChild]:
        for horizon in [10, 15]:
          for fickle in [false, true]:
            config.slot0Role = role
            config.turns = horizon
            config.preferenceSwitch = fickle
            let identity = identities(config)
            doAssert identity.family == expected
            let world = initSim(config)
            groups.inc(identity.family)
            actualLayouts.inc($world.yard.layoutHash())
            conditions.inc($sparse & ":" & $world.yard.mirrored & ":" &
              $world.preference & ":" & $fickle & ":" & $world.switchTurn)
      if seed < 2: examples.add(%*{"seed": seed, "sparse": sparse, "family": expected})
  doAssert groups.len == 2 and actualLayouts.len == 4
  var result = %*{"status": "PASS offline native init-only family alias audit",
    "seeds": 256, "initializations": 4096, "groups": groups.len,
    "actual_mirrored_layouts": actualLayouts.len, "condition_strata": conditions.len,
    "seed_role_horizon_fickle_aliases_grouped": true,
    "independent_worlds": false, "shared_authored_board_and_trees": true,
    "games": 0, "examples": examples}
  writeFile(destination, $result & "\n")
  echo $result

when isMainModule:
  doAssert paramCount() == 2
  case paramStr(1)
  of "--check": reconstruct(paramStr(2))
  of "--mixed": component(paramStr(2))
  of "--families": auditFamilies(paramStr(2))
  else: quit("use --check OUTPUT or --mixed CONFIG", 1)
