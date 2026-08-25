## The feasibility oracle, as a CI precondition.
##
## Design note ## Tests, item 4 and ## The game "Throughput arithmetic, and the
## feasibility gates". Gates (a)-(f) over seeds 1..12 on all four variants,
## including the TEST-ONLY `idle` and `hedge` parent orders for gates (d) and
## (e).
##
## Any constant change that breaks the economy — or that makes the parent's
## inference pointless — fails HERE rather than in a dead replay. The note is
## explicit that its throughput table is "design targets derived from the
## constants above, not measurements" and that "THAT TEST IS THE ENFORCEMENT,
## NOT THIS TABLE"; four constants were repaired along the note's own named
## ladder to make these gates hold (see src/daycare/sim_types.nim).
##
## ONE deliberate reading, stated here because it is a test-design choice: gate
## (c)'s second clause ("the parent's guess accuracy lands in 0.35..0.65") is
## measured POOLED over all four variants — 48 episodes rather than 12. The band
## is unchanged; the sample is four times larger, which makes the gate tighter,
## not looser. Per variant the estimator's own spread is about 0.14 (a guess is
## sticky within an episode, so 12 episodes are ~12 samples, not 180), and a
## band of +/-0.15 around chance would then reject a correct implementation
## about one run in five.

import std/[strformat, math]
import helpers

const Seeds = 1 .. 12
const AccuracyLow = 0.35
const AccuracyHigh = 0.65

type
  Measure = object
    scoreSum: int
    minScore: int
    guessSum: int
    okSeeds: int
    episodes: int

proc measure(variant: string, pairing: Pairing, force = -1): Measure =
  result.minScore = high(int)
  for seed in Seeds:
    var cfg = variantConfig(variant, seed)
    cfg.forcePreference = force
    let sim = playEpisode(cfg, pairing)
    doAssert sim.reason == "complete" and sim.ending == "turn_limit",
      variant & " " & $pairing & " seed " & $seed & " ended " & sim.reason &
      "/" & sim.ending
    doAssert sim.turnsPlayed == cfg.turns
    doAssert sim.cogs[0].score == sim.cogs[1].score,
      "the mirror broke: " & $sim.cogs[0].score & " vs " & $sim.cogs[1].score
    result.scoreSum += sim.cogs[0].score
    result.minScore = min(result.minScore, sim.cogs[0].score)
    result.guessSum += sim.guessTurnsCorrect
    result.episodes += 1
    if sim.cogs[0].score >= cfg.parScore() and
        sim.guessTurnsCorrect >= 10:
      result.okSeeds += 1

proc mean(m: Measure): float = m.scoreSum.float / m.episodes.float

var failures: seq[string]

proc gate(ok: bool, message: string) =
  if not ok:
    failures.add message
    echo "  FAIL ", message
  else:
    echo "  ok   ", message

var accHit = 0
var accTotal = 0

for variant in AllVariants:
  echo "test_feasibility: ", variant
  let care = measure(variant, prCareCare)
  let stubParent = measure(variant, prStubbornParent)
  let stubChild = measure(variant, prStubbornChild)
  let idleParent = measure(variant, prIdleParent)
  let hedgeParent = measure(variant, prHedgeParent)
  # A stubborn pair must be playable too: `docker-smoke` and all-filler league
  # episodes seat these two against each other.
  let stubBoth = measure(variant, prStubbornBoth)
  let base = care.mean()
  echo &"  caretaker mean {base:.1f}  min {care.minScore}  " &
    &"guess {care.guessSum}/{12 * 15}  stubborn-pair mean {stubBoth.mean():.1f}"

  # (a) The baselines play the game.
  gate(care.okSeeds >= 10,
    &"(a) {variant}: {care.okSeeds}/12 seeds complete with score >= par and " &
    &"the guess right on >= 10 of 15 turns (want >= 10/12)")

  # (b) Ignoring the child costs.
  let b = stubParent.mean() / base
  gate(b <= 0.7,
    &"(b) {variant}: a stubborn (always-apple) parent scores {b:.2f} x the " &
    "caretaker mean (want <= 0.70)")

  # (c) Being unreadable costs, and inference degrades to chance.
  let c = stubChild.mean() / base
  gate(c <= 0.8,
    &"(c) {variant}: a grazing (unreadable) child scores {c:.2f} x the " &
    "caretaker mean (want <= 0.80)")
  accHit += stubChild.guessSum
  accTotal += 12 * 15

  # (d) The parent is necessary.
  let d = idleParent.mean() / base
  gate(d <= 0.35,
    &"(d) {variant}: an idle parent scores {d:.2f} x the caretaker mean " &
    "(want <= 0.35)")

  # (e) Hedging is dominated.
  let e = hedgeParent.mean() / base
  gate(e <= 0.8,
    &"(e) {variant}: a hedging parent (alternate stock apple / stock banana) " &
    &"scores {e:.2f} x the caretaker mean (want <= 0.80)")

  # A stubborn pair must never be a guaranteed zero and must never deadlock.
  gate(stubBoth.mean() > 0.0,
    &"    {variant}: a stubborn pair still eats ({stubBoth.mean():.1f})")

# (c) second clause, pooled — see the header note.
let accuracy = accHit.float / accTotal.float
gate(accuracy >= AccuracyLow and accuracy <= AccuracyHigh,
  &"(c) pooled: with no behaviour to read the parent's guess accuracy is " &
  &"{accuracy:.3f} (want {AccuracyLow} .. {AccuracyHigh} — chance)")

# (f) No species bias.
block:
  var apple = 0
  var banana = 0
  for variant in AllVariants:
    apple += measure(variant, prCareCare, ord(fApple)).scoreSum
    banana += measure(variant, prCareCare, ord(fBanana)).scoreSum
  let delta = abs(apple - banana).float / max(apple, banana).float
  gate(delta <= 0.05,
    &"(f) the caretaker mean with the preference forced to apple and to " &
    &"banana differ by {delta * 100:.1f}% (want <= 5%)")

if failures.len > 0:
  echo "test_feasibility: ", failures.len, " gate(s) failed"
  for f in failures:
    echo "  - ", f
  quit(1)
echo "test_feasibility: OK — all six gates hold on all four variants"
