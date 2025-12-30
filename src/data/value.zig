const std = @import("std");

pub const ValueTag = enum(u4) {
    i32,
    i64,
    f32,
    f64,
    string,
    array,
};

pub const Value = struct {
    tag: ValueTag,
    flags: packed struct(u4) {
        is_constant: bool = false,
        _reserved: u3 = 0,
    } = .{},
    data: Data,

    const Data = union {
        i32: i32,
        i64: i64,
        f32: f32,
        f64: f64,
        string: u32,
        array: u32,
    };

    pub fn initI32(val: i32) Value {
        return .{ .tag = .i32, .data = .{ .i32 = val } };
    }

    pub fn initI64(val: i64) Value {
        return .{ .tag = .i64, .data = .{ .i64 = val } };
    }

    pub fn initF32(val: f32) Value {
        return .{ .tag = .f32, .data = .{ .f32 = val } };
    }

    pub fn initF64(val: f64) Value {
        return .{ .tag = .f64, .data = .{ .f64 = val } };
    }

    pub fn initString(idx: u32) Value {
        return .{ .tag = .string, .data = .{ .string = idx } };
    }

    pub fn initArray(idx: u32) Value {
        return .{ .tag = .array, .data = .{ .array = idx } };
    }

    pub fn needsCleanup(self: Value) bool {
        return self.tag == .array;
    }

    pub fn isNumeric(self: Value) bool {
        return switch (self.tag) {
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
        switch (self.tag) {
            .i32 => try writer.print("i32({})", .{self.data.i32}),
            .i64 => try writer.print("i64({})", .{self.data.i64}),
            .f32 => try writer.print("f32({})", .{self.data.f32}),
            .f64 => try writer.print("f64({})", .{self.data.f64}),
            .string => try writer.print("string(idx:{})", .{self.data.string}),
            .array => try writer.print("array(idx:{})", .{self.data.array}),
            .boolean => try writer.print("bool({})", .{self.data.boolean}),
        }
    }
};

pub const ArrayData = struct {
    values: std.ArrayList(Value),

    pub const empty: ArrayData = .{
        .values = std.ArrayList(Value).empty,
    };

    pub fn deinit(self: *ArrayData, allocator: std.mem.Allocator) void {
        self.values.deinit(allocator);
    }

    pub fn append(self: *ArrayData, value: Value, allocator: std.mem.Allocator) !void {
        try self.values.append(allocator, value);
    }

    pub fn get(self: *const ArrayData, index: usize) ?Value {
        if (index >= self.values.items.len) return null;
        return self.values.items[index];
    }

    pub fn set(self: *ArrayData, index: usize, value: Value) !void {
        if (index >= self.values.items.len) return error.IndexOutOfBounds;
        self.values.items[index] = value;
    }

    pub fn len(self: *const ArrayData) usize {
        return self.values.items.len;
    }
};
