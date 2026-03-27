const std         = @import("std");
const Allocator   = std.mem.Allocator;
const handles     = @import("../utils/handles.zig");
const identifiers = @import("../utils/identifiers.zig");
const storage     = @import("../data/storage.zig");
const memory      = @import("../utils/memory.zig");
const hasher      = @import("../utils/hasher.zig");

pub const SourceIdentifier = identifiers.TypedId("Source");
pub const SourceIndex      = u64;

pub const SourcePosition = struct {
    index:  SourceIndex,
    line:   f32,
    column: u32,
};
pub const SourceSlabSize = 256;

const SourceType = enum {
    file,
    snippet,
    runtime,
    memory,
};
pub const SourceHandle = handles.Handle(SourceIdentifier);

pub fn SourceStorage(comptime field: []const u8) type {
    return struct {
        const Self = @This();
        handle: SourceHandle,

        pub fn init(handle: SourceHandle) Self {
            return .{ .handle = handle };
        }

        pub fn hasNext(self: Self) bool {
            return self.handle.isValid();
        }

        pub fn next(self: Self, store: *storage.ParamStorage) !Self {
            if (!self.hasNext()) return error.EndOfList;
            const data: *SourceData = @ptrCast(@alignCast(try store.retrieve(.create(self.handle.id))));
            return @field(data, field);
        }

        pub const Iterator = struct {
            store: *storage.ParamStorage,
            current: Self,

            pub fn next(it: *@This()) ?Self {
                if (!it.current.hasNext()) return null;
                const result = it.current;
                it.current = it.current.next(it.store) catch return null;
                return result;
            }
        };

        pub fn iterator(self: Self, store: *storage.ParamStorage) Iterator {
            return .{
                .store   = store,
                .current = self,
            };
        }

        pub const empty: Self = .{ .handle = SourceHandle.invalid };
    };
}

pub const SourceContent = union(SourceType) {
    file:    FileContent,
    snippet: SnippetContent,
    runtime: RuntimeContent,
    memory:  MemoryContent,
};

pub const MemoryContent = struct {
    data: []const u8,
    pub const Init = struct {
        name: []const u8,
        data: []const u8,
    };

    fn read(self: MemoryContent) []const u8 {
        return self.data;
    }

    fn deinit(self: MemoryContent, allocator: Allocator) void {
        allocator.free(self.data);
    }
};

pub const RuntimeContent = struct {
    data: []const u8,
    pub const Init = struct {
        name: []const u8,
        data: []const u8,
    };

    fn read(self: MemoryContent) []const u8 {
        return self.data;
    }
};

pub const FileContent = struct {
    file: std.Io.File,
    pub const Init = struct {
        allocator: Allocator,
        io: std.Io,
        path: []const u8,
    };

    fn read(self: FileContent, allocator: Allocator, io: std.Io) []const u8 {
        var readerBuffer: [1024]u8 = undefined;
        const fileReader = self.file.reader(io, &readerBuffer);
        var reader = fileReader.interface;
    
        const data = try reader.readAlloc(allocator, reader.end);

        errdefer allocator.free(data);
        
        return data;
    }
};

pub const SourceInit = union(SourceType) {
    file:    FileContent.Init,
    snippet: SnippetContent.Init,
    runtime: RuntimeContent.Init,
    memory:  MemoryContent.Init,
};

pub const SnippetContent = struct {
    pub const Init = struct {
        name:   []const u8,
        source: SourceHandle,
        start:  SourcePosition,
        end:    SourcePosition,
    };
    source: SourceHandle,
    start:  SourcePosition,
    end:    SourcePosition,
};

pub const SourceData = struct {
    name:       []const u8,
    alive:      bool,
    generation: u32,
    nameHash:   u64,
    content:    SourceContent,
    next:       SourceStorage("next"),

    pub fn init(args: SourceInit) !SourceData {
        return switch (args) {
            .file => |fileArgs| {
                const file = try std.Io.Dir.openFileAbsolute(fileArgs.io, fileArgs.path, .{ .mode = .read_only, .lock = .none, });

                return .{
                    .name = fileArgs.path,
                    .nameHash = hasher.hash(fileArgs.path),
                    .alive = true,
                    .generation = 1,
                    .content = .{ .file = .{ .file = file, } },
                    .next = .empty,
                };
            },
            .memory => |memArgs| .{
                .name = memArgs.name,
                .nameHash = hasher.hash(memArgs.name),
                .alive = true,
                .generation = 1,
                .content = .{ .memory = .{ .data = memArgs.data, } },
                .next = .empty,
            },
            .runtime => |rtArgs| .{
                .name = rtArgs.name,
                .nameHash = hasher.hash(rtArgs.name),
                .alive = true,
                .generation = 1,
                .content = .{ .runtime = .{ .data = rtArgs.data, } },
                .next = .empty,
            },
            .snippet => |snipArgs| .{
                .name = snipArgs.name,
                .nameHash = hasher.hash(snipArgs.name),
                .alive = true,
                .generation = 1,
                .content = .{ .snippet = .{
                    .source = snipArgs.source,
                    .start = snipArgs.start,
                    .end = snipArgs.end,
                } },
                .next = .empty,
            },
        };
    }
};



pub const SourcePool = memory.SlabPool(SourceData, SourceIdentifier, SourceSlabSize);
