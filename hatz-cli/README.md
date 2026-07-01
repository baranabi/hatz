# hatz-cli

Python CLI client for the hatz simulation WebSocket daemon.

## Install

The only external dependency is `websocket-client` 1.9.0.

```bash
pip install websocket-client       # system Python
# or via uv (project root):
cd hatz-cli && uv sync
```

`websocket-client` 1.9.0 is already installed on this system — install is typically a no-op.

## Usage

```bash
# Connect to the daemon on the default address (127.0.0.1:9876)
./hatz-cli/cli.py

# Connect to a custom address
./hatz-cli/cli.py localhost:9876
./hatz-cli/cli.py 10.0.0.5:9876

# Run self-test (connect, sim.initialize, sim.advance 1 tick, sim.end)
./hatz-cli/cli.py --selftest

# Explicit python invocation (useful when the script isn't executable)
python3 hatz-cli/cli.py localhost:9876
```

When invoked without `--selftest` and with the daemon reachable, the CLI starts an interactive REPL.

## Command Reference

All commands are entered at the REPL prompt (`>`). Brackets `[]` denote optional arguments.

| Command | Description | Example |
|---|---|---|
| `init <seed>` | Initialize a new simulation run with the given random seed | `init 42` |
| `advance [n]` | Advance the simulation by `n` ticks (default 1) | `advance 5` |
| `end` | End the current simulation run | `end` |
| `beacons` | List all beacons (attack targets) on the map | `beacons` |
| `orgs` | List all benign and terrorist organizations | `orgs` |
| `members <org_id>` | List members of an organization | `members org_07f3` |
| `loc <hat_id> [payment]` | Query the last known location of a hat (agent). Optional payment improves accuracy | `loc hat_00a1 0.5` |
| `cap <hat_id> [payment]` | Query the capabilities of a hat (agent). Optional payment improves accuracy | `cap hat_00a1 0.5` |
| `alert <beacon_id> <level>` | Set an alert level for a beacon (action) | `alert beacon_01 high` |
| `arrest <hat_id>` | Arrest a hat (agent) | `arrest hat_00a1` |
| `events` | Fetch event history for the current run | `events` |
| `state` | Print cached run ID and current tick number | `state` |
| `help` | Show available commands | `help` |
| `quit` | Exit the REPL | `quit` |

### Notes

- **Payment**: The `loc` and `cap` commands accept an optional `payment` argument (a float). Higher payments increase the Information Broker's accuracy (P(correct) = 1 − e^(−λ·p)). The default payment is 0 (free, low accuracy).
- **Alert levels**: Depend on the simulation configuration. Common levels are `green`, `yellow`, `orange`, `red`.

## Troubleshooting

### "failed handshake"

The daemon is not running on the target address (default 127.0.0.1:9876). Start the daemon first:

```bash
zig build daemon -- --port 9876
```

The daemon's default port is 9876. Pass `--port` to change it and `--host` to bind a specific interface.

### `ok:false` in responses

An `ok:false` response means the daemon rejected the request. Check `response.error.code` for details:

```json
{"requestId": "req-abc123", "ok": false, "error": {"code": "RUN_NOT_FOUND", "message": "no active run"}}
```

Common error codes:

| Code | Meaning |
|---|---|
| `RUN_NOT_FOUND` | No active simulation run — call `init <seed>` first |
| `INVALID_PARAMS` | Missing or malformed arguments (wrong types, missing fields) |
| `UNKNOWN_COMMAND` | The `type` field doesn't match a known handler |
| `INTERNAL_ERROR` | Something went wrong in the engine — check daemon logs |

If the error code isn't documented here, check the daemon's stderr or log file for a stack trace.

## Development

```bash
# Add a dependency
uv add <pkg>

# Verify the venv works
uv run python -c "import websocket"

# Inspect dependency tree
uv tree
```

See `docs/` at the project root for the simulation and Information Broker specifications.
