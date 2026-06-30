#!/usr/bin/env python3
"""Regression test for daemon TCP FD leak on WebSocket disconnect.

Reproduces the CLOSE_WAIT socket accumulation bug.
Acceptance: daemon handles 100+ sequential WS connections without hang.

Usage:
    python3 hatz-cli/test_fd_leak.py           # requires daemon running
    python3 hatz-cli/test_fd_leak.py --spawn   # spawns daemon automatically
"""
import json
import os
import subprocess
import sys
import time
import uuid
from websocket import WebSocket, WebSocketConnectionClosedException, WebSocketTimeoutException

PORT = 9876
URL = f"ws://127.0.0.1:{PORT}/"
CONTRACT = "1.0.0"
CONNECTIONS = 100


def run_sequence(idx: int) -> bool:
    """Connect, init, advance(1), end, disconnect — all synchronous."""
    try:
        ws = WebSocket()
        ws.connect(URL, timeout=3)
    except Exception as e:
        print(f"  [{idx:3d}] FAIL connect: {e}")
        return False

    ws.settimeout(1)

    def call(typ, payload):
        rid = f"req-{uuid.uuid4().hex[:12]}"
        env = {"contractVersion": CONTRACT, "type": typ, "payload": payload, "requestId": rid}
        ws.send(json.dumps(env))
        deadline = time.time() + 5
        while time.time() < deadline:
            try:
                raw = ws.recv()
            except WebSocketTimeoutException:
                continue
            except Exception:
                break
            if raw:
                try:
                    f = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if f.get("requestId") == rid:
                    return f
        return None

    try:
        # init
        r = call("sim.initialize", {"seed": idx + 1, "params": {}})
        if r is None or r.get("ok") is not True:
            print(f"  [{idx:3d}] FAIL init: {r}")
            return False
        run_id = r["payload"]["runId"]

        # advance 1
        r = call("sim.advance", {"runId": run_id, "numberOfTicks": 1})
        if r is None or r.get("ok") is not True:
            print(f"  [{idx:3d}] FAIL advance: {r}")
            return False

        # end
        r = call("sim.end", {"runId": run_id})
        if r is None or r.get("ok") is not True:
            print(f"  [{idx:3d}] FAIL end: {r}")
            return False

        print(f"  [{idx:3d}] OK", flush=True)
        return True
    finally:
        try:
            # Raw socket close to avoid WS close-handshake delay
            ws.sock.settimeout(0.01)
            ws.sock.close()
        except Exception:
            pass


def spawn_daemon():
    daemon_bin = os.path.join(os.path.dirname(__file__), "..", "zig-out", "bin", "hatz-daemon")
    daemon_bin = os.path.abspath(daemon_bin)
    if not os.path.exists(daemon_bin):
        print(f"  daemon binary not found — run 'zig build' first")
        return None
    proc = subprocess.Popen(
        [daemon_bin, "--port", str(PORT)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    for _ in range(20):
        try:
            ws = WebSocket()
            ws.connect(URL, timeout=2)
            ws.close()
            return proc
        except Exception:
            time.sleep(0.5)
    proc.kill()
    proc.wait()
    print("  daemon failed to start within 10s")
    return None


def main():
    spawn = "--spawn" in sys.argv
    daemon_proc = None

    if spawn:
        print(f"  Spawning daemon on 127.0.0.1:{PORT}...", flush=True)
        daemon_proc = spawn_daemon()
        if daemon_proc is None:
            return 1
    else:
        try:
            ws = WebSocket()
            ws.connect(URL, timeout=3)
            ws.close()
        except Exception:
            print(f"  No daemon on {URL}. Pass --spawn to auto-start.")
            return 1

    print(f"  Testing {CONNECTIONS} sequential WS connections...", flush=True)

    passed = 0
    failed = 0
    for idx in range(1, CONNECTIONS + 1):
        ok = run_sequence(idx)
        if ok:
            passed += 1
        else:
            failed += 1
            if failed >= 3:
                print(f"\n  3 failures — stopping early", flush=True)
                break

    total = passed + failed
    print(f"\n  {total} connections: {passed} passed, {failed} failed", flush=True)

    if daemon_proc:
        daemon_proc.terminate()
        daemon_proc.wait(timeout=5)

    return 0 if (failed == 0 and total >= CONNECTIONS) else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\n  interrupted")
        sys.exit(1)
    except Exception as e:
        print(f"\n  ERROR: {e}", file=sys.stderr)
        sys.exit(1)
