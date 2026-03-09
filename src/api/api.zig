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
pub const RetrieveType = enum {
    none,
    class,
    parameter,
    arrayValue,
};

pub const RetrieveResult = union(RetrieveType) {
    class: ParClass,
    parameter: ParParameter,
    arrayValue: values.Value,

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

    pub fn arrayValueOrNull(self: *RetrieveResult) ?values.Value {
        return switch (self) {
            .class => null,
            .arrayValue => |value| value,
            .parameter => null,
        };
    }
};

pub const ParClass = struct {
    _handle: handles.ClassHandle,
    _data: slabs.ClassData,
    db: *ParDatabase,

    pub fn retrieve(
        self: ParClass,
        allocator: Allocator,
        path: []const u8,
        comptime context: RetrieveType
    ) !?RetrieveResult {
        const currentPath = paths.getPath(allocator, self.db.store, self);
        const fullPath = try std.fmt.allocPrint(allocator, "{}.{}", .{currentPath, path});
        return self.db.retrieve(fullPath, context);
    }
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

    //TODO
    pub fn retrieve(self: ParDatabase, path: []const u8, comptime context: RetrieveType) !?RetrieveResult {
        if(context != .arrayValue
        //|| check if path contains [x] if .none
        ) {
            const id = self.store.path_to_id.get(hasher.hash(path));
            return switch (context) {
                .parameter => {
                    const paramId = identifiers.ParameterId.fromIndex(id);
                    const paramData: *slabs.ParameterData =
                        try self.store.retrieve(.create(paramId));
                    return RetrieveResult {
                        .parameter = ParParameter {
                            ._handle = handles.makeHandle(self.store, paramId),
                            ._data = paramData,
                            .db = self
                        }
                    };
                },
                .class => {
                    const classId = identifiers.ClassId.fromIndex(id);
                    const classData: *slabs.ClassData =
                        try self.store.retrieve(.create(classId));
                    return RetrieveResult {
                        .class = ParClass {
                            ._handle = handles.makeHandle(self.store, classId),
                            ._data = classData,
                            .db = self
                        }
                    };
                },
                .none => {
                    //first look for params
                    {
                        const paramId = identifiers.ParameterId.fromIndex(id);
                        if (self.store.retrieve(.create(paramId))) |paramVoid| {
                            return RetrieveResult {
                                .parameter = ParParameter {
                                    ._handle = handles.makeHandle(self.store, paramId),
                                    ._data = paramVoid,
                                    .db = self
                                }
                            };
                        }
                    }
                    //then classes
                    {
                        const classId = identifiers.ClassId.fromIndex(id);
                        if (self.store.retrieve(.create(classId))) |classVoid| {
                            return RetrieveResult {
                                .parameter = ParClass {
                                    ._handle = handles.makeHandle(self.db, classId),
                                    ._data = classVoid,
                                    .db = self
                                }
                            };
                        }
                    }

                    return null;
                }
            };
        }
    }
};