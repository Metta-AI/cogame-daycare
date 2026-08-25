## The hidden preference is actually hidden.
##
## Design note ## Tests, item 2. Five gates:
##  (a) the parent's `state` frame bytes carry neither the string `preference`
##      nor the preference value in any field it reads, nor the child's `hunch`
##      or `notes`;
##  (b) the same for the child's frame with respect to the parent's `guess`,
##      `hunch` and `notes`;
##  (c) `layoutHash(seed)` is IDENTICAL whether the preference is forced to
##      apple or banana — the layout comes from `rngLayout`, the preference from
##      `rngSecret`;
##  (d) the apple source set maps exactly onto the banana source set under
##      x -> 23 - x, in both mirror states and in all four variants;
##  (e) the `final` frame carries no `preference` key.

import std/[strutils]
import helpers

const Marker = "PARENT-PRIVATE-MARKER-\u00fc\u00f1\u00ee"
const ChildMarker = "CHILD-PRIVATE-MARKER-\u00fc\u00f1\u00ee"

proc jsonKeys(node: JsonNode, found: var seq[string]) =
  case node.kind
  of JObject:
    for key, value in node:
      found.add key
      jsonKeys(value, found)
  of JArray:
    for value in node: jsonKeys(value, found)
  else: discard

proc keysOf(node: JsonNode): seq[string] =
  jsonKeys(node, result)

echo "test_noleak: (a) the parent's state frame leaks nothing about the child"
echo "test_noleak: (b) the child's state frame leaks nothing about the parent"
block:
  for variant in AllVariants:
    let cfg = variantConfig(variant, 6)
    var sim = initSim(cfg, ["daycare-attentive", "daycare-provider"])
    let parent = sim.parentSeat
    let child = sim.childSeat
    var hedge = 0
    for turn in 1 .. cfg.turns:
      sim.turn = turn
      for seat in 0 .. 1:
        var order = orderFor(sim, seat, prCareCare, hedge)
        # Plant a private marker in each seat's own hunch and notes: if either
        # ever crosses to the other seat, these strings appear in its frame.
        if seat == parent:
          order.hunch = Marker
          order.notes = Marker & " notes"
        else:
          order.hunch = ChildMarker
          order.notes = ChildMarker & " notes"
        sim.applyOrder(seat, order)

      let parentJson = sim.playerStateJson(parent)
      let childJson = sim.playerStateJson(child)
      let parentFrame = $parentJson
      let childFrame = $childJson
      let parentKeys = keysOf(parentJson)
      let childKeys = keysOf(childJson)

      # (a) The parent's frame carries NO field that names the preference, the
      # switch turn, the seed or the reward split, and none of the child's
      # private strings. The word itself appears once, in the rules block that
      # TELLS the parent the preference is hidden from it — which is why this
      # gate walks the KEYS rather than grepping the bytes for a common word.
      for banned in ["preference", "rewardPreferred", "rewardOther",
          "switchTurn", "seed", "shrubPickChancePermille"]:
        doAssert banned notin parentKeys,
          variant & " turn " & $turn & ": the parent's frame has a " &
          banned & " field"
      doAssert ChildMarker notin parentFrame,
        variant & ": the child's hunch/notes reached the parent"
      # ... and its own private notes ARE returned to it.
      doAssert Marker in parentFrame,
        variant & ": the parent lost its own notes"

      # (b) The child's frame carries no `guess` field at all, and none of the
      # parent's private strings.
      doAssert "guess" notin childKeys,
        variant & " turn " & $turn & ": the child's frame has a guess field"
      for banned in ["switchTurn", "seed"]:
        doAssert banned notin childKeys, variant & ": child sees " & banned
      doAssert Marker notin childFrame,
        variant & ": the parent's hunch/notes reached the child"
      doAssert ChildMarker in childFrame,
        variant & ": the child lost its own notes"
      # The child DOES see its own preference — that is the asymmetry.
      doAssert "preference" in childKeys,
        variant & ": the child cannot see its own preference"
      doAssert "\"preference\":\"" & $sim.preference & "\"" in childFrame
      sim.playTurn()
    sim.settle("complete", "turn_limit")

echo "test_noleak: (a2) at turn 1 the parent's frame is BYTE-IDENTICAL " &
  "whichever preference was drawn"
block:
  # Before the child has done anything there is no behaviour to read, so the
  # only way the preference could reach the parent is through the bytes. It
  # does not.
  for variant in AllVariants:
    for seed in 1 .. 6:
      var frames: array[2, string]
      for forced in 0 .. 1:
        var cfg = variantConfig(variant, seed)
        cfg.forcePreference = forced
        var sim = initSim(cfg, ["daycare-attentive", "daycare-provider"])
        sim.turn = 1
        var hedge = 0
        for seat in 0 .. 1:
          sim.applyOrder(seat, orderFor(sim, seat, prCareCare, hedge))
        frames[forced] = $sim.playerStateJson(sim.parentSeat)
      doAssert frames[0] == frames[1],
        variant & " seed " & $seed &
        ": the parent's turn-1 frame depends on the preference"

echo "test_noleak: (c) the layout hash is independent of the preference"
block:
  for variant in AllVariants:
    for seed in 1 .. 12:
      var apple = variantConfig(variant, seed)
      apple.forcePreference = ord(fApple)
      var banana = variantConfig(variant, seed)
      banana.forcePreference = ord(fBanana)
      let a = initSim(apple)
      let b = initSim(banana)
      doAssert a.preference == fApple and b.preference == fBanana
      doAssert a.yard.layoutHash() == b.yard.layoutHash(),
        variant & " seed " & $seed &
        ": the layout depends on the preference"
      doAssert a.yard.mirrored == b.yard.mirrored
      # ... and the yard a seat can observe is byte-identical.
      doAssert $a.configJson() == $b.configJson(),
        variant & " seed " & $seed & ": the config JSON differs"

echo "test_noleak: (c2) the child's shrub-pick coin is not drawn from rngSecret"
block:
  # r1 review N4: the pick coin used to be seeded from rngSecret's own stream,
  # so an outcome the parent DOES observe (a `reach` event, `reachFails`) came
  # off the stream the note reserves for what the parent may never see — and a
  # switch draw shifted the pick sequence, which the code's own comment denied.
  # The coin now has its own stream off the seed: neither the preference nor the
  # switch turn can move it.
  proc pickDraws(cfg: GameConfig): seq[int] =
    var sim = initSim(cfg)
    for i in 0 ..< 32:
      result.add sim.pickRng.rand(1000)

  for seed in 1 .. 12:
    var apple = variantConfig("daycare", seed)
    apple.forcePreference = ord(fApple)
    var banana = variantConfig("daycare", seed)
    banana.forcePreference = ord(fBanana)
    doAssert pickDraws(apple) == pickDraws(banana),
      "seed " & $seed & ": the pick coin depends on the preference"
    # `daycare` and `daycare-fickle` differ only in preferenceSwitch, and the
    # switch turn is the second draw off rngSecret.
    let fixed = variantConfig("daycare", seed)
    let fickle = variantConfig("daycare-fickle", seed)
    doAssert initSim(fickle).switchTurn > 0
    doAssert pickDraws(fixed) == pickDraws(fickle),
      "seed " & $seed & ": the switch draw shifts the pick sequence"

echo "test_noleak: (d) the apple source set maps onto the banana set under " &
  "x -> 23 - x, in both mirror states and in all four variants"
block:
  for variant in AllVariants:
    for mirrored in [false, true]:
      let yard = initYard(variantConfig(variant, 1), mirrored)
      for kind in [skTall, skShrub]:
        var apples: seq[(int, int)]
        var bananas: seq[(int, int)]
        for s in yard.sources:
          if s.kind != kind: continue
          if s.fruit == fApple: apples.add (YardCols - 1 - s.x, s.y)
          else: bananas.add (s.x, s.y)
        doAssert apples.len == bananas.len,
          variant & " " & $kind & ": " & $apples.len & " apple vs " &
          $bananas.len & " banana sources"
        for cell in apples:
          doAssert cell in bananas,
            variant & " " & $kind & " mirrored=" & $mirrored &
            ": reflected apple source " & $cell & " is not a banana source"

echo "test_noleak: (d2) the spawns do NOT mirror, so the mirror bit really " &
  "swaps which species is nearer"
block:
  # The reflection is an isometry: mirroring the spawns with the sources would
  # leave every distance unchanged and the mirror bit could not remove a species
  # bias. Feasibility gate (f) is what measures the outcome; this pins the
  # mechanism.
  var seenNearApple = false
  var seenNearBanana = false
  for mirrored in [false, true]:
    let yard = initYard(variantConfig("daycare", 1), mirrored)
    let spawn = yard.spawns[ord(rChild)]
    doAssert spawn == yard.idx(ChildSpawn[0], ChildSpawn[1]),
      "the child spawn moved with the mirror"
    var nearest: array[Fruit, int]
    for f in Fruit:
      nearest[f] = high(int)
      for s in yard.sources:
        if s.fruit != f: continue
        nearest[f] = min(nearest[f], chebyshev(spawn mod yard.cols,
          spawn div yard.cols, s.x, s.y))
    if nearest[fApple] < nearest[fBanana]: seenNearApple = true
    if nearest[fBanana] < nearest[fApple]: seenNearBanana = true
  doAssert seenNearApple and seenNearBanana,
    "the mirror bit does not swap which species is nearer the spawn"

echo "test_noleak: (e) the final frame carries no preference"
block:
  let sim = playEpisode(variantConfig("daycare-fickle", 8))
  let results = sim.resultsJson()
  # This is the exact object src/daycare/server.nim sends as `final`.
  let final = %*{
    "type": "final",
    "done": true,
    "scores": results["scores"],
    "names": [sim.names[0], sim.names[1]],
    "roles": results["roles"],
    "turns": results["turns"],
    "reason": results["reason"],
    "ending": results["ending"]
  }
  doAssert not final.hasKey("preference")
  doAssert "preference" notin $final
  doAssert $sim.preference notin $final,
    "the final frame leaks the preference by value"
  # results.json DOES carry it: the platform stores results, players never see
  # them, and the spectator reveal is the whole broadcast premise.
  doAssert results.hasKey("preference")

echo "test_noleak: the replay's secret block is written after the episode"
block:
  let sim = playEpisode(variantConfig("daycare", 2))
  let replay = replayJson(sim, sim.resultsJson())
  let doc = parseJson(replay)
  doAssert doc["secret"]{"preference"}.getStr() == $sim.preference
  doAssert doc["secret"]{"switchTurn"}.getInt() == sim.switchTurn

echo "test_noleak: OK"
