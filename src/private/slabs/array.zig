const std         = @import("std");
const Allocator   = std.mem.Allocator;
const identifiers = @import("../utils/identifiers.zig");
const handles     = @import("../utils/handles.zig");
const value       = @import("../data/value.zig");
const parameter   = @import("parameter.zig");
const source      = @import("source.zig");
const memory      = @import("../utils/memory.zig");
const time        = @import("../utils/time.zig");
const storage     = @import("../data/storage.zig");

pub const ArraySlabSize   = 1024;
pub const ArrayIdentifier = identifiers.TypedId("Array");
pub const ArrayHandle     = handles.Handle(ArrayIdentifier);

pub const ArrayInit = struct {
    values:      []value.Value              = undefined,
    parentArray: ?ArrayHandle               = null,
    parentParam: parameter.ParameterHandle,
    source:      source.SourceHandle
};

pub fn ArrayStorage(comptime field: []const u8) type {
    return struct {
        const Self = @This();
        handle: ArrayHandle,

        pub fn init(handle: ArrayHandle) Self {
            return .{ .handle = handle };
        }

        pub fn hasNext(self: Self) bool {
            return self.handle.isValid();
        }

        pub fn next(self: Self, store: *const storage.ParamStorage) !Self {
            if (!self.hasNext()) return error.EndOfList;
            const data: *ArrayData = @ptrCast(@alignCast(try store.retrieve(.create(self.handle.id))));
            return @field(data, field);
        }

        pub const Iterator = struct {
            store: *const storage.ParamStorage,
            current: Self,

            pub fn next(it: *@This()) ?Self {
                if (!it.current.hasNext()) return null;
                const result = it.current;
                it.current = it.current.next(it.store) catch return null;
                return result;
            }
        };

        pub fn iterator(self: Self, store: *const storage.ParamStorage) Iterator {
            return .{
                .store = store,
                .current = self,
            };
        }

        pub const empty: Self = .{ .handle = ArrayHandle.invalid };
    };
}

pub const ArrayData = struct {
    alive:       bool,
    generation:  u32,
    values:      std.ArrayList(value.Value),
    parentParam: parameter.ParameterStorage("parent"),
    parentArray: ArrayStorage("parentArray"),
    createdBy:   source.SourceHandle,
    createdAt:   i64,
    modifiedBy:  source.SourceHandle,
    modifiedAt:  i64,

    pub fn init(allocator: Allocator, io: std.Io, args: ArrayInit) !ArrayData {
        const timestamp = time.getTimeMs(io, .real);

        return .{
            .alive       = true,
            .generation  = 1,
            .values      = std.ArrayList(value.Value).initBuffer(try allocator.dupe(value.Value, args.values)),
            .parentParam = parameter.ParameterStorage("parent").init(args.parentParam),
            .parentArray = ArrayStorage("parentArray").init(args.parentArray orelse ArrayHandle.invalid),
            .createdBy   = args.source,
            .modifiedBy  = args.source,
            .createdAt   = timestamp,
            .modifiedAt  = timestamp,
        };
    }

    pub fn deinit(self: *ArrayData, allocator: Allocator) void {
        self.values.deinit(allocator);
    }
};

pub const ArrayPool = memory.SlabPool(ArrayData, ArrayIdentifier, ArraySlabSize);
