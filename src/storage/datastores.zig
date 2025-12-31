const std = @import("std");
const class_mod = @import("../data/class.zig");
const param_mod = @import("../data/param.zig");
const value_mod = @import("../data/value.zig");
const enum_mod = @import("../data/enum.zig");
const id_mod = @import("../core/identifiers.zig");
const pools_mod = @import("../utils/pools.zig");
const source_pool_mod = @import("source_pool.zig");
const log = @import("../utils/log.zig");

const Allocator = std.mem.Allocator;
const ClassId = id_mod.ClassId;
const ParamId = id_mod.ParamId;
const EnumId = id_mod.EnumId;

const StringPool = pools_mod.StringPool;
const SlabPool = pools_mod.SlabPool;
const ClassData = class_mod.ClassData;
const EnumData = enum_mod.EnumData;
const ParamData = param_mod.ParamData;
const ArrayData = value_mod.ArrayData;
const SourcePool = source_pool_mod.SourcePool;
const StringId = id_mod.TypedId();

pub const AstDatastore = struct {
    arrays: SlabPool(ArrayData, 128),
    strings: StringPool,

    pub fn init() !*AstDatastore {
        return .{
            .arrays = SlabPool(ArrayData, 128).empty,
            .strings = StringPool.empty,
        };
    }

    pub fn deinit(self: *AstDatastore, allocator: Allocator) void {
        self.arrays.deinit(allocator);
        self.strings.deinit(allocator);
    }

    pub fn allocArray(self: *AstDatastore, allocator: Allocator) !u32 {
        const result = try self.arrays.acquire(allocator);
        result.ptr.* = ArrayData.empty;
        return result.index;
    }

    pub fn freeArray(self: *AstDatastore, idx: u32, allocator: Allocator) !void {
        const arr = self.arrays.get(idx);
        arr.deinit(allocator);
        try self.arrays.release(idx, allocator);
    }

    pub fn getArray(self: *AstDatastore, idx: u32) *ArrayData {
        return self.arrays.get(idx);
    }

    pub fn internString(self: *AstDatastore, str: []const u8, allocator: Allocator) !StringId {
        return self.strings.intern(str, allocator);
    }

    pub fn getString(self: *AstDatastore, idx: u32) []const u8 {
        return self.strings.get(idx);
    }

    pub fn internAndGetString(self: *AstDatastore, str: []const u8, allocator: Allocator) ![]const u8 {
        return self.strings.get(try self.strings.intern(str, allocator));
    }

};

pub const DataStore = struct {
    params:  SlabPool(ParamData, 512),
    classes: SlabPool(ClassData, 256),
    arrays:  SlabPool(ArrayData, 128),
    enums:   SlabPool(EnumData, 128),

    strings: StringPool,
    sources: SourcePool,

    path_to_class: std.AutoHashMapUnmanaged(u64, ClassId),

    pub fn init() !DataStore {
        return .{
            .classes = SlabPool(ClassData, 256).empty,
            .params = SlabPool(ParamData, 512).empty,
            .arrays = SlabPool(ArrayData, 128).empty,
            .enums = SlabPool(EnumData, 128).empty,
            .strings = StringPool.empty,
            .sources = SourcePool.empty,
            .path_to_class = std.AutoHashMapUnmanaged(u64, ClassId).empty,
        };
    }

    pub fn deinit(self: *DataStore, io: std.Io, allocator: Allocator) void {
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
        self.sources.deinit(io, allocator);
        self.path_to_class.deinit(allocator);
    }

    pub fn allocClass(self: *DataStore, allocator: Allocator) !struct { ptr: *ClassData, id: ClassId } {
        const result = try self.classes.acquire(allocator);
        const id: ClassId = @enumFromInt(result.index);
        log.debug("DataStore: allocClass id={}", .{id});
        return .{
            .ptr = result.ptr,
            .id = id,
        };
    }

    pub fn freeClass(self: *DataStore, id: ClassId, allocator: Allocator) !void {
        const idx = id.toIndex() orelse return error.InvalidId;
        log.debug("DataStore: freeClass id={}", .{id});
        try self.classes.release(idx, allocator);
    }

    pub fn getClass(self: *DataStore, id: ClassId) ?*ClassData {
        const idx = id.toIndex() orelse return null;
        return self.classes.get(idx);
    }

    pub fn allocEnum(self: *DataStore, allocator: Allocator) !struct { ptr: *EnumData, id: EnumId } {
        const result = try self.enums.acquire(allocator);
        const id: EnumId = @enumFromInt(result.index);
        log.debug("DataStore: allocEnum id={}", .{id});
        return .{
            .ptr = result.ptr,
            .id = id,
        };
    }

    pub fn freeEnum(self: *DataStore, id: EnumId, allocator: Allocator) !void {
        const idx = id.toIndex() orelse return error.InvalidId;
        log.debug("DataStore: freeEnum id={}", .{id});
        try self.enums.release(idx, allocator);
    }

    pub fn getEnum(self: *DataStore, id: ParamId) ?*EnumData {
        const idx = id.toIndex() orelse return null;
        return self.enums.get(idx);
    }

    pub fn allocParam(self: *DataStore, allocator: Allocator) !struct { ptr: *ParamData, id: ParamId } {
        const result = try self.params.acquire(allocator);
        const id: ParamId = @enumFromInt(result.index);
        log.debug("DataStore: allocParam id={}", .{id});
        return .{
            .ptr = result.ptr,
            .id = id,
        };
    }

    pub fn freeParam(self: *DataStore, id: ParamId, allocator: Allocator) !void {
        const idx = id.toIndex() orelse return error.InvalidId;
        log.debug("DataStore: freeParam id={}", .{id});
        try self.params.release(idx, allocator);
    }

    pub fn getParam(self: *DataStore, id: ParamId) ?*ParamData {
        const idx = id.toIndex() orelse return null;
        return self.params.get(idx);
    }

    pub fn allocArray(self: *DataStore, allocator: Allocator) !u32 {
        const result = try self.arrays.acquire(allocator);
        result.ptr.* = ArrayData.empty;
        return result.index;
    }

    pub fn freeArray(self: *DataStore, idx: u32, allocator: Allocator) !void {
        const arr = self.arrays.get(idx);
        arr.deinit(allocator);
        try self.arrays.release(idx, allocator);
    }

    pub fn getArray(self: *DataStore, idx: u32) *ArrayData {
        return self.arrays.get(idx);
    }

    pub fn internString(self: *DataStore, str: []const u8, allocator: Allocator) !u32 {
        return self.strings.intern(str, allocator);
    }

    pub fn getString(self: *DataStore, idx: u32) []const u8 {
        return self.strings.get(idx);
    }

    pub fn internAndGetString(self: *DataStore, str: []const u8, allocator: Allocator) ![]const u8 {
        return self.strings.get(try self.strings.intern(str, allocator));
    }

    pub fn getStats(self: *const DataStore) Stats {
        return .{
            .classes = self.classes.getStats(),
            .params = self.params.getStats(),
            .arrays = self.arrays.getStats(),
            .enums = self.enums.getStats(),
            .strings_count = self.strings.count(),
            .sources_count = self.sources.sources.items.len,
            .path_lookups = self.path_to_class.count(),
        };
    }

    pub const Stats = struct {
        params: SlabPool(ParamData, 512).Stats,
        classes: SlabPool(ClassData, 256).Stats,
        arrays: SlabPool(ArrayData, 128).Stats,
        enums: SlabPool(EnumData, 128).Stats,
        strings_count: usize,
        sources_count: usize,
        path_lookups: usize,
    };
};
