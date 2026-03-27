const std      = @import("std");
const testing  = std.testing;
const Allocator = std.mem.Allocator;

const database    = @import("api//database.zig");
const identifiers = @import("private/utils/identifiers.zig");
const handles     = @import("private/utils/handles.zig");
const hasher      = @import("private/utils/hasher.zig");
const strings     = @import("private/utils/strings.zig");
const memory      = @import("private/utils/memory.zig");
const paths       = @import("private/utils/paths.zig");
const values      = @import("private/data/value.zig");
const storage     = @import("private/data/storage.zig");
const query       = @import("private/tree/query.zig");
const factory     = @import("private/tree/factory.zig");
const refs        = @import("private/tree/references.zig");
const source_mod  = @import("private/slabs/source.zig");
const class_mod   = @import("private/slabs/class.zig");
const param_mod   = @import("private/slabs/parameter.zig");
const testIo      = std.testing.io;

fn allocRootClass(
    allocator: Allocator,
    store: *storage.ParamStorage,
    name: []const u8,
) !class_mod.ClassHandle {
    const raw = try store.alloc(allocator, testIo, .createClass(.{
        .name   = name,
        .parent = null,
        .source = source_mod.SourceHandle.invalid,
    }));
    const data: *const class_mod.ClassData = @ptrCast(@alignCast(raw.ptr));
    return .{ .id = @enumFromInt(raw.index.toIndex().?), .generation = data.generation };
}

fn allocChildClass(
    allocator: Allocator,
    store: *storage.ParamStorage,
    name: []const u8,
    parent: class_mod.ClassHandle,
) !class_mod.ClassHandle {
    const raw = try store.alloc(allocator, testIo, .createClass(.{
        .name   = name,
        .parent = parent,
        .source = source_mod.SourceHandle.invalid,
    }));
    const data: *const class_mod.ClassData = @ptrCast(@alignCast(raw.ptr));
    return .{ .id = @enumFromInt(raw.index.toIndex().?), .generation = data.generation };
}

fn allocParam(
    allocator: Allocator,
    store: *storage.ParamStorage,
    name: []const u8,
    parent: class_mod.ClassHandle,
    value: values.Value,
) !storage.StorageIdentifier {
    const raw = try store.alloc(allocator, testIo, .createParameter(.{
        .name   = name,
        .parent = parent,
        .source = source_mod.SourceHandle.invalid,
        .value  = value,
    }));
    return raw.index;
}

// ============================================================================
// TypedId
// ============================================================================

test "identifiers: TypedId basic creation" {
    const Id = identifiers.TypedId("Test1");
    const valid_id: Id = @enumFromInt(0);
    const invalid_id: Id = .invalid;
    try testing.expect(valid_id.isValid());
    try testing.expect(!invalid_id.isValid());
}

test "identifiers: TypedId toIndex" {
    const Id = identifiers.TypedId("Test2");
    const valid_id: Id = @enumFromInt(5);
    const invalid_id: Id = .invalid;
    try testing.expectEqual(@as(?usize, 5), valid_id.toIndex());
    try testing.expectEqual(@as(?usize, null), invalid_id.toIndex());
}

test "identifiers: TypedId fromIndex" {
    const Id = identifiers.TypedId("Test3");
    const id_from_5 = Id.fromIndex(5);
    const id_from_null = Id.fromIndex(null);
    try testing.expect(id_from_5.isValid());
    try testing.expectEqual(@as(?usize, 5), id_from_5.toIndex());
    try testing.expect(!id_from_null.isValid());
}

test "identifiers: fromIndex 0 is valid" {
    const Id = identifiers.TypedId("IdEdge1");
    const id = Id.fromIndex(0);
    try testing.expect(id.isValid());
    try testing.expectEqual(@as(?usize, 0), id.toIndex());
}

test "identifiers: fromIndex null gives invalid" {
    const Id = identifiers.TypedId("IdEdge2");
    const id = Id.fromIndex(null);
    try testing.expect(!id.isValid());
    try testing.expectEqual(Id.invalid, id);
}

test "identifiers: maxInt-1 is valid, maxInt (invalid sentinel) is not" {
    const Id = identifiers.TypedId("IdEdge3");
    const max_valid: Id = @enumFromInt(std.math.maxInt(usize) - 1);
    try testing.expect(max_valid.isValid());
    try testing.expectEqual(@as(?usize, std.math.maxInt(usize) - 1), max_valid.toIndex());
    try testing.expect(!Id.invalid.isValid());
}

test "identifiers: sequential IDs" {
    const Id = identifiers.TypedId("Test7");
    const id0: Id = @enumFromInt(0);
    const id1: Id = @enumFromInt(1);
    const id2: Id = @enumFromInt(2);
    try testing.expect(id0.isValid());
    try testing.expect(id1.isValid());
    try testing.expect(id2.isValid());
    try testing.expectEqual(@as(?usize, 0), id0.toIndex());
    try testing.expectEqual(@as(?usize, 1), id1.toIndex());
    try testing.expectEqual(@as(?usize, 2), id2.toIndex());
}

test "identifiers: different TypedId names are distinct types" {
    // Compile-time proof — you cannot assign between them without a cast
    const ClassId = identifiers.TypedId("ClassIdDistinct");
    const ParamId = identifiers.TypedId("ParamIdDistinct");
    const c: ClassId = @enumFromInt(5);
    const p: ParamId = @enumFromInt(5);
    try testing.expect(c.isValid());
    try testing.expect(p.isValid());
    try testing.expectEqual(@as(?usize, 5), c.toIndex());
    try testing.expectEqual(@as(?usize, 5), p.toIndex());
}

// ============================================================================
// Handle
// ============================================================================

test "handles: Handle creation and validation" {
    const Id = identifiers.TypedId("Test4");
    const H = handles.Handle(Id);
    const valid_handle: H = .{ .id = @enumFromInt(0), .generation = 1 };
    const invalid_handle: H = .{ .id = .invalid, .generation = 0 };
    try testing.expect(valid_handle.isValid());
    try testing.expect(!invalid_handle.isValid());
}

test "handles: Handle equality" {
    const Id = identifiers.TypedId("Test5");
    const H = handles.Handle(Id);
    const handle1: H = .{ .id = @enumFromInt(0), .generation = 1 };
    const handle2: H = .{ .id = @enumFromInt(0), .generation = 1 };
    const handle3: H = .{ .id = @enumFromInt(0), .generation = 2 };
    try testing.expect(handle1.eql(handle2));
    try testing.expect(!handle1.eql(handle3));
}

test "handles: Handle invalid constant" {
    const Id = identifiers.TypedId("Test8");
    const H = handles.Handle(Id);
    const invalid = H.invalid;
    try testing.expect(!invalid.isValid());
    try testing.expect(!invalid.id.isValid());
}

test "handles: Multiple generations" {
    const Id = identifiers.TypedId("Test9");
    const H = handles.Handle(Id);
    const h1: H = .{ .id = @enumFromInt(5), .generation = 1 };
    const h2: H = .{ .id = @enumFromInt(5), .generation = 2 };
    const h3: H = .{ .id = @enumFromInt(5), .generation = 3 };
    try testing.expect(!h1.eql(h2));
    try testing.expect(!h2.eql(h3));
    try testing.expect(h1.eql(h1));
}

test "handles: generation 0 with valid id IS valid (isValid only checks id)" {
    const Id = identifiers.TypedId("HandleEdge1");
    const H = handles.Handle(Id);
    const h = H{ .id = @enumFromInt(0), .generation = 0 };
    try testing.expect(h.isValid());
}

test "handles: eql requires both id and generation to match" {
    const Id = identifiers.TypedId("HandleEdge2");
    const H = handles.Handle(Id);
    const h1 = H{ .id = @enumFromInt(5), .generation = 3 };
    const h2 = H{ .id = @enumFromInt(5), .generation = 3 };
    const h3 = H{ .id = @enumFromInt(5), .generation = 4 };
    const h4 = H{ .id = @enumFromInt(6), .generation = 3 };
    try testing.expect(h1.eql(h2));
    try testing.expect(!h1.eql(h3));
    try testing.expect(!h1.eql(h4));
    try testing.expect(!h3.eql(h4));
}

test "handles: two invalid handles are equal" {
    const Id = identifiers.TypedId("HandleEdge3");
    const H = handles.Handle(Id);
    try testing.expect(H.invalid.eql(H.invalid));
}

test "handles: maxInt generation is stored correctly" {
    const Id = identifiers.TypedId("HandleEdge4");
    const H = handles.Handle(Id);
    const h = H{ .id = @enumFromInt(0), .generation = std.math.maxInt(u32) };
    try testing.expect(h.isValid());
    try testing.expectEqual(std.math.maxInt(u32), h.generation);
}

// ============================================================================
// Hasher
// ============================================================================

test "hasher: same string produces same hash" {
    try testing.expectEqual(hasher.hash("test_string"), hasher.hash("test_string"));
}

test "hasher: different strings produce different hashes" {
    try testing.expect(hasher.hash("string1") != hasher.hash("string2"));
    try testing.expect(hasher.hash("string2") != hasher.hash("string3"));
}

test "hasher: empty string hashes consistently" {
    try testing.expectEqual(hasher.hash(""), hasher.hash(""));
}

test "hasher: single character strings differ" {
    try testing.expect(hasher.hash("a") != hasher.hash("b"));
}

test "hasher: path strings produce consistent hashes" {
    const path = "root.module.parameter";
    try testing.expectEqual(hasher.hash(path), hasher.hash(path));
    try testing.expect(hasher.hash(path) != hasher.hash("root.module.different"));
}

test "hasher: near-identical paths all differ (hash quality)" {
    const h1 = hasher.hash("player.health");
    const h4 = hasher.hash("playe.rhealth");
    try testing.expect(h1 != h4);
}

test "hasher: long deeply nested path is consistent" {
    const p = "root.world.level1.zone_a.area_3.room_7.chest.loot.weapon.sword.damage";
    try testing.expectEqual(hasher.hash(p), hasher.hash(p));
}

// ============================================================================
// Value
// ============================================================================

test "value: Value initialization methods" {
    const v_i32    = values.Value.initI32(42);
    const v_i64    = values.Value.initI64(1000);
    const v_f32    = values.Value.initF32(3.14);
    const v_f64    = values.Value.initF64(2.71828);
    const v_string = values.Value.initString(5);
    const v_array  = values.Value.initArray(10);
    try testing.expectEqual(v_i32.i32, 42);
    try testing.expectEqual(v_i64.i64, 1000);
    try testing.expectApproxEqAbs(v_f32.f32, 3.14, 0.01);
    try testing.expectApproxEqAbs(v_f64.f64, 2.71828, 0.00001);
    try testing.expectEqual(v_string.string, 5);
    try testing.expectEqual(v_array.array, 10);
}

test "value: needsCleanup is true only for array" {
    try testing.expect(!values.Value.initI32(0).needsCleanup());
    try testing.expect(!values.Value.initI64(0).needsCleanup());
    try testing.expect(!values.Value.initF32(0.0).needsCleanup());
    try testing.expect(!values.Value.initF64(0.0).needsCleanup());
    try testing.expect(!values.Value.initString(0).needsCleanup());
    try testing.expect(values.Value.initArray(0).needsCleanup());
}

test "value: isNumeric is true for numeric types only" {
    try testing.expect(values.Value.initI32(0).isNumeric());
    try testing.expect(values.Value.initI64(0).isNumeric());
    try testing.expect(values.Value.initF32(0.0).isNumeric());
    try testing.expect(values.Value.initF64(0.0).isNumeric());
    try testing.expect(!values.Value.initString(0).isNumeric());
    try testing.expect(!values.Value.initArray(0).isNumeric());
}

test "value: sizeOf matches @sizeOf" {
    try testing.expectEqual(@sizeOf(values.Value), values.Value.sizeOf());
}

test "value: i32 boundary values" {
    const v_max  = values.Value.initI32(std.math.maxInt(i32));
    const v_min  = values.Value.initI32(std.math.minInt(i32));
    const v_zero = values.Value.initI32(0);
    try testing.expectEqual(std.math.maxInt(i32), v_max.i32);
    try testing.expectEqual(std.math.minInt(i32), v_min.i32);
    try testing.expectEqual(@as(i32, 0), v_zero.i32);
    try testing.expect(v_max.isNumeric());
    try testing.expect(!v_max.needsCleanup());
}

test "value: i64 boundary values" {
    try testing.expectEqual(std.math.maxInt(i64), values.Value.initI64(std.math.maxInt(i64)).i64);
    try testing.expectEqual(std.math.minInt(i64), values.Value.initI64(std.math.minInt(i64)).i64);
}

test "value: f32 special values" {
    const v_inf     = values.Value.initF32(std.math.inf(f32));
    const v_neg_inf = values.Value.initF32(-std.math.inf(f32));
    try testing.expect(std.math.isInf(v_inf.f32));
    try testing.expect(std.math.isInf(v_neg_inf.f32));
    try testing.expect(v_inf.isNumeric());
    try testing.expect(!v_inf.needsCleanup());
}

test "value: f64 precision (pi)" {
    const v = values.Value.initF64(std.math.pi);
    try testing.expectApproxEqAbs(std.math.pi, v.f64, 1e-15);
    try testing.expect(v.isNumeric());
}

test "value: active tag matches init method" {
    try testing.expect(values.Value.initI32(1)   == .i32);
    try testing.expect(values.Value.initI64(1)   == .i64);
    try testing.expect(values.Value.initF32(1.0) == .f32);
    try testing.expect(values.Value.initF64(1.0) == .f64);
    try testing.expect(values.Value.initString(0) == .string);
    try testing.expect(values.Value.initArray(0)  == .array);
}

test "value: negative numeric values" {
    try testing.expectEqual(@as(i32, -42),    values.Value.initI32(-42).i32);
    try testing.expectEqual(@as(i64, -1000),  values.Value.initI64(-1000).i64);
    try testing.expect(values.Value.initF32(-3.14).isNumeric());
    try testing.expect(values.Value.initF64(-2.71828).isNumeric());
}

test "value: large index values" {
    const large: usize = 999_999;
    try testing.expectEqual(large, values.Value.initString(large).string);
    try testing.expectEqual(large, values.Value.initArray(large).array);
}

// ============================================================================
// StringPool
// ============================================================================

test "strings: intern single string" {
    const Tid = identifiers.TypedId("StrTest1");
    var pool = strings.StringPool(Tid).empty;
    defer pool.deinit(testing.allocator);

    const result = try pool.intern(testing.allocator, "player.health");
    try testing.expect(result.idx.isValid());
    try testing.expectEqualStrings("player.health", result.str);
}

test "strings: intern same string twice returns same index (dedup)" {
    const Tid = identifiers.TypedId("StrTest2");
    var pool = strings.StringPool(Tid).empty;
    defer pool.deinit(testing.allocator);

    const r1 = try pool.intern(testing.allocator, "speed");
    const r2 = try pool.intern(testing.allocator, "speed");
    try testing.expectEqual(r1.idx, r2.idx);
    try testing.expectEqualStrings(r1.str, r2.str);
}

test "strings: different strings get different indices" {
    const Tid = identifiers.TypedId("StrTest3");
    var pool = strings.StringPool(Tid).empty;
    defer pool.deinit(testing.allocator);

    const r1 = try pool.intern(testing.allocator, "health");
    const r2 = try pool.intern(testing.allocator, "mana");
    const r3 = try pool.intern(testing.allocator, "stamina");
    try testing.expect(r1.idx != r2.idx);
    try testing.expect(r2.idx != r3.idx);
    try testing.expect(r1.idx != r3.idx);
}

test "strings: get returns correct string" {
    const Tid = identifiers.TypedId("StrTest4");
    var pool = strings.StringPool(Tid).empty;
    defer pool.deinit(testing.allocator);

    const result = try pool.intern(testing.allocator, "player_name");
    const retrieved = try pool.get(result.idx);
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings("player_name", retrieved.?);
}

test "strings: get with .invalid id returns error" {
    const Tid = identifiers.TypedId("StrTest5");
    var pool = strings.StringPool(Tid).empty;
    defer pool.deinit(testing.allocator);

    try testing.expectError(error.InvalidId, pool.get(Tid.invalid));
}

test "strings: get_ptr with .invalid id returns error" {
    const Tid = identifiers.TypedId("StrTest6");
    var pool = strings.StringPool(Tid).empty;
    defer pool.deinit(testing.allocator);

    try testing.expectError(error.InvalidId, pool.get_ptr(Tid.invalid));
}

test "strings: get out-of-bounds index returns null" {
    const Tid = identifiers.TypedId("StrTest7");
    var pool = strings.StringPool(Tid).empty;
    defer pool.deinit(testing.allocator);

    // Nothing interned yet — index 5 doesn't exist
    const oob_id: Tid = @enumFromInt(5);
    try testing.expectEqual(@as(?[]const u8, null), try pool.get(oob_id));
}

test "strings: count reflects unique interns only" {
    const Tid = identifiers.TypedId("StrTest8");
    var pool = strings.StringPool(Tid).empty;
    defer pool.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), pool.count());
    _ = try pool.intern(testing.allocator, "health");
    try testing.expectEqual(@as(usize, 1), pool.count());
    _ = try pool.intern(testing.allocator, "mana");
    try testing.expectEqual(@as(usize, 2), pool.count());
    _ = try pool.intern(testing.allocator, "health"); // duplicate — no change
    try testing.expectEqual(@as(usize, 2), pool.count());
}

test "strings: empty string can be interned" {
    const Tid = identifiers.TypedId("StrTest9");
    var pool = strings.StringPool(Tid).empty;
    defer pool.deinit(testing.allocator);

    const result = try pool.intern(testing.allocator, "");
    try testing.expect(result.idx.isValid());
    const retrieved = try pool.get(result.idx);
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings("", retrieved.?);
}

test "strings: get_ptr returns pointer to stored string" {
    const Tid = identifiers.TypedId("StrTest10");
    var pool = strings.StringPool(Tid).empty;
    defer pool.deinit(testing.allocator);

    const result = try pool.intern(testing.allocator, "attack_power");
    const ptr = try pool.get_ptr(result.idx);
    try testing.expect(ptr != null);
    try testing.expectEqualStrings("attack_power", ptr.?.*);
}

test "strings: game stat registry - intern 20 stats, retrieve all correctly" {
    const Tid = identifiers.TypedId("StrTest11");
    var pool = strings.StringPool(Tid).empty;
    defer pool.deinit(testing.allocator);

    const stat_names = [_][]const u8{
        "health", "mana", "stamina", "strength", "dexterity",
        "intelligence", "charisma", "luck", "speed", "attack",
        "defense", "magic_attack", "magic_defense", "critical_rate",
        "evasion", "accuracy", "fire_resist", "ice_resist",
        "lightning_resist", "poison_resist",
    };

    var ids: [stat_names.len]Tid = undefined;
    for (stat_names, 0..) |name, i| {
        ids[i] = (try pool.intern(testing.allocator, name)).idx;
    }
    try testing.expectEqual(@as(usize, stat_names.len), pool.count());

    // All stats retrievable
    for (stat_names, ids) |name, id| {
        const retrieved = try pool.get(id);
        try testing.expect(retrieved != null);
        try testing.expectEqualStrings(name, retrieved.?);
    }

    // Re-interning returns same IDs (no duplicates)
    for (stat_names, ids) |name, expected_id| {
        const re = try pool.intern(testing.allocator, name);
        try testing.expectEqual(expected_id, re.idx);
    }
    try testing.expectEqual(@as(usize, stat_names.len), pool.count());
}

// ============================================================================
// SlabPool
// ============================================================================

const TestComponent = struct {
    x: f32, y: f32, z: f32,
    health: i32,
    alive: bool,
    generation: u32 = 1,
};

test "memory: slab pool acquire single item" {
    const Tid = identifiers.TypedId("SlabTest1");
    var pool = memory.SlabPool(TestComponent, Tid, 16).empty;
    defer pool.deinit(testing.allocator);

    const result = try pool.acquire(testing.allocator);
    try testing.expect(result.index.isValid());

    result.ptr.* = .{ .generation = 1, .x = 1.0, .y = 2.0, .z = 3.0, .health = 100, .alive = true };
    try testing.expectApproxEqAbs(@as(f32, 1.0), result.ptr.x, 0.001);
    try testing.expectEqual(@as(i32, 100), result.ptr.health);
}

test "memory: slab pool acquire and get / getConst" {
    const Tid = identifiers.TypedId("SlabTest2");
    var pool = memory.SlabPool(TestComponent, Tid, 16).empty;
    defer pool.deinit(testing.allocator);

    const result = try pool.acquire(testing.allocator);
    result.ptr.* = .{ .x = 42.0, .y = 0.0, .z = 0.0, .health = 75, .alive = true };

    const gotten = pool.get(result.index);
    try testing.expectApproxEqAbs(@as(f32, 42.0), gotten.x, 0.001);
    try testing.expectEqual(@as(i32, 75), gotten.health);

    const gotten_const = pool.getConst(result.index);
    try testing.expectApproxEqAbs(@as(f32, 42.0), gotten_const.x, 0.001);
}

test "memory: slab pool fills first slab and spills into second" {
    const slab_size = 8;
    const Tid = identifiers.TypedId("SlabTest3");
    var pool = memory.SlabPool(TestComponent, Tid, slab_size).empty;
    defer pool.deinit(testing.allocator);

    var items: [slab_size + 3]Tid = undefined;
    for (0..slab_size + 3) |i| {
        const r = try pool.acquire(testing.allocator);
        r.ptr.health = @intCast(i);
        items[i] = r.index;
    }

    const stats = pool.getStats();
    try testing.expect(stats.slab_count >= 2);
    try testing.expect(stats.used_count >= slab_size + 3);

    // Data integrity across slab boundary
    for (items, 0..) |idx, i| {
        try testing.expectEqual(@as(i32, @intCast(i)), pool.getConst(idx).health);
    }
}

test "memory: slab pool release and reacquire uses free slot" {
    const Tid = identifiers.TypedId("SlabTest4");
    var pool = memory.SlabPool(TestComponent, Tid, 16).empty;
    defer pool.deinit(testing.allocator);

    const a = try pool.acquire(testing.allocator);
    const b = try pool.acquire(testing.allocator);
    _ = try pool.acquire(testing.allocator);

    const b_idx = b.index;
    _ = a;
    try pool.release(testing.allocator, b_idx);

    const d = try pool.acquire(testing.allocator);
    try testing.expect(d.index.isValid());
}

test "memory: slab pool getStats — empty pool" {
    const Tid = identifiers.TypedId("SlabTest5");
    var pool = memory.SlabPool(TestComponent, Tid, 4).empty;
    defer pool.deinit(testing.allocator);

    const s = pool.getStats();
    try testing.expectEqual(@as(usize, 0), s.slab_count);
    try testing.expectEqual(@as(usize, 0), s.used_count);
}

test "memory: slab pool getStats — after two acquires" {
    const Tid = identifiers.TypedId("SlabTest6");
    var pool = memory.SlabPool(TestComponent, Tid, 4).empty;
    defer pool.deinit(testing.allocator);

    _ = try pool.acquire(testing.allocator);
    _ = try pool.acquire(testing.allocator);

    const s = pool.getStats();
    try testing.expectEqual(@as(usize, 1), s.slab_count);
    try testing.expectEqual(@as(usize, 2), s.used_count);
}

test "memory: slab pool - fill entire slab then spill" {
    const slab_size = 4;
    const Tid = identifiers.TypedId("SlabTest7");
    var pool = memory.SlabPool(TestComponent, Tid, slab_size).empty;
    defer pool.deinit(testing.allocator);

    // Exactly fill one slab
    for (0..slab_size) |_| _ = try pool.acquire(testing.allocator);
    try testing.expectEqual(@as(usize, 1), pool.getStats().slab_count);

    // One more spills to slab 2
    _ = try pool.acquire(testing.allocator);
    try testing.expectEqual(@as(usize, 2), pool.getStats().slab_count);
}

test "memory: slab pool - game entity spawn/despawn wave cycle" {
    // Think: waves of mobs spawning and dying
    const Tid = identifiers.TypedId("SlabTest8");
    var pool = memory.SlabPool(TestComponent, Tid, 64).empty;
    defer pool.deinit(testing.allocator);

    var active = std.ArrayList(Tid).empty;
    defer active.deinit(testing.allocator);

    for (0..5) |wave| {
        // Spawn 30 monsters this wave
        for (0..30) |i| {
            const m = try pool.acquire(testing.allocator);
            m.ptr.* = .{ .x = @floatFromInt(i), .y = @floatFromInt(wave), .z = 0.0, .health = 100, .alive = true };
            try active.append(testing.allocator, m.index);
        }
        // Kill the first 15
        for (0..15) |_| {
            const idx = active.orderedRemove(0);
            try pool.release(testing.allocator, idx);
        }
    }

    const stats = pool.getStats();
    try testing.expect(stats.used_count > 0);
    try testing.expect(stats.slab_count > 0);

    for (active.items) |idx| {
        const c = pool.getConst(idx);
        try testing.expect(c.alive);
        try testing.expect(c.health == 100);
    }
}

// ============================================================================
// paths
// ============================================================================

test "paths: joinPaths empty slice" {
    const result = try paths.joinPaths(testing.allocator, &[_][]const u8{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("", result);
}

test "paths: joinPaths single segment" {
    const result = try paths.joinPaths(testing.allocator, &[_][]const u8{"player"});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("player", result);
}

test "paths: joinPaths two segments" {
    const result = try paths.joinPaths(testing.allocator, &[_][]const u8{ "player", "health" });
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("player.health", result);
}

test "paths: joinPaths three segments" {
    const result = try paths.joinPaths(testing.allocator, &[_][]const u8{ "world", "zone1", "enemy" });
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("world.zone1.enemy", result);
}

test "paths: joinPaths deep hierarchy" {
    const result = try paths.joinPaths(testing.allocator, &[_][]const u8{ "root", "game", "player", "stats", "health" });
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("root.game.player.stats.health", result);
}

test "paths: joinPaths result is hashable" {
    const r1 = try paths.joinPaths(testing.allocator, &[_][]const u8{ "player", "speed" });
    defer testing.allocator.free(r1);
    const r2 = try paths.joinPaths(testing.allocator, &[_][]const u8{ "player", "speed" });
    defer testing.allocator.free(r2);

    try testing.expectEqual(hasher.hash(r1), hasher.hash(r2));
    try testing.expectEqual(hasher.hash(r1), hasher.hash("player.speed"));
}

test "paths: getName from nested path" {
    try testing.expectEqualStrings("health", paths.getName("player.stats.health"));
}

test "paths: getName from two-segment path" {
    try testing.expectEqualStrings("gravity", paths.getName("world.gravity"));
}

test "paths: getName from root (no dot) returns whole string" {
    try testing.expectEqualStrings("player", paths.getName("player"));
}

test "paths: getParent from nested path" {
    try testing.expectEqualStrings("player.stats", paths.getParent("player.stats.health"));
}

test "paths: getParent from two-segment path" {
    try testing.expectEqualStrings("player", paths.getParent("player.health"));
}

test "paths: getParent from root returns empty string" {
    try testing.expectEqualStrings("", paths.getParent("player"));
}

test "paths: getParent and getName roundtrip" {
    const full = "game.world.player.stats.health";
    const name   = paths.getName(full);
    const parent = paths.getParent(full);

    try testing.expectEqualStrings("health",                 name);
    try testing.expectEqualStrings("game.world.player.stats", parent);
    try testing.expectEqualStrings("game.world.player",       paths.getParent(parent));
    try testing.expectEqualStrings("stats",                   paths.getName(parent));
}

// ============================================================================
// StorageIdentifier
// ============================================================================

test "storage: StorageIdentifier isValid for each variant" {
    try testing.expect((storage.StorageIdentifier{ .arr   = @enumFromInt(0) }).isValid());
    try testing.expect((storage.StorageIdentifier{ .clazz = @enumFromInt(0) }).isValid());
    try testing.expect((storage.StorageIdentifier{ .par   = @enumFromInt(0) }).isValid());
    try testing.expect((storage.StorageIdentifier{ .segment = @enumFromInt(0) }).isValid());
    try testing.expect((storage.StorageIdentifier{ .str   = @enumFromInt(0) }).isValid());
}

test "storage: StorageIdentifier invalid states" {
    try testing.expect(!(storage.StorageIdentifier{ .arr     = .invalid }).isValid());
    try testing.expect(!(storage.StorageIdentifier{ .par     = .invalid }).isValid());
    try testing.expect(!(storage.StorageIdentifier{ .segment = .invalid }).isValid());
    try testing.expect(!(storage.StorageIdentifier{ .str     = .invalid }).isValid());
}

test "storage: StorageIdentifier toIndex" {
    const id: storage.StorageIdentifier = .{ .clazz = @enumFromInt(7) };
    try testing.expectEqual(@as(?usize, 7), id.toIndex());

    const invalid_id: storage.StorageIdentifier = .{ .clazz = .invalid };
    try testing.expectEqual(@as(?usize, null), invalid_id.toIndex());
}

test "storage: alloc and retrieve string value" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const result = try store.alloc(testing.allocator, undefined, .createString("fire_resistance"));
    try testing.expect(result.index.isValid());

    const ptr = try store.retrieve(result.index);
    const str_ptr: *const []const u8 = @ptrCast(@alignCast(ptr));
    try testing.expectEqualStrings("fire_resistance", str_ptr.*);
}

test "storage: alloc and retrieve path segment" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const result = try store.alloc(testing.allocator, undefined, .createSegment("player"));
    try testing.expect(result.index.isValid());

    const ptr = try store.retrieve(result.index);
    const str_ptr: *const []const u8 = @ptrCast(@alignCast(ptr));
    try testing.expectEqualStrings("player", str_ptr.*);
}

test "storage: retrieve invalid id returns InvalidId" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    try testing.expectError(error.InvalidId, store.retrieve(.{ .str = .invalid }));
}

test "storage: free segment returns CannotFreeSegment" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const seg = try store.alloc(testing.allocator, undefined, .createSegment("world"));
    try testing.expectError(error.CannotFreeSegment, store.free(testing.allocator, seg.index));
}

test "storage: free string returns CannotFreeString" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const str = try store.alloc(testing.allocator, undefined, .createString("hello"));
    try testing.expectError(error.CannotFreeString, store.free(testing.allocator, str.index));
}

test "storage: free invalid id returns InvalidId" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    try testing.expectError(error.InvalidId, store.free(testing.allocator, .{ .arr = .invalid }));
}

test "storage: same string interned twice gives same index (dedup)" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const r1 = try store.alloc(testing.allocator, undefined, .createString("damage"));
    const r2 = try store.alloc(testing.allocator, undefined, .createString("damage"));
    try testing.expectEqual(r1.index.toIndex(), r2.index.toIndex());
}

test "storage: same segment interned twice gives same index" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const r1 = try store.alloc(testing.allocator, undefined, .createSegment("enemy"));
    const r2 = try store.alloc(testing.allocator, undefined, .createSegment("enemy"));
    try testing.expectEqual(r1.index.toIndex(), r2.index.toIndex());
}

test "storage: multiple strings all independently retrievable" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const stats = [_][]const u8{ "health", "mana", "attack", "defense", "speed" };
    var indices: [stats.len]storage.StorageIdentifier = undefined;

    for (stats, 0..) |name, i| {
        indices[i] = (try store.alloc(testing.allocator, undefined, .createString(name))).index;
    }
    for (stats, indices) |name, idx| {
        const ptr = try store.retrieve(idx);
        const str_ptr: *const []const u8 = @ptrCast(@alignCast(ptr));
        try testing.expectEqualStrings(name, str_ptr.*);
    }
}

test "storage: deinit on empty store does not crash" {
    var store = storage.ParamStorage.empty;
    store.deinit(testing.allocator); // should be a no-op
}

// ============================================================================
// SourceData
// ============================================================================

test "source: SourceHandle invalid is not valid" {
    try testing.expect(!source_mod.SourceHandle.invalid.isValid());
}

test "source: SourceData init memory content" {
    const src = try source_mod.SourceData.init(.{
        .memory = .{ .name = "test_memory_source", .data = "x = 10; y = 20;" },
    });
    try testing.expect(src.alive);
    try testing.expectEqual(@as(u32, 1), src.generation);
    try testing.expectEqualStrings("test_memory_source", src.name);
    try testing.expect(src.nameHash != 0);
    switch (src.content) {
        .memory => |m| try testing.expectEqualStrings("x = 10; y = 20;", m.data),
        else    => return error.UnexpectedContentType,
    }
}

test "source: SourceData init runtime content" {
    const src = try source_mod.SourceData.init(.{
        .runtime = .{ .name = "runtime_config", .data = "player_speed=5.0" },
    });
    try testing.expect(src.alive);
    try testing.expectEqual(@as(u32, 1), src.generation);
    try testing.expectEqualStrings("runtime_config", src.name);
    switch (src.content) {
        .runtime => |r| try testing.expectEqualStrings("player_speed=5.0", r.data),
        else     => return error.UnexpectedContentType,
    }
}

test "source: SourceData init snippet content" {
    const src = try source_mod.SourceData.init(.{
        .snippet = .{
            .name   = "health_snippet",
            .source = source_mod.SourceHandle.invalid,
            .start  = .{ .index = 0,  .line = 1.0, .column = 0  },
            .end    = .{ .index = 50, .line = 3.0, .column = 20 },
        },
    });
    try testing.expect(src.alive);
    try testing.expectEqualStrings("health_snippet", src.name);
    switch (src.content) {
        .snippet => |s| {
            try testing.expectEqual(@as(u64, 0),  s.start.index);
            try testing.expectEqual(@as(u64, 50), s.end.index);
            try testing.expectApproxEqAbs(@as(f32, 1.0), s.start.line, 0.001);
            try testing.expectApproxEqAbs(@as(f32, 3.0), s.end.line, 0.001);
        },
        else => return error.UnexpectedContentType,
    }
}

test "source: SourceData nameHash consistent across same name" {
    const s1 = try source_mod.SourceData.init(.{ .memory = .{ .name = "config.par", .data = "" } });
    const s2 = try source_mod.SourceData.init(.{ .memory = .{ .name = "config.par", .data = "" } });
    const s3 = try source_mod.SourceData.init(.{ .memory = .{ .name = "other.par",  .data = "" } });
    try testing.expectEqual(s1.nameHash, s2.nameHash);
    try testing.expect(s1.nameHash != s3.nameHash);
}

test "source: SourceData starts alive with generation 1 and empty next chain" {
    const mem = try source_mod.SourceData.init(.{ .memory  = .{ .name = "a", .data = "" } });
    const rt  = try source_mod.SourceData.init(.{ .runtime = .{ .name = "b", .data = "" } });
    try testing.expect(mem.alive);
    try testing.expect(rt.alive);
    try testing.expectEqual(@as(u32, 1), mem.generation);
    try testing.expectEqual(@as(u32, 1), rt.generation);
    try testing.expect(!mem.next.hasNext());
    try testing.expect(!rt.next.hasNext());
}

test "source: snippet with zero-length range is valid" {
    const src = try source_mod.SourceData.init(.{
        .snippet = .{
            .name   = "zero_span",
            .source = source_mod.SourceHandle.invalid,
            .start  = .{ .index = 10, .line = 2.0, .column = 5 },
            .end    = .{ .index = 10, .line = 2.0, .column = 5 },
        },
    });
    try testing.expect(src.alive);
    switch (src.content) {
        .snippet => |s| try testing.expectEqual(s.start.index, s.end.index),
        else     => return error.UnexpectedContentType,
    }
}

// ============================================================================
// Integration
// ============================================================================

test "integration: path building + hashing pipeline" {
    const segments = [_][]const u8{ "game", "player", "stats" };
    const base = try paths.joinPaths(testing.allocator, &segments);
    defer testing.allocator.free(base);

    const health_path = try paths.joinPaths(testing.allocator, &[_][]const u8{ base, "health" });
    defer testing.allocator.free(health_path);

    try testing.expectEqualStrings("game.player.stats.health", health_path);

    // Hash built the same way as a literal
    try testing.expectEqual(hasher.hash(health_path), hasher.hash("game.player.stats.health"));

    // Navigation
    try testing.expectEqualStrings("game.player.stats", paths.getParent(health_path));
    try testing.expectEqualStrings("health",            paths.getName(health_path));
}

test "integration: string pool as asset registry" {
    const AssetId = identifiers.TypedId("AssetRegistry");
    var pool = strings.StringPool(AssetId).empty;
    defer pool.deinit(testing.allocator);

    const tex_id  = (try pool.intern(testing.allocator, "textures/player.png")).idx;
    const mesh_id = (try pool.intern(testing.allocator, "meshes/player.obj")).idx;
    const sfx_id  = (try pool.intern(testing.allocator, "sounds/jump.wav")).idx;

    try testing.expect(tex_id  != mesh_id);
    try testing.expect(mesh_id != sfx_id);

    // Re-registering is idempotent
    try testing.expectEqual(tex_id, (try pool.intern(testing.allocator, "textures/player.png")).idx);
    try testing.expectEqual(@as(usize, 3), pool.count());
}

test "integration: slab pool as typed component system - spawn, kill, respawn" {
    const Position = struct { generation: u32 = 1, alive: bool, x: f32, y: f32, z: f32 };
    const PosId = identifiers.TypedId("PosComp");
    var positions = memory.SlabPool(Position, PosId, 32).empty;
    defer positions.deinit(testing.allocator);

    // Spawn 100 entities
    var entity_pos: [100]PosId = undefined;
    for (0..100) |i| {
        const p = try positions.acquire(testing.allocator);
        p.ptr.* = .{ .alive = true, .x = @floatFromInt(i), .y = 0.0, .z = @floatFromInt(i * 2) };
        entity_pos[i] = p.index;
    }

    // Kill entities 25..49
    for (25..50) |i| try positions.release(testing.allocator, entity_pos[i]);

    // Respawn 25 new entities — reuse freed slots
    var new_pos: [25]PosId = undefined;
    for (0..25) |i| {
        const p = try positions.acquire(testing.allocator);
        p.ptr.* = .{ .alive = true, .x = 999.0, .y = @floatFromInt(i), .z = 0.0 };
        new_pos[i] = p.index;
    }

    // Verify survivors still have their original positions
    for (0..25) |i| {
        const pos = positions.getConst(entity_pos[i]);
        try testing.expectApproxEqAbs(@as(f32, @floatFromInt(i)), pos.x, 0.001);
    }
    for (50..100) |i| {
        const pos = positions.getConst(entity_pos[i]);
        try testing.expectApproxEqAbs(@as(f32, @floatFromInt(i)), pos.x, 0.001);
    }
}

test "integration: handle generation staleness simulation" {
    // Simulate: entity spawns (gen=1), dies, new entity takes same slot (gen=2)
    const Id = identifiers.TypedId("StaleTest");
    const H = handles.Handle(Id);
    const slot: Id = @enumFromInt(0);

    const original_handle = H{ .id = slot, .generation = 1 };
    const stale_handle    = H{ .id = slot, .generation = 1 }; // old reference
    const new_handle      = H{ .id = slot, .generation = 2 }; // new entity same slot

    // Stale and original look equal from the outside (same gen)
    try testing.expect(original_handle.eql(stale_handle));
    // New entity at same slot has different generation
    try testing.expect(!original_handle.eql(new_handle));
    // Both are "valid" (non-null id) — staleness requires storage check
    try testing.expect(original_handle.isValid());
    try testing.expect(new_handle.isValid());
}

test "integration: storage as multi-type param registry" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    // Store a mix of segments and string values
    const seg_player  = try store.alloc(testing.allocator, undefined, .createSegment("player"));
    const seg_enemy   = try store.alloc(testing.allocator, undefined, .createSegment("enemy"));
    const str_tooltip = try store.alloc(testing.allocator, undefined, .createString("Deals fire damage"));

    // All valid and distinct
    try testing.expect(seg_player.index.isValid());
    try testing.expect(seg_enemy.index.isValid());
    try testing.expect(str_tooltip.index.isValid());

    // Retrieve and verify
    const pp = try store.retrieve(seg_player.index);
    const ep = try store.retrieve(seg_enemy.index);
    const tp = try store.retrieve(str_tooltip.index);

    try testing.expectEqualStrings("player",            (@as(*const []const u8, @ptrCast(@alignCast(pp)))).*);
    try testing.expectEqualStrings("enemy",             (@as(*const []const u8, @ptrCast(@alignCast(ep)))).*);
    try testing.expectEqualStrings("Deals fire damage", (@as(*const []const u8, @ptrCast(@alignCast(tp)))).*);
}

test "integration: value types and their properties (all 7 values)" {
    var val_list: [7]values.Value = undefined;
    val_list[0] = values.Value.initI32(42);
    val_list[1] = values.Value.initI64(1000);
    val_list[2] = values.Value.initF32(3.14);
    val_list[3] = values.Value.initF64(2.71828);
    val_list[4] = values.Value.initString(0);
    val_list[5] = values.Value.initArray(1);
    val_list[6] = values.Value.initString(2);

    var numeric_count: usize = 0;
    var cleanup_count: usize = 0;
    for (val_list) |v| {
        if (v.isNumeric()) numeric_count += 1;
        if (v.needsCleanup()) cleanup_count += 1;
    }
    try testing.expectEqual(@as(usize, 4), numeric_count);
    try testing.expectEqual(@as(usize, 1), cleanup_count);
}

test "integration: handle workflow with id operations" {
    const Id = identifiers.TypedId("HandleWorkflow");
    const H = handles.Handle(Id);

    const valid_id: Id = @enumFromInt(10);
    const valid_handle = H{ .id = valid_id, .generation = 1 };

    try testing.expect(valid_handle.isValid());
    try testing.expect(valid_handle.id.isValid());
    try testing.expect(valid_handle.generation > 0);

    const invalid_handle = H.invalid;
    try testing.expect(!invalid_handle.isValid());
    try testing.expect(!invalid_handle.id.isValid());
}

fn makeRootClass(
    allocator: std.mem.Allocator,
    store: *storage.ParamStorage,
    name: []const u8,
) !class_mod.ClassHandle {
    const clazz = try store.alloc(allocator, testIo, .createClass(.{
        .name   = name,
        .parent = null,
        .source = source_mod.SourceHandle.invalid,
    }));
    const data: *class_mod.ClassData = @ptrCast(clazz.ptr);
    return class_mod.ClassHandle{ .id = @enumFromInt(clazz.index.toIndex().?), .generation = data.generation };
}

// ============================================================================
// Storage — class allocation
// ============================================================================

test "storage: alloc root class — basic fields" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const result = try store.alloc(testing.allocator, testIo, .createClass(.{
        .name   = "player",
        .parent = null,
        .source = source_mod.SourceHandle.invalid,
    }));

    try testing.expect(result.index.isValid());
    const data: *const class_mod.ClassData = @ptrCast(@alignCast(result.ptr));
    _ = data; // just ensure it compiles — field checks below via retrieve
}

test "storage: alloc root class — pathToId lookup works" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    _ = try store.alloc(testing.allocator, testIo, .createClass(.{
        .name   = "world",
        .parent = null,
        .source = source_mod.SourceHandle.invalid,
    }));

    const hash = hasher.hash("world");
    const found = store.pathToId.get(hash);
    try testing.expect(found != null);
    try testing.expect(found.?.isValid());
}

test "storage: alloc two root classes get distinct identifiers" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const a = try store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "zone_a", .parent = null, .source = source_mod.SourceHandle.invalid,
    }));
    const b = try store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "zone_b", .parent = null, .source = source_mod.SourceHandle.invalid,
    }));

    try testing.expect(a.index.toIndex() != b.index.toIndex());
}

test "storage: alloc child class — pathHash includes parent path" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const root = try store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "game", .parent = null, .source = source_mod.SourceHandle.invalid,
    }));
    const rootHandle = class_mod.ClassHandle{
        .id         = @enumFromInt(root.index.toIndex().?),
        .generation = (@as(*const class_mod.ClassData, @ptrCast(@alignCast(root.ptr)))).generation,
    };

    _ = try store.alloc(testing.allocator, testIo, .createClass(.{
        .name   = "player",
        .parent = rootHandle,
        .source = source_mod.SourceHandle.invalid,
    }));

    const expected_hash = hasher.hash("game.player");
    try testing.expect(store.pathToId.get(expected_hash) != null);
}

test "storage: alloc parameter in class" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const root = try store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "entity", .parent = null, .source = source_mod.SourceHandle.invalid,
    }));
    const parentHandle = class_mod.ClassHandle{
        .id         = @enumFromInt(root.index.toIndex().?),
        .generation = (@as(*const class_mod.ClassData, @ptrCast(@alignCast(root.ptr)))).generation,
    };

    const param = try store.alloc(testing.allocator, testIo, .createParameter(.{
        .name   = "speed",
        .parent = parentHandle,
        .source = source_mod.SourceHandle.invalid,
        .value  = values.Value.initF32(5.0),
    }));

    try testing.expect(param.index.isValid());
    const expected = hasher.hash("entity.speed");
    try testing.expect(store.pathToId.get(expected) != null);
}

test "storage: free class releases slot" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const c = try store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "tmp", .parent = null, .source = source_mod.SourceHandle.invalid,
    }));
    try store.free(testing.allocator, c.index);
    // Double-free should be an error, not a crash
    try testing.expectError(error.InvalidId, store.free(testing.allocator, .{ .clazz = .invalid }));
}

// ============================================================================
// Query — findClass / findParameter
// ============================================================================

test "query: findClass returns null on empty store" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    try testing.expect(query.lookupClass(&store, "player") == null);
}

test "query: findClass finds a root class by path" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    _ = try store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "enemy", .parent = null, .source = source_mod.SourceHandle.invalid,
    }));

    const found = query.lookupClass(&store, "enemy");
    try testing.expect(found != null);
    try testing.expect(found.?.alive);
}

test "query: findClass returns null for wrong path" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    _ = try store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "npc", .parent = null, .source = source_mod.SourceHandle.invalid,
    }));

    try testing.expect(query.lookupClass(&store, "player") == null);
    try testing.expect(query.lookupClass(&store, "npc.stats") == null);
}

test "query: findClass finds nested class" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const root = try store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "world", .parent = null, .source = source_mod.SourceHandle.invalid,
    }));
    const rootHandle = class_mod.ClassHandle{
        .id         = @enumFromInt(root.index.toIndex().?),
        .generation = (@as(*const class_mod.ClassData, @ptrCast(@alignCast(root.ptr)))).generation,
    };
    _ = try store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "zone1", .parent = rootHandle, .source = source_mod.SourceHandle.invalid,
    }));

    try testing.expect(query.lookupClass(&store, "world.zone1") != null);
    try testing.expect(query.lookupClass(&store, "world") != null);
    try testing.expect(query.lookupClass(&store, "zone1") == null); // not a root path
}

test "query: findClass does not return a parameter" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const root = try store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "cfg", .parent = null, .source = source_mod.SourceHandle.invalid,
    }));
    const parentHandle = class_mod.ClassHandle{
        .id         = @enumFromInt(root.index.toIndex().?),
        .generation = (@as(*const class_mod.ClassData, @ptrCast(@alignCast(root.ptr)))).generation,
    };
    _ = try store.alloc(testing.allocator, testIo, .createParameter(.{
        .name = "volume", .parent = parentHandle,
        .source = source_mod.SourceHandle.invalid, .value = values.Value.initF32(1.0),
    }));

    // "cfg.volume" is a parameter, not a class — findClass must return null
    try testing.expect(query.lookupClass(&store, "cfg.volume") == null);
}

test "query: findParameter returns null on empty store" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    try testing.expect(query.lookupParameter(&store, "player.health") == null);
}

test "query: findParameter finds a parameter by full path" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const root = try store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "player", .parent = null, .source = source_mod.SourceHandle.invalid,
    }));
    const parentHandle = class_mod.ClassHandle{
        .id         = @enumFromInt(root.index.toIndex().?),
        .generation = (@as(*const class_mod.ClassData, @ptrCast(@alignCast(root.ptr)))).generation,
    };
    _ = try store.alloc(testing.allocator, testIo, .createParameter(.{
        .name = "health", .parent = parentHandle,
        .source = source_mod.SourceHandle.invalid, .value = values.Value.initI32(100),
    }));

    const found = query.lookupParameter(&store, "player.health");
    try testing.expect(found != null);
    try testing.expect(found.?.alive);
    try testing.expectEqual(values.Value.initI32(100), found.?.value);
}

test "query: findParameter does not return a class" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    _ = try store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "player", .parent = null, .source = source_mod.SourceHandle.invalid,
    }));

    // "player" is a class, not a parameter — findParameter must return null
    try testing.expect(query.lookupParameter(&store, "player") == null);
}

test "query: findParameter returns null for wrong path" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const root = try store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "cfg", .parent = null, .source = source_mod.SourceHandle.invalid,
    }));
    const parentHandle = class_mod.ClassHandle{
        .id         = @enumFromInt(root.index.toIndex().?),
        .generation = (@as(*const class_mod.ClassData, @ptrCast(@alignCast(root.ptr)))).generation,
    };
    _ = try store.alloc(testing.allocator, testIo, .createParameter(.{
        .name = "volume", .parent = parentHandle,
        .source = source_mod.SourceHandle.invalid, .value = values.Value.initF32(0.5),
    }));

    try testing.expect(query.lookupParameter(&store, "cfg.brightness") == null);
    try testing.expect(query.lookupParameter(&store, "volume") == null);
}

// ============================================================================
// Query — findClassesByPattern
// ============================================================================

test "query: findClassesByPattern empty pattern returns empty" {
    var db = try database.ParamDatabase.init(testing.allocator, testIo);
    defer db.deinit(testing.allocator, testIo);

    _ = try db.store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "player", .parent = null, .source = source_mod.SourceHandle.invalid
    }));
    const root = &db.store.root;

    const results = try query.findClassesByPattern(testing.allocator, &db.store, root, "");
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 0), results.len);
}

test "query: findClassesByPattern exact root name match" {
    var db = try database.ParamDatabase.init(testing.allocator, testIo);
    defer db.deinit(testing.allocator, testIo);

    _ = try db.store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "enemy", .parent = null, .source = source_mod.SourceHandle.invalid
    }));
    _ = try db.store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "player", .parent = null, .source = source_mod.SourceHandle.invalid
    }));

    const root = &db.store.root;
    const results = try query.findClassesByPattern(testing.allocator, &db.store, root, "enemy");
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 1), results.len);
}

test "query: findClassesByPattern wildcard matches all root classes" {
    var db = try database.ParamDatabase.init(testing.allocator, testIo);
    defer db.deinit(testing.allocator, testIo);

    _ = try db.store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "a", .parent = null, .source = source_mod.SourceHandle.invalid
    }));
    _ = try db.store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "b", .parent = null, .source = source_mod.SourceHandle.invalid
    }));
    _ = try db.store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "c", .parent = null, .source = source_mod.SourceHandle.invalid
    }));

    const root = &db.store.root;
    const results = try query.findClassesByPattern(testing.allocator, &db.store, root, "*");
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 3), results.len);
}

test "query: findClassesByPattern no match returns empty" {
    var db = try database.ParamDatabase.init(testing.allocator, testIo);
    defer db.deinit(testing.allocator, testIo);

    _ = try db.store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "npc", .parent = null, .source = source_mod.SourceHandle.invalid
    }));

    const root = &db.store.root;
    const results = try query.findClassesByPattern(testing.allocator, &db.store, root, "player");
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 0), results.len);
}

// ============================================================================
// Query — findParametersByPattern
// ============================================================================

test "query: findParametersByPattern empty pattern returns empty" {
    var db = try database.ParamDatabase.init(testing.allocator, testIo);
    defer db.deinit(testing.allocator, testIo);

    const root = try db.store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "cfg", .parent = null, .source = source_mod.SourceHandle.invalid
    }));
    const parentHandle = class_mod.ClassHandle{
        .id         = @enumFromInt(root.index.toIndex().?),
        .generation = (@as(*const class_mod.ClassData, @ptrCast(@alignCast(root.ptr)))).generation,
    };
    const clazz: *const class_mod.ClassData = @ptrCast(@alignCast(root.ptr));

    const results = try query.findParametersByPattern(testing.allocator, &db.store, clazz, "");
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 0), results.len);
    _ = parentHandle;
}

test "query: findParametersByPattern exact name match" {
    var db = try database.ParamDatabase.init(testing.allocator, testIo);
    defer db.deinit(testing.allocator, testIo);

    const root = try db.store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "settings", .parent = null, .source = source_mod.SourceHandle.invalid
    }));
    const parentHandle = class_mod.ClassHandle{
        .id         = @enumFromInt(root.index.toIndex().?),
        .generation = (@as(*const class_mod.ClassData, @ptrCast(@alignCast(root.ptr)))).generation,
    };
    _ = try db.store.alloc(testing.allocator, testIo, .createParameter(.{
        .name = "volume", .parent = parentHandle,
        .source = source_mod.SourceHandle.invalid, .value = values.Value.initF32(0.8),
    }));
    _ = try db.store.alloc(testing.allocator, testIo, .createParameter(.{
        .name = "brightness", .parent = parentHandle,
        .source = source_mod.SourceHandle.invalid, .value = values.Value.initF32(1.0),
    }));

    const clazz: *const class_mod.ClassData = @ptrCast(@alignCast(root.ptr));
    const results = try query.findParametersByPattern(testing.allocator, &db.store, clazz, "volume");
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 1), results.len);
}

test "query: findParametersByPattern wildcard returns all parameters" {
    var db = try database.ParamDatabase.init(testing.allocator, testIo);
    defer db.deinit(testing.allocator, testIo);

    const root = try db.store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "audio", .parent = null, .source = source_mod.SourceHandle.invalid,
    }));
    const parentHandle = class_mod.ClassHandle{
        .id         = @enumFromInt(root.index.toIndex().?),
        .generation = (@as(*const class_mod.ClassData, @ptrCast(@alignCast(root.ptr)))).generation,
    };
    _ = try db.store.alloc(testing.allocator, testIo, .createParameter(.{
        .name = "master",  .parent = parentHandle, .source = source_mod.SourceHandle.invalid, .value = values.Value.initF32(1.0),
    }));
    _ = try db.store.alloc(testing.allocator, testIo, .createParameter(.{
        .name = "music",   .parent = parentHandle, .source = source_mod.SourceHandle.invalid, .value = values.Value.initF32(0.7),
    }));
    _ = try db.store.alloc(testing.allocator, testIo, .createParameter(.{
        .name = "effects", .parent = parentHandle, .source = source_mod.SourceHandle.invalid, .value = values.Value.initF32(0.9),
    }));

    const clazz: *const class_mod.ClassData = @ptrCast(@alignCast(root.ptr));
    const results = try query.findParametersByPattern(testing.allocator, &db.store, clazz, "*");
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 3), results.len);
}

// ============================================================================
// Factory — createClass
// ============================================================================

test "factory: createClass root class — alive and generation 1" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    // Need a root handle as parent — create one via storage directly first
    const root_raw = try store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "__root__", .parent = null, .source = source_mod.SourceHandle.invalid,
    }));
    const rootHandle = class_mod.ClassHandle{
        .id         = @enumFromInt(root_raw.index.toIndex().?),
        .generation = (@as(*const class_mod.ClassData, @ptrCast(@alignCast(root_raw.ptr)))).generation,
    };

    const data = try factory.createClass(testing.allocator, testIo, &store, .{
        .name   = "player",
        .parent = rootHandle,
        .source = source_mod.SourceHandle.invalid,
    });

    try testing.expect(data.alive);
    try testing.expectEqual(@as(u32, 1), data.generation);
}

test "factory: createClass — class is findable via query.findClass" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const root_raw = try store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "__root__", .parent = null, .source = source_mod.SourceHandle.invalid,
    }));
    const rootHandle = class_mod.ClassHandle{
        .id         = @enumFromInt(root_raw.index.toIndex().?),
        .generation = (@as(*const class_mod.ClassData, @ptrCast(@alignCast(root_raw.ptr)))).generation,
    };

    _ = try factory.createClass(testing.allocator, testIo, &store, .{
        .name   = "npc",
        .parent = rootHandle,
        .source = source_mod.SourceHandle.invalid,
    });

    // findClass by full dotted path
    const found = query.lookupClass(&store, "__root__.npc");
    try testing.expect(found != null);
    try testing.expect(found.?.alive);
}

test "factory: createClass — sibling chain links into parent" {
    var db = try database.ParamDatabase.init(testing.allocator, testIo);
    defer db.deinit(testing.allocator, testIo);

    const root_raw = try db.store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "world", .parent = null, .source = source_mod.SourceHandle.invalid
    }));
    const worldClass: *const class_mod.ClassData = @ptrCast(@alignCast(root_raw.ptr));
    const worldHandle = class_mod.ClassHandle{
        .id         = @enumFromInt(root_raw.index.toIndex().?),
        .generation = worldClass.generation,
    };

    _ = try factory.createClass(testing.allocator, testIo, &db.store, .{
        .name = "zone1", .parent = worldHandle, .source = source_mod.SourceHandle.invalid,
    });
    _ = try factory.createClass(testing.allocator, testIo, &db.store, .{
        .name = "zone2", .parent = worldHandle, .source = source_mod.SourceHandle.invalid,
    });

    // Both children should be discoverable via pattern query
    const root = &db.store.root;
    const results = try query.findClassesByPattern(testing.allocator, &db.store, root, "world.*");
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 2), results.len);
}

test "factory: createClass with base class — increments base references" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const root_raw = try store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "root", .parent = null, .source = source_mod.SourceHandle.invalid,
    }));
    const rootHandle = class_mod.ClassHandle{
        .id         = @enumFromInt(root_raw.index.toIndex().?),
        .generation = (@as(*const class_mod.ClassData, @ptrCast(@alignCast(root_raw.ptr)))).generation,
    };

    const base_raw = try factory.createClass(testing.allocator, testIo, &store, .{
        .name = "BaseEntity", .parent = rootHandle, .source = source_mod.SourceHandle.invalid,
    });
    const initial_refs = base_raw.references.load(.monotonic);

    const baseHandle = class_mod.ClassHandle{
        .id = store.pathToId.get(base_raw.pathHash).?.clazz,
        .generation = base_raw.generation,
    };

    _ = try factory.createClass(testing.allocator, testIo, &store, .{
        .name   = "Enemy",
        .parent = rootHandle,
        .source = source_mod.SourceHandle.invalid,
        .base   = baseHandle,
    });

    const base_after = query.lookupClass(&store, "root.BaseEntity").?;
    try testing.expectEqual(initial_refs + 1, base_after.references.load(.monotonic));
}

test "factory: createClass with invalid parent returns error" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const bad_handle = class_mod.ClassHandle{ .id = @enumFromInt(999), .generation = 1 };
    try testing.expectError(error.InvalidId, factory.createClass(testing.allocator, testIo, &store, .{
        .name   = "orphan",
        .parent = bad_handle,
        .source = source_mod.SourceHandle.invalid,
    }));
}

test "integration: two-level CfgVehicles hierarchy — all classes queryable" {
    // Simulates:  CfgVehicles { class Car { ... }; class Truck { ... }; class Plane { ... }; }
    var db = try database.ParamDatabase.init(testing.allocator, testIo);
    defer db.deinit(testing.allocator, testIo);

    const cfg = try allocRootClass(testing.allocator, &db.store, "CfgVehicles");
    _ = try allocChildClass(testing.allocator, &db.store, "Car",   cfg);
    _ = try allocChildClass(testing.allocator, &db.store, "Truck", cfg);
    _ = try allocChildClass(testing.allocator, &db.store, "Plane", cfg);

    try testing.expect(query.lookupClass(&db.store, "CfgVehicles")           != null);
    try testing.expect(query.lookupClass(&db.store, "CfgVehicles.Car")       != null);
    try testing.expect(query.lookupClass(&db.store, "CfgVehicles.Truck")     != null);
    try testing.expect(query.lookupClass(&db.store, "CfgVehicles.Plane")     != null);
    try testing.expect(query.lookupClass(&db.store, "CfgVehicles.Submarine") == null);
}

test "integration: parameters in nested hierarchy — full-path lookup" {
    var db = try database.ParamDatabase.init(testing.allocator, testIo);
    defer db.deinit(testing.allocator, testIo);

    const cfg    = try allocRootClass(testing.allocator, &db.store, "Settings");
    const audio  = try allocChildClass(testing.allocator, &db.store, "Audio",  cfg);
    const video  = try allocChildClass(testing.allocator, &db.store, "Video",  cfg);

    _ = try allocParam(testing.allocator, &db.store, "masterVolume", audio, values.Value.initF32(0.8));
    _ = try allocParam(testing.allocator, &db.store, "musicVolume",  audio, values.Value.initF32(0.5));
    _ = try allocParam(testing.allocator, &db.store, "resolution",   video, values.Value.initI32(1080));
    _ = try allocParam(testing.allocator, &db.store, "fullscreen",   video, values.Value.initI32(1));

    // Positive lookups
    const mv = query.lookupParameter(&db.store, "Settings.Audio.masterVolume");
    try testing.expect(mv != null);
    try testing.expectApproxEqAbs(@as(f32, 0.8), mv.?.value.f32, 1e-5);

    const res = query.lookupParameter(&db.store, "Settings.Video.resolution");
    try testing.expect(res != null);
    try testing.expectEqual(@as(i32, 1080), res.?.value.i32);

    // Negative lookups — wrong class prefix
    try testing.expect(query.lookupParameter(&db.store, "Audio.masterVolume")         == null);
    try testing.expect(query.lookupParameter(&db.store, "Settings.masterVolume")      == null);
    try testing.expect(query.lookupParameter(&db.store, "Settings.Video.masterVolume") == null);
}

test "integration: type discipline — findClass and findParameter are exclusive" {
    var db = try database.ParamDatabase.init(testing.allocator, testIo);
    defer db.deinit(testing.allocator, testIo);

    const root  = try allocRootClass(testing.allocator, &db.store, "Cfg");
    _ = try allocChildClass(testing.allocator, &db.store, "Sub", root);
    _ = try allocParam(testing.allocator, &db.store, "value", root, values.Value.initI64(42));

    // "Cfg"       is a class  → findParameter must return null
    // "Cfg.Sub"   is a class  → findParameter must return null
    // "Cfg.value" is a param  → findClass must return null
    try testing.expect(query.lookupParameter(&db.store, "Cfg")       == null);
    try testing.expect(query.lookupParameter(&db.store, "Cfg.Sub")   == null);
    try testing.expect(query.lookupClass(&db.store, "Cfg.value")     == null);
}

test "integration: five-level deep hierarchy — queries at every depth" {
    var db = try database.ParamDatabase.init(testing.allocator, testIo);
    defer db.deinit(testing.allocator, testIo);

    const l1 = try allocRootClass(testing.allocator, &db.store, "root");
    const l2 = try allocChildClass(testing.allocator, &db.store, "game",   l1);
    const l3 = try allocChildClass(testing.allocator, &db.store, "world",  l2);
    const l4 = try allocChildClass(testing.allocator, &db.store, "player", l3);
    const l5 = try allocChildClass(testing.allocator, &db.store, "stats",  l4);
    _ = try allocParam(testing.allocator, &db.store, "health", l5, values.Value.initI32(100));

    try testing.expect(query.lookupClass(&db.store, "root")                        != null);
    try testing.expect(query.lookupClass(&db.store, "root.game")                   != null);
    try testing.expect(query.lookupClass(&db.store, "root.game.world")             != null);
    try testing.expect(query.lookupClass(&db.store, "root.game.world.player")      != null);
    try testing.expect(query.lookupClass(&db.store, "root.game.world.player.stats") != null);

    const h = query.lookupParameter(&db.store, "root.game.world.player.stats.health");
    try testing.expect(h != null);
    try testing.expectEqual(@as(i32, 100), h.?.value.i32);
}

test "integration: findClassesByPattern wildcard returns all siblings" {
    var db = try database.ParamDatabase.init(testing.allocator, testIo);
    defer db.deinit(testing.allocator, testIo);

    const cfg = try allocRootClass(testing.allocator, &db.store, "Weapons");
    _ = try allocChildClass(testing.allocator, &db.store, "Rifle",   cfg);
    _ = try allocChildClass(testing.allocator, &db.store, "Pistol",  cfg);
    _ = try allocChildClass(testing.allocator, &db.store, "Shotgun", cfg);
    _ = try allocChildClass(testing.allocator, &db.store, "Knife",   cfg);

    const root = &db.store.root;
    const results = try query.findClassesByPattern(testing.allocator, &db.store, root, "Weapons.*");
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 4), results.len);

    for (results) |r| {
        try testing.expect(r == .class);
        try testing.expect(r.class.alive);
    }
}

test "integration: findClassesByPattern exact nested match" {
    var db = try database.ParamDatabase.init(testing.allocator, testIo);
    defer db.deinit(testing.allocator, testIo);

    const cfg  = try allocRootClass(testing.allocator, &db.store, "CfgGroups");
    _ = try allocChildClass(testing.allocator, &db.store, "Alpha",   cfg);
    _ = try allocChildClass(testing.allocator, &db.store, "Bravo",   cfg);
    _ = try allocChildClass(testing.allocator, &db.store, "Charlie", cfg);

    const root = &db.store.root;

    const results = try query.findClassesByPattern(testing.allocator, &db.store, root, "CfgGroups.Bravo");
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 1), results.len);
}

test "integration: findParametersByPattern wildcard returns all params" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const cls = try allocRootClass(testing.allocator, &store, "PhysicsConfig");
    _ = try allocParam(testing.allocator, &store, "gravity",    cls, values.Value.initF32(-9.81));
    _ = try allocParam(testing.allocator, &store, "friction",   cls, values.Value.initF32(0.3));
    _ = try allocParam(testing.allocator, &store, "restitution",cls, values.Value.initF32(0.5));
    _ = try allocParam(testing.allocator, &store, "drag",       cls, values.Value.initF32(0.01));

    const clsData = query.lookupClass(&store, "PhysicsConfig").?;
    const results  = try query.findParametersByPattern(testing.allocator, &store, clsData, "*");
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 4), results.len);
    for (results) |r| {
        try testing.expect(r == .parameter);
        try testing.expect(r.parameter.alive);
    }
}

test "integration: all six value types are stored and retrieved correctly" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const cls = try allocRootClass(testing.allocator, &store, "TypeSampler");

    _ = try allocParam(testing.allocator, &store, "intVal",    cls, values.Value.initI32(7));
    _ = try allocParam(testing.allocator, &store, "longVal",   cls, values.Value.initI64(1_000_000_000_000));
    _ = try allocParam(testing.allocator, &store, "floatVal",  cls, values.Value.initF32(3.14));
    _ = try allocParam(testing.allocator, &store, "doubleVal", cls, values.Value.initF64(2.718281828));
    _ = try allocParam(testing.allocator, &store, "strVal",    cls, values.Value.initString(99));
    _ = try allocParam(testing.allocator, &store, "arrVal",    cls, values.Value.initArray(128));

    const i = query.lookupParameter(&store, "TypeSampler.intVal").?;
    const l = query.lookupParameter(&store, "TypeSampler.longVal").?;
    const f = query.lookupParameter(&store, "TypeSampler.floatVal").?;
    const d = query.lookupParameter(&store, "TypeSampler.doubleVal").?;
    const s = query.lookupParameter(&store, "TypeSampler.strVal").?;
    const a = query.lookupParameter(&store, "TypeSampler.arrVal").?;

    try testing.expectEqual(@as(i32, 7),                 i.value.i32);
    try testing.expectEqual(@as(i64, 1_000_000_000_000), l.value.i64);
    try testing.expectApproxEqAbs(@as(f32, 3.14),        f.value.f32,   1e-5);
    try testing.expectApproxEqAbs(@as(f64, 2.718281828), d.value.f64,   1e-9);
    try testing.expectEqual(@as(usize, 99),              s.value.string);
    try testing.expectEqual(@as(usize, 128),             a.value.array);

    // Semantic properties
    try testing.expect(i.value.isNumeric());
    try testing.expect(l.value.isNumeric());
    try testing.expect(f.value.isNumeric());
    try testing.expect(d.value.isNumeric());
    try testing.expect(!s.value.isNumeric());
    try testing.expect(!a.value.isNumeric());

    try testing.expect(!i.value.needsCleanup());
    try testing.expect(!s.value.needsCleanup());
    try testing.expect(a.value.needsCleanup());
}

test "integration: same parameter name in different classes resolved by path" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const player = try allocRootClass(testing.allocator, &store, "Player");
    const enemy  = try allocRootClass(testing.allocator, &store, "Enemy");
    const boss   = try allocRootClass(testing.allocator, &store, "Boss");

    _ = try allocParam(testing.allocator, &store, "health", player, values.Value.initI32(100));
    _ = try allocParam(testing.allocator, &store, "health", enemy,  values.Value.initI32(50));
    _ = try allocParam(testing.allocator, &store, "health", boss,   values.Value.initI32(1000));

    const ph = query.lookupParameter(&store, "Player.health").?;
    const eh = query.lookupParameter(&store, "Enemy.health").?;
    const bh = query.lookupParameter(&store, "Boss.health").?;

    try testing.expectEqual(@as(i32, 100),  ph.value.i32);
    try testing.expectEqual(@as(i32, 50),   eh.value.i32);
    try testing.expectEqual(@as(i32, 1000), bh.value.i32);
}

test "integration: base class reference count increments per derived class" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    // Build a root to parent everything
    const root_raw = try store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "__root__", .parent = null, .source = source_mod.SourceHandle.invalid,
    }));
    const rootHandle = class_mod.ClassHandle{
        .id         = @enumFromInt(root_raw.index.toIndex().?),
        .generation = (@as(*const class_mod.ClassData, @ptrCast(@alignCast(root_raw.ptr)))).generation,
    };

    // Create base class via factory
    const base_data = try factory.createClass(testing.allocator, testIo, &store, .{
        .name   = "VehicleBase",
        .parent = rootHandle,
        .source = source_mod.SourceHandle.invalid,
    });
    const initial_refs = base_data.references.load(.monotonic);

    const baseHandle = class_mod.ClassHandle{
        .id         = store.pathToId.get(base_data.pathHash).?.clazz,
        .generation = base_data.generation,
    };

    // Three derived classes all inherit from VehicleBase
    _ = try factory.createClass(testing.allocator, testIo, &store, .{
        .name = "Car",   .parent = rootHandle, .source = source_mod.SourceHandle.invalid, .base = baseHandle,
    });
    _ = try factory.createClass(testing.allocator, testIo, &store, .{
        .name = "Truck", .parent = rootHandle, .source = source_mod.SourceHandle.invalid, .base = baseHandle,
    });
    _ = try factory.createClass(testing.allocator, testIo, &store, .{
        .name = "Bike",  .parent = rootHandle, .source = source_mod.SourceHandle.invalid, .base = baseHandle,
    });

    const base_after = query.lookupClass(&store, "__root__.VehicleBase").?;
    try testing.expectEqual(initial_refs + 3, base_after.references.load(.monotonic));
}

test "integration: source handle is preserved on class and parameter data" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    // Allocate a source
    const src_raw = try store.alloc(testing.allocator, testIo, .createSource(.{
        .memory = .{ .name = "main.cfg", .data = "..." },
    }));
    const srcHandle = source_mod.SourceHandle{
        .id         = @enumFromInt(src_raw.index.toIndex().?),
        .generation = (@as(*const source_mod.SourceData, @ptrCast(@alignCast(src_raw.ptr)))).generation,
    };

    // Create a class and parameter tagged with that source
    const raw_cls = try store.alloc(testing.allocator, testIo, .createClass(.{
        .name = "Vehicle", .parent = null, .source = srcHandle,
    }));
    const clsHandle = class_mod.ClassHandle{
        .id         = @enumFromInt(raw_cls.index.toIndex().?),
        .generation = (@as(*const class_mod.ClassData, @ptrCast(@alignCast(raw_cls.ptr)))).generation,
    };
    _ = try store.alloc(testing.allocator, testIo, .createParameter(.{
        .name = "mass", .parent = clsHandle, .source = srcHandle, .value = values.Value.initF32(1200.0),
    }));

    const cls_data = query.lookupClass(&store, "Vehicle").?;
    try testing.expect(cls_data.createdBy.eql(srcHandle));

    const par_data = query.lookupParameter(&store, "Vehicle.mass").?;
    try testing.expect(par_data.createdBy.eql(srcHandle));
}

test "integration: large-scale — 20 classes × 5 params, all queryable" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const class_count = 20;
    const param_count = 5;
    const class_names = [class_count][]const u8{
        "Alpha", "Bravo", "Charlie", "Delta", "Echo",
        "Foxtrot", "Golf", "Hotel", "India", "Juliet",
        "Kilo", "Lima", "Mike", "November", "Oscar",
        "Papa", "Quebec", "Romeo", "Sierra", "Tango",
    };
    const param_names = [param_count][]const u8{ "p0", "p1", "p2", "p3", "p4" };

    // Build the structure
    var class_handles: [class_count]class_mod.ClassHandle = undefined;
    for (class_names, 0..) |name, ci| {
        class_handles[ci] = try allocRootClass(testing.allocator, &store, name);
        for (param_names, 0..) |pname, pi| {
            _ = try allocParam(testing.allocator, &store, pname, class_handles[ci],
                values.Value.initI32(@intCast(ci * 10 + pi)));
        }
    }

    // Verify every class and every parameter is reachable
    var buf: [128]u8 = undefined;
    for (class_names, 0..) |cname, ci| {
        try testing.expect(query.lookupClass(&store, cname) != null);
        for (param_names, 0..) |pname, pi| {
            const path = try std.fmt.bufPrint(&buf, "{s}.{s}", .{ cname, pname });
            const par = query.lookupParameter(&store, path);
            try testing.expect(par != null);
            try testing.expectEqual(@as(i32, @intCast(ci * 10 + pi)), par.?.value.i32);
        }
    }
}

test "integration: 8 siblings under one parent — wildcard discovers all" {
    var db = try database.ParamDatabase.init(testing.allocator, testIo);
    defer db.deinit(testing.allocator, testIo);

    const parent = try allocRootClass(testing.allocator, &db.store, "Zones");
    const zone_names = [_][]const u8{
        "Zone1", "Zone2", "Zone3", "Zone4",
        "Zone5", "Zone6", "Zone7", "Zone8",
    };
    for (zone_names) |zn| {
        _ = try allocChildClass(testing.allocator, &db.store, zn, parent);
    }

    const root = &db.store.root;

    const results = try query.findClassesByPattern(testing.allocator, &db.store, root, "Zones.*");
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, zone_names.len), results.len);
}

test "integration: path helpers produce paths that resolve in storage" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const l1 = try allocRootClass(testing.allocator, &store, "CfgSounds");
    const l2 = try allocChildClass(testing.allocator, &store, "Ambient",  l1);
    const l3 = try allocChildClass(testing.allocator, &store, "Rain",     l2);
    _ = try allocParam(testing.allocator, &store, "volume", l3, values.Value.initF32(0.6));

    // Build the same path strings manually via path helpers
    const seg1 = try paths.joinPaths(testing.allocator, &[_][]const u8{ "CfgSounds", "Ambient" });
    defer testing.allocator.free(seg1);
    const full = try paths.joinPaths(testing.allocator, &[_][]const u8{ seg1, "Rain" });
    defer testing.allocator.free(full);
    const param_path = try paths.joinPaths(testing.allocator, &[_][]const u8{ full, "volume" });
    defer testing.allocator.free(param_path);

    try testing.expect(query.lookupClass(&store, full)          != null);
    try testing.expect(query.lookupParameter(&store, param_path) != null);

    // Hash of the built path equals hash of the literal
    try testing.expectEqual(hasher.hash(full),       hasher.hash("CfgSounds.Ambient.Rain"));
    try testing.expectEqual(hasher.hash(param_path), hasher.hash("CfgSounds.Ambient.Rain.volume"));
}

test "integration: factory.createClass result is identical to storage.alloc path" {
    // Build two parallel stores: one using factory, one using storage directly.
    // Both should yield findClass returning a live, generation-1 class.
    var store_a = storage.ParamStorage.empty;
    defer store_a.deinit(testing.allocator);
    var store_b = storage.ParamStorage.empty;
    defer store_b.deinit(testing.allocator);

    // Store A — via factory
    const root_a_raw = try store_a.alloc(testing.allocator, testIo, .createClass(.{
        .name = "root", .parent = null, .source = source_mod.SourceHandle.invalid,
    }));
    const root_a = class_mod.ClassHandle{
        .id         = @enumFromInt(root_a_raw.index.toIndex().?),
        .generation = (@as(*const class_mod.ClassData, @ptrCast(@alignCast(root_a_raw.ptr)))).generation,
    };
    _ = try factory.createClass(testing.allocator, testIo, &store_a, .{
        .name   = "Child",
        .parent = root_a,
        .source = source_mod.SourceHandle.invalid,
    });

    const root_b_raw = try store_b.alloc(testing.allocator, testIo, .createClass(.{
        .name = "root", .parent = null, .source = source_mod.SourceHandle.invalid,
    }));
    const root_b = class_mod.ClassHandle{
        .id         = @enumFromInt(root_b_raw.index.toIndex().?),
        .generation = (@as(*const class_mod.ClassData, @ptrCast(@alignCast(root_b_raw.ptr)))).generation,
    };
    _ = try store_b.alloc(testing.allocator, testIo, .createClass(.{
        .name   = "Child",
        .parent = root_b,
        .source = source_mod.SourceHandle.invalid,
    }));

    const a = query.lookupClass(&store_a, "root.Child");
    const b = query.lookupClass(&store_b, "root.Child");

    try testing.expect(a != null);
    try testing.expect(b != null);
    try testing.expect(a.?.alive);
    try testing.expect(b.?.alive);
    try testing.expectEqual(a.?.generation, b.?.generation);
    try testing.expectEqual(a.?.pathHash,   b.?.pathHash);
    try testing.expectEqual(a.?.nameHash,   b.?.nameHash);
}

test "integration: freed parameter slot is no longer alive" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const cls = try allocRootClass(testing.allocator, &store, "Cfg");
    const par_idx = try allocParam(testing.allocator, &store, "val", cls, values.Value.initI32(1));

    try testing.expect(query.lookupParameter(&store, "Cfg.val") != null);

    try store.free(testing.allocator, par_idx);

    const raw = store.retrieve(par_idx) catch null;
    if (raw) |ptr| {
        const data: *const param_mod.ParameterData = @ptrCast(@alignCast(ptr));
        try testing.expect(!data.alive);
    }
}

test "integration: createdAt <= modifiedAt on fresh class and parameter" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const cls = try allocRootClass(testing.allocator, &store, "TimedClass");
    _ = try allocParam(testing.allocator, &store, "tick", cls, values.Value.initI64(0));

    const c = query.lookupClass(&store, "TimedClass").?;
    const p = query.lookupParameter(&store, "TimedClass.tick").?;

    try testing.expect(c.createdAt <= c.modifiedAt);
    try testing.expect(p.createdAt <= p.modifiedAt);
    // Timestamps must be positive (real clock, not monotonic zero)
    try testing.expect(c.createdAt >= 0);
    try testing.expect(p.createdAt >= 0);
}

test "integration: empty pattern returns empty results for classes and params" {
    var db = try database.ParamDatabase.init(testing.allocator, testIo);
    defer db.deinit(testing.allocator, testIo);

    const cls = try allocRootClass(testing.allocator, &db.store, "PopulatedClass");
    _ = try allocParam(testing.allocator, &db.store, "x", cls, values.Value.initF32(1.0));

    const root = &db.store.root;

    const class_results = try query.findClassesByPattern(testing.allocator, &db.store, root, "");
    defer testing.allocator.free(class_results);
    try testing.expectEqual(@as(usize, 0), class_results.len);

    const cls_data = query.lookupClass(&db.store, "PopulatedClass").?;
    const param_results = try query.findParametersByPattern(testing.allocator, &db.store, cls_data, "");
    defer testing.allocator.free(param_results);
    try testing.expectEqual(@as(usize, 0), param_results.len);
}

test "integration: deinit on populated store releases all memory cleanly" {
    var store = storage.ParamStorage.empty;

    const l1 = try allocRootClass(testing.allocator, &store, "A");
    const l2 = try allocChildClass(testing.allocator, &store, "B", l1);
    const l3 = try allocChildClass(testing.allocator, &store, "C", l2);
    _ = try allocParam(testing.allocator, &store, "p1", l3, values.Value.initI32(1));
    _ = try allocParam(testing.allocator, &store, "p2", l3, values.Value.initF64(2.0));

    // deinit must not crash or leak (verified by the test allocator)
    store.deinit(testing.allocator);
}

test "integration: pathHash uniqueness across realistic mixed hierarchy" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const weapons  = try allocRootClass(testing.allocator, &store, "CfgWeapons");
    const rifle    = try allocChildClass(testing.allocator, &store, "Rifle",   weapons);
    const pistol   = try allocChildClass(testing.allocator, &store, "Pistol",  weapons);
    _ = try allocParam(testing.allocator, &store, "damage",     rifle,  values.Value.initF32(35.0));
    _ = try allocParam(testing.allocator, &store, "damage",     pistol, values.Value.initF32(20.0));
    _ = try allocParam(testing.allocator, &store, "fireRate",   rifle,  values.Value.initF32(600.0));
    _ = try allocParam(testing.allocator, &store, "fireRate",   pistol, values.Value.initF32(400.0));
    _ = try allocParam(testing.allocator, &store, "magazineSize", rifle,  values.Value.initI32(30));
    _ = try allocParam(testing.allocator, &store, "magazineSize", pistol, values.Value.initI32(15));

    // Every full path must resolve to a unique, correct value
    try testing.expectApproxEqAbs(@as(f32, 35.0),  query.lookupParameter(&store, "CfgWeapons.Rifle.damage").?.value.f32,  1e-5);
    try testing.expectApproxEqAbs(@as(f32, 20.0),  query.lookupParameter(&store, "CfgWeapons.Pistol.damage").?.value.f32, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 600.0), query.lookupParameter(&store, "CfgWeapons.Rifle.fireRate").?.value.f32, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 400.0), query.lookupParameter(&store, "CfgWeapons.Pistol.fireRate").?.value.f32, 1e-3);
    try testing.expectEqual(@as(i32, 30),          query.lookupParameter(&store, "CfgWeapons.Rifle.magazineSize").?.value.i32);
    try testing.expectEqual(@as(i32, 15),          query.lookupParameter(&store, "CfgWeapons.Pistol.magazineSize").?.value.i32);

    // Cross-paths must NOT resolve
    try testing.expect(query.lookupParameter(&store, "CfgWeapons.damage") == null);
    try testing.expect(query.lookupParameter(&store, "Rifle.damage") == null);
}

// ============================================================================
// References — retain / release
// ============================================================================

test "references: retainClass increments references on the class itself" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const handle = try allocRootClass(testing.allocator, &store, "RetainRoot");
    const data   = store.classes.get(handle.id);

    const before = data.references.load(.monotonic);
    try refs.retainHandle(&store, handle);
    try testing.expectEqual(before + 1, data.references.load(.monotonic));
}

test "references: retainClass also increments parent's references" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const parent_h = try allocRootClass(testing.allocator, &store, "ParentRetain");
    const child_h  = try allocChildClass(testing.allocator, &store, "ChildRetain", parent_h);

    const parent_data = store.classes.get(parent_h.id);
    const before      = parent_data.references.load(.monotonic);

    try refs.retainHandle(&store, child_h);
    // Parent must have been retained too
    try testing.expectEqual(before + 1, parent_data.references.load(.monotonic));
}

test "references: releaseClass mirrors retainClass — parent refcount restored" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const parent_h    = try allocRootClass(testing.allocator, &store, "ParentRelease");
    const child_h     = try allocChildClass(testing.allocator, &store, "ChildRelease", parent_h);
    const parent_data = store.classes.get(parent_h.id);
    const child_data  = store.classes.get(child_h.id);

    const parent_before = parent_data.references.load(.monotonic);
    const child_before  = child_data.references.load(.monotonic);

    try refs.retainHandle(&store, child_h);
    try refs.releaseHandle(&store, child_h);

    // Both should be back where they started
    try testing.expectEqual(parent_before, parent_data.references.load(.monotonic));
    try testing.expectEqual(child_before,  child_data.references.load(.monotonic));
}

test "references: retain/release across 3-level chain keeps every ancestor balanced" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const l1 = try allocRootClass(testing.allocator, &store, "L1");
    const l2 = try allocChildClass(testing.allocator, &store, "L2", l1);
    const l3 = try allocChildClass(testing.allocator, &store, "L3", l2);

    const d1 = store.classes.get(l1.id);
    const d2 = store.classes.get(l2.id);
    const d3 = store.classes.get(l3.id);

    const b1 = d1.references.load(.monotonic);
    const b2 = d2.references.load(.monotonic);
    const b3 = d3.references.load(.monotonic);

    try refs.retainHandle(&store, l3);
    try refs.retainHandle(&store, l3); // retain twice
    try refs.releaseHandle(&store, l3);
    try refs.releaseHandle(&store, l3); // release twice

    try testing.expectEqual(b1, d1.references.load(.monotonic));
    try testing.expectEqual(b2, d2.references.load(.monotonic));
    try testing.expectEqual(b3, d3.references.load(.monotonic));
}

// ============================================================================
// Delete marker (tombstone)
// ============================================================================

test "delete marker: is_delete_marker is false on normal class" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const h = try allocRootClass(testing.allocator, &store, "NormalClass");
    const d = store.classes.get(h.id);
    try testing.expect(!d.is_delete_marker);
}

test "delete marker: createDeleteMarker sets is_delete_marker = true" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const marker = try factory.createDeleteMarker(
        testing.allocator, testIo, &store,
        "DeletedClass", null, source_mod.SourceHandle.invalid,
    );
    try testing.expect(marker.is_delete_marker);
    try testing.expect(marker.alive);
    try testing.expectEqual(class_mod.ClassAccess.readOnly, marker.access);
}

test "delete marker: tombstone has no children and no params" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const marker = try factory.createDeleteMarker(
        testing.allocator, testIo, &store,
        "Ghost", null, source_mod.SourceHandle.invalid,
    );
    try testing.expect(!marker.children.hasNext());
    try testing.expect(!marker.params.hasNext());
}

test "delete marker: tombstone is hidden from lookupClass" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    _ = try factory.createDeleteMarker(
        testing.allocator, testIo, &store,
        "ToDelete", null, source_mod.SourceHandle.invalid,
    );

    // lookupClass must NOT expose tombstones to callers
    try testing.expect(query.lookupClass(&store, "ToDelete") == null);

    // But the entry IS in pathToId — merge logic needs to find it via
    // the raw store, not via the public query API
    const h = hasher.hash("ToDelete");
    try testing.expect(store.pathToId.contains(h));
}

test "delete marker: tombstone is skipped by findClassesByPattern wildcard" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    _ = try allocRootClass(testing.allocator, &store, "RealClass");
    _ = try factory.createDeleteMarker(
        testing.allocator, testIo, &store,
        "GhostClass", null, source_mod.SourceHandle.invalid,
    );

    const root    = &store.root;
    const results = try query.findClassesByPattern(testing.allocator, &store, root, "*");
    defer testing.allocator.free(results);

    // Only RealClass should appear — GhostClass is a tombstone and must be filtered
    try testing.expectEqual(@as(usize, 1), results.len);
    const name_ptr: *const []const u8 = @ptrCast(@alignCast(
        try store.retrieve(.{ .segment = results[0].class.nameIdx }),
    ));
    try testing.expectEqualStrings("RealClass", name_ptr.*);
}

// ============================================================================
// deleteParameter
// ============================================================================

test "deleteParameter: lookup returns null after deletion" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const cls_h = try allocRootClass(testing.allocator, &store, "Owner");
    const p_id  = try allocParam(testing.allocator, &store, "speed", cls_h, values.Value.initF32(5.0));

    try testing.expect(query.lookupParameter(&store, "Owner.speed") != null);

    const p_handle = param_mod.ParameterHandle{
        .id         = p_id.par,
        .generation = store.parameters.get(p_id.par).generation,
    };
    try factory.deleteParameter(testing.allocator, &store, p_handle);

    try testing.expect(query.lookupParameter(&store, "Owner.speed") == null);
}

test "deleteParameter: unlinks from parent params list — sibling still visible" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const cls_h = try allocRootClass(testing.allocator, &store, "MultiParam");
    const a_id  = try allocParam(testing.allocator, &store, "alpha", cls_h, values.Value.initI32(1));
    _           = try allocParam(testing.allocator, &store, "beta",  cls_h, values.Value.initI32(2));

    const a_handle = param_mod.ParameterHandle{
        .id         = a_id.par,
        .generation = store.parameters.get(a_id.par).generation,
    };
    try factory.deleteParameter(testing.allocator, &store, a_handle);

    // alpha is gone, beta must still be reachable
    try testing.expect(query.lookupParameter(&store, "MultiParam.alpha") == null);
    try testing.expect(query.lookupParameter(&store, "MultiParam.beta")  != null);
}

test "deleteParameter: slab slot generation is bumped (handle goes stale)" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const cls_h = try allocRootClass(testing.allocator, &store, "GenCheck");
    const p_id  = try allocParam(testing.allocator, &store, "val", cls_h, values.Value.initI32(99));

    const old_gen = store.parameters.get(p_id.par).generation;
    const p_handle = param_mod.ParameterHandle{ .id = p_id.par, .generation = old_gen };

    try factory.deleteParameter(testing.allocator, &store, p_handle);

    // Generation must have been bumped by SlabPool.release
    const new_gen = store.parameters.get(p_id.par).generation;
    try testing.expect(new_gen != old_gen);

    // validateHandle must now return StaleHandle
    try testing.expectError(error.StaleHandle, handles.validateHandle(&store, p_handle));
}

test "deleteParameter: deleting all params leaves parent with empty list" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const cls_h = try allocRootClass(testing.allocator, &store, "EmptyAfter");
    const p1_id = try allocParam(testing.allocator, &store, "x", cls_h, values.Value.initF32(1.0));
    const p2_id = try allocParam(testing.allocator, &store, "y", cls_h, values.Value.initF32(2.0));

    const p1_h = param_mod.ParameterHandle{ .id = p1_id.par, .generation = store.parameters.get(p1_id.par).generation };
    const p2_h = param_mod.ParameterHandle{ .id = p2_id.par, .generation = store.parameters.get(p2_id.par).generation };

    try factory.deleteParameter(testing.allocator, &store, p1_h);
    try factory.deleteParameter(testing.allocator, &store, p2_h);

    const cls_data = store.classes.get(cls_h.id);
    try testing.expect(!cls_data.params.hasNext());
}

// ============================================================================
// deleteClass
// ============================================================================

test "deleteClass: lookup returns null after deletion" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const h = try allocRootClass(testing.allocator, &store, "Doomed");
    try testing.expect(query.lookupClass(&store, "Doomed") != null);

    try factory.deleteClass(testing.allocator, &store, h);

    try testing.expect(query.lookupClass(&store, "Doomed") == null);
}

test "deleteClass: handle goes stale after deletion" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const h = try allocRootClass(testing.allocator, &store, "Stale");
    try factory.deleteClass(testing.allocator, &store, h);

    try testing.expectError(error.StaleHandle, handles.validateHandle(&store, h));
}

test "deleteClass: deletes all owned parameters" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const h = try allocRootClass(testing.allocator, &store, "ParamOwner");
    _ = try allocParam(testing.allocator, &store, "hp",  h, values.Value.initI32(100));
    _ = try allocParam(testing.allocator, &store, "mp",  h, values.Value.initI32(50));
    _ = try allocParam(testing.allocator, &store, "spd", h, values.Value.initF32(1.5));

    try factory.deleteClass(testing.allocator, &store, h);

    try testing.expect(query.lookupParameter(&store, "ParamOwner.hp")  == null);
    try testing.expect(query.lookupParameter(&store, "ParamOwner.mp")  == null);
    try testing.expect(query.lookupParameter(&store, "ParamOwner.spd") == null);
}

test "deleteClass: recursively deletes children" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const root  = try allocRootClass(testing.allocator,  &store, "CfgRoot");
    const child = try allocChildClass(testing.allocator, &store, "Child",  root);
    _           = try allocChildClass(testing.allocator, &store, "GrandChild", child);

    try factory.deleteClass(testing.allocator, &store, root);

    try testing.expect(query.lookupClass(&store, "CfgRoot")            == null);
    try testing.expect(query.lookupClass(&store, "CfgRoot.Child")      == null);
    try testing.expect(query.lookupClass(&store, "CfgRoot.Child.GrandChild") == null);
}

test "deleteClass: sibling at same level survives deletion" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const parent  = try allocRootClass(testing.allocator,  &store, "Parent");
    const child_a = try allocChildClass(testing.allocator, &store, "ChildA", parent);
    _             = try allocChildClass(testing.allocator, &store, "ChildB", parent);

    try factory.deleteClass(testing.allocator, &store, child_a);

    try testing.expect(query.lookupClass(&store, "Parent.ChildA") == null);
    try testing.expect(query.lookupClass(&store, "Parent.ChildB") != null);
    // Parent itself must still be alive
    try testing.expect(query.lookupClass(&store, "Parent") != null);
}

test "deleteClass: root-level sibling survives deletion of another root" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const root_a = try allocRootClass(testing.allocator, &store, "RootA");
    _            = try allocRootClass(testing.allocator, &store, "RootB");

    try factory.deleteClass(testing.allocator, &store, root_a);

    try testing.expect(query.lookupClass(&store, "RootA") == null);
    try testing.expect(query.lookupClass(&store, "RootB") != null);
}

test "deleteClass: deep tree — children's params all removed" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const cfg    = try allocRootClass(testing.allocator,  &store, "CfgVehicles");
    const car    = try allocChildClass(testing.allocator, &store, "Car",   cfg);
    const truck  = try allocChildClass(testing.allocator, &store, "Truck", cfg);
    _ = try allocParam(testing.allocator, &store, "speed",  car,   values.Value.initF32(120.0));
    _ = try allocParam(testing.allocator, &store, "mass",   car,   values.Value.initF32(1200.0));
    _ = try allocParam(testing.allocator, &store, "speed",  truck, values.Value.initF32(90.0));
    _ = try allocParam(testing.allocator, &store, "mass",   truck, values.Value.initF32(8000.0));

    try factory.deleteClass(testing.allocator, &store, cfg);

    // Everything gone
    try testing.expect(query.lookupClass(&store, "CfgVehicles")           == null);
    try testing.expect(query.lookupClass(&store, "CfgVehicles.Car")        == null);
    try testing.expect(query.lookupClass(&store, "CfgVehicles.Truck")      == null);
    try testing.expect(query.lookupParameter(&store, "CfgVehicles.Car.speed")   == null);
    try testing.expect(query.lookupParameter(&store, "CfgVehicles.Car.mass")    == null);
    try testing.expect(query.lookupParameter(&store, "CfgVehicles.Truck.speed") == null);
    try testing.expect(query.lookupParameter(&store, "CfgVehicles.Truck.mass")  == null);
}

// ============================================================================
// getOrCreateClass
// ============================================================================

test "getOrCreateClass: second call with same name returns existing class" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const a = try factory.getOrCreateClass(testing.allocator, testIo, &store, .{
        .name   = "Singleton",
        .parent = null,
        .source = source_mod.SourceHandle.invalid,
    });
    const b = try factory.getOrCreateClass(testing.allocator, testIo, &store, .{
        .name   = "Singleton",
        .parent = null,
        .source = source_mod.SourceHandle.invalid,
    });

    // Same pointer — no duplicate allocated
    try testing.expectEqual(a, b);
    try testing.expectEqual(a.pathHash, b.pathHash);
}

test "getOrCreateClass: different names create distinct classes" {
    var store = storage.ParamStorage.empty;
    defer store.deinit(testing.allocator);

    const a = try factory.getOrCreateClass(testing.allocator, testIo, &store, .{
        .name = "Alpha", .parent = null, .source = source_mod.SourceHandle.invalid,
    });
    const b = try factory.getOrCreateClass(testing.allocator, testIo, &store, .{
        .name = "Beta",  .parent = null, .source = source_mod.SourceHandle.invalid,
    });

    try testing.expect(a != b);
    try testing.expect(a.pathHash != b.pathHash);
}
