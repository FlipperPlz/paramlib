const std = @import("std");
const parLsp = @import("lsp.zig");
const lsp = @import("lsp");

pub fn main(init: std.process.Init) !void {
    var read_buffer: [64 * 1024]u8 = undefined;
    var stdio: lsp.Transport.Stdio = .init(&read_buffer, .stdin(), .stdout());
    const transport: *lsp.Transport  = &stdio.transport;

    return startServer(init.io, init.gpa, transport);
}

pub export fn custom_log(ptr: [*]const u8, len: usize) void {
    std.debug.print("{s}\n", .{ptr[0..len]});
}

pub fn startServer(io: std.Io, allocator: std.mem.Allocator, transport: *lsp.Transport) !void {
    var documents: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var schema_manager: parLsp.SchemaManager = .empty;
    defer {
        for (documents.keys())   |k| allocator.free(k);
        for (documents.values()) |v| allocator.free(v);
        documents.deinit(allocator);
        schema_manager.deinit(allocator);
    }

    while (true) {
        const json_message = try transport.readJsonMessage(io, allocator);
        defer allocator.free(json_message);

        const msg = try parLsp.Message.parseFromSlice(
            allocator, json_message, .{ .ignore_unknown_fields = true },
        );
        defer msg.deinit();

        try parLsp.handleMessage(&documents, &schema_manager, allocator, io, msg, transport);
    }
}