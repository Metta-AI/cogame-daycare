## Daycare entrypoint. Reads the Coworld runtime contract and starts the episode
## server.
##
## Forked from `coworld-ctf/src/ctf.nim`: the seed is randomised BEFORE
## `config.update`, which is paintbot's rule — every seed-derived draw (the
## mirror bit, the child's preference, the fickle switch turn) must follow the
## FINAL seed.

import
  std/[json, sysrand],
  bitworld/runtime,
  daycare/[server, sim, sim_config]

proc randomSeed(): int =
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(DaycareError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc seedPinned(configJson: string): bool =
  if configJson.len == 0:
    return false
  try:
    let node = parseJson(configJson)
    node.kind == JObject and node.hasKey("seed")
  except CatchableError:
    false

when isMainModule:
  let runtimeConfig = readRuntimeConfig()
  var config = defaultGameConfig()
  if not seedPinned(runtimeConfig.config):
    ## An unpinned seed is randomised so the preference, the mirror bit and the
    ## switch turn are not precomputable.
    config.seed = randomSeed()
    echo "daycare: seed not pinned; randomized"
  config.update(runtimeConfig.config)
  echo "daycare: seats=", config.numAgents, " turns=", config.turns,
    " ticksPerTurn=", config.ticksPerTurn, " variant=", config.variantId()
  runGameServer(config, runtimeConfig)
