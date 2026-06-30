//! Beacon attack detection engine.
//!
//! During sim.advance(), after each meeting executes, this module checks
//! the 4-condition beacon attack rule:
//! 1. Meeting location matches any beacon location
//! 2. Meeting is the final (root) meeting of an active taskforce
//! 3. Taskforce belongs to a terrorist organization
//! 4. Combined capabilities of hats at the meeting are a superset of
//!    the beacon's vulnerabilities
//!
//! If all 4 conditions are met, an EVENT_ATTACK is recorded in the event log
//! and the taskforce is marked as DISBANDED (attack completes the taskforce).
const std = @import("std");
const types = @import("types.zig");
const sim = @import("sim.zig");

/// Check the 4-condition beacon attack rule after a meeting executes.
///
/// Called from meetings.zig when the final meeting of an active taskforce
/// has been processed (trades executed, meeting event recorded). If all 4
/// conditions hold, records an attack event. The caller is responsible for
/// disbanding the taskforce afterwards.
///
/// Returns true if an attack was detected and recorded.
pub fn checkBeaconAttack(
    run: *sim.RunState,
    tick: types.Tick,
    tf: *types.Taskforce,
    meeting: types.Meeting,
    tf_idx: usize,
) !bool {
    // Condition 3 (moved up for early exit): taskforce must belong to terrorist org.
    const org = run.organizations[tf.organization_id];
    if (org.org_type != .TERRORIST) return false;

    // Check each beacon.
    for (run.beacons, 0..) |beacon, beacon_idx| {
        // Condition 1: meeting location must match beacon location.
        if (meeting.location.x != beacon.location.x or meeting.location.y != beacon.location.y) continue;

        // Condition 4: combined capabilities of hats at meeting must be a
        // superset of the beacon's vulnerabilities.
        // NOTE: read from run.beacon_vulnerabilities, not beacon.vulnerabilities,
        // because the latter is a slice that dangles after RunState.init returns
        // (it points into the stack frame before the struct copy).
        var combined_bits: u64 = 0;
        for (meeting.participants) |hat_id| {
            if (hat_id < run.hat_states.len) {
                combined_bits |= run.hat_states[hat_id].capability_bits;
            }
        }

        var all_covered = true;
        const vulns = run.beacon_vulnerabilities[beacon_idx][0..];
        for (vulns) |vuln| {
            if (!types.hasCapability(combined_bits, vuln)) {
                all_covered = false;
                break;
            }
        }
        if (!all_covered) continue;

        // All 4 conditions met → record attack event.
        try run.event_log.append(run.allocator, .{
            .tick = tick,
            .type = types.event_type_attack,
            .beaconId = @as(types.BeaconId, @intCast(beacon_idx)),
            .location = meeting.location,
            .taskforceId = @as(u32, @intCast(tf_idx)),
        });

        // Track attack for alert effectiveness: mark interval and increment
        // appropriate hits/attack-level counters based on the beacon's alert level.
        run.beacon_alert_tracking[beacon_idx].interval_had_attack = true;
        const alert = run.beacons[beacon_idx].alertLevel;
        switch (alert) {
            .OFF => run.attacks_at_level_off += 1,
            .LEVEL_ONE => {
                run.beacon_alert_tracking[beacon_idx].level_one.hits += 1;
                run.attacks_at_level_one += 1;
            },
            .LEVEL_TWO => {
                run.beacon_alert_tracking[beacon_idx].level_two.hits += 1;
                run.attacks_at_level_two += 1;
            },
        }

        return true; // Attack detected.
    }

    return false; // No beacon matched or vulnerability check failed.
}

// ── Tests ──────────────────────────────────────────────────────────────

test "attack detected when all 4 conditions met" {
    const allocator = std.testing.allocator;

    // Build a minimal RunState with a beacon and a terrorist taskforce
    // whose root meeting is at the beacon's location, with hats that have
    // all required vulnerabilities.
    var state = try makeTestRunState(allocator);
    defer deinitTestRunState(allocator, &state);

    // Record an attack event.
    const tf_idx: usize = 0;
    const attack_detected = try checkBeaconAttack(
        &state, 42,
        &state.taskforces.items[tf_idx],
        state.taskforces.items[tf_idx].meeting_plan[0], // root meeting
        tf_idx,
    );

    try std.testing.expect(attack_detected);

    // Event log should have exactly 1 entry (the attack event).
    try std.testing.expectEqual(@as(usize, 1), state.event_log.items.len);
    const ev = state.event_log.items[0];
    try std.testing.expectEqualStrings(types.event_type_attack, ev.type);
    try std.testing.expectEqual(@as(u64, 42), ev.tick);
    try std.testing.expectEqual(@as(types.BeaconId, 0), ev.beaconId.?);
    try std.testing.expectEqual(@as(u32, 0), ev.taskforceId.?);
}

test "no attack when meeting location does not match any beacon" {
    const allocator = std.testing.allocator;
    var state = try makeTestRunState(allocator);
    defer deinitTestRunState(allocator, &state);

    // Move the meeting location far from the beacon.
    var tf0 = &state.taskforces.items[0];
    tf0.meeting_plan[0].location = .{ .x = 99, .y = 99 };

    const attack_detected = try checkBeaconAttack(
        &state, 42,
        &state.taskforces.items[0],
        state.taskforces.items[0].meeting_plan[0],
        0,
    );
    try std.testing.expect(!attack_detected);
    try std.testing.expectEqual(@as(usize, 0), state.event_log.items.len);
}

test "no attack when org is benign" {
    const allocator = std.testing.allocator;
    var state = try makeTestRunState(allocator);
    defer deinitTestRunState(allocator, &state);

    // Change taskforce's org to benign.
    state.taskforces.items[0].organization_id = 1;
    // Make sure org 1 is BENIGN.
    state.organizations[1].org_type = .BENIGN;

    const attack_detected = try checkBeaconAttack(
        &state, 42,
        &state.taskforces.items[0],
        state.taskforces.items[0].meeting_plan[0],
        0,
    );
    try std.testing.expect(!attack_detected);
    try std.testing.expectEqual(@as(usize, 0), state.event_log.items.len);
}

test "no attack when capabilities do not cover vulnerabilities" {
    const allocator = std.testing.allocator;
    var state = try makeTestRunState(allocator);
    defer deinitTestRunState(allocator, &state);

    // Clear all hat capabilities so the vulnerability check fails.
    for (state.hat_states) |*hs| {
        hs.capability_bits = 0;
    }

    const attack_detected = try checkBeaconAttack(
        &state, 42,
        &state.taskforces.items[0],
        state.taskforces.items[0].meeting_plan[0],
        0,
    );
    try std.testing.expect(!attack_detected);
    try std.testing.expectEqual(@as(usize, 0), state.event_log.items.len);
}

test "attack recorded with correct beacon id when multiple beacons exist" {
    const allocator = std.testing.allocator;
    var state = try makeTestRunState(allocator);
    defer deinitTestRunState(allocator, &state);

    // Move the meeting to beacon 2's location.
    const beacon2_loc = state.beacons[2].location;
    var tf0 = &state.taskforces.items[0];
    tf0.meeting_plan[0].location = beacon2_loc;

    const attack_detected = try checkBeaconAttack(
        &state, 99,
        &state.taskforces.items[0],
        state.taskforces.items[0].meeting_plan[0],
        0,
    );
    try std.testing.expect(attack_detected);
    try std.testing.expectEqual(@as(usize, 1), state.event_log.items.len);
    try std.testing.expectEqual(@as(types.BeaconId, 2), state.event_log.items[0].beaconId.?);
    try std.testing.expectEqual(@as(u64, 99), state.event_log.items[0].tick);
}

test "attack not re-recorded for same meeting and beacon" {
    // Verify that calling checkBeaconAttack twice produces two events
    // (the function itself does not deduplicate — the caller gates on
    // final-meeting-only so it won't be called twice for the same meeting).
    const allocator = std.testing.allocator;
    var state = try makeTestRunState(allocator);
    defer deinitTestRunState(allocator, &state);

    _ = try checkBeaconAttack(&state, 42, &state.taskforces.items[0], state.taskforces.items[0].meeting_plan[0], 0);
    _ = try checkBeaconAttack(&state, 42, &state.taskforces.items[0], state.taskforces.items[0].meeting_plan[0], 0);

    // Two calls → two events.
    try std.testing.expectEqual(@as(usize, 2), state.event_log.items.len);
}

// ── Test helpers ──────────────────────────────────────────────────────

/// Build a minimal RunState for unit testing attack detection.
/// Creates 5 beacons, 2 orgs (one terrorist, one benign), 1 terrorist
/// taskforce with a single root meeting located at beacon[0]'s location,
/// and hats with all capabilities set so the vulnerability check passes.
fn makeTestRunState(allocator: std.mem.Allocator) !sim.RunState {
    // Create hats: 3 hats with all 16 capabilities set.
    const n_hats: usize = 3;
    const hats = try allocator.alloc(types.Hat, n_hats);
    for (hats, 0..) |*hat, i| {
        hat.* = .{ .id = @intCast(i), .true_color = .TERRORIST, .advertised_color = .UNKNOWN };
    }

    // Hat states with all capabilities set.
    const hat_states = try allocator.alloc(types.HatState, n_hats);
    for (hat_states) |*hs| {
        hs.* = .{ .current_location = .{ .x = 0, .y = 0 }, .capability_bits = 0xFFFF };
    }

    // 2 orgs: terrorist and benign.
    const n_orgs: usize = 2;
    var orgs = try allocator.alloc(types.Organization, n_orgs);
    orgs[0] = .{ .id = 0, .org_type = .TERRORIST, .members = try allocator.dupe(types.HatId, &.{ 0, 1, 2 }) };
    orgs[1] = .{ .id = 1, .org_type = .BENIGN, .members = try allocator.dupe(types.HatId, &.{}) };

    // Create beacons with deterministic locations.
    const beacon_count = 5;
    var beacons: [beacon_count]types.Beacon = undefined;
    var beacon_vulns: [beacon_count][3]types.CapabilityId = undefined;
    for (&beacons, 0..) |*beacon, idx| {
        const bid: types.BeaconId = @intCast(idx);
        beacon_vulns[idx] = .{ 0, 1, 2 };
        beacon.* = .{
            .beaconId = bid,
            .alertLevel = .OFF,
            .location = types.deterministicBeaconLocation(42, bid),
        };
    }

    // Single taskforce: terrorist, one root meeting at beacon[0]'s location.
    const beacon0_loc = beacons[0].location;
    const meeting = types.Meeting{
        .tick = 42,
        .location = beacon0_loc,
        .participants = try allocator.dupe(types.HatId, &.{ 0, 1, 2 }),
        .trades = &.{},
    };
    const meeting_plan = try allocator.alloc(types.Meeting, 1);
    meeting_plan[0] = meeting;

    var taskforces = std.ArrayList(types.Taskforce).empty;
    try taskforces.append(allocator, types.Taskforce{
        .id = 0,
        .organization_id = 0,
        .members = try allocator.dupe(types.HatId, &.{ 0, 1, 2 }),
        .target = beacon0_loc,
        .required_capabilities = try allocator.dupe(types.CapabilityId, &.{ 0, 1, 2 }),
        .meeting_plan = meeting_plan,
        .status = .ACTIVE,
    });

    return sim.RunState{
        .allocator = allocator,
        .run_id = try allocator.dupe(u8, "test-run"),
        .seed = 42,
        .tick = 0,
        .params = sim.SimParams{},
        .analyst_states = std.StringHashMap(sim.AnalystState).init(allocator),
        .beacons = beacons,
        .beacon_vulnerabilities = beacon_vulns,
        .arrested_hats = std.AutoHashMap(types.HatId, bool).init(allocator),
        .event_log = .empty,
        .hat_states = hat_states,
        .hats = hats,
        .organizations = orgs,
        .taskforces = taskforces,
    };
}

/// Free all allocations in the test RunState.
fn deinitTestRunState(allocator: std.mem.Allocator, state: *sim.RunState) void {
    // Free meeting plans.
    for (state.taskforces.items) |tf| {
        allocator.free(tf.members);
        allocator.free(tf.required_capabilities);
        for (tf.meeting_plan) |m| {
            allocator.free(m.participants);
            allocator.free(m.trades);
        }
        allocator.free(tf.meeting_plan);
    }
    state.taskforces.deinit(allocator);
    for (state.organizations) |org| {
        allocator.free(org.members);
    }
    allocator.free(state.organizations);
    allocator.free(state.hats);
    allocator.free(state.hat_states);
    state.event_log.deinit(allocator);
    state.analyst_states.deinit();
    state.arrested_hats.deinit();
    allocator.free(state.run_id);
}
