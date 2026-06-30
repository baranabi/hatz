//! Meeting execution engine: processes scheduled meetings per tick.
//!
//! Called by sim.advance() each tick after hat movement.
//! For each active taskforce, checks if any meetings occur at the current tick
//! and executes them: capability trades, event recording, taskforce disbanding.
const std = @import("std");
const types = @import("types.zig");
const sim = @import("sim.zig");
const attack = @import("attack.zig");

/// Execute all scheduled meetings for the given tick.
/// Scans active taskforces, finds meetings at this tick, executes trades,
/// records events, and disbands taskforces after their final meeting.
pub fn executeMeetings(run: *sim.RunState, tick: types.Tick) !void {
    for (run.taskforces.items, 0..) |*tf, tf_idx| {
        if (tf.status != .ACTIVE) continue;

        for (tf.meeting_plan, 0..) |meeting, meeting_idx| {
            if (meeting.tick != tick) continue;

            // ── Execute trades for this meeting ────────────────────────
            for (meeting.trades) |trade| {
                // Both source and recipient must be valid hat ids in range.
                if (trade.source_hat_id >= run.hat_states.len) continue;
                if (trade.recipient_hat_id >= run.hat_states.len) continue;

                const src = &run.hat_states[trade.source_hat_id];
                const dst = &run.hat_states[trade.recipient_hat_id];

                // Remove capability from source if they have it.
                if (types.hasCapability(src.capability_bits, trade.capability_id)) {
                    types.removeCapability(&src.capability_bits, trade.capability_id);
                }

                // Add to recipient (duplicate add is harmless for bitmask).
                types.addCapability(&dst.capability_bits, trade.capability_id);

                // Record trade event.
                try run.event_log.append(run.allocator, .{
                    .tick = tick,
                    .type = types.event_type_trade,
                    .taskforceId = @as(u32, @intCast(tf_idx)),
                    .tradeSourceId = trade.source_hat_id,
                    .tradeRecipientId = trade.recipient_hat_id,
                    .tradeCapabilityId = trade.capability_id,
                });
            }

            // ── Record meeting event ───────────────────────────────────
            try run.event_log.append(run.allocator, .{
                .tick = tick,
                .type = types.event_type_meeting,
                .location = meeting.location,
                .taskforceId = @as(u32, @intCast(tf_idx)),
                .participantCount = @as(u32, @intCast(meeting.participants.len)),
            });

            // ── Disband taskforce after final meeting ──────────────────
            if (meeting_idx == tf.meeting_plan.len - 1) {
                // Check beacon attack conditions before disbanding.
                // Attack event (if any) is recorded chronologically before the
                // disband event.
                _ = try attack.checkBeaconAttack(run, tick, tf, meeting, tf_idx);

                tf.status = .DISBANDED;
                try run.event_log.append(run.allocator, .{
                    .tick = tick,
                    .type = types.event_type_disbanded,
                    .taskforceId = @as(u32, @intCast(tf_idx)),
                });
            }
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

test "trades transfer capability from source to recipient" {
    const allocator = std.testing.allocator;
    var state = try makeTestRunState(allocator);
    defer deinitTestRunState(allocator, &state);

    // Hat 0 has cap 3, hat 1 does not.
    state.hat_states[0].capability_bits = 0x0008;
    state.hat_states[1].capability_bits = 0;

    // Execute the trade meeting at tick 10.
    try executeMeetings(&state, 10);

    // Hat 0 should have lost cap 3, hat 1 should have gained it.
    try std.testing.expect(!types.hasCapability(state.hat_states[0].capability_bits, 3));
    try std.testing.expect(types.hasCapability(state.hat_states[1].capability_bits, 3));
}

test "taskforce disbanded after final meeting" {
    const allocator = std.testing.allocator;
    var state = try makeTestRunState(allocator);
    defer deinitTestRunState(allocator, &state);

    try std.testing.expectEqual(.ACTIVE, state.taskforces.items[0].status);

    try executeMeetings(&state, 10);

    try std.testing.expectEqual(.DISBANDED, state.taskforces.items[0].status);
}

test "non-final meeting does not disband taskforce" {
    const allocator = std.testing.allocator;
    var state = try makeTestRunStateForMultiMeeting(allocator);
    defer deinitTestRunState(allocator, &state);

    try std.testing.expectEqual(.ACTIVE, state.taskforces.items[0].status);

    // Intermediate meeting at tick 10 — should NOT disband.
    try executeMeetings(&state, 10);
    try std.testing.expectEqual(.ACTIVE, state.taskforces.items[0].status);

    // Final meeting at tick 20 — should disband.
    try executeMeetings(&state, 20);
    try std.testing.expectEqual(.DISBANDED, state.taskforces.items[0].status);
}

test "meeting and trade events recorded in event log" {
    const allocator = std.testing.allocator;
    var state = try makeTestRunState(allocator);
    defer deinitTestRunState(allocator, &state);

    try executeMeetings(&state, 10);

    // Should have: trade event + meeting event + disband event.
    try std.testing.expect(state.event_log.items.len >= 3);

    // Find the meeting event.
    var found_meeting = false;
    var found_trade = false;
    var found_disband = false;
    for (state.event_log.items) |ev| {
        if (std.mem.eql(u8, ev.type, types.event_type_meeting)) {
            found_meeting = true;
            try std.testing.expectEqual(@as(u64, 10), ev.tick);
        }
        if (std.mem.eql(u8, ev.type, types.event_type_trade)) {
            found_trade = true;
            try std.testing.expectEqual(@as(types.HatId, 0), ev.tradeSourceId.?);
            try std.testing.expectEqual(@as(types.HatId, 1), ev.tradeRecipientId.?);
            try std.testing.expectEqual(@as(types.CapabilityId, 3), ev.tradeCapabilityId.?);
        }
        if (std.mem.eql(u8, ev.type, types.event_type_disbanded)) {
            found_disband = true;
        }
    }
    try std.testing.expect(found_meeting);
    try std.testing.expect(found_trade);
    try std.testing.expect(found_disband);
}

test "inactive taskforces are skipped during meeting execution" {
    const allocator = std.testing.allocator;
    var state = try makeTestRunState(allocator);
    defer deinitTestRunState(allocator, &state);

    // Mark taskforce as DISBANDED before execution.
    state.taskforces.items[0].status = .DISBANDED;

    try executeMeetings(&state, 10);

    // No events should have been recorded.
    try std.testing.expectEqual(@as(usize, 0), state.event_log.items.len);
    // Hat state unchanged: hat 0 still has cap 3.
    try std.testing.expect(types.hasCapability(state.hat_states[0].capability_bits, 3));
    try std.testing.expect(!types.hasCapability(state.hat_states[1].capability_bits, 3));
}

test "terrorist final meeting at beacon emits attack event" {
    const allocator = std.testing.allocator;

    // Build a state with a TERRORIST taskforce whose final meeting is at a
    // beacon's location and the hats' capabilities cover the beacon's
    // vulnerabilities.  This exercises the full path:
    //   executeMeetings → attack.checkBeaconAttack → event emission.
    const n_hats: usize = 2;
    const hats = try allocator.alloc(types.Hat, n_hats);
    for (hats, 0..) |*hat, i| {
        hat.* = .{ .id = @intCast(i), .true_color = .TERRORIST, .advertised_color = .UNKNOWN };
    }

    const hat_states = try allocator.alloc(types.HatState, n_hats);
    hat_states[0] = .{ .current_location = .{ .x = 5, .y = 5 }, .capability_bits = 0x0007 }; // caps 0,1,2
    hat_states[1] = .{ .current_location = .{ .x = 5, .y = 5 }, .capability_bits = 0x0007 }; // caps 0,1,2

    const n_orgs: usize = 1;
    const orgs = try allocator.alloc(types.Organization, n_orgs);
    orgs[0] = .{ .id = 0, .org_type = .TERRORIST, .members = try allocator.dupe(types.HatId, &.{ 0, 1 }) };

    // Beacons: beacon[0] is targetable at (10,10) with vulns {0,1,2};
    // the other 4 are dummies (RunState requires exactly 5).
    var beacons: [sim.beacon_count]types.Beacon = undefined;
    var beacon_vulns: [sim.beacon_count][3]types.CapabilityId = undefined;
    for (&beacons, 0..) |*b, i| {
        beacon_vulns[i] = .{ 0, 1, 2 };
        b.* = .{
            .beaconId = @intCast(i),
            .alertLevel = .OFF,
            .location = .{ .x = @intCast(10 + i * 20), .y = 10 },
        };
    }

    // Single meeting at tick 10, at beacon[0]'s location.
    const p0 = try allocator.dupe(types.HatId, &.{ 0, 1 });
    const meeting0 = types.Meeting{
        .tick = 10,
        .location = beacons[0].location,
        .participants = p0,
        .trades = &.{},
    };
    const mp = try allocator.alloc(types.Meeting, 1);
    mp[0] = meeting0;

    var taskforces = std.ArrayList(types.Taskforce).empty;
    try taskforces.append(allocator, types.Taskforce{
        .id = 0,
        .organization_id = 0,
        .members = try allocator.dupe(types.HatId, &.{ 0, 1 }),
        .target = beacons[0].location,
        .required_capabilities = try allocator.dupe(types.CapabilityId, &beacon_vulns[0]),
        .meeting_plan = mp,
        .status = .ACTIVE,
    });

    var state = sim.RunState{
        .allocator = allocator,
        .run_id = try allocator.dupe(u8, "attack-integration"),
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
    defer {
        // Manual cleanup matching the allocations above.
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
        for (state.organizations) |org| allocator.free(org.members);
        allocator.free(state.organizations);
        allocator.free(state.hats);
        allocator.free(state.hat_states);
        state.event_log.deinit(allocator);
        state.analyst_states.deinit();
        state.arrested_hats.deinit();
        allocator.free(state.run_id);
    }

    // Execute meetings at tick 10 — this is the final meeting at the beacon.
    try executeMeetings(&state, 10);

    // Must have at least 2 events: attack + disband (plus any trade/meeting events).
    try std.testing.expect(state.event_log.items.len >= 2);

    // Find and verify the attack event.
    var found_attack = false;
    for (state.event_log.items) |ev| {
        if (std.mem.eql(u8, ev.type, types.event_type_attack)) {
            try std.testing.expectEqual(@as(u64, 10), ev.tick);
            try std.testing.expectEqual(@as(types.BeaconId, 0), ev.beaconId.?);
            try std.testing.expectEqual(@as(u32, 0), ev.taskforceId.?);
            found_attack = true;
        }
    }
    try std.testing.expect(found_attack);
}

// ── Test helpers ──────────────────────────────────────────────────────

/// Build a minimal RunState for meeting execution tests.
/// Creates 3 hats, 1 benign org, 1 active taskforce with a single meeting
/// at tick 10 that trades capability 3 from hat 0 to hat 1.
fn makeTestRunState(allocator: std.mem.Allocator) !sim.RunState {
    const n_hats: usize = 3;
    const hats = try allocator.alloc(types.Hat, n_hats);
    for (hats, 0..) |*hat, i| {
        hat.* = .{ .id = @intCast(i), .true_color = .BENIGN, .advertised_color = .UNKNOWN };
    }

    const hat_states = try allocator.alloc(types.HatState, n_hats);
    hat_states[0] = .{ .current_location = .{ .x = 0, .y = 0 }, .capability_bits = 0x0008 }; // cap 3
    hat_states[1] = .{ .current_location = .{ .x = 0, .y = 0 }, .capability_bits = 0 };
    hat_states[2] = .{ .current_location = .{ .x = 0, .y = 0 }, .capability_bits = 0 };

    const n_orgs: usize = 1;
    const orgs = try allocator.alloc(types.Organization, n_orgs);
    orgs[0] = .{ .id = 0, .org_type = .BENIGN, .members = try allocator.dupe(types.HatId, &.{ 0, 1, 2 }) };

    // Beacon init (not used directly but struct requires it).
    const beacon_count = 5;
    var beacons: [beacon_count]types.Beacon = undefined;
    var beacon_vulns: [beacon_count][3]types.CapabilityId = undefined;
    for (&beacons, 0..) |*b, i| {
        beacon_vulns[i] = .{ 0, 1, 2 };
        b.* = .{
            .beaconId = @intCast(i),
            .alertLevel = .OFF,
            .location = .{ .x = @intCast(i * 10), .y = @intCast(i * 10) },
        };
    }

    // Meeting at tick 10: trade cap 3 from hat 0 to hat 1.
    const trades = try allocator.alloc(types.CapabilityTrade, 1);
    trades[0] = .{ .source_hat_id = 0, .recipient_hat_id = 1, .capability_id = 3 };

    const p0 = try allocator.dupe(types.HatId, &.{ 0, 1 });
    const meeting0 = types.Meeting{
        .tick = 10,
        .location = .{ .x = 5, .y = 5 },
        .participants = p0,
        .trades = trades,
    };

    const mp = try allocator.alloc(types.Meeting, 1);
    mp[0] = meeting0;

    var taskforces = std.ArrayList(types.Taskforce).empty;
    try taskforces.append(allocator, types.Taskforce{
        .id = 0,
        .organization_id = 0,
        .members = try allocator.dupe(types.HatId, &.{ 0, 1 }),
        .target = .{ .x = 10, .y = 10 },
        .required_capabilities = try allocator.dupe(types.CapabilityId, &.{ 3 }),
        .meeting_plan = mp,
        .status = .ACTIVE,
    });

    return sim.RunState{
        .allocator = allocator,
        .run_id = try allocator.dupe(u8, "meetings-test"),
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

/// Build a RunState with 2-meeting taskforce (intermediate at 10, final at 20).
fn makeTestRunStateForMultiMeeting(allocator: std.mem.Allocator) !sim.RunState {
    var state = try makeTestRunState(allocator);

    // Replace meeting plan: intermediate at 10, final at 20.
    allocator.free(state.taskforces.items[0].meeting_plan);

    const n_hats = state.hats.len;
    _ = n_hats;

    const p0 = try allocator.dupe(types.HatId, &.{ 0, 1 });
    const m0 = types.Meeting{
        .tick = 10,
        .location = .{ .x = 3, .y = 3 },
        .participants = p0,
        .trades = &.{},
    };

    const p1 = try allocator.dupe(types.HatId, &.{ 0, 1, 2 });
    const m1 = types.Meeting{
        .tick = 20,
        .location = .{ .x = 8, .y = 8 },
        .participants = p1,
        .trades = &.{},
    };

    const mp = try allocator.alloc(types.Meeting, 2);
    mp[0] = m0;
    mp[1] = m1;
    state.taskforces.items[0].meeting_plan = mp;

    return state;
}

/// Free all allocations in a test RunState.
fn deinitTestRunState(allocator: std.mem.Allocator, state: *sim.RunState) void {
    _ = allocator;
    state.deinit();
}
