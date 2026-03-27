const std         = @import("std");
const Allocator   = std.mem.Allocator;
const storage     = @import("storage.zig");
const params      = @import("../slabs/parameter.zig");
const class       = @import("../slabs/class.zig");
const hasher      = @import("../utils/hasher.zig");
const handles     = @import("../utils/handles.zig");
const query       = @import("../data/query.zig");
const refereneces = @import("references.zig");
const paths       = @import("../utils/paths.zig");

pub fn createClass(allocator: Allocator, io: std.Io, store: *storage.ParamStorage, init: class.ClassInit) !*class.ClassData {
    const clazz = try store.alloc(allocator, io, .createClass(init));
    errdefer store.free(allocator, clazz.index) catch @panic("OOM");

    if(init.base) |_baseHandle|
        refereneces.retainHandle(store, _baseHandle) catch return error.RetainError;

    return @ptrCast(@alignCast(clazz.ptr));
}

pub fn getOrCreateClass(allocator: Allocator, io: std.Io, store: *storage.ParamStorage, init: class.ClassInit) !*class.ClassData {
    const hash = blk: {
        if(init.parent) |parent| {
            const parentHandle = try handles.validateHandle(store, parent);
            const parentData: *class.ClassData = @ptrCast(parentHandle.ptr);

            const parentPath = try paths.getPath(allocator, store, .createClass(parentData));
            defer allocator.free(parentPath);

            const targetPath = paths.joinPaths(allocator, parentPath, init.name);

            if (query.lookupClass(store, targetPath)) |existingClass| {
                return existingClass;
            }
            if(!init.pathHash) break :blk hasher.hash(targetPath);
        } else if (!init.pathHash) {
            const targetPath = init.name;
            if (query.lookupClass(store, targetPath)) |existingClass| {
                return existingClass;
            }
            break :blk hasher.hash(targetPath);
        }
        break :blk null;
    };
    if (hash) |pathHash| init.pathHash = pathHash;

    return createClass(allocator, io, store, init); 
}
