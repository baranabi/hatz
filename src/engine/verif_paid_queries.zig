//! Ad-hoc verification: paid broker queries return real data + noise.
const std = @import("std");
const types = @import("types.zig");
const sim = @import("sim.zig");
const broker = @import("broker.zig");
const runs = @import("runs.zig");

fn newObject(allocator: std.mem.Allocator) !std.json.ObjectMap {
    return std.json.ObjectMap.init(allocator, &.{}, &.{});
}

fn putInt(obj: *std.json.ObjectMap, key: []const u8, value: i64) !void {
    try obj.put(std.testing.allocator, key, .{ .integer = value });
}

fn putFloat(obj: *std.json.ObjectMap, key: []const u8, value: f64) !void {
    try obj.put(std.testing.allocator, key, .{ .float = value });
}

fn advanceRun(registry: *runs.Runs, run_id: []const u8, allocator: std.mem.Allocator, n_ticks: u64) !void {
    _ = try sim.advance(registry, allocator, .{
        .runId = run_id,
        .numberOfTicks = n_ticks,
        .includeDefaultRequestResults = false,
    });
}

test "paid queries return real data + noise model applies" {
    const allocator = std.testing.allocator;
    var registry = runs.Runs.init(allocator);
    defer registry.deinit();

    const params = sim.SimParams{ .n_hats = 100, .n_benign_orgs = 3, .n_terrorist_orgs = 2, .planning_interval = 10 };
    const run = try registry.createRun(42, params);
    const run_id = run.run_id;

    // Advance so planner creates taskforces
    try advanceRun(&registry, run_id, allocator, 15);

    // 1) ib.capabilities — reads from hat_states
    {
        var args = try newObject(allocator);
        try putInt(&args, "hatId", 0);
        try putFloat(&args, "payment", 10.0);
        const resp = try broker.call(allocator, run, .{
            .runId = run_id, .analystId = "test",
            .method = "ib.capabilities", .args = .{ .object = args },
        });
        try std.testing.expectEqualStrings("ib.capabilities", resp.method);
        try std.testing.expect(resp.charged > 0);
        const caps = resp.result.object.get("capabilities").?.array;
        try std.testing.expect(caps.items.len > 0); // hat 0 should have some caps
        std.debug.print("  OK capabilities: {} caps, noisy={}\n", .{ caps.items.len, resp.metadata.noisy });
    }

    // 2) ib.last_location — reads hat_states
    {
        var args = try newObject(allocator);
        try putInt(&args, "hatId", 0);
        try putFloat(&args, "payment", 10.0);
        const resp = try broker.call(allocator, run, .{
            .runId = run_id, .analystId = "test",
            .method = "ib.last_location", .args = .{ .object = args },
        });
        try std.testing.expectEqualStrings("ib.last_location", resp.method);
        const loc = resp.result.object.get("location").?;
        if (loc != .null) {
            const x = loc.object.get("x").?.integer;
            const y = loc.object.get("y").?.integer;
            try std.testing.expect(x >= 0 and x <= 50);
            try std.testing.expect(y >= 0 and y <= 50);
        }
        std.debug.print("  OK last_location: location=({}), noisy={}\n", .{
            if (loc == .null) @as(i64, -1) else 0, resp.metadata.noisy,
        });
    }

    // 3) ib.meeting_times — scans taskforces
    {
        var args = try newObject(allocator);
        try putInt(&args, "hatId", 0);
        try putFloat(&args, "payment", 10.0);
        const resp = try broker.call(allocator, run, .{
            .runId = run_id, .analystId = "test",
            .method = "ib.meeting_times", .args = .{ .object = args },
        });
        try std.testing.expectEqualStrings("ib.meeting_times", resp.method);
        _ = resp.result.object.get("ticks").?.array;
        std.debug.print("  OK meeting_times: noisy={}\n", .{resp.metadata.noisy});
    }

    // 4) ib.meeting_location — scans taskforces
    {
        var args = try newObject(allocator);
        try putInt(&args, "hatId", 0);
        try putInt(&args, "tick", 0);
        try putFloat(&args, "payment", 10.0);
        const resp = try broker.call(allocator, run, .{
            .runId = run_id, .analystId = "test",
            .method = "ib.meeting_location", .args = .{ .object = args },
        });
        try std.testing.expectEqualStrings("ib.meeting_location", resp.method);
        std.debug.print("  OK meeting_location: noisy={}\n", .{resp.metadata.noisy});
    }

    // 5) ib.meeting_participants — scans taskforces
    {
        var loc_obj = try newObject(allocator);
        try putInt(&loc_obj, "x", 0);
        try putInt(&loc_obj, "y", 0);
        var args = try newObject(allocator);
        try putInt(&args, "tick", 0);
        try args.put(allocator, "location", .{ .object = loc_obj });
        try putFloat(&args, "payment", 10.0);
        const resp = try broker.call(allocator, run, .{
            .runId = run_id, .analystId = "test",
            .method = "ib.meeting_participants", .args = .{ .object = args },
        });
        try std.testing.expectEqualStrings("ib.meeting_participants", resp.method);
        std.debug.print("  OK meeting_participants: noisy={}\n", .{resp.metadata.noisy});
    }

    // 6) ib.meeting_trades — scans taskforces
    {
        var loc_obj = try newObject(allocator);
        try putInt(&loc_obj, "x", 0);
        try putInt(&loc_obj, "y", 0);
        var args = try newObject(allocator);
        try putInt(&args, "tick", 0);
        try args.put(allocator, "location", .{ .object = loc_obj });
        try putFloat(&args, "payment", 10.0);
        const resp = try broker.call(allocator, run, .{
            .runId = run_id, .analystId = "test",
            .method = "ib.meeting_trades", .args = .{ .object = args },
        });
        try std.testing.expectEqualStrings("ib.meeting_trades", resp.method);
        std.debug.print("  OK meeting_trades: noisy={}\n", .{resp.metadata.noisy});
    }

    // 7) Zero payment → noisy for sure
    {
        var args = try newObject(allocator);
        try putInt(&args, "hatId", 0);
        try putFloat(&args, "payment", 0.0);
        const resp = try broker.call(allocator, run, .{
            .runId = run_id, .analystId = "test",
            .method = "ib.capabilities", .args = .{ .object = args },
        });
        try std.testing.expect(resp.metadata.noisy);
        try std.testing.expectEqual(@as(usize, 0), resp.result.object.get("capabilities").?.array.items.len);
        std.debug.print("  OK zero_payment: noisy={}, caps empty\n", .{resp.metadata.noisy});
    }

    // 8) Unknown hat → empty capabilities (not noisy)
    {
        var args = try newObject(allocator);
        try putInt(&args, "hatId", 999);
        try putFloat(&args, "payment", 10.0);
        const resp = try broker.call(allocator, run, .{
            .runId = run_id, .analystId = "test",
            .method = "ib.capabilities", .args = .{ .object = args },
        });
        try std.testing.expect(!resp.metadata.noisy); // unknown hat isn't "noisy", just empty
        try std.testing.expectEqual(@as(usize, 0), resp.result.object.get("capabilities").?.array.items.len);
        std.debug.print("  OK unknown_hat: capabilities empty, noisy={}\n", .{resp.metadata.noisy});
    }

    // 9) Unknown hat → last_location null (not noisy)
    {
        var args = try newObject(allocator);
        try putInt(&args, "hatId", 999);
        try putFloat(&args, "payment", 10.0);
        const resp = try broker.call(allocator, run, .{
            .runId = run_id, .analystId = "test",
            .method = "ib.last_location", .args = .{ .object = args },
        });
        try std.testing.expect(!resp.metadata.noisy);
        try std.testing.expect(resp.result.object.get("location").? == .null);
        std.debug.print("  OK unknown_hat last_location: null, noisy={}\n", .{resp.metadata.noisy});
    }
}
