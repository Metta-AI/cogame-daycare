# Daycare prompt diversity and training

Set `promptVariant` to `canonical`, `plain`, `numbered`, `questions`, or
`reordered`. `mixed` selects one of these five using explicit nonnegative
`promptSeed % 5`. Selection stays fixed across both roles, turns, and retries,
and does not consume simulation randomness. `heldout-briefing` and
`heldout-reference` are evaluation-only. The canonical prompt retains its
original bytes. Alternatives vary identity, simultaneous communication rules,
and role-specific knowledge. Game facts, job definitions, and strategic hints
retain their meaning.

The private provenance bank is `daycare-rules-v2`. It records exact system/user
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

## Teacher exports

```bash
nim c -d:release --path:src -o:/tmp/daycare-export tools/export_posttrain.nim
/tmp/daycare-export /tmp/daycare-examples 10 1 daycare mixed 0
```

Run from a clean, committed checkout. The original `train.jsonl`,
`validation.jsonl`, and `manifest.json` format is preserved.
Mixed selection cycles once per game through the five training wordings.
Seed families exclude yard variant and wording; multiples of five enter
validation. Held-out wordings and existing output paths are rejected.
Output directories are private.

The teacher remains caretaker in seat zero and stubborn in seat one, including
swapped roles. Both orders are parsed and validated before either is installed.
Each export covers all 15 turns and 900 ticks. Wording metadata records the
selected variant and rendered message hashes.

```bash
python3 tools/test_export_posttrain.py /tmp/daycare-export
python3 tools/test_prompt_games.py /tmp/daycare-train-bridge
```

Complete-game checks cover all four variants, private role information,
independent parent guesses, note persistence, and normalized orders.
They check mechanics and protocol behavior, not improved learning or resistance
to policy collapse. Model comparisons require separate matched evaluations.

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
