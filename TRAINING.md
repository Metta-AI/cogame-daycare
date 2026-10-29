# Daycare prompt diversity and training

Set `promptVariant` to `canonical`, `plain`, `numbered`, `questions`, or `reordered`. `mixed` selects one of these five
using explicit nonnegative `promptSeed % 5`. Selection stays fixed across both roles, turns, and retries, and does not
consume simulation randomness. `heldout-briefing` and `heldout-reference` are evaluation-only. The canonical prompt
retains its original bytes. Alternatives vary identity, simultaneous communication rules, and role-specific knowledge.
Game facts, job definitions, and strategic hints retain their meaning.

The private provenance bank is `daycare-rules-v2`. It records exact system/user hashes without placing provenance in
model input or spectator replay. Role observations remain unchanged: parents cannot see the child's preference, orders,
hunches, or notes; children cannot see the parent's guess or private text.

## Full-text collection

```bash
nim c -d:release --path:src -o:/tmp/daycare-train-bridge tools/train_bridge.nim
```

Use `[/tmp/daycare-train-bridge, /absolute/path/coworld_manifest_template.json, daycare, text]` with the shared Metta
text collector and `players=2`. Reset accepts `promptVariant`, `promptSeed`, and `split`; training rejects both held-out
variants. All four published yard variants are supported.

The text path accepts full orders, including independent parent guesses, spectator hunches, and private notes. It
collects both seats' orders before installing either, preserving simultaneous decisions. The hosted parser and validator
determine the normalized order returned to the collector.

## Teacher exports

```bash
nim c -d:release --path:src -o:/tmp/daycare-export tools/export_posttrain.nim
/tmp/daycare-export /tmp/daycare-examples 10 1 daycare mixed 0
```

Run from a clean, committed checkout. The original `train.jsonl`, `validation.jsonl`, and `manifest.json` format is
preserved. Mixed selection cycles the five training wordings separately within each split, so validation does not remove
a wording from training. Episode IDs include requested selection, resolved wording, and prompt seed to distinguish
matched collections of the same scenario. Seed families exclude yard variant and wording; multiples of five enter
validation. Held-out wordings and existing output paths are rejected. Output directories are private.

The teacher remains caretaker in seat zero and stubborn in seat one, including swapped roles. Both orders are parsed and
validated before either is installed. Each export covers all 15 turns and 900 ticks. Wording metadata records the
selected variant and rendered message hashes.

```bash
python3 tools/test_export_posttrain.py /tmp/daycare-export
python3 tools/test_prompt_games.py /tmp/daycare-train-bridge
```

Complete-game checks cover all four variants, private role information, independent parent guesses, note persistence,
and normalized orders. They check mechanics and protocol behavior, not improved learning or resistance to policy
collapse. Model comparisons require separate matched evaluations.

## Numeric training

For reinforcement learning, compile the persistent bridge and test all four certified variants:

```bash
nim c -d:release --path:src -o:daycare-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py ./daycare-train-bridge
```

From Metta, use either `recipes.external.coworld.train` for native PufferLib or
`recipes.external.coworld_metta_rl.train` for Metta RL. Pass a command with the absolute bridge and manifest paths, the
variant ID, and `players=2`. Set a training timestep limit. The bridge exposes 32 player-visible numeric values and a
fixed 12-choice catalog. It masks unused choices by role and uses the published caretaker and stubborn baselines for
opponents and teacher labels.

Daycare is cooperative: both seats receive the same score. The bridge supplies an explicit terminal utility
`2 * score / (score + par) - 1`, which is monotonic in the shared score. This needs Metta #24683, stacked on #24679 and
#24573.

## Native private capture

Set `COGAME_SAVE_TRAJECTORY_URI` to a private artifact destination to opt in. The ordinary `/bin/daycare-player` still
delivers its prompt, and the game still issues the native simultaneous batch. Capture does not replace either player,
change prompts, decode moves differently, advance an RNG, or change clocks. With the variable unset, new observations,
request copies and hashes are skipped.

Supply the runtime episode, game version and source revision through `COWORLD_EPISODE_ID`, `COWORLD_GAME_VERSION` and
`COWORLD_SOURCE_REVISION`. `COWORLD_GAME_IMAGE_DIGEST`, when supplied, must be an immutable SHA256 digest. These
identity fields must contain Unicode scalar UTF-8. The private destination must differ from both public artifact
destinations, including equivalent file paths or signed URLs to the same object.

Each actor row freezes the native `playerStateJson` before either current order is installed. It includes only that
actor's private view, prompt selection, original request bytes, safe **request** headers, original response bytes and
parsed private response headers, decoder settings, model/usage diagnostics, call IDs and all failed/retried attempts.
HTTP receipt IDs in local fixtures are synthetic UUIDs. A captured ID does not independently authenticate a provider
receipt; hosted admission must join actual owned platform requests.

After both native orders are applied, capture records the actor's installed order and its own authoritative `order`
event. It does not copy another seat's notes or use the spectator replay's secret preference in an observation. The
existing spectator replay remains a post-episode record and includes secret and note fields; it is not the actor's
observation or a model completion.

The native parser also checks consumed `hunch` and `notes` strings for Unicode scalar UTF-8 before cleaning them.
Invalid consumed text follows the existing retry and caretaker fallback path. Direct native order application performs
this preflight before cleaning or changing state. Ignored outer JSON fields remain ignored by gameplay. This validation
is independent of capture.

Selection requires a completed joined 2xx response, no prior rejection, strict JSON grammar and decoded-key uniqueness,
scalar UTF-8, and unchanged types and values for every supplied field compared with the installed action. Native fences
and omitted defaults remain eligible. Native case folding, trimming, clamping, truncated strings, ignored fields and
permissive numeric/JSON forms continue to work in the game but are rejected as targets. Original responses are never
rewritten into canonical labels. Scripted/external actions without a native model attempt remain unselected; actual
fallback orders are identified as fallback. Invalid scalar evidence is quarantined as exact base64 JSON bytes, with no
selected attempt or action. The same guard covers persistent next-turn requests, terminal results and runtime identity.

Evidence limits are 64 KiB per request/response, 16 KiB parsed response headers, 128 KiB per observation and 24 MiB per
episode. Overbounds and publication failures are explicit capture gaps; they do not change gameplay or public artifacts.
Batch elapsed time is recorded separately: synchronous batch return does not measure individual successful-request
latency. The native Curly header API does not expose a lossless original HTTP-header byte stream.

The writer is reused without changes from the MIT-licensed
[Bitworld decision trajectory module](https://github.com/Metta-AI/bitworld/blob/c336f54e10e9028d9cfbda540ee085ac7627fbb3/src/bitworld/decision_trajectory.nim),
using the already reviewed runtime import adaptation.

`scenario_family` identifies canonical unmirrored physical yard configuration. Seed, role swaps, horizon and prompt
wording do not create new groups. Exact effective configuration has a separate `task_identity`. Standard four-shrub and
sparse two-shrub configurations differ physically, but share much of the authored yard. Neither a hash nor different
seeds establishes independent worlds; overlap and symmetry audits are required before a learning split.

For a bounded local native system check, compile the original game/player and the patched game with the repository's
pinned Nim dependencies, then run:

```sh
env -i PATH="$PATH" HOME="$HOME" TMPDIR=/tmp LANG=en_US.UTF-8 \
  python tools/ci/native_capture_system.py \
  --game /absolute/patched-game --player /absolute/daycare-player \
  --output /absolute/unique-proof-dir --capture
```

The driver uses only a loopback sentinel, real native player/global WebSockets, raw HTTP journals and continuous
process/disk measurements. It preserves the published 15 turns, 900 ticks, 600 tokens, 18-second request deadline and
8-second pacing floor. Compile `tools/check_native_capture.nim` for independent reconstruction (`--check OUTPUT`) and a
bounded native partial component (`--mixed CONFIG`, driven by the Python harness's `--mixed-component`). The partial
component is not a completed strategic game. Fixture runs establish capture behavior, not teacher quality, authenticated
admission or learning.
