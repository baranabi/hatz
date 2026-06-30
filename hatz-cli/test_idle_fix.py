#!/usr/bin/env python3
"""hatz-cli: verification test for the recv_loop idle-timeout fix.

Tests that WsClient survives idle periods (simulating user thinking time)
and still sends/receives correctly.

Usage: python3 hatz-cli/test_idle_fix.py
Requires: hatz-daemon running on 127.0.0.1:9876
"""
import sys
import os
import time

# Add cli.py to path so we import the module-under-test
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cli import WsClient


def test_case(label, idle_seconds, timeout=3):
    """Connect, wait idle_seconds, send sim.initialize, expect ok:true."""
    client = WsClient("ws://127.0.0.1:9876/", timeout=5)
    client.connect()
    if idle_seconds:
        time.sleep(idle_seconds)
    client.send_envelope("sim.initialize", {"seed": 42, "params": {}})
    resp = client.recv_response(timeout=timeout)
    ok = resp is not None and resp.get("ok") is True
    rid = resp["payload"]["runId"] if ok else None
    client.close()
    status = "PASS" if ok else "FAIL"
    print(f"  {status}: idle={idle_seconds}s ok={ok} runId={rid}")
    return ok


def main():
    print("hatz-cli: recv_loop idle-timeout verification")
    print(f"  daemon: ws://127.0.0.1:9876/")
    print()

    cases = [
        ("immediate", 0),
        ("short idle (3s)", 3),
        ("long idle (7s — over old 5s limit)", 7),
        ("extended idle (15s)", 15),
    ]

    passed = 0
    failed = 0
    for label, idle in cases:
        print(f"  {label}...")
        if test_case(label, idle):
            passed += 1
        else:
            failed += 1

    total = passed + failed
    print(f"\n  {total} tests: {passed} passed, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        print(f"  ERROR: {e}", file=sys.stderr)
        sys.exit(1)
