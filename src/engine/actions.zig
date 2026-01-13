//! Analyst actions that mutate run state (stubbed).
const std = @import("std");
const types = @import("types.zig");
const sim = @import("sim.zig");

pub const ActionAlertBeaconRequestPayload = struct {
    runId: types.RunId,
    analystId: types.AnalystId,
    beaconId: types.BeaconId,
    alertLevel: types.AlertLevel,
};

pub const ActionAlertBeaconResponsePayload = struct {
    beaconId: types.BeaconId,
    alertLevel: types.AlertLevel,
};

pub const ActionArrestHatRequestPayload = struct {
    runId: types.RunId,
    analystId: types.AnalystId,
    hatId: types.HatId,
    location: types.Location,
};

pub const ActionArrestHatResponsePayload = struct {
    hatId: types.HatId,
    status: types.ArrestStatus,
    arrestedUntilTick: ?types.Tick,
};

/// Update a beacon's alert level, returning the applied state.
/// This is a direct mutation of the run's beacon array.
pub fn alertBeacon(run: *sim.RunState, payload: ActionAlertBeaconRequestPayload) !ActionAlertBeaconResponsePayload {
    if (payload.beaconId >= run.beacons.len) return error.BeaconNotFound;
    run.beacons[payload.beaconId].alertLevel = payload.alertLevel;
    return ActionAlertBeaconResponsePayload{
        .beaconId = payload.beaconId,
        .alertLevel = payload.alertLevel,
    };
}

/// Attempt to arrest a hat at a given location.
/// The stub succeeds only when the location matches the deterministic location
/// and the hat id satisfies a simple modulo rule.
pub fn arrestHat(run: *sim.RunState, payload: ActionArrestHatRequestPayload) !ActionArrestHatResponsePayload {
    const expected = types.deterministicLocation(run.seed, run.tick, payload.hatId);
    const matches = payload.location.x == expected.x and payload.location.y == expected.y;
    const success = (payload.hatId % 7 == 0) and matches;
    if (success) {
        _ = try run.arrested_hats.put(payload.hatId, true);
    }
    return ActionArrestHatResponsePayload{
        .hatId = payload.hatId,
        .status = if (success) .SUCCESSFUL else .FAILURE,
        .arrestedUntilTick = if (success) run.tick + 10 else null,
    };
}
