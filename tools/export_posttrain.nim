## Stream complete private candidates; shared review owns training admission.
import std/[json, os, osproc, strutils]
import daycare/[llm, scripted, sim, prompts, evidence, replays]

const OperatorPrompt = "Cooperate to maximize the child's food score while respecting what each role can observe."

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3, 4, 6]:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT [PROMPT_VARIANT PROMPT_SEED]]", 1)
  let output = absolutePath(args[0])
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: "daycare"
  let selection = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out wording is evaluation-only")
  doAssert games >= 10 and firstSeed >= 1
  doAssert not dirExists(output) and not fileExists(output)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit qualified source before generating a pinned candidate corpus"
  let head = execCmdEx("git rev-parse HEAD")
  doAssert head.exitCode == 0
  let revision = head.output.strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: variantConfig = entry["game_config"]
  doAssert variantConfig.kind == JObject
  writePrivate(output / "trajectories.jsonl", "")
  writePrivate(output / "execution.jsonl", "")
  let stream = open(output / "trajectories.jsonl", fmAppend)
  let execution = open(output / "execution.jsonl", fmAppend)
  var runs = newJArray()
  try:
    for seed in firstSeed ..< firstSeed + games:
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = %*["t0", "t1"]
      runtimeConfig["seed"] = %seed
      config.update($runtimeConfig)
      var sim = initSim(config, ["caretaker", "stubborn"])
      let family = "daycare-" & $seed
      let episode = family & "-" & variant & "-" & $selection.selectedVariant & "-" & $selection.seed
      for turn in 1 .. config.turns:
        sim.turn = turn
        var orders: array[2, Order]
        var records: array[2, JsonNode]
        for seat in 0 .. 1:
          let role = sim.roleOf[seat]
          let system = systemPrompt(sim, seat, selection)
          let user = userPrompt(sim, seat, OperatorPrompt)
          let messages = %*[{"role": "system", "content": system}, {"role": "user", "content": user}]
          var view = sim.playerStateJson(seat)
          view["prompt_template"] = selection.promptMetadata(system, user)
          let kind = if seat == 0: skCaretaker else: skStubborn
          let proposal = orderJson(role, scriptedOrder(sim, seat, kind))
          var parsed = parseOrder(role, proposal)
          sim.validateOrder(seat, parsed)
          parsed.source = osScripted
          orders[seat] = parsed
          let installed = orderJson(role, parsed)
          let accepted = proposal == installed
          let id = (turn - 1) * 2 + seat
          let attemptId = $id & "-teacher"
          let attempt = %*{
            "attempt_id": attemptId, "policy": "scripted-caretaker-and-stubborn", "origin": "teacher",
            "inference_mode": "text_action", "prompt": messages,
            "response": $proposal, "parsed_action": proposal, "accepted": accepted,
            "request": newJNull(), "platform_call_id": newJNull(), "behavior_logprobs": newJNull(),
            "rejection_reason": (if accepted: newJNull() else: %"engine-normalized-submission")
          }
          records[seat] = %*{
            "schema_version": "1", "event_type": "decision", "episode_id": episode,
            "decision_id": $id, "decision_index": id,
            "game": "daycare", "game_version": "source-" & revision,
            "source_revision": revision, "seat": $seat, "visibility": "private",
            "observation": view, "prompt": (if accepted: messages else: newJNull()),
            "attempts": [attempt], "selected_attempt_id": (if accepted: %attemptId else: newJNull()),
            "executed_action": installed, "action_status": (if accepted: "accepted" else: "fallback"),
            "fallback_origin": (if accepted: newJNull() else: %"engine-normalized-submission"),
            "terminal": turn == config.turns and seat == 1
          }
        for seat in 0 .. 1: sim.applyOrder(seat, orders[seat])
        let startTick = sim.tick
        let actions = sim.playTurn()
        var frames = newJArray()
        for tick in startTick ..< sim.tick: frames.add(frameJson(sim.frames[tick]))
        execution.writeLine($(%*{
          "schema_version": 1, "event_type": "turn_execution", "episode_id": episode,
          "decision_ids": [$(2 * (turn - 1)), $(2 * (turn - 1) + 1)],
          "source_revision": revision, "visibility": "private", "turn": turn,
          "start_tick": startTick, "end_tick": sim.tick,
          "kernel_actions": kernelActionsJson(actions), "frames": frames,
          "terminal": turn == config.turns
        }))
        for record in records: stream.writeLine($record)
      sim.settle("complete", "turn_limit")
      doAssert sim.turnsPlayed == config.turns and sim.tick == config.turns * config.ticksPerTurn
      let outcome = sim.resultsJson()
      stream.writeLine($(%*{
        "schema_version": "1", "event_type": "episode", "episode_id": episode,
        "seed_family": family, "game": "daycare", "game_version": "source-" & revision,
        "source_revision": revision, "status": "completed", "outcome": outcome,
        "participant_outcomes": {"0": {"score": sim.cogs[0].score}, "1": {"score": sim.cogs[1].score}}
      }))
      runs.add(%*{"seed": seed, "decisions": config.turns * 2, "scores": outcome["scores"],
        "turns_played": sim.turnsPlayed})
  finally:
    execution.close()
    stream.close()
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "daycare", "variant": variant,
    "source_revision": revision, "teacher": "scripted-caretaker-and-stubborn",
    "prompt_selection": selection.selectionMetadata(),
    "split_authority": "shared Coworld SDK and application importer by seed_family",
    "execution_evidence": "execution.jsonl", "runs": runs}) & "\n")
  echo "complete games=", games
