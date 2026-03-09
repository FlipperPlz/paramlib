pub const std = @import("std");
pub const Allocator = std.mem.Allocator;
pub const storage = @import("../data/storage.zig");
pub const slabs = @import("../slabs/slabs.zig");
pub const identifiers = @import("../data/identifiers.zig");

pub fn getPath(allocator: Allocator, store: storage.ParamStorage, comptime dataType: type) ![]const u8 {
    var total_len: usize = 0;
    const sections: std.ArrayList([]const u8) = .empty;
    {
        const dataOpt: ?dataType = dataType;
        while (dataOpt) | data |{
            const name_idx: identifiers.StringId = data.name_idx;
            const name: []const u8 = (try store.retrieve(.create(name_idx))).*;
            total_len += name.len;
            sections.append(allocator, name);

            const parentId: identifiers.ClassId = data.parent;
            dataOpt = try store.retrieve(.create(parentId));
        }
    }

    const slice = try sections.toOwnedSlice(allocator);
    defer allocator.free(slice);

    std.mem.reverse([]const u8, slice);

    if (slice.len > 0) {
        total_len += (slice.len - 1) * 1;
    }

    var combined_buffer = try allocator.alloc(u8, total_len);
    var current_index: usize = 0;

    for (slice) |part| {
        @memcpy(combined_buffer[current_index..][0..part.len], part);
        current_index += part.len;

        if (current_index < total_len) {
            @memcpy(combined_buffer[current_index..][0..1], ".");
            current_index += 1;
        }
    }

    return combined_buffer;
}