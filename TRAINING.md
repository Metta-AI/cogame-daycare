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
quality. Daycare's role-specific jobs and fruit choices could support a
factorized discrete RL codec, but the current Metta RL and PufferLib bridges
do not expose its action and observation.
