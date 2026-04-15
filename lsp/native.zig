const std = @import("std");
const lsp = @import("lsp.zig");

pub fn main(init: std.process.Init) !void {
    return lsp.startServer(init.io, init.gpa);
}