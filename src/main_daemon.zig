//! CLI entrypoint for the WebSocket daemon.
//! Usage: hatz-daemon [--port <port>] [--host <address>]
//! Default: --port 9876 --host 127.0.0.1

const std = @import("std");
const daemon = @import("daemon.zig");

// ponytail: route daemon logs to /tmp/hatz-daemon.log so we can see them
// regardless of how the process was launched (background, launchd, etc).
// std.log default writes to stderr which gets dropped in non-tty contexts.
// Uses raw posix open/write (std.fs.File was removed in Zig 0.16).
// Must be in the root source file (main_daemon.zig) — `std.options` reads
// `@hasDecl(root, "std_options")` and `root` is the entry point module.
pub const std_options: std.Options = .{
    .logFn = logToFile,
    .log_level = .info,
};

var log_fd: std.posix.fd_t = -1;
var log_mutex: std.atomic.Mutex = .unlocked;

fn logToFile(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime fmt: []const u8,
    args: anytype,
) void {
    const prefix = comptime level.asText();
    _ = scope;
    const msg = std.fmt.allocPrint(std.heap.page_allocator, "[" ++ prefix ++ "] " ++ fmt ++ "\n", args) catch return;
    defer std.heap.page_allocator.free(msg);
    if (log_fd >= 0) {
        // ponytail: best-effort spinlock — if contending, skip file write
        // rather than block. The daemon is effectively single-threaded
        // (one accept loop) so contention is extremely rare.
        if (log_mutex.tryLock()) {
            defer log_mutex.unlock();
            _ = std.c.write(log_fd, msg.ptr, msg.len);
        }
    }
    _ = std.c.write(std.posix.STDERR_FILENO, msg.ptr, msg.len);
}

fn openLog() void {
    if (log_fd >= 0) return;
    log_fd = std.posix.openatZ(
        std.posix.AT.FDCWD,
        "/tmp/hatz-daemon.log",
        .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
        0o644,
    ) catch -1;
}

pub fn main(init: std.process.Init) !void {
    const default_port: u16 = 9876;
    const default_host: []const u8 = "127.0.0.1";

    var port: u16 = default_port;
    var host: []const u8 = default_host;

    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_it.next(); // skip program name

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            port = if (args_it.next()) |port_str|
                std.fmt.parseUnsigned(u16, port_str, 10) catch |err| {
                    std.log.warn("invalid --port value \"{s}\": {s}; using default {d}", .{ port_str, @errorName(err), default_port });
                    return err;
                }
            else
                default_port;
        } else if (std.mem.eql(u8, arg, "--host")) {
            host = if (args_it.next()) |host_str| host_str else default_host;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.log.warn("unknown flag: {s}", .{arg});
        } else {
            // Backward compat: positional arg treated as port
            port = std.fmt.parseUnsigned(u16, arg, 10) catch |err| {
                std.log.warn("invalid positional port \"{s}\": {s}; using default {d}", .{ arg, @errorName(err), default_port });
                return err;
            };
        }
    }

    // Open the log file before starting the daemon so that startup messages
    // are captured.
    openLog();

    try daemon.start(init.io, host, port);
}
