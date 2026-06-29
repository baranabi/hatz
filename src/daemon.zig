const std = @import("std");
const engine = @import("engine");

const log = std.log.scoped(.hatz_daemon);

pub fn start(io: std.Io, port: u16) !void {
    const addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    var listener = try addr.listen(io, .{
        .mode = .stream,
        .reuse_address = true,
        .kernel_backlog = 128,
    });
    defer listener.deinit(io);

    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    log.info("listening on :{d}", .{port});

    while (true) {
        const stream = listener.accept(io) catch |err| {
            log.err("accept error: {}", .{err});
            continue;
        };
        defer stream.close(io);

        // HTTP requests don't use a registry; each WS connection creates its own.
        handleConnection(io, stream, allocator);
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

        if (std.mem.eql(u8, request.head.target, "/ws")) {
            handleWebSocket(allocator, &request) catch |err| {
                log.warn("websocket error: {}", .{err});
            };
            return;
        }

        request.respond("hello from hatz", .{}) catch |err| {
            log.warn("respond error: {}", .{err});
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
                    for (advance.events) |event| {
                        const frame = try eventFrame(arena, event);
                        try ws.writeMessage(frame, .text);
                    }
                    try ws.writeMessage(advance.response_json, .text);
                } else {
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
) !struct { response_json: []const u8, events: []const engine.types.EventRecord } {
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
    return .{ .response_json = response_json, .events = events };
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
