const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../private/data/storage.zig");
const handles = @import("../private/data/handles.zig");
const sources = @import("../private/slabs/source.zig");
const slabs = @import("../private/slabs/slabs.zig");
const identifiers = @import("../private/data/identifiers.zig");
const values = @import("../private/data/value.zig");
const hasher = @import("../private/utils/hasher.zig");
const paths = @import("../private/utils/paths.zig");

pub const ParDatabase = @import("database.zig").ParDatabase;

pub const ParClass = struct {
    _handle: handles.ClassHandle,
    _data: slabs.ClassData,
    db: *ParDatabase,

    pub fn retrieve(
        self: ParClass,
        allocator: Allocator,
        path: []const u8,
        comptime context: ParDatabase.NodeType
    ) !?ParDatabase.RetrieveResult {
        const currentPath = paths.getPath(allocator, self.db.store, self);
        const fullPath = try std.fmt.allocPrint(allocator, "{}.{}", .{currentPath, path});
        return self.db.retrieve(fullPath, context);
    }

    pub fn create(
        self: ParClass,
        allocator: Allocator,
        io: std.Io,
        source: ?identifiers.SourceId,
        path: []const u8,
        comptime DataType: type,
        create_init: type.Init
    ) !ParDatabase.RetrieveResult {
        const currentPath = paths.getPath(allocator, self.db.store, self);
        const fullPath = try std.fmt.allocPrint(allocator, "{}.{}", .{currentPath, path});
        return self.db.create(allocator, io, source, fullPath, DataType, create_init);
    }
};

pub const ParArray = struct {
    _data: *slabs.ArrayData,
    _handle: handles.ArrayHandle,
    db: *ParDatabase,
};

pub const ParEnum = struct {
    _data: *slabs.EnumData,
    _handle: handles.EnumHandle,
    db: *ParDatabase,
};

pub const ParParameter = struct {
    _data: *slabs.ParameterData,
    _handle: handles.ParameterHandle,
    db: *ParDatabase,
};