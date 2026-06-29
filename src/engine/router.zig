//! Dispatches contract envelope requests to the stub engine handlers.
const std = @import("std");
const protocol = @import("protocol.zig");
const sim = @import("sim.zig");
const defaults = @import("defaults.zig");
const broker = @import("broker.zig");
const actions = @import("actions.zig");
const runs = @import("runs.zig");
const json_util = @import("json_util.zig");

/// Route an envelope request to the appropriate engine handler.
/// This keeps a single code path for CLI, daemon, and fixture replay.
pub fn dispatch(registry: *runs.Runs, allocator: std.mem.Allocator, request: protocol.EnvelopeRequest) !protocol.EnvelopeResponse {
    if (std.mem.eql(u8, request.type, "sim.initialize")) {
        const payload = try parsePayload(sim.SimInitializeRequestPayload, allocator, request.payload);
        const response = try sim.initialize(registry, payload);
        return okResponse(allocator, request, response);
    }
    if (std.mem.eql(u8, request.type, "sim.advance")) {
        const payload = try parsePayload(sim.SimAdvanceRequestPayload, allocator, request.payload);
        const response = try sim.advance(registry, allocator, payload);
        return okResponse(allocator, request, response);
    }
    if (std.mem.eql(u8, request.type, "sim.end")) {
        const payload = try parsePayload(sim.SimEndRequestPayload, allocator, request.payload);
        const response = try sim.end(registry, allocator, payload);
        return okResponse(allocator, request, response);
    }
    if (std.mem.eql(u8, request.type, "defaults.add")) {
        const payload = try parsePayload(defaults.DefaultsAddRequestPayload, allocator, request.payload);
        const run = registry.get(payload.runId) orelse return error.RunNotFound;
        const response = try defaults.add(allocator, run, payload);
        return okResponse(allocator, request, response);
    }
    if (std.mem.eql(u8, request.type, "defaults.remove")) {
        const payload = try parsePayload(defaults.DefaultsRemoveRequestPayload, allocator, request.payload);
        const run = registry.get(payload.runId) orelse return error.RunNotFound;
        const response = try defaults.remove(run, payload);
        return okResponse(allocator, request, response);
    }
    if (std.mem.eql(u8, request.type, "defaults.clear")) {
        const payload = try parsePayload(defaults.DefaultsClearRequestPayload, allocator, request.payload);
        const run = registry.get(payload.runId) orelse return error.RunNotFound;
        const response = try defaults.clear(run, payload);
        return okResponse(allocator, request, response);
    }
    if (std.mem.eql(u8, request.type, "defaults.list")) {
        const payload = try parsePayload(defaults.DefaultsListRequestPayload, allocator, request.payload);
        const run = registry.get(payload.runId) orelse return error.RunNotFound;
        const response = try defaults.list(allocator, run, payload);
        return okResponse(allocator, request, response);
    }
    if (std.mem.eql(u8, request.type, "broker.call")) {
        const payload = try parsePayload(broker.BrokerCallRequestPayload, allocator, request.payload);
        const run = registry.get(payload.runId) orelse return error.RunNotFound;
        const response = try broker.call(allocator, run, payload);
        return okResponse(allocator, request, response);
    }
    if (std.mem.eql(u8, request.type, "action.alert_beacon")) {
        const payload = try parsePayload(actions.ActionAlertBeaconRequestPayload, allocator, request.payload);
        const run = registry.get(payload.runId) orelse return error.RunNotFound;
        const response = try actions.alertBeacon(run, payload);
        return okResponse(allocator, request, response);
    }
    if (std.mem.eql(u8, request.type, "action.arrest_hat")) {
        const payload = try parsePayload(actions.ActionArrestHatRequestPayload, allocator, request.payload);
        const run = registry.get(payload.runId) orelse return error.RunNotFound;
        const response = try actions.arrestHat(run, payload);
        return okResponse(allocator, request, response);
    }
    return error.UnknownRequestType;
}

/// Convert a dynamic JSON value into a typed payload by re-stringifying.
/// This avoids re-implementing JSON decoding for every message shape.
pub fn parsePayload(comptime T: type, allocator: std.mem.Allocator, value: std.json.Value) !T {
    const json_text = try json_util.stringifyAlloc(allocator, value);
    const parsed = try std.json.parseFromSlice(T, allocator, json_text, .{ .allocate = .alloc_always });
    return parsed.value;
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
pub fn valueFromStruct(allocator: std.mem.Allocator, value: anytype) !std.json.Value {
    const json_text = try json_util.stringifyAlloc(allocator, value);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{ .allocate = .alloc_always });
    return parsed.value;
}
