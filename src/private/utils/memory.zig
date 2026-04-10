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
            self.slabs.items[slab_idx].data[slot].alive = false;
            self.slabs.items[slab_idx].data[slot].generation +%= 1;
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

        pub fn getConstChecked(self: *const Self, index: Tid) !*const T {
            const idx = index.toIndex() orelse return error.InvalidId;
            if (idx >= self.slabs.items.len * slab_size) return error.InvalidId;
            return &self.slabs.items[idx / slab_size].data[idx % slab_size];
        }

        pub fn getChecked(self: *Self, index: Tid) !*T {
            const idx = index.toIndex() orelse return error.InvalidId;
            if (idx >= self.slabs.items.len * slab_size) return error.InvalidId;
            return &self.slabs.items[idx / slab_size].data[idx % slab_size];
        }

        pub fn forEachLive(self: *Self, ctx: anytype, comptime cb: fn(@TypeOf(ctx), *T) void) void {
            for (self.slabs.items) |slab| {
                var slot: usize = 0;
                while (slot < slab_size) : (slot += 1) {
                    if (slab.used.isSet(slot)) {
                        cb(ctx, &slab.data[slot]);
                    }
                }
            }
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

const identifiers = @import("identifiers.zig");

const TestComponent = struct {
    x: f32, y: f32, z: f32,
    health: i32,
    alive: bool,
    generation: u32 = 1,
};


test "memory: slab pool acquire single item" {
    const Tid = identifiers.TypedId("SlabTest1", .str, *TestComponent, *const TestComponent);
    var pool = SlabPool(TestComponent, Tid, 16).empty;
    defer pool.deinit(std.testing.allocator);

    const result = try pool.acquire(std.testing.allocator);
    try std.testing.expect(result.index.isValid());

    result.ptr.* = .{ .generation = 1, .x = 1.0, .y = 2.0, .z = 3.0, .health = 100, .alive = true };
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result.ptr.x, 0.001);
    try std.testing.expectEqual(@as(i32, 100), result.ptr.health);
}

test "memory: slab pool acquire and get / getConst" {
    const Tid = identifiers.TypedId("SlabTest2", .str, *TestComponent, *const TestComponent);
    var pool = SlabPool(TestComponent, Tid, 16).empty;
    defer pool.deinit(std.testing.allocator);

    const result = try pool.acquire(std.testing.allocator);
    result.ptr.* = .{ .x = 42.0, .y = 0.0, .z = 0.0, .health = 75, .alive = true };

    const gotten = pool.get(result.index);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), gotten.x, 0.001);
    try std.testing.expectEqual(@as(i32, 75), gotten.health);

    const gotten_const = pool.getConst(result.index);
    try std.testing.expectApproxEqAbs(@as(f32, 42.0), gotten_const.x, 0.001);
}

test "memory: slab pool fills first slab and spills into second" {
    const slab_size = 8;
    const Tid = identifiers.TypedId("SlabTest3", .str, *TestComponent, *const TestComponent);
    var pool = SlabPool(TestComponent, Tid, slab_size).empty;
    defer pool.deinit(std.testing.allocator);

    var items: [slab_size + 3]Tid = undefined;
    for (0..slab_size + 3) |i| {
        const r = try pool.acquire(std.testing.allocator);
        r.ptr.health = @intCast(i);
        items[i] = r.index;
    }

    const stats = pool.getStats();
    try std.testing.expect(stats.slab_count >= 2);
    try std.testing.expect(stats.used_count >= slab_size + 3);

    // Data integrity across slab boundary
    for (items, 0..) |idx, i| {
        try std.testing.expectEqual(@as(i32, @intCast(i)), pool.getConst(idx).health);
    }
}

test "memory: slab pool release and reacquire uses free slot" {
    const Tid = identifiers.TypedId("SlabTest4", .str, *TestComponent, *const TestComponent);
    var pool = SlabPool(TestComponent, Tid, 16).empty;
    defer pool.deinit(std.testing.allocator);

    const a = try pool.acquire(std.testing.allocator);
    const b = try pool.acquire(std.testing.allocator);
    _ = try pool.acquire(std.testing.allocator);

    const b_idx = b.index;
    _ = a;
    try pool.release(std.testing.allocator, b_idx);

    const d = try pool.acquire(std.testing.allocator);
    try std.testing.expect(d.index.isValid());
}

test "memory: slab pool getStats — empty pool" {
    const Tid = identifiers.TypedId("SlabTest5", .str, *TestComponent, *const TestComponent);
    var pool = SlabPool(TestComponent, Tid, 4).empty;
    defer pool.deinit(std.testing.allocator);

    const s = pool.getStats();
    try std.testing.expectEqual(@as(usize, 0), s.slab_count);
    try std.testing.expectEqual(@as(usize, 0), s.used_count);
}

test "memory: slab pool getStats — after two acquires" {
    const Tid = identifiers.TypedId("SlabTest6", .str, *TestComponent, *const TestComponent);
    var pool = SlabPool(TestComponent, Tid, 4).empty;
    defer pool.deinit(std.testing.allocator);

    _ = try pool.acquire(std.testing.allocator);
    _ = try pool.acquire(std.testing.allocator);

    const s = pool.getStats();
    try std.testing.expectEqual(@as(usize, 1), s.slab_count);
    try std.testing.expectEqual(@as(usize, 2), s.used_count);
}

test "memory: slab pool - fill entire slab then spill" {
    const slab_size = 4;
    const Tid = identifiers.TypedId("SlabTest7", .str, *TestComponent, *const TestComponent);
    var pool = SlabPool(TestComponent, Tid, slab_size).empty;
    defer pool.deinit(std.testing.allocator);

    // Exactly fill one slab
    for (0..slab_size) |_| _ = try pool.acquire(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), pool.getStats().slab_count);

    // One more spills to slab 2
    _ = try pool.acquire(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), pool.getStats().slab_count);
}

test "memory: slab pool - game entity spawn/despawn wave cycle" {
    // Think: waves of mobs spawning and dying
    const Tid = identifiers.TypedId("SlabTest8", .str, *TestComponent, *const TestComponent);
    var pool = SlabPool(TestComponent, Tid, 64).empty;
    defer pool.deinit(std.testing.allocator);

    var active = std.ArrayList(Tid).empty;
    defer active.deinit(std.testing.allocator);

    for (0..5) |wave| {
        // Spawn 30 monsters this wave
        for (0..30) |i| {
            const m = try pool.acquire(std.testing.allocator);
            m.ptr.* = .{ .x = @floatFromInt(i), .y = @floatFromInt(wave), .z = 0.0, .health = 100, .alive = true };
            try active.append(std.testing.allocator, m.index);
        }
        // Kill the first 15
        for (0..15) |_| {
            const idx = active.orderedRemove(0);
            try pool.release(std.testing.allocator, idx);
        }
    }

    const stats = pool.getStats();
    try std.testing.expect(stats.used_count > 0);
    try std.testing.expect(stats.slab_count > 0);

    for (active.items) |idx| {
        const c = pool.getConst(idx);
        try std.testing.expect(c.alive);
        try std.testing.expect(c.health == 100);
    }
}
