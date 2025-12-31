const std = @import("std");
const id_mod = @import("../core/identifiers.zig");
const class_mod = @import("class.zig");
const value_mod = @import("value.zig");
const source_mod = @import("source.zig");
const time_mod = @import("../utils/time.zig");

const ClassId = id_mod.ClassId;
const ParamId = id_mod.ParamId;
const SourceId = id_mod.SourceId;
const Value = value_mod.Value;

pub const ParamFlags = packed struct(u8) {
    is_protected: bool = false,
    is_inherited: bool = false,
    _padding: u6 = 0,
};

pub const ParamData = struct {
    name_hash: u64,
    value: Value,
    next: ParamId,

    name_idx: u32,
    source_class: ClassId,
    flags: ParamFlags,

    created_by: SourceId,
    modified_by: SourceId,
    created_at: i64,
    modified_at: i64,

    pub fn init(
        name_idx: u32,
        name_hash: u64,
        value: Value,
        source: ClassId,
        source_id: SourceId,
        io: std.Io
    ) ParamData {
        const timestamp = time_mod.getTimeMs(io);
        return .{
            .name_hash = name_hash,
            .value = value,
            .next = .invalid,
            .name_idx = name_idx,
            .source_class = source,
            .flags = .{},
            .created_by = source_id,
            .modified_by = source_id,
            .created_at = timestamp,
            .modified_at = timestamp,
        };
    }

    pub fn markModified(self: *ParamData, source: SourceId, io: std.Io) void {
        self.modified_by = source;
        self.modified_at = time_mod.getTimeMs(io);
    }
};