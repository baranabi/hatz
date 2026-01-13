//! Minimal CLI harness to exercise the stub engine end-to-end.
const std = @import("std");
const sim = @import("sim.zig");
const runs = @import("runs.zig");
const broker = @import("broker.zig");
const defaults = @import("defaults.zig");
const actions = @import("actions.zig");
const protocol = @import("protocol.zig");
const types = @import("types.zig");
const json_util = @import("json_util.zig");

/// Entry point for the engine demo harness.
pub fn main() !void {
    try runDemo();
}

/// Execute a small end-to-end demo of the engine APIs.
/// This exercises initialize, defaults, advance, broker calls, and actions.
pub fn runDemo() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var registry = runs.Runs.init(allocator);
    defer registry.deinit();

    const params_value = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
    const init_payload = sim.SimInitializeRequestPayload{
        .seed = 1234,
        .params = params_value,
    };
    const init_resp = try sim.initialize(&registry, allocator, init_payload);
    try printJson(init_resp);

    const run = registry.get(init_resp.runId).?;
    const empty_args = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
    const default_requests = [_]protocol.DefaultIbRequest{
        .{ .method = "ib.beacons", .args = empty_args },
    };
    const defaults_payload = defaults.DefaultsAddRequestPayload{
        .runId = init_resp.runId,
        .analystId = "human",
        .requests = default_requests[0..],
    };
    const defaults_resp = try defaults.add(allocator, run, defaults_payload);
    try printJson(defaults_resp);

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const advance_resp = try sim.advance(&registry, arena.allocator(), .{
            .runId = init_resp.runId,
            .numberOfTicks = 3,
            .timeIt = true,
            .includeDefaultRequestResults = true,
        });
        try printJson(advance_resp);
    }

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const broker_args = try jsonObject(arena.allocator(), &.{
            .{ .key = "hatId", .value = std.json.Value{ .integer = 14 } },
            .{ .key = "payment", .value = std.json.Value{ .float = 5.0 } },
        });
        const broker_resp = try broker.call(arena.allocator(), run, .{
            .runId = init_resp.runId,
            .analystId = "human",
            .method = "ib.last_location",
            .args = broker_args,
        });
        try printJson(broker_resp);
    }

    const alert_resp = try actions.alertBeacon(run, .{
        .runId = init_resp.runId,
        .analystId = "human",
        .beaconId = 1,
        .alertLevel = .LEVEL_ONE,
    });
    try printJson(alert_resp);

    const expected_loc = types.deterministicLocation(run.seed, run.tick, 14);
    const arrest_resp = try actions.arrestHat(run, .{
        .runId = init_resp.runId,
        .analystId = "human",
        .hatId = 14,
        .location = expected_loc,
    });
    try printJson(arrest_resp);
}

/// Build a JSON object value from key/value pairs.
/// This is a small helper for constructing broker args.
fn jsonObject(allocator: std.mem.Allocator, fields: []const struct { key: []const u8, value: std.json.Value }) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    for (fields) |field| {
        try obj.put(field.key, field.value);
    }
    return std.json.Value{ .object = obj };
}

/// Serialize a value to JSON and write it to stdout.
fn printJson(value: anytype) !void {
    const json_text = try json_util.stringifyAlloc(std.heap.page_allocator, value);
    defer std.heap.page_allocator.free(json_text);
    try std.fs.File.stdout().writeAll(json_text);
    try std.fs.File.stdout().writeAll("\n");
}
