//! CLI entrypoint that runs the demo harness.
const std = @import("std");
const engine = @import("engine");

/// Run the demo harness from the engine module.
pub fn main() !void {
    try engine.demo.runDemo();
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz removed for 0.16 compat" {}
