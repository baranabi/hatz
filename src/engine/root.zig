//! Public entry point for the stub engine module.
pub const types = @import("types.zig");
pub const protocol = @import("protocol.zig");
pub const sim = @import("sim.zig");
pub const broker = @import("broker.zig");
pub const defaults = @import("defaults.zig");
pub const actions = @import("actions.zig");
pub const runs = @import("runs.zig");
pub const router = @import("router.zig");
pub const demo = @import("main.zig");
pub const population = @import("population.zig");
pub const planner = @import("planner.zig");
pub const meetings = @import("meetings.zig");
pub const attack = @import("attack.zig");
pub const json_util = @import("json_util.zig");
pub const movement = @import("movement.zig");

// ponytail: Zig 0.16.0 test runner only executes test blocks from files
// explicitly imported via comptime. Without these, `zig test root.zig`
// and `zig build test` would report 0 engine tests.
comptime {
    _ = @import("types.zig");
    _ = @import("sim.zig");
    _ = @import("broker.zig");
    _ = @import("defaults.zig");
    _ = @import("actions.zig");
    _ = @import("runs.zig");
    _ = @import("population.zig");
    _ = @import("planner.zig");
    _ = @import("meetings.zig");
    _ = @import("attack.zig");
    _ = @import("json_util.zig");
    _ = @import("router.zig");
    _ = @import("movement.zig");
    _ = @import("verif_paid_queries.zig");
}
