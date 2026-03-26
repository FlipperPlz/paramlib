const std         = @import("std");
const storage     = @import("../data/storage.zig");
const identifiers = @import("identifiers.zig");
const class       = @import("../slabs/class.zig");
const Allocator   = std.mem.Allocator;
const handles     = @import("./handles.zig");
const parameter   = @import("../slabs/parameter.zig");
const query       = @import("../data/query.zig");
pub const PathSeparator         = ".";
pub const PathSegmentIdentifier = identifiers.TypedId("PathSegment");

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

pub fn getPath(allocator: Allocator, store: *const storage.ParamStorage, pathType: PathType) ![]const u8 {
    var next: class.ClassStorage("parent") = undefined;
    var list: std.ArrayList([]const u8) = blk: {switch (pathType) {
        .class => |data| {
            next = data.parent;
            const name_ptr: *const []const u8 = @ptrCast(@alignCast(try store.retrieve(.create(data.nameIdx))));
            var result = std.ArrayList([]const u8).empty;
            try result.append(allocator, name_ptr.*);
            break :blk result;
        },
        .parameter => |data| {
            const parentHandle = try handles.validateHandle(store, data.parent.handle);
            const parentData: *const class.ClassData = @ptrCast(@alignCast(parentHandle.ptr));
            const name_ptr: *const []const u8 = @ptrCast(@alignCast(try store.retrieve(.create(data.nameIdx))));
            var result = std.ArrayList([]const u8).empty;
            try result.append(allocator, name_ptr.*);

            const parent_name_ptr: *const []const u8 = @ptrCast(@alignCast(try store.retrieve(.{ .segment = parentData.nameIdx })));
            try result.append(allocator, parent_name_ptr.*);
            next = parentData.parent;
            break :blk result;
        },
    }};

    var iter = next.iterator(store);
    while (iter.next()) |parent| {
        const handle = try handles.validateHandle(store, parent.handle);
        const parentData: *const class.ClassData = @ptrCast(@alignCast(handle.ptr));
        const parent_name_ptr: *const []const u8 = @ptrCast(@alignCast(try store.retrieve(.{ .segment = parentData.nameIdx })));
        try list.append(allocator, parent_name_ptr.*);
    }
    
    const slice = try list.toOwnedSlice(allocator);
    std.mem.reverse([]const u8, slice);
    const path = try std.mem.join(allocator, PathSeparator, slice);
    
    return path;
}

pub fn getName(path: []const u8) []const u8 {
    const sepIdx = std.mem.lastIndexOfScalar(u8, path, PathSeparator);
    if (sepIdx) |i| {
        return path[i + 1 ..];
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