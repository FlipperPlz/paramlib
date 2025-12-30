const std = @import("std");

pub const enable_logging = true;

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (enable_logging) {
        std.debug.print(fmt ++ "\n", args);
    }
}
