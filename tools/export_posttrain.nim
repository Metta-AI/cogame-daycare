## Export complete Daycare games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import daycare/[llm, scripted, sim, prompts]

const OperatorPrompt = "Cooperate to maximize the child's food score while respecting what each role can observe."
const Variants = ["daycare", "daycare-sparse", "daycare-fickle",
  "daycare-swapped"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3, 4, 6]:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT [PROMPT_VARIANT PROMPT_SEED]]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: Variants[0]
  let selection = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out wording is evaluation-only")
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit source before generating a pinned corpus"
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert variantConfig.kind == JObject
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + games:
    var wording = selection
    if wording.variant == pvMixed: wording.seed += seed - firstSeed
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = %*["t0", "t1"]
    runtimeConfig["seed"] = %seed
    config.update($runtimeConfig)
    var sim = initSim(config, ["caretaker", "stubborn"])
    var rows: seq[string]
    for turn in 1 .. config.turns:
      sim.turn = turn
      var decisions: array[2, Order]
      for seat in 0 .. 1:
        let teacher = scriptedOrder(sim, seat,
          if seat == 0: skCaretaker else: skStubborn)
        let role = sim.roleOf[seat]
        let completion = %*{
          "job": (if role == rParent: $teacher.pjob else: $teacher.cjob),
          "fruit": (if teacher.hasFruit: %($teacher.fruit) else: newJNull()),
          "guess": (if teacher.hasGuess: %($teacher.guess) else: newJNull()),
          "hunch": teacher.hunch,
          "notes": teacher.notes
        }
        let parsed = parseOrder(role, completion)
        sim.validateOrder(seat, parsed)
        let system = systemPrompt(sim, seat, wording)
        let user = userPrompt(sim, seat, OperatorPrompt)
        doAssert parsed.pjob == teacher.pjob and
          parsed.cjob == teacher.cjob and
          parsed.hasFruit == teacher.hasFruit and
          parsed.fruit == teacher.fruit and
          parsed.hasGuess == teacher.hasGuess and
          parsed.guess == teacher.guess and
          parsed.hunch == teacher.hunch and parsed.notes == teacher.notes
        rows.add($(%*{
          "episode_id": "daycare-" & variant & "-" & $seed,
          "seed": "daycare-" & $seed,
          "decision_id": rows.len,
          "prompt": [
            {"role": "system", "content": system},
            {"role": "user", "content": user}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "daycare",
          "prompt_template": wording.promptMetadata(system, user),
          "action_schema_revision": "daycare-order-v1"
        }))
        decisions[seat] = parsed
      for seat in 0 .. 1:
        sim.applyOrder(seat, decisions[seat])
      sim.playTurn()
    sim.settle("complete", "turn_limit")
    doAssert sim.turnsPlayed == config.turns
    let outcome = sim.resultsJson()
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "turns_played": sim.turnsPlayed,
      "prompt_selection": wording.selectionMetadata()})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "daycare",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-caretaker-and-stubborn",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
