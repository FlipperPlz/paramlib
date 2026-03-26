const std         = @import("std");
const identifiers = @import("../utils/identifiers.zig");

pub const ValueStringIdentifier = identifiers.TypedId("ValueString");

pub const ValueType = enum {
    i32,
    i64,
    f32,
    f64,
    string,
    array,
};

pub const Value = union(ValueType) {
    i32:    i32,
    i64:    i64,
    f32:    f32,
    f64:    f64,
    string: usize,
    array:  usize,

    pub fn initI32(val: i32) Value {
        return .{ .i32 = val };
    }

    pub fn initI64(val: i64) Value {
        return .{ .i64 = val };
    }

    pub fn initF32(val: f32) Value {
        return .{ .f32 = val };
    }

    pub fn initF64(val: f64) Value {
        return .{ .f64 = val };
    }

    pub fn initString(idx: usize) Value {
        return .{ .string = idx };
    }

    pub fn initArray(idx: usize) Value {
        return .{ .array = idx };
    }

    pub fn needsCleanup(self: Value) bool {
        return self == .array;
    }

    pub fn isNumeric(self: Value) bool {
        return switch (self) {
            .i32, .i64, .f32, .f64 => true,
            else => false,
        };
    }

    pub fn sizeOf() usize {
        return @sizeOf(Value);
    }

};
