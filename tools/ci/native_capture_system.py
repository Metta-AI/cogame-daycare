"""Actual native Daycare HTTP/WS control; fixture completions are never teachers."""

import argparse
import base64
import hashlib
import http.server
import json
import os
import re
import shutil
import socket
import subprocess
import threading
import time
import urllib.request
import uuid
from pathlib import Path

from websockets.exceptions import ConnectionClosed
from websockets.sync.client import connect


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", type=Path, required=True)
    parser.add_argument("--player", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--capture", action="store_true")
    parser.add_argument("--mixed-component", action="store_true")
    parser.add_argument("--original-negative", action="store_true")
    parser.add_argument("--external-component", action="store_true")
    args = parser.parse_args()
    assert not (args.mixed_component and args.external_component)
    allowed = {"PATH", "HOME", "TMPDIR", "LANG", "LC_CTYPE", "__CF_USER_TEXT_ENCODING"}
    assert not (set(os.environ) - allowed), "Start the parent with env -i"
    output = args.output.resolve()
    assert not output.exists()
    output.mkdir(parents=True)
    os.umask(0o077)
    started = time.monotonic()
    logs, children, calls, viewer_rows = [], [], [], []
    done = threading.Event()
    base_env = {
        key: os.environ[key]
        for key in ("PATH", "HOME", "TMPDIR", "LANG")
        if key in os.environ
    }
    audit = []
    config = {
        "seed": 23,
        "turns": 15,
        "ticksPerTurn": 60,
        "minTurnSeconds": 8,
        "llmTimeoutSeconds": 18,
        "maxOutputTokens": 600,
        "episodeTimeoutSeconds": 1200,
        "playerConnectTimeoutSeconds": 120,
        "shutdownGraceSeconds": 20,
        "num_agents": 2,
        "players": [{"name": "fixture-parent"}, {"name": "fixture-child"}],
        "tokens": ["local-parent", "local-child"],
    }
    (output / "config.json").write_text(json.dumps(config))

    http_lock = threading.Lock()

    def save_http():
        with http_lock:
            (output / "http.json").write_text(json.dumps(calls, indent=2))

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            row = {
                "arrival_s": time.monotonic() - started,
                "path": self.path,
                "headers": list(self.headers.items()),
                "request_b64": base64.b64encode(raw).decode(),
            }
            calls.append(row)
            save_http()
            try:
                request = json.loads(raw.decode("utf-8", "surrogatepass"))
                slot = int(self.headers["X-Coworld-Player-Slot"])
                assert self.path == "/v1/messages" and slot in (0, 1)
                assert request["model"] == "local-daycare-sentinel"
                assert request["max_tokens"] == 600 and "temperature" not in request
                assert len(calls) <= 180
                action = {
                    "job": "provide" if slot == 0 else "show",
                    "fruit": "banana",
                    "hunch": "local plumbing only",
                    "notes": f"private-note-seat-{slot}",
                }
                if slot == 0:
                    action["guess"] = "banana"
                text = json.dumps(action, separators=(",", ":"))
                http_status, case = 200, "ordinary"
                if args.mixed_component:
                    user = request["messages"][0]["content"]
                    matched = re.match(r"TURN (\d+)", user)
                    assert matched is not None
                    turn = int(matched.group(1))
                    retry = "Your previous reply was invalid" in user
                    case = str(turn)
                    if turn == 1:
                        text = "```json\n" + text + "\n```"
                    elif turn == 2:
                        text = text.replace(action["job"], action["job"].upper())
                    elif turn == 3:
                        key = "job" if slot == 0 else r"\u006aob"
                        text = text[:-1] + ',"' + key + '":"' + action["job"] + '"}'
                    elif turn == 4:
                        action["notes"] = "\udc00"
                        text = json.dumps(action)
                    elif turn == 5:
                        action["notes"] = "cleared"
                        text = json.dumps(action)
                    elif turn == 6 and slot == 0 and not retry:
                        http_status = 429
                    elif turn == 7 and slot == 0 and not retry:
                        text = "{invalid"
                    elif turn == 8:
                        action["hunch"] = "h" * 81
                        text = json.dumps(action)
                    elif turn == 9:
                        text = text[:-1] + ',"ignored":1e999}'
                    elif turn == 10:
                        action.pop("hunch")
                        action.pop("notes")
                        text = json.dumps(action)
                body = json.dumps(
                    {
                        "id": "local-only",
                        "model": "local-daycare-sentinel",
                        "stop_reason": "end_turn",
                        "content": [{"type": "text", "text": text}],
                        "usage": {"input_tokens": 0, "output_tokens": 0},
                    }
                ).encode()
                call_id = str(uuid.uuid4())
                row.update(
                    slot=slot,
                    case=case,
                    http_status=http_status,
                    text=text,
                    intended_response_b64=base64.b64encode(body).decode(),
                    call_id=call_id,
                )
                save_http()
                self.send_response(http_status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("X-Softmax-Llm-Call-Id", call_id)
                self.end_headers()
                self.wfile.write(body)
                row["send_success_s"] = time.monotonic() - started
            except (AssertionError, ValueError, OSError, KeyError) as error:
                row["error"] = type(error).__name__
                raise
            finally:
                save_http()

        def log_message(self, format: str, *args: object) -> None:
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]

    def launch(argv, env, name):
        assert all(
            not any(
                word in key
                for word in ("ANTHROPIC", "BEDROCK", "AWS_", "OPENAI", "OPENROUTER")
            )
            for key in env
        )
        audit.append({"argv": argv, "environment_keys": sorted(env)})
        (output / "environment-audit.json").write_text(json.dumps(audit, indent=2))
        log = (output / (name + ".log")).open("wb")
        logs.append(log)
        child = subprocess.Popen(argv, env=env, stdout=log, stderr=subprocess.STDOUT)
        children.append(child)
        return child

    def metrics():
        with (output / "metrics.jsonl").open("w") as stream:
            while not done.is_set():
                row = {
                    "elapsed_s": time.monotonic() - started,
                    "free_bytes": shutil.disk_usage(output).free,
                    "output_bytes": sum(
                        path.stat().st_size
                        for path in output.rglob("*")
                        if path.is_file()
                    ),
                    "http_calls": len(calls),
                    "processes": [],
                }
                for child in children:
                    readback = subprocess.run(
                        ["ps", "-p", str(child.pid), "-o", "pid=,pcpu=,rss=,etime="],
                        env=base_env,
                        capture_output=True,
                        text=True,
                        timeout=2,
                        check=False,
                    )
                    row["processes"].append(
                        {
                            "pid": child.pid,
                            "returncode": child.poll(),
                            "ps": readback.stdout.strip() or None,
                        }
                    )
                stream.write(json.dumps(row) + "\n")
                stream.flush()
                if (
                    row["free_bytes"] < 2 * 1024**3
                    or row["output_bytes"]
                    > (8 if args.external_component else 32) * 1024**2
                    or row["elapsed_s"] > (22 if args.external_component else 180)
                ):
                    for child in children:
                        if child.poll() is None:
                            child.terminate()
                    return
                done.wait(0.5)

    monitor = threading.Thread(target=metrics, daemon=True)
    monitor.start()

    def viewer():
        try:
            with connect(f"ws://127.0.0.1:{port}/global", open_timeout=5) as ws:
                while not done.is_set():
                    try:
                        message = ws.recv(timeout=0.5)
                        raw = message.encode() if isinstance(message, str) else message
                        viewer_rows.append(
                            {
                                "elapsed_s": time.monotonic() - started,
                                "kind": "text"
                                if isinstance(message, str)
                                else "binary",
                                "body_b64": base64.b64encode(raw).decode(),
                            }
                        )
                    except TimeoutError:
                        ws.ping().wait(2)
                        viewer_rows.append(
                            {"elapsed_s": time.monotonic() - started, "pong": True}
                        )
        except (OSError, TimeoutError, ConnectionClosed) as error:
            viewer_rows.append({"error": type(error).__name__})
        finally:
            (output / "global-ws.json").write_text(json.dumps(viewer_rows))

    status = {
        "qualification": "Local synthetic transport only; authenticated teachers=0",
        "expected_http": 30,
    }
    view = None
    try:
        env = base_env | {
            "COGAME_HOST": "127.0.0.1",
            "COGAME_PORT": str(port),
            "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
            "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
            "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
            "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{server.server_port}",
            "COWORLD_LLM_MODEL": "local-daycare-sentinel",
            "COWORLD_EPISODE_ID": "local-daycare-native",
            "COWORLD_GAME_VERSION": "0.0.0",
            "COWORLD_SOURCE_REVISION": "local-qa",
            "COWORLD_GAME_NAME": "daycare",
            "COWORLD_GAME_IMAGE_DIGEST": "sha256:" + "0" * 64,
        }
        if args.capture or args.original_negative:
            env["COGAME_SAVE_TRAJECTORY_URI"] = (output / "trajectory.jsonl").as_uri()
        if args.external_component:
            # Actual external/scripted native paths require no model transport.
            env.pop("COWORLD_LLM_ENDPOINT")
            env.pop("COWORLD_LLM_MODEL")
        if args.mixed_component:
            game = launch(
                [str(args.game.resolve()), "--mixed", str(output / "config.json")],
                env,
                "component",
            )
            game.wait(timeout=30)
            assert game.returncode == 0
            assert (output / "trajectory.jsonl").is_file()
            status.update(
                status="PASS partial native component; not full episode",
                trajectory_present=True,
                http_calls=len(calls),
            )
            return
        game = launch([str(args.game.resolve())], env, "game")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                with urllib.request.urlopen(
                    f"http://127.0.0.1:{port}/healthz", timeout=1
                ) as response:
                    assert response.status == 200
                break
            except OSError:
                time.sleep(0.05)
        else:
            raise TimeoutError("native health did not start")
        view = threading.Thread(target=viewer, daemon=True)
        view.start()
        if args.external_component:
            # Preserve wire bytes before parsing or asserting anything about them.
            transcript = []
            work_deadline = started + 22

            def flush_wire():
                (output / "external-ws.json").write_text(
                    json.dumps(transcript, indent=2)
                )

            def persist_wire(direction, message):
                raw = message.encode() if isinstance(message, str) else message
                row = {
                    "direction": direction,
                    "elapsed_s": time.monotonic() - started,
                    "body_b64": base64.b64encode(raw).decode(),
                }
                transcript.append(row)
                flush_wire()
                return row

            try:
                with connect(
                    f"ws://127.0.0.1:{port}/player?slot=0&token={config['tokens'][0]}",
                    open_timeout=min(5, max(0.1, work_deadline - time.monotonic())),
                ) as ws:
                    registration = json.dumps(
                        {"type": "register", "control": "external"}
                    )
                    sent = persist_wire("send", registration)
                    ws.send(registration)
                    sent["send_success_s"] = time.monotonic() - started
                    flush_wire()
                    launch(
                        [str(args.player.resolve())],
                        base_env
                        | {
                            "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot=1&token={config['tokens'][1]}",
                            "PLAYER_SCRIPTED": "caretaker",
                        },
                        "player-1",
                    )
                    injected = False
                    while time.monotonic() < work_deadline:
                        try:
                            message = ws.recv(
                                timeout=max(
                                    0.1, min(2, work_deadline - time.monotonic())
                                )
                            )
                        except TimeoutError:
                            continue
                        persist_wire("receive", message)
                        if not isinstance(message, str):
                            continue
                        packet = json.loads(message)
                        if packet.get("type") != "observation":
                            continue
                        turn = packet["turn"]
                        if turn == 1 and not injected:
                            valid = {
                                "job": "provide",
                                "fruit": "banana",
                                "guess": "banana",
                                "notes": "KEEP",
                                "hunch": "é 😀",
                            }
                            # ASCII JSON transports decoded bad scalars through the real
                            # TextMessage parser. Invalid raw UTF-8 WS frames would instead
                            # test RFC6455; raw80 is covered by the native direct-apply probe.
                            orders = [
                                valid | {"notes": "\udc00"},
                                valid | {"hunch": "\ud800"},
                                valid,
                                valid | {"notes": "must-not-overwrite"},
                            ]
                            for order in orders:
                                action = json.dumps(
                                    {"type": "action", "turn": turn, "order": order}
                                )
                                sent = persist_wire("send", action)
                                ws.send(action)
                                sent["send_success_s"] = time.monotonic() - started
                                flush_wire()
                            injected = True
                        elif turn == 2:
                            state = packet["observation"]
                            # If invalid input set received/pending prematurely, the first
                            # valid same-turn order could not have been installed intact.
                            assert injected and state["notes"] == "KEEP"
                            assert state["you"]["lastOrder"]["source"] == "external"
                            assert len(calls) == 0
                            assert any(row.get("pong") for row in viewer_rows)
                            assert any("body_b64" in row for row in viewer_rows)
                            status.update(
                                status="PASS real external WS atomicity partial",
                                expected_http=0,
                                http_calls=0,
                                last_observed_turn=turn,
                                last_observed_tick=state["tick"],
                                qualification="Partial original native server; no completed episode or final artifact claim",
                            )
                            break
                    else:
                        raise TimeoutError("bounded external WS observation deadline")
                    (output / "external-ws.json").write_text(
                        json.dumps(transcript, indent=2)
                    )
            except (
                AssertionError,
                OSError,
                TimeoutError,
                ConnectionClosed,
                KeyError,
                ValueError,
            ) as error:
                status.update(
                    status="FAIL external WS partial; preserved",
                    error_type=type(error).__name__,
                )
                raise
            finally:
                flush_wire()
            return
        for slot, token in enumerate(config["tokens"]):
            launch(
                [str(args.player.resolve())],
                base_env
                | {
                    "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={slot}&token={token}"
                },
                f"player-{slot}",
            )
        game.wait(timeout=max(1, 175 - (time.monotonic() - started)))
        for child in children:
            child.wait(timeout=3)
            assert child.returncode == 0
        results = json.loads((output / "results.json").read_text())
        replay = json.loads((output / "replay.json").read_text())
        assert len(calls) == 30 and all("send_success_s" in call for call in calls)
        assert results["turns"] == 15
        status.update(
            status="PASS complete native fixture",
            results=results,
            replay_keys=list(replay),
            trajectory_present=(output / "trajectory.jsonl").exists(),
            http_calls=len(calls),
            source_game_sha256=hashlib.sha256(args.game.read_bytes()).hexdigest(),
        )
        if args.original_negative:
            assert not status["trajectory_present"]
            status["capture_gate"] = (
                "EXPECTED FAIL original missing requested private trajectory"
            )
        elif args.capture:
            assert status["trajectory_present"]
        else:
            assert not status["trajectory_present"]
    finally:
        done.set()
        server.shutdown()
        for child in children:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=2 if args.external_component else 3)
                except subprocess.TimeoutExpired:
                    if not args.external_component:
                        raise
                    child.kill()
                    child.wait(timeout=0.5)
        monitor.join(timeout=0.5 if args.external_component else 3)
        if args.external_component and view is not None:
            view.join(timeout=0.5)
            status["viewer_joined"] = not view.is_alive()
        for log in logs:
            log.close()
        status.update(
            elapsed_s=time.monotonic() - started,
            http_calls=len(calls),
            child_returns=[child.returncode for child in children],
        )
        (output / "result-card.json").write_text(json.dumps(status, indent=2))


if __name__ == "__main__":
    main()
