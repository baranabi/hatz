//! Simulation lifecycle and run state management.
const std = @import("std");
const types = @import("types.zig");
const protocol = @import("protocol.zig");
const broker = @import("broker.zig");
const defaults = @import("defaults.zig");
const runs = @import("runs.zig");
const population = @import("population.zig");
const meetings = @import("meetings.zig");
const planner = @import("planner.zig");
const actions = @import("actions.zig");
const json_util = @import("json_util.zig");
const movement = @import("movement.zig");

/// High-level simulation parameters with sensible defaults.
/// These control population generation, world geometry, and simulation behaviour.
pub const SimParams = struct {
    n_hats: u32 = 200,
    n_benign_orgs: u32 = 3,
    n_terrorist_orgs: u32 = 2,
    org_size_mean: f64 = 8.0,
    org_size_std: f64 = 3.0,
    fraction_covert: f64 = 0.30,
    fraction_terrorist: f64 = 0.20,
    capability_overlap: f64 = 0.50,
    grid_x_min: i32 = 0,
    grid_x_max: i32 = 50,
    grid_y_min: i32 = 0,
    grid_y_max: i32 = 50,
    planning_interval: u64 = 10,
};

/// Parse a JSON value into SimParams, using defaults for any missing fields.
/// Returns all defaults when the value is not a JSON object.
pub fn parseSimParams(value: std.json.Value) SimParams {
    const obj = if (value != .object) return SimParams{} else value.object;
    const get = struct {
        fn int(m: std.json.ObjectMap, key: []const u8, default: u32) u32 {
            const entry = m.get(key) orelse return default;
            return @intCast(entry.integer);
        }
        fn i32_fn(m: std.json.ObjectMap, key: []const u8, default: i32) i32 {
            const entry = m.get(key) orelse return default;
            return @intCast(entry.integer);
        }
        fn float(m: std.json.ObjectMap, key: []const u8, default: f64) f64 {
            const entry = m.get(key) orelse return default;
            return entry.float;
        }
    };
    return SimParams{
        .n_hats = get.int(obj, "n_hats", 200),
        .n_benign_orgs = get.int(obj, "n_benign_orgs", 3),
        .n_terrorist_orgs = get.int(obj, "n_terrorist_orgs", 2),
        .org_size_mean = get.float(obj, "org_size_mean", 8.0),
        .org_size_std = get.float(obj, "org_size_std", 3.0),
        .fraction_covert = get.float(obj, "fraction_covert", 0.30),
        .fraction_terrorist = get.float(obj, "fraction_terrorist", 0.20),
        .capability_overlap = get.float(obj, "capability_overlap", 0.50),
        .grid_x_min = get.i32_fn(obj, "grid_x_min", 0),
        .grid_x_max = get.i32_fn(obj, "grid_x_max", 50),
        .grid_y_min = get.i32_fn(obj, "grid_y_min", 0),
        .grid_y_max = get.i32_fn(obj, "grid_y_max", 50),
        .planning_interval = get.int(obj, "planning_interval", 10),
        };
}

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

/// Create a clean Runs registry for testing with a default seed+params.
/// Convenience wrapper so tests don't need to import runs directly.
pub fn initForTesting(allocator: std.mem.Allocator) runs.Runs {
    return runs.Runs.init(allocator);
}

/// Per-beacon, per-level effectiveness tracking for scoring.
/// hits: attacks that occurred while alert was at this level.
/// false_positives: alert intervals that began/ended with no attack.
pub const BeaconAlertEffectiveness = struct {
    hits: u32 = 0,
    false_positives: u32 = 0,
};

/// Internal per-beacon alert interval tracking.
const BeaconAlertTracking = struct {
    current_level: types.AlertLevel = .OFF,
    interval_had_attack: bool = false,
    level_one: BeaconAlertEffectiveness = .{},
    level_two: BeaconAlertEffectiveness = .{},
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
    params: SimParams,
    analyst_states: std.StringHashMap(AnalystState),
    beacons: [beacon_count]types.Beacon,
    beacon_vulnerabilities: [beacon_count][beacon_vuln_count]types.CapabilityId,
    arrested_hats: std.AutoHashMap(types.HatId, bool),
    event_log: std.ArrayList(types.EventRecord),
    false_arrests: u32 = 0,

    /// Per-beacon alert interval tracking for effectiveness scoring.
    beacon_alert_tracking: [beacon_count]BeaconAlertTracking = .{BeaconAlertTracking{}} ** beacon_count,

    /// Attack occurrence counters keyed by the beacon's alert level at attack time.
    attacks_at_level_off: u32 = 0,
    attacks_at_level_one: u32 = 0,
    attacks_at_level_two: u32 = 0,

    /// Per-hat simulation state (current location, updated each tick).
    hat_states: []types.HatState,

    /// Population: hats, organizations, and taskforces.
    hats: []types.Hat,
    organizations: []types.Organization,
    taskforces: std.ArrayList(types.Taskforce),

    /// Initialize a run with a seeded population and empty runtime state.
    /// Takes ownership of run_id allocation.
    pub fn init(allocator: std.mem.Allocator, run_id: []const u8, seed: u64, params: SimParams) !RunState {
        // Convert SimParams to PopulationParams for the population generator.
        const pop_params = population.PopulationParams{
            .n_hats = params.n_hats,
            .n_benign_orgs = params.n_benign_orgs,
            .n_terrorist_orgs = params.n_terrorist_orgs,
            .fraction_covert = params.fraction_covert,
            .fraction_terrorist = params.fraction_terrorist,
            .mean_org_size = params.org_size_mean,
            .std_org_size = params.org_size_std,
            .n_capabilities = 16,
        };

        // Generate seeded population.
        const pop = try population.generate(allocator, seed, pop_params);

        var state = RunState{
            .allocator = allocator,
            .run_id = run_id,
            .seed = seed,
            .tick = 0,
            .params = params,
            .analyst_states = std.StringHashMap(AnalystState).init(allocator),
            .beacons = undefined,
            .beacon_vulnerabilities = undefined,
            .arrested_hats = std.AutoHashMap(types.HatId, bool).init(allocator),
            .event_log = .empty,
            .false_arrests = 0,
            .beacon_alert_tracking = undefined,
            .attacks_at_level_off = 0,
            .attacks_at_level_one = 0,
            .attacks_at_level_two = 0,
            .hat_states = &.{}, // replaced below
            .hats = pop.hats,
            .organizations = pop.orgs,
            .taskforces = .empty,
        };

        // Copy generated taskforces from population into the ArrayList.
        try state.taskforces.appendSlice(allocator, pop.taskforces);
        // Free the outer taskforce slice (inner allocations stay owned by taskforces).
        allocator.free(pop.taskforces);

        for (&state.beacons, 0..) |*beacon, idx| {
            const beacon_id: types.BeaconId = @intCast(idx);
            state.beacon_vulnerabilities[idx] = beaconVulnerabilities(seed, beacon_id);
            beacon.* = types.Beacon{
                .beaconId = beacon_id,
                .alertLevel = .OFF,
                .location = types.deterministicBeaconLocation(seed, beacon_id),
            };
            // Initialize alert tracking with OFF level.
            state.beacon_alert_tracking[idx] = BeaconAlertTracking{
                .current_level = .OFF,
                .interval_had_attack = false,
                .level_one = .{},
                .level_two = .{},
            };
        }

        // Initialize per-hat state (current location at tick 0, starting capabilities).
        state.hat_states = try allocator.alloc(types.HatState, state.hats.len);
        for (state.hat_states, state.hats) |*hs, hat| {
            hs.* = types.HatState{
                .current_location = types.deterministicLocation(seed, 0, hat.id),
                .capability_bits = initialCapabilities(seed, hat.id, 16),
            };
        }

        return state;
    }

    /// Release all allocations owned by the run, including analyst state, logs, and population.
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
        // Free population: org member slices, hat/org arrays.
        for (self.organizations) |org| {
            self.allocator.free(org.members);
        }
        // Free taskforces: each taskforce owns members, capabilities, and meetings slices.
        for (self.taskforces.items) |tf| {
            self.allocator.free(tf.members);
            self.allocator.free(tf.required_capabilities);
            for (tf.meeting_plan) |meeting| {
                self.allocator.free(meeting.participants);
                self.allocator.free(meeting.trades);
            }
            self.allocator.free(tf.meeting_plan);
        }
        self.taskforces.deinit(self.allocator);
        self.allocator.free(self.hat_states);
        self.allocator.free(self.hats);
        self.allocator.free(self.organizations);
        self.allocator.free(self.run_id);
    }
};

/// Close an open alert interval: if it had no attacks, increment false_positives.
/// Resets the interval to OFF.
pub fn closeAlertInterval(tracking: *BeaconAlertTracking) void {
    if (tracking.current_level != .OFF) {
        if (!tracking.interval_had_attack) {
            switch (tracking.current_level) {
                .LEVEL_ONE => tracking.level_one.false_positives += 1,
                .LEVEL_TWO => tracking.level_two.false_positives += 1,
                else => {},
            }
        }
        tracking.current_level = .OFF;
        tracking.interval_had_attack = false;
    }
}

pub const beacon_count = 5;
const beacon_vuln_count = 3;
const default_analyst_id = "human";

/// Create a new run in the registry and return its id and initial tick.
/// Params are parsed into SimParams with defaults for missing fields.
pub fn initialize(registry: *runs.Runs, payload: SimInitializeRequestPayload) !SimInitializeResponsePayload {
    const sim_params = parseSimParams(payload.params);
    const run = try registry.createRun(payload.seed, sim_params);
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
    const ticks_to_advance = payload.numberOfTicks;
    run.tick += ticks_to_advance;
    const to_tick = run.tick;

    // Update hat locations for each intermediate tick, and run org planner.
    var tick: types.Tick = from_tick + 1;
    const events_before = run.event_log.items.len;
    while (tick <= to_tick) : (tick += 1) {
        for (run.hat_states, run.hats) |*hs, hat| {
            // Stepwise movement: hat moves at most 1 cell per tick.
            hs.current_location = movement.updateLocation(
                run.seed, tick, hat.id, hs.current_location,
                run.params.grid_x_min, run.params.grid_x_max,
                run.params.grid_y_min, run.params.grid_y_max,
            );
        }
        // Run organization planner each tick (only effective on planning_interval ticks).
        try planner.plan(run.allocator, run.seed, run.params.planning_interval, tick, run.organizations, run.beacons[0..], &run.taskforces, &run.event_log);
        // Execute any meetings scheduled at this tick.
        try meetings.executeMeetings(run, tick);
    }

    const events_after = run.event_log.items.len;

    var response = SimAdvanceResponsePayload{
        .runId = run.run_id,
        .fromTick = from_tick,
        .toTick = to_tick,
        .eventsEmitted = @intCast(events_after - events_before),
        .defaultRequestResults = null,
        .timing = null,
    };

    if (payload.includeDefaultRequestResults) {
        const defaults_list = defaults.getDefaults(run, default_analyst_id);
        if (defaults_list.len > 0) {
            var results: std.ArrayList(protocol.DefaultIbResult) = .empty;
            for (defaults_list) |request| {
                const args_value = try json_util.parseJsonValue(allocator, request.args_json);
                const broker_payload = broker.BrokerCallRequestPayload{
                    .runId = run.run_id,
                    .analystId = default_analyst_id,
                    .method = request.method,
                    .args = args_value,
                };
                const broker_response = try broker.call(allocator, run, broker_payload);
                // Track spend from defaults on the default analyst.
                if (run.analyst_states.getPtr(default_analyst_id)) |analyst| {
                    analyst.spend_total += broker_response.charged;
                }
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

/// End a run and return a scoring report.
/// Computes information cost, false arrests, beacon effectiveness, and attack counts.
pub fn end(registry: *runs.Runs, allocator: std.mem.Allocator, payload: SimEndRequestPayload) !SimEndResponsePayload {
    const run = registry.get(payload.runId) orelse return error.RunNotFound;

    // Close any open alert intervals.
    for (&run.beacon_alert_tracking) |*tracking| {
        closeAlertInterval(tracking);
    }

    // Compute information cost: sum of all analyst spend_total values.
    var info_cost: f64 = 0;
    var as_iter = run.analyst_states.iterator();
    while (as_iter.next()) |entry| {
        info_cost += entry.value_ptr.spend_total;
    }

    // Build summary via struct+stringify to avoid verbose ObjectMap construction.
    const BeaconLevel = struct {
        hits: u32,
        falsePositives: u32,
    };
    const BeaconEffEntry = struct {
        beaconId: i64,
        levelOne: BeaconLevel,
        levelTwo: BeaconLevel,
    };
    const SummaryData = struct {
        informationCost: f64,
        falseArrests: u32,
        beaconEffectiveness: []const BeaconEffEntry,
        totalTicks: i64,
        attacksAttempted: u32,
        attacksSucceeded: u32,
        attacksPreventedByAlert: u32,
    };

    var beacon_eff_list: std.ArrayList(BeaconEffEntry) = .empty;
    for (run.beacon_alert_tracking, 0..) |tracking, idx| {
        try beacon_eff_list.append(allocator, .{
            .beaconId = @as(i64, @intCast(idx)),
            .levelOne = .{ .hits = tracking.level_one.hits, .falsePositives = tracking.level_one.false_positives },
            .levelTwo = .{ .hits = tracking.level_two.hits, .falsePositives = tracking.level_two.false_positives },
        });
    }

    const summary_data = SummaryData{
        .informationCost = info_cost,
        .falseArrests = run.false_arrests,
        .beaconEffectiveness = try beacon_eff_list.toOwnedSlice(allocator),
        .totalTicks = @as(i64, @intCast(run.tick)),
        .attacksAttempted = run.attacks_at_level_off + run.attacks_at_level_one + run.attacks_at_level_two,
        .attacksSucceeded = run.attacks_at_level_off,
        .attacksPreventedByAlert = run.attacks_at_level_one + run.attacks_at_level_two,
    };
    const json_text = try json_util.stringifyAlloc(allocator, summary_data);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{ .allocate = .alloc_always });
    const summary_value = parsed.value;

    return SimEndResponsePayload{
        .runId = run.run_id,
        .finalTick = run.tick,
        .summary = summary_value,
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

/// Compute initial capability bitmask for a hat deterministically from seed and hat id.
/// Each hat starts with ~30% of the total capability space, randomly selected per seed+hat.
fn initialCapabilities(seed: u64, hat_id: types.HatId, n_caps: u32) u64 {
    var bits: u64 = 0;
    var i: u32 = 0;
    while (i < n_caps) : (i += 1) {
        // Use mix to generate deterministic bits per cap index.
        const mixed = types.mix(seed ^ (@as(u64, hat_id) *% 0x9E3779B97F4A7C15) ^ (@as(u64, i) *% 0xBF58476D1CE4E5B9));
        if (mixed & 1 == 1) {
            bits |= @as(u64, 1) << @as(u6, @intCast(i));
        }
    }
    return bits;
}

// parseArgsValue moved to json_util.parseJsonValue

// ── SimParams parse tests ─────────────────────────────────────────────

const TestRun = struct {
    registry: *runs.Runs,
    run_id: []const u8,
    run: *RunState,
};

/// Create a registry and initialized run for testing, given JSON params overrides.
fn initTestRun(allocator: std.mem.Allocator, params_value: std.json.Value) !TestRun {
    var registry = try allocator.create(runs.Runs);
    registry.* = runs.Runs.init(allocator);
    const init_resp = try initialize(registry, .{ .seed = 42, .params = params_value });
    const run = registry.get(init_resp.runId) orelse return error.RunNotFound;
    return TestRun{ .registry = registry, .run_id = init_resp.runId, .run = run };
}

fn initTestRunWithParams(allocator: std.mem.Allocator, params: std.json.ObjectMap) !TestRun {
    return initTestRun(allocator, std.json.Value{ .object = params });
}

test "SimParams empty object uses all defaults" {
    const empty = std.json.Value{ .object = std.json.ObjectMap{} };
    const p = parseSimParams(empty);
    try std.testing.expectEqual(@as(u32, 200), p.n_hats);
    try std.testing.expectEqual(@as(u32, 3), p.n_benign_orgs);
    try std.testing.expectEqual(@as(u32, 2), p.n_terrorist_orgs);
    try std.testing.expectEqual(@as(f64, 8.0), p.org_size_mean);
    try std.testing.expectEqual(@as(f64, 3.0), p.org_size_std);
    try std.testing.expectEqual(@as(f64, 0.30), p.fraction_covert);
    try std.testing.expectEqual(@as(f64, 0.20), p.fraction_terrorist);
    try std.testing.expectEqual(@as(f64, 0.50), p.capability_overlap);
    try std.testing.expectEqual(@as(i32, 0), p.grid_x_min);
    try std.testing.expectEqual(@as(i32, 50), p.grid_x_max);
    try std.testing.expectEqual(@as(i32, 0), p.grid_y_min);
    try std.testing.expectEqual(@as(i32, 50), p.grid_y_max);
}

test "SimParams partial override preserves remaining defaults" {
    var obj = std.json.ObjectMap{};
    try obj.put(std.testing.allocator, "n_hats", std.json.Value{ .integer = 50 });
    const partial = std.json.Value{ .object = obj };
    const p = parseSimParams(partial);
    try std.testing.expectEqual(@as(u32, 50), p.n_hats);
    try std.testing.expectEqual(@as(u32, 3), p.n_benign_orgs);
    try std.testing.expectEqual(@as(f64, 0.30), p.fraction_covert);
}

test "SimParams non-object value returns all defaults" {
    const not_obj = std.json.Value{ .null = {} };
    const p = parseSimParams(not_obj);
    try std.testing.expectEqual(@as(u32, 200), p.n_hats);
    try std.testing.expectEqual(@as(i32, 0), p.grid_x_min);
}

test "SimParams all fields explicit are parsed correctly" {
    var obj = std.json.ObjectMap{};
    try obj.put(std.testing.allocator, "n_hats", std.json.Value{ .integer = 100 });
    try obj.put(std.testing.allocator, "n_benign_orgs", std.json.Value{ .integer = 5 });
    try obj.put(std.testing.allocator, "n_terrorist_orgs", std.json.Value{ .integer = 3 });
    try obj.put(std.testing.allocator, "org_size_mean", std.json.Value{ .float = 12.0 });
    try obj.put(std.testing.allocator, "fraction_terrorist", std.json.Value{ .float = 0.4 });
    try obj.put(std.testing.allocator, "grid_x_min", std.json.Value{ .integer = -10 });
    try obj.put(std.testing.allocator, "grid_x_max", std.json.Value{ .integer = 100 });
    const full = std.json.Value{ .object = obj };
    const p = parseSimParams(full);
    try std.testing.expectEqual(@as(u32, 100), p.n_hats);
    try std.testing.expectEqual(@as(u32, 5), p.n_benign_orgs);
    try std.testing.expectEqual(@as(u32, 3), p.n_terrorist_orgs);
    try std.testing.expectEqual(@as(f64, 12.0), p.org_size_mean);
    try std.testing.expectEqual(@as(f64, 0.4), p.fraction_terrorist);
    try std.testing.expectEqual(@as(i32, -10), p.grid_x_min);
    try std.testing.expectEqual(@as(i32, 100), p.grid_x_max);
}

test "advance(50) creates taskforces with valid meetings from both org types" {
    const allocator = std.testing.allocator;

    var params = std.json.ObjectMap{};
    try params.put(allocator, "n_hats", std.json.Value{ .integer = 200 });
    try params.put(allocator, "n_benign_orgs", std.json.Value{ .integer = 4 });
    try params.put(allocator, "n_terrorist_orgs", std.json.Value{ .integer = 2 });
    try params.put(allocator, "planning_interval", std.json.Value{ .integer = 10 });
    var tr = try initTestRunWithParams(allocator, params);
    defer tr.registry.deinit();

    // Advance 50 ticks.
    const adv_resp = try advance(tr.registry, allocator, .{
        .runId = tr.run_id,
        .numberOfTicks = 50,
        .includeDefaultRequestResults = false,
    });
    try std.testing.expectEqual(@as(u64, 0), adv_resp.fromTick);
    try std.testing.expectEqual(@as(u64, 50), adv_resp.toTick);

    const run = tr.run;

    // At least 1 taskforce total (initial terrorist taskforces + any new planner taskforces).
    try std.testing.expect(run.taskforces.items.len >= 1);

    // Both terrorist and benign orgs should have active taskforces.
    var terror_has: bool = false;
    var benign_has: bool = false;
    for (run.taskforces.items) |tf| {
        if (tf.status == .ACTIVE) {
            const org = run.organizations[tf.organization_id];
            if (org.org_type == .TERRORIST) terror_has = true;
            if (org.org_type == .BENIGN) benign_has = true;
        }
    }
    try std.testing.expect(terror_has);
    try std.testing.expect(benign_has);

    // All taskforce meetings have non-decreasing tick order and valid locations.
    for (run.taskforces.items) |tf| {
        var prev_tick: types.Tick = 0;
        for (tf.meeting_plan) |m| {
            try std.testing.expect(m.tick >= prev_tick);
            prev_tick = m.tick;
            // Valid grid locations.
            try std.testing.expect(m.location.x >= 0 and m.location.x <= types.WorldMax);
            try std.testing.expect(m.location.y >= 0 and m.location.y <= types.WorldMax);
        }
    }
}

test "end returns correct final tick and summary" {
    const allocator = std.testing.allocator;

    var params = std.json.ObjectMap{};
    try params.put(allocator, "n_hats", std.json.Value{ .integer = 50 });
    try params.put(allocator, "n_benign_orgs", std.json.Value{ .integer = 2 });
    try params.put(allocator, "n_terrorist_orgs", std.json.Value{ .integer = 1 });
    var tr = try initTestRunWithParams(allocator, params);
    defer tr.registry.deinit();

    // Advance 20 ticks.
    _ = try advance(tr.registry, allocator, .{
        .runId = tr.run_id,
        .numberOfTicks = 20,
        .includeDefaultRequestResults = false,
    });

    // End the run.
    const end_resp = try end(tr.registry, allocator, .{ .runId = tr.run_id });
    try std.testing.expectEqualStrings(tr.run_id, end_resp.runId);
    try std.testing.expectEqual(@as(u64, 20), end_resp.finalTick);
    _ = end_resp.summary; // summary should exist
}

test "end returns complete scoring report with alert and arrest actions" {
    const allocator = std.testing.allocator;

    var params = std.json.ObjectMap{};
    try params.put(allocator, "n_hats", std.json.Value{ .integer = 100 });
    try params.put(allocator, "n_benign_orgs", std.json.Value{ .integer = 3 });
    try params.put(allocator, "n_terrorist_orgs", std.json.Value{ .integer = 2 });
    try params.put(allocator, "planning_interval", std.json.Value{ .integer = 10 });
    var tr = try initTestRunWithParams(allocator, params);
    defer tr.registry.deinit();

    const run = tr.run;

    // Advance enough ticks to create taskforces.
    _ = try advance(tr.registry, allocator, .{
        .runId = tr.run_id,
        .numberOfTicks = 50,
        .includeDefaultRequestResults = false,
    });

    // Set a beacon alert (simulates analyst action).
    _ = try actions.alertBeacon(run, .{
        .runId = tr.run_id,
        .analystId = "test-analyst",
        .beaconId = 0,
        .alertLevel = .LEVEL_ONE,
    });

    // Attempt an arrest on a hat known to be benign (will fail → false arrest).
    const benign_id = actions.findBenignHat(run);
    if (benign_id) |hat_id| {
        run.hat_states[hat_id].current_location = .{ .x = 10, .y = 10 };
        _ = try actions.arrestHat(run, .{
            .runId = tr.run_id,
            .analystId = "test-analyst",
            .hatId = hat_id,
            .location = .{ .x = 10, .y = 10 },
        });
    }

    // End the run.
    const end_resp = try end(tr.registry, allocator, .{ .runId = tr.run_id });
    try std.testing.expectEqualStrings(tr.run_id, end_resp.runId);
    try std.testing.expect(end_resp.finalTick >= 50);

    const summary = end_resp.summary;
    try std.testing.expect(summary == .object);

    // Validate all expected summary fields.
    const obj = summary.object;
    try std.testing.expect(obj.contains("informationCost"));
    try std.testing.expect(obj.contains("falseArrests"));
    try std.testing.expect(obj.contains("beaconEffectiveness"));
    try std.testing.expect(obj.contains("totalTicks"));
    try std.testing.expect(obj.contains("attacksAttempted"));
    try std.testing.expect(obj.contains("attacksSucceeded"));
    try std.testing.expect(obj.contains("attacksPreventedByAlert"));

    // falseArrests > 0 after a failed arrest.
    const false_arrests = obj.get("falseArrests").?.integer;
    try std.testing.expect(false_arrests > 0);

    // Beacon effectiveness is a non-empty array.
    const beacon_eff = obj.get("beaconEffectiveness").?.array;
    try std.testing.expect(beacon_eff.items.len > 0);

    // Verify beacon effectiveness entry structure.
    const entry0 = beacon_eff.items[0].object;
    try std.testing.expect(entry0.contains("beaconId"));
    try std.testing.expect(entry0.contains("levelOne"));
    try std.testing.expect(entry0.contains("levelTwo"));
    try std.testing.expect(entry0.get("levelOne").?.object.contains("hits"));
    try std.testing.expect(entry0.get("levelOne").?.object.contains("falsePositives"));
    try std.testing.expect(entry0.get("levelTwo").?.object.contains("hits"));
    try std.testing.expect(entry0.get("levelTwo").?.object.contains("falsePositives"));

    // totalTicks is > 0.
    try std.testing.expect(obj.get("totalTicks").?.integer > 0);
}

test "beacon vulnerabilities for seed=42 are all in [0, 15]" {
    const allocator = std.testing.allocator;
    var registry = runs.Runs.init(allocator);
    defer registry.deinit();
    const run = try registry.createRun(42, .{});
    // Every beacon must have exactly 3 vulnerabilities (matching beacon_vuln_count),
    // and every vulnerability value must be a per-cap ID in [0, 15] (not a raw
    // bitmask that would exceed 15).
    for (run.beacon_vulnerabilities, 0..) |vulns, beacon_idx| {
        // Verify exact count: 3 per beacon.
        try std.testing.expectEqual(@as(usize, 3), vulns.len);
        for (vulns) |vuln| {
            if (vuln > 15) {
                std.debug.panic("beacon[{}] vulnerability {} exceeds 15 (got raw bitmask?)", .{ beacon_idx, vuln });
            }
            // Also verify that a hat with all 16 caps set could satisfy it.
            try std.testing.expect(types.hasCapability(0xFFFF, vuln));
        }
    }
}

test "planner taskforce_created events match beacon locations (seed=42, 100 ticks)" {
    // This test verifies the planner targets match broker beacon locations.
    // If this fails, the planner is selecting beacon indices that don't match
    // the broker's beacon array order.
    const allocator = std.testing.allocator;

    var params = std.json.ObjectMap{};
    try params.put(allocator, "n_hats", std.json.Value{ .integer = 200 });
    try params.put(allocator, "n_benign_orgs", std.json.Value{ .integer = 3 });
    try params.put(allocator, "n_terrorist_orgs", std.json.Value{ .integer = 2 });
    try params.put(allocator, "planning_interval", std.json.Value{ .integer = 10 });
    var tr = try initTestRunWithParams(allocator, params);
    defer tr.registry.deinit();

    const run = tr.run;

    // Advance 100 ticks like the reproducer script.
    _ = try advance(tr.registry, allocator, .{
        .runId = tr.run_id,
        .numberOfTicks = 100,
        .includeDefaultRequestResults = false,
    });

    // Collect beacon locations.
    var beacon_locs: [beacon_count]types.Location = undefined;
    for (run.beacons, 0..) |b, i| {
        beacon_locs[i] = b.location;
    }

    // Check taskforce_created events for beacon-matching targets.
    // This directly validates the acceptance criteria:
    // "at least one taskforce_created event has a target that matches
    //  one of the 5 broker-reported beacon locations."
    var event_match_count: usize = 0;
    for (run.event_log.items) |ev| {
        if (std.mem.eql(u8, ev.type, "taskforce_created")) {
            if (ev.location) |loc| {
                for (beacon_locs) |bl| {
                    if (loc.x == bl.x and loc.y == bl.y) {
                        event_match_count += 1;
                        break;
                    }
                }
            }
        }
    }

    // At least one taskforce_created event must have a target matching a beacon.
    try std.testing.expect(event_match_count >= 1);
}

test "advance with 0 ticks does not change state" {
    const allocator = std.testing.allocator;

    var params = std.json.ObjectMap{};
    try params.put(allocator, "n_hats", std.json.Value{ .integer = 50 });
    try params.put(allocator, "planning_interval", std.json.Value{ .integer = 10 });
    var tr = try initTestRunWithParams(allocator, params);
    defer tr.registry.deinit();

    const run = tr.run;
    const events_before = run.event_log.items.len;
    const tf_before = run.taskforces.items.len;

    _ = try advance(tr.registry, allocator, .{
        .runId = tr.run_id,
        .numberOfTicks = 0,
        .includeDefaultRequestResults = false,
    });

    try std.testing.expectEqual(@as(u64, 0), run.tick);
    try std.testing.expectEqual(events_before, run.event_log.items.len);
    try std.testing.expectEqual(tf_before, run.taskforces.items.len);
}
