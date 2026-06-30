//! Organization planner: generative meeting trees for taskforces.
//!
//! Per organization, every planning_interval ticks, there is a 50% chance
//! to create a new taskforce with a deterministic meeting tree that routes
//! selected members toward a target location. Both terrorist and benign orgs
//! use the same planner logic.
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
    taskforces: *std.ArrayList(types.Taskforce),
    event_log: *std.ArrayList(types.EventRecord),
) !void {
    if (interval == 0 or tick % interval != 0) return;

    for (organizations) |org| {
        try planForOrg(allocator, seed, org, tick, beacons, taskforces, event_log);
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

    // 5. Capabilities routable among hats — stub: always OK (skip real routing check).

    // 6. Generate meeting tree.
    const travel_time: types.Tick = 3 + (org_mix >> 40) % 3; // 3–5 ticks
    const meetings = try generateMeetingTree(allocator, seed, org.id, tick, travel_time, target, members);

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
/// Meetings are returned sorted by tick (non-decreasing).
fn generateMeetingTree(
    allocator: std.mem.Allocator,
    seed: u64,
    org_id: types.OrganizationId,
    current_tick: types.Tick,
    travel_time: types.Tick,
    target: types.Location,
    members: []const types.HatId,
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

    // Intermediate meetings: groups of up to 3 members meet at intermediate
    // locations that progress toward the target.
    const group_size: usize = 3;
    var midx: usize = 0;
    var mid_tick = current_tick + 1;

    const tree_mix = types.mix(seed ^ (@as(u64, org_id) *% 0x9E3779B97F4A7C15) ^ (@as(u64, current_tick) *% 0xBF58476D1CE4E5B9));

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

        try meetings.append(allocator, types.Meeting{
            .tick = mid_tick,
            .location = loc,
            .participants = try allocator.dupe(types.HatId, group),
            .trades = &.{},
        });

        midx = group_end;
        mid_tick += 1;
    }

    // Root meeting at target — all members.
    try meetings.append(allocator, types.Meeting{
        .tick = root_tick,
        .location = target,
        .participants = try allocator.dupe(types.HatId, members),
        .trades = &.{},
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
    try plan(allocator, 42, 10, 1, &orgs, &.{}, &taskforces, &event_log);
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
        for (event_log.items) |*ev| {
            allocator.free(ev.type);
        }
        event_log.deinit(allocator);
    }

    const orgs = [_]types.Organization{
        .{ .id = 0, .org_type = .TERRORIST, .members = &.{ 0, 1, 2, 3, 4 } },
        .{ .id = 1, .org_type = .BENIGN, .members = &.{ 5, 6, 7, 8, 9 } },
    };

    // Tick 10 with interval 10 → planning tick (50% chance per org).
    try plan(allocator, 42, 10, 10, &orgs, &.{}, &taskforces, &event_log);
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
        for (event_log.items) |*ev| {
            allocator.free(ev.type);
        }
        event_log.deinit(allocator);
    }

    const orgs = [_]types.Organization{
        .{ .id = 0, .org_type = .TERRORIST, .members = &.{ 0, 1, 2, 3, 4, 5 } },
        .{ .id = 1, .org_type = .BENIGN, .members = &.{ 6, 7, 8 } },
    };

    try plan(allocator, 12345, 10, 10, &orgs, &.{}, &taskforces, &event_log);

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
        for (event_log.items) |*ev| {
            allocator.free(ev.type);
        }
        event_log.deinit(allocator);
    }

    const orgs = [_]types.Organization{
        .{ .id = 0, .org_type = .TERRORIST, .members = &.{ 0, 1, 2, 3, 4, 5 } },
    };

    try plan(allocator, 99, 10, 10, &orgs, &.{}, &taskforces, &event_log);

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
        for (event_log.items) |*ev| {
            allocator.free(ev.type);
        }
        event_log.deinit(allocator);
    }

    // Orgs with zero members.
    const orgs = [_]types.Organization{
        .{ .id = 0, .org_type = .TERRORIST, .members = &.{} },
        .{ .id = 1, .org_type = .BENIGN, .members = &.{} },
    };

    try plan(allocator, 42, 10, 10, &orgs, &.{}, &taskforces, &event_log);

    try std.testing.expectEqual(@as(usize, 0), taskforces.items.len);
    try std.testing.expectEqual(@as(usize, 0), event_log.items.len);
}
