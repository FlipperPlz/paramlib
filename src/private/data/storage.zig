const std = @import("std");
const Allocator = std.mem.Allocator;
const identifiers = @import("identifiers.zig");
const memory = @import("../utils/memory.zig");
const strings = @import("../utils/strings.zig");
const slabs = @import("../slabs/slabs.zig");
const handles = @import("../data/handles.zig");
const storage = @import("../data/storage.zig");

pub const StorageType = enum {
    slab,
    string,
};

pub const EnumStorage = struct {
    firstEnum: handles.EnumHandle,

    pub const empty: EnumStorage = .{
        .firstEnum = .invalid
    };

    pub const AddArgs = struct {
        allocator: Allocator,
        io: std.Io,
        store: *storage.ParamStorage,
        source: identifiers.SourceId,
        name: []const u8,
        value: f32
    };

    pub fn add(self: *EnumStorage, args: AddArgs) !void {
        const enum_name = try args.store.intern(args,args.allocator, args.name);
        const name_hash =  std.hash.Wyhash.hash(0, args.name);
        var current = self.firstEnum;
        if(current == .invalid) {
            self.firstEnum = handles.makeHandle(args.store, try args.store.allocateEnum(args.allocator, .{
                .io = args.io,
                .name_idx = enum_name.id,
                .name_hash = name_hash,
                .value = args.value,
                .source_id = args.source
            }).id);

            return;
        } else {
            while (current != .invalid) {
                const par = args.store.retrieve(.create(current.id)).?;
                if (par.name_hash == name_hash) {
                    return error.EnumAlreadyExists;
                }
                current = par.next;
            }
        }

        const enum_value = try args.store.allocateEnum(args.allocator, .{
            .io = args.io,
            .name_idx = enum_name.id,
            .name_hash = name_hash,
            .value = args.value,
            .source_id = args.source
        });
        enum_value.ptr.next = self.firstEnum;

        self.firstEnum = handles.makeHandle(args.store, enum_value .id);
    }
};

pub const StorageInit = union(StorageType) {
    slab: slabs.SlabInit,
    string: []const u8,

    pub fn fromString(string: []const u8) StorageInit {
        return StorageInit {
            .string = string
        };
    }
};

pub const StorageIdentifier = union(StorageType) {
    slab: slabs.SlabIdentifier,
    string: identifiers.StringId,

    pub fn isValid(self: StorageIdentifier) bool {
        return switch (self) {
            .slab => |s| s.isValid(),
            .string => |s| s.isValid()
        };
    }

    pub fn toIndex(self: StorageIdentifier) ?u32 {
        return switch (self) {
            .slab => |s| s.toIndex(),
            .string => |s| s.toIndex()
        };
    }

    pub fn create(comptime id: type) StorageIdentifier {
        return switch (id) {
            identifiers.StringId => StorageIdentifier {
                .string = id,
            },
            identifiers.EnumId => StorageIdentifier {
                .slab = .{.enumeration = type},
            },
            identifiers.ArrayId => StorageIdentifier {
                .slab = .{.array = type},
            },
            identifiers.ParameterId => StorageIdentifier {
                .slab = .{.parameter = type},
            },
            identifiers.ClassId => StorageIdentifier {
                .slab = .{.class = type},
            },
            identifiers.SourceId => StorageIdentifier {
                .slab = .{ .source = type }
            },
            else => @compileError("No identifier type for " ++ @typeName(type)),
        };
    }
};

pub const ParamStorage = struct {
    arrays: memory.SlabPool(slabs.ArrayData, 1024),
    params: memory.SlabPool(slabs.ParameterData, 512),
    classes: memory.SlabPool(slabs.ClassData, 512),
    sources: memory.SlabPool(slabs.SourceData, 256),
    enums: memory.SlabPool(slabs.EnumData, 64),
    strings: strings.StringPool,
    path_to_class: std.AutoHashMapUnmanaged(u64, identifiers.ClassId),

    pub const empty: ParamStorage = .{
        .arrays = .empty,
        .params = .empty,
        .classes = .empty,
        .sources = .empty,
        .enums = .empty,
        .strings = .empty,
        .path_to_class = .empty
    };

    pub fn deinit(self: *ParamStorage, allocator: Allocator) void {
        const array_stats = self.arrays.getStats();
        for (0..array_stats.total_capacity) |i| {
            const idx: u32 = @intCast(i);
            const arr = self.arrays.get(idx);
            if (i < array_stats.used_count) {
                arr.deinit(allocator);
            }
        }
        self.classes.deinit(allocator);
        self.params.deinit(allocator);
        self.arrays.deinit(allocator);
        self.enums.deinit(allocator);
        self.strings.deinit(allocator);
        self.sources.deinit(allocator);
        self.path_to_class.deinit(allocator);
    }

    pub fn allocate(self: *ParamStorage, allocator: Allocator, args: StorageInit) !struct {ptr: *anyopaque, idx: u32} {
        return switch (args) {
            .slab => |slab_init| switch (slab_init) {
                .parameter => |d| acquireFrom(try self.params.acquire(allocator), d, slabs.ParameterData),
                .class => |d| acquireFrom(try self.classes.acquire(allocator), d, slabs.ClassData),
                .enumeration=> |d| acquireFrom(try self.enums.acquire(allocator), d, slabs.EnumData),
                .array => |d| acquireFrom(try self.arrays.acquire(allocator), d, slabs.ArrayData),
                .source => |d| acquireFrom(try self.sources.acquire(allocator), d, slabs.SourceData)
            },
            .string => |string_init| {
                const interned = try self.strings.intern(allocator, string_init);
                return .{
                    .ptr = &interned.str,
                    .idx = interned.idx
                };
            }
        };
    }

    pub fn free(self: *ParamStorage, allocator: Allocator, id: StorageIdentifier) !void {
        const index = id.toIndex() orelse return error.InvalidId;
        return switch (id) {
            .slab => |slab_id| return switch (slab_id) {
                .parameter => try self.params.release(allocator, index),
                .class => try self.classes.release(allocator, index),
                .enumeration => try self.enums.release(allocator, index),
                .array => try self.arrays.release(allocator, index),
                .source => try self.sources.release(allocator, index),
            },
            .string => self.strings.free(allocator, index)
        };
    }

    pub fn retrieve(self: *ParamStorage, id: StorageIdentifier) !*anyopaque {
        const index = id.toIndex() orelse return error.InvalidId;
        return switch (id) {
            .slab => |slab| switch (slab) {
                .parameter => self.params.get(index),
                .class => self.classes.get(index),
                .enumeration => self.enums.get(index),
                .array => self.arrays.get(index),
                .source => self.sources.get(index),
        },
            .string => try self.strings.get(index),
        };
    }

    pub inline fn intern(self: *ParamStorage, allocator: Allocator, string: []const u8) !struct {
        ptr: []const u8,
        id: identifiers.StringId
    } {
        const allocated = try self.allocate(allocator, StorageInit.fromString(string));
        const string_ptr: *[]const u8 = @ptrCast(@alignCast(allocated.ptr));

        return .{
            .ptr = string_ptr.*,
            .id = identifiers.StringId.fromIndex(allocated.idx)
        };
    }
    // helpers

    pub inline fn allocateClass(self: *ParamStorage, allocator: Allocator, args: ?slabs.ClassData.Init) !SlabResult(slabs.ClassData) {
        return self.allocateSlab(allocator, slabs.ClassData, args);
    }

    pub inline fn allocateParameter(self: *ParamStorage, allocator: Allocator, args: ?slabs.ParameterData.Init) !SlabResult(slabs.ParameterData) {
        return self.allocateSlab(allocator, slabs.ParameterData, args);
    }

    pub inline fn allocateArray(self: *ParamStorage, allocator: Allocator, args: ?slabs.ArrayData.Init) !SlabResult(slabs.ArrayData) {
        return self.allocateSlab(allocator, slabs.ArrayData, args);
    }

    pub inline fn allocateEnum(self: *ParamStorage, allocator: Allocator, args: ?slabs.EnumData.Init) !SlabResult(slabs.EnumData) {
        return self.allocateSlab(allocator, slabs.EnumData, args);
    }

    pub inline fn allocateSource(self: *ParamStorage, allocator: Allocator, args: ?slabs.SourceData.Init) !SlabResult(slabs.SourceData) {
        return self.allocateSlab(allocator, slabs.SourceData, args);
    }

    // private helpers
    inline fn allocateSlab(self: *ParamStorage, allocator: Allocator, comptime datatype: type, args: ?datatype.Init) !SlabResult(datatype) {
        const init = StorageInit{ .slab = slabs.SlabInit.from(datatype, args) };
        const allocated = try self.allocate(allocator, init);
        return .{
            .ptr = @ptrCast(@alignCast(allocated.ptr)),
            .id  = identifiers.idFor(type).fromIndex(allocated.idx),
        };
    }
};

fn SlabResult(comptime DataType: type) type {
    return struct {
        ptr: *DataType,
        id:  identifiers.idFor(type),
    };
}

fn acquireFrom(result: anytype, init_data: anytype, comptime DataType: type) struct { ptr: *anyopaque, id: StorageIdentifier } {
    if (init_data) |data| result.ptr.* = DataType.init(data);
    return .{ .ptr = result.ptr, .id = result.index };
}
