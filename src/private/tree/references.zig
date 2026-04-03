pub const std     = @import("std");
pub const class   = @import("../slabs/class.zig");
pub const params  = @import("../slabs/parameter.zig");
pub const storage = @import("../data/storage.zig");
pub const handles = @import("../utils/handles.zig");

pub fn retainHandle(store: *storage.ParamAllocator, handle: class.ClassHandle) !void {
    const data: *class.ClassData = try (try store.retrieve(handle.id)).getMutable(store);
    return retainClass(store, data);
}

pub fn releaseHandle(store: *storage.ParamAllocator, handle: class.ClassHandle) !void {
    return releaseClass(store, try (try store.retrieve(handle.id)).getMutable(store));
}

pub fn retainClass(store: *storage.ParamAllocator, data: *class.ClassData) !void {
    var next: ?*class.ClassData = data;
    while (next) |current| {
        _ = current.references.fetchAdd(1, .monotonic);
        if (current.parent.handleOrNull()) |parentHandle| {
            const parentData: *class.ClassData = try (try parentHandle.validateHandle(store)).ptr.getMutable(store);
            next = parentData;
        } else {
            next = null;
        }
    }
}

pub fn releaseClass(store: *storage.ParamAllocator, data: *class.ClassData) !void {
    var next: ?*class.ClassData = data;
    while (next) |current| {
        _ = current.references.fetchSub(1, .monotonic);

        if (current.parent.handleOrNull()) |parentHandle| {
            const parentPtr = store.retrieve(parentHandle.id) catch break;
            next = try parentPtr.getMutable(store);
        } else {
            next = null;
        }
    }
}

pub fn releaseParamParent(store: *storage.ParamAllocator, param: *params.ParameterData) !void {
    if (param.parent.handleOrNull()) |parentHandle| {
        const parentData: *class.ClassData = try (try store.retrieve(parentHandle.id)).getMutable(store);
        _ = parentData.references.fetchSub(1, .monotonic);
    }
}
