const std = @import("std");

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

pub const NodeId = TypedId();
pub const StringId = TypedId();
pub const ValueId = TypedId();
pub const SourceId = TypedId();
pub const ClassId = TypedId();
pub const ParamId = TypedId();
pub const ArrayId = TypedId();
pub const EnumId = TypedId();

pub const ClassHandle = struct {
    id: ClassId,
    generation: u32,

    pub const invalid: ClassHandle = .{
        .id = .invalid,
        .generation = 0,
    };

    pub fn isValid(self: ClassHandle) bool {
        return self.id.isValid();
    }

    pub fn eql(self: ClassHandle, other: ClassHandle) bool {
        return self.id == other.id and self.generation == other.generation;
    }

    pub fn format(
        self: ClassHandle,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("ClassHandle({}, gen:{})", .{ self.id, self.generation });
    }
};