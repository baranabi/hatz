# hatz

[![CI](https://github.com/baranabi/hatz/actions/workflows/contract-replay.yml/badge.svg)](https://github.com/baranabi/hatz/actions/workflows/contract-replay.yml)
[![codecov](https://codecov.io/gh/baranabi/hatz/branch/main/graph/badge.svg)](https://codecov.io/gh/baranabi/hatz)

Deterministic tick-based multi-agent simulation engine. Implements the **Hats Simulator** (Cohen & Morrison, WSC 2004): a 2D grid world where hats (agents) move, organizations plan taskforces with meeting trees, beacons are attack targets, and an Information Broker provides noisy/paid intelligence to a defender.

## Status

The engine is **fully implemented** — no stubs or synthetic stand-ins remain. All Information Broker methods read from real seeded population state; the planner generates runtime-created taskforces with capability-trade routing; meetings execute with capability transfers; attacks trigger on the 4-condition rule; scoring reports information cost, false arrests, and beacon effectiveness.

Verification:
- **68 unit tests** (`zig build test`) — engine, broker actions, paid query noise model, population generation, movement
- **33 contract fixtures** (`zig build replay-check`) — golden request/response pairs against the contracts/v1/ schemas
- **Autonomous demo** (`zig build run`) — full 120-tick lifecycle with scoring report

## Build

Requires Zig **0.16.0** (CI pins via `mlugg/setup-zig@v2`).

```sh
# compile
zig build

# run autonomous demo (full sim lifecycle + scoring report)
zig build run

# run tests (68 unit tests)
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
├── planner.zig     — generative meeting tree planner with capability-trade routing
├── meetings.zig    — meeting execution with capability trades
├── attack.zig      — beacon attack detection (4-condition rule)
├── json_util.zig   — JSON serialization helpers
└── main.zig        — autonomous demo harness
```

All state is deterministic from seed. Same seed + params + action sequence = identical output.

Key components:

- **planner.zig** — Generates meeting trees for runtime-created taskforces. For each required capability not already held by a taskforce member, finds an org member that holds the capability and schedules a trade at an intermediate or root meeting.
- **meetings.zig** — Executes meetings with full capability trades and participant location updates.
- **attack.zig** — Detects beacon attacks when a taskforce at a beacon's location holds capabilities covering the beacon's vulnerabilities.

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
- `ib.benign_organizations`, `ib.terrorist_organizations` (partial — not all terrorist orgs revealed, per spec)
- `ib.known_terrorist_hats` (partial — overt terrorists only; covert terrorists not included, per spec)
- `ib.members`, `ib.hat_advertised_color`
- `ib.events_history`, `ib.clear_events_history`, `ib.arrested_hats`

**Paid queries** (cost + noise via P(correct) = 1 - e^(-λ·p)):
- `ib.last_location`, `ib.capabilities`
- `ib.meeting_times`, `ib.meeting_location`
- `ib.meeting_participants`, `ib.meeting_trades`

## Contract Fixtures

33 golden request/response pairs in `tools/contract/examples/`. Run `zig build replay-check` to verify the engine matches expected outputs. All 33 pass.

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

### Python CLI

A full-featured Python REPL client is at `hatz-cli/` with 14 commands (init, advance, end, beacons, orgs, members, loc, cap, alert, arrest, events, state, help, quit). See [hatz-cli/README.md](hatz-cli/README.md).

```sh
./hatz-cli/cli.py
./hatz-cli/cli.py localhost:9876        # custom address
```

### Go TUI

A Go Bubbletea TUI client at `hatz-tui/` with an interactive command UI, auto-initialization on connect, event log, and brokered query interface. The client supports `/advance`, `/beacons`, `/loc`, `/caps`, `/color`, `/orgs`, `/members`, `/events`, `/arrest`, `/alert`, `/score`, `/setdefaults`, and `/help` commands.
