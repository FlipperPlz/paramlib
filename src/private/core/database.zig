const std = @import("std");
const Allocator = std.mem.Allocator;
const storage = @import("../data/storage.zig");
const handle = @import("../data/handles.zig");
const sources = @import("../slabs/source.zig");

const identifiers = @import("../data/identifiers.zig");

pub const ParamDatabase = struct {
    store: storage.ParamStorage,
    root: handle.ClassHandle,
    runtime: identifiers.SourceId,
    firstEnum: handle.EnumHandle = .invalid,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: Allocator, io: std.Io) ParamDatabase {
        const store: storage.ParamStorage = .empty;
        const root_name = try store.intern(allocator, "root");
        const path_hash = std.hash.Wyhash.hash(0, root_name);
        const source = try store.allocateSource(allocator, .{
            .runtime = .{
                "runtime", //maybe use interned ids
                "" //maybe use interned ids
            }
        });
        const root = try store.allocateClass(allocator, .{
            .io = io,
            .parent = .invalid,
            .name_idx = root_name.id,
            .name_hash = path_hash,
            .path_hash = path_hash,
            .source = source.id,
        });

        return .{
            .store = .empty,
            .runtime = source.id,
            .root = .{
                .id = root.id,
                .generation = 1
            },
            .firstEnum = .{
                .id = .invalid,
                .generation = 0
            }
        };
    }
};