"""Exercise every certified Daycare variant through its JSONL training bridge."""

import json
import subprocess
import sys
from pathlib import Path


manifest = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
for variant in ("daycare", "daycare-sparse", "daycare-fickle", "daycare-swapped"):
    with subprocess.Popen(
        [sys.argv[1], str(manifest), variant],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    ) as bridge:
        assert bridge.stdin is not None and bridge.stdout is not None

        def request(payload):
            bridge.stdin.write(json.dumps(payload) + "\n")
            bridge.stdin.flush()
            return json.loads(bridge.stdout.readline())

        observation = request({"kind": "reset", "seed": "bridge-test", "players": 2})
        decisions = 0
        roles = {}
        while observation["kind"] == "decision":
            role = observation["semantic_view"]["role"]
            roles[observation["seat"]] = role
            if role == "parent":
                assert "preference" not in observation["semantic_view"]["you"]
            encoded = request({"kind": "encode"})
            assert encoded["decision_id"] == observation["decision_id"]
            assert len(encoded["values"]) == 32 and len(encoded["actions"]) == 12
            assert sum(action is not None for action in encoded["actions"]) == (12 if role == "parent" else 7)
            response = request({"kind": "teacher"})["response"]
            action = json.loads(response)
            assert action in encoded["actions"]
            result = request({"kind": "step", "decision_id": observation["decision_id"], "response": response})
            assert result["kind"] == "accepted" and result["action"] == action
            observation = result["observation"]
            decisions += 1
        assert decisions == 30 and set(roles.values()) == {"parent", "child"}
        assert observation["scores"]["0"] == observation["scores"]["1"]
        assert observation["utilities"]["0"] == observation["utilities"]["1"]
        assert -1 <= observation["utilities"]["0"] <= 1
        bridge.stdin.close()
        assert bridge.wait() == 0
    print(f"{variant}: {decisions} decisions")
