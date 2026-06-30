const std = @import("std");
const engine = @import("engine");

// ponytail: log infrastructure (std_options, logToFile, openLog) lives in
// main_daemon.zig because std.options reads @hasDecl(root, "std_options")
// and root is the entry-point module. All modules inherit the root's
// custom log function automatically.

const log = std.log.scoped(.hatz_daemon);

var shutdown_flag = std.atomic.Value(bool).init(false);

fn handleSigint(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    shutdown_flag.store(true, .monotonic);
}

pub fn start(io: std.Io, host: []const u8, port: u16) !void {
    // Set up SIGINT handler for clean Ctrl-C shutdown.
    const sa = std.posix.Sigaction{
        .handler = .{ .handler = handleSigint },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);

    const addr = try std.Io.net.IpAddress.parse(host, port);
    var listener = try addr.listen(io, .{
        .mode = .stream,
        .reuse_address = true,
        .kernel_backlog = 128,
    });
    const listen_fd = listener.socket.handle;
    // ponytail: extract the fd and skip listener.deinit — we manage the
    // socket lifecycle ourselves with raw posix calls so that the accept
    // loop can respond to SIGINT without the Io runtime panicking on
    // EBADF/EAGAIN (the threaded backend treats both as programmer bugs).
    _ = &listener;

    var gpa = std.heap.DebugAllocator(.{}).init;
    defer {
        if (gpa.deinit() == .leak) {
            log.err("memory leaks detected on shutdown", .{});
        }
    }
    const allocator = gpa.allocator();

    log.info("listening on {s}:{d}", .{ host, port });
    log.info("logging to /tmp/hatz-daemon.log", .{});

    var connection_count: u32 = 0;

    // Accept loop — runs ppoll with a 500ms timeout so we can check the
    // shutdown flag periodically. On macOS's threaded Io backend, EINTR
    // on accept() is retried internally, so we use raw ppoll + accept4
    // to stay responsive to Ctrl-C.
    while (!shutdown_flag.load(.monotonic)) {
        var pfd = [1]std.posix.pollfd{.{ .fd = listen_fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const polled = rawPollTimeout(&pfd, 500) catch |err| switch (err) {
            error.SignalInterrupt => {
                if (shutdown_flag.load(.monotonic)) break;
                continue;
            },
            else => {
                log.err("poll error: {}", .{err});
                continue;
            },
        };
        if (polled == 0) continue; // timeout — loop and check flag
        if (shutdown_flag.load(.monotonic)) break;

        // Accept the connection. ppoll() said data is ready, but there's a
        // tiny race where the client disconnects between poll and accept.
        // We handle it by catching ConnectionAborted and retrying.
        const stream = listener.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            error.SocketNotListening => break,
            error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.SystemResources => {
                log.err("accept resource error: {}", .{err});
                continue;
            },
            else => |e| {
                log.err("accept error: {}", .{e});
                continue;
            },
        };
        defer stream.close(io);

        connection_count += 1;
        log.info("[{d}] connection opened", .{connection_count});

        handleConnection(io, stream, allocator);

        log.info("[{d}] connection closed", .{connection_count});
    }

    // ponytail: close the listen fd manually (we skipped listener.deinit).
    _ = std.c.close(listen_fd);

    log.info("shutdown complete ({d} connections handled)", .{connection_count});
}

/// Wrapper around raw poll system call that returns on EINTR (unlike
/// posix.poll which retries internally). ppoll is not available on macOS.
fn rawPollTimeout(fds: []std.posix.pollfd, timeout_ms: u32) !usize {
    const nfds: std.c.nfds_t = @intCast(fds.len);
    const rc = std.c.poll(fds.ptr, nfds, @as(c_int, @intCast(timeout_ms)));
    switch (std.posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .INTR => return error.SignalInterrupt,
        .FAULT => unreachable,
        .INVAL => unreachable,
        .NOMEM => return error.SystemResources,
        else => |e| return std.posix.unexpectedErrno(e),
    }
}

fn handleConnection(io: std.Io, stream: std.Io.net.Stream, allocator: std.mem.Allocator) void {
    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;

    var stream_reader = stream.reader(io, &read_buf);
    var stream_writer = stream.writer(io, &write_buf);

    var server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| {
            log.warn("receiveHead error: {}", .{err});
            return;
        };

        // ponytail: daemon is WS-only; any path upgrades.
        handleWebSocket(allocator, &request) catch |err| {
            log.warn("websocket error: {}", .{err});
            return;
        };
    }
}

fn handleWebSocket(allocator: std.mem.Allocator, request: *std.http.Server.Request) !void {
    const upgrade = request.upgradeRequested();
    const key = switch (upgrade) {
        .websocket => |k| k orelse return error.MissingWebSocketKey,
        else => return error.NotWebSocketUpgrade,
    };
    var ws = try request.respondWebSocket(.{ .key = key });
    try ws.output.flush(); // ponytail: handshake is buffered; flush before reading frames

    // Each WebSocket connection owns an isolated Runs registry.
    // No state is shared between connections.
    var registry = engine.runs.Runs.init(allocator);
    defer registry.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    while (true) {
        const msg = ws.readSmallMessage() catch |err| switch (err) {
            error.ConnectionClose => return,
            else => return err,
        };

        switch (msg.opcode) {
            .text => {
                const parsed_request = std.json.parseFromSlice(engine.protocol.EnvelopeRequest, arena, msg.data, .{ .allocate = .alloc_always }) catch {
                    try ws.writeMessage(msg.data, .text);
                    _ = arena_state.reset(.retain_capacity);
                    continue;
                };
                if (std.mem.eql(u8, parsed_request.value.type, "sim.advance")) {
                    const advance = try dispatchAdvanceMessage(arena, &registry, parsed_request.value);
                    const log_rid_adv = if (parsed_request.value.requestId) |r| r else "(null)";
                    log.info("sim.advance runId={s} events={d} requestId={s}", .{ advance.run_id, advance.events.len, log_rid_adv });
                    for (advance.events) |event| {
                        const frame = try eventFrame(arena, event);
                        try ws.writeMessage(frame, .text);
                    }
                    try ws.writeMessage(advance.response_json, .text);
                } else if (std.mem.eql(u8, parsed_request.value.type, "sim.initialize")) {
                    const log_rid_init = if (parsed_request.value.requestId) |r| r else "(null)";
                    log.info("sim.initialize requestId={s}", .{log_rid_init});
                    const response_json = try engine.router.dispatch(&registry, arena, parsed_request.value);
                    const response_text = try engine.json_util.stringifyAlloc(arena, response_json);
                    try ws.writeMessage(response_text, .text);
                } else if (std.mem.eql(u8, parsed_request.value.type, "sim.end")) {
                    const log_rid_end = if (parsed_request.value.requestId) |r| r else "(null)";
                    log.info("sim.end requestId={s}", .{log_rid_end});
                    const response_json = try engine.router.dispatch(&registry, arena, parsed_request.value);
                    const response_text = try engine.json_util.stringifyAlloc(arena, response_json);
                    try ws.writeMessage(response_text, .text);
                } else {
                    const log_rid_other = if (parsed_request.value.requestId) |r| r else "(null)";
                    log.info("{s} requestId={s}", .{ parsed_request.value.type, log_rid_other });
                    const response_json = try engine.router.dispatch(&registry, arena, parsed_request.value);
                    const response_text = try engine.json_util.stringifyAlloc(arena, response_json);
                    try ws.writeMessage(response_text, .text);
                }
                _ = arena_state.reset(.retain_capacity);
            },
            .ping => try ws.writeMessage(msg.data, .pong),
            else => return error.UnexpectedOpCode,
        }
    }
}

fn dispatchMessage(arena: std.mem.Allocator, registry: *engine.runs.Runs, json_text: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(engine.protocol.EnvelopeRequest, arena, json_text, .{ .allocate = .alloc_always });
    const response = engine.router.dispatch(registry, arena, parsed.value) catch |err| {
        return errorResponse(arena, parsed.value, err);
    };
    return engine.json_util.stringifyAlloc(arena, response);
}

/// Dispatches a sim.advance request and returns the JSON text of the final
/// advance response. The caller is responsible for sending any event frames
/// produced during the advance.
fn dispatchAdvanceMessage(
    arena: std.mem.Allocator,
    registry: *engine.runs.Runs,
    request: engine.protocol.EnvelopeRequest,
) !struct { response_json: []const u8, events: []const engine.types.EventRecord, run_id: []const u8 } {
    const payload = try engine.router.parsePayload(engine.sim.SimAdvanceRequestPayload, arena, request.payload);
    const response = try engine.sim.advance(registry, arena, payload);

    // Capture the events emitted during this advance so the caller can push
    // them as real-time frames before the final response.
    const run = registry.get(payload.runId) orelse return error.RunNotFound;
    const from_index = if (response.eventsEmitted <= run.event_log.items.len)
        run.event_log.items.len - response.eventsEmitted
    else
        0;
    const events = run.event_log.items[from_index..];

    const response_value = try engine.router.okResponseValue(arena, request, response);
    const response_json = try engine.json_util.stringifyAlloc(arena, response_value);
    return .{ .response_json = response_json, .events = events, .run_id = payload.runId };
}

fn errorResponse(arena: std.mem.Allocator, request: engine.protocol.EnvelopeRequest, err: anyerror) ![]const u8 {
    const response = engine.protocol.EnvelopeResponse{
        .contractVersion = request.contractVersion,
        .ok = false,
        .payload = null,
        .@"error" = .{
            .code = @errorName(err),
            .message = @errorName(err),
        },
        .requestId = request.requestId,
    };
    return engine.json_util.stringifyAlloc(arena, response);
}

/// Serialize a single event record into a client push frame:
/// {"type":"event","payload":{...event...}}.
fn eventFrame(arena: std.mem.Allocator, event: engine.types.EventRecord) ![]const u8 {
    var obj = try std.json.ObjectMap.init(arena, &.{}, &.{});
    try obj.put(arena, "type", std.json.Value{ .string = "event" });
    const payload_value = try engine.router.valueFromStruct(arena, event);
    try obj.put(arena, "payload", payload_value);
    return engine.json_util.stringifyAlloc(arena, std.json.Value{ .object = obj });
}
