const std = @import("std");

pub const ValueData = union {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
    string: u32,
    array: u32,

    pub fn initI32(val: i32) Value {
        return .{ .{ .i32 = val } };
    }

    pub fn initI64(val: i64) Value {
        return .{ .{ .i64 = val } };
    }

    pub fn initF32(val: f32) Value {
        return .{ .{ .f32 = val } };
    }

    pub fn initF64(val: f64) Value {
        return .{ .{ .f64 = val } };
    }

    pub fn initString(idx: u32) Value {
        return .{ .{ .string = idx } };
    }

    pub fn initArray(idx: u32) Value {
        return .{ .{ .array = idx } };
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

    pub fn format(
        self: Value,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .i32 => try writer.print("i32({})", .{self.i32}),
            .i64 => try writer.print("i64({})", .{self.i64}),
            .f32 => try writer.print("f32({})", .{self.f32}),
            .f64 => try writer.print("f64({})", .{self.f64}),
            .string => try writer.print("string(idx:{})", .{self.string}),
            .array => try writer.print("array(idx:{})", .{self.array}),
        }
    }
};

pub const Value = struct {
    data: ValueData,
    path_hash: u64
};

