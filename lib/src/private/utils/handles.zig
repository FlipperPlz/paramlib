
const std         = @import("std");
const storage     = @import("../data/storage.zig");
const parameters  = @import("../slabs/parameter.zig");
const class       = @import("../slabs/class.zig");
const source      = @import("../slabs/source.zig");
const array       = @import("../slabs/array.zig");
const value       = @import("../data/value.zig");
const paths       = @import("../utils/paths.zig");

pub fn Handle(comptime Tid: type) type {
    return struct {
        const Self = @This();
        pub const _identifier = Tid;
        pub const _name = Tid._name;
        pub const _target = Tid._target;

        id: Tid,
        generation: u32,

        pub const invalid: Self = .{ .id = .invalid, .generation = 0 };

        pub inline fn isValid(self: Self) bool {
            return self.id.isValid();
        }

        pub fn eql(self: Self, other: Self) bool {
            return self.id == other.id and self.generation == other.generation;
        }

        pub fn validateHandle(self: Self, store: *const storage.ParamAllocator) !struct{ptr: Tid._targetConst, id: Tid} {
             if (!self.isValid()) return error.InvalidHandle;

             const data_ptr = try store.retrieve(self.id);

             const generation, const alive = blk: {
                 if (Tid == parameters.ParameterIdentifier) {
                     const d: *const parameters.ParameterData = data_ptr;
                     break :blk .{ d.generation, d.alive };
                 } else if (Tid == class.ClassIdentifier) {
                     const d: *const class.ClassData = data_ptr;
                     break :blk .{ d.generation, d.alive };
                 } else if (Tid == source.SourceIdentifier) {
                     const d: *const source.SourceData = data_ptr;
                     break :blk .{ d.generation, d.alive };
                 } else if (Tid == array.ArrayIdentifier) {
                     const d: *const array.ArrayData = data_ptr;
                     break :blk .{ d.generation, d.alive };
                 } else {
                     @compileError("validateHandle: unsupported handle id type " ++ @typeName(Tid));
                 }
             };

             if (generation != self.generation) return error.StaleHandle;
             if (!alive) return error.DeadData;

             return .{
                 .ptr = data_ptr,
                 .id  = self.id,
             };
         }

        pub fn refreshHandle(store: *const storage.ParamAllocator, handle: anytype) !@TypeOf(handle) {
            _ = try validateHandle(store, handle);
            return handle;
        }
    };
}

const identifiers = @import("identifiers.zig");

test "handles: Handle creation and validation" {
    const Id = identifiers.TypedId("Test4", .str, []const u8, []const u8);
    const H = Handle(Id);
    const valid_handle: H = .{ .id = @enumFromInt(0), .generation = 1 };
    const invalid_handle: H = .{ .id = .invalid, .generation = 0 };
    try std.testing.expect(valid_handle.isValid());
    try std.testing.expect(!invalid_handle.isValid());
}

test "handles: Handle equality" {
    const Id = identifiers.TypedId("Test5", .str, []const u8, []const u8);
    const H = Handle(Id);
    const handle1: H = .{ .id = @enumFromInt(0), .generation = 1 };
    const handle2: H = .{ .id = @enumFromInt(0), .generation = 1 };
    const handle3: H = .{ .id = @enumFromInt(0), .generation = 2 };
    try std.testing.expect(handle1.eql(handle2));
    try std.testing.expect(!handle1.eql(handle3));
}

test "handles: Handle invalid constant" {
    const Id = identifiers.TypedId("Test8", .str, []const u8, []const u8);
    const H = Handle(Id);
    const invalid = H.invalid;
    try std.testing.expect(!invalid.isValid());
    try std.testing.expect(!invalid.id.isValid());
}

test "handles: Multiple generations" {
    const Id = identifiers.TypedId("Test9", .str, []const u8, []const u8);
    const H = Handle(Id);
    const h1: H = .{ .id = @enumFromInt(5), .generation = 1 };
    const h2: H = .{ .id = @enumFromInt(5), .generation = 2 };
    const h3: H = .{ .id = @enumFromInt(5), .generation = 3 };
    try std.testing.expect(!h1.eql(h2));
    try std.testing.expect(!h2.eql(h3));
    try std.testing.expect(h1.eql(h1));
}

test "handles: generation 0 with valid id IS valid (isValid only checks id)" {
    const Id = identifiers.TypedId("HandleEdge1", .str, []const u8, []const u8);
    const H = Handle(Id);
    const h = H{ .id = @enumFromInt(0), .generation = 0 };
    try std.testing.expect(h.isValid());
}

test "handles: eql requires both id and generation to match" {
    const Id = identifiers.TypedId("HandleEdge2", .str, []const u8, []const u8);
    const H = Handle(Id);
    const h1 = H{ .id = @enumFromInt(5), .generation = 3 };
    const h2 = H{ .id = @enumFromInt(5), .generation = 3 };
    const h3 = H{ .id = @enumFromInt(5), .generation = 4 };
    const h4 = H{ .id = @enumFromInt(6), .generation = 3 };
    try std.testing.expect(h1.eql(h2));
    try std.testing.expect(!h1.eql(h3));
    try std.testing.expect(!h1.eql(h4));
    try std.testing.expect(!h3.eql(h4));
}

test "handles: two invalid handles are equal" {
    const Id = identifiers.TypedId("HandleEdge3", .str, []const u8, []const u8);
    const H = Handle(Id);
    try std.testing.expect(H.invalid.eql(H.invalid));
}

test "handles: maxInt generation is stored correctly" {
    const Id = identifiers.TypedId("HandleEdge4", .str, []const u8, []const u8);
    const H = Handle(Id);
    const h = H{ .id = @enumFromInt(0), .generation = std.math.maxInt(u32) };
    try std.testing.expect(h.isValid());
    try std.testing.expectEqual(std.math.maxInt(u32), h.generation);
}