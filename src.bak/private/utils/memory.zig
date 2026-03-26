const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn SlabPool(comptime T: type, comptime slab_size: usize) type {
    return struct {
        slabs: std.ArrayList(*Slab),
        current_slab: usize,
        free_list: std.ArrayList(FreeSlab),
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
            used_count: usize,
            slab_count: usize,
        };

        pub const empty: Self = .{
            .slabs = .empty,
            .current_slab = 0,
            .free_list = .empty,
            .total_allocated = 0
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

        pub fn release(self: *Self, allocator: std.mem.Allocator, index: u32) !void {
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
    };
}

pub fn ObjectPool(comptime T: type) type {
    return struct {
        const Self = @This();

        free_objects: std.ArrayList(*T),
        total_allocated: usize,

        pub const empty: Self = .{
            .free_objects = .empty,
            .total_allocated = 0
        };

        pub fn deinit(self: *Self, arena: *std.heap.ArenaAllocator) void {
            self.free_objects.deinit(arena.child_allocator);
        }

        pub fn acquire(self: *Self, arena: *std.heap.ArenaAllocator) !*T {
            if (self.free_objects.pop()) |obj| {
                return obj;
            }
            const obj = try arena.allocator().create(T);
            self.total_allocated += 1;
            return obj;
        }

        pub fn release(self: *Self, arena: *std.heap.ArenaAllocator, obj: *T) !void {
            try self.free_objects.append(arena.child_allocator, obj);
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

const testing = std.testing;

const U32Pool4 = SlabPool(u32, 4);

test "SlabPool: empty stats are all zero" {
    var pool = U32Pool4.empty;
    defer pool.deinit(testing.allocator);

    const s = pool.getStats();
    try testing.expectEqual(@as(usize, 0), s.slab_count);
    try testing.expectEqual(@as(usize, 0), s.total_capacity);
    try testing.expectEqual(@as(usize, 0), s.used_count);
}

test "SlabPool: first acquire returns index 0" {
    var pool = U32Pool4.empty;
    defer pool.deinit(testing.allocator);

    const r = try pool.acquire(testing.allocator);
    try testing.expectEqual(@as(u32, 0), r.index);
}

test "SlabPool: acquire allocates a new slab when empty" {
    var pool = U32Pool4.empty;
    defer pool.deinit(testing.allocator);

    _ = try pool.acquire(testing.allocator);
    try testing.expectEqual(@as(usize, 1), pool.getStats().slab_count);
}

test "SlabPool: ptr returned by acquire matches get(index)" {
    var pool = U32Pool4.empty;
    defer pool.deinit(testing.allocator);

    const r = try pool.acquire(testing.allocator);
    r.ptr.* = 42;
    try testing.expectEqual(@as(u32, 42), pool.get(r.index).*);
}

test "SlabPool: filling one slab does not allocate a second" {
    var pool = U32Pool4.empty;
    defer pool.deinit(testing.allocator);

    for (0..4) |_| _ = try pool.acquire(testing.allocator);
    try testing.expectEqual(@as(usize, 1), pool.getStats().slab_count);
    try testing.expectEqual(@as(usize, 4), pool.getStats().used_count);
}

test "SlabPool: exceeding slab capacity spills into a second slab" {
    var pool = U32Pool4.empty;
    defer pool.deinit(testing.allocator);

    for (0..5) |_| _ = try pool.acquire(testing.allocator);
    try testing.expectEqual(@as(usize, 2), pool.getStats().slab_count);
    try testing.expectEqual(@as(usize, 8), pool.getStats().total_capacity);
}

test "SlabPool: release decrements used_count" {
    var pool = U32Pool4.empty;
    defer pool.deinit(testing.allocator);

    const r = try pool.acquire(testing.allocator);
    try testing.expectEqual(@as(usize, 1), pool.getStats().used_count);

    try pool.release(r.index, testing.allocator);
    try testing.expectEqual(@as(usize, 0), pool.getStats().used_count);
}

test "SlabPool: slot freed by release is reused on next acquire" {
    var pool = U32Pool4.empty;
    defer pool.deinit(testing.allocator);

    const first = try pool.acquire(testing.allocator);
    const saved_index = first.index;
    try pool.release(first.index, testing.allocator);

    const second = try pool.acquire(testing.allocator);

    try testing.expectEqual(saved_index / 4, second.index / 4);

    try testing.expectEqual(@as(usize, 1), pool.getStats().slab_count);
}

test "SlabPool: acquire–release–acquire cycle keeps used_count correct" {
    var pool = U32Pool4.empty;
    defer pool.deinit(testing.allocator);

    var indices: [4]u32 = undefined;
    for (&indices) |*idx| {
        const r = try pool.acquire(testing.allocator);
        idx.* = r.index;
    }
    try testing.expectEqual(@as(usize, 4), pool.getStats().used_count);

    for (indices) |idx| try pool.release(idx, testing.allocator);
    try testing.expectEqual(@as(usize, 0), pool.getStats().used_count);

    for (0..4) |_| _ = try pool.acquire(testing.allocator);
    try testing.expectEqual(@as(usize, 4), pool.getStats().used_count);

    try testing.expectEqual(@as(usize, 1), pool.getStats().slab_count);
}

test "SlabPool: indices across two slabs are distinct" {
    var pool = U32Pool4.empty;
    defer pool.deinit(testing.allocator);

    var seen = std.AutoHashMap(u32, void).init(testing.allocator);
    defer seen.deinit();

    for (0..8) |_| {
        const r = try pool.acquire(testing.allocator);
        try testing.expect(!seen.contains(r.index));
        try seen.put(r.index, {});
    }
}

test "SlabPool: written values survive across separate get calls" {
    var pool = U32Pool4.empty;
    defer pool.deinit(testing.allocator);

    const r0 = try pool.acquire(testing.allocator);
    const r1 = try pool.acquire(testing.allocator);
    r0.ptr.* = 100;
    r1.ptr.* = 200;

    try testing.expectEqual(@as(u32, 100), pool.get(r0.index).*);
    try testing.expectEqual(@as(u32, 200), pool.get(r1.index).*);
}

test "SlabPool: total_capacity is slab_count × slab_size" {
    var pool = U32Pool4.empty;
    defer pool.deinit(testing.allocator);

    for (0..6) |_| _ = try pool.acquire(testing.allocator);
    const s = pool.getStats();
    try testing.expectEqual(s.slab_count * 4, s.total_capacity);
}

const ObjPool = ObjectPool(u64);

test "ObjectPool: empty stats are zero" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var pool = ObjPool.empty;
    defer pool.deinit(&arena);

    const s = pool.getStats();
    try testing.expectEqual(@as(usize, 0), s.total_allocated);
    try testing.expectEqual(@as(usize, 0), s.free_count);
}

test "ObjectPool: acquire allocates a new object when pool is empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var pool = ObjPool.empty;
    defer pool.deinit(&arena);

    _ = try pool.acquire(&arena);
    try testing.expectEqual(@as(usize, 1), pool.getStats().total_allocated);
}

test "ObjectPool: returned pointer is writable and readable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var pool = ObjPool.empty;
    defer pool.deinit(&arena);

    const obj = try pool.acquire(&arena);
    obj.* = 0xDEAD_BEEF;
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF), obj.*);
}

test "ObjectPool: release adds object to free list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var pool = ObjPool.empty;
    defer pool.deinit(&arena);

    const obj = try pool.acquire(&arena);
    try pool.release(obj, &arena);
    try testing.expectEqual(@as(usize, 1), pool.getStats().free_count);
}

test "ObjectPool: acquire after release reuses freed object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var pool = ObjPool.empty;
    defer pool.deinit(&arena);

    const first = try pool.acquire(&arena);
    const addr = @intFromPtr(first);
    try pool.release(first, &arena);

    const second = try pool.acquire(&arena);

    try testing.expectEqual(addr, @intFromPtr(second));

    try testing.expectEqual(@as(usize, 1), pool.getStats().total_allocated);
}

test "ObjectPool: free_count drops back to zero after re-acquiring" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var pool = ObjPool.empty;
    defer pool.deinit(&arena);

    const obj = try pool.acquire(&arena);
    try pool.release(obj, &arena);
    try testing.expectEqual(@as(usize, 1), pool.getStats().free_count);

    _ = try pool.acquire(&arena);
    try testing.expectEqual(@as(usize, 0), pool.getStats().free_count);
}

test "ObjectPool: multiple objects released are all reused before fresh allocation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var pool = ObjPool.empty;
    defer pool.deinit(&arena);

    var objs: [4]*u64 = undefined;
    for (&objs) |*o| o.* = try pool.acquire(&arena);
    for (objs) |o| try pool.release(o, &arena);

    try testing.expectEqual(@as(usize, 4), pool.getStats().free_count);

    for (0..4) |_| _ = try pool.acquire(&arena);
    try testing.expectEqual(@as(usize, 4), pool.getStats().total_allocated);
    try testing.expectEqual(@as(usize, 0), pool.getStats().free_count);
}

test "ObjectPool: total_allocated grows only on fresh allocations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var pool = ObjPool.empty;
    defer pool.deinit(&arena);

    const a = try pool.acquire(&arena);
    const b = try pool.acquire(&arena);
    try pool.release(a, &arena);
    _ = try pool.acquire(&arena);
    try pool.release(b, &arena);
    _ = try pool.acquire(&arena);

    try testing.expectEqual(@as(usize, 2), pool.getStats().total_allocated);
}