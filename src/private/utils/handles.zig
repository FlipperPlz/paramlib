const std         = @import("std");
const storage     = @import("../data/storage.zig");
const parameters  = @import("../slabs/parameter.zig");
const class       = @import("../slabs/class.zig");
const source      = @import("../slabs/source.zig");
const array       = @import("../slabs/array.zig");

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
    };
}

pub fn validateHandle(store: *const storage.ParamStorage, handle: anytype) !struct{ptr: *const anyopaque, id: @TypeOf(handle.id)} {
    if (!handle.id.isValid()) return error.InvalidHandle;

    const data_ptr = try store.retrieve(.create(handle.id));

    const IdType = @TypeOf(handle.id);
    const generation, const alive = blk: {
        if (IdType == parameters.ParameterIdentifier) {
            const d: *const parameters.ParameterData = @ptrCast(@alignCast(data_ptr));
            break :blk .{ d.generation, d.alive };
        } else if (IdType == class.ClassIdentifier) {
            const d: *const class.ClassData = @ptrCast(@alignCast(data_ptr));
            break :blk .{ d.generation, d.alive };
        } else if (IdType == source.SourceIdentifier) {
            const d: *const source.SourceData = @ptrCast(@alignCast(data_ptr));
            break :blk .{ d.generation, d.alive };
        } else if (IdType == array.ArrayIdentifier) {
            const d: *const array.ArrayData = @ptrCast(@alignCast(data_ptr));
            break :blk .{ d.generation, d.alive };
        } else {
            @compileError("validateHandle: unsupported handle id type " ++ @typeName(IdType));
        }
    };

    if (generation != handle.generation) return error.StaleHandle;
    if (!alive) return error.DeadData;

    return .{
        .ptr = data_ptr,
        .id  = handle.id,
    };
}

pub fn isValid(store: *const storage.ParamStorage, handle: anytype) bool {
    if (!handle.id.isValid()) return false;
    const result = validateHandle(store, handle) catch return false;
    _ = result;
    return true;
}

pub fn getGeneration(store: *const storage.ParamStorage, handle: anytype) ?u32 {
    const result = validateHandle(store, handle) catch return null;
    _ = result;

    return handle.generation;
}

pub fn refreshHandle(store: *const storage.ParamStorage, handle: anytype) !@TypeOf(handle) {
    _ = try validateHandle(store, handle);
    return handle;
}
