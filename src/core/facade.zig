
const std = @import("std");
const ParamTree = @import("../core/tree.zig").ParamTree;
const Parser = @import("../parse/parser.zig").Parser;
const ClassHandle = @import("../core/identifiers.zig").ClassHandle;
const ClassId = @import("../core/identifiers.zig").ClassId;
const SearchOptions = @import("../managers/navigation.zig").SearchOptions;
const Value = @import("../data/value.zig").Value;
const SourceId = @import("../core/identifiers.zig").SourceId;
const log = @import("../utils/log.zig");

pub const Class = struct {
    tree: *ParamTree,
    handle: ClassHandle,

    pub fn init(tree: *ParamTree, handle: ClassHandle) Class {
        log.debug("Facade: Class.init handle={}", .{handle});
        return .{ .tree = tree, .handle = handle };
    }

    pub fn fromId(tree: *ParamTree, id: ClassId) ?Class {
        const class_data = tree.store.getClass(id) orelse return null;
        return Class{
            .tree = tree,
            .handle = .{
                .id = id,
                .generation = class_data.generation,
            },
        };
    }

    pub fn createChild(self: Class, name: []const u8) !Class {
        log.debug("Facade: createChild '{s}' for class {}", .{ name, self.handle });
        const child_handle = try self.tree.createClass(self.handle, name);
        return Class.init(self.tree, child_handle);
    }

    pub fn findChild(self: Class, name: []const u8, options: SearchOptions) !?Class {
        log.debug("Facade: findChild '{s}' for class {} options={any}", .{ name, self.handle, options });
        const child_handle = try self.tree.findChild(self.handle, name, options) orelse return null;
        return Class.init(self.tree, child_handle);
    }

    pub fn getOrCreateChild(self: Class, name: []const u8) !Class {
        if (try self.findChild(name, .{})) |child| {
            return child;
        }
        return self.createChild(name);
    }

    pub fn waitForChild(self: Class, name: []const u8, parser: ?*Parser, options: SearchOptions) !?Class {
        self.tree.mutex.lock();
        defer self.tree.mutex.unlock();

        while (true) {
            const class_id = try self.tree.validateHandleInternal(self.handle);
            if (self.tree.navigation.findChild(class_id, name, options)) |child_id| {
                const child = self.tree.store.getClass(child_id).?;
                return Class.init(self.tree, .{
                    .id = child_id,
                    .generation = child.generation,
                });
            }

            if (parser) |p| {
                if (!p.hasActiveParsers()) {
                    return null;
                }
            }

            self.tree.thread_manager.wait(&self.tree.mutex);
        }
    }

    pub fn setI32(self: Class, name: []const u8, value: i32) !void {
        log.debug("Facade: setI32 '{s}' = {} for class {}", .{ name, value, self.handle });
        try self.tree.setParam(self.handle, name, Value.initI32(value));
    }

    pub fn setI64(self: Class, name: []const u8, value: i64) !void {
        try self.tree.setParam(self.handle, name, Value.initI64(value));
    }

    pub fn setF32(self: Class, name: []const u8, value: f32) !void {
        try self.tree.setParam(self.handle, name, Value.initF32(value));
    }

    pub fn setF64(self: Class, name: []const u8, value: f64) !void {
        try self.tree.setParam(self.handle, name, Value.initF64(value));
    }

    pub fn setString(self: Class, name: []const u8, value: []const u8) !void {
        const str_idx = try self.tree.store.internString(value);
        try self.tree.setParam(self.handle, name, Value.initString(str_idx));
    }

    pub fn setValue(self: Class, name: []const u8, value: Value) !void {
        try self.tree.setParam(self.handle, name, value);
    }

    pub fn get(self: Class, name: []const u8) !?Value {
        return self.tree.getParam(self.handle, name);
    }

    pub fn getI32(self: Class, name: []const u8) !?i32 {
        log.debug("Facade: getI32 '{s}' for class {}", .{ name, self.handle });
        const val = try self.get(name) orelse return null;
        if(val.tag == .i32 ) {
            return val.data.i32;
        }
        return null;
    }

    pub fn getI64(self: Class, name: []const u8) !?i64 {
        const val = try self.get(name) orelse return null;
        if(val.tag == .i64 ) {
            return val.data.i64;
        }
        return null;
    }

    pub fn getF32(self: Class, name: []const u8) !?f32 {
        const val = try self.get(name) orelse return null;
        if(val.tag == .f32 ) {
            return val.data.f32;
        }
        return null;
    }

    pub fn getF64(self: Class, name: []const u8) !?f64 {
        const val = try self.get(name) orelse return null;
        if(val.tag == .f64 ) {
            return val.data.f64;
        }
        return null;
    }

    pub fn getString(self: Class, name: []const u8) !?[]const u8 {
        const val = try self.get(name) orelse return null;
        if (val.tag != .string) return null;
        return self.tree.store.getString(val.data.string);
    }

    pub fn getI32OrDefault(self: Class, name: []const u8, default: i32) !i32 {
        return (try self.getI32(name)) orelse default;
    }

    pub fn getF32OrDefault(self: Class, name: []const u8, default: f32) !f32 {
        return (try self.getF32(name)) orelse default;
    }

    pub fn has(self: Class, name: []const u8) !bool {
        return (try self.get(name)) != null;
    }

    pub fn setBase(self: Class, base: ?Class) !void {
        const base_handle = if (base) |b| b.handle else null;

        try self.tree.setBase(self.handle, base_handle);
    }

    pub fn getBase(self: Class) !?Class {
        const class_id = try self.getId();
        const base_id = self.tree.inheritance.getBase(class_id) orelse return null;
        const base = self.tree.store.getClass(base_id) orelse return null;
        return Class.init(self.tree, .{
            .id = base_id,
            .generation = base.generation,
        });
    }

    pub fn waitForBase(self: Class) !Class {
        self.tree.mutex.lock();
        defer self.tree.mutex.unlock();

        while (true) {
            const class_id = try self.tree.validateHandleInternal(self.handle);
            if (self.tree.inheritance.getBase(class_id)) |base_id| {
                const base = self.tree.store.getClass(base_id).?;
                return Class.init(self.tree, .{
                    .id = base_id,
                    .generation = base.generation,
                });
            }
            self.tree.thread_manager.wait(&self.tree.mutex);
        }
    }

    pub fn waitForParam(self: Class, name: []const u8) !Value {
        self.tree.mutex.lock();
        defer self.tree.mutex.unlock();

        while (true) {
            const class_id = try self.tree.validateHandleInternal(self.handle);
            if (try self.tree.getParamInternal(class_id, name)) |val| {
                return val;
            }
            self.tree.thread_manager.wait(&self.tree.mutex);
        }
    }

    pub fn getInheritanceChain(self: Class, allocator: std.mem.Allocator) !std.ArrayList(Class) {
        const class_id = try self.getId();
        const chain_ids = try self.tree.inheritance.getInheritanceChain(class_id, allocator);
        defer chain_ids.deinit(allocator);

        var chain = std.ArrayList(Class).empty;
        errdefer chain.deinit(allocator);

        for (chain_ids.items) |id| {
            if (Class.fromId(self.tree, id)) |cls| {
                try chain.append(allocator, cls);
            }
        }

        return chain;
    }

    pub fn lock(self: Class) !void {
        try self.tree.access.lock(try self.getId());
    }

    pub fn unlock(self: Class) !void {
        try self.tree.access.unlock(try self.getId());
    }

    pub fn isLocked(self: Class) !bool {
        return self.tree.access.isLocked(try self.getId());
    }

    pub fn canWrite(self: Class) !bool {
        return self.tree.access.canWrite(try self.getId());
    }

    pub fn canCreate(self: Class) !bool {
        return self.tree.access.canCreate(try self.getId());
    }

    pub fn setAccess(self: Class, access: @import("../data/class.zig").ClassAccess) !void {
        try self.tree.access.setAccess(try self.getId(), access);
    }

    pub fn getSource(self: Class) !SourceId {
        return self.tree.source.getClassSource(try self.getId()) orelse .invalid;
    }

    pub fn getSourceName(self: Class) !?[]const u8 {
        const source_id = try self.getSource();
        const source = self.tree.source.getSourceInfo(source_id) orelse return null;
        return source.name;
    }

    pub fn getCreatedAt(self: Class) !i64 {
        const class_id = try self.getId();
        const class_data = self.tree.store.getClass(class_id) orelse return error.InvalidClass;
        return class_data.created_at;
    }

    pub fn getModifiedAt(self: Class) !i64 {
        const class_id = try self.getId();
        const class_data = self.tree.store.getClass(class_id) orelse return error.InvalidClass;
        return class_data.modified_at;
    }

    pub fn getParent(self: Class) !?Class {
        const class_id = try self.getId();
        const parent_id = self.tree.navigation.getParent(class_id) orelse return null;
        return Class.fromId(self.tree, parent_id);
    }

    pub fn getParentChain(self: Class, allocator: std.mem.Allocator) !std.ArrayList(Class) {
        const class_id = try self.getId();
        var chain_ids = try self.tree.navigation.getParentChain(class_id, allocator);
        defer chain_ids.deinit(allocator);

        var chain = std.ArrayList(Class).empty;
        errdefer chain.deinit(allocator);

        for (chain_ids.items) |id| {
            if (Class.fromId(self.tree, id)) |cls| {
                try chain.append(allocator, cls);
            }
        }

        return chain;
    }

    pub fn getChildren(self: Class, allocator: std.mem.Allocator) !std.ArrayList(Class) {
        const class_id = try self.getId();
        var child_ids = try self.tree.navigation.getChildren(class_id, allocator);
        defer child_ids.deinit(allocator);

        var children = std.ArrayList(Class).empty;
        errdefer children.deinit(allocator);

        for (child_ids.items) |child_id| {
            if (Class.fromId(self.tree, child_id)) |child| {
                try children.append(allocator, child);
            }
        }

        return children;
    }

    pub fn getPath(self: Class, allocator: std.mem.Allocator) ![]const u8 {
        return self.tree.navigation.getPath(try self.getId(), allocator);
    }

    pub fn getName(self: Class) ![]const u8 {
        const class_id = try self.getId();
        const class_data = self.tree.store.getClass(class_id) orelse return error.InvalidClass;
        return self.tree.store.getString(class_data.name_index);
    }

    pub fn retain(self: Class) !void {
        try self.tree.retain(self.handle);
    }

    pub fn release(self: Class) !void {
        try self.tree.release(self.handle);
    }

    pub fn getRefCount(self: Class) !u32 {
        const class_id = try self.getId();
        const class_data = self.tree.store.getClass(class_id) orelse return error.InvalidClass;
        return class_data.references;
    }

    pub fn isValid(self: Class) bool {
        return self.handle.isValid() and
            self.tree.store.getClass(self.handle.id) != null;
    }

    pub fn getHandle(self: Class) ClassHandle {
        return self.handle;
    }

    pub fn getId(self: Class) !ClassId {
        return self.tree.validateHandle(self.handle);
    }

    pub fn eql(self: Class, other: Class) bool {
        return self.handle.eql(other.handle);
    }

    pub fn sameClass(self: Class, other: Class) bool {
        return self.handle.id == other.handle.id;
    }

    pub fn format(
        self: Class,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        const name = self.getName() catch "<?>";
        try writer.print("Class({s}, {})", .{ name, self.handle });
    }

    pub fn setMany(self: Class, params: []const struct { name: []const u8, value: Value }) !void {
        for (params) |param| {
            try self.tree.setParam(self.handle, param.name, param.value);
        }
    }

    pub fn copyParamsFrom(self: Class, other: Class, allocator: std.mem.Allocator) !void {
        const other_id = try other.getId();
        const other_data = self.tree.store.getClass(other_id) orelse return error.InvalidClass;

        var param_id = other_data.first_param;
        while (param_id.isValid()) {
            const param = self.tree.store.getParam(param_id) orelse break;
            const name = self.tree.store.getString(param.name_idx);

            const value_copy = try self.cloneValue(param.value, allocator);
            try self.tree.setParam(self.handle, name, value_copy);

            param_id = param.next;
        }
    }

    fn cloneValue(self: Class, value: Value, allocator: std.mem.Allocator) !Value {
        if (value.tag == .array) {
            const src_array = self.tree.store.getArray(value.data.array);
            const new_idx = try self.tree.store.allocArray();
            const new_array = self.tree.store.getArray(new_idx);

            for (src_array.values.items) |elem| {
                try new_array.append(try self.cloneValue(elem, allocator), allocator);
            }

            return Value.initArray(new_idx);
        }

        return value;
    }
};