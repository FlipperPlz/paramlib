const std     = @import("std");
const storage = @import("../data/storage.zig");
const params  = @import("../slabs/parameter.zig");
const class   = @import("../slabs/class.zig");
const hasher  = @import("../utils/hasher.zig");
const Allocator = std.mem.Allocator;

pub const QueryType = enum {
    class,
    parameter,
};

pub const QueryResult = union(enum) {
    class:     *const class.ClassData,
    parameter: *const params.ParameterData,
};

const PatternSegments = struct {
    segments: [][]const u8,

    fn init(allocator: Allocator, pattern: []const u8) !PatternSegments {
        var segments = std.ArrayList([]const u8).empty;
        defer segments.deinit(allocator);

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

pub fn lookupParameter(store: *storage.ParamAllocator, path: []const u8) ?*const params.ParameterData {
    const hash = hasher.hash(path);
    const id = store.pathToId.get(hash) orelse return null;
    if (id != .par) return null;
    const data: *const params.ParameterData = store.retrieve(id.par) catch return null;
    if (!data.alive) return null;
    return data;
}

pub fn findClassByNameHash(store: *storage.ParamAllocator, parent: *const class.ClassData, hash: u64) !?class.ClassHandle {
    var iter = parent.children.iterator(store);
    while (iter.next()) |next_handle|{
        if(hash == (try next_handle.current(store)).nameHash) return next_handle.handle;
    }
    return null;
}

pub fn findParameterByNameHash(store: *storage.ParamAllocator, parent: *const class.ClassData, hash: u64) !?params.ParameterHandle {
    var iter = parent.params.iterator(store);
    while (iter.next()) |next_handle|{
        if(hash == (try next_handle.current(store)).nameHash) return next_handle.handle;
    }
    return null;
}

pub fn lookupClassByPathHash(store: *storage.ParamAllocator, hash: u64) ?*const class.ClassData {
    const id = store.pathToId.get(hash) orelse return null;
    if (id != .clazz) return null;
    const data: *const class.ClassData = store.retrieve(id.clazz) catch return null;
    if (!data.alive or data.is_delete_marker) return null;
    return data;
}

pub fn lookupParameterByPathHash(store: *storage.ParamAllocator, hash: u64) ?*const params.ParameterData {
    const id = store.pathToId.get(hash) orelse return null;
    if (id != .par) return null;
    const data: *const params.ParameterData = store.retrieve(id.par) catch return null;
    if (!data.alive) return null;
    return data;
}

pub inline fn lookupClass(store: *storage.ParamAllocator, path: []const u8) ?*const class.ClassData {
    return lookupClassByPathHash(store, hasher.hash(path));
}

pub fn findClassesByPattern(allocator: Allocator, store: *storage.ParamAllocator, siblings: *const class.ClassStorage("sibling"), pattern: []const u8,) ![]QueryResult {
    var segments = try PatternSegments.init(allocator, pattern);
    defer segments.deinit(allocator);

    var results = std.ArrayList(QueryResult).empty;
    errdefer results.deinit(allocator);

    if (segments.segments.len == 0) {
        return results.toOwnedSlice(allocator);
    }

    try matchClassesRecursive(allocator, store, siblings, segments.segments, 0, &results);

    const slice = try results.toOwnedSlice(allocator);
    return slice;
}

fn matchClassesRecursive(
    allocator:        Allocator,
    store:            *storage.ParamAllocator,
    current_class:    *const class.ClassStorage("sibling"),
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
        const sibling: *const class.ClassData = try store.retrieve(sibling_storage.handle.id);

        if (!sibling.alive or sibling.is_delete_marker) continue;

        const sibling_name_segment = (store.pathSegments.get(sibling.nameIdx) catch continue) orelse continue;

        const name_matches = is_wildcard or std.mem.eql(u8, sibling_name_segment, current_segment);

        if (!name_matches) continue;

        if (is_last_segment) {
            try results.append(allocator, .{ .class = sibling });
        } else {
            var children = sibling.children;
            try matchClassesRecursive(allocator, store, &children, pattern_segments, segment_idx + 1, results);
        }
    }
}

pub fn findParametersByPattern(
    allocator:    Allocator,
    store:        *storage.ParamAllocator,
    parent_class: *const class.ClassData,
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
            const param: *const params.ParameterData = try store.retrieve(param_storage.handle.id);
            if (!param.alive) continue;

            if (is_wildcard) {
                try results.append(allocator, .{ .parameter = param });
            } else {
                const param_name_segment = (store.pathSegments.get(param.nameIdx) catch continue) orelse continue;
                if (std.mem.eql(u8, param_name_segment, segment)) {
                    try results.append(allocator, .{ .parameter = param });
                }
            }
        }
    }

    const slice = try results.toOwnedSlice(allocator);
    return slice;
}

const source = @import("../slabs/source.zig");
const values = @import("../data/value.zig");

test "query: findClass returns null on empty store" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    try std.testing.expect(lookupClass(&store, "player") == null);
}

test "query: findClass finds a root class by path" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    _ = try store.alloc(std.testing.allocator, std.testing.io, class.ClassInit {
        .name = "enemy", .parent = null, .source = source.SourceHandle.invalid,
    });

    const found = lookupClass(&store, "enemy");
    try std.testing.expect(found != null);
    try std.testing.expect(found.?.alive);
}

test "query: findClass returns null for wrong path" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    _ = try store.alloc(std.testing.allocator, std.testing.io, class.ClassInit {
        .name = "npc", .parent = null, .source = source.SourceHandle.invalid,
    });

    try std.testing.expect(lookupClass(&store, "player") == null);
    try std.testing.expect(lookupClass(&store, "npc.stats") == null);
}

test "query: findClass finds nested class" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const root = try store.alloc(std.testing.allocator, std.testing.io, class.ClassInit {
        .name = "world", .parent = null, .source = source.SourceHandle.invalid,
    });
    const rootHandle = class.ClassHandle{
        .id         = root.index,
        .generation = root.ptr.generation,
    };
    _ = try store.alloc(std.testing.allocator, std.testing.io, class.ClassInit {
        .name = "zone1", .parent = rootHandle, .source = source.SourceHandle.invalid,
    });

    try std.testing.expect(lookupClass(&store, "world.zone1") != null);
    try std.testing.expect(lookupClass(&store, "world") != null);
    try std.testing.expect(lookupClass(&store, "zone1") == null); // not a root path
}

test "query: findClass does not return a parameter" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const root = try store.alloc(std.testing.allocator, std.testing.io, class.ClassInit {
        .name = "cfg", .parent = null, .source = source.SourceHandle.invalid,
    });
    const parentHandle = class.ClassHandle{
        .id         = root.index,
        .generation = root.ptr.generation,
    };
    _ = try store.alloc(std.testing.allocator, std.testing.io, params.ParameterInit{
        .name = "volume", .parent = parentHandle,
        .source = source.SourceHandle.invalid, .value = values.Value.initF32(1.0),
    });

    // "cfg.volume" is a parameter, not a class — findClass must return null
    try std.testing.expect(lookupClass(&store, "cfg.volume") == null);
}

test "query: findParameter returns null on empty store" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    try std.testing.expect(lookupParameter(&store, "player.health") == null);
}

test "query: findParameter finds a parameter by full path" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const root = try store.alloc(std.testing.allocator, std.testing.io, class.ClassInit{
        .name = "player", .parent = null, .source = source.SourceHandle.invalid,
    });
    const parentHandle = class.ClassHandle{
        .id         = root.index,
        .generation = root.ptr.generation,
    };
    _ = try store.alloc(std.testing.allocator, std.testing.io, params.ParameterInit{
        .name = "health", .parent = parentHandle,
        .source = source.SourceHandle.invalid, .value = values.Value.initI32(100),
    });

    const found = lookupParameter(&store, "player.health");
    try std.testing.expect(found != null);
    try std.testing.expect(found.?.alive);
    try std.testing.expectEqual(values.Value.initI32(100), found.?.value);
}

test "query: findParameter does not return a class" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    _ = try store.alloc(std.testing.allocator, std.testing.io, class.ClassInit{
        .name = "player", .parent = null, .source = source.SourceHandle.invalid,
    });

    // "player" is a class, not a parameter — findParameter must return null
    try std.testing.expect(lookupParameter(&store, "player") == null);
}

test "query: findParameter returns null for wrong path" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const root = try store.alloc(std.testing.allocator, std.testing.io, class.ClassInit{
        .name = "cfg", .parent = null, .source = source.SourceHandle.invalid,
    });
    const parentHandle = class.ClassHandle{
        .id         = root.index,
        .generation = root.ptr.generation,
    };
    _ = try store.alloc(std.testing.allocator, std.testing.io, params.ParameterInit{
        .name = "volume", .parent = parentHandle,
        .source = source.SourceHandle.invalid, .value = values.Value.initF32(0.5),
    });

    try std.testing.expect(lookupParameter(&store, "cfg.brightness") == null);
    try std.testing.expect(lookupParameter(&store, "volume") == null);
}

const database = @import("../../api/database.zig");

test "query: findClassesByPattern empty pattern returns empty" {
    var db = try database.ParamDatabase.init(std.testing.allocator, std.testing.io);
    defer db.deinit(std.testing.allocator, std.testing.io);

    _ = try db.store.alloc(std.testing.allocator, std.testing.io, class.ClassInit{
        .name = "player", .parent = null, .source = source.SourceHandle.invalid
    });
    const root = &db.store.root;

    const results = try findClassesByPattern(std.testing.allocator, &db.store, root, "");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "query: findClassesByPattern exact root name match" {
    var db = try database.ParamDatabase.init(std.testing.allocator, std.testing.io);
    defer db.deinit(std.testing.allocator, std.testing.io);

    _ = try db.store.alloc(std.testing.allocator, std.testing.io, class.ClassInit{
        .name = "enemy", .parent = null, .source = source.SourceHandle.invalid
    });
    _ = try db.store.alloc(std.testing.allocator, std.testing.io, class.ClassInit{
        .name = "player", .parent = null, .source = source.SourceHandle.invalid
    });

    const root = &db.store.root;
    const results = try findClassesByPattern(std.testing.allocator, &db.store, root, "enemy");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
}

test "query: findClassesByPattern wildcard matches all root classes" {
    var db = try database.ParamDatabase.init(std.testing.allocator, std.testing.io);
    defer db.deinit(std.testing.allocator, std.testing.io);

    _ = try db.store.alloc(std.testing.allocator, std.testing.io, class.ClassInit{
        .name = "a", .parent = null, .source = source.SourceHandle.invalid
    });
    _ = try db.store.alloc(std.testing.allocator, std.testing.io, class.ClassInit{
        .name = "b", .parent = null, .source = source.SourceHandle.invalid
    });
    _ = try db.store.alloc(std.testing.allocator, std.testing.io, class.ClassInit{
        .name = "c", .parent = null, .source = source.SourceHandle.invalid
    });

    const root = &db.store.root;
    const results = try findClassesByPattern(std.testing.allocator, &db.store, root, "*");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 3), results.len);
}

test "query: findClassesByPattern no match returns empty" {
    var db = try database.ParamDatabase.init(std.testing.allocator, std.testing.io);
    defer db.deinit(std.testing.allocator, std.testing.io);

    _ = try db.store.alloc(std.testing.allocator, std.testing.io, class.ClassInit{
        .name = "npc", .parent = null, .source = source.SourceHandle.invalid
    });

    const root = &db.store.root;
    const results = try findClassesByPattern(std.testing.allocator, &db.store, root, "player");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "query: findParametersByPattern empty pattern returns empty" {
    var db = try database.ParamDatabase.init(std.testing.allocator, std.testing.io);
    defer db.deinit(std.testing.allocator, std.testing.io);

    const root = try db.store.alloc(std.testing.allocator, std.testing.io, class.ClassInit{
        .name = "cfg", .parent = null, .source = source.SourceHandle.invalid
    });
    const parentHandle = class.ClassHandle{
        .id         = root.index,
        .generation = root.ptr.generation,
    };
    const clazz: *const class.ClassData = root.ptr;

    const results = try findParametersByPattern(std.testing.allocator, &db.store, clazz, "");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
    _ = parentHandle;
}

test "query: findParametersByPattern exact name match" {
    var db = try database.ParamDatabase.init(std.testing.allocator, std.testing.io);
    defer db.deinit(std.testing.allocator, std.testing.io);

    const root = try db.store.alloc(std.testing.allocator, std.testing.io, class.ClassInit{
        .name = "settings", .parent = null, .source = source.SourceHandle.invalid
    });
    const parentHandle = class.ClassHandle{
        .id         = root.index,
        .generation =  root.ptr.generation,
    };
    _ = try db.store.alloc(std.testing.allocator, std.testing.io, params.ParameterInit{
        .name = "volume", .parent = parentHandle,
        .source = source.SourceHandle.invalid, .value = values.Value.initF32(0.8),
    });
    _ = try db.store.alloc(std.testing.allocator, std.testing.io, params.ParameterInit{
        .name = "brightness", .parent = parentHandle,
        .source = source.SourceHandle.invalid, .value = values.Value.initF32(1.0),
    });

    const clazz: *const class.ClassData =root.ptr;
    const results = try findParametersByPattern(std.testing.allocator, &db.store, clazz, "volume");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
}

test "query: findParametersByPattern wildcard returns all parameters" {
    var db = try database.ParamDatabase.init(std.testing.allocator, std.testing.io);
    defer db.deinit(std.testing.allocator, std.testing.io);

    const root = try db.store.alloc(std.testing.allocator, std.testing.io, class.ClassInit{
        .name = "audio", .parent = null, .source = source.SourceHandle.invalid,
    });
    const parentHandle = class.ClassHandle{
        .id         = @enumFromInt(root.index.toIndex().?),
        .generation = (@as(*const class.ClassData, @ptrCast(@alignCast(root.ptr)))).generation,
    };
    _ = try db.store.alloc(std.testing.allocator, std.testing.io, params.ParameterInit{
        .name = "master",  .parent = parentHandle, .source = source.SourceHandle.invalid, .value = values.Value.initF32(1.0),
    });
    _ = try db.store.alloc(std.testing.allocator, std.testing.io, params.ParameterInit{
        .name = "music",   .parent = parentHandle, .source = source.SourceHandle.invalid, .value = values.Value.initF32(0.7),
    });
    _ = try db.store.alloc(std.testing.allocator, std.testing.io, params.ParameterInit{
        .name = "effects", .parent = parentHandle, .source = source.SourceHandle.invalid, .value = values.Value.initF32(0.9),
    });

    const clazz: *const class.ClassData = @ptrCast(@alignCast(root.ptr));
    const results = try findParametersByPattern(std.testing.allocator, &db.store, clazz, "*");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 3), results.len);
}
