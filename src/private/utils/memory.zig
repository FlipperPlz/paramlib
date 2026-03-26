const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn SlabPool(comptime T: type, comptime Tid: type, comptime slab_size: usize) type {
    return struct {
        slabs:           std.ArrayList(*Slab),
        current_slab:    usize,
        free_list:       std.ArrayList(FreeSlab),
        total_allocated: usize,

        const Self = @This();

        const Slab = struct {
            data: [slab_size]T,
            used: std.StaticBitSet(slab_size),
            next_free: ?usize,
        };

        pub const FreeSlab = struct {
            slab: usize,
            slot: usize
        };

        pub const Stats = struct {
            total_capacity: usize,
            used_count:     usize,
            slab_count:     usize,
        };

        pub const empty: Self = .{
            .slabs           = .empty,
            .current_slab    = 0,
            .free_list       = .empty,
            .total_allocated = 0
        };

        pub fn deinit(self: *Self, allocator: Allocator) void {
            for (self.slabs.items) |slab| {
                allocator.destroy(slab);
            }
            self.slabs.deinit(allocator);
            self.free_list.deinit(allocator);
        }

        pub fn acquire(self: *Self, allocator: Allocator) !struct { ptr: *T, index: Tid } {
            if (self.free_list.pop()) |entry| {
                const slab = self.slabs.items[entry.slab];
                slab.used.set(entry.slot);
                const global_idx = entry.slab * slab_size + entry.slot;
                return .{
                    .ptr = &slab.data[entry.slot],
                    .index = Tid.fromIndex(global_idx),
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
                        .index = Tid.fromIndex(global_idx),
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
                .index = Tid.fromIndex(global_idx),
            };
        }

        pub fn release(self: *Self, allocator: std.mem.Allocator, index: Tid) !void {
            const slab_idx = @intFromEnum(index) / slab_size;
            const slot = @intFromEnum(index) % slab_size;

            const slab = self.slabs.items[slab_idx];
            slab.used.unset(slot);

            if (slab.next_free == null) {
                slab.next_free = slot;
            } else {
                try self.free_list.append(allocator, .{ .slab = slab_idx, .slot = slot });
            }
        }

        pub fn get(self: *Self, index: Tid) *T {
            const slab_idx = @intFromEnum(index) / slab_size;
            const slot = @intFromEnum(index) % slab_size;
            return &self.slabs.items[slab_idx].data[slot];
        }

        pub fn getConst(self: *const Self, index: Tid) *const T {
            const slab_idx = @intFromEnum(index) / slab_size;
            const slot = @intFromEnum(index) % slab_size;
            return &self.slabs.items[slab_idx].data[slot];
        }

        pub fn getStats(self: *const Self) Stats {
            var used: usize = 0;
            for (self.slabs.items) |slab| {
                used += slab.used.count();
            }

            return .{
                .total_capacity = self.slabs.items.len * slab_size,
                .used_count     = used,
                .slab_count     = self.slabs.items.len,
            };
        }
    };
}

pub fn ObjectPool(comptime T: type, comptime Tid: type) type {
    return struct {
        objects:         std.ArrayList(*T),
        free_indices:    std.ArrayList(usize),
        total_allocated: usize,

        const Self = @This();

        pub const Stats = struct {
            total_allocated: usize,
            free_count:      usize,
        };

        pub const empty: Self = .{
            .objects         = .empty,
            .free_indices    = .empty,
            .total_allocated = 0
        };

        pub fn deinit(self: *Self, allocator: Allocator) void {
            for (self.objects.items) |obj| {
                allocator.destroy(obj);
            }
            self.objects.deinit(allocator);
            self.free_indices.deinit(allocator);
        }

        pub fn acquire(self: *Self, allocator: Allocator) !struct { ptr: *T, index: Tid } {
            if (self.free_indices.popOrNull()) |idx| {
                const ptr = self.objects.items[idx];
                return .{
                    .ptr = ptr,
                    .index = Tid.fromIndex(idx),
                };
            }

            const ptr = try allocator.create(T);
            errdefer allocator.destroy(ptr);

            const idx = self.objects.items.len;
            try self.objects.append(allocator, ptr);
            self.total_allocated += 1;

            return .{
                .ptr = ptr,
                .index = Tid.fromIndex(idx),
            };
        }

        pub fn release(self: *Self, allocator: Allocator, index: Tid) !void {
            const idx = @intFromEnum(index);
            try self.free_indices.append(allocator, idx);
        }

        pub fn get(self: *Self, index: Tid) *T {
            const idx = @intFromEnum(index);
            return self.objects.items[idx];
        }

        pub fn getStats(self: *const Self) Stats {
            return .{
                .total_allocated = self.total_allocated,
                .free_count      = self.free_indices.items.len,
            };
        }
    };
}

