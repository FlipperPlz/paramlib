const std = @import("std");
const ids_mod = @import("../core/identifiers.zig");
const time_mod = @import("../utils/time.zig");

const SourceId = ids_mod.SourceId;
const Allocator = std.mem.Allocator;

pub const SourceType = enum(u2) {
    File,
    Memory,
    Runtime,
    Unknown,
};

const FileContext = struct {
    file: std.Io.File,
    path: []const u8,
};

const MemoryContext = struct {
    contents: []const u8,
};

const RuntimeContext = struct {
    creator: []const u8,
};

pub const Source = struct {
    id: SourceId,
    name: []const u8,
    stype: SourceType,
    context: *anyopaque,
    timestamp: i64,

    pub fn init_file(path: []const u8, io: std.Io, alloc: Allocator) !Source {
        const f = try std.Io.Dir.cwd().openFile(io, path, .{});

        const ctx = try alloc.create(FileContext);
        errdefer alloc.destroy(ctx);

        const path_copy = try alloc.dupe(u8, path);
        errdefer alloc.free(path_copy);

        ctx.* = FileContext{
            .file = f,
            .path = path_copy,
        };

        const name = try alloc.dupe(u8, path);
        errdefer alloc.free(name);

        return Source{
            .id = .invalid,
            .name = name,
            .stype = .File,
            .context = @ptrCast(ctx),
            .timestamp = time_mod.getTimeMs(),
        };
    }

    pub fn init_memory(name: []const u8, content: []const u8, io: std.Io, alloc: Allocator) !Source {
        const ctx = try alloc.create(MemoryContext);
        errdefer alloc.destroy(ctx);

        const content_copy = try alloc.dupe(u8, content);
        errdefer alloc.free(content_copy);

        ctx.* = MemoryContext{
            .contents = content_copy,
        };

        const name_copy = try alloc.dupe(u8, name);
        errdefer alloc.free(name_copy);

        return Source{
            .id = .invalid,
            .name = name_copy,
            .stype = .Memory,
            .context = @ptrCast(ctx),
            .timestamp = time_mod.getTimeMs(io),
        };
    }

    pub fn init_runtime(creator: []const u8, io: std.Io, alloc: Allocator) !Source {
        const ctx = try alloc.create(RuntimeContext);
        errdefer alloc.destroy(ctx);

        const creator_copy = try alloc.dupe(u8, creator);
        errdefer alloc.free(creator_copy);

        ctx.* = RuntimeContext{
            .creator = creator_copy,
        };

        const name = try std.fmt.allocPrint(alloc, "runtime:{s}", .{creator});
        errdefer alloc.free(name);

        return Source{
            .id = .invalid,
            .name = name,
            .stype = .Runtime,
            .context = @ptrCast(ctx),
            .timestamp = time_mod.getTimeMs(io),
        };
    }

    pub fn deinit(self: *Source, io: std.Io, alloc: Allocator) void {
        alloc.free(self.name);
        switch (self.stype) {
            .File => cleanupFile(alloc, io, self.context),
            .Memory => cleanupMemory(alloc, self.context),
            .Runtime => cleanupRuntime(alloc, self.context),
            .Unknown => {},
        }
    }

    pub fn contents(self: *const Source, io: std.Io, allocator: Allocator) ![]const u8 {
        return switch (self.stype) {
            .File => readFile(allocator, io, self.context),
            .Memory => readMemory(allocator, self.context),
            .Runtime => error.NoContents,
            .Unknown => error.NoContents,
        };
    }

    fn readMemory(allocator: Allocator, ctx: *anyopaque) ![]const u8 {
        const mem_ctx: *MemoryContext = @ptrCast(@alignCast(ctx));
        return try allocator.dupe(u8, mem_ctx.contents);
    }

    fn readFile(allocator: Allocator, io: std.Io, ctx: *anyopaque) ![]const u8 {
        const file_ctx: *FileContext = @ptrCast(@alignCast(ctx));

        var reader_buffer: [1024]u8 = undefined;
        var file_reader = file_ctx.file.reader(io, &reader_buffer);
        var reader = file_reader.interface;
        const content = try reader.readAlloc(allocator, reader.end);

        errdefer allocator.free(content);

        return content;
    }

    fn cleanupFile(alloc: Allocator, io: std.Io, ctx: *anyopaque) void {
        const file_ctx: *FileContext = @ptrCast(@alignCast(ctx));
        alloc.free(file_ctx.path);
        file_ctx.file.close(io);
        alloc.destroy(file_ctx);
    }

    fn cleanupMemory(alloc: Allocator, ctx: *anyopaque) void {
        const mem_ctx: *MemoryContext = @ptrCast(@alignCast(ctx));
        alloc.free(mem_ctx.contents);
        alloc.destroy(mem_ctx);
    }

    fn cleanupRuntime(alloc: Allocator, ctx: *anyopaque) void {
        const rt_ctx: *RuntimeContext = @ptrCast(@alignCast(ctx));
        alloc.free(rt_ctx.creator);
        alloc.destroy(rt_ctx);
    }
};
