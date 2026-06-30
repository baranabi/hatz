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

/// Parse a JSON string into a dynamic JSON value.
/// The parsed value is allocated using the provided allocator and owned by the caller.
pub fn parseJsonValue(allocator: std.mem.Allocator, json_bytes: []const u8) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{ .allocate = .alloc_always });
    return parsed.value;
}
