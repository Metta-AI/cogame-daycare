# Daycare training

Daycare has a local simulator and hosted text players. Export complete games
for Metta post-training with the same per-seat prompts and reply parser as the
hosted player:

```bash
nimby sync nimby.lock
nim r --path:src tools/export_posttrain.nim /tmp/daycare 10 1 daycare
nim r --path:src tools/export_posttrain.nim /tmp/daycare-sparse 10 1 daycare-sparse
nim r --path:src tools/export_posttrain.nim /tmp/daycare-fickle 10 1 daycare-fickle
nim r --path:src tools/export_posttrain.nim /tmp/daycare-swapped 10 1 daycare-swapped
```

The exporter reads each certified `game_config` from
`coworld_manifest_template.json`, runs ten seeded games per variant, and writes
`train.jsonl`, `validation.jsonl`, and `manifest.json`. Seeds divisible by five
go to validation, keeping each game entirely in one split. The published
caretaker and stubborn scripts provide teacher replies. Each reply passes
through the hosted parser and native simulator. The exporter refuses an
existing output directory.

Train the text policy with Metta's post-training CLI:

```bash
uv run python -m metta_posttrain.train --dataset /tmp/daycare \
  --output /tmp/daycare-model --model Qwen/Qwen2.5-0.5B-Instruct \
  --max-steps 100 --max-length 4096
```

The dataset is imitation of scripted play; its loss does not measure policy
quality.

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
