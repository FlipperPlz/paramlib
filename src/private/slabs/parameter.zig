const std         = @import("std");
const Allocator   = std.mem.Allocator;

const identifiers = @import("../utils/identifiers.zig");
const handles     = @import("../utils/handles.zig");
const values      = @import("../data/value.zig");
const paths       = @import("../utils/paths.zig");
const memory      = @import("../utils/memory.zig");
const class       = @import("class.zig");
const source      = @import("source.zig");
const time        = @import("../utils/time.zig");
const storage     = @import("../data/storage.zig");

pub const ParameterSlabSize   = 512;
pub const ParameterIdentifier = identifiers.TypedId("Parameter");
pub const ParameterHandle     = handles.Handle(ParameterIdentifier);

pub fn ParameterStorage(comptime field: []const u8) type {
    return struct {
        const Self = @This();
        handle: ParameterHandle,

        pub fn init(handle: ParameterHandle) Self {
            return .{ .handle = handle };
        }

        pub fn hasNext(self: Self) bool {
            return self.handle.isValid();
        }

        pub fn next(self: Self, store: *const storage.ParamStorage) !Self {
            if (!self.hasNext()) return error.EndOfList;
            const data: *const ParameterData = @constCast(@ptrCast(@alignCast(try store.retrieve(.create(self.handle.id)))));
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

        pub const empty: Self = .{ .handle = ParameterHandle.invalid };
    };
}

pub const ParameterInit = struct {
    name:     []const u8,
    nameHash: ?u64                         = null,
    nameIdx:  ?paths.PathSegmentIdentifier = null,
    parent:   class.ClassHandle,
    source:   source.SourceHandle,
    pathHash: ?u64                         = null,
    value:    values.Value,
};

pub const ParameterData = struct { 
    alive:      bool,
    generation: u32,
    nameHash:   u64,
    value:      values.Value,
    sibling:    ParameterStorage("sibling"),
    pathHash:   u64,
    nameIdx:    paths.PathSegmentIdentifier,
    parent:     class.ClassStorage("parent"),
    createdBy:  source.SourceHandle,
    createdAt:  i64,
    modifiedBy: source.SourceHandle,
    modifiedAt: i64,

    pub fn init(io: std.Io, args: ParameterInit) ParameterData {
        std.debug.assert(args.nameIdx != null and args.nameHash != null and args.pathHash != null);
        const timestamp = time.getTimeMs(io, .real);

        return .{
            .alive      = true,
            .generation = 1,
            .nameHash   = args.nameHash.?,
            .value      = args.value,
            .sibling    = ParameterStorage("sibling").empty,
            .pathHash   = args.pathHash.?,
            .nameIdx    = args.nameIdx.?,
            .parent     = class.ClassStorage("parent").init(args.parent),
            .createdBy  = args.source,
            .createdAt  = timestamp,
            .modifiedBy = args.source,
            .modifiedAt = timestamp
        };
    }
}; 

pub const ParameterPool = memory.SlabPool(ParameterData, ParameterIdentifier, ParameterSlabSize);
