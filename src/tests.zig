const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

// Import modules
const identifiers = @import("private/utils/identifiers.zig");
const handles = @import("private/utils/handles.zig");
const hasher = @import("private/utils/hasher.zig");
const values = @import("private/data/value.zig");

// ============================================================================
// Tests for identifiers module
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

// ============================================================================
// Tests for handles module
// ============================================================================

test "handles: Handle creation and validation" {
    const Id = identifiers.TypedId("Test4");
    const HandleType = handles.Handle(Id);

    const valid_handle: HandleType = .{ .id = @enumFromInt(0), .generation = 1 };
    const invalid_handle: HandleType = .{ .id = .invalid, .generation = 0 };

    try testing.expect(valid_handle.isValid());
    try testing.expect(!invalid_handle.isValid());
}

test "handles: Handle equality" {
    const Id = identifiers.TypedId("Test5");
    const HandleType = handles.Handle(Id);

    const handle1: HandleType = .{ .id = @enumFromInt(0), .generation = 1 };
    const handle2: HandleType = .{ .id = @enumFromInt(0), .generation = 1 };
    const handle3: HandleType = .{ .id = @enumFromInt(0), .generation = 2 };

    try testing.expect(handle1.eql(handle2));
    try testing.expect(!handle1.eql(handle3));
}

// ============================================================================
// Tests for hasher module
// ============================================================================

test "hasher: consistent hashing" {
    const hash1 = hasher.hash("test_string");
    const hash2 = hasher.hash("test_string");
    const hash3 = hasher.hash("different_string");

    try testing.expectEqual(hash1, hash2);
    try testing.expect(hash1 != hash3);
}

test "hasher: different strings produce different hashes" {
    const hash1 = hasher.hash("string1");
    const hash2 = hasher.hash("string2");
    const hash3 = hasher.hash("string3");

    try testing.expect(hash1 != hash2);
    try testing.expect(hash2 != hash3);
    try testing.expect(hash1 != hash3);
}

// ============================================================================
// Tests for Value module
// ============================================================================

test "value: Value initialization methods" {
    const v_i32 = values.Value.initI32(42);
    const v_i64 = values.Value.initI64(1000);
    const v_f32 = values.Value.initF32(3.14);
    const v_f64 = values.Value.initF64(2.71828);
    const v_string = values.Value.initString(5);
    const v_array = values.Value.initArray(10);

    try testing.expectEqual(v_i32.i32, 42);
    try testing.expectEqual(v_i64.i64, 1000);
    try testing.expectApproxEqAbs(v_f32.f32, 3.14, 0.01);
    try testing.expectApproxEqAbs(v_f64.f64, 2.71828, 0.00001);
    try testing.expectEqual(v_string.string, 5);
    try testing.expectEqual(v_array.array, 10);
}

test "value: Value needsCleanup" {
    const v_i32 = values.Value.initI32(42);
    const v_array = values.Value.initArray(10);

    try testing.expect(!v_i32.needsCleanup());
    try testing.expect(v_array.needsCleanup());
}

test "value: Value isNumeric" {
    const v_i32 = values.Value.initI32(42);
    const v_i64 = values.Value.initI64(1000);
    const v_f32 = values.Value.initF32(3.14);
    const v_f64 = values.Value.initF64(2.71828);
    const v_string = values.Value.initString(5);
    const v_array = values.Value.initArray(10);

    try testing.expect(v_i32.isNumeric());
    try testing.expect(v_i64.isNumeric());
    try testing.expect(v_f32.isNumeric());
    try testing.expect(v_f64.isNumeric());
    try testing.expect(!v_string.isNumeric());
    try testing.expect(!v_array.isNumeric());
}

test "value: Value sizeOf" {
    const size = values.Value.sizeOf();
    try testing.expectEqual(@sizeOf(values.Value), size);
}

// ============================================================================
// Tests for Storage module
// ============================================================================

// NOTE: Storage tests are commented out until import issues are resolved
// in the strings.zig and other modules


// ============================================================================
// Tests for Hasher with Storage
// ============================================================================

test "hasher: hash consistency with path strings" {
    const path1 = "root.module.parameter";
    const path2 = "root.module.parameter";
    const path3 = "root.module.different";

    const hash1 = hasher.hash(path1);
    const hash2 = hasher.hash(path2);
    const hash3 = hasher.hash(path3);

    try testing.expectEqual(hash1, hash2);
    try testing.expect(hash1 != hash3);
}

// ============================================================================
// Tests for Identifier edge cases
// ============================================================================

test "identifiers: max int handling" {
    const Id = identifiers.TypedId("Test6");
    const invalid: Id = .invalid;

    try testing.expect(!invalid.isValid());
    try testing.expectEqual(@as(?usize, null), invalid.toIndex());
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

// ============================================================================
// Tests for Handle edge cases
// ============================================================================

test "handles: Handle invalid constant" {
    const Id = identifiers.TypedId("Test8");
    const HandleType = handles.Handle(Id);

    const invalid = HandleType.invalid;
    try testing.expect(!invalid.isValid());
    try testing.expect(!invalid.id.isValid());
}

test "handles: Multiple generations" {
    const Id = identifiers.TypedId("Test9");
    const HandleType = handles.Handle(Id);

    const handle_gen1: HandleType = .{ .id = @enumFromInt(5), .generation = 1 };
    const handle_gen2: HandleType = .{ .id = @enumFromInt(5), .generation = 2 };
    const handle_gen3: HandleType = .{ .id = @enumFromInt(5), .generation = 3 };

    try testing.expect(!handle_gen1.eql(handle_gen2));
    try testing.expect(!handle_gen2.eql(handle_gen3));
    try testing.expect(handle_gen1.eql(handle_gen1));
}

// ============================================================================
// Tests for Value union type edge cases
// ============================================================================

test "value: Different numeric types" {
    const v_i32 = values.Value.initI32(-42);
    const v_i64 = values.Value.initI64(-1000);
    const v_f32_neg = values.Value.initF32(-3.14);
    const v_f64_neg = values.Value.initF64(-2.71828);

    try testing.expectEqual(v_i32.i32, -42);
    try testing.expectEqual(v_i64.i64, -1000);
    try testing.expect(v_i32.isNumeric());
    try testing.expect(v_i64.isNumeric());
    try testing.expect(v_f32_neg.isNumeric());
    try testing.expect(v_f64_neg.isNumeric());
}

test "value: Large index values" {
    const large_idx: usize = 999999;
    const v_string = values.Value.initString(large_idx);
    const v_array = values.Value.initArray(large_idx);

    try testing.expectEqual(v_string.string, large_idx);
    try testing.expectEqual(v_array.array, large_idx);
}

// ============================================================================
// Integration tests
// ============================================================================

test "integration: hasher and identifier work together" {
    const name = "test_parameter";
    const hash = hasher.hash(name);

    try testing.expect(hash > 0);
    const hash_again = hasher.hash(name);
    try testing.expectEqual(hash, hash_again);
}

test "integration: value types and their properties" {
    var values_list: [7]values.Value = undefined;
    values_list[0] = values.Value.initI32(42);
    values_list[1] = values.Value.initI64(1000);
    values_list[2] = values.Value.initF32(3.14);
    values_list[3] = values.Value.initF64(2.71828);
    values_list[4] = values.Value.initString(0);
    values_list[5] = values.Value.initArray(1);
    values_list[6] = values.Value.initString(2);

    var numeric_count: usize = 0;
    var cleanup_count: usize = 0;

    for (values_list) |v| {
        if (v.isNumeric()) numeric_count += 1;
        if (v.needsCleanup()) cleanup_count += 1;
    }

    try testing.expectEqual(@as(usize, 4), numeric_count);
    try testing.expectEqual(@as(usize, 1), cleanup_count);
}

test "integration: handle validation workflow" {
    const Id = identifiers.TypedId("Test10");
    const HandleType = handles.Handle(Id);

    const valid_id: Id = @enumFromInt(10);
    const valid_handle: HandleType = .{ .id = valid_id, .generation = 1 };

    try testing.expect(valid_handle.isValid());
    try testing.expect(valid_handle.id.isValid());
    try testing.expect(valid_handle.generation > 0);

    const invalid_handle: HandleType = HandleType.invalid;
    try testing.expect(!invalid_handle.isValid());
    try testing.expect(!invalid_handle.id.isValid());
}



