const std = @import("std");

const Allocator = std.mem.Allocator;

const storage     = @import("../private/data/storage.zig");
const enumeration = @import("../private/slabs/enum.zig");
const class       = @import("../private/slabs/class.zig");
const source      = @import("../private/slabs/source.zig");
const params      = @import("../private/slabs/parameter.zig");
const query       = @import("../private/data/query.zig");
const handle      = @import("../private/utils/handles.zig");
const hasher      = @import("../private/utils/hasher.zig");

pub const ParamDatabase = struct {
    store:   storage.ParamStorage,
    enums:   enumeration.EnumStorage("next"),
    root:    class.ClassStorage("sibling"),
    params:  params.ParameterStorage("next"),
    sources: source.SourceStorage("next"),
    lock:    std.Io.RwLock = .init,
    
    pub const empty = .{
        .store   = storage.ParamStorage.empty,
        .enums   = enumeration.EnumStorage("next").empty,
        .root    = class.ClassStorage("sibling").empty,
        .params  = params.ParameterStorage("next").empty,
        .sources = source.SourceStorage("next").empty,
    };

    pub fn init(allocator: Allocator, io: std.Io) !ParamDatabase {
        var store                    = storage.ParamStorage.empty;
        const path                   = try store.allocate(allocator, io, .createSegment(""));
        const pathString: []const u8 = @ptrCast(path.ptr);
        const enums                  = enumeration.EnumStorage("next").empty;

        const src = try store.alloc(allocator, io, .createSource(.{
            .runtime = .{
                .name = pathString,
                .data = pathString,
            },
        }));
        errdefer store.free(allocator, src.index) catch @panic("OOM");

        const root = try store.alloc(allocator, io, .createClass(.{
            .name = pathString,
            .source = handle.makeHandle(store, src.index),
            .access = .readCreate,
            .parent = null,
        }));
        errdefer store.free(allocator, root.index);

        return .{
            .store   = store,
            .enums   = enums,
            .root    = .init(handle.makeHandle(root.index)),
            .sources = .empty,
            .params  = .empty,
        };
    }

    pub fn findClassesByPattern(self: ParamDatabase, allocator: Allocator, io: std.Io, pattern: []const u8) ![]query.QueryResult {
        self.lock.lockShared(io);
        defer self.lock.unlockShared(io);

        return query.findClassesByPattern(allocator, self.storage, pattern);
    }

    pub fn findParameter(self: *ParamDatabase, io: std.Io, path: []const u8) ?*params.ParameterData {
        self.lock.lockShared(io);
        defer self.lock.unlockShared(io);
         
        return query.findParameter(self.storage, path);
    }

    pub fn findClass(self: *ParamDatabase, io: std.Io, path: []const u8) ?*class.ClassData {
        self.lock.lockShared(io);
        defer self.lock.unlockShared(io);

        return query.findParameter(self.storage, path);
    }

    pub fn getParameter(self: *ParamDatabase, io: std.Io, path: []const u8) !*const params.ParameterData {
        return self.findParameter(io, path) orelse {
            return error.ParameterNotFound;
        };
    }

    pub fn getClass(self: *ParamDatabase, io: std.Io, path: []const u8) !*const class.ClassData {
        return self.findClass(io, path) orelse {
            return error.ClassNotFound;
        };
    }

};
