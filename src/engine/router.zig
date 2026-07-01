//! Dispatches contract envelope requests to the stub engine handlers.
const std = @import("std");
const protocol = @import("protocol.zig");
const sim = @import("sim.zig");
const defaults = @import("defaults.zig");
const broker = @import("broker.zig");
const actions = @import("actions.zig");
const runs = @import("runs.zig");
const json_util = @import("json_util.zig");
const types = @import("types.zig");

/// Route an envelope request to the appropriate engine handler.
/// This keeps a single code path for CLI, daemon, and fixture replay.
pub fn dispatch(registry: *runs.Runs, allocator: std.mem.Allocator, request: protocol.EnvelopeRequest) !protocol.EnvelopeResponse {
    if (std.mem.eql(u8, request.type, "sim.initialize")) {
        const json_text = try json_util.stringifyAlloc(allocator, request.payload);
        defer allocator.free(json_text);
        var parsed = try std.json.parseFromSlice(sim.SimInitializeRequestPayload, allocator, json_text, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const response = try sim.initialize(registry, parsed.value);
        return okResponse(allocator, request, response);
    }
    if (std.mem.eql(u8, request.type, "sim.advance")) {
        const json_text = try json_util.stringifyAlloc(allocator, request.payload);
        defer allocator.free(json_text);
        var parsed = try std.json.parseFromSlice(sim.SimAdvanceRequestPayload, allocator, json_text, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const response = try sim.advance(registry, allocator, parsed.value);
        return okResponse(allocator, request, response);
    }
    if (std.mem.eql(u8, request.type, "sim.end")) {
        const json_text = try json_util.stringifyAlloc(allocator, request.payload);
        defer allocator.free(json_text);
        var parsed = try std.json.parseFromSlice(sim.SimEndRequestPayload, allocator, json_text, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const response = try sim.end(registry, allocator, parsed.value);
        return okResponse(allocator, request, response);
    }
    if (std.mem.eql(u8, request.type, "defaults.add")) {
        const json_text = try json_util.stringifyAlloc(allocator, request.payload);
        defer allocator.free(json_text);
        var parsed = try std.json.parseFromSlice(defaults.DefaultsAddRequestPayload, allocator, json_text, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const run = registry.get(parsed.value.runId) orelse return error.RunNotFound;
        const response = try defaults.add(allocator, run, parsed.value);
        return okResponse(allocator, request, response);
    }
    if (std.mem.eql(u8, request.type, "defaults.remove")) {
        const json_text = try json_util.stringifyAlloc(allocator, request.payload);
        defer allocator.free(json_text);
        var parsed = try std.json.parseFromSlice(defaults.DefaultsRemoveRequestPayload, allocator, json_text, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const run = registry.get(parsed.value.runId) orelse return error.RunNotFound;
        const response = try defaults.remove(run, parsed.value);
        return okResponse(allocator, request, response);
    }
    if (std.mem.eql(u8, request.type, "defaults.clear")) {
        const json_text = try json_util.stringifyAlloc(allocator, request.payload);
        defer allocator.free(json_text);
        var parsed = try std.json.parseFromSlice(defaults.DefaultsClearRequestPayload, allocator, json_text, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const run = registry.get(parsed.value.runId) orelse return error.RunNotFound;
        const response = try defaults.clear(run, parsed.value);
        return okResponse(allocator, request, response);
    }
    if (std.mem.eql(u8, request.type, "defaults.list")) {
        const json_text = try json_util.stringifyAlloc(allocator, request.payload);
        defer allocator.free(json_text);
        var parsed = try std.json.parseFromSlice(defaults.DefaultsListRequestPayload, allocator, json_text, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const run = registry.get(parsed.value.runId) orelse return error.RunNotFound;
        const response = try defaults.list(allocator, run, parsed.value);
        return okResponse(allocator, request, response);
    }
    if (std.mem.eql(u8, request.type, "broker.call")) {
        const json_text = try json_util.stringifyAlloc(allocator, request.payload);
        defer allocator.free(json_text);
        var parsed = try std.json.parseFromSlice(broker.BrokerCallRequestPayload, allocator, json_text, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const run = registry.get(parsed.value.runId) orelse return error.RunNotFound;
        var response = try broker.call(allocator, run, parsed.value);
        defer json_util.jsonValueDeinit(allocator, &response.result);
        return okResponse(allocator, request, response);
    }
    if (std.mem.eql(u8, request.type, "action.alert_beacon")) {
        const json_text = try json_util.stringifyAlloc(allocator, request.payload);
        defer allocator.free(json_text);
        var parsed = try std.json.parseFromSlice(actions.ActionAlertBeaconRequestPayload, allocator, json_text, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const run = registry.get(parsed.value.runId) orelse return error.RunNotFound;
        const response = try actions.alertBeacon(run, parsed.value);
        return okResponse(allocator, request, response);
    }
    if (std.mem.eql(u8, request.type, "action.arrest_hat")) {
        const json_text = try json_util.stringifyAlloc(allocator, request.payload);
        defer allocator.free(json_text);
        var parsed = try std.json.parseFromSlice(actions.ActionArrestHatRequestPayload, allocator, json_text, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const run = registry.get(parsed.value.runId) orelse return error.RunNotFound;
        const response = try actions.arrestHat(run, parsed.value);
        return okResponse(allocator, request, response);
    }
    return error.UnknownRequestType;
}

/// Convert a dynamic JSON value into a typed payload by re-stringifying.
/// This avoids re-implementing JSON decoding for every message shape.
/// The returned value owns its allocations — free them via `std.json.parseFree(T, value, allocator)` if T has allocated fields.
/// NOTE: parsePayload uses parseFromSliceLeaky, so memory leaks on every call.
/// Prefer inlining parseFromSlice + defer parsed.deinit() in the caller instead.
pub fn parsePayload(comptime T: type, allocator: std.mem.Allocator, value: std.json.Value) !T {
    const json_text = try json_util.stringifyAlloc(allocator, value);
    defer allocator.free(json_text);
    const parsed = try std.json.parseFromSliceLeaky(T, allocator, json_text, .{ .allocate = .alloc_always });
    return parsed;
}

/// Wrap a typed payload into a success EnvelopeResponse value.
/// The requestId is preserved for end-to-end correlation.
pub fn okResponseValue(allocator: std.mem.Allocator, request: protocol.EnvelopeRequest, payload: anytype) !std.json.Value {
    const payload_value = try valueFromStruct(allocator, payload);
    return std.json.Value{ .object = try okResponseObject(allocator, request, payload_value) };
}

fn okResponse(allocator: std.mem.Allocator, request: protocol.EnvelopeRequest, payload: anytype) !protocol.EnvelopeResponse {
    const payload_value = try valueFromStruct(allocator, payload);
    return protocol.EnvelopeResponse{
        .contractVersion = request.contractVersion,
        .ok = true,
        .payload = payload_value,
        .@"error" = null,
        .requestId = request.requestId,
    };
}

fn okResponseObject(allocator: std.mem.Allocator, request: protocol.EnvelopeRequest, payload_value: std.json.Value) !std.json.ObjectMap {
    var obj = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try obj.put(allocator, "contractVersion", std.json.Value{ .string = request.contractVersion });
    try obj.put(allocator, "ok", std.json.Value{ .bool = true });
    try obj.put(allocator, "payload", payload_value);
    if (request.requestId) |rid| {
        try obj.put(allocator, "requestId", std.json.Value{ .string = rid });
    }
    return obj;
}

/// Convert a typed response payload into a dynamic JSON value.
/// This keeps the router independent of schema-specific JSON builders.
/// Caller owns the returned std.json.Value and **must** call `json_util.jsonValueDeinit(allocator, &value)` when done.
pub fn valueFromStruct(allocator: std.mem.Allocator, value: anytype) !std.json.Value {
    const json_text = try json_util.stringifyAlloc(allocator, value);
    defer allocator.free(json_text);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    return try json_util.jsonValueClone(allocator, &parsed.value);
}

// ── Tests ──────────────────────────────────────────────────────────

/// Free allocations owned by an EnvelopeResponse (payload and error fields).
fn cleanResponse(allocator: std.mem.Allocator, resp: *protocol.EnvelopeResponse) void {
    if (resp.payload) |*p| {
        json_util.jsonValueDeinit(allocator, p);
    }
    if (resp.@"error") |*e| {
        allocator.free(@constCast(e.code));
        allocator.free(@constCast(e.message));
        if (e.details) |d| {
            json_util.jsonValueDeinit(allocator, &d);
        }
    }
}

test "dispatch: unknown type returns UnknownRequestType error" {
    const allocator = std.testing.allocator;
    var registry = runs.Runs.init(allocator);
    defer registry.deinit();

    try std.testing.expectError(error.UnknownRequestType, dispatch(&registry, allocator, .{
        .contractVersion = "1.0", .type = "nonexistent.operation",
        .payload = std.json.Value{ .null = {} }, .requestId = null,
    }));
}

test "dispatch: sim.initialize returns ok with runId" {
    const allocator = std.testing.allocator;
    var registry = runs.Runs.init(allocator);
    defer registry.deinit();

    var empty_params = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer empty_params.deinit(allocator);
    const init_payload = try valueFromStruct(allocator, sim.SimInitializeRequestPayload{
        .seed = 42,
        .params = std.json.Value{ .object = empty_params },
    });
    var resp = try dispatch(&registry, allocator, .{
        .contractVersion = "1.0", .type = "sim.initialize",
        .payload = init_payload, .requestId = null,
    });
    defer cleanResponse(allocator, &resp);
    json_util.jsonValueDeinit(allocator, &init_payload);

    try std.testing.expect(resp.ok);
    try std.testing.expect(resp.payload != null);
    try std.testing.expect(resp.payload.?.object.get("runId") != null);
}

test "dispatch: defaults.add with missing run returns RunNotFound error" {
    const allocator = std.testing.allocator;
    var registry = runs.Runs.init(allocator);
    defer registry.deinit();

    const add_payload = try valueFromStruct(allocator, defaults.DefaultsAddRequestPayload{
        .runId = "nonexistent",
        .analystId = "analyst-1",
        .requests = &.{},
    });
    defer json_util.jsonValueDeinit(allocator, &add_payload);

    try std.testing.expectError(error.RunNotFound, dispatch(&registry, allocator, .{
        .contractVersion = "1.0", .type = "defaults.add",
        .payload = add_payload, .requestId = null,
    }));
}

test "dispatch: sim.advance advances tick and returns response" {
    const allocator = std.testing.allocator;
    var registry = runs.Runs.init(allocator);
    defer registry.deinit();

    var empty_params = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer empty_params.deinit(allocator);
    const init_payload = try valueFromStruct(allocator, sim.SimInitializeRequestPayload{
        .seed = 42,
        .params = std.json.Value{ .object = empty_params },
    });
    var init_resp = try dispatch(&registry, allocator, .{
        .contractVersion = "1.0", .type = "sim.initialize",
        .payload = init_payload, .requestId = null,
    });
    defer cleanResponse(allocator, &init_resp);
    json_util.jsonValueDeinit(allocator, &init_payload);
    const run_id = init_resp.payload.?.object.get("runId").?.string;

    const adv_payload = try valueFromStruct(allocator, sim.SimAdvanceRequestPayload{
        .runId = run_id, .numberOfTicks = 5, .includeDefaultRequestResults = false,
    });
    var adv_resp = try dispatch(&registry, allocator, .{
        .contractVersion = "1.0", .type = "sim.advance",
        .payload = adv_payload, .requestId = null,
    });
    defer cleanResponse(allocator, &adv_resp);
    json_util.jsonValueDeinit(allocator, &adv_payload);

    try std.testing.expect(adv_resp.ok);
    try std.testing.expectEqual(@as(i64, 5), adv_resp.payload.?.object.get("toTick").?.integer);
}

test "dispatch: defaults.add stores request returns totalDefaults" {
    const allocator = std.testing.allocator;
    var registry = runs.Runs.init(allocator);
    defer registry.deinit();

    var empty_params = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer empty_params.deinit(allocator);
    const init_payload = try valueFromStruct(allocator, sim.SimInitializeRequestPayload{
        .seed = 42,
        .params = std.json.Value{ .object = empty_params },
    });
    var init_resp = try dispatch(&registry, allocator, .{
        .contractVersion = "1.0", .type = "sim.initialize",
        .payload = init_payload, .requestId = null,
    });
    defer cleanResponse(allocator, &init_resp);
    json_util.jsonValueDeinit(allocator, &init_payload);
    const run_id = init_resp.payload.?.object.get("runId").?.string;

    const add_payload = try valueFromStruct(allocator, defaults.DefaultsAddRequestPayload{
        .runId = run_id,
        .analystId = "test-analyst",
        .requests = &.{
            protocol.DefaultIbRequest{ .method = "ib.capabilities", .args = std.json.Value{ .null = {} } },
        },
    });
    defer json_util.jsonValueDeinit(allocator, &add_payload);
    var resp = try dispatch(&registry, allocator, .{
        .contractVersion = "1.0", .type = "defaults.add",
        .payload = add_payload, .requestId = null,
    });
    defer cleanResponse(allocator, &resp);

    try std.testing.expect(resp.ok);
    try std.testing.expectEqual(@as(i64, 1), resp.payload.?.object.get("totalDefaults").?.integer);
}

test "dispatch: broker.call returns ok" {
    const allocator = std.testing.allocator;
    var registry = runs.Runs.init(allocator);
    defer registry.deinit();

    var empty_params = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer empty_params.deinit(allocator);
    const init_payload = try valueFromStruct(allocator, sim.SimInitializeRequestPayload{
        .seed = 42,
        .params = std.json.Value{ .object = empty_params },
    });
    var init_resp = try dispatch(&registry, allocator, .{
        .contractVersion = "1.0", .type = "sim.initialize",
        .payload = init_payload, .requestId = null,
    });
    defer cleanResponse(allocator, &init_resp);
    json_util.jsonValueDeinit(allocator, &init_payload);
    const run_id = init_resp.payload.?.object.get("runId").?.string;

    // Build args object with hatId and payment for ib.capabilities
    var args_obj = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try args_obj.put(allocator, try allocator.dupe(u8, "hatId"), std.json.Value{ .integer = 0 });
    try args_obj.put(allocator, try allocator.dupe(u8, "payment"), std.json.Value{ .float = 0 });
    var args_value = std.json.Value{ .object = args_obj };
    defer json_util.jsonValueDeinit(allocator, &args_value);
    const call_payload = try valueFromStruct(allocator, broker.BrokerCallRequestPayload{
        .runId = run_id,
        .analystId = "test-analyst",
        .method = "ib.capabilities",
        .args = args_value,
    });
    defer json_util.jsonValueDeinit(allocator, &call_payload);
    var resp = try dispatch(&registry, allocator, .{
        .contractVersion = "1.0", .type = "broker.call",
        .payload = call_payload, .requestId = null,
    });
    defer cleanResponse(allocator, &resp);

    try std.testing.expect(resp.ok);
    try std.testing.expectEqualStrings("ib.capabilities", resp.payload.?.object.get("method").?.string);
}

test "dispatch: action.alert_beacon returns ok" {
    const allocator = std.testing.allocator;
    var registry = runs.Runs.init(allocator);
    defer registry.deinit();

    var empty_params = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer empty_params.deinit(allocator);
    const init_payload = try valueFromStruct(allocator, sim.SimInitializeRequestPayload{
        .seed = 42,
        .params = std.json.Value{ .object = empty_params },
    });
    var init_resp = try dispatch(&registry, allocator, .{
        .contractVersion = "1.0", .type = "sim.initialize",
        .payload = init_payload, .requestId = null,
    });
    defer cleanResponse(allocator, &init_resp);
    json_util.jsonValueDeinit(allocator, &init_payload);
    const run_id = init_resp.payload.?.object.get("runId").?.string;

    const alert_payload = try valueFromStruct(allocator, actions.ActionAlertBeaconRequestPayload{
    .runId = run_id,
    .analystId = "test-analyst",
    .beaconId = 0,
    .alertLevel = .LEVEL_ONE,
    });
    var resp = try dispatch(&registry, allocator, .{
    .contractVersion = "1.0", .type = "action.alert_beacon",
    .payload = alert_payload, .requestId = null,
    });
    defer cleanResponse(allocator, &resp);
    json_util.jsonValueDeinit(allocator, &alert_payload);

    try std.testing.expect(resp.ok);
    try std.testing.expectEqualStrings("LEVEL_ONE", resp.payload.?.object.get("alertLevel").?.string);
    }

test "dispatch: action.arrest_hat returns ok" {
    const allocator = std.testing.allocator;
    var registry = runs.Runs.init(allocator);
    defer registry.deinit();

    var empty_params = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer empty_params.deinit(allocator);
    const init_payload = try valueFromStruct(allocator, sim.SimInitializeRequestPayload{
        .seed = 42,
        .params = std.json.Value{ .object = empty_params },
    });
    var init_resp = try dispatch(&registry, allocator, .{
        .contractVersion = "1.0", .type = "sim.initialize",
        .payload = init_payload, .requestId = null,
    });
    defer cleanResponse(allocator, &init_resp);
    json_util.jsonValueDeinit(allocator, &init_payload);
    const run_id = init_resp.payload.?.object.get("runId").?.string;

    const arrest_payload = try valueFromStruct(allocator, actions.ActionArrestHatRequestPayload{
        .runId = run_id,
        .analystId = "test-analyst",
        .hatId = 0,
        .location = types.Location{ .x = 0, .y = 0 },
    });
    var resp = try dispatch(&registry, allocator, .{
        .contractVersion = "1.0", .type = "action.arrest_hat",
        .payload = arrest_payload, .requestId = null,
    });
    defer cleanResponse(allocator, &resp);
    json_util.jsonValueDeinit(allocator, &arrest_payload);

    try std.testing.expect(resp.ok);
    try std.testing.expect(resp.payload.?.object.get("status") != null);
}
