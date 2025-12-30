const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn SlabPool(comptime T: type, comptime slab_size: usize) type {
    return struct {
        const Self = @This();
        const Slab = struct {
            data: [slab_size]T,
            used: std.StaticBitSet(slab_size),
            next_free: ?usize,
        };

        slabs: std.ArrayList(*Slab),
        current_slab: usize,
        free_list: std.ArrayList(FreeSlab),
        total_allocated: usize,

        pub const FreeSlab = struct {
            slab: usize, slot: usize
        };

        pub const empty: Self = .{
            .slabs = std.ArrayList(*Slab).empty,
            .current_slab = 0,
            .free_list = std.ArrayList(FreeSlab).empty,
            .total_allocated = 0,
        };

        pub fn deinit(self: *Self, allocator: Allocator) void {
            for (self.slabs.items) |slab| {
                allocator.destroy(slab);
            }
            self.slabs.deinit(allocator);
            self.free_list.deinit(allocator);
        }

        pub fn acquire(self: *Self, allocator: Allocator) !struct { ptr: *T, index: u32 } {
            if (self.free_list.pop()) |entry| {
                const slab = self.slabs.items[entry.slab];
                slab.used.set(entry.slot);
                const global_idx = entry.slab * slab_size + entry.slot;
                return .{
                    .ptr = &slab.data[entry.slot],
                    .index = @intCast(global_idx),
                };
            }

            for (self.slabs.items, 0..) |slab, slab_idx| {
                if (slab.next_free) |slot| {
                    slab.used.set(slot);

                    slab.next_free = null;
                    for (0..slab_size) |i| {
                        if (!slab.used.isSet(i)) {
                            slab.next_free = i;
                            break;
                        }
                    }
                    const global_idx = slab_idx * slab_size + slot;
                    return .{
                        .ptr = &slab.data[slot],
                        .index = @intCast(global_idx),
                    };
                }
            }

            const new_slab = try allocator.create(Slab);
            new_slab.* = .{
                .data = undefined,
                .used = std.StaticBitSet(slab_size).initEmpty(),
                .next_free = 1,
            };
            try self.slabs.append(allocator, new_slab);

            new_slab.used.set(0);
            self.total_allocated += 1;

            const slab_idx = self.slabs.items.len - 1;
            const global_idx = slab_idx * slab_size;

            return .{
                .ptr = &new_slab.data[0],
                .index = @intCast(global_idx),
            };
        }

        pub fn release(self: *Self, index: u32, allocator: std.mem.Allocator) !void {
            const slab_idx = index / slab_size;
            const slot = index % slab_size;

            const slab = self.slabs.items[slab_idx];
            slab.used.unset(slot);

            if (slab.next_free == null) {
                slab.next_free = slot;
            } else {
                try self.free_list.append(allocator, .{ .slab = slab_idx, .slot = slot });
            }
        }

        pub fn get(self: *Self, index: u32) *T {
            const slab_idx = index / slab_size;
            const slot = index % slab_size;
            return &self.slabs.items[slab_idx].data[slot];
        }

        pub fn getStats(self: *const Self) Stats {
            var used: usize = 0;
            for (self.slabs.items) |slab| {
                used += slab.used.count();
            }

            return .{
                .total_capacity = self.slabs.items.len * slab_size,
                .used_count = used,
                .slab_count = self.slabs.items.len,
            };
        }

        pub const Stats = struct {
            total_capacity: usize,
            used_count: usize,
            slab_count: usize,
        };
    };
}


pub const StringPool = struct {
    strings: std.ArrayList([]const u8),
    lookup:  std.StringHashMapUnmanaged(u32),

    pub const empty: StringPool = .{
        .strings = std.ArrayList([]const u8).empty,
        .lookup = std.StringHashMapUnmanaged(u32).empty,
    };

    pub fn deinit(self: *StringPool, allocator: Allocator) void {
        for (self.strings.items) |str| {
            allocator.free(str);
        }
        self.strings.deinit(allocator);
        self.lookup.deinit(allocator);
    }

    pub fn intern(self: *StringPool, str: []const u8, allocator: Allocator) !u32 {
        if (self.lookup.get(str)) |idx| {
            return idx;
        }

        const idx = @as(u32, @intCast(self.strings.items.len));
        const owned = try allocator.dupe(u8, str);
        try self.strings.append(allocator, owned);
        try self.lookup.put(allocator, owned, idx);
        return idx;
    }

    pub fn get(self: *const StringPool, idx: u32) []const u8 {
        return self.strings.items[idx];
    }

    pub fn count(self: *const StringPool) usize {
        return self.strings.items.len;
    }
};

pub fn ObjectPool(comptime T: type) type {
    return struct {
        const Self = @This();

        arena: std.heap.ArenaAllocator,
        free_objects: std.ArrayList(*T),
        total_allocated: usize,

        pub fn init(child_allocator: Allocator) Self {
            return Self{
                .arena = std.heap.ArenaAllocator.init(child_allocator),
                .free_objects = .empty,
                .total_allocated = 0,
            };
        }

        pub fn deinit(self: *Self, child_allocator: Allocator) void {
            self.free_objects.deinit(child_allocator);
            self.arena.deinit();
        }

        pub fn acquire(self: *Self) !*T {
            if (self.free_objects.pop()) |obj| {
                return obj;
            }
            const obj = try self.arena.allocator().create(T);
            self.total_allocated += 1;
            return obj;
        }

        pub fn release(self: *Self, obj: *T, child_allocator: Allocator) !void {
            try self.free_objects.append(child_allocator, obj);
        }

        pub const Stats = struct { total_allocated: usize, free_count: usize };

        pub fn getStats(self: *const Self) Stats {
            return .{
                .total_allocated = self.total_allocated,
                .free_count = self.free_objects.items.len,
            };
        }
    };
}
