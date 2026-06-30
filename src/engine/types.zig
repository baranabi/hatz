//! Core types and deterministic helpers for the stub engine.
const std = @import("std");

pub const ContractVersion = []const u8;
pub const RequestId = []const u8;
pub const RunId = []const u8;
pub const AnalystId = []const u8;
pub const Tick = u64;
pub const HatId = u32;
pub const BeaconId = u32;
pub const OrganizationId = u32;
pub const CapabilityId = u32;

/// A trade record: capability transferred from source to recipient at a meeting.
pub const CapabilityTrade = struct {
    source_hat_id: HatId,
    recipient_hat_id: HatId,
    capability_id: CapabilityId,
};
pub const Payment = f64;

pub const Location = struct {
    x: i32,
    y: i32,
};

pub const AlertLevel = enum {
    OFF,
    LEVEL_ONE,
    LEVEL_TWO,
};

pub const ArrestStatus = enum {
    SUCCESSFUL,
    FAILURE,
};

pub const HatAdvertisedColor = enum {
    TERRORIST,
    UNKNOWN,
    NOT_A_KNOWN_HAT,
};

pub const TrueColor = enum {
    BENIGN,
    TERRORIST,
    COVERT_TERRORIST,
};

pub const Hat = struct {
    id: HatId,
    true_color: TrueColor,
    advertised_color: HatAdvertisedColor,
};

pub const OrganizationType = enum {
    BENIGN,
    TERRORIST,
};

pub const Organization = struct {
    id: OrganizationId,
    org_type: OrganizationType,
    members: []const HatId,
};

pub const TaskforceStatus = enum {
    ACTIVE,
    DISBANDED,
};

pub const Meeting = struct {
    tick: Tick,
    location: Location,
    participants: []const HatId,
    trades: []const CapabilityTrade,
};

pub const Taskforce = struct {
    id: u32,
    organization_id: OrganizationId,
    members: []const HatId,
    target: Location,
    required_capabilities: []const CapabilityId,
    meeting_plan: []const Meeting,
    status: TaskforceStatus,
};

pub const EventRecord = struct {
    tick: Tick,
    type: []const u8,
    location: ?Location = null,
    beaconId: ?BeaconId = null,
    taskforceId: ?u32 = null,
    participantCount: ?u32 = null,
    tradeSourceId: ?HatId = null,
    tradeRecipientId: ?HatId = null,
    tradeCapabilityId: ?CapabilityId = null,
    hatId: ?HatId = null,
};

/// Per-hat simulation state tracked by RunState.
/// Stores the current location of each hat per tick and owned capabilities.
pub const HatState = struct {
    current_location: Location,
    /// Bitmask of capabilities owned by this hat (bit i = 1 => owns capability i).
    capability_bits: u64,
};

pub const Beacon = struct {
    beaconId: BeaconId,
    alertLevel: AlertLevel,
    location: Location,
    // NOTE: vulnerabilities intentionally omitted from Beacon struct.
    // The RunState stores them in beacon_vulnerabilities[idx][0..] and
    // a slice in Beacon would dangle after RunState.init() returns by value.
    // Consumers must read from run.beacon_vulnerabilities[beacon_idx][0..].
};

pub const WorldMax: i32 = 50;

/// Compute a deterministic hat location for the given seed, tick, and hat id.
/// This keeps simulations reproducible across runs and provides a stable target
/// for tests and fixtures without storing per-hat state.
pub fn deterministicLocation(seed: u64, tick: Tick, hat_id: HatId) Location {
    const mixed = mix(seed ^ (@as(u64, tick) *% 0x9E3779B97F4A7C15) ^ (@as(u64, hat_id) *% 0xBF58476D1CE4E5B9));
    return Location{
        .x = bounded(mixed, WorldMax),
        .y = bounded(mixed >> 8, WorldMax),
    };
}

/// Compute a deterministic beacon location for the given seed and beacon id.
/// Beacons are fixed, so this omits the tick from the mix to keep placement stable.
pub fn deterministicBeaconLocation(seed: u64, beacon_id: BeaconId) Location {
    const mixed = mix(seed ^ (@as(u64, beacon_id) *% 0x94D049BB133111EB));
    return Location{
        .x = bounded(mixed, WorldMax),
        .y = bounded(mixed >> 16, WorldMax),
    };
}

/// Helper: test if a capability bitmask includes a given capability.
pub fn hasCapability(bits: u64, cap: CapabilityId) bool {
    return (bits >> @as(u6, @intCast(cap))) & 1 == 1;
}

/// Helper: add a capability to a bitmask.
pub fn addCapability(bits: *u64, cap: CapabilityId) void {
    bits.* |= @as(u64, 1) << @as(u6, @intCast(cap));
}

/// Helper: remove a capability from a bitmask.
pub fn removeCapability(bits: *u64, cap: CapabilityId) void {
    bits.* &= ~(@as(u64, 1) << @as(u6, @intCast(cap)));
}

/// Event type constants for event log.
pub const event_type_meeting = "meeting_executed";
pub const event_type_trade = "capability_trade";
pub const event_type_disbanded = "taskforce_disbanded";
pub const event_type_arrest = "arrest";
pub const event_type_false_arrest = "false_arrest";
pub const event_type_alert_change = "alert_change";
pub const event_type_attack = "beacon_attack";

/// Bound a 64-bit value into the inclusive range [0, max].
pub fn bounded(value: u64, max: i32) i32 {
    return @as(i32, @intCast(value % @as(u64, @intCast(max + 1))));
}

/// Stateless 64-bit mixing function (SplitMix64-style).
/// Used to scramble seed/tick/id inputs into well-distributed coordinates.
pub fn mix(value: u64) u64 {
    var v = value;
    v ^= v >> 30;
    v *%= 0xBF58476D1CE4E5B9;
    v ^= v >> 27;
    v *%= 0x94D049BB133111EB;
    v ^= v >> 31;
    return v;
}

test "deterministicLocation same inputs produce same result" {
    const loc_a = deterministicLocation(42, 10, 5);
    const loc_b = deterministicLocation(42, 10, 5);
    try std.testing.expectEqual(loc_a.x, loc_b.x);
    try std.testing.expectEqual(loc_a.y, loc_b.y);
}

test "deterministicLocation different hats produce different locations" {
    const loc_a = deterministicLocation(42, 10, 0);
    const loc_b = deterministicLocation(42, 10, 1);
    try std.testing.expect(loc_a.x != loc_b.x or loc_a.y != loc_b.y);
}

test "deterministicBeaconLocation produces valid world coordinates" {
    var all_valid = true;
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const loc = deterministicBeaconLocation(42, i);
        if (loc.x < 0 or loc.x > WorldMax or loc.y < 0 or loc.y > WorldMax) {
            all_valid = false;
            break;
        }
    }
    try std.testing.expect(all_valid);
}

test "hasCapability correctly detects owned capabilities" {
    const bits: u64 = 0b0000_0000_1000_0101; // caps 0, 2, 7 set
    try std.testing.expect(hasCapability(bits, 0));
    try std.testing.expect(hasCapability(bits, 2));
    try std.testing.expect(hasCapability(bits, 7));
    try std.testing.expect(!hasCapability(bits, 1));
    try std.testing.expect(!hasCapability(bits, 3));
    try std.testing.expect(!hasCapability(bits, 15));
}

test "addCapability and removeCapability work correctly" {
    var bits: u64 = 0;
    addCapability(&bits, 3);
    try std.testing.expect(hasCapability(bits, 3));
    try std.testing.expect(!hasCapability(bits, 0));

    addCapability(&bits, 0);
    try std.testing.expect(hasCapability(bits, 0));

    removeCapability(&bits, 3);
    try std.testing.expect(!hasCapability(bits, 3));
    try std.testing.expect(hasCapability(bits, 0)); // still set
}

test "addCapability is idempotent (duplicate add does not change bits)" {
    var bits: u64 = 0;
    addCapability(&bits, 5);
    addCapability(&bits, 5);
    try std.testing.expect(hasCapability(bits, 5));
}

test "bounded produces values in [0, max]" {
    const max_val = 50;
    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        const v = bounded(i *% 0x9E3779B97F4A7C15, max_val);
        try std.testing.expect(v >= 0);
        try std.testing.expect(v <= max_val);
    }
}

test "mix produces deterministic output" {
    const a = mix(42);
    const b = mix(42);
    try std.testing.expectEqual(a, b);
    const c = mix(99);
    try std.testing.expect(a != c);
}
