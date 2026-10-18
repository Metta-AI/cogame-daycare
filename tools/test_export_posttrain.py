"""Complete published Daycare games and join simultaneous orders to tick execution."""

import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VARIANTS = ("daycare", "daycare-sparse", "daycare-fickle", "daycare-swapped")
ACTIONS = {"move_n", "move_s", "move_e", "move_w", "pick", "drop", "eat", "wait"}

if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    families: dict[str, set[str]] = {}
    with tempfile.TemporaryDirectory() as temp:
        for variant in VARIANTS:
            output = Path(temp) / variant
            subprocess.run([str(binary), str(output), "10", "1", variant], cwd=ROOT, check=True)
            manifest = json.loads((output / "manifest.json").read_text())
            assert len(manifest["runs"]) == 10
            for filename in ("trajectories.jsonl", "execution.jsonl", "manifest.json"):
                assert (output / filename).stat().st_mode & 0o777 == 0o600
            decisions = episodes = terminals = 0
            applied = {}
            with (output / "trajectories.jsonl").open() as stream, (output / "execution.jsonl").open() as execution:
                for line in stream:
                    row = json.loads(line)
                    assert row["game"] == "daycare" and row["source_revision"] == manifest["source_revision"]
                    if row["event_type"] == "episode":
                        run = manifest["runs"][episodes]
                        assert row["status"] == "completed" and decisions == run["decisions"] == 30
                        assert terminals == 1
                        result = row["outcome"]
                        assert result["reason"] == "complete" and result["ending"] == "turn_limit"
                        assert result["turns"] == 15 and applied["end_tick"] == 900
                        assert result["scores"] == run["scores"]
                        assert result["scores"][0] == result["scores"][1]
                        for seat in (0, 1):
                            assert row["participant_outcomes"][str(seat)]["score"] == result["scores"][seat]
                            assert applied["frames"][-1]["c"][seat * 4 + 3] == result["scores"][seat]
                        families.setdefault(row["seed_family"], set()).add(variant)
                        decisions = terminals = 0
                        episodes += 1
                        continue
                    assert row["event_type"] == "decision" and row["visibility"] == "private"
                    assert row["decision_index"] == decisions and terminals == 0
                    seat = decisions % 2
                    turn = decisions // 2 + 1
                    if seat == 0:
                        applied = json.loads(next(execution))
                        assert applied["source_revision"] == row["source_revision"]
                        assert applied["episode_id"] == row["episode_id"] and applied["turn"] == turn
                        assert applied["visibility"] == "private" and applied["terminal"] == (turn == 15)
                        assert applied["start_tick"] == (turn - 1) * 60 and applied["end_tick"] == turn * 60
                        assert len(applied["kernel_actions"]) == len(applied["frames"]) == 60
                        for offset, (controls, frame) in enumerate(
                            zip(applied["kernel_actions"], applied["frames"], strict=True)
                        ):
                            assert len(controls) == 2 and set(controls) <= ACTIONS
                            assert frame["t"] == (turn - 1) * 60 + offset and len(frame["c"]) == 8
                    assert applied["decision_ids"][seat] == row["decision_id"]
                    view = row["observation"]
                    assert view["tick"] == (turn - 1) * 60 and view["turn"] == turn
                    other = "child" if view["role"] == "parent" else "parent"
                    assert not ({"preference", "guess", "hunch", "notes", "lastOrder"} & set(view[other]))
                    if view["role"] == "parent":
                        assert "preference" not in view["you"]
                    decisions += 1
                    terminals += row["terminal"]
                    (attempt,) = row["attempts"]
                    assert attempt["origin"] == "teacher" and attempt["policy"] == "scripted-caretaker-and-stubborn"
                    assert attempt["request"] is None and attempt["platform_call_id"] is None
                    assert attempt["behavior_logprobs"] is None
                    assert json.loads(attempt["response"]) == attempt["parsed_action"]
                    metadata = view["prompt_template"]
                    for message in attempt["prompt"]:
                        assert (
                            metadata[message["role"] + "_sha256"].lower()
                            == hashlib.sha256(message["content"].encode()).hexdigest()
                        )
                    assert row["action_status"] == "accepted" and attempt["accepted"]
                    assert row["selected_attempt_id"] == attempt["attempt_id"]
                    assert row["executed_action"] == attempt["parsed_action"]
                assert execution.read() == ""
            assert episodes == 10 and decisions == 0
            print(variant, "10 complete private source games and 9000 kernel ticks PASS", flush=True)
    assert len(families) == 10 and all(variants == set(VARIANTS) for variants in families.values())
