const std = @import("std");

pub fn TypedId(comptime name: []const u8) type {
    return struct {
        pub const T = enum(usize) {
            const Self = @This();
            pub const _name = name;
            invalid = std.math.maxInt(usize),
            _,

            pub fn toIndex(self: Self) ?usize {
                const val = @intFromEnum(self);
                if (val == std.math.maxInt(usize)) return null;
                return val;
            }

            pub fn fromIndex(idx: ?usize) Self {
                return if (idx) |i| @enumFromInt(i) else .invalid;
            }

            pub fn isValid(self: Self) bool {
                return self != .invalid;
            }
        };
    }.T;
}
