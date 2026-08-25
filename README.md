# Daycare

**One cog can reach the fruit, the other one knows which fruit it wants, and
neither can say a word.**

Two cogs share a walled yard. The **child** (`Bramble`) secretly prefers apples
or bananas and can *never* reach the tall trees — reaching there always fails.
The **parent** (`Alder`) can harvest everything, and is paid only when the child
eats: three points when the meal is the fruit the child wants, one when it is
the other. **Both seats score the same number.** There is no message channel in
either direction, so the parent has to read the child's preference out of where
it walks, what it reaches for, and what it refuses to eat.

Caregiving as a game: read another agent's goals from its actions and provide
for them, with no explicit channel. Ported from Melting Pot's `daycare`
substrate — as a design source, not a binary to reproduce.

A policy is just a prompt.

---

## How a turn works

An episode is **15 turns × 60 ticks = 900 ticks** (37.5 s of replay at 24 fps).
A seat does not author 900 actions — no model can. Once per turn each seat sends
**one standing order** and a deterministic kernel turns it into the per-tick grid
action stream for the whole turn. Both seats' orders are decided
**simultaneously**, and both requests go out as **one parallel batch** per turn.

| role | jobs |
|---|---|
| parent | `provide <fruit>` · `stock <fruit>` · `watch` · `idle`, plus a `guess` every turn |
| child | `seek <fruit>` · `show <fruit>` · `graze` · `beg` · `idle` |

`show` is the channel: the child stands under a tall tree of its species and
reaches for it over and over. It can never yield food. It is the only way the
child can say what it wants.

`graze` is the anti-channel: eat whatever is nearest, either species, and tell
the parent nothing.

## The yard

A fixed 24 × 14 grid inside a fence ring, 48 board px per cell — 1152 × 672, and
the whole board always fits the frame. Eight tall trees (4 apple, 4 banana), two
to four shrubs, and a four-cell woven basket mat in the middle where fruit never
rots. The layout is **species-congruent by construction**: the reflection
`x → 23 − x` maps the apple source set exactly onto the banana set, and a mirror
bit drawn from the layout RNG decides which species sits nearer the spawns — so
no species is favoured, and "apples live on the left" is not a learnable prior
either. The child's preference is drawn from a *separate* RNG sub-stream
(`seed xor 0x0DA9CA12`), so nothing the parent can observe depends on it.

`tests/test_noleak.nim` asserts all of that on the bytes: the parent's turn-1
state frame is byte-identical whichever preference was drawn.

## Variants

| id | shrubs | child shrub pick | preference switches | slot 0 |
|---|---|---|---|---|
| `daycare` | 4 | 25 % | no | parent |
| `daycare-sparse` | 2 | 15 % | no | parent |
| `daycare-fickle` | 4 | 25 % | **yes**, once, at a turn in 6..9 | parent |
| `daycare-swapped` | 4 | 25 % | no | **child** |

`num_agents` is **2** in every one, and in the certification fixture.

## Fielding a policy

Two policies ship in the same image from day one, selected by env var:

```bash
# an LLM policy — the strategy IS the prompt
coworld upload-policy coworld-daycare:latest --name my-daycare \
  --run /bin/daycare-player \
  --secret-env PLAYER_PROMPT="<your strategy, for BOTH roles>" \
  --secret-env USE_BEDROCK=true

# a built-in baseline, deterministic, no LLM
coworld upload-policy coworld-daycare:latest --name my-baseline \
  --run /bin/daycare-player --secret-env PLAYER_SCRIPTED=caretaker
```

The model answers with exactly one JSON object:

```json
{"job":"provide","fruit":"banana","guess":"banana",
 "hunch":"it only ever reaches for bananas",
 "notes":"turn 3 it walked over an apple twice"}
```

`hunch` is capped at 80 runes and is **spectator-only**; `notes` is capped at 240
runes and is **private to that seat**, returned to it next turn. Neither ever
reaches the other seat — that is how "no explicit channel" is enforced
mechanically rather than by convention. Every recorded string is truncated on
**rune** boundaries.

An invalid reply is retried once with a hint; still failing, that seat plays the
`caretaker` order for the turn and the `order` event records
`"source":"fallback"`. With no credentials at all the client disables itself
immediately and both seats play `caretaker`, which is what keeps offline
certification green and deterministic.

Full per-role schema: `game.docs.pages[policies.md]` in
`coworld_manifest_template.json`.

## Baselines

- **`caretaker`** — the working baseline, and the order every failed LLM decision
  lands on. As the parent it weighs the child's cumulative behaviour summary
  (failed reaches first, then refusals, then adjacency, then meals), guesses and
  provides. As the child it seeks its own species when it can, and otherwise
  stands under a tall tree of that species and reaches.
- **`stubborn`** — the anti-theory-of-mind foil. As the parent: apples, forever,
  ignoring the child. As the child: `graze`, which emits no species signal at
  all.

## Watching

Replays are a **static file plus a browser wasm viewer**, never a pod. The
manifest declares `"replay_viewer": {"bundle": "static-replay-viewer"}` and
`tools/build_replay_viewer.sh` is the `coworld build` hook that compiles the same
sim module to wasm with emscripten.

The broadcast chrome is `coworld-ctf`'s (paintbot's), with a Daycare block
appended: `client/chrome_common.js` and `client/broadcast_core.js` ship
**byte-for-byte**, and `client/replay_broadcast.html` is the starter's page with
the zoom/locator panel, the first-person inset, the POV badge and the
replay-hash warning removed, two scorebug literals re-lettered, and the game's
own CSS, markup and script appended under a banner comment.

What a spectator sees: `TURN 9 / 15`, two plates reading `PARENT 41` and
`CHILD 41`, and the panel this whole game exists for —

```
BRAMBLE WANTS:   🍌 BANANA
ALDER GUESSES:   🍎 APPLE     WRONG
RIGHT 6 / 15 TURNS
■■□■■■□■■■□□□□□          <- one chip per turn
```

The child's preference is revealed to **spectators only**. The parent never
learns it — not from an observation, not from the `final` frame, not at the
buzzer. Only the replay and `results.json` carry it.

## Layout

```
src/daycare.nim              entrypoint; the seed is randomised BEFORE config.update
src/daycare_player.nim       the thin prompt-carrying player (from cogame-bullwhip)
src/daycare/sim_types.nim    consts, wire types, the seeded RNG. Field order is sacred.
src/daycare/yard.nim         the authored 24x14 grid, the mirror, and the BFS
src/daycare/kernel.nim       both standing-order kernels
src/daycare/sim.nim          the nine-step tick, scoring, the per-seat observation
src/daycare/scripted.nim     the two role-aware baselines
src/daycare/llm.nim          the batched decision layer (from cogame-bullwhip)
src/daycare/replays.nim      daycare.replay.v1: STATE, not inputs
src/daycare/broadcast.nim    the chrome frame in the starter's own shapes
src/daycare/global.nim       the sprite-protocol board emitter
src/daycare/server.nim       the Coworld game contract
replay-viewer/               the static wasm bundle (coworld-ctf, one starter)
scripts/art/                 nano-banana cog kits + the deterministic yard tiles
tests/                       ten test items; ci.yml is the only harness
```

`nim.cfg` is host-specific and gitignored — the Dockerfile and `ci.yml` both
rebuild it from `~/.nimby/pkgs`.

## Art

The two character kits are **nano-banana renders of the Softmax cog**
(`gemini-2.5-flash-image`): one sheet, three figures — the tall blue parent with
a wicker fruit basket, the small yellow child, and the same child with both arms
overhead for the reach frame. The source sheet is committed at
`scripts/art/source/cogs_sheet.png` and `scripts/art/split_cog_sheet.py` keys,
splits and pads it. The roles read apart at 40 px and 28 px with every label
hidden, which is the point.

Everything else in the yard — grass, path, fence, mat, the tall trees in three
canopy states, the shrubs, the fruit sprites (round vs crescent, so the guess is
legible in greyscale), the reach puff, the eat sparkle, the waste cloud and the
loading curtain — is `scripts/art/gen_daycare_art.py`, deterministic Pillow.

```bash
python3 scripts/art/split_cog_sheet.py     # sheet -> the two cog kits
python3 scripts/art/gen_daycare_art.py     # everything else, plus the carry poses
```

## Tests

The sandbox that wrote this cannot run Docker; `.github/workflows/ci.yml` is the
only verdict. Three jobs: `test` (every `tests/*.nim`, twice — debug and
release), `docker-smoke` (the production image plays a real two-container episode
off the certification fixture and keeps the replay), and `wasm-viewer` (builds
the bundle, **opens it in headless chromium against that replay** with `--soak`
and `--strict-text-bounds`, then renders `tools/ci/renderer_fixture.html` — the
worst-case chrome with a full-cap hunch and notes on both seats at 360 px,
because a credential-free smoke replay carries zero LLM text).

`tests/test_feasibility.nim` is the economy oracle: six gates over seeds 1..12 on
all four variants — the baselines play the game, ignoring the child costs, being
unreadable costs, the parent is necessary, hedging is dominated, and there is no
species bias. Four constants were repaired along the design note's own named
ladder to make those gates hold; `src/daycare/sim_types.nim` says which and why.

## License

MIT.
