const std = @import("std");
const time_mod = @import("../utils/time.zig");
const log = @import("../utils/log.zig");

const DataStore = @import("../storage/datastores.zig").DataStore;
const ClassId = @import("../core/identifiers.zig").ClassId;
const ParamId = @import("../core/identifiers.zig").ParamId;
const SourceId = @import("../core/identifiers.zig").SourceId;

pub const ModificationRecord = struct {
    target_type: enum { Class, Param },
    target_id: union(enum) {
        class: ClassId,
        param: ParamId,
    },
    source_id: SourceId,
    timestamp: i64,
};

pub const ModificationManager = struct {
    store: *DataStore,
    history: std.ArrayList(ModificationRecord),

    pub fn init(store: *DataStore) ModificationManager {
        return .{
            .store = store,
            .history = std.ArrayList(ModificationRecord).empty,
        };
    }

    pub fn deinit(self: *ModificationManager, allocator: std.mem.Allocator) void {
        self.history.deinit(allocator);
    }

    pub fn recordClassModification(
        self: *ModificationManager,
        class_id: ClassId,
        source_id: SourceId,
        allocator: std.mem.Allocator
    ) !void {
        const class = self.store.getClass(class_id) orelse return error.InvalidClass;
        log.debug("recordClassModification: class {} mod by {}", .{ class_id, source_id });
        class.markModified(source_id, self.store.io);

        try self.history.append(allocator, .{
            .target_type = .Class,
            .target_id = .{ .class = class_id },
            .source_id = source_id,
            .timestamp = time_mod.getTimeMs(self.store.io),
        });
    }

    pub fn recordParamModification(
        self: *ModificationManager,
        param_id: ParamId,
        source_id: SourceId,
        allocator: std.mem.Allocator
    ) !void {
        const param = self.store.getParam(param_id) orelse return error.InvalidParam;
        log.debug("recordParamModification: param {} mod by {}", .{ param_id, source_id });
        param.markModified(source_id, self.store.io);

        try self.history.append(allocator, .{
            .target_type = .Param,
            .target_id = .{ .param = param_id },
            .source_id = source_id,
            .timestamp = time_mod.getTimeMs(self.store.io),
        });
    }

    pub fn getModificationHistory(
        self: *const ModificationManager,
    ) []const ModificationRecord {
        return self.history.items;
    }

    pub fn clearHistory(self: *ModificationManager) void {
        self.history.clearRetainingCapacity();
    }
};