const std = @import("std");

const time = @import("../utils/time.zig");
const identifiers = @import("../data/identifiers.zig");
const slabs = @import("slabs.zig");
const Value = @import("../data/value.zig").Value;

pub const ParameterData = packed struct {
    pub const Init = struct {
        io: std.Io,
        name_hash: u64,
        name_idx:  identifiers.StringId,
        value: Value,
        parent: identifiers.ClassId,
        source: identifiers.SourceId,

        pub fn toSlabInit(self: ?*Init) slabs.SlabInit{
            return slabs.SlabInit {
                .parameter = self
            };
        }
    };
    alive: bool,
    generation: u32,
    name_hash: u64,
    value: Value,
    next: identifiers.ParameterId,

    name_idx: identifiers.StringId,
    parent: identifiers.ClassId,

    created_by: identifiers.SourceId,
    created_at: i64,
    modified_by: identifiers.SourceId,
    modified_at: i64,

    pub fn init(
        args: Init
    ) ParameterData {
        const timestamp = time.getTimeMs(args.io, std.Io.Clock.real);

        return .{
            .alive = true,
            .generation = 1,
            .name_hash = args.name_hash,
            .value = args.value,
            .next = .invalid,
            .name_idx = args.name_idx,
            .parent = args.parent,
            .created_by = args.source,
            .created_at = timestamp,
            .modified_by = args.source,
            .modified_at = timestamp
        };
    }

    pub fn markModified(self: *ParameterData, source: identifiers.SourceId, io: std.Io) void {
        self.modified_by = source;
        self.modified_at = time.getTimeMs(io, std.Io.Clock.real);
    }
};