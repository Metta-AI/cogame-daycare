## Bounded orders / legality, for both baselines in both roles.
##
## Design note ## Tests, item 3: for 12 seeds x a full episode on all four
## variants, for each of the four baseline pairings, every emitted order's `job`
## is inside THAT ROLE'S enum, `fruit` is inside the species enum wherever
## required, the parent emits a legal `guess` every turn; every per-tick action
## is one of the eight vocabulary values; no cog is ever outside the yard,
## inside fence/tree/shrub, or sharing a cell; no cog carries more than one
## fruit; no score, `ripe` or `ttl` goes negative; `ripe` never exceeds
## capacity; the mat never exceeds `basketCapacity`; neither baseline raises,
## and neither takes more than 1 ms per turn.

import std/[strformat, times]
import helpers

const
  Pairings = [prCareCare, prStubbornParent, prStubbornChild, prStubbornBoth]
  ParentJobs = {pjProvide, pjStock, pjWatch, pjIdle}
  ChildJobs = {cjSeek, cjShow, cjGraze, cjBeg, cjIdle}
  Actions = {aMoveN, aMoveS, aMoveE, aMoveW, aPick, aDrop, aEat, aWait}

var slowestTurnMs = 0.0
var orders = 0

for variant in AllVariants:
  for pairing in Pairings:
    for seed in 1 .. 12:
      let cfg = variantConfig(variant, seed)
      var sim = initSim(cfg, ["daycare-attentive", "daycare-caretaker"])
      var hedge = 0
      let where = &"{variant} {pairing} seed {seed}"
      for turn in 1 .. cfg.turns:
        sim.turn = turn
        let started = epochTime()
        for seat in 0 .. 1:
          let order = orderFor(sim, seat, pairing, hedge)
          inc orders
          if sim.roleOf[seat] == rParent:
            doAssert order.pjob in ParentJobs, &"{where}: parent job"
            doAssert order.hasGuess, &"{where}: the parent sent no guess"
            doAssert order.guess in {fApple, fBanana}, &"{where}: guess"
            if order.pjob in {pjProvide, pjStock}:
              doAssert order.hasFruit, &"{where}: {order.pjob} without a fruit"
              doAssert order.fruit in {fApple, fBanana}, &"{where}: fruit"
          else:
            doAssert order.cjob in ChildJobs, &"{where}: child job"
            doAssert not order.hasGuess or sim.roleOf[seat] == rParent,
              &"{where}: the child sent a guess"
            if order.cjob in {cjSeek, cjShow}:
              doAssert order.hasFruit, &"{where}: {order.cjob} without a fruit"
              doAssert order.fruit in {fApple, fBanana}, &"{where}: fruit"
          doAssert order.hunch.len <= 4 * MaxHunchLen, &"{where}: hunch bytes"
          # applyOrder is the validator every LLM reply also goes through.
          sim.applyOrder(seat, order)
        let decideMs = (epochTime() - started) * 1000.0
        slowestTurnMs = max(slowestTurnMs, decideMs)

        for tick in 1 .. cfg.ticksPerTurn:
          for seat in 0 .. 1:
            doAssert kernelAction(sim, seat) in Actions, &"{where}: action"
          sim.stepTick()
          doAssert sim.cogs[0].x != sim.cogs[1].x or
            sim.cogs[0].y != sim.cogs[1].y, &"{where}: the cogs share a cell"
          for seat in 0 .. 1:
            let cog = sim.cogs[seat]
            doAssert cog.x > 0 and cog.y > 0 and
                cog.x < sim.yard.cols - 1 and cog.y < sim.yard.rows - 1,
              &"{where}: seat {seat} left the yard at ({cog.x},{cog.y})"
            doAssert sim.yard.kindAt(cog.x, cog.y) in {ckGrass, ckMat},
              &"{where}: seat {seat} stands on {sim.yard.kindAt(cog.x, cog.y)}"
            doAssert cog.carry >= -1 and cog.carry <= 1,
              &"{where}: carryCap broken ({cog.carry})"
            doAssert cog.score >= 0, &"{where}: negative score"
          for s in sim.yard.sources:
            doAssert s.ripe >= 0, &"{where}: {s.id} ripe {s.ripe}"
            doAssert s.ripe <= s.capacity,
              &"{where}: {s.id} ripe {s.ripe} over capacity {s.capacity}"
          for g in sim.ground:
            doAssert g.ttl == -1 or g.ttl > 0, &"{where}: ttl {g.ttl}"
          doAssert sim.matTotal() <= cfg.basketCapacity,
            &"{where}: the mat holds {sim.matTotal()}"
        sim.closeTurn()
      sim.settle("complete", "turn_limit")
      doAssert sim.cogs[0].score == sim.cogs[1].score, &"{where}: mirror"

echo &"test_baseline: {orders} orders, slowest decision {slowestTurnMs:.3f} ms"
doAssert slowestTurnMs <= 1.0,
  &"a baseline turn took {slowestTurnMs:.3f} ms (want <= 1 ms)"
echo "test_baseline: OK"
