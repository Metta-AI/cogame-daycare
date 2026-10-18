"""Complete every published Daycare variant with matched wordings and private roles."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BRIDGE = Path(sys.argv[1]).resolve()
ORIGINAL = Path(sys.argv[2]).resolve()
OUTPUT = Path(sys.argv[3]).resolve()
VARIANTS = ("daycare", "daycare-sparse", "daycare-fickle", "daycare-swapped")
WORDINGS = ("canonical", "plain", "numbered", "questions", "reordered", "heldout-briefing", "heldout-reference")


def play(variant, seed, wording, prompt_seed, normalize=False):
    with subprocess.Popen(
        [str(BRIDGE), str(ROOT / "coworld_manifest_template.json"), variant, "text"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    ) as process:
        assert process.stdin is not None and process.stdout is not None

        def request(value):
            process.stdin.write(json.dumps(value) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())

        observation = request(
            {
                "kind": "reset",
                "players": 2,
                "seed": seed,
                "promptVariant": wording,
                "promptSeed": prompt_seed,
                "split": "test" if wording.startswith("heldout-") else "train",
            }
        )
        trace, systems, roles = [], {}, {}
        conflicts = 0
        while observation["kind"] == "decision":
            seat = observation["seat"]
            assert seat == len(trace) % 2 and observation["decision_id"] == len(trace)
            view = observation["semantic_view"].copy()
            metadata = view.pop("prompt_template")
            role = view["role"]
            roles[seat] = role
            other = "child" if role == "parent" else "parent"
            assert not ({"guess", "hunch", "notes", "preference", "lastOrder"} & set(view[other]))
            if role == "parent":
                assert "preference" not in view["you"]
            messages = observation["messages"]
            expected = WORDINGS[prompt_seed] if wording == "mixed" else wording
            assert (metadata["bank"], metadata["variant"]) == ("daycare-rules-v1", expected)
            for message in messages:
                assert (
                    metadata[message["role"] + "_sha256"].lower()
                    == hashlib.sha256(message["content"].encode()).hexdigest()
                )
            assert systems.setdefault(seat, messages[0]["content"]) == messages[0]["content"]
            if role == "parent":
                assert "YOUR SECRET PREFERENCE:" not in messages[1]["content"]
            else:
                assert f"YOUR SECRET PREFERENCE: {view['you']['preference']}" in messages[1]["content"]
            proposal = json.loads(request({"kind": "teacher"})["response"])
            if normalize:
                own_marker = "雪" if seat == 0 else "森"
                other_marker = "森" if seat == 0 else "雪"
                assert other_marker not in json.dumps(view, ensure_ascii=False)
                assert all(other_marker not in message["content"] for message in messages)
                if view["turn"] > 1:
                    assert view["notes"] == own_marker * 239 + "…"
                    assert own_marker * 239 + "…" in messages[1]["content"]
                proposal["hunch"] = own_marker * 100
                proposal["notes"] = own_marker * 270
                proposal["job"] = proposal["job"].upper()
                if role == "parent" and proposal["fruit"] is not None:
                    proposal["guess"] = "banana" if proposal["fruit"] == "apple" else "apple"
                    conflicts += 1
            accepted = request(
                {"kind": "step", "decision_id": observation["decision_id"], "response": json.dumps(proposal)}
            )
            assert accepted["kind"] == "accepted"
            if normalize:
                assert accepted["action"]["hunch"] == own_marker * 79 + "…"
                assert accepted["action"]["notes"] == own_marker * 239 + "…"
                assert accepted["action"]["job"] == proposal["job"].lower()
                assert accepted["action"]["guess"] == proposal["guess"]
            else:
                assert accepted["action"] == proposal
            trace.append((view, messages, accepted["action"]))
            observation = accepted["observation"]
            assert len(trace) <= 30
        process.stdin.close()
        assert process.wait(timeout=30) == 0
        assert observation["kind"] == "terminal" and len(trace) == 30
        assert set(roles.values()) == {"parent", "child"}
        assert roles[0] == ("child" if variant == "daycare-swapped" else "parent")
        assert observation["scores"]["0"] == observation["scores"]["1"]
        assert observation["utilities"]["0"] == observation["utilities"]["1"]
        if normalize:
            assert conflicts > 0
        return trace, observation


for variant in VARIANTS:
    for heldout in WORDINGS[5:]:
        rejected = subprocess.run(
            [str(BRIDGE), str(ROOT / "coworld_manifest_template.json"), variant, "text"],
            input=json.dumps({"kind": "reset", "players": 2, "seed": "17", "promptVariant": heldout, "split": "train"})
            + "\n",
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert rejected.returncode != 0 and "evaluation-only" in rejected.stderr
    canonical_first = None
    for seed in ("17", "946001"):
        canonical = None
        introductions = set()
        selected_systems = {}
        for wording, prompt_seed in [*((name, 0) for name in WORDINGS), *(("mixed", index) for index in range(5))]:
            trace, outcome = play(variant, seed, wording, prompt_seed)
            selected = WORDINGS[prompt_seed] if wording == "mixed" else wording
            rendered = trace[0][1][0]["content"]
            assert selected_systems.setdefault(selected, rendered) == rendered
            introductions.add(rendered.split("\n", 1)[0])
            stripped = [
                (view, messages[0]["content"].split("\n", 1)[1], messages[1], action)
                for view, messages, action in trace
            ]
            if canonical is None:
                canonical = stripped, outcome
                if seed == "17":
                    canonical_first = trace, outcome
            else:
                assert (stripped, outcome) == canonical
        assert len(introductions) == 7
        print(variant, seed, "12 complete matched games PASS", flush=True)
    normalized, outcome = play(variant, "17", "canonical", 0, normalize=True)
    assert canonical_first is not None and outcome == canonical_first[1]
    hashed_seed = 2166136261
    for byte in b"17":
        hashed_seed = ((hashed_seed ^ byte) * 16777619) & 0xFFFFFFFF
    hashed_seed &= 0x7FFFFFFF
    baseline = OUTPUT / variant
    subprocess.run(
        [str(ORIGINAL), str(baseline), "10", str(hashed_seed), variant],
        cwd=ROOT.parent / "daycare-baseline",
        check=True,
        timeout=600,
    )
    rows = []
    for filename in ("train.jsonl", "validation.jsonl"):
        with (baseline / filename).open() as stream:
            for line in stream:
                row = json.loads(line)
                if row["episode_id"] == f"daycare-{variant}-{hashed_seed}":
                    rows.append(row)
    trace, _ = canonical_first
    assert len(rows) == len(trace)
    for row, (_, messages, action) in zip(rows, trace, strict=True):
        assert row["prompt"] == messages
        assert json.loads(row["completion"][0]["content"]) == action
    print(variant, "private notes, conflicting guesses, normalization and original source trajectory PASS", flush=True)
