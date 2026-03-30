const std = @import("std");

const operator = @import("operator.zig");
const value = @import("value.zig");

pub const ParameterAST = struct {
    name: []const u8,
    operator: operator.OperatorAST,
    value: value.ValueAst,
};