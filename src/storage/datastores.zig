const std = @import("std");
const class_mod = @import("../data/class.zig");
const param_mod = @import("../data/param.zig");
const value_mod = @import("../data/value.zig");
const id_mod = @import("../core/identifiers.zig");
const pools_mod = @import("../utils/pools.zig");
const source_pool_mod = @import("source_pool.zig");
const log = @import("../utils/log.zig");

const Allocator = std.mem.Allocator;
const ClassId = id_mod.ClassId;
const ParamId = id_mod.ParamId;
const StringPool = pools_mod.StringPool;
const SlabPool = pools_mod.SlabPool;
const ClassData = class_mod.ClassData;
const ParamData = param_mod.ParamData;
const ArrayData = value_mod.ArrayData;
const SourcePool = source_pool_mod.SourcePool;
const StringId = id_mod.TypedId();

pub const AstDatastore = struct {
    allocator: Allocator,
    arrays: SlabPool(ArrayData, 128),
    strings: StringPool,

    pub fn init(allocator: Allocator) !*AstDatastore {
        return .{
            .allocator = allocator,
            .arrays = SlabPool(ArrayData, 128).empty,
            .strings = StringPool.empty,
        };
    }

    pub fn deinit(self: *AstDatastore) void {
        self.arrays.deinit(self.allocator);
        self.strings.deinit(self.allocator);
    }

    pub fn allocArray(self: *AstDatastore) !u32 {
        const result = try self.arrays.acquire(self.allocator);
        result.ptr.* = ArrayData.empty;
        return result.index;
    }

    pub fn freeArray(self: *AstDatastore, idx: u32) !void {
        const arr = self.arrays.get(idx);
        arr.deinit(self.allocator);
        try self.arrays.release(idx, self.allocator);
    }

    pub fn getArray(self: *AstDatastore, idx: u32) *ArrayData {
        return self.arrays.get(idx);
    }

    pub fn internString(self: *AstDatastore, str: []const u8) !StringId {
        return self.strings.intern(str, self.allocator);
    }

    pub fn getString(self: *AstDatastore, idx: u32) []const u8 {
        return self.strings.get(idx);
    }

    pub fn internAndGetString(self: *AstDatastore, str: []const u8) ![]const u8 {
        return self.strings.get(try self.strings.intern(str, self.allocator));
    }

};

pub const DataStore = struct {
    allocator: Allocator,

    params: SlabPool(ParamData, 512),
    classes: SlabPool(ClassData, 256),
    arrays: SlabPool(ArrayData, 128),

    strings: StringPool,
    sources: SourcePool,

    path_to_class: std.AutoHashMapUnmanaged(u64, ClassId),

    pub fn init(allocator: Allocator) !*DataStore {
        const self = try allocator.create(DataStore);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .classes = SlabPool(ClassData, 256).empty,
            .params = SlabPool(ParamData, 512).empty,
            .arrays = SlabPool(ArrayData, 128).empty,
            .strings = StringPool.empty,
            .sources = SourcePool.empty,
            .path_to_class = std.AutoHashMapUnmanaged(u64, ClassId).empty,
        };

        return self;
    }

    pub fn deinit(self: *DataStore) void {
        const array_stats = self.arrays.getStats();
        for (0..array_stats.total_capacity) |i| {
            const idx: u32 = @intCast(i);
            const arr = self.arrays.get(idx);
            if (i < array_stats.used_count) {
                arr.deinit(self.allocator);
            }
        }

        self.classes.deinit(self.allocator);
        self.params.deinit(self.allocator);
        self.arrays.deinit(self.allocator);
        self.strings.deinit(self.allocator);
        self.sources.deinit(self.allocator);  // NEW
        self.path_to_class.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn allocClass(self: *DataStore) !struct { ptr: *ClassData, id: ClassId } {
        const result = try self.classes.acquire(self.allocator);
        const id: ClassId = @enumFromInt(result.index);
        log.debug("DataStore: allocClass id={}", .{id});
        return .{
            .ptr = result.ptr,
            .id = id,
        };
    }

    pub fn freeClass(self: *DataStore, id: ClassId) !void {
        const idx = id.toIndex() orelse return error.InvalidId;
        log.debug("DataStore: freeClass id={}", .{id});
        try self.classes.release(idx, self.allocator);
    }

    pub fn getClass(self: *DataStore, id: ClassId) ?*ClassData {
        const idx = id.toIndex() orelse return null;
        return self.classes.get(idx);
    }

    pub fn allocParam(self: *DataStore) !struct { ptr: *ParamData, id: ParamId } {
        const result = try self.params.acquire(self.allocator);
        const id: ParamId = @enumFromInt(result.index);
        log.debug("DataStore: allocParam id={}", .{id});
        return .{
            .ptr = result.ptr,
            .id = id,
        };
    }

    pub fn freeParam(self: *DataStore, id: ParamId) !void {
        const idx = id.toIndex() orelse return error.InvalidId;
        log.debug("DataStore: freeParam id={}", .{id});
        try self.params.release(idx, self.allocator);
    }

    pub fn getParam(self: *DataStore, id: ParamId) ?*ParamData {
        const idx = id.toIndex() orelse return null;
        return self.params.get(idx);
    }

    pub fn allocArray(self: *DataStore) !u32 {
        const result = try self.arrays.acquire(self.allocator);
        result.ptr.* = ArrayData.empty;
        return result.index;
    }

    pub fn freeArray(self: *DataStore, idx: u32) !void {
        const arr = self.arrays.get(idx);
        arr.deinit(self.allocator);
        try self.arrays.release(idx, self.allocator);
    }

    pub fn getArray(self: *DataStore, idx: u32) *ArrayData {
        return self.arrays.get(idx);
    }

    pub fn internString(self: *DataStore, str: []const u8) !u32 {
        return self.strings.intern(str, self.allocator);
    }

    pub fn getString(self: *DataStore, idx: u32) []const u8 {
        return self.strings.get(idx);
    }

    pub fn internAndGetString(self: *DataStore, str: []const u8) ![]const u8 {
        return self.strings.get(try self.strings.intern(str, self.allocator));
    }

    pub fn getStats(self: *const DataStore) Stats {
        return .{
            .classes = self.classes.getStats(),
            .params = self.params.getStats(),
            .arrays = self.arrays.getStats(),
            .strings_count = self.strings.count(),
            .sources_count = self.sources.sources.items.len,
            .path_lookups = self.path_to_class.count(),
        };
    }

    pub const Stats = struct {
        params: SlabPool(ParamData, 512).Stats,
        classes: SlabPool(ClassData, 256).Stats,
        arrays: SlabPool(ArrayData, 128).Stats,
        strings_count: usize,
        sources_count: usize,
        path_lookups: usize,
    };
};
