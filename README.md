# hatz

Deterministic tick-based multi-agent simulation engine. Implements the **Hats Simulator** (Cohen & Morrison, WSC 2004): a 2D grid world where hats (agents) move, organizations plan taskforces with meeting trees, beacons are attack targets, and an Information Broker provides noisy/paid intelligence to a defender.

## Build

Requires Zig **0.16.0** (CI pins via `mlugg/setup-zig@v2`).

```sh
# compile
zig build

# run autonomous demo (full sim lifecycle + scoring report)
zig build run

# run tests (inline zig test blocks)
zig build test

# contract fixture replay
zig build replay

# replay + verify against expected outputs
zig build replay-check
```

Zig binary: `~/bin/zig` (local install at `~/.local/share/zig-0.16.0/`).

## Architecture

```
src/engine/
├── root.zig        — module entry, re-exports submodules
├── types.zig       — core types (HatId, Location, EventRecord, etc.)
├── protocol.zig    — envelope request/response types
├── router.zig      — dispatch by message type → handler
├── sim.zig         — lifecycle: initialize, advance, end + RunState
├── broker.zig      — 17 IB methods (10 free, 7 paid + noise model)
├── actions.zig     — analyst actions (alert_beacon, arrest_hat)
├── defaults.zig    — per-analyst default request scheduling
├── runs.zig        — in-memory run registry
├── population.zig  — seed-driven population generator (hats, orgs, beacons)
├── planner.zig     — generative meeting tree planner (taskforce creation)
├── meetings.zig    — meeting execution with capability trades
├── attack.zig      — beacon attack detection (4-condition rule)
├── json_util.zig   — JSON serialization helpers
└── main.zig        — autonomous demo harness
```

All state is deterministic from seed. Same seed + params + action sequence = identical output.

## Contract Protocol

The engine communicates via JSON envelopes (defined in `contracts/v1/`):

```json
// Request
{
  "contractVersion": "1.0.0",
  "type": "sim.initialize",
  "requestId": "req-01",
  "payload": { "seed": 12345, "params": {} }
}

// Response
{
  "contractVersion": "1.0.0",
  "ok": true,
  "requestId": "req-01",
  "payload": { "runId": "run-12345-1", "startedAtTick": 0 }
}
```

Message types:
- `sim.initialize` / `sim.advance` / `sim.end` — lifecycle
- `broker.call` — Information Broker query (17 methods)
- `action.alert_beacon` / `action.arrest_hat` — player actions
- `defaults.*` — default request scheduling

## Information Broker

**Free queries** (no cost, always succeed):
- `ib.world_dimensions`, `ib.beacons`, `ib.all_capabilities`
- `ib.benign_organizations`, `ib.terrorist_organizations` (partial)
- `ib.known_terrorist_hats` (partial)
- `ib.members`, `ib.hat_advertised_color`
- `ib.events_history`, `ib.clear_events_history`, `ib.arrested_hats`

**Paid queries** (cost + noise via P(correct) = 1 - e^(-λ·p)):
- `ib.last_location`, `ib.capabilities`
- `ib.meeting_times`, `ib.meeting_location`
- `ib.meeting_participants`, `ib.meeting_trades`

## Contract Fixtures

33 golden request/response pairs in `tools/contract/examples/`. Run `zig build replay-check` to verify the engine matches expected outputs.

## Scoring

Reported at `sim.end()`:
- **Information Cost** — total IB spend
- **False Arrests** — failed arrest attempts
- **Beacon Effectiveness** — hits vs false positives per beacon per alert level

## Interactive Play

The WebSocket daemon exposes the full engine API over a persistent connection.

```sh
# build
zig build daemon

# run (defaults: 127.0.0.1:9876)
./zig-out/bin/hatz-daemon
./zig-out/bin/hatz-daemon --port 9877 --host 0.0.0.0

# Ctrl-C for clean shutdown (drains connections, frees RunStates)
```

Send JSON envelopes as text frames; per-tick event frames are pushed during `sim.advance` before the final response frame:

```sh
# example with websocat
websocat ws://127.0.0.1:9876
{"contractVersion":"1.0.0","type":"sim.initialize","requestId":"r1","payload":{"seed":42,"params":{}}}
```

Go Charm TUI client: in development.
