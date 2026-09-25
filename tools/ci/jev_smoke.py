"""Exercise both Daycare Jev roles beside a scripted player in Docker."""

import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time


class SystemOne(http.server.BaseHTTPRequestHandler):
    calls = []

    def do_POST(self):
        assert self.path == "/v1/systemone"
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        observation = json.loads(
            body["state"].split("seat observation:\n", 1)[1].split(
                "\nStrategy guidance:", 1
            )[0]
        )
        role = observation["role"]
        selected = (
            "provide_apple_guess_apple" if role == "parent" else "seek_apple"
        )
        choices = body["questions"]["order"]["criteria"]
        assert selected in choices
        self.calls.append((dict(self.headers), body["model"], observation))
        payload = json.dumps(
            {
                "model": body["model"],
                "answers": {
                    "order": {
                        "type": "choice",
                        "probabilities": {
                            name: float(name == selected) for name in choices
                        },
                    }
                },
                "usage": {"input_tokens": 100, "output_tokens": 1},
            }
        ).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args):
        pass


def docker(*args):
    return subprocess.run(
        ["docker", *args], check=True, capture_output=True, text=True, timeout=90
    ).stdout.strip()


def episode(image, server, role):
    prefix = f"daycare-jev-{os.getpid()}-{role}"
    network = f"{prefix}-net"
    containers = [f"{prefix}-game", f"{prefix}-p0", f"{prefix}-p1"]
    with tempfile.TemporaryDirectory(prefix=f"{prefix}-") as directory:
        work = Path(directory)
        os.chmod(work, 0o777)
        (work / "config.json").write_text(
            json.dumps(
                {
                    "seed": 7,
                    "num_agents": 2,
                    "players": [{"name": "Alder"}, {"name": "Bramble"}],
                    "tokens": ["token-0", "token-1"],
                    "slot0Role": role,
                    "turns": 3,
                    "ticksPerTurn": 12,
                    "minTurnSeconds": 0,
                    "llmTimeoutSeconds": 5,
                    "playerConnectTimeoutSeconds": 10,
                    "episodeTimeoutSeconds": 120,
                    "shutdownGraceSeconds": 0,
                }
            )
        )
        docker("network", "create", network)
        passed = False
        try:
            docker(
                "run", "-d", "--name", containers[0], "--network", network,
                "--network-alias", "daycare-game", "-e", "COGAME_HOST=0.0.0.0",
                "-e", "COGAME_PORT=8080",
                "-e", "COGAME_CONFIG_URI=file:///coworld/config.json",
                "-e", "COGAME_RESULTS_URI=file:///coworld/results.json",
                "-e", "COGAME_SAVE_REPLAY_URI=file:///coworld/replay.json",
                "-v", f"{work}:/coworld:rw", image, "/bin/daycare",
            )
            time.sleep(1)
            for slot in range(2):
                args = [
                    "run", "-d", "--name", containers[slot + 1],
                    "--network", network,
                    "--add-host", "host.docker.internal:host-gateway",
                    "-e", f"COWORLD_PLAYER_WS_URL=ws://daycare-game:8080/"
                    f"player?slot={slot}&token=token-{slot}",
                ]
                if slot == 0:
                    args += [
                        "-e", "PLAYER_JEV=1", "-e",
                        "AWS_ENDPOINT_URL_BEDROCK_RUNTIME="
                        f"http://host.docker.internal:{server.server_port}",
                    ]
                else:
                    args += ["-e", "PLAYER_SCRIPTED=caretaker"]
                docker(*args, image, "/bin/daycare-player")
            assert docker("wait", containers[0]) == "0"
            for container in containers[1:]:
                assert docker("wait", container) == "0"
            results = json.loads((work / "results.json").read_text())
            replay = json.loads((work / "replay.json").read_text())
            orders = [event for event in replay["events"] if event["k"] == "order"]
            jev_orders = [event for event in orders if event["seat"] == 0]
            scripted = [event for event in orders if event["seat"] == 1]
            calls = [call for call in SystemOne.calls if call[2]["role"] == role]
            assert results["reason"] == "complete"
            assert results["turns"] == 3
            assert len(calls) == len(jev_orders) == len(scripted) == 3
            assert all(event["source"] == "external" for event in jev_orders)
            assert all(event["source"] == "scripted" for event in scripted)
            assert all(event["job"] == ("provide" if role == "parent" else "seek")
                       for event in jev_orders)
            for headers, model, observation in calls:
                assert headers["x-coworld-player-slot"] == "0"
                assert "authorization" not in headers
                assert model == "typesafe/jev-1.13"
                assert observation["slot"] == 0
                assert observation["role"] == role
                if role == "parent":
                    assert "preference" not in observation["you"]
                    assert "preference" not in observation["child"]
                else:
                    assert observation["you"]["preference"] in ("apple", "banana")
                    assert "guess" not in observation["parent"]
            print(f"Daycare {role}: 3 accepted Jev orders, 3 scripted orders")
            passed = True
        finally:
            if not passed:
                for container in containers:
                    logs = subprocess.run(
                        ["docker", "logs", container], capture_output=True, text=True
                    )
                    print(logs.stdout, logs.stderr, file=sys.stderr)
            for container in containers:
                subprocess.run(["docker", "rm", "-f", container], capture_output=True)
            subprocess.run(["docker", "network", "rm", network], capture_output=True)


if __name__ == "__main__":
    model = http.server.HTTPServer(("0.0.0.0", 0), SystemOne)
    worker = threading.Thread(target=model.serve_forever, daemon=True)
    worker.start()
    try:
        for role in ("parent", "child"):
            episode(sys.argv[1], model, role)
    finally:
        model.shutdown()
        worker.join()
