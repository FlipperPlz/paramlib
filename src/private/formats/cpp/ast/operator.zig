const std = @import("std");

pub const OperatorAST = enum {
    addAssign,
    subAssign,
    assign
};