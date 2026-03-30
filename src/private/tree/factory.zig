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

pub fn createClass(allocator: Allocator, io: std.Io, store: *storage.ParamStorage, init: class.ClassInit) !*class.ClassData {
    const clazz = try store.alloc(allocator, io, .createClass(init));
    errdefer store.free(allocator, clazz.index) catch @panic("OOM");

    if (init.base) |baseHandle|
        try refs.retainHandle(store, baseHandle);

    return @ptrCast(@alignCast(clazz.ptr));
}

pub fn getOrCreateClass(allocator: Allocator, io: std.Io, store: *storage.ParamStorage, init: class.ClassInit) !*class.ClassData {
    var resolved_init = init;

    if (resolved_init.pathHash == null) {
        const path = if (init.parent) |parentHandle| blk: {
            const parentData: *class.ClassData = @constCast(@ptrCast(@alignCast((try handles.validateHandle(store, parentHandle)).ptr)));
            //Using FNV-1a a non stateful hash really gives us leverage here
            break :blk paths.getPathHash(parentData.pathHash, init.name);
        } else blk: {
            break :blk hasher.hash(init.name);
        };

        if (query.lookupClassByPathHash(store, path)) |existing| return @constCast(existing);
        resolved_init.pathHash = path;
    }

    return createClass(allocator, io, store, resolved_init);
}

pub fn createDeleteMarker(
    allocator: Allocator,
    io:        std.Io,
    store:     *storage.ParamStorage,
    name:      []const u8,
    parent:    ?class.ClassHandle,
    source:    anytype,
) !*class.ClassData {
    return createClass(allocator, io, store, .{
        .name             = name,
        .parent           = parent,
        .source           = source,
        .access           = .readOnly,
        .is_delete = true,
    });
}

pub fn deleteParameter(
    allocator: Allocator,
    store:     *storage.ParamStorage,
    handle:    params.ParameterHandle,
) !void {
    const result = try handles.validateHandle(store, handle);
    const param: *params.ParameterData = @constCast(@ptrCast(@alignCast(result.ptr)));

    if (param.parent.handleOrNull()) |parentHandle| {
        const parentResult = try handles.validateHandle(store, parentHandle);
        const parentData: *class.ClassData = @constCast(@ptrCast(@alignCast(parentResult.ptr)));

        var cur = parentData.params;
        if (cur.handle.id == handle.id) {
            parentData.params = param.sibling;
        } else {
            while (cur.hasNext()) {
                const curResult = try handles.validateHandle(store, cur.handle);
                const curData: *params.ParameterData = @constCast(@ptrCast(@alignCast(curResult.ptr)));
                if (curData.sibling.handle.id == handle.id) {
                    curData.sibling = param.sibling;
                    break;
                }
                cur = curData.sibling;
            }
        }
    }

    _ = store.pathToId.remove(param.pathHash);

    try store.free(allocator, .create(handle.id));
}

pub fn deleteClass(
    allocator: Allocator,
    store:     *storage.ParamStorage,
    handle:    class.ClassHandle,
) !void {
    const result = try handles.validateHandle(store, handle);
    const data: *class.ClassData = @constCast(@ptrCast(@alignCast(result.ptr)));

    if(data.references.load(.monotonic) > 1) return error.ClassInUse;

    var child = data.children;
    while (child.hasNext()) {
        const childHandle = child.handle;
        const childData: *class.ClassData = @constCast(@ptrCast(@alignCast(
            (try handles.validateHandle(store, childHandle)).ptr,
        )));
        child = childData.sibling;
        try deleteClass(allocator, store, childHandle);
    }

    var p = data.params;
    while (p.hasNext()) {
        const paramHandle = p.handle;
        const paramData: *params.ParameterData = @constCast(@ptrCast(@alignCast(
            (try handles.validateHandle(store, paramHandle)).ptr,
        )));
        p = paramData.sibling;
        _ = store.pathToId.remove(paramData.pathHash);
        try store.free(allocator, .create(paramHandle.id));
    }
    data.params = params.ParameterStorage("sibling").empty;

    if (data.base.handleOrNull()) |baseHandle| {
        refs.releaseHandle(store, baseHandle) catch {};
    }

    if (data.parent.handleOrNull()) |parentHandle| {
        if (handles.validateHandle(store, parentHandle)) |parentResult| {
            const parentData: *class.ClassData = @constCast(@ptrCast(@alignCast(parentResult.ptr)));
            var cur = parentData.children;
            if (cur.handle.id == handle.id) {
                parentData.children = data.sibling;
            } else {
                while (cur.hasNext()) {
                    const curResult = handles.validateHandle(store, cur.handle) catch break;
                    const curData: *class.ClassData = @constCast(@ptrCast(@alignCast(curResult.ptr)));
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
                const curResult = handles.validateHandle(store, cur.handle) catch break;
                const curData: *class.ClassData = @constCast(@ptrCast(@alignCast(curResult.ptr)));
                if (curData.sibling.handle.id == handle.id) {
                    curData.sibling = data.sibling;
                    break;
                }
                cur = curData.sibling;
            }
        }
    }

    _ = store.pathToId.remove(data.pathHash);

    try store.free(allocator, .create(handle.id));
}

