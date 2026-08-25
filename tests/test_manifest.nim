## Packaging.
##
## Design note ## Tests, item 7. Everything `coworld build` / `coworld certify`
## / the platform validator can reject, checked here where it is cheap.

import std/[json, os, strutils, tables]
import helpers

let root = currentSourcePath().parentDir().parentDir()
let manifest = parseJson(readFile(root / "coworld_manifest_template.json"))
let compose = readFile(root / "compose.yaml")

echo "test_manifest: the image placeholder is derived from the compose service"
block:
  # `coworld build` hard-fails anything else: the placeholder comes from the
  # COMPOSE SERVICE NAME (service daycare -> {{DAYCARE_IMAGE}}); {{GAME_IMAGE}}
  # is not a thing (lantern 0.1.0, 2026-08-23).
  var service = ""
  var image = ""
  var inServices = false
  for rawLine in compose.splitLines():
    let line = rawLine.strip(leading = false)
    if line.startsWith("services:"):
      inServices = true
      continue
    if not inServices: continue
    if line.startsWith("  ") and not line.startsWith("    ") and
        line.strip().endsWith(":"):
      service = line.strip().strip(chars = {':'})
    if line.strip().startsWith("image:"):
      image = line.strip()[len("image:") .. ^1].strip()
  doAssert service == "daycare", "compose service is " & service
  doAssert image == "coworld-daycare:latest", "compose image is " & image
  let derived = "{{" & service.toUpperAscii() & "_IMAGE}}"
  doAssert derived == "{{DAYCARE_IMAGE}}"
  doAssert manifest["game"]["runnable"]["image"].getStr() == derived,
    "game.runnable.image is " & manifest["game"]["runnable"]["image"].getStr()
  for entry in manifest["player"]:
    doAssert entry["image"].getStr() == derived,
      "player " & entry["id"].getStr() & " image is " & entry["image"].getStr()
  doAssert "platform: linux/amd64" in compose
  doAssert "network: host" in compose
  doAssert "dockerfile: Dockerfile" in compose

echo "test_manifest: num_agents is 2 in EVERY variant and in the cert fixture"
block:
  doAssert manifest["variants"].len == 4, $manifest["variants"].len
  var ids: seq[string]
  for variant in manifest["variants"]:
    ids.add variant["id"].getStr()
    doAssert variant.hasKey("description") and
      variant["description"].getStr().len > 0,
      variant["id"].getStr() & " has no description"
    let config = variant["game_config"]
    doAssert config{"num_agents"}.getInt() == 2,
      variant["id"].getStr() & " num_agents is " & $config{"num_agents"}
    doAssert config["players"].len == 2
    # The variant's own game_config must produce the variant it claims to be.
    var cfg = defaultGameConfig()
    cfg.update($config)
    doAssert cfg.variantId() == variant["id"].getStr(),
      variant["id"].getStr() & " game_config derives " & cfg.variantId()
    doAssert cfg.numAgents == 2
  doAssert ids == @["daycare", "daycare-sparse", "daycare-fickle",
    "daycare-swapped"], $ids
  let cert = manifest["certification"]["game_config"]
  doAssert cert{"num_agents"}.getInt() == 2
  doAssert cert["players"].len == 2
  doAssert manifest["certification"]["players"].len == 2
  # `coworld certify` defaults to --timeout-seconds 60 over start + connect
  # grace + every round + linger: keep the fixture short enough to fit, and
  # long enough that the derived replay outlasts the 10 s viewer soak.
  var certCfg = defaultGameConfig()
  certCfg.update($cert)
  let certTicks = certCfg.turns * certCfg.ticksPerTurn
  doAssert certTicks.float / TargetFps.float >= 12.0,
    "the cert replay is only " & $(certTicks div TargetFps) &
    " s of video; the viewer soak needs > 10 s"
  doAssert certCfg.minTurnSeconds == 0,
    "the cert fixture must not pace: it has no credentials to wait for"

echo "test_manifest: every declared player entry occupies a certification slot"
block:
  # `players-run` seats the whole roster; a fixture that omits one fails
  # `players_missing` (raid 0.1.2 -> 0.1.3).
  doAssert manifest["player"].len == 2, $manifest["player"].len
  var seated: seq[string]
  for slot in manifest["certification"]["players"]:
    seated.add slot["player_id"].getStr()
  for entry in manifest["player"]:
    let id = entry["id"].getStr()
    doAssert id in seated, id & " has no certification slot"
    doAssert entry["type"].getStr() == "player"
    doAssert entry["run"][0].getStr() == "/bin/daycare-player"
    doAssert entry.hasKey("resources")
    doAssert entry["description"].getStr().len > 0
  # Two entries, not three: every declared player must occupy one of the TWO
  # slots this game has, so a third runnable makes the fixture unsatisfiable.
  doAssert manifest["player"].len == manifest["certification"]["players"].len

echo "test_manifest: the replay ships as a STATIC bundle, never a pod"
block:
  doAssert manifest["game"]["replay_viewer"]["bundle"].getStr() ==
    "static-replay-viewer"
  doAssert not manifest["game"].hasKey("display_name")
  doAssert not manifest.hasKey("version")
  doAssert manifest["game"].hasKey("owner")
  doAssert manifest["game"]["runnable"]["type"].getStr() == "game"
  doAssert manifest.hasKey("episode_timeout_minutes")
  doAssert manifest["episode_timeout_minutes"].getInt() == 20
  doAssert manifest["tags"].len >= 3, $manifest["tags"].len
  doAssert manifest.hasKey("$schema")
  doAssert not manifest["certification"]["game_config"].hasKey("tokens"),
    "the cert fixture must not carry runner-managed tokens"

echo "test_manifest: the coworld secret reaches the GAME container"
block:
  let env = manifest["game"]["runnable"]["env"]
  doAssert env.hasKey("ANTHROPIC_API_KEY_URI"),
    "without this the hosted game never sees the secret and every league " &
    "episode silently plays scripted (hive, 2026-08-23)"
  let uri = env["ANTHROPIC_API_KEY_URI"].getStr()
  let name = manifest["game"]["name"].getStr()
  doAssert uri == "secret://coworld/" & name & "/anthropic_api_key", uri
  # The namespace must equal game.name exactly, not the page slug.
  doAssert name == "daycare"

echo "test_manifest: docs and BOTH protocols are text objects with content"
block:
  let docs = manifest["game"]["docs"]
  doAssert docs["readme"]["type"].getStr() == "text"
  doAssert docs["readme"]["value"].getStr().len > 200
  doAssert docs["pages"].len >= 2
  for page in docs["pages"]:
    doAssert page["id"].getStr().len > 0
    doAssert page["title"].getStr().len > 0
    doAssert page["content"]["type"].getStr() == "text"
    doAssert page["content"]["value"].getStr().len > 200,
      page["id"].getStr() & " is empty"
  let protocols = manifest["game"]["protocols"]
  for key in ["player", "global"]:
    doAssert protocols.hasKey(key), "game.protocols." & key & " is missing"
    doAssert protocols[key].kind == JObject,
      "game.protocols." & key & " is a bare string; the platform validator " &
      "rejects it (cogame-garble v0.1.0)"
    doAssert protocols[key]["type"].getStr() == "text"
    doAssert protocols[key]["value"].getStr().len > 200

echo "test_manifest: every ARRAY property declares minItems AND maxItems"
block:
  proc checkArrays(node: JsonNode, path: string, want = -1) =
    if node.kind != JObject: return
    if node{"type"}.getStr() == "array":
      doAssert node.hasKey("minItems"),
        path & " is an array without minItems"
      doAssert node.hasKey("maxItems"),
        path & " is an array without maxItems"
      if want > 0:
        doAssert node["minItems"].getInt() == want and
          node["maxItems"].getInt() == want,
          path & " must be exactly " & $want & " long"
    for key, value in node:
      if key in ["properties", "items"]:
        if key == "items":
          checkArrays(value, path & ".items", want)
        else:
          for name, prop in value:
            checkArrays(prop, path & "." & name, want)
  checkArrays(manifest["game"]["config_schema"], "config_schema")
  checkArrays(manifest["game"]["results_schema"], "results_schema", want = 2)
  let schema = manifest["game"]["config_schema"]
  doAssert schema["additionalProperties"].getBool() == false
  doAssert "tokens" in schema["required"].to(seq[string])
  doAssert schema["properties"]["num_agents"]["maximum"].getInt() == 2
  doAssert schema["properties"]["num_agents"]["default"].getInt() == 2
  let results = manifest["game"]["results_schema"]
  for key in ["names", "scores", "win", "reason", "ending"]:
    doAssert key in results["required"].to(seq[string]),
      key & " is not required in results_schema"
  doAssert results["properties"]["reason"]["enum"].to(seq[string]) ==
    @["complete", "deadline", "forfeit"]
  doAssert results["properties"]["ending"]["enum"].to(seq[string]) ==
    @["turn_limit", "deadline", "forfeit"]
  doAssert results["properties"]["preference"]["enum"].to(seq[string]) ==
    @["apple", "banana"]

echo "test_manifest: config_schema admits every game_config this file ships"
block:
  # B1 (r1 review): `tokens` and `players` declared `maxItems: 1` in a TWO-seat
  # game, so the schema this manifest publishes rejected its own four variants
  # and its own certification fixture — and the server refuses to start with
  # fewer than two of either (src/daycare/server.nim). The bound belongs to the
  # seat count, and every shipped game_config is checked against it here so a
  # schema that rejects the fixtures fails the job instead of the platform.
  let schema = manifest["game"]["config_schema"]
  let props = schema["properties"]
  let seats = props["num_agents"]["maximum"].getInt()
  doAssert seats == 2
  for key in ["tokens", "players"]:
    doAssert props[key]["maxItems"].getInt() == seats,
      "config_schema." & key & " caps at " & $props[key]["maxItems"].getInt() &
      " in a " & $seats & "-seat game"
  var configs: seq[(string, JsonNode)]
  for variant in manifest["variants"]:
    configs.add((variant["id"].getStr(), variant["game_config"]))
  configs.add(("certification", manifest["certification"]["game_config"]))
  # The runner injects `tokens` and `players` at seat time (the shape
  # tools/ci/docker_smoke.sh writes), so check that shape against the schema too.
  var injected = newJObject()
  injected["tokens"] = newJArray()
  injected["players"] = newJArray()
  for slot in 0 ..< seats:
    injected["tokens"].add(%("token-" & $slot))
    injected["players"].add(%*{"name": "seat-" & $slot})
  configs.add(("runner-injected", injected))
  for entry in configs:
    let name = entry[0]
    for key, value in entry[1]:
      doAssert props.hasKey(key),
        name & " sets " & key & ", which config_schema does not declare"
      if value.kind == JArray:
        let least = props[key]["minItems"].getInt()
        let most = props[key]["maxItems"].getInt()
        doAssert value.len >= least and value.len <= most,
          name & "." & key & " has " & $value.len &
          " entries, outside the declared " & $least & ".." & $most

echo "test_manifest: results.json validates against the declared schema"
block:
  let sim = playEpisode(variantConfig("daycare", 3))
  let results = sim.resultsJson()
  let schema = manifest["game"]["results_schema"]
  for key in schema["required"].to(seq[string]):
    doAssert results.hasKey(key), "results.json has no " & key
  for key, value in results:
    doAssert schema["properties"].hasKey(key),
      "results.json has an undeclared key: " & key
    let prop = schema["properties"][key]
    case prop["type"].getStr()
    of "array":
      doAssert value.kind == JArray, key
      doAssert value.len == prop["minItems"].getInt(), key
    of "integer":
      doAssert value.kind == JInt, key
    of "string":
      doAssert value.kind == JString, key
      if prop.hasKey("enum"):
        doAssert value.getStr() in prop["enum"].to(seq[string]),
          key & " = " & value.getStr()
    else: discard
  doAssert results["reason"].getStr() == "complete"
  doAssert results["ending"].getStr() == "turn_limit"

echo "test_manifest: the policy set is two prompt champions plus two fillers"
block:
  let policies = parseJson(readFile(root / "tools" / "ci" / "policies.json"))
  doAssert policies.len == 4, $policies.len
  var prompts = 0
  var scripted = 0
  var owners: seq[string]
  var names: seq[string]
  for policy in policies:
    let name = policy["name"].getStr()
    names.add name
    doAssert name.startsWith("daycare-"), name
    doAssert policy["run"].getStr() == "/bin/daycare-player"
    let env = policy["env"]
    if env.hasKey("PLAYER_PROMPT"):
      inc prompts
      doAssert env["PLAYER_PROMPT"].getStr().len > 400, name
      # Without USE_BEDROCK the platform gives the player pod no Bedrock
      # sidecar and the seat silently plays scripted (cogolf, 2026-08-24).
      doAssert env{"USE_BEDROCK"}.getStr() == "true",
        name & " has no USE_BEDROCK"
      # A champion prompt must cover BOTH roles: the ladder seats a policy in
      # either.
      let text = env["PLAYER_PROMPT"].getStr()
      doAssert "AS THE PARENT" in text, name & " does not cover the parent"
      doAssert "AS THE CHILD" in text, name & " does not cover the child"
    else:
      inc scripted
      doAssert env{"PLAYER_SCRIPTED"}.getStr() in ["caretaker", "stubborn"],
        name
    if policy.hasKey("player"):
      owners.add policy["player"].getStr()
  doAssert prompts == 2, $prompts & " prompt policies"
  doAssert scripted == 2, $scripted & " scripted policies"
  doAssert names[0] == "daycare-attentive" and names[1] == "daycare-provider"
  # Champion #2 must be uploaded while daveey-1 is the active player, or
  # submitting it as daveey-1 409s "already assigned to player".
  doAssert owners == @["ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"], $owners
  doAssert policies[1]["player"].getStr() ==
    "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"
  # Filler names must differ from champion names, or the platform renames a
  # scored champion "Baseline (N)".
  var seen = initTable[string, bool]()
  for name in names:
    doAssert not seen.hasKey(name), "duplicate policy name " & name
    seen[name] = true
  # Both scripted names are declared player entries too, so the smoke and the
  # certifier field the same seats the league does.
  var declared: seq[string]
  for entry in manifest["player"]:
    declared.add entry["id"].getStr()
  doAssert "daycare-caretaker" in declared and "daycare-stubborn" in declared

echo "test_manifest: the scaffold is present and has no unsubstituted " &
  "placeholders"
block:
  for path in ["tools/ci/docker_smoke.sh", "tools/build_replay_viewer.sh",
      "tools/ci/viewer_smoke.mjs", "tools/ci/policies.json",
      "tools/ci/renderer_fixture.html", ".github/workflows/ci.yml",
      ".github/workflows/coworld-release.yml",
      ".github/workflows/coworld-submit.yml"]:
    doAssert fileExists(root / path), path & " is missing"
  for path in [".github/workflows/ci.yml",
      ".github/workflows/coworld-release.yml",
      ".github/workflows/coworld-submit.yml", "tools/ci/docker_smoke.sh",
      "tools/ci/policies.json"]:
    let text = readFile(root / path)
    for placeholder in ["<slug>", "<IMAGE>", "<SEATS>"]:
      doAssert placeholder notin text,
        path & " still contains " & placeholder
  let smoke = readFile(root / "tools/ci/docker_smoke.sh")
  doAssert "SMOKE_SEATS:-2" in smoke, "SMOKE_SEATS was not substituted to 2"
  doAssert "/bin/daycare" in smoke
  doAssert "coworld-daycare:ci" in smoke

echo "test_manifest: OK"
