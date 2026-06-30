#!/usr/bin/env python3
"""hatz-cli — WebSocket client for the hatz simulation engine.

Usage:
    python hatz-cli/cli.py --selftest
    python hatz-cli/cli.py [<addr>]
"""

import argparse
import atexit
import json
import os
import readline  # noqa: F401 — enables input() history; imported for side effect
import sys
import threading
import uuid
from queue import Empty, Queue

from websocket import WebSocket, WebSocketConnectionClosedException, WebSocketTimeoutException  # 1.9.0

CONTRACT_VERSION = "1.0.0"


def envelope(msg_type, payload, request_id=None):
    """Build an envelope dict for a request.

    Matches contracts/v1/protocol.schema.json#EnvelopeRequest.
    contractVersion is pinned to "1.0.0".
    """
    if request_id is None:
        request_id = f"req-{uuid.uuid4().hex[:12]}"
    return {
        "contractVersion": CONTRACT_VERSION,
        "type": msg_type,
        "payload": payload,
        "requestId": request_id,
    }


def parse_response(text):
    """Parse a JSON response envelope.

    Returns (requestId, ok, payload, error) — matches the
    EnvelopeResponse shape from the protocol schema.
    """
    data = json.loads(text)
    return (
        data.get("requestId"),
        data.get("ok", False),
        data.get("payload"),
        data.get("error"),
    )


class WsClient:
    """Thin wrapper around websocket.WebSocket with threaded recv.

    - connect() initiates the WS handshake and starts a daemon thread
      that reads frames into an internal queue.Queue.
    - send(text) writes a text frame.
    - recv() pops the next received frame from the queue (blocks up to
      self.timeout seconds).
    - close() stops the recv thread and closes the underlying socket.
    """

    def __init__(self, url, timeout=5):
        self.url = url
        self.timeout = timeout
        self._ws: WebSocket | None = None
        self._recv_queue: Queue = Queue()
        self._recv_thread: threading.Thread | None = None
        self._running = threading.Event()
        # ponytail: event frames that recv_response() skipped while searching
        # for the matching response frame. drain_events() merges these with
        # any newly-arrived events from the recv queue.
        self._event_buffer: list[dict] = []

    def connect(self):
        self._ws = WebSocket()
        self._ws.connect(self.url, timeout=self.timeout)
        # ponytail: shorten recv timeout so _recv_loop checks _running promptly
        self._ws.settimeout(1)
        self._running.set()
        self._recv_thread = threading.Thread(target=self._recv_loop, daemon=True)
        self._recv_thread.start()

    def _recv_loop(self):
        while self._running.is_set():
            try:
                data = self._ws.recv()
                if data:
                    self._recv_queue.put(data)
            except WebSocketConnectionClosedException:
                break
            except WebSocketTimeoutException:
                continue  # ponytail: socket.timeout after idle — loop back
            except Exception:
                break

    def send(self, text):
        """Send a text frame (accepts str)."""
        self._ws.send(text)

    def recv(self, timeout=None):
        """Return next received message, or None on timeout."""
        try:
            return self._recv_queue.get(timeout=timeout or self.timeout)
        except Empty:
            return None

    def close(self):
        self._running.clear()
        if self._ws:
            self._ws.close()

    # -- convenience helpers for the selftest / repl ---------------

    def send_envelope(self, msg_type, payload, request_id=None):
        """Serialize and send an envelope request."""
        env = envelope(msg_type, payload, request_id)
        self.send(json.dumps(env))
        return env

    def recv_response(self, timeout=None):
        """Read until we get a proper response envelope (skipping event push frames).

        Returns the parsed dict or None on timeout.

        NOTE: event push frames encountered while searching for the response
        are buffered in _event_buffer and surfaced via drain_events(). Without
        this buffer, recv_response would consume them silently since the recv
        queue is drained frame by frame.
        """
        while True:
            raw = self.recv(timeout=timeout)
            if raw is None:
                return None
            try:
                data = json.loads(raw)
            except json.JSONDecodeError:
                continue
            # Skip event push frames ({"type":"event","payload":{...}})
            # but save them so drain_events can still find them.
            if "ok" not in data:
                self._event_buffer.append(data)
                continue
            return data

    def drain_events(self):
        """Return all pending event push frames (non-response) from the recv queue.

        These are out-of-band frames the daemon pushes asynchronously
        (e.g. {"type":"event","payload":{...}}).

        Merges any event frames that recv_response() buffered while searching
        for the matching response frame, together with newly-arrived frames
        from the recv thread.
        Safe to call between commands to keep the queue clear.
        """
        frames = list(self._event_buffer)
        self._event_buffer.clear()
        while True:
            try:
                raw = self._recv_queue.get_nowait()
            except Empty:
                break
            try:
                data = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if "ok" not in data:
                frames.append(data)
        return frames


# ---------------------------------------------------------------------------
# Selftest
# ---------------------------------------------------------------------------

def run_selftest(host="127.0.0.1", port=9876):
    """Connect, init/advance/end, assert three ok:true responses.

    Writes one 'ok:true' line to stderr per successful step.
    Exits 0 on success, non-zero on failure.
    """
    url = f"ws://{host}:{port}/"

    client = WsClient(url)
    try:
        client.connect()
    except Exception as e:
        print(f"FAIL connect: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        # 1. sim.initialize
        client.send_envelope("sim.initialize", {"seed": 42, "params": {}})
        resp = client.recv_response()
        if resp is None or not resp.get("ok"):
            print(f"FAIL sim.initialize: {resp}", file=sys.stderr)
            sys.exit(1)
        run_id = resp["payload"]["runId"]
        print("ok:true sim.initialize", file=sys.stderr)

        # 2. sim.advance
        client.send_envelope("sim.advance", {"runId": run_id, "numberOfTicks": 1})
        resp = client.recv_response()
        if resp is None or not resp.get("ok"):
            print(f"FAIL sim.advance: {resp}", file=sys.stderr)
            sys.exit(1)
        print("ok:true sim.advance", file=sys.stderr)

        # 3. sim.end
        client.send_envelope("sim.end", {"runId": run_id})
        resp = client.recv_response()
        if resp is None or not resp.get("ok"):
            print(f"FAIL sim.end: {resp}", file=sys.stderr)
            sys.exit(1)
        print("ok:true sim.end", file=sys.stderr)

    finally:
        client.close()

    sys.exit(0)


# ---------------------------------------------------------------------------
# REPL
# ---------------------------------------------------------------------------

class Repl:
    """Interactive REPL for the hatz simulation daemon.

    Connects on init, presents a ``hatz> `` prompt, and dispatches commands
    to the daemon via the WS client.  Caches runId / tick in ``self.state``.
    Out-of-band event push frames are printed to stderr between prompts.
    """

    def __init__(self, host, port):
        self.client = WsClient(f"ws://{host}:{port}/")
        self.client.connect()
        self.state: dict = {"runId": None, "tick": None}
        self.analyst_id = "repl-analyst"
        self._running = True

    # -- dispatch table (populated in cmdloop so handlers reference self) --

    def _broker_call(self, method, args):
        """Send a broker.call request and return the parsed response envelope."""
        if not self.state["runId"]:
            print('{"ok":false,"error":"No active run. Use init first."}')
            return None
        self.client.send_envelope(
            "broker.call",
            {
                "runId": self.state["runId"],
                "analystId": self.analyst_id,
                "method": method,
                "args": args,
            },
        )
        return self.client.recv_response()

    def _pretty(self, payload):
        """Print indented JSON for array-containing payloads, compact otherwise."""
        if isinstance(payload, dict) and any(
            isinstance(v, list) for v in payload.values()
        ):
            print(json.dumps(payload, indent=2))
        else:
            print(json.dumps(payload))

    # -- command handlers (return True to continue, False to quit) ---------

    def do_init(self, args):
        if not args:
            print("Usage: init <seed>", file=sys.stderr)
            return True
        seed = int(args[0])
        self.client.send_envelope("sim.initialize", {"seed": seed, "params": {}})
        resp = self.client.recv_response()
        if resp and resp.get("ok"):
            self.state["runId"] = resp["payload"]["runId"]
            self.state["tick"] = resp["payload"]["startedAtTick"]
            print(json.dumps({"ok": True, "runId": self.state["runId"]}))
        else:
            err = (resp or {}).get("error", {"message": "no response"})
            print(json.dumps({"ok": False, "error": err.get("message")}))
        return True

    def do_advance(self, args):
        if not self.state["runId"]:
            print('{"ok":false,"error":"No active run. Use init first."}')
            return True
        n = int(args[0]) if args else 1
        self.client.send_envelope(
            "sim.advance",
            {"runId": self.state["runId"], "numberOfTicks": n},
        )
        resp = self.client.recv_response()
        if resp and resp.get("ok"):
            self.state["tick"] = resp["payload"]["toTick"]
            print(
                json.dumps(
                    {
                        "ok": True,
                        "runId": self.state["runId"],
                        "tick": self.state["tick"],
                    }
                )
            )
        else:
            err = (resp or {}).get("error", {"message": "no response"})
            print(json.dumps({"ok": False, "error": err.get("message")}))
        return True

    def do_end(self, args):
        if not self.state["runId"]:
            print('{"ok":false,"error":"No active run."}')
            return True
        self.client.send_envelope("sim.end", {"runId": self.state["runId"]})
        resp = self.client.recv_response()
        if resp and resp.get("ok"):
            self.state["tick"] = resp["payload"]["finalTick"]
            print(
                json.dumps(
                    {"ok": True, "finalTick": resp["payload"]["finalTick"]}
                )
            )
            self.state["runId"] = None
        else:
            err = (resp or {}).get("error", {"message": "no response"})
            print(json.dumps({"ok": False, "error": err.get("message")}))
        return True

    def do_beacons(self, args):
        resp = self._broker_call("ib.beacons", {})
        if resp and resp.get("ok"):
            self._pretty(resp["payload"])
        elif resp:
            self._pretty(
                {"ok": False, "error": resp.get("error", {}).get("message")}
            )
        return True

    def do_orgs(self, args):
        benign = self._broker_call("ib.benign_organizations", {})
        benign_ids = (
            benign["payload"].get("result", {}).get("organizationIds", [])
            if benign and benign.get("ok")
            else []
        )
        terrorist = self._broker_call("ib.terrorist_organizations", {})
        terrorist_ids = (
            terrorist["payload"].get("result", {}).get("organizationIds", [])
            if terrorist and terrorist.get("ok")
            else []
        )
        print(json.dumps({"benign": benign_ids, "terrorist": terrorist_ids}, indent=2))
        return True

    def do_members(self, args):
        if not args:
            print("Usage: members <org_id>", file=sys.stderr)
            return True
        resp = self._broker_call("ib.members", {"organizationId": int(args[0])})
        if resp and resp.get("ok"):
            self._pretty(resp["payload"])
        elif resp:
            self._pretty(
                {"ok": False, "error": resp.get("error", {}).get("message")}
            )
        return True

    @staticmethod
    def _payment(args, idx=1):
        return float(args[idx]) if len(args) > idx else 0

    def do_loc(self, args):
        if not args:
            print("Usage: loc <hat_id> [payment]", file=sys.stderr)
            return True
        resp = self._broker_call(
            "ib.last_location",
            {"hatId": int(args[0]), "payment": self._payment(args)},
        )
        if resp and resp.get("ok"):
            self._pretty(resp["payload"])
        elif resp:
            self._pretty(
                {"ok": False, "error": resp.get("error", {}).get("message")}
            )
        return True

    def do_cap(self, args):
        if not args:
            print("Usage: cap <hat_id> [payment]", file=sys.stderr)
            return True
        resp = self._broker_call(
            "ib.capabilities",
            {"hatId": int(args[0]), "payment": self._payment(args)},
        )
        if resp and resp.get("ok"):
            self._pretty(resp["payload"])
        elif resp:
            self._pretty(
                {"ok": False, "error": resp.get("error", {}).get("message")}
            )
        return True

    def do_alert(self, args):
        if len(args) < 2:
            print("Usage: alert <beacon_id> <OFF|LEVEL_ONE|LEVEL_TWO>", file=sys.stderr)
            return True
        beacon_id = int(args[0])
        level = args[1].upper()
        if level not in ("OFF", "LEVEL_ONE", "LEVEL_TWO"):
            print(
                '{"ok":false,"error":"Level must be OFF, LEVEL_ONE, or LEVEL_TWO"}'
            )
            return True
        if not self.state["runId"]:
            print('{"ok":false,"error":"No active run. Use init first."}')
            return True
        self.client.send_envelope(
            "action.alert_beacon",
            {
                "runId": self.state["runId"],
                "analystId": self.analyst_id,
                "beaconId": beacon_id,
                "alertLevel": level,
            },
        )
        resp = self.client.recv_response()
        if resp and resp.get("ok"):
            self._pretty(resp["payload"])
        elif resp:
            self._pretty(
                {"ok": False, "error": resp.get("error", {}).get("message")}
            )
        return True

    def do_arrest(self, args):
        if not args:
            print("Usage: arrest <hat_id> [x y]", file=sys.stderr)
            return True
        hat_id = int(args[0])
        x = int(args[1]) if len(args) > 1 else 0
        y = int(args[2]) if len(args) > 2 else 0
        if not self.state["runId"]:
            print('{"ok":false,"error":"No active run. Use init first."}')
            return True
        self.client.send_envelope(
            "action.arrest_hat",
            {
                "runId": self.state["runId"],
                "analystId": self.analyst_id,
                "hatId": hat_id,
                "location": {"x": x, "y": y},
            },
        )
        resp = self.client.recv_response()
        if resp and resp.get("ok"):
            self._pretty(resp["payload"])
        elif resp:
            self._pretty(
                {"ok": False, "error": resp.get("error", {}).get("message")}
            )
        return True

    def do_events(self, args):
        resp = self._broker_call("ib.events_history", {})
        if resp and resp.get("ok"):
            self._pretty(resp["payload"])
        elif resp:
            self._pretty(
                {"ok": False, "error": resp.get("error", {}).get("message")}
            )
        return True

    def do_state(self, args):
        print(json.dumps(self.state, indent=2))
        return True

    def do_help(self, args):
        print("Commands:")
        for name, (_, help_text) in self.dispatch.items():
            print(f"  {help_text}")
        return True

    def do_quit(self, args):
        self._running = False
        return False

    # -- event drain ------------------------------------------------

    def _drain_events(self):
        """Print pending event push frames to stderr before next prompt."""
        for frame in self.client.drain_events():
            print(f"[event] {json.dumps(frame)}", file=sys.stderr)

    # -- main loop ------------------------------------------------

    def cmdloop(self):
        histfile = os.path.expanduser("~/.hatz-cli_history")
        try:
            readline.read_history_file(histfile)
        except (FileNotFoundError, OSError):
            pass
        atexit.register(lambda: readline.write_history_file(histfile))

        self.dispatch = {
            "init": (self.do_init, "init <seed>  — Start new simulation run"),
            "advance": (
                self.do_advance,
                "advance [n]  — Advance sim by n ticks (default 1)",
            ),
            "end": (self.do_end, "end  — End current simulation run"),
            "beacons": (self.do_beacons, "beacons  — List all beacons"),
            "orgs": (self.do_orgs, "orgs  — List benign and terrorist orgs"),
            "members": (self.do_members, "members <org_id>  — List members of an org"),
            "loc": (
                self.do_loc,
                "loc <hat_id> [payment]  — Get last location of a hat",
            ),
            "cap": (
                self.do_cap,
                "cap <hat_id> [payment]  — Get capabilities of a hat",
            ),
            "alert": (
                self.do_alert,
                "alert <beacon_id> <OFF|LEVEL_ONE|LEVEL_TWO>  — Set beacon alert level",
            ),
            "arrest": (
                self.do_arrest,
                "arrest <hat_id> [x y]  — Arrest hat at location (default 0,0)",
            ),
            "events": (self.do_events, "events  — Show events history"),
            "state": (self.do_state, "state  — Show cached run state"),
            "help": (self.do_help, "help  — Show this help"),
            "quit": (self.do_quit, "quit  — Exit REPL"),
        }

        self._running = True
        while self._running:
            self._drain_events()
            try:
                line = input("hatz> ")
            except EOFError:
                print()
                break
            except KeyboardInterrupt:
                print()
                continue

            line = line.strip()
            if not line:
                continue

            parts = line.split()
            cmd = parts[0].lower()
            cmd_args = parts[1:]

            handler = self.dispatch.get(cmd)
            if handler:
                try:
                    handler[0](cmd_args)
                except ValueError as e:
                    print(json.dumps({"ok": False, "error": f"Bad argument: {e}"}))
                except Exception as e:
                    print(json.dumps({"ok": False, "error": str(e)}))
            else:
                print(
                    f"Unknown command: {cmd}. Type 'help' for available commands."
                )

        self.client.close()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_addr(addr):
    """Parse 'host:port' or 'host' (default port 9876)."""
    if ":" in addr:
        host, port_str = addr.rsplit(":", 1)
        return host or "127.0.0.1", int(port_str)
    return addr or "127.0.0.1", 9876


def main():
    parser = argparse.ArgumentParser(description="hatz simulation CLI client")
    parser.add_argument(
        "addr",
        nargs="?",
        default="127.0.0.1:9876",
        help="host:port of the hatz daemon (default 127.0.0.1:9876)",
    )
    parser.add_argument(
        "--selftest",
        action="store_true",
        help="Run self-test: connect, init, advance 1 tick, end, verify ok:true",
    )
    args = parser.parse_args()

    host, port = parse_addr(args.addr)

    if args.selftest:
        run_selftest(host, port)
        return  # unreachable

    repl = Repl(host, port)
    repl.cmdloop()


if __name__ == "__main__":
    main()
