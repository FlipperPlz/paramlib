const std = @import("std");
const Allocator = std.mem.Allocator;
const identifiers = @import("../data/identifiers.zig");
const time = @import("../utils/time.zig");
const slabs = @import("slabs.zig");
const handles = @import("../data/handles.zig");
const storage = @import("../data/storage.zig");
const hasher = @import("../utils/hasher.zig");

pub const EnumStorage = struct {
    firstEnum: handles.EnumHandle,

    pub const empty: EnumStorage = .{
        .firstEnum = .invalid
    };

    pub const CreateArgs = struct {
        allocator: Allocator,
        io: std.Io,
        store: *storage.ParamStorage,
        source: identifiers.SourceId,
        name: []const u8,
        value: f32
    };

    pub fn create(self: *EnumStorage, args: CreateArgs) !struct {id: identifiers.EnumId, ptr: *slabs.EnumData} {
        const enum_name = try args.store.intern(args,args.allocator, args.name);
        const name_hash =  hasher.hash(enum_name.ptr);
        var current = self.firstEnum;
        while (current != .invalid) {
            const par = try args.store.retrieve(.create(current.id)).?;
            if (par.name_hash == name_hash) {
                return error.EnumAlreadyExists;
            }
            current = par.next;
        }

        const enum_value = try args.store.allocateEnum(args.allocator, .{
            .io = args.io,
            .name_idx = enum_name.id,
            .name_hash = name_hash,
            .value = args.value,
            .source_id = args.source
        });
        enum_value.ptr.next = self.firstEnum;
        self.firstEnum = try handles.makeHandle(args.store, enum_value.id);
        return .{ .id = enum_value.id, .ptr = enum_value.ptr};
    }
};

pub const EnumData = packed struct {
    pub const Id = identifiers.EnumId;
    pub const Storage = EnumStorage;
    pub const Handle = handles.ParameterHandle;
    pub const Init = struct {
        io: std.Io,
        name_idx: identifiers.StringId,
        name_hash: u64,
        value: f32,
        source_id: identifiers.SourceId,

        pub fn toSlabInit(self: ?*Init) slabs.SlabInit{
            return slabs.SlabInit {
                .enumeration = self
            };
        }
    };
    alive: bool,
    generation: u32,
    name_hash: u64,
    value: f32,
    next: identifiers.EnumId,

    name_idx: identifiers.StringId,
    created_by: identifiers.SourceId,
    created_at: i64,

    pub fn init(
        args: Init
    ) EnumData {
        return .{
            .alive = true,
            .generation = 1,
            .name_hash = args.name_hash,
            .next = .invalid,
            .name_idx = args.name_idx,
            .value = args.value,
            .created_by = args.source_id,
            .created_at = time.getTimeMs(args.io, .real),
        };
    }
};