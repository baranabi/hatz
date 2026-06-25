//! Small JSON helpers to bridge std.json APIs across versions.
const std = @import("std");

/// Serialize a value to JSON using an allocating writer.
/// This normalizes std.json usage across Zig versions and keeps ownership explicit.
pub fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}
