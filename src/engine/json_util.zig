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
                allocator.free(@constCast(entry.key_ptr.*));
                jsonValueDeinit(allocator, entry.value_ptr);
            }
            obj.deinit(allocator); // frees backing storage + index header
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

// ── Tests ──────────────────────────────────────────────────────────

test "stringifyAlloc and parseJsonValue round-trip scalar types" {
    const allocator = std.testing.allocator;
    const value = std.json.Value{ .integer = 42 };
    const json_bytes = try stringifyAlloc(allocator, value);
    defer allocator.free(json_bytes);
    const parsed = try parseJsonValue(allocator, json_bytes);
    defer jsonValueDeinit(allocator, &parsed);
    try std.testing.expectEqual(@as(std.json.Value, .{ .integer = 42 }), parsed);
}

test "stringifyAlloc and parseJsonValue round-trip struct with nested arrays" {
    const allocator = std.testing.allocator;
    const TestStruct = struct {
        name: []const u8,
        values: []const i32,
        flag: bool,
    };
    const ts = TestStruct{ .name = "hello", .values = &.{ 1, 2, 3 }, .flag = true };
    const json_text = try stringifyAlloc(allocator, ts);
    defer allocator.free(json_text);
    const parsed = try parseJsonValue(allocator, json_text);
    defer jsonValueDeinit(allocator, &parsed);
    try std.testing.expect(parsed == .object);
    try std.testing.expectEqual(@as(usize, 3), parsed.object.get("values").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 1), parsed.object.get("values").?.array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 2), parsed.object.get("values").?.array.items[1].integer);
    try std.testing.expectEqual(@as(i64, 3), parsed.object.get("values").?.array.items[2].integer);
    try std.testing.expectEqualStrings("hello", parsed.object.get("name").?.string);
    try std.testing.expectEqual(true, parsed.object.get("flag").?.bool);
}

test "jsonValueClone deep-copy is independent of original" {
    const allocator = std.testing.allocator;
    var arr = std.json.Array.init(allocator);
    try arr.append(std.json.Value{ .integer = 1 });
    try arr.append(std.json.Value{ .integer = 2 });
    try arr.append(std.json.Value{ .integer = 3 });
    var orig_obj = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try orig_obj.put(allocator, "key", std.json.Value{ .array = arr });
    const original = std.json.Value{ .object = orig_obj };
    const cloned = try jsonValueClone(allocator, &original);
    defer jsonValueDeinit(allocator, &cloned);
    // Clean up original: free the inner array before deiniting the object map
    {
        var arr_val = &orig_obj.get("key").?.array;
        arr_val.deinit();
    }
    orig_obj.deinit(allocator);
    try std.testing.expect(cloned == .object);
    try std.testing.expectEqual(@as(usize, 3), cloned.object.get("key").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 1), cloned.object.get("key").?.array.items[0].integer);
}

test "jsonValueDeinit does not double-free on nested object with multiple keys" {
    const allocator = std.testing.allocator;

    // Create a nested value via jsonValueClone, then deinit it.
    // If jsonValueDeinit double-frees, std.testing.allocator catches it.
    const source = try parseJsonValue(allocator, "{\"a\":{\"b\":[1]},\"c\":\"str\"}");
    const value = try jsonValueClone(allocator, &source);
    jsonValueDeinit(allocator, &value);
    jsonValueDeinit(allocator, &source);
}

test "jsonValueDeinit correctly frees object keys (regression: t_c262ce43)" {
    const allocator = std.testing.allocator;
    var obj = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try obj.put(allocator, try allocator.dupe(u8, "alpha"), std.json.Value{ .integer = 1 });
    try obj.put(allocator, try allocator.dupe(u8, "beta"), std.json.Value{ .integer = 2 });
    const value = std.json.Value{ .object = obj };
    var mutable = value;
    jsonValueDeinit(allocator, &mutable);
}
