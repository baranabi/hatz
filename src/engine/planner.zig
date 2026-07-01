//! Organization planner: generative meeting trees for taskforces.
//!
//! Per organization, every planning_interval ticks, there is a 50% chance
//! to create a new taskforce with a deterministic meeting tree that routes
//! selected members toward a target location. Both terrorist and benign orgs
//! use the same planner logic.
//!
//! Capability routing: generateMeetingTree now creates trades in intermediate
//! meetings that transfer required capabilities from org members (non-taskforce
//! hats) to taskforce members, ensuring the root meeting has all required
//! capabilities for beacon attacks. This matches the population-init pattern
//! in population.zig::generateTaskforces.
const std = @import("std");
const types = @import("types.zig");

/// Run organization planning for one tick.
/// Creates new taskforces on planning-interval boundaries if tick is a
/// planning trigger.
/// `beacons` is used by terrorist orgs to select attack targets.
/// Pass an empty slice when no beacons are defined (unit tests).
pub fn plan(
    allocator: std.mem.Allocator,
    seed: u64,
    interval: u64,
    tick: types.Tick,
    organizations: []const types.Organization,
    beacons: []const types.Beacon,
    hat_states: []const types.HatState,
    taskforces: *std.ArrayList(types.Taskforce),
    event_log: *std.ArrayList(types.EventRecord),
) !void {
    if (interval == 0 or tick % interval != 0) return;

    for (organizations) |org| {
        try planForOrg(allocator, seed, org, tick, beacons, hat_states, taskforces, event_log);
    }
}

/// Plan a single taskforce for one organization (50% chance per planning interval).
/// For TERRORIST orgs the target is a beacon location; for BENIGN orgs a random
/// world coordinate.
fn planForOrg(
    allocator: std.mem.Allocator,
    seed: u64,
    org: types.Organization,
    tick: types.Tick,
    beacons: []const types.Beacon,
    hat_states: []const types.HatState,
    taskforces: *std.ArrayList(types.Taskforce),
    event_log: *std.ArrayList(types.EventRecord),
) !void {
    // Skip orgs with no members.
    if (org.members.len == 0) return;

    // Deterministic mix for this org at this tick.
    const org_mix = types.mix(seed ^ (@as(u64, tick) *% 0x9E3779B97F4A7C15) ^ (@as(u64, org.id) *% 0xBF58476D1CE4E5B9));

    // 1. 50% chance to create new taskforce.
    if (org_mix % 100 >= 50) return;

    // 2. Select target and required capabilities.
    //    TERRORIST orgs target a beacon (attack condition 1 + matching vulnerabilities).
    //    BENIGN orgs get a random world coordinate (cover behaviour).
    const beacon_idx: usize = blk: {
        if (org.org_type == .TERRORIST and beacons.len > 0) {
            const idx = types.bounded(org_mix >> 8, @as(i32, @intCast(beacons.len - 1)));
            break :blk @as(usize, @intCast(idx));
        }
        break :blk 0; // unused for BENIGN
    };

    const target: types.Location = target: {
        if (org.org_type == .TERRORIST and beacons.len > 0) {
            break :target beacons[beacon_idx].location;
        }
        break :target types.Location{
            .x = types.bounded(org_mix, types.WorldMax),
            .y = types.bounded(org_mix >> 16, types.WorldMax),
        };
    };

    // 3. Select required capabilities.
    //    For TERRORIST orgs targeting a beacon, compute vulnerabilities
    //    deterministically (same formula as sim.beaconVulnerabilities).
    //    NOTE: we do NOT read from beacon.vulnerabilities — that field was
    //    removed from Beacon because it's a dangling slice after RunState.init
    //    returns by value.  Instead, recompute from seed + beaconId.
    //    Otherwise pick 2–4 random capabilities (current behaviour).
    const capabilities: []types.CapabilityId = if (org.org_type == .TERRORIST and beacons.len > 0) blk: {
        const bid = beacons[beacon_idx].beaconId;
        const base = seed + @as(u64, bid) * 7;
        var vulns_buf: [3]types.CapabilityId = undefined;
        for (&vulns_buf, 0..) |*v, i| {
            v.* = @intCast((base + @as(u64, i) * 3) % 16);
        }
        break :blk try allocator.dupe(types.CapabilityId, vulns_buf[0..]);
    } else blk: {
        const n_caps: usize = @intCast(2 + (org_mix >> 8) % 3); // 2, 3, or 4
        var caps = try allocator.alloc(types.CapabilityId, n_caps);
        for (0..n_caps) |i| {
            caps[i] = @intCast((org_mix + @as(u64, i) *% 7) % 16);
        }
        break :blk caps;
    };

    // 4. Select 3–6 taskforce members from org, clamped to available count.
    const n_members_desired: u32 = 3 + @as(u32, @intCast((org_mix >> 24) % 4)); // 3, 4, 5, or 6
    const actual_n = @min(n_members_desired, @as(u32, @intCast(org.members.len)));
    if (actual_n < 1) {
        allocator.free(capabilities);
        return;
    }
    var members = try allocator.alloc(types.HatId, actual_n);
    // Deterministic selection from org members (no duplicates within taskforce).
    {
        var seen = try allocator.alloc(bool, org.members.len);
        defer allocator.free(seen);
        @memset(seen, false);
        var picked: usize = 0;
        var attempt: u64 = 0;
        while (picked < actual_n) : (attempt += 1) {
            const idx = (org_mix +% @as(u64, attempt) *% 13) % @as(u64, org.members.len);
            if (!seen[idx]) {
                members[picked] = org.members[idx];
                seen[idx] = true;
                picked += 1;
            }
        }
    }

    // 5. Capabilities routable among hats — generate trades in meeting tree.
    //    (Step 5 is now the trade generation, replacing the old stub comment.)

    // 6. Generate meeting tree with capability trades.
    const travel_time: types.Tick = 3 + (org_mix >> 40) % 3; // 3–5 ticks
    const meetings = try generateMeetingTree(allocator, seed, org.id, tick, travel_time, target, members, org, capabilities, hat_states);

    // 7. Store taskforce.
    const tf_id: u32 = @intCast(taskforces.items.len);
    try taskforces.append(allocator, types.Taskforce{
        .id = tf_id,
        .organization_id = org.id,
        .members = members,
        .target = target,
        .required_capabilities = capabilities,
        .meeting_plan = meetings,
        .status = .ACTIVE,
    });

    // Log taskforce creation event.
    try event_log.append(allocator, types.EventRecord{
        .tick = tick,
        .type = "taskforce_created",
        .location = target,
        .taskforceId = tf_id,
        .participantCount = @intCast(members.len),
    });
}

/// Generate a deterministic meeting tree for a taskforce.
///
/// Structure (deterministic from seed + org_id + tick):
/// - Intermediate meetings at intermediate ticks/locations, one per group of up
///   to 3 members, meeting at locations progressing toward the target.
/// - Root meeting at the target at tick = current_tick + travel_time.
///
/// Capability routing: for each required capability not already held by a
/// taskforce member, finds an org member (preferring non-taskforce hats) that
/// holds the capability and schedules a trade in the first intermediate meeting.
/// The source hat is added as a participant to that meeting. If there are no
/// intermediate meetings, trades are placed at the root meeting instead.
///
/// Meetings are returned sorted by tick (non-decreasing).
fn generateMeetingTree(
    allocator: std.mem.Allocator,
    seed: u64,
    org_id: types.OrganizationId,
    current_tick: types.Tick,
    travel_time: types.Tick,
    target: types.Location,
    members: []const types.HatId,
    org: types.Organization,
    required_capabilities: []const types.CapabilityId,
    hat_states: []const types.HatState,
) ![]types.Meeting {
    const n_members = members.len;
    const root_tick = current_tick + travel_time;

    var meetings = std.ArrayList(types.Meeting).empty;
    errdefer meetings.deinit(allocator);

    if (n_members == 0) {
        // No members: single empty root meeting at target.
        try meetings.append(allocator, types.Meeting{
            .tick = root_tick,
            .location = target,
            .participants = try allocator.dupe(types.HatId, &.{}),
            .trades = &.{},
        });
        return meetings.toOwnedSlice(allocator);
    }

    // ── Compute capability trades ───────────────────────────────────────
    // Build a set of taskforce members for fast lookup.
    var member_set = std.AutoHashMap(types.HatId, void).init(allocator);
    defer member_set.deinit();
    for (members) |m| {
        try member_set.put(m, {});
    }

    // Determine which required capabilities are not already held by any
    // taskforce member (check hat_states for current capability ownership).
    // These are the capabilities we need to route via trades.
    var needed_caps = std.ArrayList(types.CapabilityId).empty;
    defer needed_caps.deinit(allocator);
    caps: for (required_capabilities) |cap| {
        for (members) |m| {
            if (m < hat_states.len and types.hasCapability(hat_states[m].capability_bits, cap)) {
                continue :caps;
            }
        }
        try needed_caps.append(allocator, cap);
    }

    // Build trades: for each needed capability, find a source hat.
    var trades = std.ArrayList(types.CapabilityTrade).empty;
    defer trades.deinit(allocator);
    // Track which trading hats we'll add as participants.
    var trading_hats = std.AutoHashMap(types.HatId, void).init(allocator);
    defer trading_hats.deinit();

    for (needed_caps.items, 0..) |cap, idx| {
        const recipient = members[idx % n_members];

        // Phase 1: find non-taskforce org member that holds this capability.
        var source: ?types.HatId = null;
        for (org.members) |org_m| {
            if (!member_set.contains(org_m) and org_m < hat_states.len and
                types.hasCapability(hat_states[org_m].capability_bits, cap))
            {
                source = org_m;
                break;
            }
        }

        // Phase 2: fallback — any org member (even taskforce members) with the cap.
        if (source == null) {
            for (org.members) |org_m| {
                if (org_m < hat_states.len and
                    types.hasCapability(hat_states[org_m].capability_bits, cap))
                {
                    source = org_m;
                    break;
                }
            }
        }

        if (source) |src| {
            try trades.append(allocator, .{
                .source_hat_id = src,
                .recipient_hat_id = recipient,
                .capability_id = cap,
            });
            try trading_hats.put(src, {});
        }
        // If no source found, the capability remains uncovered. The attack
        // check will simply fail for this taskforce, which is valid behaviour.
    }

    // ── Intermediate meetings ───────────────────────────────────────────
    // Groups of up to 3 members meet at intermediate locations that progress
    // toward the target. Trading hats are added to the first intermediate
    // meeting (or root if no intermediates exist).
    const group_size: usize = 3;
    var midx: usize = 0;
    var mid_tick = current_tick + 1;

    const tree_mix = types.mix(seed ^ (@as(u64, org_id) *% 0x9E3779B97F4A7C15) ^ (@as(u64, current_tick) *% 0xBF58476D1CE4E5B9));

    var trades_placed = false;

    while (midx < n_members and mid_tick < root_tick) {
        const group_end = @min(midx + group_size, n_members);
        const group = members[midx..group_end];

        // Intermediate location: deterministic point progressing toward target.
        const progress: f64 = @as(f64, @floatFromInt(mid_tick - current_tick)) / @as(f64, @floatFromInt(travel_time));
        const int_x = @as(i32, @intFromFloat(@as(f64, @floatFromInt(target.x)) * progress));
        const int_y = @as(i32, @intFromFloat(@as(f64, @floatFromInt(target.y)) * progress));

        // Add a small deterministic offset so intermediate meetings at the same
        // progress are at slightly different locations.
        const offset = types.bounded(tree_mix ^ @as(u64, midx) *% 0x9E3779B97F4A7C15, 5);
        const loc = types.Location{
            .x = @min(types.WorldMax, @max(0, int_x + offset)),
            .y = @min(types.WorldMax, @max(0, int_y - @divFloor(offset, 2))),
        };

        if (!trades_placed and trades.items.len > 0) {
            // First intermediate meeting: include trading hat participants + trades.
            const n_extra = trading_hats.count();
            var participants = try allocator.alloc(types.HatId, group.len + n_extra);
            @memcpy(participants[0..group.len], group);
            var pi: usize = group.len;
            var iter = trading_hats.keyIterator();
            while (iter.next()) |key| {
                participants[pi] = key.*;
                pi += 1;
            }
            try meetings.append(allocator, types.Meeting{
                .tick = mid_tick,
                .location = loc,
                .participants = participants,
                .trades = try trades.toOwnedSlice(allocator),
            });
            trades_placed = true;
        } else {
            try meetings.append(allocator, types.Meeting{
                .tick = mid_tick,
                .location = loc,
                .participants = try allocator.dupe(types.HatId, group),
                .trades = &.{},
            });
        }

        midx = group_end;
        mid_tick += 1;
    }

    // Root meeting at target — all members.
    // If no intermediate meeting exists and we have trades, put trades here.
    // (Without intermediate meetings, the trading hats can't participate,
    // but trades still execute on hat_states — meetings.zig doesn't require
    // source/recipient to be participants.)
    var root_trades: []const types.CapabilityTrade = &.{};
    if (!trades_placed and trades.items.len > 0) {
        root_trades = try trades.toOwnedSlice(allocator);
    }
    try meetings.append(allocator, types.Meeting{
        .tick = root_tick,
        .location = target,
        .participants = try allocator.dupe(types.HatId, members),
        .trades = root_trades,
    });

    return meetings.toOwnedSlice(allocator);
}

// ── Tests ──────────────────────────────────────────────────────────────

test "planner does nothing on non-multiple ticks" {
    const allocator = std.testing.allocator;
    var taskforces = std.ArrayList(types.Taskforce).empty;
    defer taskforces.deinit(allocator);
    var event_log = std.ArrayList(types.EventRecord).empty;
    defer event_log.deinit(allocator);

    const orgs = [_]types.Organization{
        .{ .id = 0, .org_type = .TERRORIST, .members = &.{ 0, 1, 2 } },
        .{ .id = 1, .org_type = .BENIGN, .members = &.{ 3, 4, 5 } },
    };

    // Tick 1 with interval 10 → no planning.
    try plan(allocator, 42, 10, 1, &orgs, &.{}, &.{}, &taskforces, &event_log);
    try std.testing.expectEqual(@as(usize, 0), taskforces.items.len);
    try std.testing.expectEqual(@as(usize, 0), event_log.items.len);
}

test "planner creates taskforces on planning interval ticks" {
    const allocator = std.testing.allocator;
    var taskforces = std.ArrayList(types.Taskforce).empty;
    defer {
        for (taskforces.items) |*tf| {
            allocator.free(tf.members);
            allocator.free(tf.required_capabilities);
            for (tf.meeting_plan) |m| {
                allocator.free(m.participants);
                allocator.free(m.trades);
            }
            allocator.free(tf.meeting_plan);
        }
        taskforces.deinit(allocator);
    }
    var event_log = std.ArrayList(types.EventRecord).empty;
    defer {
        event_log.deinit(allocator);
    }

    const orgs = [_]types.Organization{
        .{ .id = 0, .org_type = .TERRORIST, .members = &.{ 0, 1, 2, 3, 4 } },
        .{ .id = 1, .org_type = .BENIGN, .members = &.{ 5, 6, 7, 8, 9 } },
    };

    // Tick 10 with interval 10 → planning tick (50% chance per org).
    try plan(allocator, 12345, 10, 10, &orgs, &.{}, &.{}, &taskforces, &event_log);
    // At least one taskforce should be created with seed 42 (deterministic).
    try std.testing.expect(taskforces.items.len > 0);
    try std.testing.expectEqual(taskforces.items.len, event_log.items.len);
}

test "taskforce meetings have non-decreasing tick order and valid locations" {
    const allocator = std.testing.allocator;
    var taskforces = std.ArrayList(types.Taskforce).empty;
    defer {
        for (taskforces.items) |*tf| {
            allocator.free(tf.members);
            allocator.free(tf.required_capabilities);
            for (tf.meeting_plan) |m| {
                allocator.free(m.participants);
                allocator.free(m.trades);
            }
            allocator.free(tf.meeting_plan);
        }
        taskforces.deinit(allocator);
    }
    var event_log = std.ArrayList(types.EventRecord).empty;
    defer {
        event_log.deinit(allocator);
    }

    const orgs = [_]types.Organization{
        .{ .id = 0, .org_type = .TERRORIST, .members = &.{ 0, 1, 2, 3, 4, 5 } },
        .{ .id = 1, .org_type = .BENIGN, .members = &.{ 6, 7, 8 } },
    };

    try plan(allocator, 12345, 10, 10, &orgs, &.{}, &.{}, &taskforces, &event_log);

    for (taskforces.items) |tf| {
        var prev_tick: types.Tick = 0;
        for (tf.meeting_plan) |m| {
            try std.testing.expect(m.tick >= prev_tick);
            prev_tick = m.tick;
            try std.testing.expect(m.location.x >= 0 and m.location.x <= types.WorldMax);
            try std.testing.expect(m.location.y >= 0 and m.location.y <= types.WorldMax);
        }
        if (tf.meeting_plan.len > 0) {
            try std.testing.expect(tf.meeting_plan[tf.meeting_plan.len - 1].tick > 10);
        }
    }
}

test "taskforces have valid members and capabilities" {
    const allocator = std.testing.allocator;
    var taskforces = std.ArrayList(types.Taskforce).empty;
    defer {
        for (taskforces.items) |*tf| {
            allocator.free(tf.members);
            allocator.free(tf.required_capabilities);
            for (tf.meeting_plan) |m| {
                allocator.free(m.participants);
                allocator.free(m.trades);
            }
            allocator.free(tf.meeting_plan);
        }
        taskforces.deinit(allocator);
    }
    var event_log = std.ArrayList(types.EventRecord).empty;
    defer {
        event_log.deinit(allocator);
    }

    const orgs = [_]types.Organization{
        .{ .id = 0, .org_type = .TERRORIST, .members = &.{ 0, 1, 2, 3, 4, 5 } },
    };

    try plan(allocator, 99, 10, 10, &orgs, &.{}, &.{}, &taskforces, &event_log);

    for (taskforces.items) |tf| {
        try std.testing.expect(tf.members.len >= 1);
        try std.testing.expect(tf.required_capabilities.len >= 2);
        try std.testing.expect(tf.required_capabilities.len <= 4);
        try std.testing.expect(tf.status == .ACTIVE);
    }
}

test "planner creates no taskforces for empty orgs" {
    const allocator = std.testing.allocator;
    var taskforces = std.ArrayList(types.Taskforce).empty;
    defer {
        for (taskforces.items) |*tf| {
            allocator.free(tf.members);
            allocator.free(tf.required_capabilities);
            for (tf.meeting_plan) |m| {
                allocator.free(m.participants);
                allocator.free(m.trades);
            }
            allocator.free(tf.meeting_plan);
        }
        taskforces.deinit(allocator);
    }
    var event_log = std.ArrayList(types.EventRecord).empty;
    defer {
        event_log.deinit(allocator);
    }

    // Orgs with zero members.
    const orgs = [_]types.Organization{
        .{ .id = 0, .org_type = .TERRORIST, .members = &.{} },
        .{ .id = 1, .org_type = .BENIGN, .members = &.{} },
    };

    try plan(allocator, 42, 10, 10, &orgs, &.{}, &.{}, &taskforces, &event_log);

    try std.testing.expectEqual(@as(usize, 0), taskforces.items.len);
    try std.testing.expectEqual(@as(usize, 0), event_log.items.len);
}

test "generateMeetingTree creates trades for capabilities not held by members" {
    const allocator = std.testing.allocator;

    // ── Setup a scenario where trades are needed ──────────────────────
    // Org: {0, 1, 2, 3, 4}  (5 hats)
    // Taskforce members: {0, 1, 2} (hats 0, 1, 2)
    // Required capabilities: {2, 5}
    // Hat states:
    //   hat 0: cap 0 only
    //   hat 1: cap 1 only
    //   hat 2: none
    //   hat 3: cap 2 (non-taskforce member — can trade)
    //   hat 4: cap 5 (non-taskforce member — can trade)
    //
    // Expect: trades {source=3→recipient=0, cap=2}, {source=4→recipient=1, cap=5}
    //         at the first intermediate meeting.
    //         Participating hats in first intermediate meeting include 3 and 4.

    const org = types.Organization{
        .id = 0,
        .org_type = .TERRORIST,
        .members = try allocator.dupe(types.HatId, &.{ 0, 1, 2, 3, 4 }),
    };
    defer allocator.free(org.members);

    const members = try allocator.dupe(types.HatId, &.{ 0, 1, 2 });
    defer allocator.free(members);

    const req_caps = try allocator.dupe(types.CapabilityId, &.{ 2, 5 });
    defer allocator.free(req_caps);

    // Hat states with capabilities as described.
    var hat_state_list = std.ArrayList(types.HatState).empty;
    defer hat_state_list.deinit(allocator);
    // hat 0: cap 0
    try hat_state_list.append(allocator, .{ .current_location = .{ .x = 0, .y = 0 }, .capability_bits = (1 << 0) });
    // hat 1: cap 1
    try hat_state_list.append(allocator, .{ .current_location = .{ .x = 0, .y = 0 }, .capability_bits = (1 << 1) });
    // hat 2: none
    try hat_state_list.append(allocator, .{ .current_location = .{ .x = 0, .y = 0 }, .capability_bits = 0 });
    // hat 3: cap 2
    try hat_state_list.append(allocator, .{ .current_location = .{ .x = 0, .y = 0 }, .capability_bits = (1 << 2) });
    // hat 4: cap 5
    try hat_state_list.append(allocator, .{ .current_location = .{ .x = 0, .y = 0 }, .capability_bits = (1 << 5) });
    const hat_states = try hat_state_list.toOwnedSlice(allocator);
    defer allocator.free(hat_states);

    const meetings = try generateMeetingTree(
        allocator, 42, 0, 10, 3,
        types.Location{ .x = 30, .y = 30 },
        members,
        org,
        req_caps,
        hat_states,
    );
    defer {
        for (meetings) |m| {
            allocator.free(m.participants);
            allocator.free(m.trades);
        }
        allocator.free(meetings);
    }

    // At least 2 meetings: intermediate + root.
    try std.testing.expect(meetings.len >= 2);

    // ── Verify trades: look across all meetings for trades of cap 2 and cap 5 ──
    var found_cap2_trade = false;
    var found_cap5_trade = false;
    var found_hat3_participant = false;
    var found_hat4_participant = false;

    for (meetings, 0..) |m, midx| {
        // Check participants for trading hats.
        for (m.participants) |pid| {
            if (pid == 3) found_hat3_participant = true;
            if (pid == 4) found_hat4_participant = true;
        }

        for (m.trades) |t| {
            if (t.capability_id == 2 and t.source_hat_id == 3) {
                found_cap2_trade = true;
                // Recipient should be one of the taskforce members.
                const valid_recipient = t.recipient_hat_id == 0 or
                    t.recipient_hat_id == 1 or t.recipient_hat_id == 2;
                try std.testing.expect(valid_recipient);
            }
            if (t.capability_id == 5 and t.source_hat_id == 4) {
                found_cap5_trade = true;
                const valid_recipient = t.recipient_hat_id == 0 or
                    t.recipient_hat_id == 1 or t.recipient_hat_id == 2;
                try std.testing.expect(valid_recipient);
            }
        }

        // Trades should only be on one meeting (not the root or not duplicated).
        _ = midx;
    }

    try std.testing.expect(found_cap2_trade);
    try std.testing.expect(found_cap5_trade);
    // Trading hats 3 and 4 should be participants in at least one meeting.
    try std.testing.expect(found_hat3_participant);
    try std.testing.expect(found_hat4_participant);

    // ── Verify trades are NOT on the root meeting ─────────────────────
    // The root meeting is the last one. It should have empty trades
    // (trades should be on the first intermediate meeting).
    const root_meeting = meetings[meetings.len - 1];
    try std.testing.expectEqual(@as(usize, 0), root_meeting.trades.len);
    // Root meeting participants should be just the taskforce members.
    try std.testing.expectEqual(members.len, root_meeting.participants.len);
    for (root_meeting.participants, members) |p, m| {
        try std.testing.expectEqual(m, p);
    }
}

test "generateMeetingTree skips trades for capabilities already held" {
    const allocator = std.testing.allocator;

    // All taskforce members already have the required capabilities → no trades needed.
    const org = types.Organization{
        .id = 0,
        .org_type = .TERRORIST,
        .members = try allocator.dupe(types.HatId, &.{ 0, 1, 2 }),
    };
    defer allocator.free(org.members);

    const members = try allocator.dupe(types.HatId, &.{ 0, 1 });
    defer allocator.free(members);

    const req_caps = try allocator.dupe(types.CapabilityId, &.{ 3, 7 });
    defer allocator.free(req_caps);

    // Both taskforce members have both capabilities.
    var hat_state_list = std.ArrayList(types.HatState).empty;
    defer hat_state_list.deinit(allocator);
    try hat_state_list.append(allocator, .{ .current_location = .{ .x = 0, .y = 0 }, .capability_bits = (1 << 3) | (1 << 7) });
    try hat_state_list.append(allocator, .{ .current_location = .{ .x = 0, .y = 0 }, .capability_bits = (1 << 3) | (1 << 7) });
    try hat_state_list.append(allocator, .{ .current_location = .{ .x = 0, .y = 0 }, .capability_bits = 0 });
    const hat_states = try hat_state_list.toOwnedSlice(allocator);
    defer allocator.free(hat_states);

    const meetings = try generateMeetingTree(
        allocator, 42, 0, 10, 3,
        types.Location{ .x = 30, .y = 30 },
        members,
        org,
        req_caps,
        hat_states,
    );
    defer {
        for (meetings) |m| {
            allocator.free(m.participants);
            allocator.free(m.trades);
        }
        allocator.free(meetings);
    }

    // All meetings should have empty trades — no routing needed.
    for (meetings, 0..) |m, midx| {
        try std.testing.expectEqual(@as(usize, 0), m.trades.len);
        _ = midx;
    }
}

test "generateMeetingTree creates trades at root when no intermediate meetings" {
    const allocator = std.testing.allocator;

    // Single member taskforce → no intermediate meetings (travel_time=3,
    // group_size=3, but while loop condition: mid_tick < root_tick with
    // only one member won't split into intermediate groups).

    const org = types.Organization{
        .id = 0,
        .org_type = .TERRORIST,
        .members = try allocator.dupe(types.HatId, &.{ 0, 1 }),
    };
    defer allocator.free(org.members);

    const members = try allocator.dupe(types.HatId, &.{0});
    defer allocator.free(members);

    const req_caps = try allocator.dupe(types.CapabilityId, &.{4});
    defer allocator.free(req_caps);

    // Hat 0 has no caps, hat 1 (non-taskforce) has cap 4.
    var hat_state_list = std.ArrayList(types.HatState).empty;
    defer hat_state_list.deinit(allocator);
    try hat_state_list.append(allocator, .{ .current_location = .{ .x = 0, .y = 0 }, .capability_bits = 0 });
    try hat_state_list.append(allocator, .{ .current_location = .{ .x = 0, .y = 0 }, .capability_bits = (1 << 4) });
    const hat_states = try hat_state_list.toOwnedSlice(allocator);
    defer allocator.free(hat_states);

    // Single member at tick 10, travel_time=3:
    // root_tick = 13, mid_tick starts at 11
    // while loop: midx(0) < n_members(1) and mid_tick(11) < root_tick(13) → true
    // group_end = min(0+3, 1) = 1, group = members[0..1]
    // → one intermediate meeting at tick 11
    // So we need a smaller travel_time to avoid intermediate meetings.
    // With travel_time=1: root_tick = 11, mid_tick = 11, while loop condition fails
    // → no intermediate meetings.

    const meetings = try generateMeetingTree(
        allocator, 42, 0, 10, 1,
        types.Location{ .x = 30, .y = 30 },
        members,
        org,
        req_caps,
        hat_states,
    );
    defer {
        for (meetings) |m| {
            allocator.free(m.participants);
            allocator.free(m.trades);
        }
        allocator.free(meetings);
    }

    // Only one meeting (root) since travel_time=1.
    try std.testing.expectEqual(@as(usize, 1), meetings.len);

    const root = meetings[0];
    try std.testing.expectEqual(@as(types.Tick, 11), root.tick);

    // Trade for cap 4 should be on the root meeting (no intermediate exists).
    var found_trade = false;
    for (root.trades) |t| {
        if (t.capability_id == 4 and t.source_hat_id == 1 and t.recipient_hat_id == 0) {
            found_trade = true;
        }
    }
    try std.testing.expect(found_trade);
}

test "generateMeetingTree empty hat_states produces no trades" {
    const allocator = std.testing.allocator;

    // When hat_states is empty (e.g. from unit tests that don't set up
    // capability states) — no trades should be generated.
    const org = types.Organization{
        .id = 0,
        .org_type = .TERRORIST,
        .members = try allocator.dupe(types.HatId, &.{ 0, 1, 2 }),
    };
    defer allocator.free(org.members);

    const members = try allocator.dupe(types.HatId, &.{ 0, 1 });
    defer allocator.free(members);

    const req_caps = try allocator.dupe(types.CapabilityId, &.{ 0, 1 });
    defer allocator.free(req_caps);

    // Empty hat_states — all capability checks will be skipped (out of range).
    const hat_states: []const types.HatState = &.{};

    const meetings = try generateMeetingTree(
        allocator, 42, 0, 10, 3,
        types.Location{ .x = 30, .y = 30 },
        members,
        org,
        req_caps,
        hat_states,
    );
    defer {
        for (meetings) |m| {
            allocator.free(m.participants);
            allocator.free(m.trades);
        }
        allocator.free(meetings);
    }

    // All trades should be empty (no source can be found without hat_states).
    for (meetings) |m| {
        try std.testing.expectEqual(@as(usize, 0), m.trades.len);
    }
}
