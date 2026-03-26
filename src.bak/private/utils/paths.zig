pub const std = @import("std");
pub const Allocator = std.mem.Allocator;
pub const storage = @import("../data/storage.zig");
pub const slabs = @import("../slabs/slabs.zig");
pub const identifiers = @import("../data/identifiers.zig");

pub const PathSeparator = ".";

pub fn joinPaths(allocator: Allocator, paths: [][]const u8) ![]const u8 {
    var total_len: usize = 0;
    for (paths) |path| {
        total_len += path.len;
    }

    if (paths.len > 1) {
        total_len += (paths.len - 1) * 1;
    }

    var combined_buffer = try allocator.alloc(u8, total_len);
    var current_index: usize = 0;

    for (paths) |path| {
        @memcpy(combined_buffer[current_index..][0..path.len], path);
        current_index += path.len;

        if (current_index < total_len) {
            @memcpy(combined_buffer[current_index..][0..1], PathSeparator);
            current_index += 1;
        }
    }

    return combined_buffer;
}

pub fn getName(path: []const u8) []const u8 {
    const sepIdx = std.mem.lastIndexOfScalar(u8, path, PathSeparator);
    if (sepIdx) |i| {
        return path[i+1..];
    } else {
        return path;
    }
}
pub fn getParent(path: []const u8) []const u8 {
    const sepIdx = std.mem.lastIndexOfScalar(u8, path, PathSeparator);
    if (sepIdx) |i| {
        return path[0..i];
    } else {
        return "";
    }
}

