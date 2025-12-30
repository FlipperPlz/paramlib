const std = @import("std");
const DataStore = @import("../storage/datastores.zig").DataStore;
const ClassId = @import("../core/identifiers.zig").ClassId;
const log = @import("../utils/log.zig");

pub const SearchOptions = struct {
    look_in_parent: bool = false,
    look_in_base: bool = false,
};

pub const NavigationManager = struct {
    store: *DataStore,

    pub fn init(store: *DataStore) NavigationManager {
        return .{ .store = store };
    }

    pub fn getParent(self: *const NavigationManager, class_id: ClassId) ?ClassId {
        const class = self.store.getClass(class_id) orelse return null;
        const parent = if (class.parent.isValid()) class.parent else null;
        log.debug("Navigation: getParent of {} is {any}", .{ class_id, parent });
        return parent;
    }

    pub fn getChildren(
        self: *const NavigationManager,
        class_id: ClassId,
        allocator: std.mem.Allocator,
    ) !std.ArrayList(ClassId) {
        var children = std.ArrayList(ClassId).empty;
        errdefer children.deinit(allocator);

        const class = self.store.getClass(class_id) orelse return children;

        var current = class.first_child;
        while (current.isValid()) {
            try children.append(allocator, current);
            const child = self.store.getClass(current) orelse break;
            current = child.next_sibling;
        }

        return children;
    }

    pub fn findChild(
        self: *const NavigationManager,
        class_id: ClassId,
        name: []const u8,
        options: SearchOptions,
    ) ?ClassId {
        const name_hash = computeNameHash(name);
        return self.findChildByHash(class_id, name_hash, options);
    }

    pub fn findChildByHash(
        self: *const NavigationManager,
        class_id: ClassId,
        name_hash: u64,
        options: SearchOptions,
    ) ?ClassId {
        var current = class_id;
        while (current.isValid()) {
            if (self.findImmediateChildByHash(current, name_hash)) |found| return found;
            if (!options.look_in_parent) break;
            const class = self.store.getClass(current) orelse break;
            current = class.parent;
        }

        if (options.look_in_base) {
            current = class_id;
            while (current.isValid()) {
                const class = self.store.getClass(current) orelse break;
                
                if (class.flags.has_base) {
                    var current_base = class.base;
                    while (current_base.isValid()) {
                        if (self.findImmediateChildByHash(current_base, name_hash)) |found| return found;
                        
                        const base_class = self.store.getClass(current_base) orelse break;
                        if (!base_class.flags.has_base) break;
                        current_base = base_class.base;
                    }
                }

                if (!options.look_in_parent) break;
                current = class.parent;
            }
        }

        return null;
    }

    fn findImmediateChildByHash(
        self: *const NavigationManager,
        parent_id: ClassId,
        name_hash: u64,
    ) ?ClassId {
        const parent = self.store.getClass(parent_id) orelse return null;

        var current = parent.first_child;
        while (current.isValid()) {
            const child = self.store.getClass(current) orelse break;
            if (child.name_hash == name_hash) {
                return current;
            }
            current = child.next_sibling;
        }

        return null;
    }

    pub fn findChildByName(
        self: *const NavigationManager,
        parent_id: ClassId,
        name: []const u8,
    ) ?ClassId {
        return self.findChild(parent_id, name, .{});
    }

    pub fn getParentChain(
        self: *const NavigationManager,
        class_id: ClassId,
        allocator: std.mem.Allocator,
    ) !std.ArrayList(ClassId) {
        var chain = std.ArrayList(ClassId).empty;
        errdefer chain.deinit(allocator);

        var current = class_id;
        while (current.isValid()) {
            try chain.append(allocator, current);
            const class = self.store.getClass(current) orelse break;
            current = class.parent;
        }

        return chain;
    }

    pub fn getPath(
        self: *const NavigationManager,
        class_id: ClassId,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        var path_parts = std.ArrayList([]const u8).empty;
        defer path_parts.deinit(allocator);

        var current = class_id;
        while (current.isValid()) {
            const class = self.store.getClass(current) orelse break;
            const name = self.store.getString(class.name_index);
            try path_parts.insert(allocator, 0, name);
            current = class.parent;
        }

        return std.mem.join(allocator, ".", path_parts.items);
    }

    inline fn computeNameHash(name: []const u8) u64 {
        return std.hash.Wyhash.hash(0, name);
    }
};