const std = @import("std");
const id_mod = @import("../core/identifiers.zig");
const source_mod = @import("source.zig");
const time_mod = @import("../utils/time.zig");

pub const ClassId = id_mod.ClassId;
pub const ParamId = id_mod.ParamId;
pub const SourceId = id_mod.SourceId;

pub const ClassAccess = enum(u2) {
    ReadWrite = 0,
    ReadCreate = 1,
    ReadOnly = 2,
    ReadOnlyVerified = 3,
};

pub const ClassFlags = packed struct(u8) {
    is_alive: bool = true,
    is_locked: bool = false,
    has_base: bool = false,
    access_level: ClassAccess = .ReadWrite,
    _padding: u3 = 0,
};

pub const ClassData = struct {
    generation: u32,
    name_hash: u64,
    first_param: ParamId,
    flags: ClassFlags,

    parent: ClassId,
    base: ClassId,
    first_child: ClassId,
    next_sibling: ClassId,

    references: u32,
    name_index: u32,
    path_hash: u64,

    created_by: SourceId,
    modified_by: SourceId,
    created_at: i64,
    modified_at: i64,

    pub fn init(
        parent: ClassId,
        name_idx: u32,
        name_hash: u64,
        path_hash: u64,
        source: SourceId,
        io: std.Io,
    ) ClassData {
        const timestamp = time_mod.getTimeMs(io);
        return .{
            .generation = 1,
            .name_hash = name_hash,
            .first_param = .invalid,
            .flags = .{},
            .parent = parent,
            .base = .invalid,
            .first_child = .invalid,
            .next_sibling = .invalid,
            .references = 1,
            .name_index = name_idx,
            .path_hash = path_hash,
            .created_by = source,
            .modified_by = source,
            .created_at = timestamp,
            .modified_at = timestamp,
        };
    }

    pub fn markModified(self: *ClassData, source: SourceId, io: std.Io) void {
        self.modified_by = source;
        self.modified_at = time_mod.getTimeMs(io);
    }
};