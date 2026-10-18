"""Published Daycare episodes with real players and a closed inference endpoint."""

import argparse
import hashlib
import json
import os
import socket
import subprocess
import time
from pathlib import Path


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("game", type=Path)
    parser.add_argument("player", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    manifest = json.loads((root / "coworld_manifest_template.json").read_text())
    variants = {entry["id"]: entry["game_config"] for entry in manifest["variants"]}
    cases = [(name, "canonical") for name in variants]
    cases += [
        ("daycare", wording)
        for wording in ("plain", "numbered", "questions", "reordered", "heldout-briefing", "heldout-reference", "mixed")
    ]
    if args.smoke:
        cases = [("daycare", "canonical"), ("daycare-swapped", "canonical")]
    args.output.mkdir(parents=True, exist_ok=False, mode=0o700)
    for variant, wording in cases:
        work = args.output / f"{variant}-{wording}"
        work.mkdir(mode=0o700)
        config = dict(variants[variant])
        seats = config["num_agents"]
        config.update(
            seed=7,
            promptVariant=wording,
            promptSeed=4,
            tokens=[f"t{seat}" for seat in range(seats)],
            players=[{"name": f"policy-{seat}"} for seat in range(seats)],
        )
        (work / "config.json").write_text(json.dumps(config))
        port, closed_port = free_port(), free_port()
        env = os.environ.copy()
        for key in (
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_API_KEY_URI",
            "AWS_BEARER_TOKEN_BEDROCK",
            "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
            "PLAYER_SCRIPTED",
        ):
            env.pop(key, None)
        env.update(
            COGAME_HOST="127.0.0.1",
            COGAME_PORT=str(port),
            COGAME_CONFIG_URI=(work / "config.json").as_uri(),
            COGAME_RESULTS_URI=(work / "results.json").as_uri(),
            COGAME_SAVE_REPLAY_URI=(work / "episode.replay").as_uri(),
            COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{closed_port}",
            DAYCARE_HOST_TRACE_PATH=str(work / "host.jsonl"),
            DAYCARE_ATTEMPT_TRACE_DIR=str(work / "attempts"),
            DAYCARE_SOURCE_REVISION="uncommitted-daycare-validation",
        )
        processes, logs = [], []
        try:
            log = (work / "game.log").open("w")
            logs.append(log)
            game = subprocess.Popen([str(args.game)], cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
            processes.append(game)
            for _ in range(200):
                assert game.poll() is None, work
                with socket.socket() as probe:
                    ready = probe.connect_ex(("127.0.0.1", port)) == 0
                if ready:
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError(f"host did not start: {work}")
            for seat in range(seats):
                player_env = dict(
                    env,
                    COWORLD_PLAYER_WS_URL=f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
                    PLAYER_PROMPT=(
                        f"PRIVATE-STRATEGY-{seat}: Cooperate using only the information available to your role."
                    ),
                )
                log = (work / f"player-{seat}.log").open("w")
                logs.append(log)
                processes.append(
                    subprocess.Popen([str(args.player)], cwd=root, env=player_env, stdout=log, stderr=subprocess.STDOUT)
                )
            assert game.wait(timeout=manifest["episode_timeout_minutes"] * 60 + 30) == 0
            for player in processes[1:]:
                assert player.wait(timeout=15) == 0
            results = json.loads((work / "results.json").read_text())
            assert results["reason"] == "complete" and results["ending"] == "turn_limit", results
            assert results["turns"] == 15 and results["scores"][0] == results["scores"][1]
            assert results["roles"][0] == ("child" if variant == "daycare-swapped" else "parent")
            with (work / "host.jsonl").open() as stream:
                records = [json.loads(line) for line in stream]
            assert records[0]["event_type"] == "host_started"
            assert records[-1]["event_type"] == "host_finished" and records[-1]["results"] == results
            decisions = [row for row in records if row["event_type"] == "host_decision"]
            turns = [row for row in records if row["event_type"] == "host_turn"]
            assert len(decisions) == 30 and len(turns) == 15
            starts, finishes = {}, {}
            for path in (work / "attempts").glob("*.jsonl"):
                assert path.stat().st_mode & 0o777 == 0o600
                start, finish = [json.loads(line) for line in path.read_text().splitlines()]
                assert start["attempt_id"] == finish["attempt_id"]
                starts[start["attempt_id"]] = start
                finishes[finish["attempt_id"]] = finish
            assert len(starts) == 60 and set(starts) == set(finishes)
            assert {identity for row in decisions for identity in row["attempt_ids"]} == set(finishes)
            for index, row in enumerate(decisions):
                assert row["turn"] == index // 2 + 1 and row["seat"] == index % 2
                assert row["tick"] == index // 2 * 60
                assert row["source"] == "fallback" and row["policy_origin"] == "scripted-fallback"
                assert row["selected_attempt_id"] is None and len(row["attempt_ids"]) == 2
                assert row["proposal"] == row["executed_action"]
                other = "child" if row["role"] == "parent" else "parent"
                assert not ({"preference", "guess", "hunch", "notes", "lastOrder"} & set(row["observation"][other]))
                if row["role"] == "parent":
                    assert "preference" not in row["observation"]["you"]
                for identity in row["attempt_ids"]:
                    start, finish = starts[identity], finishes[identity]
                    assert finish["failure"] and not finish["selected"]
                    assert finish["parsed_action"] is None and finish["normalized_action"] is None
                    assert finish["platform_call_id"] is None and finish["behavior_logprobs"] is None
                    system, user = (message["content"] for message in start["prompt"])
                    assert system == row["prompt"][0]["content"] and user.startswith(row["prompt"][1]["content"])
                    assert f"PRIVATE-STRATEGY-{row['seat']}" in user
                    assert f"PRIVATE-STRATEGY-{1 - row['seat']}" not in user
                    body = start["request"]["body"]
                    assert body["system"] == system and body["messages"] == start["prompt"][1:]
                    assert start["request"]["model"] == body["model"]
                    metadata = start["prompt_template"]
                    assert metadata["variant"] == ("reordered" if wording == "mixed" else wording)
                    for role, text in (("system", system), ("user", user)):
                        assert metadata[f"{role}_sha256"].lower() == hashlib.sha256(text.encode()).hexdigest()
            replay = json.loads((work / "episode.replay").read_text())
            assert replay["results"] == results and len(replay["frames"]) == 900
            for index, turn in enumerate(turns):
                assert turn["turn"] == index + 1 and turn["start_tick"] == index * 60
                assert turn["end_tick"] == (index + 1) * 60
                assert turn["frames"] == replay["frames"][index * 60 : (index + 1) * 60]
                assert len(turn["kernel_actions"]) == 60
                for pair in turn["kernel_actions"]:
                    assert len(pair) == 2 and all(
                        action in {"move_n", "move_s", "move_e", "move_w", "pick", "drop", "eat", "wait"}
                        for action in pair
                    )
            orders = [event for event in replay["events"] if event["k"] == "order"]
            assert len(orders) == len(decisions)
            for event, row in zip(orders, decisions, strict=True):
                action = row["executed_action"]
                assert event["seat"] == row["seat"] and event["turn"] == row["turn"]
                assert event["job"] == action["job"] and event["source"] == row["source"]
                for field in ("hunch", "notes"):
                    assert event[field] == action[field]
                assert event["f"] == (action["fruit"] or "") and event["guess"] == (action["guess"] or "")
            public = (work / "episode.replay").read_text()
            assert "PRIVATE-STRATEGY-" not in public and "prompt_template" not in public
            assert (work / "host.jsonl").stat().st_mode & 0o777 == 0o600
            print(work.name, "900 ticks; 60 actual attempts; 30 fallback orders; two real players PASS", flush=True)
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
            for log in logs:
                log.close()


if __name__ == "__main__":
    main()
