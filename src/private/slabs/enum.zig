const std         = @import("std");

const identifiers = @import("../utils/identifiers.zig");
const handles     = @import("../utils/handles.zig");
const paths       = @import("../utils/paths.zig");
const source      = @import("source.zig");
const memory      = @import("../utils/memory.zig");
const storage     = @import("../data/storage.zig");

pub const EnumSlabSize   = 64;
pub const EnumIdentifier = identifiers.TypedId("Enum", .enumeration, *EnumData, *const EnumData);
pub const EnumHandle     = handles.Handle(EnumIdentifier);
pub const EnumPool       = memory.SlabPool(EnumData, EnumIdentifier, EnumSlabSize);

pub const EnumData = struct {
    alive:      bool,
    generation: u32,
    nameHash:   u64,
    value:      f32,
    next:       EnumStorage("next"),
    nameIdx:    paths.PathSegmentIdentifier,
    createdBy:  source.SourceIdentifier,
    createdAt:  i64,

    pub fn init(io: std.Io, args: EnumInit) EnumData {
        if (args.nameHash == null or args.nameIdx == null) {
            @compileError("Arguments not initialized for EnumData");
        }

        const timestamp = std.Io.Timestamp.now(io, .real).toMilliseconds();
        return .{
            .alive      = true,
            .generation = 1,
            .nameHash   = args.nameHash.?,
            .value      = args.value,
            .next       = EnumStorage("next").empty,
            .nameIdx    = args.nameIdx.?,
            .createdBy  = args.source,
            .createdAt  = timestamp,
        };
    }

};

pub const EnumInit = struct {
    pub const _identifier = EnumIdentifier;
    name:     []const u8,
    value:    f32,
    nameHash: ?u64                         = null,
    nameIdx:  ?paths.PathSegmentIdentifier = null,
    source:   source.SourceHandle,
};

pub fn EnumStorage(comptime field: []const u8) type {
    return struct {
        const Self = @This();
        handle: EnumHandle,

        pub fn init(handle: EnumHandle) Self {
            return .{ .handle = handle };
        }

        pub fn hasNext(self: Self) bool {
            return self.handle.isValid();
        }

        pub fn next(self: Self, store: *const storage.ParamAllocator) !Self {
            if (!self.hasNext()) return error.EndOfList;
            const data: *EnumData = try store.retrieve(self.handle.id);
            return @field(data, field);
        }

        pub const Iterator = struct {
            store: *const storage.ParamAllocator,
            current: Self,

            pub fn next(it: *@This()) ?Self {
                if (!it.current.hasNext()) return null;
                const result = it.current;
                it.current = it.current.next(it.store) catch return null;
                return result;
            }
        };

        pub fn iterator(self: Self, store: *const storage.ParamAllocator) Iterator {
            return .{
                .store = store,
                .current = self,
            };
        }

        pub const empty: Self = .{ .handle = EnumHandle.invalid };
    };
}