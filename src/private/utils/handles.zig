const std     = @import("std");
const storage = @import("../data/storage.zig");

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

    const DataType = struct {
        generation: u32,
        _padding1 : [4]u8 align(1) = undefined,
        alive: bool,
    };
    const data: *const DataType = @ptrCast(@alignCast(data_ptr));

    if (data.generation != handle.generation) return error.StaleHandle;
    if (!data.alive) return error.DeadData;

    return .{
        .ptr = data_ptr,
        .id = handle.id
    };
}

pub fn isValid(store: *const storage.ParamStorage, handle: type) bool {
    if (!handle.id.isValid()) return false;

    const data = try store.retrieve(handle.id) orelse return false;

    if (data.generation != handle.generation) return false;
    if (!data.alive) return false;

    return true;
}

pub fn getGeneration(store: *const storage.ParamStorage, comptime handle: type) ?u32 {
    const data = try store.retrieve(handle.id) orelse return null;
    return data.generation;
}


fn HandleType(comptime identifier: storage.StorageIdentifier) type {
    return Handle(@TypeOf(switch (identifier) {
        inline else => |v| v,
    }));
}

pub fn makeHandle(store: *const storage.ParamStorage, comptime identifier: storage.StorageIdentifier) !HandleType(identifier) {
    const data = try store.retrieve(identifier);

    const id = switch (identifier) {
        inline else => |id| Handle(@TypeOf(id)) {.id = id, .generation = data.generation},
    };

    return .{ .id = id, .generation = data.generation };

}

pub fn refreshHandle(store: *const storage.ParamStorage, comptime handle: type) !handle {
    const data = store.retrieve(handle.id) orelse return error.InvalidHandle;
    if (!data.alive) return error.DeadData;

    return @TypeOf(handle) {
        .id = handle.id,
        .generation = data.generation,
    };
}

pub fn eql(a: type, b: type) bool {
    return a.id == b.id;
}
