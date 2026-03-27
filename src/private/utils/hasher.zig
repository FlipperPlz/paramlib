const std = @import("std");

pub inline fn hash(name: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    for (name) |c| h.update(&[1]u8{std.ascii.toLower(c)});
    return h.final();
}