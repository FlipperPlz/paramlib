const std = @import("std");
const storage = @import("storage.zig");
const slabs = @import("../slabs/slabs.zig");

pub fn TypedId() type {
    return comptime enum(u32) {
        const Self = @This();
        invalid = std.math.maxInt(u32),
        _,

        pub fn toIndex(self: Self) ?u32 {
            const val = @intFromEnum(self);
            if (val == std.math.maxInt(u32)) return null;
            return val;
        }

        pub fn fromIndex(idx: ?u32) Self {
            return if (idx) |i| @enumFromInt(i) else .invalid;
        }

        pub fn isValid(self: Self) bool {
            return self != .invalid;
        }
    };
}

pub fn idFor(comptime datatype: type) type {
    return switch (datatype) {
        slabs.ClassData => ClassId,
        slabs.ParameterData => ParameterId,
        slabs.EnumData => EnumId,
        slabs.ArrayData => ArrayId,
        slabs.SourceData => SourceId,
        []const u8 => StringId,
        else => @compileError("No identifier type for " ++ @typeName(datatype)),
    };
}

pub fn dataFor(comptime id: type) type {
    return switch (id) {
        ClassId => slabs.ClassData,
        ParameterId => slabs.ParameterData,
        EnumId => slabs.EnumData,
        ArrayId => slabs.ArrayData,
        StringId => []const u8,
        SourceId => slabs.SourceData,
        else => @compileError("No data type for " ++ @typeName(id)),
    };
}
pub const NodeId = TypedId();
pub const StringId = TypedId();
pub const ValueId = TypedId();
pub const SourceId = TypedId();
pub const ClassId = TypedId();
pub const ParameterId = TypedId();
pub const ArrayId = TypedId();
pub const EnumId = TypedId();

