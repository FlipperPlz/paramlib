const std = @import("std");
const Allocator = std.mem.Allocator;

const ParamStorage = @import("../data/storage.zig").ParamStorage;
const identifiers = @import("../data/identifiers.zig");
const slabs = @import("slabs.zig");
pub const SourceIndex = u64;

pub const SourcePositon = struct {
    index: SourceIndex,
    line: u32,
    column: u32,
};

const SourceType = enum {
    file,
    snippet,
    runtime,
    memory
};

pub const SourceContent = union(SourceType) {
    file: FileContent,
    memory: MemoryContent,
    runtime: RuntimeContent,
    snippet: SnippetContent,
};

pub const MemoryContent = struct {
    pub const Init = struct {
        name: identifiers.StringId,
        data: identifiers.StringId,
    };
    data: identifiers.StringId,

    fn read(self: MemoryContent) identifiers.StringId {
        return self.data;
    }
};

pub const RuntimeContent = struct {
    pub const Init = struct {
        name: identifiers.StringId,
        data: identifiers.StringId,
    };
    data: identifiers.StringId,

    fn read(self: RuntimeContent) identifiers.StringId {
        return self.data;
    }
};

pub const FileContent = struct {
    pub const Init = struct {
        allocator: Allocator,
        io: std.Io,
        store: *const ParamStorage,
        path: identifiers.StringId
    };
    pub const Read = struct {
        allocator: Allocator,
        io: std.Io,
        store: *const ParamStorage
    };
    file: std.Io.File,
    path: identifiers.StringId,

    fn read(self: FileContent, args: Read) ![]identifiers.StringId {
        var reader_buffer: [1024]u8 = undefined;
        var file_reader = self.file.reader(args.io, &reader_buffer);
        var reader = file_reader.interface;
        var data = try args.store.intern(args.allocator, try reader.readAlloc(args.allocator, reader.end));

        errdefer args.store.free(args.allocator, .create(data.id));

        return data.id;
    }
};

pub const SnippetContent = struct {

    pub const Init = struct {
        name: []const u8,
        source: identifiers.SourceId,
        start: SourcePositon,
        end: SourcePositon,
    };

    pub const Read = struct {
        store: *const ParamStorage
    };

    source: identifiers.SourceId,
    start: SourcePositon,
    end: SourcePositon,

    fn read(
        self: SnippetContent,
        args: Read,
    ) ![]const u8 {
        _ = self;
        _ = args;
        std.debug.panic("TODO", .{});
    }
};

pub const SourceData = struct {
    pub const Init = union(SourceType) {
        file: FileContent.Init,
        snippet: SnippetContent.Init,
        runtime: RuntimeContent.Init,
        memory: MemoryContent.Init,

        pub fn toSlabInit(self: ?*Init) slabs.SlabInit{
            return slabs.SlabInit {
                .source = self
            };
        }
    };

    pub const ReadArgs = union(SourceType) {
        file: FileContent.Read,
        snippet: SnippetContent.Read,
        runtime,
        memory,
    };

    name: identifiers.StringId,
    content: SourceContent,

    pub fn init(allocator: Allocator, store: *ParamStorage, arguments: Init) SourceData {
        return switch (arguments) {
            .file => | init_file| {
                const file = try std.Io.Dir.cwd().openFile(init_file.io, init_file.path, .{.lock = true});
                const path = try store.intern(allocator, init_file.path);

                SourceData {
                    .name = path.id,
                    .content = .{ .file = .{ .file = file, .path = path.id } },
                };
            },
            .snippet => |init_snippet|{
                const name = try store.intern(allocator, init_snippet.name);

                SourceData {
                    .name = name,
                    .content = .{ .snippet = .{
                        .name = name.id,
                        .source = init_snippet.source,
                        .start = init_snippet.start,
                        .end = init_snippet.end
                    }},
                };
            },
            .memory => |init_memory| {
                const name = try store.intern(allocator, init_memory.name);
                const contents = try store.intern(allocator, init_memory.data);

                SourceData {
                    .name = name,
                    .content = .{
                        .memory = .{
                            .data = contents
                        }
                    }
                };
            },
            .runtime => |init_runtime|  {
                const name = try store.intern(allocator, init_runtime.name);
                const contents = try store.intern(allocator, init_runtime.data);

                return SourceData {
                    .name = name,
                    .content = .{
                        .runtime = .{
                            .data = contents
                        }
                    }
                };
            }
        };
    }

    pub fn read( self: SourceData, arguments: SourceData.ReadArgs) ![]const u8 {
        std.debug.assert(@intFromEnum(self.content) == @intFromEnum(arguments));
        switch (arguments) {
            .file => |read_file| return self.content.file.read(read_file),
            .snippet => |read_snippet| return self.content.snippet.read(read_snippet),
            .runtime => return self.content.runtime.read(),
            .memory => return self.content.memory.read()
        }
    }
};