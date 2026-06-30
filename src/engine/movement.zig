//! Deterministic stepwise hat movement model.
//!
//! Each tick, a hat has ~30% probability of moving one step in one
//! of the 8 cardinal directions. Movement is deterministic given the seed,
//! hat id, and tick. This replaces the pure hash-based location function with
//! a stepwise model that respects continuity (no teleportation).
//!
//! The initial location at tick 0 is set during RunState.init (via
//! types.deterministicLocation). This module computes movement from the
//! previous tick's location to the next — no circular dependency with sim.zig.
const std = @import("std");
const types = @import("types.zig");

/// Deterministic movement step for one hat on one tick.
/// Returns the hat's new location after applying movement from `current`.
///
/// Parameters:
/// - `seed`: simulation seed for deterministic RNG
/// - `tick`: the tick to compute movement for (informs RNG + initial placement)
/// - `hat_id`: which hat is moving (informs RNG)
/// - `current`: the hat's location at (tick - 1)
/// - grid bounds: world dimensions for clamping
pub fn updateLocation(
    seed: u64,
    tick: types.Tick,
    hat_id: types.HatId,
    current: types.Location,
    grid_x_min: i32,
    grid_x_max: i32,
    grid_y_min: i32,
    grid_y_max: i32,
) types.Location {
    // Deterministic RNG for this hat+tick.
    const mix_key = types.mix(
        seed ^ (@as(u64, hat_id) *% 0x9E3779B97F4A7C15) ^ (tick *% 0xBF58476D1CE4E5B9),
    );

    // 30% chance to move (threshold at 30/100).
    if (mix_key % 100 >= 30) return current;

    // 8-directional movement: pick direction from remaining entropy.
    const dir_idx = (mix_key >> 8) % 8;
    const dx: [8]i32 = .{ 0, 1, 1, 1, 0, -1, -1, -1 };
    const dy: [8]i32 = .{ -1, -1, 0, 1, 1, 1, 0, -1 };

    var new_x = current.x + dx[dir_idx];
    var new_y = current.y + dy[dir_idx];

    // Clamp to grid bounds.
    if (new_x < grid_x_min) new_x = grid_x_min;
    if (new_x > grid_x_max) new_x = grid_x_max;
    if (new_y < grid_y_min) new_y = grid_y_min;
    if (new_y > grid_y_max) new_y = grid_y_max;

    return types.Location{ .x = new_x, .y = new_y };
}

// ── Tests ──────────────────────────────────────────────────────────────

test "updateLocation is deterministic" {
    const params = .{ .x_min = 0, .x_max = 50, .y_min = 0, .y_max = 50 };
    const start = types.Location{ .x = 25, .y = 25 };
    const a = updateLocation(42, 10, 5, start, params.x_min, params.x_max, params.y_min, params.y_max);
    const b = updateLocation(42, 10, 5, start, params.x_min, params.x_max, params.y_min, params.y_max);
    try std.testing.expectEqual(a.x, b.x);
    try std.testing.expectEqual(a.y, b.y);
}

test "updateLocation moves at most 1 step per tick" {
    const params = .{ .x_min = 0, .x_max = 50, .y_min = 0, .y_max = 50 };
    var loc = types.Location{ .x = 25, .y = 25 };

    var tick: types.Tick = 1;
    while (tick <= 1000) : (tick += 1) {
        const prev = loc;
        loc = updateLocation(42, tick, 5, prev, params.x_min, params.x_max, params.y_min, params.y_max);
        const dx = @abs(loc.x - prev.x);
        const dy = @abs(loc.y - prev.y);
        try std.testing.expect(dx <= 1);
        try std.testing.expect(dy <= 1);
        try std.testing.expect(dx + dy <= 2);
    }
}

test "updateLocation stays within grid bounds" {
    const params = .{ .x_min = 0, .x_max = 50, .y_min = 0, .y_max = 50 };
    var loc = types.Location{ .x = 0, .y = 0 };

    var tick: types.Tick = 1;
    while (tick <= 1000) : (tick += 1) {
        loc = updateLocation(42, tick, 5, loc, params.x_min, params.x_max, params.y_min, params.y_max);
        try std.testing.expect(loc.x >= 0);
        try std.testing.expect(loc.x <= 50);
        try std.testing.expect(loc.y >= 0);
        try std.testing.expect(loc.y <= 50);
    }
}

test "updateLocation different hats diverge from same start" {
    const params = .{ .x_min = 0, .x_max = 50, .y_min = 0, .y_max = 50 };
    var loc_0 = types.Location{ .x = 25, .y = 25 };
    var loc_1 = types.Location{ .x = 25, .y = 25 };

    var tick: types.Tick = 1;
    while (tick <= 100) : (tick += 1) {
        loc_0 = updateLocation(42, tick, 0, loc_0, params.x_min, params.x_max, params.y_min, params.y_max);
        loc_1 = updateLocation(42, tick, 1, loc_1, params.x_min, params.x_max, params.y_min, params.y_max);
    }

    // Two hats starting at the same location should have diverged after 100 ticks.
    try std.testing.expect(loc_0.x != loc_1.x or loc_0.y != loc_1.y);
}

test "updateLocation 100-tick trace is deterministic per seed" {
    const params = .{ .x_min = 0, .x_max = 50, .y_min = 0, .y_max = 50 };

    // Compute trace for seed=42, hat 0.
    var trace_a: [101]types.Location = undefined;
    trace_a[0] = types.Location{ .x = 25, .y = 25 };
    var tick: types.Tick = 1;
    while (tick <= 100) : (tick += 1) {
        trace_a[tick] = updateLocation(42, tick, 0, trace_a[tick - 1], params.x_min, params.x_max, params.y_min, params.y_max);
    }

    // Same seed produces identical trace.
    var trace_b: [101]types.Location = undefined;
    trace_b[0] = types.Location{ .x = 25, .y = 25 };
    tick = 1;
    while (tick <= 100) : (tick += 1) {
        trace_b[tick] = updateLocation(42, tick, 0, trace_b[tick - 1], params.x_min, params.x_max, params.y_min, params.y_max);
    }

    // Verify every tick matches.
    for (0..101) |i| {
        try std.testing.expectEqual(trace_a[i].x, trace_b[i].x);
        try std.testing.expectEqual(trace_a[i].y, trace_b[i].y);
    }
}

test "updateLocation handles boundary clamps at grid edges" {
    const params = .{ .x_min = 0, .x_max = 5, .y_min = 0, .y_max = 5 };
    var loc = types.Location{ .x = 0, .y = 0 };

    // 500 ticks starting at (0,0) — should stay in bounds.
    var tick: types.Tick = 1;
    while (tick <= 500) : (tick += 1) {
        loc = updateLocation(42, tick, 5, loc, params.x_min, params.x_max, params.y_min, params.y_max);
        try std.testing.expect(loc.x >= 0 and loc.x <= 5);
        try std.testing.expect(loc.y >= 0 and loc.y <= 5);
    }

    // Start at (5,5) — opposite corner.
    loc = types.Location{ .x = 5, .y = 5 };
    tick = 1;
    while (tick <= 500) : (tick += 1) {
        loc = updateLocation(42, tick, 5, loc, params.x_min, params.x_max, params.y_min, params.y_max);
        try std.testing.expect(loc.x >= 0 and loc.x <= 5);
        try std.testing.expect(loc.y >= 0 and loc.y <= 5);
    }
}
