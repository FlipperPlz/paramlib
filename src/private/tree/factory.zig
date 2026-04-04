const std         = @import("std");
const Allocator   = std.mem.Allocator;
const storage     = @import("../data/storage.zig");
const params      = @import("../slabs/parameter.zig");
const class       = @import("../slabs/class.zig");
const hasher      = @import("../utils/hasher.zig");
const handles     = @import("../utils/handles.zig");
const query       = @import("./query.zig");
const refs        = @import("./references.zig");
const paths       = @import("../utils/paths.zig");
const enumerable  = @import("../slabs/enum.zig");

pub fn createClass(allocator: Allocator, io: std.Io, store: *storage.ParamAllocator, init: class.ClassInit) !*const class.ClassData {
    const clazz = try store.alloc(allocator, io, init);
    errdefer store.free(allocator, clazz.index) catch @panic("OOM");

    if (init.base) |baseHandle|
        try refs.retainHandle(store, baseHandle);

    return clazz.ptr;
}

pub fn createParameter(
    allocator: Allocator,
    io: std.Io,
    store: *storage.ParamAllocator,
    init: params.ParameterInit
) !struct{id: params.ParameterIdentifier, ptr: *const params.ParameterData }{
    const param = try store.alloc(allocator, io, init);
    errdefer store.free(allocator, param.index);

    return .{.id = param.index, .ptr = param.ptr};
}



pub fn getOrCreateParameter(
    allocator: Allocator,
    io: std.Io,
    store: *storage.ParamAllocator,
    init: params.ParameterInit
) !struct{id: params.ParameterIdentifier, ptr: *const params.ParameterData } {
    var resolved_init = init;

    if (resolved_init.pathHash == null) {
        const path = blk: {
            const parentData: *const class.ClassData = (try init.parent.validateHandle(store)).ptr;
            var hash = hasher.IncrementalHasher.load(parentData.pathHash);
            break :blk hash.updateSep().update(init.name).final();
        };

        resolved_init.pathHash = path;
    }

    if (query.lookupParameterByPathHash(store, resolved_init.pathHash.?)) |existing|{
        return .{
            .id = existing.getIdentifier(store) orelse return error.UnknownIdentifier,
            .ptr = existing,
        };
    }

    const next = try createParameter(allocator, io, store, init);
    return .{
        .id = next.id,
        .ptr = next.ptr,
    };
}

pub fn getOrCreateClass(allocator: Allocator, io: std.Io, store: *storage.ParamAllocator, init: class.ClassInit) !*const class.ClassData {
    var resolved_init = init;

    if (resolved_init.pathHash == null) {
        const path = if (init.parent) |parentHandle| blk: {
            const parentData: *const class.ClassData = (try parentHandle.validateHandle(store)).ptr;
            var hash = hasher.IncrementalHasher.load(parentData.pathHash);
            break :blk hash.updateSep().update(init.name).final();
        } else blk: {
            break :blk hasher.hash(init.name);
        };

        resolved_init.pathHash = path;
    }
    if (query.lookupClassByPathHash(store, resolved_init.pathHash.?)) |existing| return existing;

    return createClass(allocator, io, store, resolved_init);
}

pub fn createDeleteMarker(
    allocator: Allocator,
    io:        std.Io,
    store:     *storage.ParamAllocator,
    name:      []const u8,
    parent:    ?class.ClassHandle,
    src:    anytype,
) !*const class.ClassData {
    return createClass(allocator, io, store, .{
        .name             = name,
        .parent           = parent,
        .source           = src,
        .access           = .readOnly,
        .is_delete        = true,
    });
}

pub fn deleteParameter(
    allocator: Allocator,
    store:     *storage.ParamAllocator,
    handle:    params.ParameterHandle,
) !void {
    const result = try handle.validateHandle(store);
    const param: *const params.ParameterData = result.ptr;

    if (param.parent.handleOrNull()) |parentHandle| {
        const parentResult = try parentHandle.validateHandle(store);
        const parentData: *class.ClassData = try parentResult.ptr.getMutable(store);

        var cur = parentData.params;
        if (cur.handle.id == handle.id) {
            parentData.params = param.sibling;
        } else {
            while (cur.hasNext()) {
                const curResult = try cur.handle.validateHandle(store);
                const curData: *params.ParameterData = try curResult.ptr.getMutable(store);
                if (curData.sibling.handle.id == handle.id) {
                    curData.sibling = param.sibling;
                    break;
                }
                cur = curData.sibling;
            }
        }
    }

    _ = store.pathToId.remove(param.pathHash);

    try store.free(allocator, handle.id);
}


pub fn deleteClass(
    allocator: Allocator,
    store:     *storage.ParamAllocator,
    handle:    class.ClassHandle,
) !void {
    const result = try handle.validateHandle(store);
    const data: *class.ClassData =  try result.ptr.getMutable(store);

    if(data.references.load(.monotonic) > 1) return error.ClassInUse;

    var child = data.children;
    while (child.hasNext()) {
        const childHandle = child.handle;
        const childData: *const class.ClassData = (try childHandle.validateHandle(store)).ptr;
        child = childData.sibling;
        try deleteClass(allocator, store, childHandle);
    }

    var p = data.params;
    while (p.hasNext()) {
        const paramHandle = p.handle;
        const paramData: *const params.ParameterData = (try paramHandle.validateHandle(store)).ptr;
        p = paramData.sibling;
        _ = store.pathToId.remove(paramData.pathHash);
        try store.free(allocator, paramHandle.id);
    }
    data.params = params.ParameterStorage("sibling").empty;

    if (data.base.handleOrNull()) |baseHandle| {
        refs.releaseHandle(store, baseHandle) catch {};
    }

    if (data.parent.handleOrNull()) |parentHandle| {
        if (parentHandle.validateHandle(store)) |parentResult| {
            const parentData: *class.ClassData = try parentResult.ptr.getMutable(store);
            var cur = parentData.children;
            if (cur.handle.id == handle.id) {
                parentData.children = data.sibling;
            } else {
                while (cur.hasNext()) {
                    const curResult = cur.handle.validateHandle(store) catch break;
                    const curData: *class.ClassData = try curResult.ptr.getMutable(store);
                    if (curData.sibling.handle.id == handle.id) {
                        curData.sibling = data.sibling;
                        break;
                    }
                    cur = curData.sibling;
                }
            }
        } else |_| {}
    } else {
        var cur = store.root;
        if (cur.handle.id == handle.id) {
            store.root = data.sibling;
        } else {
            while (cur.hasNext()) {
                const curResult = cur.handle.validateHandle(store ) catch break;
                const curData: *class.ClassData = try curResult.ptr.getMutable(store);
                if (curData.sibling.handle.id == handle.id) {
                    curData.sibling = data.sibling;
                    break;
                }
                cur = curData.sibling;
            }
        }
    }

    _ = store.pathToId.remove(data.pathHash);

    try store.free(allocator, handle.id);
}

const source = @import("../slabs/source.zig");

test "factory: createClass root class — alive and generation 1" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    // Need a root handle as parent — create one via storage directly first
    const root_raw = try store.alloc(std.testing.allocator, std.testing.io, class.ClassInit{
        .name = "__root__", .parent = null, .source = source.SourceHandle.invalid,
    });
    const rootHandle = class.ClassHandle{
        .id         = root_raw.index,
        .generation = root_raw.ptr.generation,
    };

    const data = try createClass(std.testing.allocator, std.testing.io, &store, .{
        .name   = "player",
        .parent = rootHandle,
        .source = source.SourceHandle.invalid,
    });

    try std.testing.expect(data.alive);
    try std.testing.expectEqual(@as(u32, 1), data.generation);
}

test "factory: createClass — class is findable via query.findClass" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const root_raw = try store.alloc(std.testing.allocator, std.testing.io, class.ClassInit{
        .name = "__root__", .parent = null, .source = source.SourceHandle.invalid,
    });
    const rootHandle = class.ClassHandle{
        .id         = root_raw.index,
        .generation = root_raw.ptr.generation,
    };

    _ = try createClass(std.testing.allocator, std.testing.io, &store, .{
        .name   = "npc",
        .parent = rootHandle,
        .source = source.SourceHandle.invalid,
    });

    // findClass by full dotted path
    const found = query.lookupClass(&store, "__root__.npc");
    try std.testing.expect(found != null);
    try std.testing.expect(found.?.alive);
}

const database = @import("../../api/database.zig");

test "factory: createClass — sibling chain links into parent" {
    var db = try database.ParamDatabase.init(std.testing.allocator, std.testing.io);
    defer db.deinit(std.testing.allocator, std.testing.io);

    const root_raw = try db.store.alloc(std.testing.allocator, std.testing.io, class.ClassInit{
        .name = "world", .parent = null, .source = source.SourceHandle.invalid
    });
    const worldClass: *const class.ClassData =root_raw.ptr;
    const worldHandle = class.ClassHandle{
        .id         = root_raw.index,
        .generation = worldClass.generation,
    };

    _ = try createClass(std.testing.allocator, std.testing.io, &db.store, .{
        .name = "zone1", .parent = worldHandle, .source = source.SourceHandle.invalid,
    });
    _ = try createClass(std.testing.allocator, std.testing.io, &db.store, .{
        .name = "zone2", .parent = worldHandle, .source = source.SourceHandle.invalid,
    });

    // Both children should be discoverable via pattern query
    const root = &db.store.root;
    const results = try query.findClassesByPattern(std.testing.allocator, &db.store, root, "world.*");
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "factory: createClass with base class — increments base references" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const root_raw = try store.alloc(std.testing.allocator, std.testing.io, class.ClassInit{
        .name = "root", .parent = null, .source = source.SourceHandle.invalid,
    });
    const rootHandle = class.ClassHandle{
        .id         = root_raw.index,
        .generation = root_raw.ptr.generation,
    };

    const base_raw = try createClass(std.testing.allocator, std.testing.io, &store, .{
        .name = "BaseEntity", .parent = rootHandle, .source = source.SourceHandle.invalid,
    });
    const initial_refs = base_raw.references.load(.monotonic);

    const baseHandle = class.ClassHandle{
        .id = store.pathToId.get(base_raw.pathHash).?.clazz,
        .generation = base_raw.generation,
    };

    _ = try createClass(std.testing.allocator, std.testing.io, &store, .{
        .name   = "Enemy",
        .parent = rootHandle,
        .source = source.SourceHandle.invalid,
        .base   = baseHandle,
    });

    const base_after = query.lookupClass(&store, "root.BaseEntity").?;
    try std.testing.expectEqual(initial_refs + 1, base_after.references.load(.monotonic));
}

test "factory: createClass with invalid parent returns error" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const bad_handle = class.ClassHandle{ .id = @enumFromInt(999), .generation = 1 };
    try std.testing.expectError(error.InvalidId, createClass(std.testing.allocator, std.testing.io, &store, .{
        .name   = "orphan",
        .parent = bad_handle,
        .source = source.SourceHandle.invalid,
    }));
}

fn allocRootClass(
    allocator: Allocator,
    store: *storage.ParamAllocator,
    name: []const u8,
) !class.ClassHandle {
    const raw = try store.alloc(allocator, std.testing.io, class.ClassInit{
        .name   = name,
        .parent = null,
        .source = source.SourceHandle.invalid,
    });
    return .{ .id = raw.index, .generation = raw.ptr.generation };
}

test "delete marker: is_delete_marker is false on normal class" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const h = try allocRootClass(std.testing.allocator, &store, "NormalClass");
    const d = store.classes.get(h.id);
    try std.testing.expect(!d.is_delete_marker);
}

test "delete marker: createDeleteMarker sets is_delete_marker = true" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const marker = try createDeleteMarker(
        std.testing.allocator, std.testing.io, &store,
        "DeletedClass", null, source.SourceHandle.invalid,
    );
    try std.testing.expect(marker.is_delete_marker);
    try std.testing.expect(marker.alive);
    try std.testing.expectEqual(class.ClassAccess.readOnly, marker.access);
}

test "delete marker: tombstone has no children and no params" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const marker = try createDeleteMarker(
        std.testing.allocator, std.testing.io, &store,
        "Ghost", null, source.SourceHandle.invalid,
    );
    try std.testing.expect(!marker.children.hasNext());
    try std.testing.expect(!marker.params.hasNext());
}

test "delete marker: tombstone is hidden from lookupClass" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    _ = try createDeleteMarker(
        std.testing.allocator, std.testing.io, &store,
        "ToDelete", null, source.SourceHandle.invalid,
    );

    // lookupClass must NOT expose tombstones to callers
    try std.testing.expect(query.lookupClass(&store, "ToDelete") == null);

    // But the entry IS in pathToId — merge logic needs to find it via
    // the raw store, not via the public query API
    const h = hasher.hash("ToDelete");
    try std.testing.expect(store.pathToId.contains(h));
}

test "delete marker: tombstone is skipped by findClassesByPattern wildcard" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    _ = try allocRootClass(std.testing.allocator, &store, "RealClass");
    _ = try createDeleteMarker(
        std.testing.allocator, std.testing.io, &store,
        "GhostClass", null, source.SourceHandle.invalid,
    );

    const root    = &store.root;
    const results = try query.findClassesByPattern(std.testing.allocator, &store, root, "*");
    defer std.testing.allocator.free(results);

    // Only RealClass should appear — GhostClass is a tombstone and must be filtered
    try std.testing.expectEqual(@as(usize, 1), results.len);
    const name = try store.retrieve(results[0].class.nameIdx);
    try std.testing.expectEqualStrings("RealClass", name);
}
const values = @import("../data/value.zig");
fn allocParam(
    allocator: Allocator,
    store: *storage.ParamAllocator,
    name: []const u8,
    parent: class.ClassHandle,
    value: values.Value,
) !params.ParameterIdentifier {
    const raw = try store.alloc(allocator, std.testing.io, params.ParameterInit {
        .name   = name,
        .parent = parent,
        .source = source.SourceHandle.invalid,
        .value  = value,
    });
    return raw.index;
}

test "deleteParameter: lookup returns null after deletion" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const cls_h = try allocRootClass(std.testing.allocator, &store, "Owner");
    const p_id  = try allocParam(std.testing.allocator, &store, "speed", cls_h, values.Value.initF32(5.0));

    try std.testing.expect(query.lookupParameter(&store, "Owner.speed") != null);

    const p_handle = params.ParameterHandle{
        .id         = p_id,
        .generation = store.parameters.get(p_id).generation,
    };
    try deleteParameter(std.testing.allocator, &store, p_handle);

    try std.testing.expect(query.lookupParameter(&store, "Owner.speed") == null);
}

test "deleteParameter: unlinks from parent params list — sibling still visible" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const cls_h = try allocRootClass(std.testing.allocator, &store, "MultiParam");
    const a_id  = try allocParam(std.testing.allocator, &store, "alpha", cls_h, values.Value.initI32(1));
    _           = try allocParam(std.testing.allocator, &store, "beta",  cls_h, values.Value.initI32(2));

    const a_handle = params.ParameterHandle{
        .id         = a_id,
        .generation = store.parameters.get(a_id).generation,
    };
    try deleteParameter(std.testing.allocator, &store, a_handle);

    // alpha is gone, beta must still be reachable
    try std.testing.expect(query.lookupParameter(&store, "MultiParam.alpha") == null);
    try std.testing.expect(query.lookupParameter(&store, "MultiParam.beta")  != null);
}

test "deleteParameter: slab slot generation is bumped (handle goes stale)" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const cls_h = try allocRootClass(std.testing.allocator, &store, "GenCheck");
    const p_id  = try allocParam(std.testing.allocator, &store, "val", cls_h, values.Value.initI32(99));

    const old_gen = store.parameters.get(p_id).generation;
    const p_handle = params.ParameterHandle{ .id = p_id, .generation = old_gen };

    try deleteParameter(std.testing.allocator, &store, p_handle);

    // Generation must have been bumped by SlabPool.release
    const new_gen = store.parameters.get(p_id).generation;
    try std.testing.expect(new_gen != old_gen);

    // validateHandle must now return StaleHandle
    try std.testing.expectError(error.StaleHandle, p_handle.validateHandle(&store));
}

test "deleteParameter: deleting all params leaves parent with empty list" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const cls_h = try allocRootClass(std.testing.allocator, &store, "EmptyAfter");
    const p1_id = try allocParam(std.testing.allocator, &store, "x", cls_h, values.Value.initF32(1.0));
    const p2_id = try allocParam(std.testing.allocator, &store, "y", cls_h, values.Value.initF32(2.0));

    const p1_h = params.ParameterHandle{ .id = p1_id, .generation = store.parameters.get(p1_id).generation };
    const p2_h = params.ParameterHandle{ .id = p2_id, .generation = store.parameters.get(p2_id).generation };

    try deleteParameter(std.testing.allocator, &store, p1_h);
    try deleteParameter(std.testing.allocator, &store, p2_h);

    const cls_data = store.classes.get(cls_h.id);
    try std.testing.expect(!cls_data.params.hasNext());
}

test "deleteClass: lookup returns null after deletion" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const h = try allocRootClass(std.testing.allocator, &store, "Doomed");
    try std.testing.expect(query.lookupClass(&store, "Doomed") != null);

    try deleteClass(std.testing.allocator, &store, h);

    try std.testing.expect(query.lookupClass(&store, "Doomed") == null);
}

test "deleteClass: handle goes stale after deletion" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const h = try allocRootClass(std.testing.allocator, &store, "Stale");
    try deleteClass(std.testing.allocator, &store, h);

    try std.testing.expectError(error.StaleHandle, h.validateHandle(&store));
}

test "deleteClass: deletes all owned parameters" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const h = try allocRootClass(std.testing.allocator, &store, "ParamOwner");
    _ = try allocParam(std.testing.allocator, &store, "hp",  h, values.Value.initI32(100));
    _ = try allocParam(std.testing.allocator, &store, "mp",  h, values.Value.initI32(50));
    _ = try allocParam(std.testing.allocator, &store, "spd", h, values.Value.initF32(1.5));

    try deleteClass(std.testing.allocator, &store, h);

    try std.testing.expect(query.lookupParameter(&store, "ParamOwner.hp")  == null);
    try std.testing.expect(query.lookupParameter(&store, "ParamOwner.mp")  == null);
    try std.testing.expect(query.lookupParameter(&store, "ParamOwner.spd") == null);
}

fn allocChildClass(
    allocator: Allocator,
    store: *storage.ParamAllocator,
    name: []const u8,
    parent: class.ClassHandle,
) !class.ClassHandle {
    const raw = try store.alloc(allocator, std.testing.io, class.ClassInit {
        .name   = name,
        .parent = parent,
        .source = source.SourceHandle.invalid,
    });
    const data: *const class.ClassData = raw.ptr;
    return .{ .id = raw.index, .generation = data.generation };
}

test "deleteClass: recursively deletes children" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const root  = try allocRootClass(std.testing.allocator,  &store, "CfgRoot");
    const child = try allocChildClass(std.testing.allocator, &store, "Child",  root);
    _           = try allocChildClass(std.testing.allocator, &store, "GrandChild", child);

    try deleteClass(std.testing.allocator, &store, root);

    try std.testing.expect(query.lookupClass(&store, "CfgRoot")            == null);
    try std.testing.expect(query.lookupClass(&store, "CfgRoot.Child")      == null);
    try std.testing.expect(query.lookupClass(&store, "CfgRoot.Child.GrandChild") == null);
}

test "deleteClass: sibling at same level survives deletion" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const parent  = try allocRootClass(std.testing.allocator,  &store, "Parent");
    const child_a = try allocChildClass(std.testing.allocator, &store, "ChildA", parent);
    _             = try allocChildClass(std.testing.allocator, &store, "ChildB", parent);

    try deleteClass(std.testing.allocator, &store, child_a);

    try std.testing.expect(query.lookupClass(&store, "Parent.ChildA") == null);
    try std.testing.expect(query.lookupClass(&store, "Parent.ChildB") != null);
    // Parent itself must still be alive
    try std.testing.expect(query.lookupClass(&store, "Parent") != null);
}

test "deleteClass: root-level sibling survives deletion of another root" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const root_a = try allocRootClass(std.testing.allocator, &store, "RootA");
    _            = try allocRootClass(std.testing.allocator, &store, "RootB");

    try deleteClass(std.testing.allocator, &store, root_a);

    try std.testing.expect(query.lookupClass(&store, "RootA") == null);
    try std.testing.expect(query.lookupClass(&store, "RootB") != null);
}

test "deleteClass: deep tree — children's params all removed" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const cfg    = try allocRootClass(std.testing.allocator,  &store, "CfgVehicles");
    const car    = try allocChildClass(std.testing.allocator, &store, "Car",   cfg);
    const truck  = try allocChildClass(std.testing.allocator, &store, "Truck", cfg);
    _ = try allocParam(std.testing.allocator, &store, "speed",  car,   values.Value.initF32(120.0));
    _ = try allocParam(std.testing.allocator, &store, "mass",   car,   values.Value.initF32(1200.0));
    _ = try allocParam(std.testing.allocator, &store, "speed",  truck, values.Value.initF32(90.0));
    _ = try allocParam(std.testing.allocator, &store, "mass",   truck, values.Value.initF32(8000.0));

    try deleteClass(std.testing.allocator, &store, cfg);

    // Everything gone
    try std.testing.expect(query.lookupClass(&store, "CfgVehicles")           == null);
    try std.testing.expect(query.lookupClass(&store, "CfgVehicles.Car")        == null);
    try std.testing.expect(query.lookupClass(&store, "CfgVehicles.Truck")      == null);
    try std.testing.expect(query.lookupParameter(&store, "CfgVehicles.Car.speed")   == null);
    try std.testing.expect(query.lookupParameter(&store, "CfgVehicles.Car.mass")    == null);
    try std.testing.expect(query.lookupParameter(&store, "CfgVehicles.Truck.speed") == null);
    try std.testing.expect(query.lookupParameter(&store, "CfgVehicles.Truck.mass")  == null);
}

// ============================================================================
// getOrCreateClass
// ============================================================================

test "getOrCreateClass: second call with same name returns existing class" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const a = try getOrCreateClass(std.testing.allocator, std.testing.io, &store, .{
        .name   = "Singleton",
        .parent = null,
        .source = source.SourceHandle.invalid,
    });
    const b = try getOrCreateClass(std.testing.allocator, std.testing.io, &store, .{
        .name   = "Singleton",
        .parent = null,
        .source = source.SourceHandle.invalid,
    });

    // Same pointer — no duplicate allocated
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(a.pathHash, b.pathHash);
}

test "getOrCreateClass: different names create distinct classes" {
    var store = storage.ParamAllocator.empty;
    defer store.deinit(std.testing.allocator);

    const a = try getOrCreateClass(std.testing.allocator, std.testing.io, &store, .{
        .name = "Alpha", .parent = null, .source = source.SourceHandle.invalid,
    });
    const b = try getOrCreateClass(std.testing.allocator, std.testing.io, &store, .{
        .name = "Beta",  .parent = null, .source = source.SourceHandle.invalid,
    });

    try std.testing.expect(a != b);
    try std.testing.expect(a.pathHash != b.pathHash);
}