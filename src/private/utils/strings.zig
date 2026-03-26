const std         = @import("std");

const Allocator = std.mem.Allocator;

pub fn StringPool(comptime Tid: type) type {
    return comptime struct {
        const Self = @This();
        strings: std.ArrayListUnmanaged([]const u8),
        lookup: std.StringHashMapUnmanaged(Tid),
        free_list: std.ArrayListUnmanaged(Tid),

        pub const empty: Self = .{
            .strings = .empty,
            .lookup = .empty,
            .free_list = .empty
        };

        pub fn deinit(self: *Self, allocator: Allocator) void {
            for (self.strings.items) |str| {
                allocator.free(str);
            }
            self.strings.deinit(allocator);
            self.lookup.deinit(allocator);
            self.free_list.deinit(allocator);
        }

        pub fn intern(self: *Self, allocator: Allocator, str: []const u8) !struct {idx: Tid, str: []const u8} {
            if (self.lookup.get(str)) |idx| {
                return .{ .idx = idx, .str = self.strings.items[idx.toIndex().?] };
            }

            const owned = try allocator.dupe(u8, str);
            errdefer allocator.free(owned);

            const idx: Tid = blk: {
                const i = Tid.fromIndex(self.strings.items.len);
                try self.strings.append(allocator, owned);
                break :blk i;
            };

            try self.lookup.put(allocator, owned, idx);
            return .{ .idx = idx, .str = owned };
        }

        pub fn get(self: *const Self, id: Tid) !?[]const u8 {
            if (!id.isValid()) return error.InvalidId;
            const index = id.toIndex() orelse return null;
            if (index >= self.strings.items.len) return null;
            return self.strings.items[index];
        }

        pub fn get_ptr(self: *const Self, id: Tid) !?*const []const u8 {
            if (!id.isValid()) return error.InvalidId;
            const index = id.toIndex() orelse return null;
            if (index >= self.strings.items.len) return null;
            return &self.strings.items[index];
        }

        pub fn count(self: *const Self) usize {
            return self.strings.items.len - self.free_list.items.len;
        }
    };
}
