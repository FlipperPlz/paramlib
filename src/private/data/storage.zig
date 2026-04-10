const std        = @import("std");
const Allocator  = std.mem.Allocator;
const class      = @import("../slabs/class.zig");
const source     = @import("../slabs/source.zig");
const strings    = @import("../utils/strings.zig");
const paths      = @import("../utils/paths.zig");
const value      = @import("value.zig");
const array      = @import("../slabs/array.zig");
const parameter  = @import("../slabs/parameter.zig");
const hasher     = @import("../utils/hasher.zig");
const enumerable = @import("../slabs/enum.zig");

pub const ParamAllocator = struct {
    arrays:       array.ArrayPool,
    classes:      class.ClassPool,
    enums:        enumerable.EnumPool,
    parameters:   parameter.ParameterPool,
    sources:      source.SourcePool,
    pathSegments: strings.StringPool(paths.PathSegmentIdentifier),
    stringValues: strings.StringPool(value.ValueStringIdentifier),
    pathToId:     std.AutoHashMapUnmanaged(u64, StorageIdentifier),
    root:         class.ClassStorage("sibling"),

    pub const empty: ParamAllocator = .{
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

    pub fn alloc(self: *ParamAllocator, allocator: Allocator, io: std.Io, init: anytype) !struct {
        index: @TypeOf(init)._identifier,
        ptr:   @TypeOf(init)._identifier._targetConst
    } {
        return switch (@TypeOf(init)._identifier._storageType) {
            StorageType.arr => {
                const array_init = init;
                const arr = try self.arrays.acquire(allocator);
                errdefer self.arrays.release(allocator, arr.index) catch @panic("oom");

                arr.ptr.* = try array.ArrayData.init(allocator, io, array_init);

                return .{
                    .index = arr.index,
                    .ptr   = arr.ptr
                };
            },
            StorageType.src => {
                const src_init = init;

                const src = try self.sources.acquire(allocator);
                errdefer self.sources.release(allocator, src.index) catch @panic("oom");

                src.ptr.* = try source.SourceData.init(src_init);

                return .{
                    .index = src.index,
                    .ptr   = src.ptr
                };
            },
            StorageType.clazz => {
                const class_init = init;

                const pathHash = class_init.pathHash orelse blk: {
                    const parentHandle: class.ClassHandle = class_init.parent orelse break :blk hasher.hash(class_init.name);
                    const parentCtx = try parentHandle.validateHandle(self);

                    // const parentIdx = parentCtx.id orelse return error.InvalidId;
                    // if (parentIdx >= self.classes.slabs.items.len * class.ClassSlabSize) return error.InvalidId;
                    const parent: *const class.ClassData = parentCtx.ptr;

                    var hash = hasher.IncrementalHasher.load(parent.pathHash);
                    break :blk hash.updateSep().update(class_init.name).final();

                };
                if (class_init.parent) |parent_handle| {
                    const parentIdx = parent_handle.id.toIndex() orelse return error.InvalidId;
                    if (parentIdx < self.classes.slabs.items.len * class.ClassSlabSize) {
                        const parent = self.classes.getConst(parent_handle.id);
                        if (parent.access == .readOnly or parent.access == .readOnlyVerified) {
                            return error.AccessDenied;
                        }
                    }
                }
                const clazz    = try self.classes.acquire(allocator);
                errdefer self.classes.release(allocator, clazz.index) catch @panic("oom");

                const nameHash = class_init.nameHash orelse hasher.hash(class_init.name);
                const nameIdx  = class_init.nameIdx orelse (try self.pathSegments.intern(allocator, class_init.name)).idx;

                try self.pathToId.put(allocator, pathHash, .create(clazz.index));
                errdefer _ = self.pathToId.remove(pathHash);

                clazz.ptr.* = class.ClassData.init(io, .{
                    .name      = class_init.name,
                    .nameHash  = nameHash,
                    .nameIdx   = nameIdx,
                    .pathHash  = pathHash,
                    .parent    = class_init.parent,
                    .source    = class_init.source,
                    .access    = class_init.access,
                    .base      = class_init.base,
                    .is_delete = class_init.is_delete,
                });

                const new_handle = class.ClassHandle{
                    .id         = clazz.index,
                    .generation = clazz.ptr.generation,
                };
                if (class_init.parent) |parent_handle| {
                    if (parent_handle.isValid()) {
                        const parent_data = self.classes.get(parent_handle.id);
                        try parent_data.children.append(self, new_handle);
                    } else {
                        // Todo maybe want to return an error here instead of silently treating it as a root class?
                        // Invalid parent handle treat as root class.
                        try self.root.append(self, new_handle);
                    }
                } else {
                    try self.root.append(self, new_handle);
                }

                return .{.index = clazz.index, .ptr = clazz.ptr};
            },
            StorageType.par => {
                const param_init = init;

                const param = try self.parameters.acquire(allocator);
                errdefer self.parameters.release(allocator, param.index) catch @panic("oom");

                const nameHash = param_init.nameHash orelse hasher.hash(param_init.name);
                const nameIdx = param_init.nameIdx orelse (try self.pathSegments.intern(allocator, param_init.name)).idx;
                const pathHash = param_init.pathHash orelse blk: {
                    if (!param_init.parent.isValid()) break :blk hasher.hash(param_init.name);
                    const parent = self.classes.getConst(param_init.parent.id);

                    var hash = hasher.IncrementalHasher.load(parent.pathHash);
                    break :blk hash.updateSep().update(param_init.name).final();
                };

                try self.pathToId.put(allocator, pathHash, .create(param.index));
                errdefer _ = self.pathToId.remove(pathHash);

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
                    try parent_data.params.append(self, new_param_handle);
                }

                return .{ .index = param.index, .ptr = param.ptr};

            },
            StorageType.segment => {
                const segment_init = init;
                const data = try self.pathSegments.intern(allocator, segment_init.data);
                return .{.index = data.idx, .ptr = try self.pathSegments.get(data.idx) orelse return error.NotFound};
            },
            StorageType.str => {
                const str_init = init;
                const data = try self.stringValues.intern(allocator, str_init.data);
                return .{.index = data.idx, .ptr = try self.stringValues.get(data.idx) orelse return error.NotFound};
            },
            StorageType.enumeration => { //TODO Enums
                @panic("Not Implemented Yet");
            }
        };
    }

    pub fn retrieve(
        self: *const ParamAllocator,
        id: anytype,
    ) !@TypeOf(id)._targetConst {
        if (!id.isValid()) return error.InvalidId;
        return switch (comptime @TypeOf(id)._storageType) {
            .arr         => self.arrays.getConstChecked(id),
            .clazz       => self.classes.getConstChecked(id),
            .enumeration => self.enums.getConstChecked(id),
            .par         => self.parameters.getConstChecked(id),
            .src         => self.sources.getConstChecked(id),
            .segment     => try self.pathSegments.get(id) orelse return error.NotFound,
            .str         => try self.stringValues.get(id) orelse return error.NotFound,
        };
    }

    pub fn retrieveMut(
        self: *ParamAllocator,
        id: anytype,
    ) !@TypeOf(id)._target {
        if (!id.isValid()) return error.InvalidId;
        return switch (comptime @TypeOf(id)._storageType) {
            .arr         => self.arrays.getChecked(id),
            .clazz       => self.classes.getChecked(id),
            .enumeration => self.enums.getChecked(id),
            .par         => self.parameters.getChecked(id),
            .src         => self.sources.getChecked(id),
            .segment     => try self.pathSegments.get(id) orelse return error.NotFound,
            .str         => try self.stringValues.get(id) orelse return error.NotFound,
        };
    }

    pub fn free(self: *ParamAllocator, allocator: Allocator, id: anytype) !void {
        if (!id.isValid()) return error.InvalidId;
        switch (comptime @TypeOf(id)._storageType) {
            .arr         => try self.arrays.release(allocator, id),
            .clazz       => try self.classes.release(allocator, id),
            .enumeration => try self.enums.release(allocator, id),
            .par         => try self.parameters.release(allocator, id),
            .src         => try self.sources.release(allocator, id),
            .segment     => return error.CannotFreeSegment, // Segments are interned and shared, so we don't free them individually
            .str         => return error.CannotFreeString, // Strings are interned and shared, so we don't free them individually
        }
    }

    pub fn deinit(self: *ParamAllocator, allocator: Allocator) void {
        const DeinitCtx = struct {
            alloc: Allocator,
            fn cb(ctx: @This(), arr: *array.ArrayData) void {
                arr.deinit(ctx.alloc);
            }
        };
        self.arrays.forEachLive(DeinitCtx {.alloc = allocator}, DeinitCtx.cb);

        self.arrays.deinit(allocator);
        self.classes.deinit(allocator);
        self.enums.deinit(allocator);
        self.parameters.deinit(allocator);
        self.sources.deinit(allocator);
        self.pathSegments.deinit(allocator);
        self.stringValues.deinit(allocator);
        self.pathToId.deinit(allocator);
    }
};

pub fn StringInit(comptime Tid: type) type {
    return struct {
        const Self = @This();
        pub const _identifier = Tid;
        data: []const u8,

        pub fn create(data: []const u8) Self {
            return Self {
                .data = data
            };
        }

    };
}


pub const StorageInitializer = union(StorageType) {
    arr:         array.ArrayInit,
    clazz:       class.ClassInit,
    enumeration: enumerable.EnumInit,
    par:         parameter.ParameterInit,
    src:         source.SourceInit,
    segment:     paths.SegmentInit,
    str:         value.StringValueInit,

    pub inline fn createArray(init: array.ArrayInit) StorageInitializer { return .{ .arr = init, }; }
    pub inline fn createClass(init: class.ClassInit) StorageInitializer { return .{ .clazz = init, }; }
    pub inline fn createEnum(init: enumerable.EnumInit) StorageInitializer { return .{ .enumeration = init, }; }
    pub inline fn createParameter(init: parameter.ParameterInit) StorageInitializer { return .{ .par = init, }; }
    pub inline fn createSource(init: source.SourceInit) StorageInitializer { return .{ .src = init, }; }
    pub inline fn createSegment(init: []const u8) StorageInitializer { return .{ .segment = init, }; }
    pub inline fn createString(init: []const u8) StorageInitializer { return .{ .str = init, }; }
};

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

    pub inline fn toIndex(self: StorageIdentifier) ?usize {
        return switch (self) {
            inline else => |s| s.toIndex(),
        };
    }

    pub inline fn isValid(self: StorageIdentifier) bool {
        return switch (self) {
            inline else => |s| s.isValid(),
        };
    }

    pub fn create(id: anytype) StorageIdentifier {
        return switch (@TypeOf(id)) {
            paths.PathSegmentIdentifier => StorageIdentifier { .segment = id, },
            value.ValueStringIdentifier => StorageIdentifier { .str = id, },
            enumerable.EnumIdentifier => StorageIdentifier { .enumeration = id, },
            array.ArrayIdentifier => StorageIdentifier { .arr = id },
            parameter.ParameterIdentifier => StorageIdentifier { .par = id, },
            class.ClassIdentifier => StorageIdentifier { .clazz = id },
            source.SourceIdentifier => StorageIdentifier { .src = id },
            else => @compileError("No identifier type for " ++ @typeName(@TypeOf(id))),
        };
    }
};

test "storage: StorageIdentifier isValid for each variant" {
    try std.testing.expect((StorageIdentifier{ .arr   = @enumFromInt(0) }).isValid());
    try std.testing.expect((StorageIdentifier{ .clazz = @enumFromInt(0) }).isValid());
    try std.testing.expect((StorageIdentifier{ .par   = @enumFromInt(0) }).isValid());
    try std.testing.expect((StorageIdentifier{ .segment = @enumFromInt(0) }).isValid());
    try std.testing.expect((StorageIdentifier{ .str   = @enumFromInt(0) }).isValid());
}

test "storage: StorageIdentifier invalid states" {
    try std.testing.expect(!(StorageIdentifier{ .arr     = .invalid }).isValid());
    try std.testing.expect(!(StorageIdentifier{ .par     = .invalid }).isValid());
    try std.testing.expect(!(StorageIdentifier{ .segment = .invalid }).isValid());
    try std.testing.expect(!(StorageIdentifier{ .str     = .invalid }).isValid());
}

test "storage: StorageIdentifier toIndex" {
    const id: StorageIdentifier = .{ .clazz = @enumFromInt(7) };
    try std.testing.expectEqual(@as(?usize, 7), id.toIndex());

    const invalid_id: StorageIdentifier = .{ .clazz = .invalid };
    try std.testing.expectEqual(@as(?usize, null), invalid_id.toIndex());
}

test "storage: alloc and retrieve string value" {
    var store = ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const result = try store.alloc(std.testing.allocator, undefined, value.StringValueInit.create("fire_resistance"));
    try std.testing.expect(result.index.isValid());

    const ptr = try store.retrieve(result.index);
    try std.testing.expectEqualStrings("fire_resistance", ptr);
}

test "storage: alloc and retrieve path segment" {
    var store = ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const result = try store.alloc(std.testing.allocator, undefined, paths.SegmentInit.create("player"));
    try std.testing.expect(result.index.isValid());

    const ptr = try store.retrieve(result.index);
    try std.testing.expectEqualStrings("player", ptr);
}

test "storage: retrieve invalid id returns InvalidId" {
    var store = ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidId, store.retrieve(value.ValueStringIdentifier.invalid));
}

test "storage: free segment returns CannotFreeSegment" {
    var store = ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const seg = try store.alloc(std.testing.allocator, undefined, paths.SegmentInit.create("world"));
    try std.testing.expectError(error.CannotFreeSegment, store.free(std.testing.allocator, seg.index));
}

test "storage: free string returns CannotFreeString" {
    var store = ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const str = try store.alloc(std.testing.allocator, undefined, value.StringValueInit.create("hello"));
    try std.testing.expectError(error.CannotFreeString, store.free(std.testing.allocator, str.index));
}

test "storage: free invalid id returns InvalidId" {
    var store = ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidId, store.free(std.testing.allocator, array.ArrayIdentifier.invalid));
}

test "storage: same string interned twice gives same index (dedup)" {
    var store = ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const r1 = try store.alloc(std.testing.allocator, undefined, value.StringValueInit.create("damage"));
    const r2 = try store.alloc(std.testing.allocator, undefined, value.StringValueInit.create("damage"));
    try std.testing.expectEqual(r1.index.toIndex(), r2.index.toIndex());
}

test "storage: same segment interned twice gives same index" {
    var store = ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const r1 = try store.alloc(std.testing.allocator, undefined, paths.SegmentInit.create("enemey"));
    const r2 = try store.alloc(std.testing.allocator, undefined, paths.SegmentInit.create("enemey"));
    try std.testing.expectEqual(r1.index.toIndex(), r2.index.toIndex());
}

test "storage: multiple strings all independently retrievable" {
    var store = ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const stats = [_][]const u8{ "health", "mana", "attack", "defense", "speed" };
    var indices: [stats.len]StorageIdentifier = undefined;

    for (stats, 0..) |name, i| {
        indices[i] = StorageIdentifier.create((try store.alloc(std.testing.allocator, undefined, value.StringValueInit.create(name))).index);
    }
    for (stats, indices) |name, idx| {
        const ptr = try store.retrieve(idx.str);
        try std.testing.expectEqualStrings(name, ptr);
    }
}

test "storage: deinit on empty store does not crash" {
    var store = ParamAllocator.empty;
    store.deinit(std.testing.allocator);
}

test "storage: alloc root class — basic fields" {
    var store = ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const result = try store.alloc(std.testing.allocator, std.testing.io, class.ClassInit {
        .name   = "player",
        .parent = null,
        .source = source.SourceHandle.invalid,
    });

    try std.testing.expect(result.index.isValid());
    const data: *const class.ClassData = result.ptr;
    _ = data;
}

test "storage: alloc root class — pathToId lookup works" {
    var store = ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    _ = try store.alloc(std.testing.allocator, std.testing.io, class.ClassInit {
        .name   = "world",
        .parent = null,
        .source = source.SourceHandle.invalid,
    });

    const hash = hasher.hash("world");
    const found = store.pathToId.get(hash);
    try std.testing.expect(found != null);
    try std.testing.expect(found.?.isValid());
}

test "storage: alloc two root classes get distinct identifiers" {
    var store = ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const a = try store.alloc(std.testing.allocator, std.testing.io, class.ClassInit {
        .name = "zone_a", .parent = null, .source = source.SourceHandle.invalid,
    });
    const b = try store.alloc(std.testing.allocator, std.testing.io, class.ClassInit {
        .name = "zone_b", .parent = null, .source = source.SourceHandle.invalid,
    });

    try std.testing.expect(a.index.toIndex() != b.index.toIndex());
}

test "storage: alloc child class — pathHash includes parent path" {
    var store = ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const root = try store.alloc(std.testing.allocator, std.testing.io, class.ClassInit {
        .name = "game", .parent = null, .source = source.SourceHandle.invalid,
    });
    const rootHandle = class.ClassHandle{
        .id         = root.index,
        .generation = root.ptr.generation,
    };

    _ = try store.alloc(std.testing.allocator, std.testing.io, class.ClassInit {
        .name   = "player",
        .parent = rootHandle,
        .source = source.SourceHandle.invalid,
    });

    const expected_hash = hasher.hash("game.player");
    try std.testing.expect(store.pathToId.get(expected_hash) != null);
}

test "storage: alloc parameter in class" {
    var store = ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const root = try store.alloc(std.testing.allocator, std.testing.io, class.ClassInit {
        .name = "entity", .parent = null, .source = source.SourceHandle.invalid,
    });
    const parentHandle = class.ClassHandle{
        .id         = root.index,
        .generation = root.ptr.generation,
    };

    const param = try store.alloc(std.testing.allocator, std.testing.io, parameter.ParameterInit {
        .name   = "speed",
        .parent = parentHandle,
        .source = source.SourceHandle.invalid,
        .value  = value.Value.initF32(5.0),
    });

    try std.testing.expect(param.index.isValid());
    const expected = hasher.hash("entity.speed");
    try std.testing.expect(store.pathToId.get(expected) != null);
}

test "storage: free class releases slot" {
    var store = ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const c = try store.alloc(std.testing.allocator, std.testing.io, class.ClassInit {
        .name = "tmp", .parent = null, .source = source.SourceHandle.invalid,
    });
    try store.free(std.testing.allocator, c.index);
    try std.testing.expectError(error.InvalidId, store.free(std.testing.allocator, class.ClassIdentifier.invalid));
}