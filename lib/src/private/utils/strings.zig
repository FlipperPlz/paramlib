const std = @import("std");

const Allocator = std.mem.Allocator;


pub fn StringPool(comptime Tid: type) type {
    return comptime struct {
        const Self = @This();
        strings: std.ArrayListUnmanaged([]const u8),
        lookup: std.StringHashMapUnmanaged(Tid),

        pub const empty: Self = .{
            .strings = .empty,
            .lookup = .empty,
        };

        pub fn deinit(self: *Self, allocator: Allocator) void {
            for (self.strings.items) |str| {
                allocator.free(str);
            }
            self.strings.deinit(allocator);
            self.lookup.deinit(allocator);
        }

        pub fn intern(self: *Self, allocator: Allocator, str: []const u8) !struct {idx: Tid, str: []const u8} {
            if (self.lookup.get(str)) |idx| {
                return .{ .idx = idx, .str = self.strings.items[idx.toIndex().?] };
            }

            const owned = try allocator.dupe(u8, str);
            errdefer allocator.free(owned);

            const idx: Tid = blk: {
                const i = Tid.fromIndex(self.strings.items.len);
                try self.strings.append(allocator, owned);
                break :blk i;
            };

            try self.lookup.put(allocator, owned, idx);
            return .{ .idx = idx, .str = owned };
        }

        pub fn get(self: *const Self, id: Tid) !?[]const u8 {
            if (!id.isValid()) return error.InvalidId;
            const index = id.toIndex() orelse return null;
            if (index >= self.strings.items.len) return null;
            return self.strings.items[index];
        }

        pub inline fn count(self: *const Self) usize {
            return self.strings.items.len;
        }
    };
}

const identifiers = @import("identifiers.zig");

test "strings: intern single string" {
    const Tid = identifiers.TypedId("StrTest1", .str, []const u8, []const u8);
    var pool = StringPool(Tid).empty;
    defer pool.deinit(std.testing.allocator);

    const result = try pool.intern(std.testing.allocator, "player.health");
    try std.testing.expect(result.idx.isValid());
    try std.testing.expectEqualStrings("player.health", result.str);
}

test "strings: intern same string twice returns same index (dedup)" {
    const Tid = identifiers.TypedId("StrTest2", .str, []const u8, []const u8);
    var pool = StringPool(Tid).empty;
    defer pool.deinit(std.testing.allocator);

    const r1 = try pool.intern(std.testing.allocator, "speed");
    const r2 = try pool.intern(std.testing.allocator, "speed");
    try std.testing.expectEqual(r1.idx, r2.idx);
    try std.testing.expectEqualStrings(r1.str, r2.str);
}

test "strings: different strings get different indices" {
    const Tid = identifiers.TypedId("StrTest3", .str, []const u8, []const u8);
    var pool = StringPool(Tid).empty;
    defer pool.deinit(std.testing.allocator);

    const r1 = try pool.intern(std.testing.allocator, "health");
    const r2 = try pool.intern(std.testing.allocator, "mana");
    const r3 = try pool.intern(std.testing.allocator, "stamina");
    try std.testing.expect(r1.idx != r2.idx);
    try std.testing.expect(r2.idx != r3.idx);
    try std.testing.expect(r1.idx != r3.idx);
}

test "strings: get returns correct string" {
    const Tid = identifiers.TypedId("StrTest4", .str, []const u8, []const u8);
    var pool = StringPool(Tid).empty;
    defer pool.deinit(std.testing.allocator);

    const result = try pool.intern(std.testing.allocator, "player_name");
    const retrieved = try pool.get(result.idx);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqualStrings("player_name", retrieved.?);
}

test "strings: get with .invalid id returns error" {
    const Tid = identifiers.TypedId("StrTest5", .str, []const u8, []const u8);
    var pool = StringPool(Tid).empty;
    defer pool.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidId, pool.get(Tid.invalid));
}

test "strings: get out-of-bounds index returns null" {
    const Tid = identifiers.TypedId("StrTest7", .str, []const u8, []const u8);
    var pool = StringPool(Tid).empty;
    defer pool.deinit(std.testing.allocator);

    const oob_id: Tid = @enumFromInt(5);
    try std.testing.expectEqual(@as(?[]const u8, null), try pool.get(oob_id));
}

test "strings: count reflects unique interns only" {
    const Tid = identifiers.TypedId("StrTest8", .str, []const u8, []const u8);
    var pool = StringPool(Tid).empty;
    defer pool.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), pool.count());
    _ = try pool.intern(std.testing.allocator, "health");
    try std.testing.expectEqual(@as(usize, 1), pool.count());
    _ = try pool.intern(std.testing.allocator, "mana");
    try std.testing.expectEqual(@as(usize, 2), pool.count());
    _ = try pool.intern(std.testing.allocator, "health"); // duplicate — no change
    try std.testing.expectEqual(@as(usize, 2), pool.count());
}

test "strings: empty string can be interned" {
    const Tid = identifiers.TypedId("StrTest9", .str, []const u8, []const u8);
    var pool = StringPool(Tid).empty;
    defer pool.deinit(std.testing.allocator);

    const result = try pool.intern(std.testing.allocator, "");
    try std.testing.expect(result.idx.isValid());
    const retrieved = try pool.get(result.idx);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqualStrings("", retrieved.?);
}

test "strings: game stat registry - intern 20 stats, retrieve all correctly" {
    const Tid = identifiers.TypedId("StrTest11", .str, []const u8, []const u8);
    var pool = StringPool(Tid).empty;
    defer pool.deinit(std.testing.allocator);

    const stat_names = [_][]const u8{
        "health", "mana", "stamina", "strength", "dexterity",
        "intelligence", "charisma", "luck", "speed", "attack",
        "defense", "magic_attack", "magic_defense", "critical_rate",
        "evasion", "accuracy", "fire_resist", "ice_resist",
        "lightning_resist", "poison_resist",
    };

    var ids: [stat_names.len]Tid = undefined;
    for (stat_names, 0..) |name, i| {
        ids[i] = (try pool.intern(std.testing.allocator, name)).idx;
    }
    try std.testing.expectEqual(@as(usize, stat_names.len), pool.count());

    // All stats retrievable
    for (stat_names, ids) |name, id| {
        const retrieved = try pool.get(id);
        try std.testing.expect(retrieved != null);
        try std.testing.expectEqualStrings(name, retrieved.?);
    }

    for (stat_names, ids) |name, expected_id| {
        const re = try pool.intern(std.testing.allocator, name);
        try std.testing.expectEqual(expected_id, re.idx);
    }
    try std.testing.expectEqual(@as(usize, stat_names.len), pool.count());
}
