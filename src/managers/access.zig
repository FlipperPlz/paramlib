const std = @import("std");
const DataStore = @import("../storage/datastores.zig").DataStore;
const ClassId = @import("../core/identifiers.zig").ClassId;
const ClassAccess = @import("../data/class.zig").ClassAccess;
const log = @import("../utils/log.zig");

pub const AccessManager = struct {
    store: *DataStore,

    pub fn init(store: *DataStore) AccessManager {
        return .{ .store = store };
    }

    pub fn canWrite(self: *const AccessManager, class_id: ClassId) bool {
        const class = self.store.getClass(class_id) orelse return false;
        const allowed = switch (class.flags.access_level) {
            .ReadWrite, .ReadCreate => true,
            .ReadOnly, .ReadOnlyVerified => false,
        };
        if (!allowed) log.debug("Access: write denied for class {}", .{class_id});
        return allowed;
    }

    pub fn canCreate(self: *const AccessManager, class_id: ClassId) bool {
        const class = self.store.getClass(class_id) orelse return false;
        const allowed = switch (class.flags.access_level) {
            .ReadWrite, .ReadCreate => true,
            .ReadOnly, .ReadOnlyVerified => false,
        };
        if (!allowed) log.debug("Access: create denied for class {}", .{class_id});
        return allowed;
    }

    pub fn setAccess(self: *AccessManager, class_id: ClassId, access: ClassAccess) !void {
        const class = self.store.getClass(class_id) orelse return error.InvalidClass;
        log.debug("Access: setAccess for class {} to {any}", .{ class_id, access });
        class.flags.access_level = access;
    }

    pub fn lock(self: *AccessManager, class_id: ClassId) !void {
        const class = self.store.getClass(class_id) orelse return error.InvalidClass;
        log.debug("Access: lock class {}", .{class_id});
        class.flags.is_locked = true;
    }

    pub fn unlock(self: *AccessManager, class_id: ClassId) !void {
        const class = self.store.getClass(class_id) orelse return error.InvalidClass;
        log.debug("Access: unlock class {}", .{class_id});
        class.flags.is_locked = false;
    }

    pub fn isLocked(self: *const AccessManager, class_id: ClassId) bool {
        const class = self.store.getClass(class_id) orelse return true;
        return class.flags.is_locked;
    }
};