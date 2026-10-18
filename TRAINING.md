# Daycare prompt diversity and training

Set `promptVariant` to `canonical`, `plain`, `numbered`, `questions`, or
`reordered`. `mixed` selects one of these five using explicit nonnegative
`promptSeed % 5`. Selection stays fixed across both roles, turns, and retries,
and does not consume simulation randomness. `heldout-briefing` and
`heldout-reference` are evaluation-only. The canonical prompt retains its
original bytes; all variants share the original rules and strategic hints.

The private provenance bank is `daycare-rules-v1`. It records exact system/user
hashes without placing provenance in model input or spectator replay. Role
observations remain unchanged: parents cannot see the child's preference,
orders, hunches, or notes; children cannot see the parent's guess or private text.

## Full-text collection

```bash
nim c -d:release --path:src -o:/tmp/daycare-train-bridge tools/train_bridge.nim
```

Use `[/tmp/daycare-train-bridge, /absolute/path/coworld_manifest_template.json,
daycare, text]` with the shared Metta text collector and `players=2`.
Reset accepts `promptVariant`, `promptSeed`, and `split`; training rejects both
held-out variants. All four published yard variants are supported.

The text path accepts full orders, including independent parent guesses,
spectator hunches, and private notes. It collects both seats' orders before
installing either, preserving simultaneous decisions. The hosted parser and
validator determine the normalized order returned to the collector.

## Private teacher candidates

```bash
nim c -d:release --path:src -o:/tmp/daycare-export tools/export_posttrain.nim
/tmp/daycare-export /tmp/daycare-candidates 10 1 daycare mixed 4
```

Run from a clean, committed checkout. `trajectories.jsonl` contains complete
candidate episodes under the shared Coworld decision/episode contract.
Candidates require independent review before training admission. Shared tooling
splits by scenario seed family, keeping every variant and wording of that seed
together. The exporter rejects held-out wording and existing output paths.

The teacher is the published caretaker in seat zero and stubborn policy in seat
one, including when roles swap. No provider request, call ID, or behavior log
probability is invented. `manifest.json` records source revision and results.
`execution.jsonl` joins each pair of decisions to the actual kernel actions
and state frames from all 60 ticks. Kernel actions are commands dispatched to
the simulator; they do not claim that a blocked move or failed pick succeeded.
All candidate artifacts are private files with mode 0600.

## Native evidence

Set `DAYCARE_HOST_TRACE_PATH`, `DAYCARE_ATTEMPT_TRACE_DIR`, and
`DAYCARE_SOURCE_REVISION` to retain private evidence. Attempts record exact
request bodies, model, retries, raw responses, failures, and normalized orders.
Both seats still share one request batch per attempt. Host records distinguish
scripted, external, fallback, and model decisions and retain per-turn kernel
commands and state frames. Skipped calls produce no fabricated attempts.

```bash
python3 tools/test_native_prompts.py /tmp/daycare /tmp/daycare-player /tmp/daycare-native
python3 tools/test_export_posttrain.py /tmp/daycare-export
```

The native workflow runs real host/player processes against a closed local
inference endpoint with unchanged manifest budgets. It checks all four variants
and seven additional wordings; `--smoke` covers canonical standard and swapped
roles. It joins private decisions to replay orders and all 900 state frames,
while checking role boundaries and strategy separation. The existing replay
remains a spectator artifact, including its secret and order history.

These checks establish matched trajectory parity and evidence integrity.
They do not demonstrate successful model inference, better learning, or
resistance to policy collapse. Evaluate frozen base/canonical/mixed checkpoints
on matched game seeds and opponents separately.

## Numeric training

For reinforcement learning, compile the persistent bridge and test all four
certified variants:

```bash
nim c -d:release --path:src -o:daycare-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py ./daycare-train-bridge
```

From Metta, use either `recipes.external.coworld.train` for native PufferLib or
`recipes.external.coworld_metta_rl.train` for Metta RL. Pass a command with the
absolute bridge and manifest paths, the variant ID, and `players=2`. Set a
training timestep limit. The bridge exposes 32 player-visible numeric values
and a fixed 12-choice catalog. It masks unused choices by role and uses the
published caretaker and stubborn baselines for opponents and teacher labels.

Daycare is cooperative: both seats receive the same score. The bridge supplies
an explicit terminal utility `2 * score / (score + par) - 1`, which is monotonic
in the shared score. This needs Metta #24683, stacked on #24679 and #24573.
