const std         = @import("std");
const identifiers = @import("../utils/identifiers.zig");
const handles     = @import("../utils/handles.zig");
const parameter   = @import("parameter.zig");
const paths       = @import("../utils/paths.zig");
const source      = @import("source.zig");
const memory      = @import("../utils/memory.zig");
const time        = @import("../utils/time.zig");
const hasher      = @import("../utils/hasher.zig");
const storage     = @import("../data/storage.zig");

pub const ClassSlabSize   = 512;
pub const ClassIdentifier = identifiers.TypedId("Class");
pub const ClassHandle     = handles.Handle(ClassIdentifier);

pub fn ClassStorage(comptime field: []const u8) type {
    return struct {
        const Self = @This();
        handle: ClassHandle,

        pub fn init(handle: ClassHandle) Self {
            return .{ .handle = handle };
        }

        pub fn hasNext(self: Self) bool {
            return self.handle.isValid();
        }

        pub fn next(self: Self, store: *const storage.ParamStorage) !Self {
            if (!self.hasNext()) return error.EndOfList;
            const data: *const ClassData = @ptrCast(@alignCast(try store.retrieve(storage.StorageIdentifier.create(self.handle.id))));
            return @field(data, field);
        }

        pub const Iterator = struct {
            store: *const storage.ParamStorage,
            current: Self,
            
            pub fn next(it: *@This()) ?Self {
                if (!it.current.hasNext()) return null;
                const result = it.current;
                it.current = it.current.next(it.store) catch return null;
                return result;
            }
        };

        pub fn iterator(self: Self, store: *const storage.ParamStorage) Iterator {
            return .{
                .store = store,
                .current = self,
            };
        }

        pub const empty: Self = .{ .handle = ClassHandle.invalid };
    };
}

pub const ClassAccess = enum(u2) {
    readWrite        = 0,
    readCreate       = 1,
    readOnly         = 2,
    readOnlyVerified = 3,
};

pub const ClassInit = struct {
    name:     []const u8,
    nameHash: ?u64                         = null,
    nameIdx:  ?paths.PathSegmentIdentifier = null,
    pathHash: ?u64                         = null,
    parent:   ?ClassHandle,
    source:   source.SourceHandle,
    access:   ClassAccess                  = .readCreate,
    base:     ?ClassHandle                 = null,
};

pub const ClassData = struct { 
    generation: u32,
    pathHash:   u64,
    alive:      bool,
    nameHash:   u64,
    params:     parameter.ParameterStorage("params"),
    access:     ClassAccess,
    parent:     ClassStorage("parent"),
    base:       ClassStorage("base"),
    next:       ClassStorage("next"),
    sibling:    ClassStorage("sibling"),
    references: u32,
    nameIdx:    paths.PathSegmentIdentifier,
    createdBy:  source.SourceHandle,
    createdAt:  i64,
    modifiedBy: source.SourceHandle,
    modifiedAt: i64,

    pub fn init(io: std.Io, args: ClassInit) ClassData {
        std.debug.assert(args.nameIdx != null and args.pathHash != null);
        const timestamp = time.getTimeMs(io, .real);
        const nameHash = args.nameHash orelse hasher.hash(args.name);
        return .{
            .alive      = true,
            .generation = 1,
            .pathHash   = args.pathHash.?,
            .nameHash   = nameHash,
            .params     = parameter.ParameterStorage("params").empty,
            .access     = args.access,
            .parent     = ClassStorage("parent").init(args.parent orelse ClassHandle.invalid),
            .base       = ClassStorage("base").init(args.base orelse ClassHandle.invalid),
            .next       = ClassStorage("next").empty,
            .sibling    = ClassStorage("sibling").empty,
            .references = 1,
            .nameIdx    = args.nameIdx.?,
            .createdBy  = args.source,
            .modifiedBy = args.source,
            .createdAt  = timestamp,
            .modifiedAt = timestamp,
        };
    }

    pub fn getMutable(self: *const ClassData, store: *storage.ParamStorage) *ClassData {
        const id = store.pathToId.get(self.pathHash) orelse error.IdNotFound;
        return @ptrCast(store.retrieveMut(id));
    }
};

pub const ClassPool = memory.SlabPool(ClassData, ClassIdentifier , ClassSlabSize);
