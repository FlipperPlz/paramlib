const std = @import("std");

const Allocator = std.mem.Allocator;
const identifiers = @import("../data/identifiers.zig");

pub const StringPool = struct {
    strings: std.ArrayList([]const u8),
    lookup: std.StringHashMapUnmanaged(identifiers.StringId),
    free_list: std.ArrayListUnmanaged(identifiers.StringId),

    pub const empty: StringPool = .{
        .strings = .empty,
        .lookup = .empty,
        .free_list = .empty
    };

    pub fn deinit(self: *StringPool, allocator: Allocator) void {
        for (self.strings.items) |maybe_str| {
            if (maybe_str) |str| allocator.free(str);
        }
        self.strings.deinit(allocator);
        self.lookup.deinit(allocator);
        self.free_list.deinit(allocator);
    }

    pub fn intern(self: *StringPool, allocator: Allocator, str: []const u8) !struct {idx: identifiers.StringId, str: []const u8} {
        if (self.lookup.get(str)) |idx| {
            return .{ .idx = idx, .str = self.strings.items[idx].? };
        }

        const owned = try allocator.dupe(u8, str);
        errdefer allocator.free(owned);

        const idx: identifiers.StringId = if (self.free_list.pop()) |reused| blk: {
            self.strings.items[reused] = owned;
            break :blk reused;
        } else blk: {
            const i = identifiers.StringId.fromIndex(@intCast(self.strings.items.len));
            if (!i.isValid()) return error.PoolExhausted;
            try self.strings.append(allocator, owned);
            break :blk i;
        };

        try self.lookup.put(allocator, owned, idx);
        return .{ .idx = idx, .str = owned };
    }

    pub fn free(self: *StringPool, allocator: Allocator, id: identifiers.StringId) !void {
        if (!id.isValid()) return error.InvalidId;

        const str = self.strings.items[id] orelse return error.DoubleFree;
        _ = self.lookup.remove(str);
        allocator.free(str);
        self.strings.items[id] = null;
        try self.free_list.append(allocator, id);
    }

    pub fn get(self: *const StringPool, id: identifiers.StringId) !*[]const u8 {
        if (!id.isValid()) return error.InvalidId;
        return &self.strings.items[id] orelse error.StringFreed;
    }

    pub fn count(self: *const StringPool) usize {
        return self.strings.items.len - self.free_list.items.len;
    }
};

pub const StringArena = struct {
    strings: std.ArrayList([]const u8),
    lookup: std.StringHashMapUnmanaged(u32),

    pub const empty: StringArena = .{
        .strings = std.ArrayList([]const u8).empty,
        .lookup = std.StringHashMapUnmanaged(u32).empty,
    };

    pub fn deinit(self: *StringArena, arena: *std.heap.ArenaAllocator) void {
        self.strings.deinit(arena.child_allocator);
        self.lookup.deinit(arena.child_allocator);
    }

    pub fn intern(self: *StringArena, arena: *std.heap.ArenaAllocator, str: []const u8) !u32 {
        if (self.lookup.get(str)) |idx| {
            return idx;
        }

        const idx = @as(u32, @intCast(self.strings.items.len));
        const owned = try arena.allocator().dupe(u8, str);
        try self.strings.append(arena.child_allocator, owned);
        try self.lookup.put(arena.child_allocator, owned, idx);
        return idx;
    }

    pub fn get(self: *const StringArena, idx: u32) []const u8 {
        return self.strings.items[idx];
    }

    pub fn count(self: *const StringArena) usize {
        return self.strings.items.len;
    }
};
