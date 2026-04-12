const std      = @import("std");
const lsp      = @import("lsp");
const paramlib = @import("paramlib");

const RequestMethods = union(enum) {
    initialize:                     lsp.types.InitializeParams,
    shutdown,
    @"textDocument/hover":          lsp.types.Hover.Params,
    @"textDocument/documentSymbol": lsp.types.DocumentSymbol.Params,
    other:                          lsp.MethodWithParams,
};

const NotificationMethods = union(enum) {
    initialized:               lsp.types.InitializedParams,
    exit,
    @"textDocument/didOpen":   lsp.types.TextDocument.DidOpenParams,
    @"textDocument/didChange": lsp.types.TextDocument.DidChangeParams,
    @"textDocument/didSave":   lsp.types.TextDocument.DidSaveParams,
    @"textDocument/didClose":  lsp.types.TextDocument.DidCloseParams,
    other:                     lsp.MethodWithParams,
};

const Message = lsp.Message(RequestMethods, NotificationMethods, .{});

pub fn main(init: std.process.Init) !void {
    const io  = init.io;
    const gpa = init.gpa;

    var read_buffer: [64 * 1024]u8 = undefined;
    var stdio: lsp.Transport.Stdio = .init(&read_buffer, .stdin(), .stdout());
    const transport: *lsp.Transport  = &stdio.transport;

    var documents: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer {
        for (documents.keys())   |k| gpa.free(k);
        for (documents.values()) |v| gpa.free(v);
        documents.deinit(gpa);
    }

    while (true) {
        const json_message = try transport.readJsonMessage(io, gpa);
        defer gpa.free(json_message);

        const msg = try Message.parseFromSlice(
            gpa, json_message, .{ .ignore_unknown_fields = true },
        );
        defer msg.deinit();

        switch (msg.value) {
            .request => |req| switch (req.params) {

                .initialize => {
                    try transport.writeResponse(io, gpa, req.id,
                        lsp.types.InitializeResult,
                        .{
                            .serverInfo  = .{ .name = "paramlib-lsp" },
                            .capabilities = .{
                                .textDocumentSync = .{ .text_document_sync_options = .{
                                    .openClose = true,
                                    .change    = .Full,
                                    .save      = .{ .bool = true },
                                }},
                                .hoverProvider          = .{ .bool = true },
                                .documentSymbolProvider = .{ .bool = true },
                            },
                        },
                        .{ .emit_null_optional_fields = false },
                    );
                },

                .shutdown => {
                    try transport.writeResponse(io, gpa, req.id, void, {}, .{});
                },

                .@"textDocument/hover" => |params| {
                    var arena = std.heap.ArenaAllocator.init(gpa);
                    defer arena.deinit();
                    const result = hover(io, &documents, arena.allocator(), params);
                    try transport.writeResponse(io, gpa, req.id,
                        ?lsp.types.Hover, result,
                        .{ .emit_null_optional_fields = false },
                    );
                },

                .@"textDocument/documentSymbol" => |params| {
                    const result = documentSymbols(io, &documents, gpa, params);
                    defer if (result) |syms| {
                        for (syms) |sym| gpa.free(sym.name);
                        gpa.free(syms);
                    };
                    try transport.writeResponse(io, gpa, req.id,
                        ?[]const lsp.types.SymbolInformation, result,
                        .{ .emit_null_optional_fields = false },
                    );
                },

                .other => {
                    try transport.writeResponse(io, gpa, req.id, void, {}, .{});
                },
            },

              .notification => |note| switch (note.params) {

                .initialized => {},
                .exit        => return,

                .@"textDocument/didOpen" => |params| {
                    const uri  = try gpa.dupe(u8, params.textDocument.uri);
                    const text = try gpa.dupe(u8, params.textDocument.text);
                    try documents.put(gpa, uri, text);
                    try publishDiagnostics(transport, io, gpa, &documents, params.textDocument.uri);
                },

                .@"textDocument/didChange" => |params| {
                    if (params.contentChanges.len > 0) {
                        const change = params.contentChanges[params.contentChanges.len - 1];
                        const new_text = switch (change) {
                            .text_document_content_change_whole_document => |c| c.text,
                            .text_document_content_change_partial        => |c| c.text,
                        };
                        if (documents.getPtr(params.textDocument.uri)) |slot| {
                            gpa.free(slot.*);
                            slot.* = try gpa.dupe(u8, new_text);
                        }
                    }
                    try publishDiagnostics(transport, io, gpa, &documents, params.textDocument.uri);
                },

                .@"textDocument/didSave" => |params| {
                    if (params.text) |text| {
                        if (documents.getPtr(params.textDocument.uri)) |slot| {
                            gpa.free(slot.*);
                            slot.* = try gpa.dupe(u8, text);
                        }
                    }
                    try publishDiagnostics(transport, io, gpa, &documents, params.textDocument.uri);
                },

                .@"textDocument/didClose" => |params| {
                    if (documents.fetchOrderedRemove(params.textDocument.uri)) |kv| {
                        gpa.free(kv.key);
                        gpa.free(kv.value);
                    }
                },

                .other => {},
            },

            .response => {},
        }
    }
}

const HoverNode = union(enum) {
    class: *const paramlib.cpp.ast.ClassAst,
    param: *const paramlib.cpp.ast.ParameterAst,
};

fn findNodeAtOffset(class: *const paramlib.cpp.ast.ClassAst, offset: u32) ?HoverNode {
    const members = class.members orelse return null;
    for (members.items) |*member| {
        switch (member.*) {
            .class => |*c| {
                if (c.name) |name| {
                    const name_end = c.name_pos + @as(u32, @intCast(name.len));
                    if (offset >= c.name_pos and offset < name_end)
                        return HoverNode{ .class = c };
                }
                if (findNodeAtOffset(c, offset)) |found| return found;
            },
            .param => |*p| {
                const name_end = p.name_pos + @as(u32, @intCast(p.name.len));
                if (offset >= p.name_pos and offset < name_end)
                    return HoverNode{ .param = p };
            },
            .delete    => {},
            .enumerable => {},
        }
    }
    return null;
}

fn hover(
    io:        std.Io,
    documents: *const std.StringArrayHashMapUnmanaged([]const u8),
    arena:     std.mem.Allocator,
    params:    lsp.types.Hover.Params,
) ?lsp.types.Hover {
    const text = documents.get(params.textDocument.uri) orelse return null;

    const src = arena.dupeZ(u8, text) catch return null;

    const line_table = paramlib.cpp.lexer.LineTable.build(arena, src) catch return null;

    const offset = offsetOf(
        line_table, src,
        @as(u32, @intCast(params.position.line))      + 1,
        @as(u32, @intCast(params.position.character)) + 1,
    );

    var errored = false;
    var root = paramlib.cpp.parser.parseSourceFull(
        io, arena, src, params.textDocument.uri, false, &errored, null,
    ) catch return null;
    defer root.deinit(arena);

    const node = findNodeAtOffset(&root, offset) orelse return null;

    const content: []const u8 = switch (node) {

        .class => |c| blk: {
            const name         = c.name orelse break :blk null;
            const member_count = if (c.members) |m| m.items.len else 0;
            if (c.base) |base| {
                const base_name = base.name orelse "?";
                break :blk std.fmt.allocPrint(
                    arena,
                    "**class** `{s}` : `{s}`\n\n*{d} member(s)*",
                    .{ name, base_name, member_count },
                ) catch return null;
            }
            break :blk std.fmt.allocPrint(
                arena,
                "**class** `{s}`\n\n*{d} member(s)*",
                .{ name, member_count },
            ) catch return null;
        },

        .param => |p| blk: {
            const op = switch (p.operator) {
                .assign    => "=",
                .addAssign => "+=",
                .subAssign => "-=",
            };
            const val = switch (p.value) {
                .integer    => |v| std.fmt.allocPrint(arena, "**int** `{d}`",       .{v}) catch return null,
                .i64        => |v| std.fmt.allocPrint(arena, "**i64** `{d}`",       .{v}) catch return null,
                .float      => |v| std.fmt.allocPrint(arena, "**float** `{d}`",     .{v}) catch return null,
                .string     => |v| std.fmt.allocPrint(arena, "**string** `\"{s}\"`",.{v}) catch return null,
                .expression => |v| std.fmt.allocPrint(arena, "**expression** `@{s}`",.{v}) catch return null,
                .array      => |v| std.fmt.allocPrint(arena, "**array**[{d}]",      .{v.len}) catch return null,
            };
            break :blk std.fmt.allocPrint(
                arena, "**param** `{s}` {s} {s}", .{ p.name, op, val },
            ) catch return null;
        },
    } orelse return null;

    return lsp.types.Hover{
        .contents = .{ .markup_content = .{ .kind = .markdown, .value = content } },
    };
}

fn collectSymbols(
    gpa:        std.mem.Allocator,
    class:      *const paramlib.cpp.ast.ClassAst,
    uri:        []const u8,
    line_table: *const paramlib.cpp.lexer.LineTable,
    list:       *std.ArrayList(lsp.types.SymbolInformation),
) void {
    const members = class.members orelse return;
    for (members.items) |*member| {
        switch (member.*) {
            .class => |*c| {
                if (c.name) |name| {
                    const start = lspPos(line_table, c.name_pos);
                    const end   = lsp.types.Position{
                        .line      = start.line,
                        .character = start.character + @as(u32, @intCast(name.len)),
                    };
                    list.append(gpa, .{
                        .name     = gpa.dupe(u8, name) catch continue,
                        .kind     = .Class,
                        .location = .{ .uri = uri, .range = .{ .start = start, .end = end } },
                    }) catch {};
                }
                collectSymbols(gpa, c, uri, line_table, list);
            },
            .param => |*p| {
                const start = lspPos(line_table, p.name_pos);
                const end   = lsp.types.Position{
                    .line      = start.line,
                    .character = start.character + @as(u32, @intCast(p.name.len)),
                };
                list.append(gpa, .{
                    .name     = gpa.dupe(u8, p.name) catch continue,
                    .kind     = .Field,
                    .location = .{ .uri = uri, .range = .{ .start = start, .end = end } },
                }) catch {};
            },
            .delete    => {},
            .enumerable => {},
        }
    }
}

fn documentSymbols(
    io:        std.Io,
    documents: *const std.StringArrayHashMapUnmanaged([]const u8),
    gpa:       std.mem.Allocator,
    params:    lsp.types.DocumentSymbol.Params,
) ?[]const lsp.types.SymbolInformation {
    const text = documents.get(params.textDocument.uri) orelse return null;

    const src = gpa.dupeZ(u8, text) catch return null;
    defer gpa.free(src);

    const line_table = paramlib.cpp.lexer.LineTable.build(gpa, src) catch return null;
    defer line_table.deinit(gpa);

    var errored = false;
    var root = paramlib.cpp.parser.parseSourceFull(
        io, gpa, src, params.textDocument.uri, false, &errored, null,
    ) catch return null;
    defer root.deinit(gpa);

    var list = std.ArrayList(lsp.types.SymbolInformation).empty;
    errdefer {
        for (list.items) |sym| gpa.free(sym.name);
        list.deinit(gpa);
    }

    collectSymbols(gpa, &root, params.textDocument.uri, &line_table, &list);

    if (list.items.len == 0) {
        list.deinit(gpa);
        return null;
    }
    return list.toOwnedSlice(gpa) catch null;
}

fn publishDiagnostics(
    transport: *lsp.Transport,
    io:        std.Io,
    gpa:       std.mem.Allocator,
    documents: *const std.StringArrayHashMapUnmanaged([]const u8),
    uri:       []const u8,
) !void {
    const text = documents.get(uri) orelse return;

    const src = try gpa.dupeZ(u8, text);
    defer gpa.free(src);

    const line_table = try paramlib.cpp.lexer.LineTable.build(gpa, src);
    defer line_table.deinit(gpa);

    var raw_diags: std.ArrayListUnmanaged(paramlib.cpp.logger.DiagEntry) = .empty;
    defer raw_diags.deinit(gpa);

    const sink = paramlib.cpp.logger.DiagSink{ .list = &raw_diags, .alloc = gpa };
    var errored = false;
    var root = paramlib.cpp.parser.parseSourceFull(io, gpa, src, uri, false, &errored, sink) catch |err| {
        try transport.writeNotification(io, gpa,
            "textDocument/publishDiagnostics",
            lsp.types.publish_diagnostics.Params,
            .{ .uri = uri, .diagnostics = &.{
                .{
                    .range    = .{ .start = .{ .line = 0, .character = 0 },
                                   .end   = .{ .line = 0, .character = 0 } },
                    .severity = .Error,
                    .message  = @errorName(err),
                },
            }},
            .{ .emit_null_optional_fields = false },
        );
        return;
    };
    root.deinit(gpa);

    var diags = std.ArrayList(lsp.types.Diagnostic).empty;
    defer diags.deinit(gpa);

    for (raw_diags.items) |entry| {
        const start = lspPos(&line_table, entry.token_pos);
        const end   = lsp.types.Position{
            .line      = start.line,
            .character = start.character + entry.span,
        };
        const severity: lsp.types.Diagnostic.Severity = switch (entry.level) {
            .err     => .Error,
            .warning => .Warning,
            .note    => .Information,
            .hint    => .Hint,
        };
        try diags.append(gpa, .{
            .range    = .{ .start = start, .end = end },
            .severity = severity,
            .message  = entry.message,
        });
    }

    try transport.writeNotification(io, gpa,
        "textDocument/publishDiagnostics",
        lsp.types.publish_diagnostics.Params,
        .{ .uri = uri, .diagnostics = diags.items },
        .{ .emit_null_optional_fields = false },
    );
}

fn offsetOf(lt: paramlib.cpp.lexer.LineTable, src: [:0]const u8, line: u32, col: u32) u32 {
    const line_start: u32 = if (line <= 1) 0
        else lt.newline_offsets[@min(line - 2, lt.newline_offsets.len -| 1)] + 1;
    return @min(line_start + col - 1, @as(u32, @intCast(src.len)));
}

fn lspPos(lt: *const paramlib.cpp.lexer.LineTable, offset: u32) lsp.types.Position {
    const r = lt.resolve(offset);
    return .{ .line = r.line - 1, .character = r.column - 1 };
}
