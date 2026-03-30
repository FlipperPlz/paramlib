const std = @import("std");

const ValueAst = union(enum) {
    float: f32,
    integer: i32,
    i64: i64,
    array: []const ValueAst,
    expression: []const u8,
    string: []const u8,
};