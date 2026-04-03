const std         = @import("std");
const identifiers = @import("../utils/identifiers.zig");
const storage = @import("storage.zig");
pub const ValueStringIdentifier = identifiers.TypedId("ValueString", .str, []const u8, []const u8);
pub const StringValueInit = storage.StringInit(ValueStringIdentifier);

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

test "value: Value initialization methods" {
    const v_i32    = Value.initI32(42);
    const v_i64    = Value.initI64(1000);
    const v_f32    = Value.initF32(3.14);
    const v_f64    = Value.initF64(2.71828);
    const v_string = Value.initString(5);
    const v_array  = Value.initArray(10);
    try std.testing.expectEqual(v_i32.i32, 42);
    try std.testing.expectEqual(v_i64.i64, 1000);
    try std.testing.expectApproxEqAbs(v_f32.f32, 3.14, 0.01);
    try std.testing.expectApproxEqAbs(v_f64.f64, 2.71828, 0.00001);
    try std.testing.expectEqual(v_string.string, 5);
    try std.testing.expectEqual(v_array.array, 10);
}

test "value: needsCleanup is true only for array" {
    try std.testing.expect(!Value.initI32(0).needsCleanup());
    try std.testing.expect(!Value.initI64(0).needsCleanup());
    try std.testing.expect(!Value.initF32(0.0).needsCleanup());
    try std.testing.expect(!Value.initF64(0.0).needsCleanup());
    try std.testing.expect(!Value.initString(0).needsCleanup());
    try std.testing.expect(Value.initArray(0).needsCleanup());
}

test "value: isNumeric is true for numeric types only" {
    try std.testing.expect(Value.initI32(0).isNumeric());
    try std.testing.expect(Value.initI64(0).isNumeric());
    try std.testing.expect(Value.initF32(0.0).isNumeric());
    try std.testing.expect(Value.initF64(0.0).isNumeric());
    try std.testing.expect(!Value.initString(0).isNumeric());
    try std.testing.expect(!Value.initArray(0).isNumeric());
}

test "value: sizeOf matches @sizeOf" {
    try std.testing.expectEqual(@sizeOf(Value), Value.sizeOf());
}

test "value: i32 boundary values" {
    const v_max  = Value.initI32(std.math.maxInt(i32));
    const v_min  = Value.initI32(std.math.minInt(i32));
    const v_zero = Value.initI32(0);
    try std.testing.expectEqual(std.math.maxInt(i32), v_max.i32);
    try std.testing.expectEqual(std.math.minInt(i32), v_min.i32);
    try std.testing.expectEqual(@as(i32, 0), v_zero.i32);
    try std.testing.expect(v_max.isNumeric());
    try std.testing.expect(!v_max.needsCleanup());
}

test "value: i64 boundary values" {
    try std.testing.expectEqual(std.math.maxInt(i64), Value.initI64(std.math.maxInt(i64)).i64);
    try std.testing.expectEqual(std.math.minInt(i64), Value.initI64(std.math.minInt(i64)).i64);
}

test "value: f32 special values" {
    const v_inf     = Value.initF32(std.math.inf(f32));
    const v_neg_inf = Value.initF32(-std.math.inf(f32));
    try std.testing.expect(std.math.isInf(v_inf.f32));
    try std.testing.expect(std.math.isInf(v_neg_inf.f32));
    try std.testing.expect(v_inf.isNumeric());
    try std.testing.expect(!v_inf.needsCleanup());
}

test "value: f64 precision (pi)" {
    const v = Value.initF64(std.math.pi);
    try std.testing.expectApproxEqAbs(std.math.pi, v.f64, 1e-15);
    try std.testing.expect(v.isNumeric());
}

test "value: active tag matches init method" {
    try std.testing.expect(Value.initI32(1)   == .i32);
    try std.testing.expect(Value.initI64(1)   == .i64);
    try std.testing.expect(Value.initF32(1.0) == .f32);
    try std.testing.expect(Value.initF64(1.0) == .f64);
    try std.testing.expect(Value.initString(0) == .string);
    try std.testing.expect(Value.initArray(0)  == .array);
}

test "value: negative numeric values" {
    try std.testing.expectEqual(@as(i32, -42),    Value.initI32(-42).i32);
    try std.testing.expectEqual(@as(i64, -1000),  Value.initI64(-1000).i64);
    try std.testing.expect(Value.initF32(-3.14).isNumeric());
    try std.testing.expect(Value.initF64(-2.71828).isNumeric());
}

test "value: large index values" {
    const large: usize = 999_999;
    try std.testing.expectEqual(large, Value.initString(large).string);
    try std.testing.expectEqual(large, Value.initArray(large).array);
}