const std = @import("std");
const parLsp = @import("lsp.zig");
const lsp = @import("lsp");

pub fn main(init: std.process.Init) !void {
    var read_buffer: [64 * 1024]u8 = undefined;
    var stdio: lsp.Transport.Stdio = .init(&read_buffer, .stdin(), .stdout());
    const transport: *lsp.Transport  = &stdio.transport;

    return parLsp.startServer(init.io, init.gpa, transport);
}