const std = @import("std");
const texture_source = @import("texture_source");
comptime {
    @export(&texture_source.alloc, .{ .name = "alloc", .linkage = .strong });
    @export(&texture_source.free, .{ .name = "free", .linkage = .strong });
    @export(&texture_source.deinit, .{ .name = "deinit", .linkage = .strong });
    @export(&texture_source.parse, .{ .name = "parse", .linkage = .strong });
    @export(&texture_source.textDocument_inlayHint, .{ .name = "textDocument/inlayHint", .linkage = .strong });
    @export(&texture_source.textDocument_completion, .{ .name = "textDocument/completion", .linkage = .strong });
    @export(&texture_source.textDocument_documentColor, .{ .name = "textDocument/documentColor", .linkage = .strong });
    @export(&texture_source.textDocument_colorPresentation, .{ .name = "textDocument/colorPresentation", .linkage = .strong });
    @export(&texture_source.textDocument_diagnostic, .{ .name = "textDocument/diagnostic", .linkage = .strong });
    @export(&texture_source.textDocument_semanticTokens_full, .{ .name = "textDocument/semanticTokens/full", .linkage = .strong });
}