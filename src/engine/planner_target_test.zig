//! Diagnostic test: verify planner targets match beacon locations for seed=42.
//! This is a standalone test that can be run with `zig test` or via `zig build test`.
const std = @import("std");
const types = @import("types.zig");
const sim = @import("sim.zig");
const runs = @import("runs.zig");
const planner = @import("planner.zig");
const broker = @import("broker.zig");
const json_util = @import("json_util.zig");

test "deterministicBeaconLocation produces expected values for seed=42" {
    const expected = [_]types.Location{
        .{ .x = 38, .y = 39 },
        .{ .x = 15, .y = 36 },
        .{ .x = 30, .y = 21 },
        .{ .x = 23, .y = 43 },
        .{ .x = 33, .y = 11 },
    };
    for (expected, 0..) |exp, i| {
        const loc = types.deterministicBeaconLocation(42, @intCast(i));
        try std.testing.expectEqual(exp.x, loc.x);
        try std.testing.expectEqual(exp.y, loc.y);
    }
}

test "run.beacons locations match deterministicBeaconLocation for seed=42" {
    const allocator = std.testing.allocator;

    var registry = runs.Runs.init(allocator);
    defer registry.deinit();

    const run = try registry.createRun(42, sim.SimParams{});

    // Verify each beacon location matches the deterministic computation.
    for (run.beacons, 0..) |beacon, i| {
        const expected = types.deterministicBeaconLocation(42, @intCast(i));
        try std.testing.expectEqual(expected.x, beacon.location.x);
        try std.testing.expectEqual(expected.y, beacon.location.y);
    }
}

test "planner targets match beacon locations for seed=42 after advance" {
    const allocator = std.testing.allocator;

    var registry = runs.Runs.init(allocator);
    defer registry.deinit();

    const run = try registry.createRun(42, sim.SimParams{
        .n_hats = 200,
        .n_benign_orgs = 3,
        .n_terrorist_orgs = 2,
        .planning_interval = 10,
    });

    // Advance 100 ticks (same as reproducer script).
    _ = try sim.advance(&registry, allocator, .{
        .runId = run.run_id,
        .numberOfTicks = 100,
        .includeDefaultRequestResults = false,
    });

    // Collect beacon locations.
    var beacon_locs: [sim.beacon_count]types.Location = undefined;
    for (run.beacons, 0..) |beacon, i| {
        beacon_locs[i] = beacon.location;
    }

    // Count how many taskforces have targets matching beacon locations.
    var terror_tfs: usize = 0;
    var beacon_matches: usize = 0;
    var benign_tfs: usize = 0;

    for (run.taskforces.items) |tf| {
        const org = run.organizations[tf.organization_id];
        if (org.org_type == .TERRORIST) {
            terror_tfs += 1;
            // Check if target matches any beacon location.
            var matches_beacon = false;
            for (beacon_locs) |bl| {
                if (tf.target.x == bl.x and tf.target.y == bl.y) {
                    matches_beacon = true;
                    break;
                }
            }
            if (matches_beacon) beacon_matches += 1;
        } else {
            benign_tfs += 1;
        }
    }

    // There must be at least one TERRORIST taskforce whose target
    // matches a beacon location.
    try std.testing.expect(beacon_matches >= 1);
}

test "broker ib.beacons returns same locations as run.beacons" {
    const allocator = std.testing.allocator;

    var registry = runs.Runs.init(allocator);
    defer registry.deinit();

    const run = try registry.createRun(42, sim.SimParams{});

    // Simulate a broker call to ib.beacons.
    const broker_resp = try broker.call(allocator, run, .{
        .runId = run.run_id,
        .analystId = "test",
        .method = "ib.beacons",
        .args = .{ .null = {} },
    });

    const result = broker_resp.result;
    try std.testing.expect(result == .object);

    const beacons_arr = result.object.get("beacons").?;
    try std.testing.expect(beacons_arr == .array);

    for (beacons_arr.array.items, 0..) |item, i| {
        const loc_obj = item.object.get("location").?.object;
        const bx = @as(i32, @intCast(loc_obj.get("x").?.integer));
        const by = @as(i32, @intCast(loc_obj.get("y").?.integer));
        const expected = run.beacons[i].location;
        try std.testing.expectEqual(expected.x, bx);
        try std.testing.expectEqual(expected.y, by);
    }

    // Verify the locations match deterministicBeaconLocation.
    for (beacons_arr.array.items, 0..) |item, i| {
        const loc_obj = item.object.get("location").?.object;
        const bx = @as(i32, @intCast(loc_obj.get("x").?.integer));
        const by = @as(i32, @intCast(loc_obj.get("y").?.integer));
        const expected = types.deterministicBeaconLocation(42, @intCast(i));
        try std.testing.expectEqual(expected.x, bx);
        try std.testing.expectEqual(expected.y, by);
    }
}
