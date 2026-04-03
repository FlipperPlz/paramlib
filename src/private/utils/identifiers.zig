const std = @import("std");
const storage = @import("../data/storage.zig");

pub fn TypedId(comptime name: []const u8, comptime TStorageType: storage.StorageType, comptime TTarget: type, comptime TTargetConst: type) type {
    return enum(usize) {
        const Self = @This();
        pub const _name = name;
        pub const _target = TTarget;
        pub const _targetConst = TTargetConst;
        pub const _storageType = TStorageType;
        invalid = std.math.maxInt(usize),
        _,

        pub fn toIndex(self: Self) ?usize {
            const val = @intFromEnum(self);
            if (val == std.math.maxInt(usize)) return null;
            return val;
        }

        pub fn fromIndex(idx: ?usize) Self {
            return if (idx) |i| @enumFromInt(i) else .invalid;
        }

        pub fn isValid(self: Self) bool {
            return self != .invalid;
        }
    };
}

test "identifiers: TypedId basic creation" {
    const Id = TypedId("Test1", .str, []const u8, []const u8);
    const valid_id: Id = @enumFromInt(0);
    const invalid_id: Id = .invalid;
    try std.testing.expect(valid_id.isValid());
    try std.testing.expect(!invalid_id.isValid());
}

test "identifiers: TypedId toIndex" {
    const Id = TypedId("Test2", .str, []const u8, []const u8);
    const valid_id: Id = @enumFromInt(5);
    const invalid_id: Id = .invalid;
    try std.testing.expectEqual(@as(?usize, 5), valid_id.toIndex());
    try std.testing.expectEqual(@as(?usize, null), invalid_id.toIndex());
}

test "identifiers: TypedId fromIndex" {
    const Id = TypedId("Test3", .str, []const u8, []const u8);
    const id_from_5 = Id.fromIndex(5);
    const id_from_null = Id.fromIndex(null);
    try std.testing.expect(id_from_5.isValid());
    try std.testing.expectEqual(@as(?usize, 5), id_from_5.toIndex());
    try std.testing.expect(!id_from_null.isValid());
}

test "identifiers: fromIndex 0 is valid" {
    const Id = TypedId("IdEdge1", .str, []const u8, []const u8);
    const id = Id.fromIndex(0);
    try std.testing.expect(id.isValid());
    try std.testing.expectEqual(@as(?usize, 0), id.toIndex());
}

test "identifiers: fromIndex null gives invalid" {
    const Id = TypedId("IdEdge2", .str, []const u8, []const u8);
    const id = Id.fromIndex(null);
    try std.testing.expect(!id.isValid());
    try std.testing.expectEqual(Id.invalid, id);
}

test "identifiers: maxInt-1 is valid, maxInt (invalid sentinel) is not" {
    const Id = TypedId("IdEdge3", .str, []const u8, []const u8);
    const max_valid: Id = @enumFromInt(std.math.maxInt(usize) - 1);
    try std.testing.expect(max_valid.isValid());
    try std.testing.expectEqual(@as(?usize, std.math.maxInt(usize) - 1), max_valid.toIndex());
    try std.testing.expect(!Id.invalid.isValid());
}

test "identifiers: sequential IDs" {
    const Id = TypedId("Test7", .str, []const u8, []const u8);
    const id0: Id = @enumFromInt(0);
    const id1: Id = @enumFromInt(1);
    const id2: Id = @enumFromInt(2);
    try std.testing.expect(id0.isValid());
    try std.testing.expect(id1.isValid());
    try std.testing.expect(id2.isValid());
    try std.testing.expectEqual(@as(?usize, 0), id0.toIndex());
    try std.testing.expectEqual(@as(?usize, 1), id1.toIndex());
    try std.testing.expectEqual(@as(?usize, 2), id2.toIndex());
}

test "identifiers: different TypedId names are distinct types" {
    const ClassId = TypedId("ClassIdDistinct", .clazz, *const void, *const void);
    const ParamId = TypedId("ParamIdDistinct", .par, *const void, *const void);
    const c: ClassId = @enumFromInt(5);
    const p: ParamId = @enumFromInt(5);
    try std.testing.expect(c.isValid());
    try std.testing.expect(p.isValid());
    try std.testing.expectEqual(@as(?usize, 5), c.toIndex());
    try std.testing.expectEqual(@as(?usize, 5), p.toIndex());
}
