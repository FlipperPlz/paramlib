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

pub const ParClass = struct {
    _handle: handles.ClassHandle,
    _data: slabs.ClassData,
    db: *ParDatabase,

    pub fn retrieve(
        self: ParClass,
        allocator: Allocator,
        path: []const u8,
        comptime context: NodeType
    ) !?RetrieveResult {
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
    ) !RetrieveResult {
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

pub const ParDatabase = struct {
    store: storage.ParamStorage,
    rootHandle: handles.ClassHandle,
    runtime: identifiers.SourceId,
    enums: storage.EnumStorage,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: Allocator, io: std.Io) ParDatabase {
        const store: storage.ParamStorage = .empty;
        const root_name = try store.intern(allocator, "root");
        const path_hash = std.hash.Wyhash.hash(0, root_name);
        const source_name = try store.intern(allocator, "RUNTIME");
        const source_data = try store.intern(allocator, "");

        const source = try store.allocateSource(allocator, .{
            .runtime = .{
                .name = source_name.id,
                .data = source_data.id
            }
        });

        const createdRoot = try store.allocateClass(allocator, .{
            .io = io,
            .parent = .invalid,
            .name_idx = root_name.id,
            .name_hash = path_hash,
            .path_hash = path_hash,
            .source = source.id,
        });

        try store.path_to_class.put(allocator, path_hash, createdRoot.id);

        const db: ParDatabase = .{
            .store = .empty,
            .runtime = source.id,
            .rootHandle = undefined,
            .enums = .empty
        };
        db.root.* = handles.makeHandle(db, createdRoot.id);

        return db;
    }

    pub fn root(self: *ParDatabase) !ParClass {
        const classData = try self.store.retrieve(.create(self.rootHandle.id));
        return ParClass {
            ._data = @ptrCast(classData),
            .db = self
        };
    }

    pub fn retrieve(
        self: ParDatabase,
        path: []const u8,
        comptime context: NodeType
    ) !?RetrieveResult {
        if(context != .array
        //|| check if path contains [x] if .none
        ) {
            const id = self.store.path_to_id.get(hasher.hash(path));
            return switch (context) {
                .parameter => try self.retrieveItem(slabs.ParameterData, id),
                .class => try self.retrieveItem(slabs.ClassData, id),
                .array => try self.retrieveItem(slabs.ArrayData, id),
                .none => (try self.retrieveItem(slabs.ParameterData, id)) orelse
                    (try self.retrieveItem(slabs.ClassData, id)),
            };
        }
    }

    pub fn create(self: ParDatabase,
        allocator: Allocator,
        io: std.Io,
        source: ?identifiers.SourceId,
        path: []const u8,
        comptime DataType: type,
        create_init: type.Init
    ) !RetrieveResult {
        self.mutex.lock(io);
        defer self.mutex.unlock(io);

        switch (DataType) {
            slabs.ArrayData => {

            },
            slabs.ParameterData => {

            },
            slabs.ClassData => {

            },
            slabs.EnumData => {
                const data = try self.enums.create(.{
                    .allocator = allocator,
                    .io = io,
                    .name = path,
                    .source = source orelse self.runtime,
                    .store = &self.store,
                    .value = create_init.value
                });
                return @unionInit(RetrieveResult, "enum", DataType.Handle {
                    ._handle = try handles.makeHandle(self.store, data.id),
                    ._data = data.ptr,
                    .db = self,
                });
            },
            else => @compileError("unsupported type: " ++ @typeName(DataType)),
        }
    }

    fn retrieveItem(self: ParDatabase, comptime T: type, id: anytype) !?RetrieveResult {
        const ItemId = T.Id;
        const Handle = T.Handle;

        const field = switch (T) {
            slabs.ParameterData => .{.name = "parameter", .handle = ParParameter },
            slabs.ClassData =>  .{.name = "class", .handle = ParClass },
            slabs.ArrayData =>  .{.name = "array", .handle = ParArray },
            slabs.EnumData => .{.name = "enum", .handle = ParEnum },
            else => @compileError("unsupported type: " ++ @typeName(T)),
        };

        const itemId = ItemId.fromIndex(id);
        const itemData: *T = try self.store.retrieve(.create(itemId));
        return @unionInit(RetrieveResult, field, Handle {
            ._handle = try handles.makeHandle(self.store, itemId),
            ._data = itemData,
            .db = self,
        });
    }

};


pub const NodeType = enum {
    none,
    class,
    parameter,
    array,
};

pub const RetrieveResult = union(NodeType) {
    class: ParClass,
    parameter: ParParameter,
    arrayValue: ParArray,

    pub fn classOrNull(self: *RetrieveResult) ?ParClass {
        return switch (self) {
            .class => |class| class,
            .arrayValue => null,
            .parameter => null
        };
    }

    pub fn parameterOrNull(self: *RetrieveResult) ?ParParameter {
        return switch (self) {
            .class => null,
            .arrayValue => null,
            .parameter => |class| class
        };
    }

    pub fn arrayValueOrNull(self: *RetrieveResult) ?ParArray {
        return switch (self) {
            .class => null,
            .arrayValue => |value| value,
            .parameter => null,
        };
    }
};