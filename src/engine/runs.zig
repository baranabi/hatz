//! Run registry for in-memory daemon/test usage.
const std = @import("std");
const sim = @import("sim.zig");

pub const Runs = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(*sim.RunState),
    next_id: u64,

    /// Initialize the run registry with a backing allocator.
    /// The registry owns created runs and cleans them up in deinit.
    pub fn init(allocator: std.mem.Allocator) Runs {
        return Runs{
            .allocator = allocator,
            .map = std.StringHashMap(*sim.RunState).init(allocator),
            .next_id = 1,
        };
    }

    /// Release all run state owned by the registry.
    /// This is the terminal cleanup for in-memory simulations.
    pub fn deinit(self: *Runs) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            const run = entry.value_ptr.*;
            run.deinit();
            self.allocator.destroy(run);
        }
        self.map.deinit();
    }

    /// Create a new run with a deterministic id derived from seed and an incrementing counter.
    pub fn createRun(self: *Runs, seed: u64, params: sim.SimParams) !*sim.RunState {
        const run_id = try std.fmt.allocPrint(self.allocator, "run-{d}-{d}", .{ seed, self.next_id });
        self.next_id += 1;
        const run_ptr = try self.allocator.create(sim.RunState);
        run_ptr.* = try sim.RunState.init(self.allocator, run_id, seed, params);
        try self.map.put(run_id, run_ptr);
        return run_ptr;
    }

    /// Look up a run by id, returning null when missing.
    pub fn get(self: *Runs, run_id: []const u8) ?*sim.RunState {
        return self.map.get(run_id);
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "Runs init and createRun produce unique IDs" {
    const allocator = std.testing.allocator;
    var registry = Runs.init(allocator);
    defer registry.deinit();

    const params = sim.SimParams{ .n_hats = 10, .n_benign_orgs = 1, .n_terrorist_orgs = 1 };
    const run_a = try registry.createRun(42, params);
    const run_b = try registry.createRun(42, params);
    try std.testing.expect(!std.mem.eql(u8, run_a.run_id, run_b.run_id));
    try std.testing.expect(run_a.seed == 42);
    try std.testing.expect(run_b.seed == 42);
    try std.testing.expect(run_a.params.n_hats == 10);
}

test "Runs get returns null for missing run" {
    const allocator = std.testing.allocator;
    var registry = Runs.init(allocator);
    defer registry.deinit();

    try std.testing.expect(registry.get("nonexistent-run") == null);
}

test "Runs get returns created run by ID" {
    const allocator = std.testing.allocator;
    var registry = Runs.init(allocator);
    defer registry.deinit();

    const params = sim.SimParams{ .n_hats = 10, .n_benign_orgs = 1, .n_terrorist_orgs = 1 };
    const created = try registry.createRun(42, params);
    const looked_up = registry.get(created.run_id) orelse return error.TestFailed;
    try std.testing.expectEqual(created, looked_up);
    try std.testing.expectEqual(created.seed, looked_up.seed);
}

test "Runs deinit reclaims all memory (no leaks)" {
    const allocator = std.testing.allocator;
    var registry = Runs.init(allocator);
    const params = sim.SimParams{ .n_hats = 10, .n_benign_orgs = 1, .n_terrorist_orgs = 1 };
    _ = try registry.createRun(42, params);
    _ = try registry.createRun(99, params);
    registry.deinit();
    // If deinit leaks, std.testing.allocator will report it after test scope.
}
