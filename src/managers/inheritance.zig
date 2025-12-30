const std = @import("std");
const DataStore = @import("../storage/datastores.zig").DataStore;
const ClassId = @import("../core/identifiers.zig").ClassId;
const ParamId = @import("../core/identifiers.zig").ParamId;
const Value = @import("../data/value.zig").Value;
const log = @import("../utils/log.zig");

pub const InheritanceManager = struct {
    store: *DataStore,

    pub fn init(store: *DataStore) InheritanceManager {
        return .{ .store = store };
    }

    pub fn setBase(self: *InheritanceManager, class_id: ClassId, base_id: ?ClassId) !void {
        const class = self.store.getClass(class_id) orelse return error.InvalidClass;

        const actual_base = base_id orelse ClassId.invalid;
        log.debug("Inheritance: setBase for class {} to base {}", .{ class_id, actual_base });

        if (actual_base.isValid()) {
            try self.checkCircularInheritance(class_id, actual_base);
        }

        class.base = actual_base;
        class.flags.has_base = actual_base.isValid();
    }

    pub fn getBase(self: *const InheritanceManager, class_id: ClassId) ?ClassId {
        const class = self.store.getClass(class_id) orelse return null;
        if (!class.flags.has_base) return null;
        return class.base;
    }

    pub fn getInheritanceChain(
        self: *const InheritanceManager,
        class_id: ClassId,
        allocator: std.mem.Allocator,
    ) !std.ArrayList(ClassId) {
        var chain = std.ArrayList(ClassId).empty;
        errdefer chain.deinit(allocator);

        var current = class_id;
        var depth: u32 = 0;
        const max_depth = 100;

        while (current.isValid() and depth < max_depth) : (depth += 1) {
            try chain.append(allocator, current);
            const class = self.store.getClass(current) orelse break;
            if (!class.flags.has_base) break;
            current = class.base;
        }

        return chain;
    }

    pub fn findInheritedParam(
        self: *const InheritanceManager,
        class_id: ClassId,
        name_hash: u64,
    ) ?struct { param_id: ParamId, source_class: ClassId } {
        var current = class_id;
        log.debug("Inheritance: findInheritedParam name_hash={} starting at class {}", .{ name_hash, class_id });

        while (current.isValid()) {
            const class = self.store.getClass(current) orelse return null;

            var param_id = class.first_param;
            while (param_id.isValid()) {
                const param = self.store.getParam(param_id) orelse break;
                if (param.name_hash == name_hash) {
                    log.debug("Inheritance: found param {} in class {}", .{ param_id, current });
                    return .{ .param_id = param_id, .source_class = current };
                }
                param_id = param.next;
            }

            if (!class.flags.has_base) break;
            current = class.base;
        }

        return null;
    }

    fn checkCircularInheritance(
        self: *const InheritanceManager,
        class_id: ClassId,
        base_id: ClassId,
    ) !void {
        if (class_id == base_id) return error.CircularInheritance;

        var current = base_id;
        var depth: u32 = 0;
        const max_depth = 100;

        while (current.isValid() and depth < max_depth) : (depth += 1) {
            if (current == class_id) return error.CircularInheritance;
            const class = self.store.getClass(current) orelse break;
            if (!class.flags.has_base) break;
            current = class.base;
        }

        if (depth >= max_depth) return error.InheritanceTooDeep;
    }
};