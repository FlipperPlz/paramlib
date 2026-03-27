pub const std     = @import("std");
pub const class   = @import("../slabs/class.zig");
pub const storage = @import("storage.zig");
pub const handles = @import("../utils/handles.zig");

pub fn retainHandle(store: *storage.ParamStorage, handle: class.ClassHandle) !void {
    const data: *class.ClassData = @ptrCast(@alignCast(try store.retrieveMut(.create(handle.id))));
    return retainClass(store, data);
}

pub fn releaseHandle(store: *storage.ParamStorage, handle: class.ClassHandle) !void {
    return releaseClass(store, @ptrCast(@alignCast(try store.retrieve(.create(handle.id)))));
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
        const refs = current.references.fetchSub(1, .monotonic);
        if(refs == 1) {
            //deinit?
            current.alive = false;
            break;
        } else if (try current.parent.nextOrNull(store)) |parentHandle| {
            const parentData: *class.ClassData = (@ptrCast(@alignCast(try handles.validateHandle(store, parentHandle))));
            next = parentData;
        } else {
            next = null;
        }
    }
}

