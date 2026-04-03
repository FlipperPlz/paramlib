const std = @import("std");
const Allocator = std.mem.Allocator;
const identifier = @import("./identifiers.zig");
const storage = @import("../data/storage.zig");
const handles = @import("./handles.zig");
const query = @import("../tree/query.zig");
const hasher = @import("./hasher.zig");
const class = @import("../slabs/class.zig");
const parameter = @import("../slabs/parameter.zig");

pub const PathSeparator = ".";
pub const PathSegmentIdentifier = identifier.TypedId("path_segment", storage.StorageType.segment, []const u8, []const u8);
pub const SegmentInit = storage.StringInit(PathSegmentIdentifier);

pub fn joinPaths(allocator: Allocator, paths: []const []const u8) ![]const u8 {
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
    const sepIdx = std.mem.lastIndexOf(u8, path, PathSeparator);
    if (sepIdx) |i| {
        return path[i + 1 ..];
    } else {
        return path;
    }
}

pub fn getParent(path: []const u8) []const u8 {
    const sepIdx = std.mem.lastIndexOf(u8, path, PathSeparator);
    if (sepIdx) |i| {
        return path[0..i];
    } else {
        return "";
    }
}

pub const PathType = union(query.QueryType) {
    class: *const class.ClassData,
    parameter: *const parameter.ParameterData,

    pub fn createClass(data: *const class.ClassData) PathType {
        return .{ .class = data };
    }

    pub fn createParameter(data: *const parameter.ParameterData) PathType {
        return .{ .parameter = data };
    }
};

pub fn getPathHash(parent: u64, child_path: []const u8) u64 {
    var inc = hasher.IncrementalHasher.load(parent);
    return inc.update(child_path)
    .final();
}

pub fn getPath(allocator: Allocator, store: *const storage.ParamAllocator, pathType: PathType) ![]const u8 {
    var next: class.ClassStorage("parent") = undefined;
    var list: std.ArrayList([]const u8) = blk: {switch (pathType) {
        .class => |data| {
            next = data.parent;
            const name_ptr: []const u8 = try store.retrieve(data.nameIdx);
            var result = std.ArrayList([]const u8).empty;
            try result.append(allocator, name_ptr);
            break :blk result;
        },
        .parameter => |data| {
            const parentHandle = try data.parent.handle.validateHandle(store);
            const parentData: *const class.ClassData = parentHandle.ptr;
            const name_ptr: []const u8 = try store.retrieve(data.nameIdx);
            var result = std.ArrayList([]const u8).empty;
            try result.append(allocator, name_ptr);

            const parent_name_ptr: []const u8 = try store.retrieve(parentData.nameIdx);
            try result.append(allocator, parent_name_ptr);
            next = parentData.parent;
            break :blk result;
        },
    }};

    var iter = next.iterator(store);
    while (iter.next()) |parent| {
        const handle = try parent.handle.validateHandle(store);
        const parentData: *const class.ClassData = handle.ptr;
        const parent_name_ptr: []const u8 = try store.retrieve(parentData.nameIdx);
        try list.append(allocator, parent_name_ptr);
    }

    const slice = try list.toOwnedSlice(allocator);
    defer allocator.free(slice);

    std.mem.reverse([]const u8, slice);
    const path = try std.mem.join(allocator, PathSeparator, slice);

    return path;
}


test "paths: joinPaths empty slice" {
    const result = try joinPaths(std.testing.allocator, &[_][]const u8{});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "paths: joinPaths single segment" {
    const result = try joinPaths(std.testing.allocator, &[_][]const u8{"player"});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("player", result);
}

test "paths: joinPaths two segments" {
    const result = try joinPaths(std.testing.allocator, &[_][]const u8{ "player", "health" });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("player.health", result);
}

test "paths: joinPaths three segments" {
    const result = try joinPaths(std.testing.allocator, &[_][]const u8{ "world", "zone1", "enemy" });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("world.zone1.enemy", result);
}

test "paths: joinPaths deep hierarchy" {
    const result = try joinPaths(std.testing.allocator, &[_][]const u8{ "root", "game", "player", "stats", "health" });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("root.game.player.stats.health", result);
}

test "paths: joinPaths result is hashable" {
    const r1 = try joinPaths(std.testing.allocator, &[_][]const u8{ "player", "speed" });
    defer std.testing.allocator.free(r1);
    const r2 = try joinPaths(std.testing.allocator, &[_][]const u8{ "player", "speed" });
    defer std.testing.allocator.free(r2);

    try std.testing.expectEqual(hasher.hash(r1), hasher.hash(r2));
    try std.testing.expectEqual(hasher.hash(r1), hasher.hash("player.speed"));
}

test "paths: getName from nested path" {
    try std.testing.expectEqualStrings("health", getName("player.stats.health"));
}

test "paths: getName from two-segment path" {
    try std.testing.expectEqualStrings("gravity", getName("world.gravity"));
}

test "paths: getName from root (no dot) returns whole string" {
    try std.testing.expectEqualStrings("player", getName("player"));
}

test "paths: getParent from nested path" {
    try std.testing.expectEqualStrings("player.stats", getParent("player.stats.health"));
}

test "paths: getParent from two-segment path" {
    try std.testing.expectEqualStrings("player", getParent("player.health"));
}

test "paths: getParent from root returns empty string" {
    try std.testing.expectEqualStrings("", getParent("player"));
}

test "paths: getParent and getName roundtrip" {
    const full = "game.world.player.stats.health";
    const name   = getName(full);
    const parent = getParent(full);

    try std.testing.expectEqualStrings("health",                 name);
    try std.testing.expectEqualStrings("game.world.player.stats", parent);
    try std.testing.expectEqualStrings("game.world.player",       getParent(parent));
    try std.testing.expectEqualStrings("stats",                   getName(parent));
}
