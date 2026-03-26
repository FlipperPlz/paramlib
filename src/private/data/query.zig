const std     = @import("std");
const storage = @import("storage.zig");
const params  = @import("../slabs/parameter.zig");
const class   = @import("../slabs/class.zig");
const hasher  = @import("../utils/hasher.zig");
const Allocator = std.mem.Allocator;

pub const QueryType = enum {
    class,
    parameter,
};

pub const QueryResult = union(enum) {
    class:     *class.ClassData,
    parameter: *params.ParameterData,
};

const PatternSegments = struct {
    segments: [][]const u8,

    fn init(allocator: Allocator, pattern: []const u8) !PatternSegments {
        var segments = std.ArrayList([]const u8).empty;
        defer segments.deinit();

        var iter = std.mem.splitSequence(u8, pattern, ".");
        while (iter.next()) |segment| {
            if (segment.len > 0) {
                try segments.append(allocator, segment);
            }
        }

        return .{
            .segments = try segments.toOwnedSlice(allocator),
        };
    }

    fn deinit(self: *PatternSegments, allocator: Allocator) void {
        allocator.free(self.segments);
    }

    fn isWildcard(segment: []const u8) bool {
        return std.mem.eql(u8, segment, "*");
    }
};

pub fn findParameter(store: *storage.ParamStorage, path: []const u8) ?*params.ParameterData {
    const hash = hasher.hash(path);
    const id = store.pathToId.get(hash) orelse return null;
    if(id != .par) return null;
    return @ptrCast(store.retrieve(id) catch return null);
}

pub fn findClass(store: *storage.ParamStorage, path: []const u8) ?*class.ClassData {
    const hash = hasher.hash(path);
    const id = store.pathToId.get(hash) orelse return null;
    if(id != .clazz) return null;
    return @ptrCast(store.retrieve(id) catch return null);
}

pub fn findClassesByPattern(allocator: Allocator,store: *storage.ParamStorage,pattern: []const u8,) ![]QueryResult {
    var segments = try PatternSegments.init(allocator, pattern);
    defer segments.deinit(allocator);

    var results = std.ArrayList(QueryResult).empty;
    errdefer results.deinit(allocator);

    if (segments.segments.len == 0) {
        return results.toOwnedSlice(allocator);
    }

    var root_class = class.ClassStorage("sibling").empty;
    try matchClassesRecursive(store, &root_class, segments.segments, 0, &results);

    return results.toOwnedSlice(allocator);
}

fn matchClassesRecursive(
    store:            *storage.ParamStorage,
    current_class:    *class.ClassStorage("sibling"),
    pattern_segments: [][]const u8,
    segment_idx:      usize,
    results:          *std.ArrayList(QueryResult),
) !void {
    if (segment_idx >= pattern_segments.len) {
        return;
    }

    const current_segment = pattern_segments[segment_idx];
    const is_wildcard = PatternSegments.isWildcard(current_segment);
    const is_last_segment = segment_idx == pattern_segments.len - 1;

    var iter = current_class.iterator(store);
    while (iter.next()) |sibling_storage| {
        const sibling: *class.ClassData = @ptrCast(try store.retrieve(sibling_storage.handle.id));

        if (!sibling.alive) continue;

        const sibling_name_segment = (store.pathSegments.get(sibling.nameIdx) catch continue) orelse continue;
        const sibling_name = (store.pathSegments.values.get(sibling_name_segment.idx) catch continue) orelse continue;

        const name_matches = is_wildcard or std.mem.eql(u8, sibling_name, current_segment);

        if (!name_matches) continue;

        if (is_last_segment) {
            try results.append(.{ .class = sibling });
        } else if (PatternSegments.isWildcard(pattern_segments[segment_idx + 1])) {
            try results.append(.{ .class = sibling });
            var next_sibling = sibling.sibling;
            try matchClassesRecursive(store, &next_sibling, pattern_segments, segment_idx + 1, results);
        } else {
            var child_sibling = sibling.sibling;
            try matchClassesRecursive(store, &child_sibling, pattern_segments, segment_idx + 1, results);
        }
    }
}

pub fn findParametersByPattern(
    allocator:    Allocator,
    store:        *storage.ParamStorage,
    parent_class: *class.ClassData,
    pattern:      []const u8,
) ![]QueryResult {
    var segments = try PatternSegments.init(allocator, pattern);
    defer segments.deinit(allocator);

    var results = std.ArrayList(QueryResult).empty;
    errdefer results.deinit(allocator);

    if (segments.segments.len == 0) {
        return results.toOwnedSlice(allocator);
    }

    if (segments.segments.len == 1) {
        const segment = segments.segments[0];
        const is_wildcard = PatternSegments.isWildcard(segment);

        var param_iter = parent_class.params.iterator(store);
        while (param_iter.next()) |param_storage| {
            const param: *params.ParameterData = @ptrCast(try store.retrieve(param_storage.handle.id));
            if (!param.alive) continue;

            if (is_wildcard) {
                try results.append(allocator, .{ .parameter = param });
            } else {
                const param_name_segment = (store.pathSegments.get(param.nameIdx) catch continue) orelse continue;
                const param_name = (store.pathSegments.values.get(param_name_segment.idx) catch continue) orelse continue;
                if (std.mem.eql(u8, param_name, segment)) {
                    try results.append(allocator, .{ .parameter = param });
                }
            }
        }
    }

    return results.toOwnedSlice(allocator);
}