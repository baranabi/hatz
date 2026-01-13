//! Information Broker method stubs and registry.
const std = @import("std");
const types = @import("types.zig");
const sim = @import("sim.zig");
const json_util = @import("json_util.zig");

pub const BrokerCallRequestPayload = struct {
    runId: types.RunId,
    analystId: types.AnalystId,
    method: []const u8,
    args: std.json.Value,
};

pub const BrokerCallMetadata = struct {
    tick: types.Tick,
    noisy: bool,
};

pub const BrokerCallResponsePayload = struct {
    method: []const u8,
    charged: types.Payment,
    result: std.json.Value,
    metadata: BrokerCallMetadata,
};

/// Dispatch an Information Broker method call and return a structured response.
/// This stub implements deterministic data and minimal validation for contract tests.
pub fn call(allocator: std.mem.Allocator, run: *sim.RunState, payload: BrokerCallRequestPayload) !BrokerCallResponsePayload {
    const tick = run.tick;
    if (std.mem.eql(u8, payload.method, "ib.world_dimensions")) {
        const result = ResultWorldDimensions{
            .x = .{ .min = 0, .max = types.WorldMax },
            .y = .{ .min = 0, .max = types.WorldMax },
        };
        return brokerResponse(allocator, payload.method, 0, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.beacons")) {
        var list: std.ArrayList(BeaconRecord) = .empty;
        for (run.beacons) |beacon| {
            try list.append(allocator, .{
                .beaconId = beacon.beaconId,
                .alertLevel = beacon.alertLevel,
                .location = beacon.location,
                .vulnerabilities = beacon.vulnerabilities,
            });
        }
        const result = ResultBeacons{ .beacons = try list.toOwnedSlice(allocator) };
        return brokerResponse(allocator, payload.method, 0, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.all_capabilities")) {
        const result = ResultAllCapabilities{ .capabilities = try capabilityRange(allocator, 16) };
        return brokerResponse(allocator, payload.method, 0, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.benign_organizations")) {
        const result = ResultOrganizations{ .organizationIds = try organizationRange(allocator, 100, 5) };
        return brokerResponse(allocator, payload.method, 0, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.terrorist_organizations")) {
        const result = ResultOrganizations{ .organizationIds = try organizationRange(allocator, 200, 2) };
        return brokerResponse(allocator, payload.method, 0, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.known_terrorist_hats")) {
        const result = ResultHatIds{ .hatIds = try knownTerroristHats(allocator, 5) };
        return brokerResponse(allocator, payload.method, 0, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.members")) {
        const args = try requireObject(payload.args);
        const org_id = try requireInt(args, "organizationId");
        const result = ResultMembers{ .hatIds = try orgMembers(allocator, @intCast(org_id)) };
        return brokerResponse(allocator, payload.method, 0, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.hat_advertised_color")) {
        const args = try requireObject(payload.args);
        const hat_id = try requireInt(args, "hatId");
        const color: types.HatAdvertisedColor = if (hat_id % 11 == 0) .TERRORIST else .UNKNOWN;
        const result = ResultHatAdvertisedColor{ .value = color };
        return brokerResponse(allocator, payload.method, 0, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.events_history")) {
        const result = ResultEventsHistory{ .events = run.event_log.items };
        return brokerResponse(allocator, payload.method, 0, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.clear_events_history")) {
        run.event_log.clearRetainingCapacity();
        const result = ResultClearEventsHistory{ .cleared = true };
        return brokerResponse(allocator, payload.method, 0, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.arrested_hats")) {
        var list: std.ArrayList(types.HatId) = .empty;
        var iter = run.arrested_hats.iterator();
        while (iter.next()) |entry| {
            try list.append(allocator, entry.key_ptr.*);
        }
        const result = ResultHatIds{ .hatIds = try list.toOwnedSlice(allocator) };
        return brokerResponse(allocator, payload.method, 0, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.last_location")) {
        const args = try requireObject(payload.args);
        const hat_id = try requireInt(args, "hatId");
        const payment = try requireNumber(args, "payment");
        const result = ResultLastLocation{ .location = types.deterministicLocation(run.seed, tick, @intCast(hat_id)) };
        return brokerResponse(allocator, payload.method, payment, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.capabilities")) {
        const args = try requireObject(payload.args);
        const hat_id = try requireInt(args, "hatId");
        const payment = try requireNumber(args, "payment");
        const result = ResultCapabilities{ .capabilities = try hatCapabilities(allocator, @intCast(hat_id)) };
        return brokerResponse(allocator, payload.method, payment, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.meeting_times")) {
        const args = try requireObject(payload.args);
        const hat_id = try requireInt(args, "hatId");
        const payment = try requireNumber(args, "payment");
        const result = ResultMeetingTimes{ .ticks = try meetingTimes(allocator, tick, @intCast(hat_id)) };
        return brokerResponse(allocator, payload.method, payment, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.meeting_location")) {
        const args = try requireObject(payload.args);
        const hat_id = try requireInt(args, "hatId");
        const meeting_tick = try requireInt(args, "tick");
        const payment = try requireNumber(args, "payment");
        const location = if ((hat_id + meeting_tick) % 5 == 0)
            types.deterministicLocation(run.seed, meeting_tick, @intCast(hat_id))
        else
            null;
        const result = ResultMeetingLocation{ .location = location };
        return brokerResponse(allocator, payload.method, payment, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.meeting_participants")) {
        const args = try requireObject(payload.args);
        const meeting_tick = try requireInt(args, "tick");
        _ = try requireLocation(args, "location");
        const payment = try requireNumber(args, "payment");
        const participants = if (meeting_tick % 3 == 0) @as(?[]types.HatId, try meetingParticipants(allocator, meeting_tick)) else null;
        const result = ResultMeetingParticipants{ .hatIds = participants };
        return brokerResponse(allocator, payload.method, payment, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.meeting_trades")) {
        const args = try requireObject(payload.args);
        const meeting_tick = try requireInt(args, "tick");
        _ = try requireLocation(args, "location");
        const payment = try requireNumber(args, "payment");
        const trades = if (meeting_tick % 4 == 0) @as(?[]TradeRecord, try meetingTrades(allocator, meeting_tick)) else null;
        const result = ResultMeetingTrades{ .trades = trades };
        return brokerResponse(allocator, payload.method, payment, tick, false, result);
    }
    return error.UnknownMethod;
}

const AxisRange = struct {
    min: i32,
    max: i32,
};

const ResultWorldDimensions = struct {
    x: AxisRange,
    y: AxisRange,
};

const BeaconRecord = struct {
    beaconId: types.BeaconId,
    alertLevel: types.AlertLevel,
    location: types.Location,
    vulnerabilities: []const types.CapabilityId,
};

const ResultBeacons = struct {
    beacons: []BeaconRecord,
};

const ResultAllCapabilities = struct {
    capabilities: []types.CapabilityId,
};

const ResultOrganizations = struct {
    organizationIds: []types.OrganizationId,
};

const ResultHatIds = struct {
    hatIds: []types.HatId,
};

const ResultMembers = struct {
    hatIds: []types.HatId,
};

const ResultHatAdvertisedColor = struct {
    value: types.HatAdvertisedColor,
};

const ResultEventsHistory = struct {
    events: []types.EventRecord,
};

const ResultClearEventsHistory = struct {
    cleared: bool,
};

const ResultLastLocation = struct {
    location: ?types.Location,
};

const ResultCapabilities = struct {
    capabilities: []types.CapabilityId,
};

const ResultMeetingTimes = struct {
    ticks: []types.Tick,
};

const ResultMeetingLocation = struct {
    location: ?types.Location,
};

const ResultMeetingParticipants = struct {
    hatIds: ?[]types.HatId,
};

const TradeRecord = struct {
    sourceHatId: types.HatId,
    recipientHatId: types.HatId,
    capabilityId: types.CapabilityId,
};

const ResultMeetingTrades = struct {
    trades: ?[]TradeRecord,
};

/// Wrap a typed result into a broker response with metadata.
/// Uses JSON round-tripping to avoid custom serialization per result type.
fn brokerResponse(allocator: std.mem.Allocator, method: []const u8, charged: types.Payment, tick: types.Tick, noisy: bool, result: anytype) !BrokerCallResponsePayload {
    const result_value = try valueFromStruct(allocator, result);
    return BrokerCallResponsePayload{
        .method = method,
        .charged = charged,
        .result = result_value,
        .metadata = .{
            .tick = tick,
            .noisy = noisy,
        },
    };
}

/// Generate a contiguous range of capability ids starting at 0.
fn capabilityRange(allocator: std.mem.Allocator, count: u32) ![]types.CapabilityId {
    var list: std.ArrayList(types.CapabilityId) = .empty;
    var idx: u32 = 0;
    while (idx < count) : (idx += 1) {
        try list.append(allocator, idx);
    }
    return list.toOwnedSlice(allocator);
}

/// Generate a contiguous range of organization ids from a start value.
fn organizationRange(allocator: std.mem.Allocator, start: types.OrganizationId, count: u32) ![]types.OrganizationId {
    var list: std.ArrayList(types.OrganizationId) = .empty;
    var idx: u32 = 0;
    while (idx < count) : (idx += 1) {
        try list.append(allocator, start + idx);
    }
    return list.toOwnedSlice(allocator);
}

/// Return a deterministic set of hats marked as known terrorists.
/// Uses a simple modulo rule to keep the stub predictable.
fn knownTerroristHats(allocator: std.mem.Allocator, count: u32) ![]types.HatId {
    var list: std.ArrayList(types.HatId) = .empty;
    var hat: u32 = 0;
    while (list.items.len < count) : (hat += 1) {
        if (hat % 11 == 0) {
            try list.append(allocator, hat);
        }
    }
    return list.toOwnedSlice(allocator);
}

/// Provide a deterministic list of members for an organization.
fn orgMembers(allocator: std.mem.Allocator, org_id: types.OrganizationId) ![]types.HatId {
    var list: std.ArrayList(types.HatId) = .empty;
    const base: types.HatId = @intCast(org_id % 50);
    var idx: u32 = 0;
    while (idx < 4) : (idx += 1) {
        try list.append(allocator, base + idx);
    }
    return list.toOwnedSlice(allocator);
}

/// Provide a deterministic capability list for a hat.
fn hatCapabilities(allocator: std.mem.Allocator, hat_id: types.HatId) ![]types.CapabilityId {
    var list: std.ArrayList(types.CapabilityId) = .empty;
    var idx: u32 = 0;
    while (idx < 3) : (idx += 1) {
        try list.append(allocator, @intCast((hat_id + idx * 5) % 16));
    }
    return list.toOwnedSlice(allocator);
}

/// Generate deterministic meeting times starting from the current tick.
/// This models sparse meetings without storing historical state.
fn meetingTimes(allocator: std.mem.Allocator, current_tick: types.Tick, hat_id: types.HatId) ![]types.Tick {
    var list: std.ArrayList(types.Tick) = .empty;
    var t: types.Tick = current_tick;
    while (t <= current_tick + 50) : (t += 1) {
        if ((t + hat_id) % 13 == 0) {
            try list.append(allocator, t);
        }
    }
    return list.toOwnedSlice(allocator);
}

/// Return deterministic participant ids for a meeting tick.
fn meetingParticipants(allocator: std.mem.Allocator, meeting_tick: types.Tick) ![]types.HatId {
    var list: std.ArrayList(types.HatId) = .empty;
    var idx: u32 = 0;
    while (idx < 3) : (idx += 1) {
        try list.append(allocator, @intCast((meeting_tick + idx * 7) % 64));
    }
    return list.toOwnedSlice(allocator);
}

/// Return deterministic trade records for a meeting tick.
fn meetingTrades(allocator: std.mem.Allocator, meeting_tick: types.Tick) ![]TradeRecord {
    var list: std.ArrayList(TradeRecord) = .empty;
    var idx: u32 = 0;
    while (idx < 2) : (idx += 1) {
        try list.append(allocator, .{
            .sourceHatId = @intCast((meeting_tick + idx) % 64),
            .recipientHatId = @intCast((meeting_tick + idx + 1) % 64),
            .capabilityId = @intCast((meeting_tick + idx * 3) % 16),
        });
    }
    return list.toOwnedSlice(allocator);
}

/// Convert a typed struct into a dynamic JSON value via stringify/parse.
fn valueFromStruct(allocator: std.mem.Allocator, value: anytype) !std.json.Value {
    const json_text = try json_util.stringifyAlloc(allocator, value);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{ .allocate = .alloc_always });
    return parsed.value;
}

/// Require a JSON object and return its map.
fn requireObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidArgs;
    return value.object;
}

/// Extract an integer argument from a JSON object by key.
fn requireInt(object: std.json.ObjectMap, key: []const u8) !u64 {
    const value = object.get(key) orelse return error.MissingArg;
    switch (value) {
        .integer => |val| return @intCast(val),
        else => return error.InvalidArgs,
    }
}

/// Extract a numeric (integer or float) argument from a JSON object by key.
fn requireNumber(object: std.json.ObjectMap, key: []const u8) !f64 {
    const value = object.get(key) orelse return error.MissingArg;
    switch (value) {
        .integer => |val| return @floatFromInt(val),
        .float => |val| return val,
        else => return error.InvalidArgs,
    }
}

/// Extract a Location object (x/y) from JSON args.
fn requireLocation(object: std.json.ObjectMap, key: []const u8) !types.Location {
    const value = object.get(key) orelse return error.MissingArg;
    if (value != .object) return error.InvalidArgs;
    const loc = value.object;
    const x = try requireInt(loc, "x");
    const y = try requireInt(loc, "y");
    return types.Location{
        .x = @intCast(x),
        .y = @intCast(y),
    };
}
