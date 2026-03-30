const std = @import("std");

pub const EnumerableAST = struct {
    values: []const EnumerableValueAst,
};

pub const EnumerableValueAst = struct {
    name: []const u8,
    value: f32,
};