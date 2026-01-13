# Contract Fixtures

Golden request/response fixtures for the v1 contract live in `tools/contract/examples/`.

Naming
- Requests: `NN_description.json` (zero-padded order).
- Responses: `tools/contract/examples/expected/NN_description.response.json`.

Replay order
- 00_initialize -> 01_defaults_add -> 02_advance_1 -> 03_broker_world_dimensions ->
- 04_broker_beacons -> 05_broker_last_location -> 06_action_alert_beacon ->
- 07_action_arrest_hat -> 08_advance_2 -> 09_end

Coverage
- sim.initialize with seed 12345 and empty params.
- defaults.add for analyst "human" with ib.beacons and ib.events_history.
- sim.advance for one tick with default results included (twice).
- broker.call for free methods (world_dimensions, beacons) and paid last_location.
- action.alert_beacon and action.arrest_hat (deterministic success location).
- sim.end to close the run.

Replay harness
- Run: `zig build replay`
- Check against expected: `zig build replay-check`
- CI helper: `tools/contract/validate.sh`
