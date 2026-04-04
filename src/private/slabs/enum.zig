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

//TODO: seems enums are just a concept of the evaluator this all may be removed
pub const EnumData = struct {
    alive:      bool,
    generation: u32,
    nameHash:   u64,
    value:      f32,
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
