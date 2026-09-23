## Persistent JSONL decision bridge for Metta RL and native Puffer training.
## nim c -d:release --path:src -o:daycare-train-bridge tools/train_bridge.nim
## daycare-train-bridge coworld_manifest_template.json [VARIANT]

import std/[json, os]
import daycare/[llm, scripted, sim, sim_types]

const OperatorPrompt = "Cooperate to maximize the child's food score while respecting what each role can observe."
const ActionWidth = 12

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc decision(game: Sim, seat, id: int): JsonNode =
  %*{
    "kind": "decision",
    "game": "daycare",
    "decision_id": id,
    "seat": seat,
    "engine_seat": seat,
    "turn": game.turn,
    "semantic_view": game.playerStateJson(seat),
    "inbox": [],
    "messages": [
      {"role": "system", "content": systemPrompt(game, seat)},
      {"role": "user", "content": userPrompt(game, seat, OperatorPrompt)}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object", "required": ["job"]},
    "typed_question": newJNull()
  }

proc encoding(game: Sim, seat, id: int): JsonNode =
  let state = game.playerStateJson(seat)
  let role = game.roleOf[seat]
  let other = if role == rParent: state["child"] else: state["parent"]
  var values = newJArray()
  for slot in 0 .. 1:
    values.add(%(if slot == seat: 1 else: 0))
  values.add(%(if role == rParent: 1 else: 0))
  for key in ["turn", "turns", "ticksPerTurn", "tick"]:
    values.add(state[key])
  for key in ["cols", "rows"]:
    values.add(state["yard"][key])
  values.add(%(if state["yard"]["mirrored"].getBool(): 1 else: 0))
  for actor in [state["you"], other]:
    values.add(actor["cell"][0])
    values.add(actor["cell"][1])
    for fruit in Fruit:
      values.add(%(if actor["carrying"].getStr("") == $fruit: 1 else: 0))
    values.add(actor["score"])
  values.add(state["you"]["par"])
  for key in ["apple", "banana", "capacity"]:
    values.add(state["basket"][key])
  for fruit in Fruit:
    var count = 0
    var ripe = 0
    var ground = 0
    for source in state["sources"]:
      if source["fruit"].getStr() == $fruit:
        inc count
        if source["ripe"].getBool(): inc ripe
    for item in state["ground"]:
      if item["fruit"].getStr() == $fruit: inc ground
    values.add(%count)
    values.add(%ripe)
    values.add(%ground)
    values.add(%(if role == rChild and state["you"]["preference"].getStr() == $fruit: 1 else: 0))
  var actions = newJArray()
  if role == rParent:
    for job in ParentJob:
      if job in {pjProvide, pjStock}:
        for fruit in Fruit:
          for guess in Fruit:
            actions.add(%*{"job": $job, "fruit": $fruit, "guess": $guess})
      else:
        for guess in Fruit:
          actions.add(%*{"job": $job, "guess": $guess})
  else:
    for job in ChildJob:
      if job in {cjSeek, cjShow}:
        for fruit in Fruit:
          actions.add(%*{"job": $job, "fruit": $fruit})
      else:
        actions.add(%*{"job": $job})
  doAssert actions.len <= ActionWidth
  while actions.len < ActionWidth:
    actions.add(newJNull())
  %*{"decision_id": id, "values": values, "actions": actions}

when isMainModule:
  let args = commandLineParams()
  if args.len notin 1 .. 2:
    quit("usage: daycare-train-bridge MANIFEST [VARIANT]", 1)
  let variant = if args.len == 2: args[1] else: "daycare"
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil, "unknown variant: " & variant
  var game: Sim
  var seat = 0
  var id = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == 2
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = %*["t0", "t1"]
      runtimeConfig["seed"] = %seedOf(request["seed"].getStr())
      config.update($runtimeConfig)
      game = initSim(config, ["learner", "opponent"])
      game.turn = 1
      seat = 0
      id = 0
      response = game.decision(seat, id)
    of "encode":
      doAssert not game.done
      response = game.encoding(seat, id)
    of "teacher":
      doAssert not game.done
      let order = scriptedOrder(game, seat,
        if seat == 0: skCaretaker else: skStubborn)
      let role = game.roleOf[seat]
      var action = %*{
        "job": (if role == rParent: $order.pjob else: $order.cjob)
      }
      if order.hasFruit: action["fruit"] = %($order.fruit)
      if role == rParent: action["guess"] = %($order.guess)
      response = %*{"response": $action}
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      let action = parseJson(request["response"].getStr())
      var order = parseOrder(game.roleOf[seat], action)
      order.source = osLlm
      game.applyOrder(seat, order)
      inc seat
      if seat == 2:
        game.playTurn()
        seat = 0
        if game.turn == game.config.turns:
          game.settle("complete", "turn_limit")
        else:
          inc game.turn
      inc id
      var observation: JsonNode
      if game.done:
        let outcome = game.resultsJson()
        var scores = newJObject()
        var utilities = newJObject()
        let par = outcome["par"].getInt().float
        doAssert par > 0
        for slot in 0 .. 1:
          let score = outcome["scores"][slot].getInt().float
          scores[$slot] = %score
          utilities[$slot] = %(2.0 * score / (score + par) - 1.0)
        observation = %*{"kind": "terminal", "scores": scores,
          "utilities": utilities}
      else:
        observation = game.decision(seat, id)
      response = %*{"kind": "accepted", "action": action,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
