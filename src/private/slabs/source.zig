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
        name: []const u8,
        data: MemoryContent,
    };
    data: []const u8,

    fn read(self: MemoryContent) []const u8 {
        return self.data;
    }
};

pub const RuntimeContent = struct {
    pub const Init = struct {
        name: []const u8,
        data: RuntimeContent,
    };
    data: []const u8,

    fn read(self: RuntimeContent) []const u8 {
        return self.data;
    }
};

pub const FileContent = struct {
    pub const Init = struct {
        allocator: Allocator,
        io: std.Io,
        path: []const u8
    };
    pub const Read = struct {
        allocator: Allocator,
        io: std.Io
    };
    file: std.Io.File,
    path: []const u8,

    fn read(self: FileContent, args: Read) ![]const u8 {
        var reader_buffer: [1024]u8 = undefined;
        var file_reader = self.file.reader(args.io, &reader_buffer);
        var reader = file_reader.interface;
        const content = try reader.readAlloc(args.allocator, reader.end);

        errdefer args.allocator.free(content);

        return content;
    }
};

pub const SnippetContent = struct {

    pub const Init = struct {
        data: SnippetContent,
        name: []const u8,
    };

    pub const Read = ParamStorage;
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


    name: []const u8,
    content: SourceContent,

    pub fn init(arguments: Init) SourceData {
        switch (arguments) {
            .file => | init_file| {
                const file = try std.Io.Dir.cwd().openFile(init_file.io, init_file.path, .{.lock = true});
                return SourceData {
                    .name = init_file.path,
                    .content = .{ .file = .{ .file = file, .path = init_file.path } },
                };
            },
            .snippet => |init_snippet| return SourceData {
                .name = init_snippet.name,
                .content = init_snippet.data,
            },
            .memory => |init_memory| return SourceData {
                .name = init_memory.name,
                .content = init_memory.data,
            },
            .runtime => |init_runtime| return SourceData {
                .name = init_runtime.name,
                .content = init_runtime.data,
            }
        }
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