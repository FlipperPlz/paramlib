const std     = @import("std");
const Allocator     = std.mem.Allocator;
const storage = @import("storage.zig");
const params  = @import("../slabs/parameter.zig");
const class   = @import("../slabs/class.zig");
const hasher        = @import("../utils/hasher.zig");
const handles       = @import("../utils/handles.zig");

pub fn createClass(allocator: Allocator, io: std.Io, store: *storage.ParamStorage, init: class.ClassInit) !*class.ClassData {
    const clazz = try store.alloc(allocator, io, .createClass(init));
    const clazzData: *class.ClassData = @ptrCast(clazz.ptr);

    errdefer store.free(allocator, clazz.index) catch @panic("OOM");
    
    const parentHandle = try handles.validateHandle(store, init.parent);
    const parentClass: *class.ClassData = @ptrCast(parentHandle.ptr);

    clazzData.sibling = parentClass.sibling;
    parentClass.sibling = .init(try handles.makeHandle(store, clazz.index));

    if(init.base) |_baseHandle| {
        const baseHandle: class.ClassHandle = try handles.validateHandle(store, _baseHandle);
        const baseClass: *class.ClassData = @ptrCast(baseHandle.ptr);
        
        baseClass.references += 1;
    }
    
    return @ptrCast(clazz.ptr);
}

pub fn getOrCreateClass(allocator: Allocator, io: std.Io, store: *storage.ParamStorage, init: class.ClassInit) !*class.ClassData {
    if(init.parent) |parent| {
        _ = parent;
    }

    return createClass(allocator, io, store, init); 
}
