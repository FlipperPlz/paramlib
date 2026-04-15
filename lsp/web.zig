const std = @import("std");
const lsp      = @import("lsp");
const parLsp = @import("lsp.zig");

var allocator = std.heap.wasm_allocator;

extern fn host_send(ptr: [*]const u8, len: u32) void;

const HostWriter = struct {
    buf: std.ArrayList(u8) = .empty,
    buffered: std.Io.Writer,

    pub fn init() HostWriter {
        var writer = .{
            .buffered = undefined
        };
        writer.buffered = std.Io.Writer.fromArrayList(&writer.buf);
        return writer;
    }

    pub fn deinit(self: *HostWriter) void {
        self.buf.deinit();
    }

    pub fn flush(self: *HostWriter) void {
        self.buffered.flush() catch {};

        if (self.buf.items.len == 0) return;
        host_send(self.buf.items.ptr, @intCast(self.buf.items.len));
        self.buf.clearRetainingCapacity();
    }
};

var host_writer: HostWriter = undefined;


export fn wasm_write(ptr: [*]u8, len: u32) void {
    const msg = ptr[0..len];
    defer allocator.free(msg);

    //recieve

    host_writer.flush();
}