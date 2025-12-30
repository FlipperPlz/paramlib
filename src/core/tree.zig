const std = @import("std");
const class_mod = @import("../data/class.zig");
const param_mod = @import("../data/param.zig");
const value_mod = @import("../data/value.zig");
const id_mod = @import("identifiers.zig");
const hash_mod = @import("../utils/hash.zig");
const log = @import("../utils/log.zig");
const stores_mod = @import("../storage/datastores.zig");
const source_mod = @import("../data/source.zig");
const facade_mod = @import("facade.zig");

const AccessManager = @import("../managers/access.zig").AccessManager;
const InheritanceManager = @import("../managers/inheritance.zig").InheritanceManager;
const NavigationManager = @import("../managers/navigation.zig").NavigationManager;
const SearchOptions = @import("../managers/navigation.zig").SearchOptions;
const SourceManager = @import("../managers/source.zig").SourceManager;
const ModificationManager = @import("../managers/modification.zig").ModificationManager;

const Class = facade_mod.Class;
const Allocator = std.mem.Allocator;
const ClassId = id_mod.ClassId;
const ParamId = id_mod.ParamId;
const Value = value_mod.Value;
const ClassHandle = id_mod.ClassHandle;
const DataStore = stores_mod.DataStore;
const ClassData = class_mod.ClassData;
const ParamData = param_mod.ParamData;
const Source = source_mod.Source;
const SourceId = source_mod.SourceId;

pub const ParamTree = struct {
    store: *DataStore,
    root_handle: ClassHandle,

    access: AccessManager,
    inheritance: InheritanceManager,
    navigation: NavigationManager,
    source: SourceManager,
    modification: ModificationManager,
    thread_manager: *@import("../managers/thread.zig").ThreadManager,

    mutex: std.Thread.Mutex = .{},

    pub fn init(alloc: Allocator) !*ParamTree {
        const self = try alloc.create(ParamTree);
        errdefer alloc.destroy(self);

        const store = try DataStore.init(alloc);
        errdefer store.deinit();

        const root_name = try store.internString("root");
        const root_hash = hash_mod.hashName("root");
        const path_hash = root_hash;

        const root_ = try store.allocClass();
        root_.ptr.* = ClassData.init(.invalid, root_name, root_hash, path_hash, .invalid);

        try store.path_to_class.put(alloc, path_hash, root_.id);

        const thread_manager = try alloc.create(@import("../managers/thread.zig").ThreadManager);
        thread_manager.* = @import("../managers/thread.zig").ThreadManager.init();

        self.* = .{
            .store = store,
            .root_handle = .{
                .id = root_.id,
                .generation = 1,
            },
            .access = AccessManager.init(store),
            .inheritance = InheritanceManager.init(store),
            .navigation = NavigationManager.init(store),
            .source = SourceManager.init(store),
            .modification = ModificationManager.init(store),
            .thread_manager = thread_manager,
            .mutex = .{},
        };

        return self;
    }

    pub fn deinit(self: *ParamTree) void {
        const alloc = self.allocator();
        
        self.mutex.lock();
        self.releaseInternal(self.root_handle) catch |err| {
            log.debug("Error releasing root during deinit: {}", .{err});
        };
        self.mutex.unlock();

        self.modification.deinit(alloc);
        alloc.destroy(self.thread_manager);
        self.store.deinit();
        alloc.destroy(self);
    }

    pub fn createClass(
        self: *ParamTree,
        parent_handle: ClassHandle,
        name: []const u8,
    ) !ClassHandle {
        self.mutex.lock();
        defer self.mutex.unlock();

        const parent_id = try self.validateHandleInternal(parent_handle);

        if (!self.access.canCreate(parent_id)) {
            return error.AccessDenied;
        }

        const parent = self.store.getClass(parent_id).?;
        const name_hash = hash_mod.hashName(name);

        if (self.navigation.findChildByName(parent_id, name)) |existing_id| {
            const existing = self.store.getClass(existing_id).?;
            return ClassHandle{
                .id = existing_id,
                .generation = existing.generation,
            };
        }

        const path_hash = self.computeChildPathHash(parent.path_hash, name_hash);
        const name_idx = try self.store.internString(name);

        const current_source = self.source.getCurrentSource();
        const child = try self.store.allocClass();
        child.ptr.* = ClassData.init(parent_id, name_idx, name_hash, path_hash, current_source);
        log.debug("createClass: class {} created, source {}", .{ child.id, current_source });

        child.ptr.next_sibling = parent.first_child;
        parent.first_child = child.id;

        try self.store.path_to_class.put(self.allocator(), path_hash, child.id);
        try self.modification.recordClassModification(child.id, current_source, self.allocator());

        self.thread_manager.notifyAll();

        const child_handle = ClassHandle{
            .id = child.id,
            .generation = child.ptr.generation,
        };
        try self.retainInternal(child_handle);

        return child_handle;
    }

    pub fn deleteClass(
        self: *ParamTree,
        handle: ClassHandle,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const class_id = try self.validateHandleInternal(handle);

        if (!self.access.canWrite(class_id)) {
            return error.AccessDenied;
        }

        try self.destroyClassInternal(class_id);

        self.thread_manager.notifyAll();
    }

    pub fn getClass(
        self: *ParamTree,
        handle: ClassHandle,
        name: []const u8,
    ) !?Class {
        self.mutex.lock();
        defer self.mutex.unlock();

        const class_id = try self.validateHandleInternal(handle);

        const child_id = try self.navigation.get(class_id, name);

        const child = self.store.getClass(child_id).?;
        const child_handle = ClassHandle{
            .id = child_id,
            .generation = child.generation,
        };
        try self.retainInternal(child_handle);

        return child_handle;
    }

    pub fn setParam(
        self: *ParamTree,
        handle: ClassHandle,
        name: []const u8,
        value: Value,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const class_id = try self.validateHandleInternal(handle);

        if (!self.access.canWrite(class_id)) {
            return error.AccessDenied;
        }

        const class = self.store.getClass(class_id).?;
        const name_hash = hash_mod.hashName(name);
        const current_source = self.source.getCurrentSource();
        const alloc = self.allocator();
        log.debug("setParam: class {}, param '{s}', source {}", .{ class_id, name, current_source });

        var current = class.first_param;
        while (current != .invalid) {
            const par = self.store.getParam(current).?;
            if (par.name_hash == name_hash) {
                if (Value.needsCleanup(par.value)) {
                    try self.freeValueInternal(par.value);
                }
                par.value = value;
                par.markModified(current_source);
                try self.modification.recordParamModification(current, current_source, alloc);
                try self.modification.recordClassModification(class_id, current_source, alloc);
                self.thread_manager.notifyAll();
                return;
            }
            current = par.next;
        }

        const name_idx = try self.store.internString(name);
        const param = try self.store.allocParam();
        param.ptr.* = ParamData.init(name_idx, name_hash, value, class_id, current_source);

        param.ptr.next = class.first_param;
        class.first_param = param.id;
        try self.modification.recordParamModification(param.id, current_source, alloc);
        try self.modification.recordClassModification(class_id, current_source, alloc);

        self.thread_manager.notifyAll();
    }

    pub fn getParam(
        self: *ParamTree,
        handle: ClassHandle,
        name: []const u8,
    ) !?Value {
        self.mutex.lock();
        defer self.mutex.unlock();

        const class_id = try self.validateHandleInternal(handle);
        return self.getParamInternal(class_id, name);
    }

    pub fn getParamInternal(
        self: *ParamTree,
        class_id: ClassId,
        name: []const u8,
    ) !?Value {
        const name_hash = hash_mod.hashName(name);

        if (self.inheritance.findInheritedParam(class_id, name_hash)) |result| {
            const param = self.store.getParam(result.param_id).?;
            return param.value;
        }

        return null;
    }

    pub fn findChild(
        self: *ParamTree,
        handle: ClassHandle,
        name: []const u8,
        options: SearchOptions,
    ) !?ClassHandle {
        self.mutex.lock();
        defer self.mutex.unlock();

        const class_id = try self.validateHandleInternal(handle);

        if (self.navigation.findChild(class_id, name, options)) |child_id| {
            const child = self.store.getClass(child_id).?;
            const child_handle = ClassHandle{
                .id = child_id,
                .generation = child.generation,
            };
            try self.retainInternal(child_handle);
            return child_handle;
        }

        return null;
    }

    pub fn setBase(
        self: *ParamTree,
        handle: ClassHandle,
        base_handle: ?ClassHandle,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const class_id = try self.validateHandleInternal(handle);

        if (!self.access.canWrite(class_id)) {
            return error.AccessDenied;
        }

        const class = self.store.getClass(class_id).?;

        const base_id = if (base_handle) |bh|
            try self.validateHandleInternal(bh)
        else
            ClassId.invalid;

        if (class.flags.has_base) {
            const old_base = self.store.getClass(class.base).?;
            try self.releaseInternal(.{ .id = class.base, .generation = old_base.generation });
        }

        try self.inheritance.setBase(class_id, if (base_id.isValid()) base_id else null);

        if (base_id.isValid()) {
            const new_base = self.store.getClass(base_id).?;
            try self.retainInternal(.{ .id = base_id, .generation = new_base.generation });
        }

        const current_source = self.source.getCurrentSource();
        class.markModified(current_source);
        try self.modification.recordClassModification(class_id, current_source, self.allocator());

        self.thread_manager.notifyAll();
    }

    pub fn retain(self: *ParamTree, handle: ClassHandle) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.retainInternal(handle);
    }

    fn retainInternal(self: *ParamTree, handle: ClassHandle) anyerror!void {
        const class_id = try self.validateHandleInternal(handle);
        const class = self.store.getClass(class_id).?;
        class.references += 1;
        log.debug("retain: class {} refs={}", .{ class_id, class.references });
    }

    pub fn release(self: *ParamTree, handle: ClassHandle) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.releaseInternal(handle);
    }

    fn releaseInternal(self: *ParamTree, handle: ClassHandle) anyerror!void {
        const class_id = try self.validateHandleInternal(handle);
        const class = self.store.getClass(class_id).?;

        if (class.references == 0) return error.InvalidRefCount;

        class.references -= 1;
        log.debug("release: class {} refs={}", .{ class_id, class.references });
        if (class.references == 0) {
            try self.destroyClassInternal(class_id);
        }
    }

    fn destroyClassInternal(self: *ParamTree, class_id: ClassId) !void {
        const class = self.store.getClass(class_id).?;
        log.debug("destroyClassInternal: class {}", .{class_id});

        var child_id = class.first_child;
        while (child_id.isValid()) {
            const child = self.store.getClass(child_id).?;
            const next = child.next_sibling;
            try self.releaseInternal(.{ .id = child_id, .generation = child.generation });
            child_id = next;
        }

        if (class.flags.has_base) {
            const base_class = self.store.getClass(class.base).?;
            try self.releaseInternal(.{ .id = class.base, .generation = base_class.generation });
        }

        class.flags.is_alive = false;
        class.generation +%= 1;

        var param_id = class.first_param;
        while (param_id.isValid()) {
            const param = self.store.getParam(param_id).?;
            const next = param.next;

            if (param.value.needsCleanup()) {
                try self.freeValueInternal(param.value);
            }
            try self.store.freeParam(param_id);

            param_id = next;
        }

        _ = self.store.path_to_class.remove(class.path_hash);
        try self.store.freeClass(class_id);
    }

    fn freeValueInternal(self: *ParamTree, value: Value) !void {
        if (value.tag == .array) {
            try self.store.freeArray(value.data.array);
        }
    }

    fn computeChildPathHash(self: *ParamTree, parent_path_hash: u64, name_hash: u64) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(parent_path_hash);
        hasher.update(std.mem.asBytes(&name_hash));
        return hasher.final();
    }

    pub fn validateHandle(self: *ParamTree, handle: ClassHandle) !ClassId {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.validateHandleInternal(handle);
    }

    pub fn validateHandleInternal(self: *ParamTree, handle: ClassHandle) !ClassId {
        if (!handle.id.isValid()) return error.InvalidHandle;

        const class = self.store.getClass(handle.id) orelse return error.InvalidHandle;

        if (class.generation != handle.generation) return error.StaleHandle;
        if (!class.flags.is_alive) return error.DeadClass;

        return handle.id;
    }

    pub inline fn root(self: *ParamTree) ClassHandle {
        return self.root_handle;
    }

    pub inline fn facade(self: *ParamTree) Class {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.retainInternal(self.root_handle) catch {};
        return Class.init(self, self.root_handle);
    }

    inline fn allocator(self: ParamTree) Allocator {
        return self.store.allocator;
    }
};