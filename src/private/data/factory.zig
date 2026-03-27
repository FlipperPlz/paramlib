const std       = @import("std");
const Allocator = std.mem.Allocator;
const storage   = @import("storage.zig");
const params    = @import("../slabs/parameter.zig");
const class     = @import("../slabs/class.zig");
const hasher    = @import("../utils/hasher.zig");
const handles   = @import("../utils/handles.zig");
const query     = @import("../data/query.zig");

pub fn createClass(allocator: Allocator, io: std.Io, store: *storage.ParamStorage, init: class.ClassInit) !*class.ClassData {
    const clazz = try store.alloc(allocator, io, .createClass(init));
    errdefer store.free(allocator, clazz.index) catch @panic("OOM");

    if(init.base) |_baseHandle| {
        _ = try handles.validateHandle(store, _baseHandle);
        const baseClass: *class.ClassData = @ptrCast(@alignCast(store.classes.get(_baseHandle.id)));
        // TODO: Make sure base is visible
        // TODO: Switch to atomic, simple for now
        baseClass.references += 1;
    }

    return @ptrCast(@alignCast(clazz.ptr));
}

pub fn getOrCreateClass(allocator: Allocator, io: std.Io, store: *storage.ParamStorage, init: class.ClassInit) !*class.ClassData {
    // TODO: We need a findNext method that looks for names e.g find direct children
    //if(init.parent) |parent| {
    //    const parentHandle = try handles.validateHandle(store, parent);
    //    const parentData: *class.ClassData = @ptrCast(parentHandle.ptr);
    //    
    //}

    return createClass(allocator, io, store, init); 
}
