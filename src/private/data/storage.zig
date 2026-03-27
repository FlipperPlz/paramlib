const std        = @import("std");
const Allocator  = std.mem.Allocator;
const array      = @import("../slabs/array.zig");
const class      = @import("../slabs/class.zig");
const enumerable = @import("../slabs/enum.zig");
const parameter  = @import("../slabs/parameter.zig");
const source     = @import("../slabs/source.zig");
const strings    = @import("../utils/strings.zig");
const paths      = @import("../utils/paths.zig");
const value      = @import("value.zig");
const hasher     = @import("../utils/hasher.zig");

pub const StorageType = enum {
    arr,
    clazz,
    enumeration,
    par,
    src,
    segment,
    str,
};

pub const StorageIdentifier = union(StorageType) {
    arr:         array.ArrayIdentifier,
    clazz:       class.ClassIdentifier,
    enumeration: enumerable.EnumIdentifier,
    par:         parameter.ParameterIdentifier,
    src:         source.SourceIdentifier,
    segment:     paths.PathSegmentIdentifier,
    str:         value.ValueStringIdentifier,

    pub fn toIndex(self: StorageIdentifier) ?usize {
        return switch (self) {
            .arr         => |s| s.toIndex(),
            .clazz       => |s| s.toIndex(),
            .enumeration => |s| s.toIndex(),
            .par         => |s| s.toIndex(),
            .src         => |s| s.toIndex(),
            .segment     => |s| s.toIndex(),
            .str         => |s| s.toIndex(),
        };
    }

    pub fn isValid(self: StorageIdentifier) bool {
        return switch (self) {
            .arr         => |s| s.isValid(),
            .clazz       => |s| s.isValid(),
            .enumeration => |s| s.isValid(),
            .par         => |s| s.isValid(),
            .src         => |s| s.isValid(),
            .segment     => |s| s.isValid(),
            .str         => |s| s.isValid()
        };
    }

     pub fn create(id: anytype) StorageIdentifier {
        return switch (@TypeOf(id)) {
            paths.PathSegmentIdentifier => StorageIdentifier {
                .segment = id,
            },
            value.ValueStringIdentifier => StorageIdentifier {
                .str = id,
            },
            enumerable.EnumIdentifier => StorageIdentifier {
                .enumeration = id,
            },
            array.ArrayIdentifier => StorageIdentifier {
                .arr = id
            },
            parameter.ParameterIdentifier => StorageIdentifier {
                .par = id,
            },
            class.ClassIdentifier => StorageIdentifier {
                .clazz = id
            },
            source.SourceIdentifier => StorageIdentifier {
                .src = id
            },
            else => @compileError("No identifier type for " ++ @typeName(@TypeOf(id))),
        };
    }

};

pub const StorageInitializer = union(StorageType) {
    arr:         array.ArrayInit,
    clazz:       class.ClassInit,
    enumeration: enumerable.EnumInit,
    par:         parameter.ParameterInit,
    src:         source.SourceInit,
    segment:     []const u8,
    str:         []const u8,

    pub fn createArray(init: array.ArrayInit) StorageInitializer {
        return .{
            .arr = init,
        };
    }

    pub fn createClass(init: class.ClassInit) StorageInitializer {
        return .{
            .clazz = init,
        };
    }
    
    pub fn createEnum(init: enumerable.EnumInit) StorageInitializer {
        return .{
            .enumeration = init,
        };
    }

    pub fn createParameter(init: parameter.ParameterInit) StorageInitializer {
        return .{
            .par = init,
        };
    }

    pub fn createSource(init: source.SourceInit) StorageInitializer {
        return .{
            .src = init,
        };
    }

    pub fn createSegment(init: []const u8) StorageInitializer {
        return .{
            .segment = init,
        };
    }

    pub fn createString(init: []const u8) StorageInitializer {
        return .{
            .str = init,
        };
    }
};


pub const ParamStorage = struct {  
    arrays:       array.ArrayPool,
    classes:      class.ClassPool,
    enums:        enumerable.EnumPool,
    parameters:   parameter.ParameterPool,
    sources:      source.SourcePool,
    pathSegments: strings.StringPool(paths.PathSegmentIdentifier),
    stringValues: strings.StringPool(value.ValueStringIdentifier),
    pathToId:     std.AutoHashMapUnmanaged(u64, StorageIdentifier),
    root:         class.ClassStorage("sibling"),

    pub const empty: ParamStorage = .{
        .arrays       = array.ArrayPool.empty,
        .classes      = class.ClassPool.empty,
        .enums        = enumerable.EnumPool.empty,
        .parameters   = parameter.ParameterPool.empty,
        .sources      = source.SourcePool.empty,
        .pathSegments = strings.StringPool(paths.PathSegmentIdentifier).empty,
        .stringValues = strings.StringPool(value.ValueStringIdentifier).empty,
        .pathToId     = std.AutoHashMapUnmanaged(u64, StorageIdentifier).empty,
        .root         = class.ClassStorage("sibling").empty,
    };

    pub fn alloc(self: *ParamStorage, allocator: Allocator, io: std.Io, initializer: StorageInitializer) !struct {index: StorageIdentifier, ptr: *anyopaque } {
        return switch (initializer) {
            .arr => |array_init| {
                const arr = try self.arrays.acquire(allocator);
                errdefer self.arrays.release(allocator, arr.index) catch @panic("oom");

                arr.ptr.* = array.ArrayData.init(io, array_init);

                return .{
                    .index = .create(arr.index),
                    .ptr   = @ptrCast(arr.ptr)
                };
            },
            .src => |src_init| {
                const src = try self.sources.acquire(allocator);
                errdefer self.sources.release(allocator, src.index) catch @panic("oom");

                src.ptr.* = try source.SourceData.init(src_init);

                return .{
                    .index = .create(src.index),
                    .ptr   = @ptrCast(src.ptr)
                };
            },
            .clazz => |class_init| {
                const clazz    = try self.classes.acquire(allocator);
                errdefer self.classes.release(allocator, clazz.index) catch @panic("oom");

                const nameHash = class_init.nameHash orelse hasher.hash(class_init.name);
                const nameIdx  = class_init.nameIdx orelse (try self.pathSegments.intern(allocator, class_init.name)).idx;
                const pathHash = class_init.pathHash orelse blk: {
                    const parentHandle = class_init.parent orelse break :blk hasher.hash(class_init.name);
                    const parentIdx = parentHandle.id.toIndex() orelse return error.InvalidId;
                    if (parentIdx >= self.classes.slabs.items.len * 16) return error.InvalidId;
                    const parent = self.classes.getConst(parentHandle.id);

                    const parentPath = try paths.getPath(allocator, self, .createClass(parent));
                    defer allocator.free(parentPath);

                    const joined = try paths.joinPaths(allocator, &[_][]const u8{parentPath, class_init.name});
                    defer allocator.free(joined);

                    break :blk hasher.hash(joined);
                };
                try self.pathToId.put(allocator, pathHash, .create(clazz.index));
                errdefer self.pathToId.remove(pathHash);

                clazz.ptr.* = class.ClassData.init(io, .{
                    .name     = class_init.name,
                    .nameHash = nameHash,
                    .nameIdx  = nameIdx,
                    .pathHash = pathHash,
                    .parent   = class_init.parent,
                    .source   = class_init.source,
                    .access   = class_init.access,
                    .base     = class_init.base,
                });

                const new_handle = class.ClassHandle{
                    .id         = clazz.index,
                    .generation = clazz.ptr.generation,
                };
                if (class_init.parent) |parent_handle| {
                    if (parent_handle.isValid()) {
                        const parent_data = self.classes.get(parent_handle.id);
                        clazz.ptr.sibling    = parent_data.children;
                        parent_data.children = class.ClassStorage("sibling").init(new_handle);
                    } else {
                        // Todo maybe want to return an error here instead of silently treating it as a root class?
                        // Invalid parent handle treat as root class.
                        clazz.ptr.sibling = self.root;
                        self.root = class.ClassStorage("sibling").init(new_handle);
                    }
                } else {
                    clazz.ptr.sibling = self.root;
                    self.root = class.ClassStorage("sibling").init(new_handle);
                }

                return .{.index = .create(clazz.index), .ptr = @ptrCast(clazz.ptr)};
            },
            .par => |param_init| {
                const param = try self.parameters.acquire(allocator);
                errdefer self.parameters.release(allocator, param.index) catch @panic("oom");

                const nameHash = param_init.nameHash orelse hasher.hash(param_init.name);
                const nameIdx = param_init.nameIdx orelse (try self.pathSegments.intern(allocator, param_init.name)).idx;
                const pathHash = param_init.pathHash orelse blk: {
                    if (!param_init.parent.isValid()) break :blk hasher.hash(param_init.name);
                    const parent = self.classes.getConst(param_init.parent.id);

                    const parentPath = try paths.getPath(allocator, self, .createClass(parent));
                    defer allocator.free(parentPath);

                    const joined = try paths.joinPaths(allocator, &[_][]const u8{ parentPath, param_init.name });
                    defer allocator.free(joined);

                    break :blk hasher.hash(joined);
                };
                
                try self.pathToId.put(allocator, pathHash, .create(param.index));
                errdefer self.pathToId.remove(pathHash);

                param.ptr.* = parameter.ParameterData.init(io, .{
                    .name     = param_init.name,
                    .nameHash = nameHash,
                    .nameIdx  = nameIdx,
                    .pathHash = pathHash,
                    .source   = param_init.source,
                    .value    = param_init.value,
                    .parent   = param_init.parent
                });

                if (param_init.parent.isValid()) {
                    const parent_data = self.classes.get(param_init.parent.id);
                    const new_param_handle = parameter.ParameterHandle{
                        .id         = param.index,
                        .generation = param.ptr.generation,
                    };
                    param.ptr.sibling  = parent_data.params;
                    parent_data.params = parameter.ParameterStorage("sibling").init(new_param_handle);
                }

                return .{ .index = .create(param.index), .ptr = @ptrCast(param.ptr)};

            },
            .segment => |segment_init| {
                const data = try self.pathSegments.intern(allocator, segment_init);
                return .{.index = .create(data.idx), .ptr = @constCast(@ptrCast((try self.pathSegments.get_ptr(data.idx)) orelse return error.NotFound))};
            },
            .str => |str_init| {
                const data = try self.stringValues.intern(allocator, str_init);
                return .{.index = .create(data.idx), .ptr = @constCast(@ptrCast((try self.stringValues.get_ptr(data.idx)) orelse return error.NotFound))};
            },
            .enumeration => { //TODO Enums
                @panic("Not Implemented Yet");
            }
        };
    }
    
    pub fn retrieve(self: *const ParamStorage, id: StorageIdentifier) !*const anyopaque {
        if (!id.isValid()) return error.InvalidId;
        return switch (id) {
            .arr         => |i| @ptrCast(@alignCast(self.arrays.getConst(i))),
            .clazz       => |i| @ptrCast(@alignCast(self.classes.getConst(i))),
            .enumeration => |i| @ptrCast(@alignCast(self.enums.getConst(i))),
            .par         => |i| @ptrCast(@alignCast(self.parameters.getConst(i))),
            .src         => |i| @ptrCast(@alignCast(self.sources.getConst(i))),
            .segment     => |i| @ptrCast((try self.pathSegments.get_ptr(i)) orelse return error.NotFound),
            .str         => |i| @ptrCast((try self.stringValues.get_ptr(i)) orelse return error.NotFound),
        };
    }

    pub fn retrieveMut(self: *ParamStorage, id: StorageIdentifier) !*anyopaque {
        if(!id.isValid()) return error.InvalidId;
        return switch (id) {
            .arr         => |i| @ptrCast(@alignCast(self.arrays.get(i))),
            .clazz       => |i| @ptrCast(@alignCast(self.classes.get(i))),
            .enumeration => |i| @ptrCast(@alignCast(self.enums.get(i))),
            .par         => |i| @ptrCast(@alignCast(self.parameters.get(i))),
            .src         => |i| @ptrCast(@alignCast(self.sources.get(i))),
            .segment     => |i| @ptrCast((try self.pathSegments.get(i)) orelse return error.NotFound),
            .str         => |i| @ptrCast((try self.stringValues.get(i)) orelse return error.NotFound), 
        };
    }

    pub fn free(self: *ParamStorage, allocator: Allocator, id: StorageIdentifier) !void {
        if (!id.isValid()) return error.InvalidId;
        switch (id) {
            .arr => |i| try self.arrays.release(allocator, i),
            .clazz => |i| try self.classes.release(allocator, i),
            .enumeration => |i| try self.enums.release(allocator, i),
            .par => |i| try self.parameters.release(allocator, i),
            .src => |i| try self.sources.release(allocator, i),
            .segment => return error.CannotFreeSegment, // Segments are interned and shared, so we don't free them individually
            .str => return error.CannotFreeString, // Strings are interned and shared, so we don't free them individually
        }
    }

    pub fn deinit(self: *ParamStorage, allocator: Allocator) void {
        const DeinitCtx = struct {
            alloc: Allocator,
            fn cb(ctx: @This(), arr: *array.ArrayData) void {
                arr.deinit(ctx.alloc);
            }
        };
        self.arrays.forEachLive(DeinitCtx{ .alloc = allocator }, DeinitCtx.cb);

        self.classes.deinit(allocator);
        self.parameters.deinit(allocator);
        self.arrays.deinit(allocator);
        self.enums.deinit(allocator);
        self.pathSegments.deinit(allocator);
        self.stringValues.deinit(allocator);
        self.sources.deinit(allocator);
        self.pathToId.deinit(allocator);
    }
}; 
