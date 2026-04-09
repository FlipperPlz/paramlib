const std         = @import("std");
const Allocator   = std.mem.Allocator;
const handles     = @import("../utils/handles.zig");
const identifiers = @import("../utils/identifiers.zig");
const memory      = @import("../utils/memory.zig");
const hasher      = @import("../utils/hasher.zig");
const storage     = @import("../data/storage.zig");

pub const SourcePool       = memory.SlabPool(SourceData, SourceIdentifier, SourceSlabSize);
pub const SourceIdentifier = identifiers.TypedId("Source", storage.StorageType.src, *SourceData, *const SourceData);
pub const SourceHandle     = handles.Handle(SourceIdentifier);
pub const SourceIndex      = u64;
pub const SourceSlabSize   = 256;


pub const SourceData = struct {
    name:       []const u8,
    alive:      bool,
    generation: u32,
    nameHash:   u64,
    content:    SourceContent,
    next:       SourceStorage("next"),

    pub fn read(self: SourceData, store: *const storage.ParamAllocator, allocator: Allocator, io: std.Io) ![:0]const u8 {
        _ = store;
        return switch (self.content) {
            .memory  => |m| m.data,
            .runtime => |r| r.data,
            .file    => |f| try f.read(allocator, io),
            .snippet => error.SnippetRequiresStore,
        };
    }

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

const SourceType = enum {
    file,
    snippet,
    runtime,
    memory,
};

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

        pub fn next(self: Self, store: *storage.ParamAllocator) !Self {
            if (!self.hasNext()) return error.EndOfList;
            const data: *SourceData = try store.retrieve(self.handle.id);
            return @field(data, field);
        }

        pub const Iterator = struct {
            store: *storage.ParamAllocator,
            current: Self,

            pub fn next(it: *@This()) ?Self {
                if (!it.current.hasNext()) return null;
                const result = it.current;
                it.current = it.current.next(it.store) catch return null;
                return result;
            }
        };

        pub fn iterator(self: Self, store: *storage.ParamAllocator) Iterator {
            return .{
                .store   = store,
                .current = self,
            };
        }

        pub const empty: Self = .{ .handle = SourceHandle.invalid };
    };
}

pub const MemoryContent = struct {
    data: [:0]const u8,
    pub const Init = struct {
        name: []const u8,
        data: [:0]const u8,
    };

    fn read(self: MemoryContent) []const u8 {
        return self.data;
    }

    fn deinit(self: MemoryContent, allocator: Allocator) void {
        allocator.free(self.data);
    }
};

pub const RuntimeContent = struct {
    data: [:0]const u8,
    pub const Init = struct {
        name: []const u8,
        data: [:0]const u8
    };

    fn read(self: RuntimeContent) []const u8 {
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

    fn read(self: FileContent, allocator: Allocator, io: std.Io) ![:0]const u8 {
        var readerBuffer: [1024]u8 = undefined;
        const fileReader = self.file.reader(io, &readerBuffer);
        var reader = fileReader.interface;

        const data = try allocator.allocSentinel(u8, reader.end, 0);
        try reader.readSliceAll(data);

        return data ;
    }
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

pub const SourceInit = union(SourceType) {
    pub const _identifier = SourceIdentifier;
    file:    FileContent.Init,
    snippet: SnippetContent.Init,
    runtime: RuntimeContent.Init,
    memory:  MemoryContent.Init,
};

pub const SourceContent = union(SourceType) {
    file:    FileContent,
    snippet: SnippetContent,
    runtime: RuntimeContent,
    memory:  MemoryContent,
};

pub const SourcePosition = struct {
    index:  SourceIndex,
    line:   u32,
    column: u32,

    pub const start: SourcePosition = .{
        .index = 0,
        .line = 1,
        .column = 1
    };
};

test "source: SourceHandle invalid is not valid" {
    try std.testing.expect(!SourceHandle.invalid.isValid());
}

test "source: SourceData init memory content" {
    const src = try SourceData.init(.{
        .memory = .{ .name = "test_memory_source", .data = "x = 10; y = 20;" },
    });
    try std.testing.expect(src.alive);
    try std.testing.expectEqual(@as(u32, 1), src.generation);
    try std.testing.expectEqualStrings("test_memory_source", src.name);
    try std.testing.expect(src.nameHash != 0);
    switch (src.content) {
        .memory => |m| try std.testing.expectEqualStrings("x = 10; y = 20;", m.data),
        else    => return error.UnexpectedContentType,
    }
}

test "source: SourceData init runtime content" {
    const src = try SourceData.init(.{
        .runtime = .{ .name = "runtime_config", .data = "player_speed=5.0" },
    });
    try std.testing.expect(src.alive);
    try std.testing.expectEqual(@as(u32, 1), src.generation);
    try std.testing.expectEqualStrings("runtime_config", src.name);
    switch (src.content) {
        .runtime => |r| try std.testing.expectEqualStrings("player_speed=5.0", r.data),
        else     => return error.UnexpectedContentType,
    }
}

test "source: SourceData init snippet content" {
    const src = try SourceData.init(.{
        .snippet = .{
            .name   = "health_snippet",
            .source = SourceHandle.invalid,
            .start  = .{ .index = 0,  .line = 1, .column = 0  },
            .end    = .{ .index = 50, .line = 3, .column = 20 },
        },
    });
    try std.testing.expect(src.alive);
    try std.testing.expectEqualStrings("health_snippet", src.name);
    switch (src.content) {
        .snippet => |s| {
            try std.testing.expectEqual(@as(u64, 0),  s.start.index);
            try std.testing.expectEqual(@as(u64, 50), s.end.index);
            try std.testing.expectEqual(1, s.start.line);
            try std.testing.expectEqual(3, s.end.line);
        },
        else => return error.UnexpectedContentType,
    }
}

test "source: SourceData nameHash consistent across same name" {
    const s1 = try SourceData.init(.{ .memory = .{ .name = "config.par", .data = "" } });
    const s2 = try SourceData.init(.{ .memory = .{ .name = "config.par", .data = "" } });
    const s3 = try SourceData.init(.{ .memory = .{ .name = "other.par",  .data = "" } });
    try std.testing.expectEqual(s1.nameHash, s2.nameHash);
    try std.testing.expect(s1.nameHash != s3.nameHash);
}

test "source: SourceData starts alive with generation 1 and empty next chain" {
    const mem = try SourceData.init(.{ .memory  = .{ .name = "a", .data = "" } });
    const rt  = try SourceData.init(.{ .runtime = .{ .name = "b", .data = "" } });
    try std.testing.expect(mem.alive);
    try std.testing.expect(rt.alive);
    try std.testing.expectEqual(@as(u32, 1), mem.generation);
    try std.testing.expectEqual(@as(u32, 1), rt.generation);
    try std.testing.expect(!mem.next.hasNext());
    try std.testing.expect(!rt.next.hasNext());
}

test "source: snippet with zero-length range is valid" {
    const src = try SourceData.init(.{
        .snippet = .{
            .name   = "zero_span",
            .source = SourceHandle.invalid,
            .start  = .{ .index = 10, .line = 2, .column = 5 },
            .end    = .{ .index = 10, .line = 2, .column = 5 },
        },
    });
    try std.testing.expect(src.alive);
    switch (src.content) {
        .snippet => |s| try std.testing.expectEqual(s.start.index, s.end.index),
        else     => return error.UnexpectedContentType,
    }
}