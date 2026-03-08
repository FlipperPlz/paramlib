const std = @import("std");

const testing = std.testing;

test {
    testing.refAllDecls(@import("utils/strings.zig"));
    testing.refAllDecls(@import("utils/memory.zig"));
}