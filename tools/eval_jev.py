"""Run matched native Daycare episodes with retained SystemOne call traces."""

import argparse
import json
import os
import secrets
import socket
import subprocess
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.request import urlopen
from uuid import uuid4

import httpx


ROOT = Path(__file__).resolve().parent.parent


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-binary", type=Path, required=True)
    parser.add_argument("--player-binary", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--seeds", type=int, nargs="+", default=[5, 7])
    parser.add_argument("--turns", type=int, default=6)
    parser.add_argument("--variant", choices=["daycare", "daycare-sparse",
        "daycare-fickle", "daycare-swapped"], default="daycare")
    parser.add_argument(
        "--arms",
        nargs="+",
        choices=["baseline", "jev", "haiku", "mixed"],
        default=["baseline", "jev", "haiku"],
    )
    args = parser.parse_args()
    if ("jev" in args.arms or "mixed" in args.arms) and not os.environ.get("TYPESAFE_API_KEY"):
        raise ValueError("TYPESAFE_API_KEY is required for Jev episodes")
    if ("haiku" in args.arms or "mixed" in args.arms) and not os.environ.get("ANTHROPIC_API_KEY"):
        raise ValueError("ANTHROPIC_API_KEY is required for Haiku episodes")
    args.output_dir = args.output_dir.resolve()
    args.output_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
    upstream = httpx.Client(timeout=45)
    try:
        for seed in args.seeds:
            for arm in args.arms:
                output = args.output_dir / f"seed-{seed}-{arm}"
                output.mkdir(mode=0o700)
                proxy = None
                proxy_thread = None
                capture_key = secrets.token_urlsafe(32)
                if arm in {"jev", "mixed"}:
                    trace_fd = os.open(
                        output / "systemone.jsonl",
                        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                        0o600,
                    )
                    trace_stream = os.fdopen(trace_fd, "w")
                    trace_lock = threading.Lock()

                    class Handler(BaseHTTPRequestHandler):
                        def do_POST(self):
                            if (
                                self.path != "/v1/systemone"
                                or self.headers.get("authorization")
                                != "Bearer " + capture_key
                            ):
                                self.send_error(401)
                                return
                            payload = json.loads(
                                self.rfile.read(int(self.headers["content-length"]))
                            )
                            trace_id = str(uuid4())
                            started = time.monotonic()
                            with trace_lock:
                                trace_stream.write(
                                    json.dumps(
                                        {
                                            "kind": "request",
                                            "version": 1,
                                            "trace_id": trace_id,
                                            "trajectory_id": f"daycare-{args.variant}-{seed}",
                                            "workload": "daycare",
                                            "schema_revision": "daycare.player.v2-external-action",
                                            "started_at": datetime.now(
                                                timezone.utc
                                            ).isoformat(),
                                            "request": payload,
                                        }
                                    )
                                    + "\n"
                                )
                                trace_stream.flush()
                                os.fsync(trace_stream.fileno())
                            finished = False
                            try:
                                response = upstream.post(
                                    "https://api.typesafe.ai/v1/systemone",
                                    headers={
                                        "Authorization": "Bearer "
                                        + os.environ["TYPESAFE_API_KEY"]
                                    },
                                    json=payload,
                                )
                                with trace_lock:
                                    trace_stream.write(
                                        json.dumps(
                                            {
                                                "kind": "response",
                                                "trace_id": trace_id,
                                                "status": response.status_code,
                                                "body": response.text,
                                                "latency_ms": (
                                                    time.monotonic() - started
                                                )
                                                * 1000,
                                            }
                                        )
                                        + "\n"
                                    )
                                    trace_stream.flush()
                                    os.fsync(trace_stream.fileno())
                                finished = True
                            finally:
                                if not finished:
                                    with trace_lock:
                                        trace_stream.write(
                                            json.dumps(
                                                {
                                                    "kind": "interrupted",
                                                    "trace_id": trace_id,
                                                }
                                            )
                                            + "\n"
                                        )
                                        trace_stream.flush()
                                        os.fsync(trace_stream.fileno())
                            self.send_response(response.status_code)
                            self.send_header(
                                "content-type",
                                response.headers.get(
                                    "content-type", "application/json"
                                ),
                            )
                            self.send_header(
                                "content-length", str(len(response.content))
                            )
                            self.end_headers()
                            self.wfile.write(response.content)

                        def log_message(self, *_args):
                            pass

                    proxy = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
                    proxy_thread = threading.Thread(
                        target=proxy.serve_forever, daemon=True
                    )
                    proxy_thread.start()
                with socket.socket() as free:
                    free.bind(("127.0.0.1", 0))
                    port = free.getsockname()[1]
                config = {
                    "players": [{"name": "Alder"}, {"name": "Bramble"}],
                    "tokens": ["local-token-0", "local-token-1"],
                    "seed": seed,
                    "turns": args.turns,
                    "slot0Role": "child" if args.variant == "daycare-swapped" else "parent",
                    "shrubs": 2 if args.variant == "daycare-sparse" else 4,
                    "childShrubPickPermille": 150 if args.variant == "daycare-sparse" else 250,
                    "preferenceSwitch": args.variant == "daycare-fickle",
                    "minTurnSeconds": 0,
                    "episodeTimeoutSeconds": 240,
                    "player_connect_timeout_seconds": 30,
                    "model": "claude-haiku-4-5-20251001",
                    "llmTimeoutSeconds": 30,
                }
                (output / "config.json").write_text(json.dumps(config))
                child_env = {
                    key: value
                    for key, value in os.environ.items()
                    if key
                    not in {
                        "TYPESAFE_API_KEY",
                        "ANTHROPIC_API_KEY",
                        "OPENROUTER_API_KEY",
                    }
                }
                game_env = {
                    **child_env,
                    "COGAME_HOST": "127.0.0.1",
                    "COGAME_PORT": str(port),
                    "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
                    "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
                    "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
                }
                if arm in {"haiku", "mixed"}:
                    game_env["ANTHROPIC_API_KEY"] = os.environ["ANTHROPIC_API_KEY"]
                game_log = (output / "game.log").open("w")
                game = subprocess.Popen(
                    [str(args.game_binary.resolve())],
                    cwd=ROOT,
                    env=game_env,
                    stdout=game_log,
                    stderr=subprocess.STDOUT,
                )
                players = []
                player_logs = []
                try:
                    for _ in range(100):
                        if game.poll() is not None:
                            raise RuntimeError(f"game exited early: {game.returncode}")
                        try:
                            with urlopen(f"http://127.0.0.1:{port}/healthz", timeout=1):
                                break
                        except OSError:
                            time.sleep(0.1)
                    else:
                        raise RuntimeError("game health timeout")
                    for seat in range(2):
                        player_env = {
                            **child_env,
                            "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token=local-token-{seat}",
                        }
                        player_env.update(
                            {"PLAYER_JEV": "1"}
                            if seat == 0 and arm in {"jev", "mixed"}
                            else {"PLAYER_PROMPT": "No additional guidance."}
                            if (seat == 0 and arm == "haiku") or
                                (seat == 1 and arm == "mixed")
                            else {"PLAYER_SCRIPTED": "caretaker"}
                        )
                        if seat == 0 and arm in {"jev", "mixed"}:
                            player_env.update(
                                {
                                    "METTA_CAPTURE_URL": f"http://127.0.0.1:{proxy.server_port}",
                                    "METTA_CAPTURE_KEY": capture_key,
                                    "METTA_CAPTURE_MODEL": "jev-latest",
                                }
                            )
                        log = (output / f"player-{seat}.log").open("w")
                        player_logs.append(log)
                        players.append(
                            subprocess.Popen(
                                [str(args.player_binary.resolve())],
                                cwd=ROOT,
                                env=player_env,
                                stdout=log,
                                stderr=subprocess.STDOUT,
                            )
                        )
                    if game.wait(timeout=240):
                        raise RuntimeError(f"game exit {game.returncode}")
                    for player in players:
                        if player.wait(timeout=10):
                            raise RuntimeError(f"player exit {player.returncode}")
                    results = json.loads((output / "results.json").read_text())
                    print(
                        seed,
                        arm,
                        "seat0",
                        results["scores"][0],
                        "turns",
                        results["turns"],
                        flush=True,
                    )
                finally:
                    if game.poll() is None:
                        game.terminate()
                        game.wait(timeout=5)
                    for player in players:
                        if player.poll() is None:
                            player.terminate()
                            player.wait(timeout=5)
                    for log in player_logs:
                        log.close()
                    game_log.close()
                    if proxy is not None:
                        proxy.shutdown()
                        proxy.server_close()
                        proxy_thread.join()
                        trace_stream.close()
    finally:
        upstream.close()


if __name__ == "__main__":
    main()
