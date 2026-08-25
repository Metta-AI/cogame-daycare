## The replay's `events[]` vocabulary: one JSON row per event.
##
## Fork of `coworld-ctf/src/ctf/events.nim` — same `jsonRow` / `eventsJsonl`
## shape. Rows are built HERE and nowhere else, so the row a live spectator
## sees and the row the replay carries are byte-identical by construction.
##
## `t` = tick, `seat` = slot, `f` = fruit species, `src` = source id.

import std/[json, strutils]
import sim_types

proc pickRow*(t, seat: int, f: Fruit, src, fromWhat: string, x, y: int): JsonNode =
  %*{"k": "pick", "t": t, "seat": seat, "f": $f, "src": src,
     "from": fromWhat, "x": x, "y": y}

proc reachRow*(t, seat: int, f: Fruit, src: string, kind: SourceKind,
    n: int): JsonNode =
  ## Coalesced: the first failure at a source emits immediately, then at most
  ## one row per `ReachCoalesceTicks` while the streak continues, with `n` =
  ## attempts since the last row. Uncoalesced this would be ~700 rows.
  %*{"k": "reach", "t": t, "seat": seat, "f": $f, "src": src,
     "kind": $kind, "n": n}

proc dropRow*(t, seat: int, f: Fruit, x, y: int, near: string): JsonNode =
  %*{"k": "drop", "t": t, "seat": seat, "f": $f, "x": x, "y": y, "near": near}

proc eatRow*(t, seat: int, f: Fruit, pref: bool, pts: int): JsonNode =
  %*{"k": "eat", "t": t, "seat": seat, "f": $f, "pref": pref, "pts": pts}

proc wasteRow*(t, seat: int, f: Fruit, x, y: int): JsonNode =
  %*{"k": "waste", "t": t, "seat": seat, "f": $f, "x": x, "y": y}

proc rotRow*(t: int, f: Fruit, x, y: int): JsonNode =
  %*{"k": "rot", "t": t, "f": $f, "x": x, "y": y}

proc ripenRow*(t: int, src: string, f: Fruit): JsonNode =
  %*{"k": "ripen", "t": t, "src": src, "f": $f}

proc orderRow*(t, seat, turn: int, role: Role, job: string, f: string,
    guess: string, source: OrderSource, hunch, notes: string,
    latencyMs: int): JsonNode =
  %*{"k": "order", "t": t, "seat": seat, "turn": turn, "role": $role,
     "job": job, "f": f, "guess": guess, "source": $source,
     "hunch": hunch, "notes": notes, "latencyMs": latencyMs}

proc guessRow*(t, turn: int, guess: Fruit, correct: bool): JsonNode =
  ## `correct` is spectator-side truth and is NEVER sent to a seat.
  %*{"k": "guess", "t": t, "turn": turn, "guess": $guess, "correct": correct}

proc switchRow*(t, turn: int, fromF, toF: Fruit): JsonNode =
  %*{"k": "switch", "t": t, "turn": turn, "from": $fromF, "to": $toF}

proc turnRow*(t, turn: int, scores: array[2, int], guess: string,
    guessCorrect: bool, childAte, delivered, reaches: array[Fruit, int]):
    JsonNode =
  ## `childAte` / `delivered` / `reaches` are indexed [apple, banana].
  %*{"k": "turn", "t": t, "turn": turn,
     "scores": [scores[0], scores[1]],
     "guess": guess, "guessCorrect": guessCorrect,
     "childAte": [childAte[fApple], childAte[fBanana]],
     "delivered": [delivered[fApple], delivered[fBanana]],
     "reaches": [reaches[fApple], reaches[fBanana]]}

proc endRow*(t: int, reason, ending: string, scores: array[2, int],
    preference: Fruit, guessTurnsCorrect, turns: int): JsonNode =
  %*{"k": "end", "t": t, "reason": reason, "ending": ending,
     "scores": [scores[0], scores[1]], "preference": $preference,
     "guessTurnsCorrect": guessTurnsCorrect, "turns": turns}

proc eventsJsonl*(events: openArray[JsonNode]): string =
  ## One row per line — the shape every probe and test reads.
  var lines: seq[string]
  for row in events:
    lines.add $row
  lines.join("\n")
