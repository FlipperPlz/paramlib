const std = @import("std");
const Allocator = std.mem.Allocator;
const time = @import("../utils/time.zig");
const identifiers = @import("../data/identifiers.zig");
const slabs = @import("slabs.zig");
const paths = @import("../utils/paths.zig");
const storage = @import("../data/storage.zig");
const hasher = @import("../utils/hasher.zig");

pub const ClassAccess = enum(u2) {
    ReadWrite = 0,
    ReadCreate = 1,
    ReadOnly = 2,
    ReadOnlyVerified = 3,
};

pub const ClassData = packed struct {
    pub const Init = struct {
        path: union {
            create: struct {
                allocator: Allocator,
                store: *storage.ParamStorage
            },
            created: u64
        },
        io: std.Io,
        parent: identifiers.ClassId,
        name_idx: identifiers.StringId,
        name_hash: u64,
        path_hash: ?u64,
        source: identifiers.SourceId,

        pub fn toSlabInit(self: ?*Init) slabs.SlabInit{
            return slabs.SlabInit {
                .class = self
            };
        }
    };
    generation: u32,
    path_hash: u64,
    alive: bool,
    name_hash: u64,
    first_param: identifiers.ParameterId,
    access: ClassAccess,

    parent: identifiers.ClassId,
    base: identifiers.ClassId,
    first_child: identifiers.ClassId,
    next_sibling: identifiers.ClassId,

    references: u32,
    name_idx: identifiers.StringId,

    created_by: identifiers.SourceId,
    created_at: i64,
    modified_by: identifiers.SourceId,
    modified_at: i64,

    pub fn init(
        args: Init
    ) ClassData {
        const timestamp = time.getTimeMs(args.io);
        const class: ClassData = .{
            .alive = true,
            .generation = 1,
            .path_hash = undefined,
            .name_hash = args.name_hash,
            .first_param = .invalid,
            .flags = .{},
            .parent = args.parent,
            .base = .invalid,
            .first_child = .invalid,
            .next_sibling = .invalid,
            .references = 1,
            .name_index = args.name_idx,
            .created_by = args.source,
            .modified_by = args.source,
            .created_at = timestamp,
            .modified_at = timestamp,
        };
        switch (args.path) {
            .create => |path_args| {
                const path = paths.getPath(path_args.allocator, path_args.store, class);
                class.path_hash = hasher.hash(path);
            },
            .created => |d| class.path_hash = d
        }

        return class;
    }
};