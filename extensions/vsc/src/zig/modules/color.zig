const std = @import("std");
const color = @import("color");
comptime {
    @export(&color.alloc, .{ .name = "alloc", .linkage = .strong });
    @export(&color.free, .{ .name = "free", .linkage = .strong });
    @export(&color.deinit, .{ .name = "deinit", .linkage = .strong });
    @export(&color.parse, .{ .name = "parse", .linkage = .strong });
    @export(&color.textDocument_documentColor, .{ .name = "textDocument/documentColor", .linkage = .strong });
    @export(&color.textDocument_colorPresentation, .{ .name = "textDocument/colorPresentation", .linkage = .strong });
    @export(&color.textDocument_inlayHint, .{ .name = "textDocument/inlayHint", .linkage = .strong });
}