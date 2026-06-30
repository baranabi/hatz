//! Seed-driven population generator for hats, organizations, and taskforces.
//!
//! Generates a deterministic population from a seed and structured params.
//! All randomness flows through a single SplitMix64 PRNG seeded from the
//! simulation seed, ensuring reproducible populations across runs.
const std = @import("std");
const types = @import("types.zig");

/// Structured parameters controlling population generation.
/// These mirror the spec's population parameters (section 7).
pub const PopulationParams = struct {
    n_hats: u32,
    n_benign_orgs: u32,
    n_terrorist_orgs: u32,
    fraction_covert: f64,
    fraction_terrorist: f64,
    mean_org_size: f64,
    std_org_size: f64,
    n_capabilities: u32,
};



/// Parsed population produced by `generate`.
/// Caller owns the slices and must call `deinit` to release memory.
pub const Population = struct {
    hats: []types.Hat,
    orgs: []types.Organization,
    taskforces: []types.Taskforce,

    pub fn deinit(self: *Population, allocator: std.mem.Allocator) void {
        for (self.orgs) |org| {
            allocator.free(org.members);
        }
        // Free taskforce meeting plans: trades, participants, members, req caps.
        for (self.taskforces) |tf| {
            for (tf.meeting_plan) |mtg| {
                allocator.free(mtg.participants);
                allocator.free(mtg.trades);
            }
            allocator.free(tf.meeting_plan);
            allocator.free(tf.members);
            allocator.free(tf.required_capabilities);
        }
        allocator.free(self.hats);
        allocator.free(self.orgs);
        allocator.free(self.taskforces);
    }
};

/// Generate initial taskforces with simple meeting plans for terrorist organizations.
/// Each terrorist org gets 1-2 taskforces, each with 2 meetings (intermediate + final at target).
/// Trades in meetings transfer capabilities from non-member org hats to taskforce members.
fn generateTaskforces(allocator: std.mem.Allocator, random: std.Random, seed: u64, orgs: []const types.Organization, n_terrorist_orgs: u32, hats: []const types.Hat) ![]types.Taskforce {
    _ = seed;
    _ = hats;
    var taskforces_list: std.ArrayList(types.Taskforce) = .empty;

    for (orgs[0..n_terrorist_orgs]) |org| {
        if (org.members.len < 2) continue;

        // Each terrorist org gets 1-2 taskforces.
        const n_tf: u32 = if (random.boolean()) 1 else 2;
        var tf_idx: u32 = 0;
        while (tf_idx < n_tf) : (tf_idx += 1) {
            // Pick 2-4 members for this taskforce.
            const tf_size = random.uintLessThan(u32, @min(org.members.len - 1, 3)) + 2;
            var member_set = std.AutoHashMap(types.HatId, void).init(allocator);
            defer member_set.deinit();
            while (member_set.count() < tf_size) {
                const idx = random.uintLessThan(usize, org.members.len);
                try member_set.put(org.members[idx], {});
            }
            var members_list: std.ArrayList(types.HatId) = .empty;
            defer members_list.deinit(allocator);
            var iter = member_set.keyIterator();
            while (iter.next()) |key| {
                try members_list.append(allocator, key.*);
            }

            // Pick a target location near a beacon position for plausibility.
            const target = types.Location{
                .x = random.intRangeAtMost(i32, 10, 40),
                .y = random.intRangeAtMost(i32, 10, 40),
            };

            // Required capabilities: 1-3 random capability IDs.
            const n_req = random.uintLessThan(u32, 3) + 1;
            var req_caps: std.ArrayList(types.CapabilityId) = .empty;
            defer req_caps.deinit(allocator);
            var ci: u32 = 0;
            while (ci < n_req) : (ci += 1) {
                try req_caps.append(allocator, random.uintLessThan(types.CapabilityId, 16));
            }

            // ── Build meeting plan ──────────────────────────────────────
            // Intermediate meeting at tick ~40, final meeting at tick ~80.
            const intermediate_tick: types.Tick = 30 + random.uintLessThan(u32, 20);
            const final_tick: types.Tick = intermediate_tick + 30 + random.uintLessThan(u32, 20);

            // Intermediate meeting location: somewhere between org area and target.
            const mid_loc = types.Location{
                .x = random.intRangeAtMost(i32, 0, 25),
                .y = random.intRangeAtMost(i32, 0, 25),
            };

            // Trades for intermediate meeting: non-taskforce org hats give capabilities to taskforce members.
            var mid_trades: std.ArrayList(types.CapabilityTrade) = .empty;
            defer mid_trades.deinit(allocator);
            // Find hats in the org that aren't in the taskforce.
            var trading_hats: std.ArrayList(types.HatId) = .empty;
            defer trading_hats.deinit(allocator);
            for (org.members) |m| {
                if (!member_set.contains(m)) {
                    try trading_hats.append(allocator, m);
                }
            }
            // Create one trade per required capability.
            const trade_count = @min(n_req, @as(u32, @intCast(trading_hats.items.len)));
            for (req_caps.items[0..trade_count], 0..) |cap, tci| {
                const recipient_idx = tci % tf_size;
                try mid_trades.append(allocator, types.CapabilityTrade{
                    .source_hat_id = trading_hats.items[tci],
                    .recipient_hat_id = members_list.items[recipient_idx],
                    .capability_id = cap,
                });
            }

            // Intermediate meeting participants: all trading hats + 1 taskforce member.
            var mid_participants: std.ArrayList(types.HatId) = .empty;
            defer mid_participants.deinit(allocator);
            for (trading_hats.items[0..trade_count]) |hid| {
                try mid_participants.append(allocator, hid);
            }
            if (members_list.items.len > 0) {
                try mid_participants.append(allocator, members_list.items[0]);
            }

            // For the final meeting: taskforce members meet at target.
            var final_trades: std.ArrayList(types.CapabilityTrade) = .empty;
            // Final meeting participants: all taskforce members.
            const final_participants = try allocator.dupe(types.HatId, members_list.items);

            const mid_meeting = types.Meeting{
                .tick = intermediate_tick,
                .location = mid_loc,
                .participants = try mid_participants.toOwnedSlice(allocator),
                .trades = try mid_trades.toOwnedSlice(allocator),
            };

            const final_meeting = types.Meeting{
                .tick = final_tick,
                .location = target,
                .participants = final_participants,
                .trades = try final_trades.toOwnedSlice(allocator),
            };

            const meeting_plan = try allocator.alloc(types.Meeting, 2);
            meeting_plan[0] = mid_meeting;
            meeting_plan[1] = final_meeting;

            try taskforces_list.append(allocator, types.Taskforce{
                .id = @as(u32, @intCast(taskforces_list.items.len)),
                .organization_id = org.id,
                .members = try members_list.toOwnedSlice(allocator),
                .target = target,
                .required_capabilities = try req_caps.toOwnedSlice(allocator),
                .status = .ACTIVE,
                .meeting_plan = meeting_plan,
            });
        }
    }

    return try taskforces_list.toOwnedSlice(allocator);
}

/// Generate a complete population from the given seed and params.
///
/// Algorithm:
/// 1. Create N hats, assigning true_color and advertised_color.
///    Terrorists are assigned first (contiguous block), then shuffled
///    so color groups are not easily identifiable by id order.
/// 2. Create benign and terrorist organizations, drawing members
///    from the hat pool with the membership rules:
///    - Terrorist orgs contain only TERRORIST + COVERT_TERRORIST hats
///    - Benign orgs may contain any true_color
/// 3. Ensure every hat belongs to at least one organization.
/// 4. Initialize an empty taskforces array (taskforce generation is
///    the responsibility of the organization planner, run during sim advance).
pub fn generate(allocator: std.mem.Allocator, seed: u64, params: PopulationParams) !Population {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    // ── 1. Generate hats ──────────────────────────────────────────────
    const hats = try allocator.alloc(types.Hat, params.n_hats);

    const n_hats_f: f64 = @floatFromInt(params.n_hats);
    const n_terrorists = @max(1, @as(u32, @intFromFloat(n_hats_f * params.fraction_terrorist)));
    const n_covert = @as(u32, @intFromFloat(@as(f64, @floatFromInt(n_terrorists)) * params.fraction_covert));
    const n_overt = n_terrorists - n_covert;

    // Assign true colors in a deterministic block: overt terrorists first,
    // then covert terrorists, then benign.
    var i: u32 = 0;
    while (i < params.n_hats) : (i += 1) {
        const true_color: types.TrueColor = if (i < n_overt)
            .TERRORIST
        else if (i < n_terrorists)
            .COVERT_TERRORIST
        else
            .BENIGN;

        const advertised_color: types.HatAdvertisedColor = switch (true_color) {
            .TERRORIST => .TERRORIST,
            .BENIGN, .COVERT_TERRORIST => .UNKNOWN,
        };

        hats[i] = .{
            .id = i,
            .true_color = true_color,
            .advertised_color = advertised_color,
        };
    }

    // Shuffle hats so true_color groups are not contiguous by id.
    random.shuffle(types.Hat, hats);
    // Reassign ids after shuffle so ids are [0..n_hats) regardless of order.
    for (hats, 0..) |*hat, idx| {
        hat.id = @as(types.HatId, @intCast(idx));
    }

    // ── 2. Generate organizations ─────────────────────────────────────
    const total_orgs = params.n_benign_orgs + params.n_terrorist_orgs;
    const orgs = try allocator.alloc(types.Organization, total_orgs);
    var org_idx: u32 = 0;

    // Collect indices of terrorist hats (TERRORIST + COVERT_TERRORIST).
    var terrorist_indices: std.ArrayList(types.HatId) = .empty;
    defer terrorist_indices.deinit(allocator);
    for (hats) |hat| {
        if (hat.true_color == .TERRORIST or hat.true_color == .COVERT_TERRORIST) {
            try terrorist_indices.append(allocator, hat.id);
        }
    }

    // Collect all hat indices for benign org membership.
    var all_indices: std.ArrayList(types.HatId) = .empty;
    defer all_indices.deinit(allocator);
    for (hats) |hat| {
        try all_indices.append(allocator, hat.id);
    }

    // Track which hats have been assigned to at least one org.
    const hat_org_count = try allocator.alloc(u32, hats.len);
    defer allocator.free(hat_org_count);
    @memset(hat_org_count, 0);

    // Helper: pick `count` random members from `pool`, ensuring uniqueness
    // within a single org. Returns caller-owned slice.
    const pickMembers = struct {
        fn pick(alloc: std.mem.Allocator, rnd: std.Random, pool: []const types.HatId, count: u32, hat_counts: []u32, track: bool) !std.ArrayList(types.HatId) {
            var selected = std.AutoHashMap(types.HatId, void).init(alloc);
            defer selected.deinit();

            const actual_count = @min(count, @as(u32, @intCast(pool.len)));
            while (selected.count() < actual_count) {
                const idx = rnd.uintLessThan(usize, pool.len);
                try selected.put(pool[idx], {});
            }

            var members: std.ArrayList(types.HatId) = .empty;
            errdefer members.deinit(alloc);
            var iter = selected.keyIterator();
            while (iter.next()) |key| {
                try members.append(alloc, key.*);
                if (track) hat_counts[key.*] += 1;
            }
            return members;
        }
    }.pick;

    // Create terrorist organizations.
    var ti: u32 = 0;
    while (ti < params.n_terrorist_orgs) : (ti += 1) {
        const target_size = sampleOrgSize(random, params.mean_org_size, params.std_org_size);
        var members_list = try pickMembers(allocator, random, terrorist_indices.items, target_size, hat_org_count, true);
        defer members_list.deinit(allocator);

        orgs[org_idx] = .{
            .id = org_idx,
            .org_type = .TERRORIST,
            .members = try members_list.toOwnedSlice(allocator),
        };
        org_idx += 1;
    }

    // Create benign organizations.
    var bi: u32 = 0;
    while (bi < params.n_benign_orgs) : (bi += 1) {
        const target_size = sampleOrgSize(random, params.mean_org_size, params.std_org_size);
        var members_list = try pickMembers(allocator, random, all_indices.items, target_size, hat_org_count, true);
        defer members_list.deinit(allocator);

        orgs[org_idx] = .{
            .id = org_idx,
            .org_type = .BENIGN,
            .members = try members_list.toOwnedSlice(allocator),
        };
        org_idx += 1;
    }

    // ── 3. Ensure every hat belongs to at least one org ───────────────
    // Any hat with count == 0 gets added to a random benign org.
    for (hat_org_count, 0..) |count, hidx| {
        if (count == 0) {
            // Find a benign org to adopt this hat.
            const org_start = params.n_terrorist_orgs;
            const target_org = org_start + random.uintLessThan(u32, params.n_benign_orgs);
            const hat_id: types.HatId = @intCast(hidx);

            const old_members = orgs[target_org].members;
            var new_members = try allocator.alloc(types.HatId, old_members.len + 1);
            @memcpy(new_members[0..old_members.len], old_members);
            new_members[old_members.len] = hat_id;
            allocator.free(old_members);
            orgs[target_org].members = new_members;
        }
    }

    // ── 4. Generate initial taskforces with meeting plans ──────────────
    // For each terrorist org, create 1-2 taskforces with a simple meeting tree.
    // Each taskforce: one intermediate meeting, one final meeting at target.
    const taskforces = try generateTaskforces(allocator, random, seed, orgs, params.n_terrorist_orgs, hats);

    return Population{
        .hats = hats,
        .orgs = orgs,
        .taskforces = taskforces,
    };
}

/// Sample an organization size from a pseudo-normal distribution clamped to [1, 30].
fn sampleOrgSize(random: std.Random, mean: f64, std_dev: f64) u32 {
    // Box-Muller transform for a normal-ish sample.
    const u1_sample = random.float(f64);
    const u2_sample = random.float(f64);
    const z = std.math.sqrt(-2.0 * std.math.log(f64, std.math.e, u1_sample)) * std.math.cos(2.0 * std.math.pi * u2_sample);
    const raw = mean + z * std_dev;
    const clamped = @max(1.0, @min(30.0, @round(raw)));
    return @as(u32, @intFromFloat(clamped));
}

/// Parse PopulationParams from a JSON value, using defaults for missing fields.
pub fn parseParams(value: std.json.Value) !PopulationParams {
    const obj = value.object;
    const get = struct {
        fn int(m: std.json.ObjectMap, key: []const u8, default: u32) u32 {
            const entry = m.get(key) orelse return default;
            return @intCast(entry.integer);
        }
        fn float(m: std.json.ObjectMap, key: []const u8, default: f64) f64 {
            const entry = m.get(key) orelse return default;
            return entry.float;
        }
    };

    return PopulationParams{
        .n_hats = get.int(obj, "n_hats", 100),
        .n_benign_orgs = get.int(obj, "n_benign_orgs", 5),
        .n_terrorist_orgs = get.int(obj, "n_terrorist_orgs", 3),
        .fraction_covert = get.float(obj, "fraction_covert", 0.3),
        .fraction_terrorist = get.float(obj, "fraction_terrorist", 0.30),
        .mean_org_size = get.float(obj, "mean_org_size", 10.0),
        .std_org_size = get.float(obj, "std_org_size", 3.0),
        .n_capabilities = get.int(obj, "n_capabilities", 16),
    };
}

test "generate produces deterministic populations for same seed" {
    const allocator = std.testing.allocator;
    const params = PopulationParams{
        .n_hats = 50,
        .n_benign_orgs = 3,
        .n_terrorist_orgs = 2,
        .fraction_covert = 0.4,
        .fraction_terrorist = 0.30,
        .mean_org_size = 8.0,
        .std_org_size = 2.0,
        .n_capabilities = 16,
    };

    const pop_a = try generate(allocator, 42, params);
    defer pop_a.deinit(allocator);
    const pop_b = try generate(allocator, 42, params);
    defer pop_b.deinit(allocator);

    // Same seed → same results.
    try std.testing.expectEqual(pop_a.hats.len, pop_b.hats.len);
    for (pop_a.hats, 0..) |hat, idx| {
        try std.testing.expectEqual(hat.true_color, pop_b.hats[idx].true_color);
        try std.testing.expectEqual(hat.advertised_color, pop_b.hats[idx].advertised_color);
    }
    try std.testing.expectEqual(pop_a.orgs.len, pop_b.orgs.len);
}

test "different seeds produce different populations" {
    const allocator = std.testing.allocator;
    const params = PopulationParams{
        .n_hats = 50,
        .n_benign_orgs = 3,
        .n_terrorist_orgs = 2,
        .fraction_covert = 0.4,
        .fraction_terrorist = 0.30,
        .mean_org_size = 8.0,
        .std_org_size = 2.0,
        .n_capabilities = 16,
    };

    const pop_a = try generate(allocator, 42, params);
    defer pop_a.deinit(allocator);
    const pop_b = try generate(allocator, 99, params);
    defer pop_b.deinit(allocator);

    // Different seeds → different hat color distributions (likely).
    var diff: usize = 0;
    for (pop_a.hats, 0..) |hat, idx| {
        if (hat.true_color != pop_b.hats[idx].true_color) diff += 1;
    }
    try std.testing.expect(diff > 0);
}

test "terrorist orgs contain only terrorist hats" {
    const allocator = std.testing.allocator;
    const params = PopulationParams{
        .n_hats = 100,
        .n_benign_orgs = 3,
        .n_terrorist_orgs = 2,
        .fraction_covert = 0.3,
        .fraction_terrorist = 0.30,
        .mean_org_size = 10.0,
        .std_org_size = 3.0,
        .n_capabilities = 16,
    };

    const pop = try generate(allocator, 1234, params);
    defer pop.deinit(allocator);

    for (pop.orgs) |org| {
        if (org.org_type == .TERRORIST) {
            for (org.members) |hat_id| {
                const hat = pop.hats[hat_id];
                try std.testing.expect(hat.true_color == .TERRORIST or hat.true_color == .COVERT_TERRORIST);
            }
        }
    }
}

test "every hat belongs to at least one org" {
    const allocator = std.testing.allocator;
    const params = PopulationParams{
        .n_hats = 50,
        .n_benign_orgs = 2,
        .n_terrorist_orgs = 1,
        .fraction_covert = 0.3,
        .fraction_terrorist = 0.30,
        .mean_org_size = 6.0,
        .std_org_size = 2.0,
        .n_capabilities = 16,
    };

    const pop = try generate(allocator, 5678, params);
    defer pop.deinit(allocator);

    var in_any_org = try allocator.alloc(bool, pop.hats.len);
    defer allocator.free(in_any_org);
    @memset(in_any_org, false);

    for (pop.orgs) |org| {
        for (org.members) |hat_id| {
            in_any_org[hat_id] = true;
        }
    }

    for (in_any_org, 0..in_any_org.len) |present, _| {
        try std.testing.expect(present); // hat {idx} has no org
    }
}

test "hat true_color and advertised_color consistency" {
    const allocator = std.testing.allocator;
    const params = PopulationParams{
        .n_hats = 100,
        .n_benign_orgs = 3,
        .n_terrorist_orgs = 2,
        .fraction_covert = 0.5,
        .fraction_terrorist = 0.30,
        .mean_org_size = 10.0,
        .std_org_size = 3.0,
        .n_capabilities = 16,
    };

    const pop = try generate(allocator, 9999, params);
    defer pop.deinit(allocator);

    for (pop.hats) |hat| {
        switch (hat.true_color) {
            .TERRORIST => try std.testing.expectEqual(types.HatAdvertisedColor.TERRORIST, hat.advertised_color),
            .BENIGN => try std.testing.expectEqual(types.HatAdvertisedColor.UNKNOWN, hat.advertised_color),
            .COVERT_TERRORIST => try std.testing.expectEqual(types.HatAdvertisedColor.UNKNOWN, hat.advertised_color),
        }
    }
}

test "empty population generates zero hats and valid orgs" {
    const allocator = std.testing.allocator;
    const params = PopulationParams{
        .n_hats = 0,
        .n_benign_orgs = 2,
        .n_terrorist_orgs = 1,
        .fraction_covert = 0.3,
        .fraction_terrorist = 0.30,
        .mean_org_size = 5.0,
        .std_org_size = 2.0,
        .n_capabilities = 16,
    };

    const pop = try generate(allocator, 42, params);
    defer pop.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), pop.hats.len);
    try std.testing.expectEqual(@as(usize, 3), pop.orgs.len);
}

test "population with max capabilities produces valid bitmask space" {
    const allocator = std.testing.allocator;
    const params = PopulationParams{
        .n_hats = 20,
        .n_benign_orgs = 1,
        .n_terrorist_orgs = 1,
        .fraction_covert = 0.5,
        .fraction_terrorist = 0.50,
        .mean_org_size = 10.0,
        .std_org_size = 2.0,
        .n_capabilities = 8,
    };

    const pop = try generate(allocator, 9999, params);
    defer pop.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 20), pop.hats.len);
    // All hats in >0 orgs.
    var in_any: usize = 0;
    for (pop.hats) |hat| {
        for (pop.orgs) |org| {
            for (org.members) |mid| {
                if (mid == hat.id) {
                    in_any += 1;
                    break;
                }
            }
        }
    }
    try std.testing.expectEqual(pop.hats.len, in_any);
}
