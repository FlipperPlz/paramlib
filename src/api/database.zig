const std = @import("std");

const Allocator = std.mem.Allocator;

const storage     = @import("../private/data/storage.zig");
const enumeration = @import("../private/slabs/enum.zig");
const class       = @import("../private/slabs/class.zig");
const source      = @import("../private/slabs/source.zig");
const params      = @import("../private/slabs/parameter.zig");
const query       = @import("../private/tree/query.zig");
const handle      = @import("../private/utils/handles.zig");
const hasher      = @import("../private/utils/hasher.zig");
const factory     = @import("../private/tree/factory.zig");

pub const ParamDatabase = struct {
    store:   storage.ParamStorage,
    enums:   enumeration.EnumStorage("next"),
    params:  params.ParameterStorage("next"),
    sources: source.SourceStorage("next"),
    runtime: source.SourceHandle,
    lock:    std.Io.RwLock = .init,

    pub fn init(allocator: Allocator, io: std.Io) !ParamDatabase {
        var store                    = storage.ParamStorage.empty;
        const path                   = try store.alloc(allocator, io, .createSegment(""));
        const path_str_ptr: *const []const u8 = @ptrCast(@alignCast(path.ptr));
        const pathString: []const u8 = path_str_ptr.*;
        const enums                  = enumeration.EnumStorage("next").empty;

        const src = try store.alloc(allocator, io, .createSource(.{
            .runtime = .{
                .name = pathString,
                .data = pathString,
            },
        }));
        errdefer store.free(allocator, src.index) catch @panic("OOM");

        const src_data: *const source.SourceData = @ptrCast(@alignCast(src.ptr));
        const sourceHandle = handle.Handle(source.SourceIdentifier) {
            .id = src.index.src,
            .generation = src_data.generation,
        };

        const sources = source.SourceStorage("next").init(sourceHandle);

        return .{
            .store   = store,
            .enums   = enums,
            .runtime = sourceHandle,
            .sources = sources,
            .params  = .empty,
        };
    }

    pub fn deinit(self: *ParamDatabase, allocator: Allocator, io: std.Io) void {
        _ = io;
        self.store.deinit(allocator);
    }

    pub fn findClassesByPattern(self: *const ParamDatabase, allocator: Allocator, io: std.Io, pattern: []const u8) ![]query.QueryResult {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);

        return query.findClassesByPattern(allocator, &self.store, &self.store.root, pattern);
    }

    pub fn lookupParameter(self: *ParamDatabase, io: std.Io, path: []const u8) ?*params.ParameterData {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);

        return query.lookupParameter(&self.store, path);
    }

    pub fn lookupClass(self: *ParamDatabase, io: std.Io, path: []const u8) ?*class.ClassData {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);

        return query.lookupClass(&self.store, path);
    }

    fn lookupClassUnlocked(self: *ParamDatabase, path: []const u8) ?*class.ClassData {
        return query.lookupClass(&self.store, path);
    }

    pub fn getParameterLookup(self: *ParamDatabase, io: std.Io, path: []const u8) !*params.ParameterData {
        return self.lookupParameter(io, path) orelse {
            return error.ParameterNotFound;
        };
    }

    pub fn getClassLookup(self: *ParamDatabase, io: std.Io, path: []const u8) !*class.ClassData {
        return self.lookupClass(io, path) orelse {
            return error.ClassNotFound;
        };
    }

    pub fn deleteClass(self: *ParamDatabase, allocator: Allocator, io: std.Io, clazz: *class.ClassData) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        try factory.deleteClass(allocator, &self.store, clazz.createHandle(self.store));
    }

    pub fn deleteParameter(self: *ParamDatabase, allocator: Allocator, io: std.Io, param: *params.ParameterData) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        try factory.deleteParameter(allocator, &self.store, param.createHandle(self.store));
    }

    pub fn createClass(self: *ParamDatabase, allocator: Allocator, io: std.Io, parentPath: ?[]const u8, args: class.ClassInit) !*class.ClassData {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        if(parentPath) |path| {
            const parentData: *class.ClassData = (self.lookupClassUnlocked(path) orelse return error.InvalidParent);
            args.parent = parentData.createHandle(self.store);
        }
        return factory.createClass(allocator, io, self.store, args);
    }
};
