//! Simulation lifecycle and run state management.
const std = @import("std");
const types = @import("types.zig");
const protocol = @import("protocol.zig");
const broker = @import("broker.zig");
const defaults = @import("defaults.zig");
const runs = @import("runs.zig");
const json_util = @import("json_util.zig");

pub const SimInitializeRequestPayload = struct {
    seed: u64,
    params: std.json.Value,
};

pub const SimInitializeResponsePayload = struct {
    runId: types.RunId,
    startedAtTick: types.Tick,
};

pub const SimAdvanceRequestPayload = struct {
    runId: types.RunId,
    numberOfTicks: u64,
    timeIt: bool = false,
    includeDefaultRequestResults: bool = true,
};

pub const SimAdvanceTiming = struct {
    elapsedMs: f64,
};

pub const SimAdvanceResponsePayload = struct {
    runId: types.RunId,
    fromTick: types.Tick,
    toTick: types.Tick,
    eventsEmitted: u64,
    defaultRequestResults: ?[]protocol.DefaultIbResult = null,
    timing: ?SimAdvanceTiming = null,
};

pub const SimEndRequestPayload = struct {
    runId: types.RunId,
};

pub const SimEndResponsePayload = struct {
    runId: types.RunId,
    finalTick: types.Tick,
    summary: std.json.Value,
};

pub const DefaultIbRequestStored = struct {
    method: []const u8,
    args_json: []const u8,
};

pub const AnalystState = struct {
    analyst_id: []const u8,
    defaults: std.ArrayList(DefaultIbRequestStored),
    spend_total: types.Payment,
    once_per_tick: std.StringHashMap(types.Tick),

    /// Initialize per-analyst bookkeeping for defaults and spend tracking.
    /// Stored strings are owned by the run allocator.
    pub fn init(allocator: std.mem.Allocator, analyst_id: []const u8) AnalystState {
        return AnalystState{
            .analyst_id = analyst_id,
            .defaults = .empty,
            .spend_total = 0,
            .once_per_tick = std.StringHashMap(types.Tick).init(allocator),
        };
    }

    /// Release all per-analyst allocations, including defaults and tick guards.
    pub fn deinit(self: *AnalystState, allocator: std.mem.Allocator) void {
        for (self.defaults.items) |item| {
            allocator.free(item.method);
            allocator.free(item.args_json);
        }
        self.defaults.deinit(allocator);
        var iter = self.once_per_tick.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.once_per_tick.deinit();
    }
};

pub const RunState = struct {
    allocator: std.mem.Allocator,
    run_id: []const u8,
    seed: u64,
    tick: types.Tick,
    params_json: []u8,
    analyst_states: std.StringHashMap(AnalystState),
    beacons: [beacon_count]types.Beacon,
    beacon_vulnerabilities: [beacon_count][beacon_vuln_count]types.CapabilityId,
    arrested_hats: std.AutoHashMap(types.HatId, bool),
    event_log: std.ArrayList(types.EventRecord),

    /// Initialize a run with deterministic beacons and empty runtime state.
    /// The run takes ownership of run_id and params_json allocations.
    pub fn init(allocator: std.mem.Allocator, run_id: []const u8, seed: u64, params_json: []u8) !RunState {
        var state = RunState{
            .allocator = allocator,
            .run_id = run_id,
            .seed = seed,
            .tick = 0,
            .params_json = params_json,
            .analyst_states = std.StringHashMap(AnalystState).init(allocator),
            .beacons = undefined,
            .beacon_vulnerabilities = undefined,
            .arrested_hats = std.AutoHashMap(types.HatId, bool).init(allocator),
            .event_log = .empty,
        };

        for (&state.beacons, 0..) |*beacon, idx| {
            const beacon_id: types.BeaconId = @intCast(idx);
            state.beacon_vulnerabilities[idx] = beaconVulnerabilities(seed, beacon_id);
            beacon.* = types.Beacon{
                .beaconId = beacon_id,
                .alertLevel = .OFF,
                .location = types.deterministicBeaconLocation(seed, beacon_id),
                .vulnerabilities = state.beacon_vulnerabilities[idx][0..],
            };
        }

        return state;
    }

    /// Release all allocations owned by the run, including analyst state and logs.
    pub fn deinit(self: *RunState) void {
        var iter = self.analyst_states.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.analyst_states.deinit();
        var arrests = self.arrested_hats.iterator();
        while (arrests.next()) |entry| {
            _ = entry;
        }
        self.arrested_hats.deinit();
        self.event_log.deinit(self.allocator);
        self.allocator.free(self.params_json);
        self.allocator.free(self.run_id);
    }
};

const beacon_count = 5;
const beacon_vuln_count = 3;
const default_analyst_id = "human";

/// Create a new run in the registry and return its id and initial tick.
/// Params are preserved as JSON for future inspection.
pub fn initialize(registry: *runs.Runs, allocator: std.mem.Allocator, payload: SimInitializeRequestPayload) !SimInitializeResponsePayload {
    const params_json = try json_util.stringifyAlloc(allocator, payload.params);
    const run = try registry.createRun(payload.seed, params_json);
    return SimInitializeResponsePayload{
        .runId = run.run_id,
        .startedAtTick = run.tick,
    };
}

/// Advance the run by N ticks and optionally include default IB results.
/// Defaults are executed against the current run state to simulate polling.
pub fn advance(registry: *runs.Runs, allocator: std.mem.Allocator, payload: SimAdvanceRequestPayload) !SimAdvanceResponsePayload {
    const run = registry.get(payload.runId) orelse return error.RunNotFound;
    const from_tick = run.tick;
    run.tick += payload.numberOfTicks;
    const to_tick = run.tick;

    var response = SimAdvanceResponsePayload{
        .runId = run.run_id,
        .fromTick = from_tick,
        .toTick = to_tick,
        .eventsEmitted = 0,
        .defaultRequestResults = null,
        .timing = null,
    };

    if (payload.includeDefaultRequestResults) {
        const defaults_list = defaults.getDefaults(run, default_analyst_id);
        if (defaults_list.len > 0) {
            var results: std.ArrayList(protocol.DefaultIbResult) = .empty;
            for (defaults_list) |request| {
                const args_value = try parseArgsValue(allocator, request.args_json);
                const broker_payload = broker.BrokerCallRequestPayload{
                    .runId = run.run_id,
                    .analystId = default_analyst_id,
                    .method = request.method,
                    .args = args_value,
                };
                const broker_response = try broker.call(allocator, run, broker_payload);
                try results.append(allocator, protocol.DefaultIbResult{
                    .method = broker_response.method,
                    .result = broker_response.result,
                    .metadata = .{
                        .tick = broker_response.metadata.tick,
                        .noisy = broker_response.metadata.noisy,
                        .charged = broker_response.charged,
                    },
                });
            }
            response.defaultRequestResults = try results.toOwnedSlice(allocator);
        }
    }

    if (payload.timeIt) {
        response.timing = .{ .elapsedMs = 0 };
    }

    return response;
}

/// End a run and return a summary placeholder with the final tick.
/// The run is not removed from the registry in the stub implementation.
pub fn end(registry: *runs.Runs, allocator: std.mem.Allocator, payload: SimEndRequestPayload) !SimEndResponsePayload {
    const run = registry.get(payload.runId) orelse return error.RunNotFound;
    const summary = std.json.Value{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
    return SimEndResponsePayload{
        .runId = run.run_id,
        .finalTick = run.tick,
        .summary = summary,
    };
}

/// Generate deterministic vulnerabilities for a beacon.
/// This avoids storing additional data while keeping results stable per seed.
fn beaconVulnerabilities(seed: u64, beacon_id: types.BeaconId) [beacon_vuln_count]types.CapabilityId {
    var out: [beacon_vuln_count]types.CapabilityId = undefined;
    const base = seed + @as(u64, beacon_id) * 7;
    var idx: usize = 0;
    while (idx < beacon_vuln_count) : (idx += 1) {
        out[idx] = @intCast((base + idx * 3) % 16);
    }
    return out;
}

/// Parse stored JSON args into a dynamic value for broker calls.
/// Defaults store args as JSON bytes to avoid lifetime issues.
fn parseArgsValue(allocator: std.mem.Allocator, args_json: []const u8) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{ .allocate = .alloc_always });
    return parsed.value;
}
