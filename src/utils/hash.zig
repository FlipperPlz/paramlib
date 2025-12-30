const std = @import("std");

pub fn hashName(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0, name);
}

pub fn hashPath(parent_hash: u64, name_hash: u64) u64 {
    var hasher = std.hash.Wyhash.init(parent_hash);
    hasher.update(std.mem.asBytes(&name_hash));
    return hasher.final();
}

pub fn hashData(data: []const u8) u64 {
    return std.hash.Wyhash.hash(0, data);
}

pub fn hashWithSeed(seed: u64, data: []const u8) u64 {
    return std.hash.Wyhash.hash(seed, data);
}

pub fn hashNameCaseInsensitive(name: []const u8, allocator: std.mem.Allocator) !u64 {
    const lower = try std.ascii.allocLowerString(allocator, name);
    defer allocator.free(lower);
    return hashName(lower);
}

pub fn hashStrings(strings: []const []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (strings) |str| {
        hasher.update(str);
        hasher.update(&[_]u8{0});
    }
    return hasher.final();
}

pub fn combineHashes(a: u64, b: u64) u64 {
    var hasher = std.hash.Wyhash.init(a);
    hasher.update(std.mem.asBytes(&b));
    return hasher.final();
}

pub const HashBuilder = struct {
    hasher: std.hash.Wyhash,

    pub fn init(seed: u64) HashBuilder {
        return .{ .hasher = std.hash.Wyhash.init(seed) };
    }

    pub fn update(self: *HashBuilder, data: []const u8) void {
        self.hasher.update(data);
    }

    pub fn updateInt(self: *HashBuilder, value: anytype) void {
        self.hasher.update(std.mem.asBytes(&value));
    }

    pub fn finalize(self: *HashBuilder) u64 {
        return self.hasher.final();
    }
};

pub fn testCollision(a: []const u8, b: []const u8) bool {
    return hashName(a) == hashName(b);
}