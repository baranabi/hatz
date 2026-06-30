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

/// Recursively free a std.json.Value tree where each string was individually
/// allocated (e.g. via jsonValueClone or parseFromSliceLeaky).
/// std.json.Value itself has no built-in deinit, so this recursively walks
/// the tree and frees strings, ObjectMap keys, and container backing storage.
/// Caller must ensure `value` was allocated with the same allocator.
pub fn jsonValueDeinit(allocator: std.mem.Allocator, value: *const std.json.Value) void {
    const v = @constCast(value);
    switch (v.*) {
        .null, .bool, .integer, .float => {},
        .string => |s| allocator.free(@constCast(s)),
        .number_string => |s| allocator.free(@constCast(s)),
        .array => {
            const arr = &v.array;
            for (arr.items) |*item| {
                jsonValueDeinit(allocator, item);
            }
            arr.deinit();
        },
        .object => {
            var obj = &v.object;
            var it = obj.iterator();
            while (it.next()) |entry| {
                jsonValueDeinit(allocator, entry.value_ptr);
            }
            obj.deinit(allocator); // frees keys + internal map storage
        },
    }
}

/// Deep-clone a std.json.Value tree from one allocator domain to another.
/// Typically used to move a value out of a temporary arena into individually-owned allocations.
pub fn jsonValueClone(allocator: std.mem.Allocator, value: *const std.json.Value) !std.json.Value {
    switch (value.*) {
        .null => return std.json.Value.null,
        .bool => |b| return std.json.Value{ .bool = b },
        .integer => |i| return std.json.Value{ .integer = i },
        .float => |f| return std.json.Value{ .float = f },
        .string => |s| return std.json.Value{ .string = try allocator.dupe(u8, s) },
        .number_string => |s| return std.json.Value{ .number_string = try allocator.dupe(u8, s) },
        .array => {
            var arr = std.json.Array.init(allocator);
            errdefer arr.deinit();
            for (value.array.items) |*item| {
                try arr.append(try jsonValueClone(allocator, item));
            }
            return std.json.Value{ .array = arr };
        },
        .object => {
            var obj = try std.json.ObjectMap.init(allocator, &.{}, &.{});
            errdefer obj.deinit(allocator);
            var it = value.object.iterator();
            while (it.next()) |entry| {
                const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key_copy);
                const val_copy = try jsonValueClone(allocator, entry.value_ptr);
                try obj.put(allocator, key_copy, val_copy);
            }
            return std.json.Value{ .object = obj };
        },
    }
}

/// Parse a JSON string into a dynamic JSON value.
/// The parsed value is allocated using the provided allocator and owned by the caller.
/// The caller must call `jsonValueDeinit(allocator, &value)` when done.
pub fn parseJsonValue(allocator: std.mem.Allocator, json_bytes: []const u8) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    return try jsonValueClone(allocator, &parsed.value);
}
