const std = @import("std");

const time = @import("../utils/time.zig");
const identifiers = @import("../data/identifiers.zig");
const slabs = @import("slabs.zig");
const Value = @import("../data/value.zig");

pub const ArrayData = struct {
    pub const Init = struct {
        io: std.Io,
        values: []Value,
        parameter: identifiers.ParameterId,
        parent_array: ?identifiers.ArrayId,
        source: identifiers.SourceId,

        pub fn toSlabInit(self: ?*Init) slabs.SlabInit{
            return slabs.SlabInit {
                .array = self
            };
        }
    };
    alive: bool,
    generation: u32,
    values: std.ArrayList(Value),

    parameter: identifiers.ParameterId,
    parent_array: ?identifiers.ArrayId,

    created_by: identifiers.SourceId,
    created_at: i64,
    modified_by: identifiers.SourceId,
    modified_at: i64,

    pub fn init(args: Init) ArrayData {
        const timestamp = time.getTimeMs(args.io, .real);
        return .{
            .alive = true,
            .generation = 1,
            .values = .initBuffer(args.values),
            .parameter = args.parameter,
            .parent_arrray = args.parent_array,
            .created_by = args.source,
            .modified_by = args.source,
            .modified_at = timestamp,
            .created_at = timestamp
        };
    }

    pub fn deinit(self: *ArrayData, allocator: std.mem.Allocator) void {
        self.values.deinit(allocator);
    }

    pub fn append(self: *ArrayData, allocator: std.mem.Allocator, value: Value) !void {
        try self.values.append(allocator, value);
    }

    pub fn get(self: *const ArrayData, index: usize) ?Value {
        if (index >= self.values.items.len) return null;
        return self.values.items[index];
    }

    pub fn set(self: *ArrayData, index: usize, value: Value) !void {
        if (index >= self.values.items.len) return error.IndexOutOfBounds;
        self.values.items[index] = value;
    }

    pub fn len(self: *const ArrayData) usize {
        return self.values.items.len;
    }
};
