//! Autonomous simulation demo: exercises the full engine end-to-end.
//!
//! Six phases:
//!   1. Initialize with seed + custom params (n_hats=50, grid 30×30)
//!   2. Add defaults: ib.beacons, ib.events_history
//!   3. Advance 50 ticks (seeds meetings, taskforces, attacks)
//!   4. Broker calls: free queries + paid queries on a known terrorist
//!   5. Alert beacon 0 to LEVEL_ONE, advance 50 ticks
//!   6. Arrest a known terrorist, advance 20 ticks, end, print scoring report
//!
//! Output: JSON lines per operation, then a structured scoring report.
const std = @import("std");
const sim = @import("sim.zig");
const runs = @import("runs.zig");
const broker = @import("broker.zig");
const defaults = @import("defaults.zig");
const actions = @import("actions.zig");
const protocol = @import("protocol.zig");
const types = @import("types.zig");
const json_util = @import("json_util.zig");

pub fn main() !void {
    try runDemo();
}

/// Run the full autonomous simulation demo.
pub fn runDemo() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var registry = runs.Runs.init(allocator);
    defer registry.deinit();

    // ── Phase 1: Initialize run ──────────────────────────────────────────
    var params_obj = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try params_obj.put(allocator, "n_hats", std.json.Value{ .integer = 50 });
    try params_obj.put(allocator, "grid_x_max", std.json.Value{ .integer = 29 });
    try params_obj.put(allocator, "grid_y_max", std.json.Value{ .integer = 29 });
    try params_obj.put(allocator, "planning_interval", std.json.Value{ .integer = 10 });

    const init_resp = try sim.initialize(&registry, .{
        .seed = 1234,
        .params = std.json.Value{ .object = params_obj },
    });
    params_obj.deinit(allocator);
    std.debug.print("--- Phase 1: Initialize ---\n", .{});
    try printJson(init_resp);

    const run_id = init_resp.runId;
    const run = registry.get(run_id).?;
    std.debug.print("  Hats={d}  Orgs={d}  Taskforces={d}\n\n", .{
        run.hats.len,
        run.organizations.len,
        run.taskforces.items.len,
    });

    // ── Phase 2: Add defaults ────────────────────────────────────────────
    {
        var empty1 = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        var empty2 = try std.json.ObjectMap.init(allocator, &.{}, &.{});

        const default_requests = [_]protocol.DefaultIbRequest{
            .{ .method = "ib.beacons", .args = std.json.Value{ .object = empty1 } },
            .{ .method = "ib.events_history", .args = std.json.Value{ .object = empty2 } },
        };
        const defaults_resp = try defaults.add(allocator, run, .{
            .runId = run_id,
            .analystId = "human",
            .requests = &default_requests,
        });
        empty1.deinit(allocator);
        empty2.deinit(allocator);
        std.debug.print("--- Phase 2: Add Defaults ---\n", .{});
        try printJson(defaults_resp);
        std.debug.print("\n", .{});
    }

    // ── Phase 3: Advance 50 ticks ────────────────────────────────────────
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const advance_resp = try sim.advance(&registry, arena_alloc, .{
            .runId = run_id,
            .numberOfTicks = 50,
            .timeIt = true,
            .includeDefaultRequestResults = true,
        });
        std.debug.print("--- Phase 3: Advance 50 ticks ---\n", .{});
        try printJson(advance_resp);
        std.debug.print("  Taskforces after={d}  Events so far={d}\n\n", .{
            run.taskforces.items.len,
            run.event_log.items.len,
        });
    }

    // ── Phase 4: Broker calls (free + paid) ──────────────────────────────
    var target_hat_id: types.HatId = 0;
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        std.debug.print("--- Phase 4a: Free broker queries ---\n", .{});

        // ib.world_dimensions (free)
        {
            const empty = try std.json.ObjectMap.init(arena_alloc, &.{}, &.{});
            const resp = try broker.call(arena_alloc, run, .{
                .runId = run_id,
                .analystId = "human",
                .method = "ib.world_dimensions",
                .args = std.json.Value{ .object = empty },
            });
            try printJson(resp);
        }

        // ib.known_terrorist_hats (free, partial info)
        var known_hat_ids: []types.HatId = &[_]types.HatId{};
        {
            const empty = try std.json.ObjectMap.init(arena_alloc, &.{}, &.{});
            const resp = try broker.call(arena_alloc, run, .{
                .runId = run_id,
                .analystId = "human",
                .method = "ib.known_terrorist_hats",
                .args = std.json.Value{ .object = empty },
            });
            try printJson(resp);

            // Parse hat IDs from the result for paid queries.
            const obj = resp.result.object;
            const arr = obj.get("hatIds") orelse return error.MissingHatIds;
            if (arr.array.items.len > 0) {
                const hats_slice = try arena_alloc.alloc(types.HatId, arr.array.items.len);
                for (arr.array.items, hats_slice) |item, *h| {
                    h.* = @intCast(item.integer);
                }
                known_hat_ids = hats_slice;
            }
        }

        // Pick first known terrorist hat for paid queries.
        if (known_hat_ids.len == 0) {
            std.debug.print("  WARNING: no known terrorist hats found (IB partial info). " ++
                "Falling back to run state.\n", .{});
            for (run.hats) |hat| {
                if (hat.true_color == .TERRORIST) {
                    target_hat_id = hat.id;
                    break;
                }
            }
        } else {
            target_hat_id = known_hat_ids[0];
        }

        std.debug.print("  Targeting hat {d} for paid queries\n\n", .{target_hat_id});

        std.debug.print("--- Phase 4b: Paid broker queries ---\n", .{});

        // ib.last_location (paid)
        {
            const broker_args = try jsonObject(arena_alloc, &.{
                .{ .key = "hatId", .value = std.json.Value{ .integer = target_hat_id } },
                .{ .key = "payment", .value = std.json.Value{ .float = 5.0 } },
            });
            const resp = try broker.call(arena_alloc, run, .{
                .runId = run_id,
                .analystId = "human",
                .method = "ib.last_location",
                .args = broker_args,
            });
            try printJson(resp);
        }

        // ib.capabilities (paid)
        {
            const broker_args = try jsonObject(arena_alloc, &.{
                .{ .key = "hatId", .value = std.json.Value{ .integer = target_hat_id } },
                .{ .key = "payment", .value = std.json.Value{ .float = 5.0 } },
            });
            const resp = try broker.call(arena_alloc, run, .{
                .runId = run_id,
                .analystId = "human",
                .method = "ib.capabilities",
                .args = broker_args,
            });
            try printJson(resp);
        }
    }

    // ── Phase 5: Alert beacon + advance 50 ticks ─────────────────────────
    {
        std.debug.print("--- Phase 5a: Alert beacon 0 to LEVEL_ONE ---\n", .{});
        const alert_resp = try actions.alertBeacon(run, .{
            .runId = run_id,
            .analystId = "human",
            .beaconId = 0,
            .alertLevel = .LEVEL_ONE,
        });
        try printJson(alert_resp);
        std.debug.print("\n", .{});

        {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const arena_alloc = arena.allocator();

            std.debug.print("--- Phase 5b: Advance 50 more ticks ---\n", .{});
            const advance_resp = try sim.advance(&registry, arena_alloc, .{
                .runId = run_id,
                .numberOfTicks = 50,
                .timeIt = true,
                .includeDefaultRequestResults = true,
            });
            try printJson(advance_resp);
            std.debug.print("  Total ticks={d}  Events so far={d}\n\n", .{
                run.tick,
                run.event_log.items.len,
            });
        }
    }

    // ── Phase 6: Arrest + advance 20 ticks + end ─────────────────────────
    {
        std.debug.print("--- Phase 6a: Attempt arrest of hat {d} ---\n", .{target_hat_id});

        // Get the hat's current location from the run state for the arrest.
        const arrest_location = run.hat_states[target_hat_id].current_location;
        const arrest_resp = try actions.arrestHat(run, .{
            .runId = run_id,
            .analystId = "human",
            .hatId = target_hat_id,
            .location = arrest_location,
        });
        try printJson(arrest_resp);
        std.debug.print("\n", .{});

        {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const arena_alloc = arena.allocator();

            std.debug.print("--- Phase 6b: Advance 20 more ticks ---\n", .{});
            const advance_resp = try sim.advance(&registry, arena_alloc, .{
                .runId = run_id,
                .numberOfTicks = 20,
                .timeIt = true,
                .includeDefaultRequestResults = true,
            });
            try printJson(advance_resp);
            std.debug.print("\n", .{});
        }

        std.debug.print("--- Phase 6c: End run ---\n", .{});
        {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const arena_alloc = arena.allocator();
            const end_resp = try sim.end(&registry, arena_alloc, .{ .runId = run_id });
            try printJson(end_resp);
        }
        std.debug.print("\n", .{});
    }

    // ── Final scoring report ─────────────────────────────────────────────
    {
        var n_meetings: u64 = 0;
        var n_trades: u64 = 0;
        var n_arrests: u64 = 0;
        var n_false_arrests_events: u64 = 0;
        var n_attacks: u64 = 0;
        var n_alerts: u64 = 0;
        var n_taskforces_disbanded: u64 = 0;

        for (run.event_log.items) |ev| {
            if (std.mem.eql(u8, ev.type, types.event_type_meeting)) n_meetings += 1;
            if (std.mem.eql(u8, ev.type, types.event_type_trade)) n_trades += 1;
            if (std.mem.eql(u8, ev.type, types.event_type_arrest)) n_arrests += 1;
            if (std.mem.eql(u8, ev.type, types.event_type_false_arrest)) n_false_arrests_events += 1;
            if (std.mem.eql(u8, ev.type, types.event_type_attack)) n_attacks += 1;
            if (std.mem.eql(u8, ev.type, types.event_type_alert_change)) n_alerts += 1;
            if (std.mem.eql(u8, ev.type, types.event_type_disbanded)) n_taskforces_disbanded += 1;
        }

        var n_active_taskforces: u64 = 0;
        var n_disbanded_taskforces: u64 = 0;
        for (run.taskforces.items) |tf| {
            if (tf.status == .ACTIVE) n_active_taskforces += 1;
            if (tf.status == .DISBANDED) n_disbanded_taskforces += 1;
        }

        std.debug.print("========== SCORING REPORT ==========\n", .{});
        std.debug.print("  finalTick:              {d}\n", .{run.tick});
        std.debug.print("  totalHats:              {d}\n", .{run.hats.len});
        std.debug.print("  totalOrganizations:     {d}\n", .{run.organizations.len});
        std.debug.print("  totalTaskforces:        {d}\n", .{run.taskforces.items.len});
        std.debug.print("    active:               {d}\n", .{n_active_taskforces});
        std.debug.print("    disbanded:            {d}\n", .{n_disbanded_taskforces});
        std.debug.print("  totalEvents:            {d}\n", .{run.event_log.items.len});
        std.debug.print("    meetings:             {d}\n", .{n_meetings});
        std.debug.print("    capabilityTrades:     {d}\n", .{n_trades});
        std.debug.print("    arrests (successful): {d}\n", .{n_arrests});
        std.debug.print("    falseArrests:         {d}\n", .{n_false_arrests_events});
        std.debug.print("    attacksDetected:      {d}\n", .{n_attacks});
        std.debug.print("    alertChanges:         {d}\n", .{n_alerts});
        std.debug.print("    taskforcesDisbanded:  {d}\n", .{n_taskforces_disbanded});
        std.debug.print("  falseArrestsCounter:    {d}\n", .{run.false_arrests});
        std.debug.print("  arrestedHats:           {d}\n", .{run.arrested_hats.count()});
        std.debug.print("  targetHat:              {d}\n", .{target_hat_id});
        std.debug.print("====================================\n", .{});
    }
}

/// Build a JSON object value from key/value pairs.
fn jsonObject(allocator: std.mem.Allocator, fields: []const struct { key: []const u8, value: std.json.Value }) !std.json.Value {
    var obj = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    for (fields) |field| {
        try obj.put(allocator, field.key, field.value);
    }
    return std.json.Value{ .object = obj };
}

/// Serialize a value to JSON and write it to stdout.
fn printJson(value: anytype) !void {
    const json_text = try json_util.stringifyAlloc(std.heap.page_allocator, value);
    defer std.heap.page_allocator.free(json_text);
    std.debug.print("{s}\n", .{json_text});
}
