//! Replay contract fixtures through the in-process engine router.
const std = @import("std");
const engine = @import("engine");

const examples_dir = "tools/contract/examples";
const expected_dir = "tools/contract/examples/expected";
const output_dir = "tools/contract/examples/output";
const max_json_size = 1024 * 1024;

/// CLI entrypoint for replaying contract fixtures.
/// Runs in-order, writes responses to stdout and output files, and can check expectations.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var check = false;
    if (args.len == 2) {
        if (!std.mem.eql(u8, args[1], "--check")) return error.InvalidArgs;
        check = true;
    } else if (args.len > 2) {
        return error.InvalidArgs;
    }

    var registry = engine.runs.Runs.init(allocator);
    defer registry.deinit();

    var names = try collectRequestFiles(allocator, examples_dir);
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    if (names.items.len == 0) return error.NoRequestsFound;

    try std.fs.cwd().makePath(output_dir);

    for (names.items) |name| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const request_path = try joinPath(arena_alloc, &.{ examples_dir, name });
        const request_json = try std.fs.cwd().readFileAlloc(arena_alloc, request_path, max_json_size);

        const parsed = try std.json.parseFromSlice(engine.protocol.EnvelopeRequest, arena_alloc, request_json, .{ .allocate = .alloc_always });
        const request = parsed.value;

        const response = engine.router.dispatch(&registry, arena_alloc, request) catch |err| {
            std.debug.print("Failed to dispatch {s}: {s}\n", .{ name, @errorName(err) });
            return err;
        };

        const response_json = try stringifyAlloc(arena_alloc, response);
        try std.fs.File.stdout().writeAll(response_json);
        try std.fs.File.stdout().writeAll("\n");

        const output_name = try replaceSuffix(arena_alloc, name, ".json", ".response.json");
        const output_path = try joinPath(arena_alloc, &.{ output_dir, output_name });
        {
            const out_file = try std.fs.cwd().createFile(output_path, .{ .truncate = true });
            defer out_file.close();
            try out_file.writeAll(response_json);
        }

        if (check) {
            const expected_name = output_name;
            const expected_path = try joinPath(arena_alloc, &.{ expected_dir, expected_name });
            const expected_json = std.fs.cwd().readFileAlloc(arena_alloc, expected_path, max_json_size) catch |err| {
                std.debug.print("Missing expected response for {s}: {s}\n", .{ name, @errorName(err) });
                return err;
            };
            const expected_value = try std.json.parseFromSlice(std.json.Value, arena_alloc, expected_json, .{ .allocate = .alloc_always });
            const actual_value = try std.json.parseFromSlice(std.json.Value, arena_alloc, response_json, .{ .allocate = .alloc_always });
            if (compareResponse(arena_alloc, expected_value.value, actual_value.value)) |mismatch| {
                std.debug.print("Mismatch in {s}: {s} expected {s}, got {s}\n", .{ name, mismatch.path, mismatch.expected, mismatch.actual });
                return error.CheckFailed;
            }
        }
    }
}

/// Collect request fixture filenames in lexical order.
/// Response files are ignored to avoid replaying generated artifacts.
fn collectRequestFiles(allocator: std.mem.Allocator, dir_path: []const u8) !std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (std.mem.endsWith(u8, entry.name, ".response.json")) continue;
        try list.append(allocator, try allocator.dupe(u8, entry.name));
    }
    sortLex(list.items);
    return list;
}

/// Sort strings in-place using a simple insertion sort.
/// The list is small, so avoiding allocations keeps this cheap and predictable.
fn sortLex(items: [][]const u8) void {
    if (items.len < 2) return;
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.lessThan(u8, items[j], items[j - 1])) : (j -= 1) {
            const tmp = items[j - 1];
            items[j - 1] = items[j];
            items[j] = tmp;
        }
    }
}

/// Replace a file suffix with a new suffix, returning a newly allocated string.
fn replaceSuffix(allocator: std.mem.Allocator, value: []const u8, suffix: []const u8, replacement: []const u8) ![]const u8 {
    if (!std.mem.endsWith(u8, value, suffix)) return error.InvalidSuffix;
    const prefix_len = value.len - suffix.len;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ value[0..prefix_len], replacement });
}

/// Join path segments using the platform separator.
fn joinPath(allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    return std.fs.path.join(allocator, parts);
}

/// Serialize a value to JSON and return an owned byte slice.
fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

const Mismatch = struct {
    path: []const u8,
    expected: []const u8,
    actual: []const u8,
};

/// Compare envelope responses, enforcing contractVersion/ok and expected payload keys.
/// Returns a mismatch structure with a path and formatted values on failure.
fn compareResponse(allocator: std.mem.Allocator, expected: std.json.Value, actual: std.json.Value) ?Mismatch {
    if (expected != .object or actual != .object) {
        return mismatchValue(allocator, "$", expected, actual);
    }
    const expected_obj = expected.object;
    const actual_obj = actual.object;

    const expected_version = expected_obj.get("contractVersion") orelse return mismatchValue(allocator, "$.contractVersion", expected, actual);
    const actual_version = actual_obj.get("contractVersion") orelse return mismatchValue(allocator, "$.contractVersion", expected, actual);
    if (expected_version != .string or actual_version != .string) {
        return mismatchValue(allocator, "$.contractVersion", expected_version, actual_version);
    }
    if (!std.mem.eql(u8, expected_version.string, actual_version.string)) {
        return mismatchValue(allocator, "$.contractVersion", expected_version, actual_version);
    }

    const expected_ok = expected_obj.get("ok") orelse return mismatchValue(allocator, "$.ok", expected, actual);
    const actual_ok = actual_obj.get("ok") orelse return mismatchValue(allocator, "$.ok", expected, actual);
    if (expected_ok != .bool or actual_ok != .bool) {
        return mismatchValue(allocator, "$.ok", expected_ok, actual_ok);
    }
    if (expected_ok.bool != actual_ok.bool) {
        return mismatchValue(allocator, "$.ok", expected_ok, actual_ok);
    }

    if (expected_obj.get("payload")) |expected_payload| {
        const actual_payload = actual_obj.get("payload") orelse return mismatchValue(allocator, "$.payload", expected_payload, actual);
        if (compareValue(allocator, expected_payload, actual_payload, "$.payload")) |mismatch| {
            return mismatch;
        }
    }
    return null;
}

/// Recursively compare JSON values with support for "__ANY__" wildcards.
/// Expected objects act as a subset: any missing expected key is a mismatch.
fn compareValue(allocator: std.mem.Allocator, expected: std.json.Value, actual: std.json.Value, path: []const u8) ?Mismatch {
    if (expected == .string and std.mem.eql(u8, expected.string, "__ANY__")) return null;
    switch (expected) {
        .null => {
            if (actual != .null) return mismatchValue(allocator, path, expected, actual);
        },
        .bool => {
            if (actual != .bool or expected.bool != actual.bool) return mismatchValue(allocator, path, expected, actual);
        },
        .integer => {
            if (actual == .float) {
                if (@as(f64, @floatFromInt(expected.integer)) != actual.float) {
                    return mismatchValue(allocator, path, expected, actual);
                }
            } else if (actual != .integer or expected.integer != actual.integer) {
                return mismatchValue(allocator, path, expected, actual);
            }
        },
        .float => {
            if (actual == .integer) {
                if (expected.float != @as(f64, @floatFromInt(actual.integer))) {
                    return mismatchValue(allocator, path, expected, actual);
                }
            } else if (actual != .float or expected.float != actual.float) {
                return mismatchValue(allocator, path, expected, actual);
            }
        },
        .string => {
            if (actual != .string or !std.mem.eql(u8, expected.string, actual.string)) return mismatchValue(allocator, path, expected, actual);
        },
        .number_string => {
            if (actual != .number_string or !std.mem.eql(u8, expected.number_string, actual.number_string)) {
                return mismatchValue(allocator, path, expected, actual);
            }
        },
        .array => {
            if (actual != .array) return mismatchValue(allocator, path, expected, actual);
            if (actual.array.items.len < expected.array.items.len) return mismatchValue(allocator, path, expected, actual);
            var idx: usize = 0;
            while (idx < expected.array.items.len) : (idx += 1) {
                const child_path = std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path, idx }) catch return mismatchValue(allocator, path, expected, actual);
                if (compareValue(allocator, expected.array.items[idx], actual.array.items[idx], child_path)) |mismatch| {
                    return mismatch;
                }
            }
        },
        .object => {
            if (actual != .object) return mismatchValue(allocator, path, expected, actual);
            var it = expected.object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const expected_child = entry.value_ptr.*;
                const child_path = std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, key }) catch return mismatchValue(allocator, path, expected, actual);
                const actual_child = actual.object.get(key) orelse return mismatchValue(allocator, child_path, expected_child, actual);
                if (compareValue(allocator, expected_child, actual_child, child_path)) |mismatch| {
                    return mismatch;
                }
            }
        },
    }
    return null;
}

/// Build a mismatch record with JSON-encoded expected and actual values.
fn mismatchValue(allocator: std.mem.Allocator, path: []const u8, expected: std.json.Value, actual: std.json.Value) ?Mismatch {
    const expected_text = stringifyAlloc(allocator, expected) catch return null;
    const actual_text = stringifyAlloc(allocator, actual) catch return null;
    return Mismatch{
        .path = path,
        .expected = expected_text,
        .actual = actual_text,
    };
}
