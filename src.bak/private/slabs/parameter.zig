const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../data/value.zig").Value;
const time = @import("../utils/time.zig");
const identifiers = @import("../data/identifiers.zig");
const slabs = @import("slabs.zig");
const storage = @import("../data/storage.zig");
const paths = @import("../utils/paths.zig");
const hasher = @import("../utils/hasher.zig");
const handles = @import("../data/handles.zig");

pub const ParameterStorage = struct {
    firstParam: handles.ParameterHandle,

    pub const empty: ParameterStorage = .{
        .firstParam = .invalid
    };

    pub const CreateArgs = struct {
        allocator: Allocator,
        io: std.Io,
        store: *storage.ParamStorage,
        source: identifiers.SourceId,
        path: slabs.ParameterData.Init.PathUnion,
        value: Value
    };

    pub fn create(self: *ParameterStorage, args: CreateArgs) !struct {id: identifiers.ParameterId, ptr: *slabs.ParameterData} {
        const pathHash = hasher.hash(args.path);
        const sepIdx = std.mem.lastIndexOfScalar(u8, args.path, '.');
        const parameter_name = try args.store.intern(args.allocator, if (sepIdx) |i| args.path[i+1..] else args.path);
        var current = self.firstParam;
        var classId = identifiers.ClassId.fromIndex(args.store.path_to_id.get(args.path[0..sepIdx]) orelse return error.MissingClass);
        const name_hash =  hasher.hash(parameter_name.ptr);

        while (current != .invalid) {
            const par = try args.store.retrieve(.create(current.id)).?;
            if (par.name_hash == name_hash) {
                return error.ParamAlreadyExists;
            }
            current = par.next;
        }

        const param_value = try args.store.allocateParameter(args.allocator, .{
            .io = args.io,
            .path = ParameterData.Init.PathUnion {
                .created = pathHash
            },
            .name_hash = name_hash,
            .name_idx = identifiers.StringId,
            .value = args.value,
            .parent = classId,
            .source = args.source
        });

        const classParams = args.store.classes.get(classId.toIndex().?).params;

        param_value.ptr.next = classParams.firstParam;
        classParams.firstParam = try handles.makeHandle(args.store, param_value.id);
        return .{ .id = param_value.id, .ptr = param_value.ptr};
    }
};

pub const ParameterData = packed struct {
    pub const Id = identifiers.ParameterId;
    pub const Handle = handles.ParameterHandle;
    pub const Storage = ParameterStorage;
    pub const Init = struct {
        pub const PathUnion = union {
            create: struct {
                allocator: Allocator,
                store: *storage.ParamStorage
            },
            created: u64
        };
        io: std.Io,
        path: PathUnion,
        store: *storage.ParamStorage,
        name_hash: u64,
        name_idx:  identifiers.StringId,
        value: Value,
        parent: identifiers.ClassId,
        source: identifiers.SourceId,

        pub fn toSlabInit(self: ?*Init) slabs.SlabInit{
            return slabs.SlabInit {
                .parameter = self
            };
        }
    };
    alive: bool,
    generation: u32,
    name_hash: u64,
    value: Value,
    next: identifiers.ParameterId,

    path_hash: u64,
    name_idx: identifiers.StringId,
    parent: identifiers.ClassId,

    created_by: identifiers.SourceId,
    created_at: i64,
    modified_by: identifiers.SourceId,
    modified_at: i64,

    pub fn init(
        args: Init
    ) ParameterData {
        const timestamp = time.getTimeMs(args.io, std.Io.Clock.real);

        const param: ParameterData = .{
            .alive = true,
            .generation = 1,
            .path_hash = undefined,
            .name_hash = args.name_hash,
            .value = args.value,
            .next = .invalid,
            .name_idx = args.name_idx,
            .parent = args.parent,
            .created_by = args.source,
            .created_at = timestamp,
            .modified_by = args.source,
            .modified_at = timestamp
        };

        switch (args.path) {
            .create => |path_args| {
                const path = paths.getPath(path_args.allocator, path_args.store, param);
                param.path_hash = hasher.hash(path);
            },
            .created => |d| param.path_hash = d
        }
        return param;
    }

    pub fn markModified(self: *ParameterData, source: identifiers.SourceId, io: std.Io) void {
        self.modified_by = source;
        self.modified_at = time.getTimeMs(io, std.Io.Clock.real);
    }
};