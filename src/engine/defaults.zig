//! Per-analyst default Information Broker request storage.
const std = @import("std");
const types = @import("types.zig");
const protocol = @import("protocol.zig");
const sim = @import("sim.zig");
const json_util = @import("json_util.zig");

pub const DefaultsAddRequestPayload = struct {
    runId: types.RunId,
    analystId: types.AnalystId,
    requests: []const protocol.DefaultIbRequest,
};

pub const DefaultsRemoveRequestPayload = struct {
    runId: types.RunId,
    analystId: types.AnalystId,
    requests: []const protocol.DefaultIbRequest,
};

pub const DefaultsClearRequestPayload = struct {
    runId: types.RunId,
    analystId: types.AnalystId,
};

pub const DefaultsListRequestPayload = struct {
    runId: types.RunId,
    analystId: types.AnalystId,
};

pub const DefaultsMutationResponsePayload = struct {
    totalDefaults: u64,
};

pub const DefaultsListResponsePayload = struct {
    requests: []protocol.DefaultIbRequest,
};

/// Add default broker requests for an analyst.
/// Requests are stored as JSON to preserve exact args for later comparison.
pub fn add(allocator: std.mem.Allocator, run: *sim.RunState, payload: DefaultsAddRequestPayload) !DefaultsMutationResponsePayload {
    _ = allocator;
    var analyst = try getOrCreateAnalyst(run, payload.analystId);
    for (payload.requests) |request| {
        const stored = try storeRequest(run.allocator, request);
        try analyst.defaults.append(run.allocator, stored);
    }
    return DefaultsMutationResponsePayload{ .totalDefaults = @intCast(analyst.defaults.items.len) };
}

/// Remove matching default requests for an analyst.
/// Comparison is done on method and serialized args for exactness.
pub fn remove(run: *sim.RunState, payload: DefaultsRemoveRequestPayload) !DefaultsMutationResponsePayload {
    var analyst = try getOrCreateAnalyst(run, payload.analystId);
    for (payload.requests) |request| {
        const args_json = try json_util.stringifyAlloc(run.allocator, request.args);
        defer run.allocator.free(args_json);
        var idx: usize = 0;
        while (idx < analyst.defaults.items.len) {
            const item = analyst.defaults.items[idx];
            if (std.mem.eql(u8, item.method, request.method) and std.mem.eql(u8, item.args_json, args_json)) {
                freeStoredRequest(run.allocator, item);
                _ = analyst.defaults.swapRemove(idx);
            } else {
                idx += 1;
            }
        }
    }
    return DefaultsMutationResponsePayload{ .totalDefaults = @intCast(analyst.defaults.items.len) };
}

/// Remove all defaults for an analyst.
/// This frees stored request allocations and resets the list.
pub fn clear(run: *sim.RunState, payload: DefaultsClearRequestPayload) !DefaultsMutationResponsePayload {
    var analyst = try getOrCreateAnalyst(run, payload.analystId);
    for (analyst.defaults.items) |item| {
        freeStoredRequest(run.allocator, item);
    }
    analyst.defaults.clearRetainingCapacity();
    return DefaultsMutationResponsePayload{ .totalDefaults = 0 };
}

/// List the currently stored defaults, decoding args back into JSON values.
/// A separate allocator is used so the caller owns the decoded values.
pub fn list(allocator: std.mem.Allocator, run: *sim.RunState, payload: DefaultsListRequestPayload) !DefaultsListResponsePayload {
    const analyst = try getOrCreateAnalyst(run, payload.analystId);
    var out: std.ArrayList(protocol.DefaultIbRequest) = .empty;
    for (analyst.defaults.items) |stored| {
        const args_value = try json_util.parseJsonValue(allocator, stored.args_json);
        try out.append(allocator, protocol.DefaultIbRequest{
            .method = stored.method,
            .args = args_value,
        });
    }
    return DefaultsListResponsePayload{ .requests = try out.toOwnedSlice(allocator) };
}

/// Fetch the stored defaults for a given analyst, or an empty slice.
/// This is used by sim.advance to run polling requests.
pub fn getDefaults(run: *sim.RunState, analyst_id: []const u8) []const sim.DefaultIbRequestStored {
    if (run.analyst_states.getPtr(analyst_id)) |state| {
        return state.defaults.items;
    }
    return &[_]sim.DefaultIbRequestStored{};
}

/// Return an existing analyst state or create a new one.
/// The analyst_id string is duplicated into run-owned storage.
fn getOrCreateAnalyst(run: *sim.RunState, analyst_id: []const u8) !*sim.AnalystState {
    if (run.analyst_states.getPtr(analyst_id)) |state| {
        return state;
    }
    const analyst_key = try run.allocator.dupe(u8, analyst_id);
    const state = sim.AnalystState.init(run.allocator, analyst_key);
    try run.analyst_states.put(analyst_key, state);
    return run.analyst_states.getPtr(analyst_key).?;
}

/// Persist a default request with owned strings and serialized args.
fn storeRequest(allocator: std.mem.Allocator, request: protocol.DefaultIbRequest) !sim.DefaultIbRequestStored {
    const method_copy = try allocator.dupe(u8, request.method);
    const args_json = try json_util.stringifyAlloc(allocator, request.args);
    return sim.DefaultIbRequestStored{
        .method = method_copy,
        .args_json = args_json,
    };
}

/// Free the allocations owned by a stored default request.
fn freeStoredRequest(allocator: std.mem.Allocator, request: sim.DefaultIbRequestStored) void {
    allocator.free(request.method);
    allocator.free(request.args_json);
}

// parseArgsValue moved to json_util.parseJsonValue

// ── Tests ──────────────────────────────────────────────────────────

test "defaults.add stores requests and returns correct count" {
    const allocator = std.testing.allocator;
    var registry = sim.initForTesting(allocator);
    defer registry.deinit();
    const run = try registry.createRun(42, sim.SimParams{ .n_hats = 10 });
    const resp = try add(allocator, run, .{
        .runId = run.run_id,
        .analystId = "analyst-1",
        .requests = &.{
            protocol.DefaultIbRequest{ .method = "ib.capabilities", .args = std.json.Value{ .null = {} } },
            protocol.DefaultIbRequest{ .method = "ib.last_location", .args = std.json.Value{ .null = {} } },
        },
    });
    try std.testing.expectEqual(@as(u64, 2), resp.totalDefaults);
}

test "defaults.add twice accumulates and list returns them" {
    const allocator = std.testing.allocator;
    var registry = sim.initForTesting(allocator);
    defer registry.deinit();
    const run = try registry.createRun(42, sim.SimParams{ .n_hats = 10 });
    _ = try add(allocator, run, .{
        .runId = run.run_id, .analystId = "analyst-1",
        .requests = &.{protocol.DefaultIbRequest{ .method = "ib.capabilities", .args = std.json.Value{ .null = {} } }},
    });
    _ = try add(allocator, run, .{
        .runId = run.run_id, .analystId = "analyst-1",
        .requests = &.{protocol.DefaultIbRequest{ .method = "ib.last_location", .args = std.json.Value{ .null = {} } }},
    });
    const list_resp = try list(allocator, run, .{ .runId = run.run_id, .analystId = "analyst-1" });
    defer {
        for (list_resp.requests) |r| json_util.jsonValueDeinit(allocator, &r.args);
        allocator.free(list_resp.requests);
    }
    try std.testing.expectEqual(@as(usize, 2), list_resp.requests.len);
    try std.testing.expectEqualStrings("ib.capabilities", list_resp.requests[0].method);
    try std.testing.expectEqualStrings("ib.last_location", list_resp.requests[1].method);
}

test "defaults.list returns empty for analyst with no defaults" {
    const allocator = std.testing.allocator;
    var registry = sim.initForTesting(allocator);
    defer registry.deinit();
    const run = try registry.createRun(42, sim.SimParams{ .n_hats = 10 });
    const list_resp = try list(allocator, run, .{ .runId = run.run_id, .analystId = "empty-analyst" });
    defer allocator.free(list_resp.requests);
    try std.testing.expectEqual(@as(usize, 0), list_resp.requests.len);
}

test "defaults.remove removes matching request" {
    const allocator = std.testing.allocator;
    var registry = sim.initForTesting(allocator);
    defer registry.deinit();
    const run = try registry.createRun(42, sim.SimParams{ .n_hats = 10 });
    _ = try add(allocator, run, .{
        .runId = run.run_id, .analystId = "analyst-1",
        .requests = &.{
            protocol.DefaultIbRequest{ .method = "ib.capabilities", .args = std.json.Value{ .null = {} } },
            protocol.DefaultIbRequest{ .method = "ib.last_location", .args = std.json.Value{ .null = {} } },
        },
    });
    const remove_resp = try remove(run, .{
        .runId = run.run_id, .analystId = "analyst-1",
        .requests = &.{protocol.DefaultIbRequest{ .method = "ib.capabilities", .args = std.json.Value{ .null = {} } }},
    });
    try std.testing.expectEqual(@as(u64, 1), remove_resp.totalDefaults);
    const list_resp = try list(allocator, run, .{ .runId = run.run_id, .analystId = "analyst-1" });
    defer {
        for (list_resp.requests) |r| json_util.jsonValueDeinit(allocator, &r.args);
        allocator.free(list_resp.requests);
    }
    try std.testing.expectEqual(@as(usize, 1), list_resp.requests.len);
    try std.testing.expectEqualStrings("ib.last_location", list_resp.requests[0].method);
}

test "defaults.clear removes all defaults for analyst" {
    const allocator = std.testing.allocator;
    var registry = sim.initForTesting(allocator);
    defer registry.deinit();
    const run = try registry.createRun(42, sim.SimParams{ .n_hats = 10 });
    _ = try add(allocator, run, .{
        .runId = run.run_id, .analystId = "analyst-1",
        .requests = &.{
            protocol.DefaultIbRequest{ .method = "ib.capabilities", .args = std.json.Value{ .null = {} } },
            protocol.DefaultIbRequest{ .method = "ib.last_location", .args = std.json.Value{ .null = {} } },
        },
    });
    const clear_resp = try clear(run, .{ .runId = run.run_id, .analystId = "analyst-1" });
    try std.testing.expectEqual(@as(u64, 0), clear_resp.totalDefaults);
    const list_resp = try list(allocator, run, .{ .runId = run.run_id, .analystId = "analyst-1" });
    defer allocator.free(list_resp.requests);
    try std.testing.expectEqual(@as(usize, 0), list_resp.requests.len);
}

test "defaults.getDefaults returns empty slice for unknown analyst" {
    const allocator = std.testing.allocator;
    var registry = sim.initForTesting(allocator);
    defer registry.deinit();
    const run = try registry.createRun(42, sim.SimParams{ .n_hats = 10 });
    const stored = getDefaults(run, "unknown-analyst");
    try std.testing.expectEqual(@as(usize, 0), stored.len);
}

test "defaults.add with no requests returns zero" {
    const allocator = std.testing.allocator;
    var registry = sim.initForTesting(allocator);
    defer registry.deinit();
    const run = try registry.createRun(42, sim.SimParams{ .n_hats = 10 });
    const resp = try add(allocator, run, .{
        .runId = run.run_id, .analystId = "analyst-1", .requests = &.{},
    });
    try std.testing.expectEqual(@as(u64, 0), resp.totalDefaults);
}
