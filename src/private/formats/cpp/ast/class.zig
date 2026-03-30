const std = @import("std");
const member = @import("./member.zig");

pub const ClassAST = struct {
    name: []const u8,
    base: []const u8,
    members: []const member.MemberAST,
};