const std = @import("std");

const time = @import("../utils/time.zig");
const identifiers = @import("../data/identifiers.zig");
const slabs = @import("slabs.zig");

pub const ClassAccess = enum(u2) {
    ReadWrite = 0,
    ReadCreate = 1,
    ReadOnly = 2,
    ReadOnlyVerified = 3,
};

pub const ClassData = packed struct {
    pub const Init = struct {
        io: std.Io,
        parent: identifiers.ClassId,
        name_idx: u32,
        name_hash: u64,
        path_hash: u64,
        source: identifiers.SourceId,

        pub fn toSlabInit(self: ?*Init) slabs.SlabInit{
            return slabs.SlabInit {
                .class = self
            };
        }
    };
    generation: u32,
    alive: bool,
    name_hash: u64,
    first_param: identifiers.ParameterId,
    access: ClassAccess,

    parent: identifiers.ClassId,
    base: identifiers.ClassId,
    first_child: identifiers.ClassId,
    next_sibling: identifiers.ClassId,

    references: u32,
    name_idx: u32,
    path_hash: u64,

    created_by: identifiers.SourceId,
    created_at: i64,
    modified_by: identifiers.SourceId,
    modified_at: i64,

    pub fn init(
        args: Init
    ) ClassData {
        const timestamp = time.getTimeMs(args.io);
        return .{
            .alive = true,
            .generation = 1,
            .name_hash = args.name_hash,
            .first_param = .invalid,
            .flags = .{},
            .parent = args.parent,
            .base = .invalid,
            .first_child = .invalid,
            .next_sibling = .invalid,
            .references = 1,
            .name_index = args.name_idx,
            .path_hash = args.path_hash,
            .created_by = args.source,
            .modified_by = args.source,
            .created_at = timestamp,
            .modified_at = timestamp,
        };
    }
};