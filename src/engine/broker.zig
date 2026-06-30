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
        return brokerResponse(allocator, run, payload.analystId, payload.method, 0, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.beacons")) {
        var list: std.ArrayList(BeaconRecord) = .empty;
        for (run.beacons, 0..) |beacon, idx| {
            try list.append(allocator, .{
                .beaconId = beacon.beaconId,
                .alertLevel = beacon.alertLevel,
                .location = beacon.location,
                .vulnerabilities = run.beacon_vulnerabilities[idx][0..],
            });
        }
        const result = ResultBeacons{ .beacons = try list.toOwnedSlice(allocator) };
        return brokerResponse(allocator, run, payload.analystId, payload.method, 0, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.all_capabilities")) {
        const result = ResultAllCapabilities{ .capabilities = try capabilityRange(allocator, 16) };
        return brokerResponse(allocator, run, payload.analystId, payload.method, 0, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.benign_organizations")) {
        const result = ResultOrganizations{ .organizationIds = try organizationRange(allocator, 100, 5) };
        return brokerResponse(allocator, run, payload.analystId, payload.method, 0, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.terrorist_organizations")) {
        const result = ResultOrganizations{ .organizationIds = try organizationRange(allocator, 200, 2) };
        return brokerResponse(allocator, run, payload.analystId, payload.method, 0, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.known_terrorist_hats")) {
        const result = ResultHatIds{ .hatIds = try knownTerroristHats(allocator, 5) };
        return brokerResponse(allocator, run, payload.analystId, payload.method, 0, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.members")) {
        const args = try requireObject(payload.args);
        const org_id = try requireInt(args, "organizationId");
        const result = ResultMembers{ .hatIds = try orgMembers(allocator, @intCast(org_id)) };
        return brokerResponse(allocator, run, payload.analystId, payload.method, 0, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.hat_advertised_color")) {
        const args = try requireObject(payload.args);
        const hat_id = try requireInt(args, "hatId");
        const color: types.HatAdvertisedColor = if (hat_id % 11 == 0) .TERRORIST else .UNKNOWN;
        const result = ResultHatAdvertisedColor{ .value = color };
        return brokerResponse(allocator, run, payload.analystId, payload.method, 0, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.events_history")) {
        const result = ResultEventsHistory{ .events = run.event_log.items };
        return brokerResponse(allocator, run, payload.analystId, payload.method, 0, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.clear_events_history")) {
        run.event_log.clearRetainingCapacity();
        const result = ResultClearEventsHistory{ .cleared = true };
        return brokerResponse(allocator, run, payload.analystId, payload.method, 0, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.arrested_hats")) {
        var list: std.ArrayList(types.HatId) = .empty;
        var iter = run.arrested_hats.iterator();
        while (iter.next()) |entry| {
            try list.append(allocator, entry.key_ptr.*);
        }
        const result = ResultHatIds{ .hatIds = try list.toOwnedSlice(allocator) };
        return brokerResponse(allocator, run, payload.analystId, payload.method, 0, tick, false, result);
    }
    if (std.mem.eql(u8, payload.method, "ib.last_location")) {
        const args = try requireObject(payload.args);
        const hat_id = try requireInt(args, "hatId");
        const payment = try requireNumber(args, "payment");
        // Unknown hat → no noise, null result.
        if (!hatExists(run, @intCast(hat_id))) return brokerResponse(allocator, run, payload.analystId, payload.method, 0, tick, false,
            ResultLastLocation{ .location = null });
        const truth = types.deterministicLocation(run.seed, tick, @intCast(hat_id));
        const nh = noiseHash(run.seed, tick, payload.method, payload.analystId);
        const outcome = noiseOutcome(nh, payment);
        const result: ?types.Location = switch (outcome) {
            .correct => truth,
            .missing => null,
            .perturbed => blk: {
                const pert = types.mix(nh ^ 0xDEAD);
                break :blk types.Location{
                    .x = truth.x + @as(i32, @intCast(@as(i33, @intCast(pert % 5)))) - 2,
                    .y = truth.y + @as(i32, @intCast(@as(i33, @intCast(types.mix(pert) % 5)))) - 2,
                };
            },
        };
        return brokerResponse(allocator, run, payload.analystId, payload.method, payment, tick, true,
            ResultLastLocation{ .location = result });
    }
    if (std.mem.eql(u8, payload.method, "ib.capabilities")) {
        const args = try requireObject(payload.args);
        const hat_id = try requireInt(args, "hatId");
        const payment = try requireNumber(args, "payment");
        // Unknown hat → no noise, empty result.
        if (!hatExists(run, @intCast(hat_id))) return brokerResponse(allocator, run, payload.analystId, payload.method, 0, tick, false,
            ResultCapabilities{ .capabilities = try allocator.alloc(types.CapabilityId, 0) });
        const nh = noiseHash(run.seed, tick, payload.method, payload.analystId);
        const outcome = noiseOutcome(nh, payment);
        const caps: []types.CapabilityId = switch (outcome) {
            .correct => try hatCapabilities(allocator, @intCast(hat_id)),
            .missing => try allocator.alloc(types.CapabilityId, 0),
            .perturbed => blk: {
                var c = try hatCapabilities(allocator, @intCast(hat_id));
                if (c.len > 0) {
                    const rand_cap = @as(types.CapabilityId, @intCast(types.mix(nh ^ 0xBEEF) % 16));
                    c[0] = rand_cap;
                }
                break :blk c;
            },
        };
        return brokerResponse(allocator, run, payload.analystId, payload.method, payment, tick, true,
            ResultCapabilities{ .capabilities = caps });
    }
    if (std.mem.eql(u8, payload.method, "ib.meeting_times")) {
        const args = try requireObject(payload.args);
        const hat_id = try requireInt(args, "hatId");
        const payment = try requireNumber(args, "payment");
        // Unknown hat → no noise, empty result.
        if (!hatExists(run, @intCast(hat_id))) return brokerResponse(allocator, run, payload.analystId, payload.method, 0, tick, false,
            ResultMeetingTimes{ .ticks = try allocator.alloc(types.Tick, 0) });
        const nh = noiseHash(run.seed, tick, payload.method, payload.analystId);
        const outcome = noiseOutcome(nh, payment);
        const ticks: []types.Tick = switch (outcome) {
            .correct => try meetingTimes(allocator, tick, @intCast(hat_id)),
            .missing => try allocator.alloc(types.Tick, 0),
            .perturbed => blk: {
                var t = try meetingTimes(allocator, tick, @intCast(hat_id));
                // Drop first tick if any exist (perturbed list).
                if (t.len > 0) {
                    const trimmed = try allocator.alloc(types.Tick, t.len - 1);
                    @memcpy(trimmed, t[1..]);
                    allocator.free(t);
                    break :blk trimmed;
                }
                break :blk t;
            },
        };
        return brokerResponse(allocator, run, payload.analystId, payload.method, payment, tick, true,
            ResultMeetingTimes{ .ticks = ticks });
    }
    if (std.mem.eql(u8, payload.method, "ib.meeting_location")) {
        const args = try requireObject(payload.args);
        const hat_id = try requireInt(args, "hatId");
        const meeting_tick = try requireInt(args, "tick");
        const payment = try requireNumber(args, "payment");
        // Unknown hat → no noise, null result.
        if (!hatExists(run, @intCast(hat_id))) return brokerResponse(allocator, run, payload.analystId, payload.method, 0, tick, false,
            ResultMeetingLocation{ .location = null });
        const truth: ?types.Location = if ((hat_id + meeting_tick) % 5 == 0)
            types.deterministicLocation(run.seed, meeting_tick, @intCast(hat_id))
        else
            null;
        const nh = noiseHash(run.seed, tick, payload.method, payload.analystId);
        const outcome = noiseOutcome(nh, payment);
        const result: ?types.Location = switch (outcome) {
            .correct => truth,
            .missing => null,
            .perturbed => blk: {
                if (truth) |loc| {
                    const pert = types.mix(nh ^ 0xCAFE);
                    break :blk types.Location{
                        .x = loc.x + @as(i32, @intCast(@as(i33, @intCast(pert % 5)))) - 2,
                        .y = loc.y + @as(i32, @intCast(@as(i33, @intCast(types.mix(pert) % 5)))) - 2,
                    };
                }
                break :blk null;
            },
        };
        return brokerResponse(allocator, run, payload.analystId, payload.method, payment, tick, true,
            ResultMeetingLocation{ .location = result });
    }
    if (std.mem.eql(u8, payload.method, "ib.meeting_participants")) {
        const args = try requireObject(payload.args);
        const meeting_tick = try requireInt(args, "tick");
        _ = try requireLocation(args, "location");
        const payment = try requireNumber(args, "payment");
        const truth: ?[]types.HatId = if (meeting_tick % 3 == 0) try meetingParticipants(allocator, meeting_tick) else null;
        const nh = noiseHash(run.seed, tick, payload.method, payload.analystId);
        const outcome = noiseOutcome(nh, payment);
        const participants: ?[]types.HatId = switch (outcome) {
            .correct => truth,
            .missing => null,
            .perturbed => blk: {
                if (truth) |p| {
                    if (p.len > 0) {
                        const trimmed = try allocator.alloc(types.HatId, p.len - 1);
                        @memcpy(trimmed, p[1..]);
                        allocator.free(p);
                        break :blk trimmed;
                    }
                }
                break :blk truth;
            },
        };
        return brokerResponse(allocator, run, payload.analystId, payload.method, payment, tick, true,
            ResultMeetingParticipants{ .hatIds = participants });
    }
    if (std.mem.eql(u8, payload.method, "ib.meeting_trades")) {
        const args = try requireObject(payload.args);
        const meeting_tick = try requireInt(args, "tick");
        _ = try requireLocation(args, "location");
        const payment = try requireNumber(args, "payment");
        const truth: ?[]TradeRecord = if (meeting_tick % 4 == 0) try meetingTrades(allocator, meeting_tick) else null;
        const nh = noiseHash(run.seed, tick, payload.method, payload.analystId);
        const outcome = noiseOutcome(nh, payment);
        const trades: ?[]TradeRecord = switch (outcome) {
            .correct => truth,
            .missing => null,
            .perturbed => blk: {
                if (truth) |t| {
                    if (t.len > 0) {
                        const modified = try allocator.alloc(TradeRecord, t.len);
                        @memcpy(modified, t);
                        modified[0].capabilityId = @intCast(types.mix(nh ^ 0x1234) % 16);
                        allocator.free(t);
                        break :blk modified;
                    }
                }
                break :blk truth;
            },
        };
        return brokerResponse(allocator, run, payload.analystId, payload.method, payment, tick, true,
            ResultMeetingTrades{ .trades = trades });
    }
    if (std.mem.eql(u8, payload.method, "ib.hat_locations")) {
        const args = try requireObject(payload.args);
        const hat_id = try requireInt(args, "hatId");
        const payment = try requireNumber(args, "payment");
        // Return the actual stepwise location from hat_states.
        // ponytail: no noise model yet — returns true location (noise is a separate card).
        const location: ?types.Location = if (hat_id < run.hat_states.len)
            run.hat_states[@as(usize, @intCast(hat_id))].current_location
        else
            null;
        const result = ResultLastLocation{ .location = location };
        return brokerResponse(allocator, run, payload.analystId, payload.method, payment, tick, false, result);
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

/// Noise outcome for a paid query.
const NoiseOutcome = enum {
    correct,
    missing,
    perturbed,
};

/// Default lambda for the noise model P(correct) = 1 - exp(-lambda * payment).
/// λ=0.5 gives ~39% correct at p=1, ~63% at p=2, ~92% at p=5.
const default_lambda: f64 = 0.5;

/// Deterministic hash for noise seeding, unique per (seed, tick, method, analyst).
fn noiseHash(run_seed: u64, tick: types.Tick, method: []const u8, analyst_id: []const u8) u64 {
    var hash: u64 = run_seed ^ tick;
    for (method) |c| hash ^= @as(u64, c);
    for (analyst_id) |c| hash ^= @as(u64, c) << 8;
    return types.mix(hash);
}

/// Determine noise outcome for a paid query.
///
/// P(correct) = 1 - exp(-lambda * max(payment, 0))
///
/// When incorrect: equal probability of missing vs perturbed.
/// payment ≤ 0 → always missing (no information).
fn noiseOutcome(seed_hash: u64, payment: f64) NoiseOutcome {
    if (payment <= 0) return .missing;
    const p_correct = 1.0 - std.math.exp(-default_lambda * payment);
    const roll = @as(f64, @floatFromInt(seed_hash & 0x7FFFFF)) / 8388608.0;
    if (roll < p_correct) return .correct;
    const remaining = 1.0 - p_correct;
    if (remaining > 0 and (roll - p_correct) / remaining < 0.5) return .missing;
    return .perturbed;
}

/// Check if a hat exists in the run's population.
fn hatExists(run: *sim.RunState, hat_id: types.HatId) bool {
    return hat_id < run.hats.len;
}

/// Wrap a typed result into a broker response with metadata.
/// Uses JSON round-tripping to avoid custom serialization per result type.
/// Tracks analyst spend from the charged amount.
fn brokerResponse(allocator: std.mem.Allocator, run: *sim.RunState, analystId: []const u8, method: []const u8, charged: types.Payment, tick: types.Tick, noisy: bool, result: anytype) !BrokerCallResponsePayload {
    // Track analyst spend.
    if (run.analyst_states.getPtr(analystId)) |analyst| {
        analyst.spend_total += charged;
    }
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
/// Caller owns the returned std.json.Value and **must** call `json_util.jsonValueDeinit(allocator, &value)` when done.
fn valueFromStruct(allocator: std.mem.Allocator, value: anytype) !std.json.Value {
    const json_text = try json_util.stringifyAlloc(allocator, value);
    defer allocator.free(json_text);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    return try json_util.jsonValueClone(allocator, &parsed.value);
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

test "noiseOutcome: zero payment always missing" {
    // payment <= 0 should always produce missing regardless of hash.
    const h = types.mix(42);
    try std.testing.expectEqual(noiseOutcome(h, 0.0), .missing);
    try std.testing.expectEqual(noiseOutcome(h, -1.0), .missing);
    try std.testing.expectEqual(noiseOutcome(types.mix(999), 0.0), .missing);
}

test "noiseOutcome: very large payment almost always correct" {
    // With λ=0.5, payment=100 gives P(correct) = 1 - exp(-50) ≈ 1.0.
    // The roll value would need to be > 1 for incorrect, which is impossible.
    // So for any hash, the outcome should be correct.
    var i: u64 = 0;
    while (i < 50) : (i += 1) {
        const h = types.mix(i *% 0x9E3779B97F4A7C15);
        try std.testing.expectEqual(noiseOutcome(h, 100.0), .correct);
    }
}

test "noiseHash is deterministic" {
    const a = noiseHash(42, 10, "ib.capabilities", "test");
    const b = noiseHash(42, 10, "ib.capabilities", "test");
    try std.testing.expectEqual(a, b);
}

test "noiseHash differs for different methods" {
    const a = noiseHash(42, 10, "ib.capabilities", "test");
    const b = noiseHash(42, 10, "ib.last_location", "test");
    try std.testing.expect(a != b);
}

test "hatExists: valid hats are found, invalid hats are not" {
    const allocator = std.testing.allocator;
    const params = sim.SimParams{ .n_hats = 50, .n_benign_orgs = 2, .n_terrorist_orgs = 1, .planning_interval = 10 };
    var registry = sim.initForTesting(allocator);
    defer registry.deinit();
    const run = try registry.createRun(42, params);

    // Hat 0 should exist (first hat in 50-hat run).
    try std.testing.expect(hatExists(run, 0));
    // Hat 49 should exist (last hat).
    try std.testing.expect(hatExists(run, 49));
    // Hat 50 should NOT exist (out of range).
    try std.testing.expect(!hatExists(run, 50));
    // Hat 999 should not exist.
    try std.testing.expect(!hatExists(run, 999));
}

test "paid query charges payment and marks noisy" {
    const allocator = std.testing.allocator;
    const params = sim.SimParams{ .n_hats = 50, .n_benign_orgs = 2, .n_terrorist_orgs = 1, .planning_interval = 10 };
    var registry = sim.initForTesting(allocator);
    defer registry.deinit();
    const run = try registry.createRun(42, params);
    const run_id = run.run_id;

    var args = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer args.deinit(allocator);
    try args.put(allocator, "hatId", std.json.Value{ .integer = 0 });
    try args.put(allocator, "payment", std.json.Value{ .float = 5.0 });

    const resp = try call(allocator, run, .{
        .runId = run_id,
        .analystId = "test-analyst",
        .method = "ib.capabilities",
        .args = std.json.Value{ .object = args },
    });
    defer json_util.jsonValueDeinit(allocator, &resp.result);

    // Charged should equal payment for paid methods.
    try std.testing.expectEqual(@as(types.Payment, 5.0), resp.charged);
    // Paid methods always mark noisy=true.
    try std.testing.expect(resp.metadata.noisy);
}

test "spend tracking accumulates across calls" {
    const allocator = std.testing.allocator;
    const params = sim.SimParams{ .n_hats = 50, .n_benign_orgs = 2, .n_terrorist_orgs = 1, .planning_interval = 10 };
    var registry = sim.initForTesting(allocator);
    defer registry.deinit();
    const run = try registry.createRun(42, params);
    const run_id = run.run_id;

    // Ensure analyst state exists (same pattern as defaults.getOrCreateAnalyst).
    const analyst_key = try run.allocator.dupe(u8, "spend-test");
    const state = sim.AnalystState.init(run.allocator, analyst_key);
    try run.analyst_states.put(analyst_key, state);
    const analyst = run.analyst_states.getPtr(analyst_key).?;

    var args = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer args.deinit(allocator);
    try args.put(allocator, "hatId", std.json.Value{ .integer = 0 });
    try args.put(allocator, "payment", std.json.Value{ .float = 3.0 });

    // First call: should charge 3.0.
    {
        const resp = try call(allocator, run, .{
            .runId = run_id, .analystId = "spend-test",
            .method = "ib.last_location", .args = std.json.Value{ .object = args },
        });
        defer json_util.jsonValueDeinit(allocator, &resp.result);
    }
    try std.testing.expectEqual(@as(types.Payment, 3.0), analyst.spend_total);

    // Second call: should add another 3.0 = 6.0 total.
    {
        const resp = try call(allocator, run, .{
            .runId = run_id, .analystId = "spend-test",
            .method = "ib.last_location", .args = std.json.Value{ .object = args },
        });
        defer json_util.jsonValueDeinit(allocator, &resp.result);
    }
    try std.testing.expectEqual(@as(types.Payment, 6.0), analyst.spend_total);
}

test "free queries have charged=0 and noisy=false" {
    const allocator = std.testing.allocator;
    const params = sim.SimParams{ .n_hats = 50, .n_benign_orgs = 2, .n_terrorist_orgs = 1, .planning_interval = 10 };
    var registry = sim.initForTesting(allocator);
    defer registry.deinit();
    const run = try registry.createRun(42, params);
    const run_id = run.run_id;

    const empty_args = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    const resp = try call(allocator, run, .{
        .runId = run_id, .analystId = "test",
        .method = "ib.beacons", .args = std.json.Value{ .object = empty_args },
    });
    defer json_util.jsonValueDeinit(allocator, &resp.result);
    try std.testing.expectEqual(@as(types.Payment, 0), resp.charged);
    try std.testing.expect(!resp.metadata.noisy);
}
