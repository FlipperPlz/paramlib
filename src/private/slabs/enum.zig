const std = @import("std");
const Allocator = std.mem.Allocator;
const identifiers = @import("../data/identifiers.zig");
const time = @import("../utils/time.zig");
const slabs = @import("slabs.zig");


pub const EnumData = struct {
    pub const Init = struct {
        io: std.Io,
        name_idx: identifiers.StringId,
        name_hash: u64,
        value: f32,
        source_id: identifiers.SourceId,

        pub fn toSlabInit(self: ?*Init) slabs.SlabInit{
            return slabs.SlabInit {
                .enumeration = self
            };
        }
    };
    alive: bool,
    generation: u32,
    name_hash: u64,
    value: f32,
    next: identifiers.EnumId,

    name_idx: identifiers.StringId,
    created_by: identifiers.SourceId,
    created_at: i64,

    pub fn init(
        args: Init
    ) EnumData {
        return .{
            .alive = true,
            .generation = 1,
            .name_hash = args.name_hash,
            .next = .invalid,
            .name_idx = args.name_idx,
            .value = args.value,
            .created_by = args.source_id,
            .created_at = time.getTimeMs(args.io, .real),
        };
    }
};