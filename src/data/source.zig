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
    file: std.fs.File,
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

    pub fn init_file(path: []const u8, alloc: Allocator) !Source {
        const f = try std.fs.cwd().openFile(path, .{});

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

    pub fn init_memory(name: []const u8, content: []const u8, alloc: Allocator) !Source {
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
            .timestamp = time_mod.getTimeMs(),
        };
    }

    pub fn init_runtime(creator: []const u8, alloc: Allocator) !Source {
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
            .timestamp = time_mod.getTimeMs(),
        };
    }

    pub fn deinit(self: *Source, alloc: Allocator) void {
        alloc.free(self.name);
        switch (self.stype) {
            .File => cleanupFile(alloc, self.context),
            .Memory => cleanupMemory(alloc, self.context),
            .Runtime => cleanupRuntime(alloc, self.context),
            .Unknown => {},
        }
    }

    pub fn contents(self: *const Source, allocator: Allocator) ![]const u8 {
        return switch (self.stype) {
            .File => readFile(allocator, self.context),
            .Memory => readMemory(allocator, self.context),
            .Runtime => error.NoContents,
            .Unknown => error.NoContents,
        };
    }

    fn readMemory(allocator: Allocator, ctx: *anyopaque) ![]const u8 {
        const mem_ctx: *MemoryContext = @ptrCast(@alignCast(ctx));
        return try allocator.dupe(u8, mem_ctx.contents);
    }

    fn readFile(allocator: Allocator, ctx: *anyopaque) ![]const u8 {
        const file_ctx: *FileContext = @ptrCast(@alignCast(ctx));
        try file_ctx.file.seekTo(0);
        const size = try file_ctx.file.getEndPos();
        const content = try allocator.alloc(u8, size);
        errdefer allocator.free(content);
        try file_ctx.file.seekTo(0);
        _ = try file_ctx.file.read(content);
        return content;
    }

    fn cleanupFile(alloc: Allocator, ctx: *anyopaque) void {
        const file_ctx: *FileContext = @ptrCast(@alignCast(ctx));
        alloc.free(file_ctx.path);
        file_ctx.file.close();
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
