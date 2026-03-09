const std = @import("std");
const Allocator = std.mem.Allocator;

const identifiers = @import("identifiers.zig");
const slabs = @import("../slabs/slabs.zig");
const storage = @import("../data/storage.zig");

pub const ClassHandle = Handle(identifiers.ClassId);
pub const ParameterHandle = Handle(identifiers.ParameterId);
pub const ArrayHandle = Handle(identifiers.ArrayId);
pub const EnumHandle = Handle(identifiers.EnumId);

pub fn Handle(comptime Id: type) type {
    return struct {
        const Self = @This();

        id: Id,
        generation: u32,

        pub const invalid: Self = .{ .id = .invalid, .generation = 0 };

        pub fn isValid(self: Self) bool {
            return self.id.isValid();
        }

        pub fn eql(self: Self, other: Self) bool {
            return self.id == other.id and self.generation == other.generation;
        }

        pub fn format(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            try writer.print("{s}({}, generation:{})", .{ @typeName(Id), self.id, self.generation });
        }
    };
}

pub fn validateHandle(store: *const storage.ParamStorage, handle: type) !@TypeOf(handle.id) {
    if (!handle.id.isValid()) return error.InvalidHandle;

    const data = store.retrieve(.create(handle.id)) orelse return error.InvalidHandle;

    if (data.generation != handle.generation) return error.StaleHandle;
    if (!data.alive) return error.DeadData;

    return handle.id;
}

pub fn isValid(store: *const storage.ParamStorage, handle: type) bool {
    if (!handle.id.isValid()) return false;

    const data: identifiers.dataFor(handle.id) = store.retrieve(handle.id) orelse return false;

    if (data.generation != handle.generation) return false;
    if (!data.alive) return false;

    return true;
}

pub fn getGeneration(store: *const storage.ParamStorage, comptime handle: type) ?u32 {
    const data: identifiers.dataFor(handle.id) = store.retrieve(handle.id) orelse return null;
    return data.generation;
}

pub fn makeHandle(store: *const storage.ParamStorage, comptime id: type) !Handle(id) {
    const data: identifiers.dataFor(id) = store.retrieve(.create(id));

    return Handle(id) {
        .id = id,
        .generation = data.generation
    };
}

pub fn refreshHandle(store: *const storage.ParamStorage, comptime handle: type) !handle {
    const data: identifiers.dataFor(handle.id) = store.retrieve(handle.id) orelse return error.InvalidHandle;
    if (!data.alive) return error.DeadData;

    return ClassHandle{
        .id = handle.id,
        .generation = data.generation,
    };
}

pub fn eql(a: type, b: type ) bool {
    return a.id == b.id;
}