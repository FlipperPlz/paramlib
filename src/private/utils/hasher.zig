const std = @import("std");
const paths = @import("paths.zig");

const FnvOffsetBasis: u64 = 0xcbf29ce484222325;
const FnvPrime: u64 = 0x100000001b3;

pub inline fn hash(name: []const u8) u64 {
    var h: u64 = FnvOffsetBasis;
    for (name) |c| {
        const byte = std.ascii.toLower(c);
        h ^= byte;
        h *%= FnvPrime;
    }
    return h;
}

pub const IncrementalHasher = struct {
    inner: u64,

    pub fn init() IncrementalHasher {
        return load(FnvOffsetBasis);
    }

    pub fn load(value: u64) IncrementalHasher {
        return .{ .inner = value };
    }

    pub fn update(self: *IncrementalHasher, data: []const u8) *IncrementalHasher {
        var buf: [512]u8 = undefined;
        var i: usize = 0;

        while (i < data.len) {
            const end = @min(i + buf.len, data.len);
            const chunk = data[i..end];

            for (buf[0..chunk.len], chunk) |*dst, src| {
                dst.* = std.ascii.toLower(src);
            }

            for (buf[0..chunk.len]) |byte| {
                self.inner ^= byte;
                self.inner *%= FnvPrime;
            }

            i = end;
        }
        return self;
    }

    pub inline fn updateSep(self: *IncrementalHasher) *IncrementalHasher {
        self.update(paths.PathSeparator);

        return self;
    }

    pub inline fn final(self: *const IncrementalHasher) u64 {
        return self.inner;
    }
};

test "hasher: same string produces same hash" {
    try std.testing.expectEqual(hash("test_string"), hash("test_string"));
}

test "hasher: different strings produce different hashes" {
    try std.testing.expect(hash("string1") != hash("string2"));
    try std.testing.expect(hash("string2") != hash("string3"));
}

test "hasher: empty string hashes consistently" {
    try std.testing.expectEqual(hash(""), hash(""));
}

test "hasher: single character strings differ" {
    try std.testing.expect(hash("a") != hash("b"));
}

test "hasher: path strings produce consistent hashes" {
    const path = "root.module.parameter";
    try std.testing.expectEqual(hash(path), hash(path));
    try std.testing.expect(hash(path) != hash("root.module.different"));
}

test "hasher: near-identical paths all differ (hash quality)" {
    const h1 = hash("player.health");
    const h4 = hash("playe.rhealth");
    try std.testing.expect(h1 != h4);
}

test "hasher: long deeply nested path is consistent" {
    const p = "root.world.level1.zone_a.area_3.room_7.chest.loot.weapon.sword.damage";
    try std.testing.expectEqual(hash(p), hash(p));
}
