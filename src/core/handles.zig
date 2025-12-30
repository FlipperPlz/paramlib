const std = @import("std");
const ClassId = @import("identifiers.zig").ClassId;
const ParamId = @import("identifiers.zig").ParamId;
const ClassHandle = @import("identifiers.zig").ClassHandle;
const ClassData = @import("../data/class.zig").ClassData;
const ParamData = @import("../data/param.zig").ParamData;
const DataStore = @import("../storage/datastores.zig").DataStore;

pub const HandleValidator = struct {
    store: *DataStore,

    pub fn init(store: *DataStore) HandleValidator {
        return .{ .store = store };
    }

    pub fn validateClass(self: *const HandleValidator, handle: ClassHandle) !ClassId {
        if (!handle.id.isValid()) return error.InvalidHandle;

        const class = self.store.getClass(handle.id) orelse return error.InvalidHandle;

        if (class.generation != handle.generation) return error.StaleHandle;
        if (!class.flags.is_alive) return error.DeadClass;

        return handle.id;
    }

    pub fn isValid(self: *const HandleValidator, handle: ClassHandle) bool {
        if (!handle.id.isValid()) return false;

        const class = self.store.getClass(handle.id) orelse return false;

        if (class.generation != handle.generation) return false;
        if (!class.flags.is_alive) return false;

        return true;
    }

    pub fn getGeneration(self: *const HandleValidator, id: ClassId) ?u32 {
        const class = self.store.getClass(id) orelse return null;
        return class.generation;
    }

    pub fn makeHandle(self: *const HandleValidator, id: ClassId) ?ClassHandle {
        const class = self.store.getClass(id) orelse return null;
        return ClassHandle{
            .id = id,
            .generation = class.generation,
        };
    }

    pub fn refreshHandle(self: *const HandleValidator, handle: ClassHandle) !ClassHandle {
        const class = self.store.getClass(handle.id) orelse return error.InvalidHandle;
        if (!class.flags.is_alive) return error.DeadClass;

        return ClassHandle{
            .id = handle.id,
            .generation = class.generation,
        };
    }

    pub fn validateParam(self: *const HandleValidator, param_id: ParamId) !*ParamData {
        if (!param_id.isValid()) return error.InvalidParam;
        return self.store.getParam(param_id) orelse error.InvalidParam;
    }

    pub fn isSameClass(self: *const HandleValidator, a: ClassHandle, b: ClassHandle) bool {
        _ = self;
        return a.id == b.id;
    }
};

pub const HandleBatch = struct {
    handles: std.ArrayList(ClassHandle),
    validator: HandleValidator,

    pub fn init(allocator: std.mem.Allocator, store: *DataStore) HandleBatch {
        return .{
            .handles = std.ArrayList(ClassHandle).init(allocator),
            .validator = HandleValidator.init(store),
        };
    }

    pub fn deinit(self: *HandleBatch) void {
        self.handles.deinit();
    }

    pub fn add(self: *HandleBatch, handle: ClassHandle) !void {
        try self.handles.append(handle);
    }

    pub fn validateAll(self: *HandleBatch) !std.ArrayList(ClassId) {
        var ids = std.ArrayList(ClassId).init(self.handles.allocator);
        errdefer ids.deinit();

        for (self.handles.items) |handle| {
            const id = try self.validator.validateClass(handle);
            try ids.append(id);
        }

        return ids;
    }

    pub fn refreshAll(self: *HandleBatch) !void {
        for (self.handles.items, 0..) |handle, i| {
            self.handles.items[i] = try self.validator.refreshHandle(handle);
        }
    }

    pub fn clear(self: *HandleBatch) void {
        self.handles.clearRetainingCapacity();
    }
};