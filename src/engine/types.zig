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

pub const EventRecord = struct {
    tick: Tick,
    type: []const u8,
    location: ?Location = null,
    beaconId: ?BeaconId = null,
};

pub const Beacon = struct {
    beaconId: BeaconId,
    alertLevel: AlertLevel,
    location: Location,
    vulnerabilities: []const CapabilityId,
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

/// Bound a 64-bit value into the inclusive range [0, max].
/// This keeps deterministic coordinates within the world bounds.
fn bounded(value: u64, max: i32) i32 {
    return @as(i32, @intCast(value % @as(u64, @intCast(max + 1))));
}

/// Stateless 64-bit mixing function (SplitMix64-style).
/// Used to scramble seed/tick/id inputs into well-distributed coordinates.
fn mix(value: u64) u64 {
    var v = value;
    v ^= v >> 30;
    v *%= 0xBF58476D1CE4E5B9;
    v ^= v >> 27;
    v *%= 0x94D049BB133111EB;
    v ^= v >> 31;
    return v;
}
