## `GameConfig` lifecycle: defaults, `config.update` from the platform's runtime
## JSON, and the bounds the manifest's `game.config_schema` declares.
##
## Fork of `coworld-ctf/src/ctf/sim_config.nim`. Fields are exactly the config
## schema in the design note's ## Packaging section.

import std/[json, strutils]
import sim_types

proc clampField(value, lo, hi: int, name: string): int =
  if value < lo or value > hi:
    raise newException(DaycareError,
      name & " must be " & $lo & ".." & $hi & ": " & $value)
  value

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults. Called AFTER the seed
  ## is settled (see `src/daycare.nim`), so every seed-derived draw follows the
  ## final seed — paintbot's rule.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(DaycareError, "config must be a JSON object")

  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add token.getStr()
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add PlayerConfig(name: player{"name"}.getStr())
  if node.hasKey("num_agents"):
    config.numAgents = clampField(node["num_agents"].getInt(), 1, 2, "num_agents")
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("slot0Role"):
    config.slot0Role = parseRole(node["slot0Role"].getStr())
  if node.hasKey("turns"):
    config.turns = clampField(node["turns"].getInt(), 1, 30, "turns")
  if node.hasKey("ticksPerTurn"):
    config.ticksPerTurn =
      clampField(node["ticksPerTurn"].getInt(), 12, 120, "ticksPerTurn")
  if node.hasKey("moveCooldown"):
    config.moveCooldown =
      clampField(node["moveCooldown"].getInt(), 1, 8, "moveCooldown")
  if node.hasKey("carryCap"):
    config.carryCap = clampField(node["carryCap"].getInt(), 1, 2, "carryCap")
  if node.hasKey("shrubs"):
    config.shrubs = clampField(node["shrubs"].getInt(), 2, 4, "shrubs")
  if node.hasKey("tallCapacity"):
    config.tallCapacity =
      clampField(node["tallCapacity"].getInt(), 1, 8, "tallCapacity")
  if node.hasKey("tallRegrowTicks"):
    config.tallRegrowTicks =
      clampField(node["tallRegrowTicks"].getInt(), 6, 240, "tallRegrowTicks")
  if node.hasKey("shrubCapacity"):
    config.shrubCapacity =
      clampField(node["shrubCapacity"].getInt(), 1, 4, "shrubCapacity")
  if node.hasKey("shrubRegrowTicks"):
    config.shrubRegrowTicks =
      clampField(node["shrubRegrowTicks"].getInt(), 24, 960, "shrubRegrowTicks")
  if node.hasKey("childShrubPickPermille"):
    config.childShrubPickPermille = clampField(
      node["childShrubPickPermille"].getInt(), 0, 1000,
      "childShrubPickPermille")
  if node.hasKey("childReachCooldownTicks"):
    config.childReachCooldownTicks = clampField(
      node["childReachCooldownTicks"].getInt(), 0, 48,
      "childReachCooldownTicks")
  if node.hasKey("fruitLifetime"):
    config.fruitLifetime =
      clampField(node["fruitLifetime"].getInt(), 24, 960, "fruitLifetime")
  if node.hasKey("basketCapacity"):
    config.basketCapacity =
      clampField(node["basketCapacity"].getInt(), 0, 4, "basketCapacity")
  if node.hasKey("rewardPreferred"):
    config.rewardPreferred =
      clampField(node["rewardPreferred"].getInt(), 1, 10, "rewardPreferred")
  if node.hasKey("rewardOther"):
    config.rewardOther =
      clampField(node["rewardOther"].getInt(), 0, 10, "rewardOther")
  if node.hasKey("preferenceSwitch"):
    config.preferenceSwitch = node["preferenceSwitch"].getBool()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds =
      clampField(node["llmTimeoutSeconds"].getInt(), 5, 60, "llmTimeoutSeconds")
  if node.hasKey("minTurnSeconds"):
    config.minTurnSeconds =
      clampField(node["minTurnSeconds"].getInt(), 0, 60, "minTurnSeconds")
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens =
      clampField(node["maxOutputTokens"].getInt(), 200, 2000, "maxOutputTokens")
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  # The platform spells its connect grace both ways depending on surface.
  if node.hasKey("playerConnectTimeoutSeconds"):
    config.playerConnectTimeoutSeconds =
      node["playerConnectTimeoutSeconds"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getInt()
  if node.hasKey("shutdownGraceSeconds"):
    config.shutdownGraceSeconds = node["shutdownGraceSeconds"].getInt()
  if node.hasKey("showPlayerLabels"):
    config.showPlayerLabels = node["showPlayerLabels"].getBool()

  if config.numAgents < 1 or config.numAgents > 2:
    raise newException(DaycareError, "num_agents must be 1 or 2")
  while config.players.len < 2:
    config.players.add PlayerConfig(name: "seat" & $config.players.len)
  while config.tokens.len < 2:
    config.tokens.add "token-" & $config.tokens.len
