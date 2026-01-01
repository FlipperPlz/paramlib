const std = @import("std");
const id_mod = @import("../core/identifiers.zig");
const time_mod = @import("../utils/time.zig");

const EnumId = id_mod.EnumId;
const SourceId = id_mod.SourceId;

pub const EnumData = struct {
    name_hash: u64,
    value: f32,
    next: EnumId,

    name_idx: u32,
    created_by: SourceId,
    created_at: i64,

    pub fn init(
        name_idx: u32,
        name_hash: u64,
        value: f32,
        source_id: SourceId,
        io: std.Io,
    ) EnumData {
        return .{
            .name_hash = name_hash,
            .next = .invalid,
            .name_idx = name_idx,
            .value = value,
            .created_by = source_id,
            .created_at = time_mod.getTimeMs(io),
        };
    }

};