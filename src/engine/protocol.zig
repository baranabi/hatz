//! Protocol envelope and shared request/response types.
const std = @import("std");
const types = @import("types.zig");

pub const Error = struct {
    code: []const u8,
    message: []const u8,
    details: ?std.json.Value = null,
};

pub const EnvelopeRequest = struct {
    contractVersion: types.ContractVersion,
    type: []const u8,
    payload: std.json.Value,
    requestId: ?types.RequestId = null,
};

pub const EnvelopeResponse = struct {
    contractVersion: types.ContractVersion,
    ok: bool,
    payload: ?std.json.Value = null,
    @"error": ?Error = null,
    requestId: ?types.RequestId = null,
};

pub const DefaultIbRequest = struct {
    method: []const u8,
    args: std.json.Value,
};

pub const DefaultIbResultMetadata = struct {
    tick: types.Tick,
    noisy: bool,
    charged: types.Payment,
};

pub const DefaultIbResult = struct {
    method: []const u8,
    result: std.json.Value,
    metadata: ?DefaultIbResultMetadata = null,
};
