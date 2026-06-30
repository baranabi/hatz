//! Analyst actions that mutate run state.
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
/// Records an EVENT_ALERT_CHANGE in the event log.
pub fn alertBeacon(run: *sim.RunState, payload: ActionAlertBeaconRequestPayload) !ActionAlertBeaconResponsePayload {
    if (payload.beaconId >= run.beacons.len) return error.BeaconNotFound;

    // Close current alert interval (increments false_positives if no attacks occurred).
    sim.closeAlertInterval(&run.beacon_alert_tracking[payload.beaconId]);
    // Set new alert level and reset tracking interval.
    run.beacon_alert_tracking[payload.beaconId].current_level = payload.alertLevel;
    run.beacon_alert_tracking[payload.beaconId].interval_had_attack = false;

    run.beacons[payload.beaconId].alertLevel = payload.alertLevel;
    try run.event_log.append(run.allocator, .{
        .tick = run.tick,
        .type = types.event_type_alert_change,
        .beaconId = payload.beaconId,
    });
    return ActionAlertBeaconResponsePayload{
        .beaconId = payload.beaconId,
        .alertLevel = payload.alertLevel,
    };
}

/// Attempt to arrest a hat at a given location.
///
/// Success requires ALL THREE:
/// 1. Hat is currently at payload.location
/// 2. Hat.true_color is TERRORIST or COVERT_TERRORIST
/// 3. Hat is member of an active terrorist taskforce
///
/// On success:
/// - Hat added to run.arrested_hats
/// - Hat capabilities excluded from attack matching for its taskforce
/// - EVENT_ARREST recorded in event_log
/// - arrestedUntilTick = tick when taskforce final meeting completes
///
/// On failure:
/// - false_arrests counter incremented for scoring
/// - EVENT_FALSE_ARREST recorded in event_log
/// - FAILURE status returned
pub fn arrestHat(run: *sim.RunState, payload: ActionArrestHatRequestPayload) !ActionArrestHatResponsePayload {
    // Check hat exists.
    if (payload.hatId >= run.hats.len) {
        return recordFalseArrest(run, payload.hatId);
    }

    // Condition 1: hat is currently at payload.location.
    const hat_state = run.hat_states[payload.hatId];
    const at_location = payload.location.x == hat_state.current_location.x and
        payload.location.y == hat_state.current_location.y;

    // Condition 2: true_color is TERRORIST or COVERT_TERRORIST.
    const hat = run.hats[payload.hatId];
    const is_terrorist = hat.true_color == .TERRORIST or hat.true_color == .COVERT_TERRORIST;

    // Condition 3: hat is member of an active terrorist taskforce.
    const tf_id = findActiveTerroristTaskforce(run, payload.hatId);

    if (at_location and is_terrorist and tf_id != null) {
        // Success.
        _ = try run.arrested_hats.put(payload.hatId, true);

        // Find final meeting tick for the taskforce.
        const tf = &run.taskforces.items[tf_id.?];
        const final_tick = tf.meeting_plan[tf.meeting_plan.len - 1].tick;

        try run.event_log.append(run.allocator, .{
            .tick = run.tick,
            .type = types.event_type_arrest,
            .hatId = payload.hatId,
            .taskforceId = @as(u32, @intCast(tf_id.?)),
        });

        return ActionArrestHatResponsePayload{
            .hatId = payload.hatId,
            .status = .SUCCESSFUL,
            .arrestedUntilTick = final_tick,
        };
    } else {
        return recordFalseArrest(run, payload.hatId);
    }
}

/// Record a false arrest: increment counter, log event, return FAILURE response.
fn recordFalseArrest(run: *sim.RunState, hat_id: types.HatId) !ActionArrestHatResponsePayload {
    run.false_arrests += 1;
    try run.event_log.append(run.allocator, .{
        .tick = run.tick,
        .type = types.event_type_false_arrest,
        .hatId = hat_id,
    });
    return ActionArrestHatResponsePayload{
        .hatId = hat_id,
        .status = .FAILURE,
        .arrestedUntilTick = null,
    };
}

/// Find the index of an active terrorist taskforce that contains the given hat.
/// Returns null if no such taskforce exists.
fn findActiveTerroristTaskforce(run: *sim.RunState, hat_id: types.HatId) ?usize {
    for (run.taskforces.items, 0..) |tf, idx| {
        if (tf.status != .ACTIVE) continue;
        const org = run.organizations[tf.organization_id];
        if (org.org_type != .TERRORIST) continue;
        for (tf.members) |member| {
            if (member == hat_id) return idx;
        }
    }
    return null;
}

test "arrestHat: terrorist in active taskforce at correct location succeeds" {
    const allocator = std.testing.allocator;
    var registry = sim.initForTesting(allocator);
    defer registry.deinit();

    const seed: u64 = 42;
    const params = sim.SimParams{};
    const run = try registry.createRun(seed, params);

    // Find a TERRORIST hat that is in an active terrorist taskforce.
    const target_hat = findTerroristInTaskforce(run) orelse return error.NoTerroristInTaskforce;
    const target_tf = run.taskforces.items[target_hat.taskforce_idx];

    // Position the hat at a known location.
    const test_location = types.Location{ .x = 10, .y = 10 };
    run.hat_states[target_hat.hat_id].current_location = test_location;

    const result = try arrestHat(run, .{
        .runId = "test",
        .analystId = "test",
        .hatId = target_hat.hat_id,
        .location = test_location,
    });

    try std.testing.expectEqual(target_hat.hat_id, result.hatId);
    try std.testing.expectEqual(.SUCCESSFUL, result.status);
    try std.testing.expect(result.arrestedUntilTick != null);
    // arrestedUntilTick should equal the final meeting tick.
    const final_tick = target_tf.meeting_plan[target_tf.meeting_plan.len - 1].tick;
    try std.testing.expectEqual(final_tick, result.arrestedUntilTick.?);

    // Hat should be in arrested_hats.
    try std.testing.expect(run.arrested_hats.contains(target_hat.hat_id));
}

test "arrestHat: terrorist not in taskforce at correct location fails (false arrest)" {
    const allocator = std.testing.allocator;
    var registry = sim.initForTesting(allocator);
    defer registry.deinit();

    const seed: u64 = 42;
    const params = sim.SimParams{};
    const run = try registry.createRun(seed, params);

    // Find a TERRORIST or COVERT_TERRORIST hat NOT in any active terrorist taskforce.
    const non_tf_hat_id = findTerroristNotInTaskforce(run) orelse return error.NoTerroristOutsideTaskforce;
    const false_arrests_before = run.false_arrests;

    const test_location = types.Location{ .x = 10, .y = 10 };
    run.hat_states[non_tf_hat_id].current_location = test_location;

    const result = try arrestHat(run, .{
        .runId = "test",
        .analystId = "test",
        .hatId = non_tf_hat_id,
        .location = test_location,
    });

    try std.testing.expectEqual(non_tf_hat_id, result.hatId);
    try std.testing.expectEqual(.FAILURE, result.status);
    try std.testing.expectEqual(null, result.arrestedUntilTick);
    // false_arrests counter incremented.
    try std.testing.expectEqual(false_arrests_before + 1, run.false_arrests);
}

test "arrestHat: terrorist in active taskforce at wrong location fails" {
    const allocator = std.testing.allocator;
    var registry = sim.initForTesting(allocator);
    defer registry.deinit();

    const seed: u64 = 42;
    const params = sim.SimParams{};
    const run = try registry.createRun(seed, params);

    const target_hat = findTerroristInTaskforce(run) orelse return error.NoTerroristInTaskforce;

    // Position the hat at a different location than the arrest request.
    run.hat_states[target_hat.hat_id].current_location = types.Location{ .x = 5, .y = 5 };
    const wrong_location = types.Location{ .x = 99, .y = 99 };

    const result = try arrestHat(run, .{
        .runId = "test",
        .analystId = "test",
        .hatId = target_hat.hat_id,
        .location = wrong_location,
    });

    try std.testing.expectEqual(.FAILURE, result.status);
}

test "arrestHat: benign hat at any location fails (false arrest)" {
    const allocator = std.testing.allocator;
    var registry = sim.initForTesting(allocator);
    defer registry.deinit();

    const seed: u64 = 42;
    const params = sim.SimParams{};
    const run = try registry.createRun(seed, params);

    // Find a BENIGN hat.
    const benign_id = findBenignHat(run) orelse return error.NoBenignHat;
    run.hat_states[benign_id].current_location = types.Location{ .x = 10, .y = 10 };

    const result = try arrestHat(run, .{
        .runId = "test",
        .analystId = "test",
        .hatId = benign_id,
        .location = types.Location{ .x = 10, .y = 10 },
    });

    try std.testing.expectEqual(.FAILURE, result.status);
}

test "alertBeacon records EVENT_ALERT_CHANGE in event_log" {
    const allocator = std.testing.allocator;
    var registry = sim.initForTesting(allocator);
    defer registry.deinit();

    const seed: u64 = 42;
    const params = sim.SimParams{};
    const run = try registry.createRun(seed, params);

    const log_before = run.event_log.items.len;

    _ = try alertBeacon(run, .{
        .runId = "test",
        .analystId = "test",
        .beaconId = 0,
        .alertLevel = .LEVEL_ONE,
    });

    try std.testing.expectEqual(log_before + 1, run.event_log.items.len);
    const event = run.event_log.items[log_before];
    try std.testing.expectEqualStrings(types.event_type_alert_change, event.type);
    try std.testing.expectEqual(@as(types.BeaconId, 0), event.beaconId.?);
    try std.testing.expectEqual(run.beacons[0].alertLevel, .LEVEL_ONE);
}

// ── Test helpers ──────────────────────────────────────────────────────

const HatInTaskforce = struct { hat_id: types.HatId, taskforce_idx: usize };

fn findTerroristInTaskforce(run: *sim.RunState) ?HatInTaskforce {
    for (run.taskforces.items, 0..) |tf, idx| {
        if (tf.status != .ACTIVE) continue;
        const org = run.organizations[tf.organization_id];
        if (org.org_type != .TERRORIST) continue;
        for (tf.members) |member| {
            const hat = run.hats[member];
            if (hat.true_color == .TERRORIST or hat.true_color == .COVERT_TERRORIST) {
                return HatInTaskforce{ .hat_id = member, .taskforce_idx = idx };
            }
        }
    }
    return null;
}

fn findTerroristNotInTaskforce(run: *sim.RunState) ?types.HatId {
    for (run.hats, 0..) |hat, idx| {
        if (hat.true_color != .TERRORIST and hat.true_color != .COVERT_TERRORIST) continue;
        // Check if this hat is in ANY active terrorist taskforce.
        var in_taskforce = false;
        for (run.taskforces.items) |tf| {
            if (tf.status != .ACTIVE) continue;
            const org = run.organizations[tf.organization_id];
            if (org.org_type != .TERRORIST) continue;
            for (tf.members) |member| {
                if (member == hat.id) {
                    in_taskforce = true;
                    break;
                }
            }
            if (in_taskforce) break;
        }
        if (!in_taskforce) return @as(types.HatId, @intCast(idx));
    }
    return null;
}

pub fn findBenignHat(run: *sim.RunState) ?types.HatId {
    for (run.hats, 0..) |hat, idx| {
        if (hat.true_color == .BENIGN) return @as(types.HatId, @intCast(idx));
    }
    return null;
}
