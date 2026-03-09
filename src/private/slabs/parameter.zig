const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../data/value.zig").Value;
const time = @import("../utils/time.zig");
const identifiers = @import("../data/identifiers.zig");
const slabs = @import("slabs.zig");
const storage = @import("../data/storage.zig");
const paths = @import("../utils/paths.zig");
const hasher = @import("../utils/hasher.zig");
const handles = @import("../data/handles.zig");

pub const ParameterData = packed struct {
    pub const Id = identifiers.ParameterId;
    pub const Handle = handles.ParameterHandle;
    pub const Init = struct {
        io: std.Io,
        path: union {
            create: struct {
                allocator: Allocator,
                store: *storage.ParamStorage
            },
            created: u64
        },
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

    path_hash: u64,
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

        const param: ParameterData = .{
            .alive = true,
            .generation = 1,
            .path_hash = undefined,
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

        switch (args.path) {
            .create => |path_args| {
                const path = paths.getPath(path_args.allocator, path_args.store, param);
                param.path_hash = hasher.hash(path);
            },
            .created => |d| param.path_hash = d
        }
        return param;
    }

    pub fn markModified(self: *ParameterData, source: identifiers.SourceId, io: std.Io) void {
        self.modified_by = source;
        self.modified_at = time.getTimeMs(io, std.Io.Clock.real);
    }
};