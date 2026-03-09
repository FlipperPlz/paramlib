const std = @import("std");

pub inline fn hash(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0, name);
}