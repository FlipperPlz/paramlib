const std = @import("std");
const Allocator = std.mem.Allocator;
const DataStore = @import("../storage/datastores.zig").DataStore;
const Source = @import("../data/source.zig").Source;
const SourceId = @import("../core/identifiers.zig").SourceId;
const ClassId = @import("../core/identifiers.zig").ClassId;
const ParamId = @import("../core/identifiers.zig").ParamId;
const log = @import("../utils/log.zig");

pub const SourceManager = struct {
    store: *DataStore,
    current_source: SourceId,

    pub fn init(store: *DataStore) SourceManager {
        return .{
            .store = store,
            .current_source = .invalid,
        };
    }

    pub fn registerSource(self: *SourceManager, source: Source, allocator: Allocator) !SourceId {
        return self.store.sources.register(source, allocator);
    }

    pub fn setCurrentSource(self: *SourceManager, source_id: SourceId) void {
        self.current_source = source_id;
    }

    pub fn getCurrentSource(self: *const SourceManager) SourceId {
        return self.current_source;
    }

    pub fn getClassSource(self: *const SourceManager, class_id: ClassId) ?SourceId {
        const class = self.store.getClass(class_id) orelse {
            log.debug("getClassSource: class {} not found", .{class_id});
            return null;
        };
        log.debug("getClassSource: class {}, modified_by {}", .{ class_id, class.modified_by });
        return class.modified_by;
    }

    pub fn getParamSource(self: *const SourceManager, param_id: ParamId) ?SourceId {
        const param = self.store.getParam(param_id) orelse {
            log.debug("getParamSource: param {} not found", .{param_id});
            return null;
        };
        log.debug("getParamSource: param {}, modified_by {}", .{ param_id, param.modified_by });
        return param.modified_by;
    }

    pub fn getSourceInfo(self: *const SourceManager, source_id: SourceId) ?*const Source {
        return self.store.sources.get(source_id);
    }
};