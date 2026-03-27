const std        = @import("std");
const Allocator  = std.mem.Allocator;
const storage    = @import("../data/storage.zig");
const class      = @import("../slabs/class.zig");
const params     = @import("../slabs/parameter.zig");
const factory    = @import("factory.zig");
const query      = @import("query.zig");
const references = @import("references.zig");
const paths      = @import("../utils/paths.zig");
const hasher     = @import("../utils/hasher.zig");

pub const MergeResult = struct {
    allOverloaded:  bool,
    containsDelete: bool,
};

pub fn mergeClass(
    allocator:    Allocator,
    io:           std.Io,
    store:        *storage.ParamStorage,
    targetHandle: class.ClassHandle,
    src:          *const class.ClassData,
    protect:      bool
) !MergeResult {
    const target = store.classes.get(targetHandle.id);

    const effectiveAccess: class.ClassAccess = if (!protect) .readWrite else target.access;
    if(effectiveAccess == .readOnly or effectiveAccess == .readOnlyVerified) {
        return .{ .allOverloaded = false, .containsDelete = false };
    }

    const baseOverloaded = try mergeBase(allocator, store, target, targetHandle, src, effectiveAccess);

    var allOverloaded = baseOverloaded;
    var containsDelete = false;

    var childIter = src.children.iterator(store);
    while (childIter.next()) |childStorage| {
        const srcChild: *const class.ClassData = try childStorage.current(store);
        
        if(srcChild.is_delete_marker) {
            containsDelete = true;

            if(query.getClassByNameHash(store, target, srcChild.nameHash)) |victimHandle| {
                try factory.deleteClass(allocator, store, victimHandle);
            }
            continue;
        }

        if(query.getClassByNameHash(store, target, srcChild.nameHash)) |targetChildHandle| {
            if(effectiveAccess == .readCreate) {
                allOverloaded = false;
                continue;
            }

            const childResult = try mergeClass(allocator, io, store, targetChildHandle, srcChild, protect);
            if(!childResult.allOverloaded) allOverloaded = false;
            if(childResult.containsDelete) containsDelete = true;
        } else {
            if(effectiveAccess == .readOnly or effectiveAccess == .readOnlyVerified) {
                allOverloaded = false;
                continue;
            }            

            try moveClassInto(allocator, io, store, srcChild, targetHandle);
        }
    }

    var paramIter = src.params.iterator(store);
    while (paramIter.next()) |paramStorage| {
        const srcParam = try paramStorage.current(store);
        if(query.getParameterByNameHash(store, target, srcParam.nameHash)) | targetParameterHandle | {
            if (effectiveAccess == .readCreate or 
                effectiveAccess == .readOnly or
                effectiveAccess == .readOnlyVerified) {
                allOverloaded = false;
                continue;    
            }

            const paramData = store.parameters.get(targetParameterHandle.id);
            paramData.*.value = srcParam.value;
            paramData.*.modifiedBy = srcParam.modifiedBy;
        } else {
            if(effectiveAccess == .readOnly or effectiveAccess == .readOnlyVerified) {
                allOverloaded = false;
                continue;
            }
            
            const namePtr: *const []const u8 = @ptrCast(@alignCast(
                try store.retrieve(.create(srcParam.nameIdx))
            ));

            _ = try store.alloc(allocator, io, .createParameter(.{
                .name = namePtr.*,
                .parent = targetHandle,
                .source = srcParam.modifiedBy,
                .value = srcParam.value,
            }));
        }
    }
    
    return .{ .allOverloaded = allOverloaded, .containsDelete = containsDelete };
}

fn mergeBase(
    allocator:       Allocator,
    store:           *storage.ParamStorage,
    target:          *class.ClassData,
    targetHandle:    class.ClassHandle,
    src:             *const class.ClassData,
    effectiveAccess: class.ClassAccess
) !bool {
    if (src.base.handleOrNull()) |srcBaseHandle| {
        const srcBase: *const class.ClassData = @ptrCast(@alignCast(
            try store.retrieve(.create(srcBaseHandle.id))
        ));

        const baseNamePtr: *const []const u8 = @ptrCast(@alignCast(
            try store.retrieve(.create(srcBase.nameIdx))
        )); 

        const resolved = try resolveBaseInScope(allocator, store, baseNamePtr.*, targetHandle);
        if (resolved == null) return false;

        const actualBase: ?class.ClassHandle = blk: {
            if(resolved) |r| {
                if(r.id == targetHandle.id) {
                    if(target.parent.handleOrNull()) |parentHandle| {
                        const parent: *const class.ClassData = @ptrCast(@alignCast(
                            try store.retrieve(.create(parentHandle.id))
                        ));
                        if (parent.base.handleOrNull()) |pb| {
                            break :blk resolveBaseInScope(allocator, store, baseNamePtr.*, pb) catch null;
                        }
                    }
                    break :blk null;
                }
                break :blk r;
            }
            break :blk null;
        };

        if(actualBase) |newBaseHandle| {
            const oldBase = target.base.handleOrNull();
            if(oldBase == null or oldBase.?.id != newBaseHandle.id) {
                if(effectiveAccess == .readCreate) return false;
                if(oldBase) |ob| try references.releaseHandle(store, ob);
                try references.releaseHandle(store, newBaseHandle);
                target.base = class.ClassStorage("base").init(newBaseHandle);
            }
        }
        return true;
    } else {
        if(target.base.handleOrNull()) |oldBase| {
            if(effectiveAccess == .readCreate) return false;
            try references.releaseHandle(store,oldBase);
            target.base = class.ClassStorage("base").empty;
        }
        return true;
    }
}

fn resolveBaseInScope(
    allocator:  Allocator,
    store:      storage.ParamStorage,
    baseName:   []const u8,
    fromHandle: class.ClassHandle
) !?class.ClassHandle {
    var currentOpt: ?class.ClassHandle = fromHandle;
    while (currentOpt) |currentHandle| {
        const current: *const class.ClassData = @ptrCast(@alignCast(
            try store.retrieve(.create(currentHandle.id))
        ));

        const currentPath = try paths.getPath(allocator, store, .createClass(current));
        defer allocator.free(currentPath);

        const parentPath = paths.getParent(currentPath);
        const candidatePath = if(parentPath.len > 0) 
            try paths.joinPaths(allocator, &[_][]const u8{ parentPath, baseName })
        else try allocator.dupe(u8, baseName);
        defer allocator.free(candidatePath);

        const candidateHash = hasher.hash(candidatePath);
        if(store.pathToId.get(candidateHash)) |id| {
            if(id == .clazz) {
                const h = class.ClassHandle {
                    .id = id.clazz,
                    .generation = store.classes.getConst(id.clazz).generation,
                };
                return h;
            }
        }

        currentOpt = current.parent.handleOrNull();
    }

    const candidateHash = hasher.hash(baseName);
    if(store.pathToId.get(candidateHash)) |id| {
        if(id == .clazz) return class.ClassHandle {
            .id = id.clazz,
            .generation = store.classes.getConst(id.clazz).generation
        };
    }
    return null;
}

fn moveClassInto(
    allocator:          Allocator,
    io:                 std.Io,
    store:              *storage.ParamStorage,
    src:                *const class.ClassData,
    targetParentHandle: class.ClassHandle
) !void {
    const namePtr: *const []const u8 = @ptrCast(@alignCast(try store.retrieve(.create(src.nameIdx))));

    const resolvedBase = if (src.base.handleOrNull()) |sb| blk: {
        const baseData: *const class.ClassData = @ptrCast(@alignCast(
            try store.retrieve(.create(sb.id))
        ));
        const baseNamePtr: *const []const u8 = @ptrCast(@alignCast(try store.retrieve(.create(baseData.nameIdx))));

        break :blk try resolveBaseInScope(allocator, store, baseNamePtr.*, targetParentHandle);
    } else null;

    const newRaw = try store.alloc(allocator, io, .createClass(.{
        .name      = namePtr.*,
        .parent    = targetParentHandle,
        .source    = src.createdBy,
        .access    = src.access,
        .base      = resolvedBase,
        .is_delete = src.is_delete_marker,
    }));
    const newHandle = class.ClassHandle{
        .id         = @enumFromInt(newRaw.index.toIndex().?),
        .generation = (@as(*const class.ClassData, @ptrCast(@alignCast(newRaw.ptr)))).generation,
    };
    if (resolvedBase) |rb| try references.retainHandle(store, rb);

    var paramBuf = std.ArrayList(*const params.ParameterData).empty;
    defer paramBuf.deinit(allocator);
    var pi = src.params.iterator(store);
    while (pi.next()) |ps| {
        const p: *const params.ParameterData = @ptrCast(@alignCast(
            try store.retrieve(.create(ps.handle.id))
        ));
        try paramBuf.append(allocator, p);
    }

    std.mem.reverse(*const params.ParameterData, paramBuf.items);
    for (paramBuf.items) |p| {
        const pname: *const []const u8 = @ptrCast(@alignCast(
            try store.retrieve(.create(p.nameIdx))
        ));
        _ = try store.alloc(allocator, io, .createParameter(.{
            .name   = pname.*,
            .parent = newHandle,
            .source = p.createdBy,
            .value  = p.value,
        }));
    }

    var childBuf = std.ArrayList(*const class.ClassData).empty;
    defer childBuf.deinit(allocator);
    var ci = src.children.iterator(store);
    while (ci.next()) |cs| {
        const c: *const class.ClassData = @ptrCast(@alignCast(
            try store.retrieve(.create(cs.handle.id))
        ));
        try childBuf.append(allocator, c);
    }
    std.mem.reverse(*const class.ClassData, childBuf.items);
    for (childBuf.items) |c| {
        try moveClassInto(allocator, io, store, c, newHandle);
    }
}
