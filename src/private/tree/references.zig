pub const std     = @import("std");
pub const class   = @import("../slabs/class.zig");
pub const params  = @import("../slabs/parameter.zig");
pub const storage = @import("../data/storage.zig");
pub const handles = @import("../utils/handles.zig");

pub fn retainHandle(store: *storage.ParamStorage, handle: class.ClassHandle) !void {
    const data: *class.ClassData = @ptrCast(@alignCast(try store.retrieveMut(.create(handle.id))));
    return retainClass(store, data);
}

pub fn releaseHandle(store: *storage.ParamStorage, handle: class.ClassHandle) !void {
    return releaseClass(store, @ptrCast(@alignCast(try store.retrieveMut(.create(handle.id)))));
}

pub fn retainClass(store: *storage.ParamStorage, data: *class.ClassData) !void {
    var next: ?*class.ClassData = data;
    while (next) |current| {
        _ = current.references.fetchAdd(1, .monotonic);
        if (current.parent.handleOrNull()) |parentHandle| {
            const parentData: *class.ClassData = @constCast(@ptrCast(@alignCast((try handles.validateHandle(store, parentHandle)).ptr)));
            next = parentData;
        } else {
            next = null;
        }
    }
}

pub fn releaseClass(store: *storage.ParamStorage, data: *class.ClassData) !void {
    var next: ?*class.ClassData = data;
    while (next) |current| {
        _ = current.references.fetchSub(1, .monotonic);

        if (current.parent.handleOrNull()) |parentHandle| {
            const parentPtr = store.retrieveMut(.create(parentHandle.id)) catch break;
            next = @ptrCast(@alignCast(parentPtr));
        } else {
            next = null;
        }
    }
}

pub fn releaseParamParent(store: *storage.ParamStorage, param: *params.ParameterData) !void {
    if (param.parent.handleOrNull()) |parentHandle| {
        const parentData: *class.ClassData = @ptrCast(@alignCast(try store.retrieveMut(.create(parentHandle.id))));
        _ = parentData.references.fetchSub(1, .monotonic);
    }
}

