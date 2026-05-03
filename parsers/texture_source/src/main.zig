const std = @import("std");
const lsp = @import("lsp");

const alloc = std.heap.wasm_allocator;

export fn wasm_alloc(len: usize) [*]u8 {
    const slice = alloc.alloc(u8, len) catch return undefined;
    return slice.ptr;
}

export fn wasm_free(ptr: [*]u8, len: usize) void {
    alloc.free(ptr[0..len]);
}

const ProcTexture = struct {
    format:   []const u8,
    width:    i32,
    height:   i32,
    nMipmaps: i32,
    procedure: []const u8,
    args:     []const u8,

    format_off: u32,
    width_off:  u32,
    height_off: u32,
    mips_off:   u32,
    proc_off:   u32,
    args_off:   u32,
};

fn isPowerOfTwo(v: i32) bool {
    if (v <= 0) return false;
    const uv: u32 = @intCast(v);
    return (uv & (uv - 1)) == 0;
}

fn parseProcTexture(src: []const u8) ?ProcTexture {
    if (!std.mem.startsWith(u8, src, "#(")) return null;
    const first_close = std.mem.indexOfScalar(u8, src, ')') orelse return null;
    const header_text = src[2..first_close];
    
    const rest = src[first_close + 1..];
    const first_open = std.mem.indexOfScalar(u8, rest, '(') orelse return null;
    const procedure = rest[0..first_open];
    
    const last_close = std.mem.lastIndexOfScalar(u8, rest, ')') orelse return null;
    const args = rest[first_open + 1 .. last_close];

    var it = std.mem.splitScalar(u8, header_text, ',');
    const f_slice = it.next() orelse return null;
    const w_slice = it.next() orelse return null;
    const h_slice = it.next() orelse return null;
    const m_slice = it.next() orelse return null;

    const f     = std.mem.trim(u8, f_slice, " ");
    const w_str = std.mem.trim(u8, w_slice, " ");
    const h_str = std.mem.trim(u8, h_slice, " ");
    const m_str = std.mem.trim(u8, m_slice, " ");

    // Derive offsets from the trimmed slice pointer positions within header_text,
    // then add 2 for the leading "#(" prefix.  Using indexOf would fail when
    // width == height (same digit string), always finding the first occurrence.
    const base: [*]const u8 = header_text.ptr;
    const f_off: u32 = 2 + @as(u32, @intCast(@intFromPtr(f.ptr)     - @intFromPtr(base)));
    const w_off: u32 = 2 + @as(u32, @intCast(@intFromPtr(w_str.ptr) - @intFromPtr(base)));
    const h_off: u32 = 2 + @as(u32, @intCast(@intFromPtr(h_str.ptr) - @intFromPtr(base)));
    const m_off: u32 = 2 + @as(u32, @intCast(@intFromPtr(m_str.ptr) - @intFromPtr(base)));
    const proc_off: u32 = @intCast(first_close + 1);
    const args_off: u32 = @intCast(first_close + 1 + first_open + 1);

    const w = std.fmt.parseInt(i32, w_str, 10) catch -1;
    const h = std.fmt.parseInt(i32, h_str, 10) catch -1;
    const m = std.fmt.parseInt(i32, m_str, 10) catch -1;

    return .{
        .format     = f,
        .width      = w,
        .height     = h,
        .nMipmaps   = m,
        .procedure  = procedure,
        .args       = args,
        .format_off = f_off,
        .width_off  = w_off,
        .height_off = h_off,
        .mips_off   = m_off,
        .proc_off   = proc_off,
        .args_off   = args_off,
    };
}

export fn parse(in_ptr: [*]const u8, in_len: usize, out_ptr: [*]u8, out_max: usize) i32 {
    const input = std.mem.trim(u8, in_ptr[0..in_len], " \t\r\n");
    const src = if (input.len >= 2 and input[0] == '"' and input[input.len - 1] == '"')
        input[1 .. input.len - 1]
    else
        input;

    if (parseProcTexture(src)) |_| {
        const result = std.fmt.bufPrint(out_ptr[0..out_max], "texture:{s}", .{src}) catch return -1;
        return @intCast(result.len);
    }
    return -1;
}

const ParserHint = struct {
    line:      u32,
    character: u32,
    offset:    u32,
    text:      []const u8,
    length:    u32,
};

fn jsonWrite(a: std.mem.Allocator, v: anytype, options: std.json.Stringify.Options, out_ptr: [*]u8, out_max: usize) i32 {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    std.json.Stringify.value(v, options, &out.writer) catch return -1;
    const json = out.written();
    if (json.len > out_max) return -1;
    @memcpy(out_ptr[0..json.len], json);
    return @intCast(json.len);
}

const InlayHintOut = struct {
    position:     lsp.types.Position,
    label:        []const u8,
    kind:         u8   = 1,
    paddingRight: bool = true,
};

fn resolvePos(offset: u32, line_offsets: []const u32) lsp.types.Position {
    var lo: usize = 0;
    var hi: usize = line_offsets.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (line_offsets[mid] < offset) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    const line: u32 = @intCast(lo);
    const line_start: u32 = if (lo == 0) 0 else line_offsets[lo - 1] + 1;
    return .{
        .line      = line,
        .character = offset - line_start,
    };
}

fn offsetOf(line: u32, character: u32, line_offsets: []const u32) u32 {
    const line_start: u32 = if (line == 0) 0 else line_offsets[line - 1] + 1;
    return line_start + character;
}

export fn textDocument_inlayHint(in_ptr: [*]const u8, in_len: usize, out_ptr: [*]u8, out_max: usize) i32 {
    var arena_alloc = std.heap.ArenaAllocator.init(alloc);
    defer arena_alloc.deinit();
    const a = arena_alloc.allocator();

    const root = std.json.parseFromSlice(std.json.Value, a, in_ptr[0..in_len], .{}) catch return -1;
    const obj  = switch (root.value) { .object => |o| o, else => return -1 };

    const hints_val = obj.get("hints") orelse return -1;
    const hints_arr = switch (hints_val) { .array => |arr| arr.items, else => return -1 };

    var result: std.ArrayList(InlayHintOut) = .empty;

    const labels  = [_][]const u8{ "format:", "width:", "height:", "mips:", "proc:", "args:" };

    for (hints_arr) |hint_val| {
        const h = switch (hint_val) { .object => |o| o, else => continue };
        const text = switch (h.get("text") orelse continue) { .string => |s| s, else => continue };
        if (!std.mem.startsWith(u8, text, "texture:")) continue;
        const src = text["texture:".len..];

        const h_line   = switch (h.get("line")      orelse continue) { .integer => |n| @as(u32, @intCast(n)), else => continue };
        const h_char   = switch (h.get("character") orelse continue) { .integer => |n| @as(u32, @intCast(n)), else => continue };
        const h_length = switch (h.get("length")    orelse continue) { .integer => |n| @as(u32, @intCast(n)), else => continue };

        const pt = parseProcTexture(src) orelse continue;

        // If the raw value is quoted the hint character points to the opening '"',
        // so add 1 to land on the '#'.
        const quoted    = h_length > @as(u32, @intCast(src.len));
        const base_char = h_char + if (quoted) @as(u32, 1) else 0;

        const offsets = [_]u32{ pt.format_off, pt.width_off, pt.height_off, pt.mips_off, pt.proc_off, pt.args_off };

        for (labels, offsets) |label, off| {
            result.append(a, .{
                .position = .{ .line = h_line, .character = base_char + off },
                .label    = label,
            }) catch continue;
        }
    }

    return jsonWrite(a, result.items, .{ .emit_null_optional_fields = false }, out_ptr, out_max);
}

export fn textDocument_completion(in_ptr: [*]const u8, in_len: usize, out_ptr: [*]u8, out_max: usize) i32 {
    var arena_alloc = std.heap.ArenaAllocator.init(alloc);
    defer arena_alloc.deinit();
    const a = arena_alloc.allocator();

    const root = std.json.parseFromSlice(std.json.Value, a, in_ptr[0..in_len], .{}) catch return -1;
    const obj  = switch (root.value) { .object => |o| o, else => return -1 };
    
    const params_val = obj.get("params") orelse return -1;
    const params_obj = switch (params_val) { .object => |o| o, else => return -1 };
    const pos_val    = params_obj.get("position") orelse return -1;
    const pos_obj    = switch (pos_val) { .object => |o| o, else => return -1 };
    const pos_line   = @as(u32, @intCast(switch (pos_obj.get("line") orelse return -1) { .integer => |n| n, else => return -1 }));
    const pos_char   = @as(u32, @intCast(switch (pos_obj.get("character") orelse return -1) { .integer => |n| n, else => return -1 }));

    const hints_val = obj.get("hints") orelse return -1;
    const hints_arr = switch (hints_val) { .array => |arr| arr.items, else => return -1 };

    const lo_val = obj.get("lineOffsets") orelse return -1;
    const lo_arr = switch (lo_val) { .array => |arr| arr.items, else => return -1 };
    const line_offsets = a.alloc(u32, lo_arr.len) catch return -1;
    for (lo_arr, 0..) |v, i| line_offsets[i] = @intCast(switch (v) { .integer => |n| n, else => 0 });

    const current_offset = offsetOf(pos_line, pos_char, line_offsets);

    var items = std.ArrayList(lsp.types.completion.Item).empty;

    for (hints_arr) |hint_val| {
        const hint = std.json.parseFromValue(
            ParserHint, a, hint_val, .{ .ignore_unknown_fields = true },
        ) catch continue;

        if (!std.mem.startsWith(u8, hint.value.text, "texture:")) continue;
        const src = hint.value.text["texture:".len..];

        const quoted = hint.value.length > src.len;
        const base_off = hint.value.offset + if (quoted) @as(u32, 1) else 0;

        if (current_offset < base_off or current_offset > base_off + src.len) continue;

        const rel_off = current_offset - base_off;

        // format completion
        if (rel_off >= 2 and rel_off <= 2 + (std.mem.indexOfScalar(u8, src[2..], ',') orelse src.len - 2)) {
            const formats = [_][]const u8{ "ai", "argb", "rgb", "a", "i" };
            for (formats) |f| {
                items.append(a, .{
                    .label = f,
                    .kind = .EnumMember,
                    .detail = "texture format",
                }) catch continue;
            }
        }

        // procedure completion
        if (std.mem.indexOfScalar(u8, src, ')')) |first_close| {
            if (rel_off > first_close and rel_off <= first_close + 1 + (std.mem.indexOfScalar(u8, src[first_close + 1..], '(') orelse src.len - (first_close + 1))) {
                const procs = [_][]const u8{ "color", "tex", "waterirradiance", "perlin", "noise", "jitters", "clouds" };
                for (procs) |p| {
                    items.append(a, .{
                        .label = p,
                        .kind = .Function,
                        .detail = "procedural texture",
                    }) catch continue;
                }
            }
        }
    }

    const result = lsp.types.completion.Result{ .completion_items = items.items };
    return jsonWrite(a, result, .{ .emit_null_optional_fields = false }, out_ptr, out_max);
}

export fn textDocument_documentColor(in_ptr: [*]const u8, in_len: usize, out_ptr: [*]u8, out_max: usize) i32 {
    var arena_alloc = std.heap.ArenaAllocator.init(alloc);
    defer arena_alloc.deinit();
    const a = arena_alloc.allocator();

    const root = std.json.parseFromSlice(std.json.Value, a, in_ptr[0..in_len], .{}) catch return -1;
    const obj  = switch (root.value) { .object => |o| o, else => return -1 };
    const hints_val = obj.get("hints") orelse return -1;
    const hints_arr = switch (hints_val) { .array => |arr| arr.items, else => return -1 };

    var colors: std.ArrayList(lsp.types.DocumentColor) = .empty;

    for (hints_arr) |hint_val| {
        const hint = std.json.parseFromValue(
            ParserHint, a, hint_val, .{ .ignore_unknown_fields = true },
        ) catch continue;

        if (!std.mem.startsWith(u8, hint.value.text, "texture:")) continue;
        const src = hint.value.text["texture:".len..];

        const pt = parseProcTexture(src) orelse continue;
        if (!std.mem.eql(u8, pt.procedure, "color")) continue;

        var rgba: [4]f32 = .{ 0, 0, 0, 1 };
        var it = std.mem.tokenizeAny(u8, pt.args, ", ");
        var i: usize = 0;
        while (it.next()) |tok| : (i += 1) {
            if (i >= 4) break;
            rgba[i] = std.fmt.parseFloat(f32, tok) catch 0.0;
        }
        if (i < 3) continue;

        colors.append(a, .{
            .range = .{
                .start = .{ .line = hint.value.line, .character = hint.value.character },
                .end   = .{ .line = hint.value.line, .character = hint.value.character + hint.value.length },
            },
            .color = .{
                .red   = rgba[0],
                .green = rgba[1],
                .blue  = rgba[2],
                .alpha = rgba[3],
            },
        }) catch continue;
    }

    return jsonWrite(a, colors.items, .{ .emit_null_optional_fields = false }, out_ptr, out_max);
}

export fn textDocument_diagnostic(in_ptr: [*]const u8, in_len: usize, out_ptr: [*]u8, out_max: usize) i32 {
    var arena_alloc = std.heap.ArenaAllocator.init(alloc);
    defer arena_alloc.deinit();
    const a = arena_alloc.allocator();

    const root = std.json.parseFromSlice(std.json.Value, a, in_ptr[0..in_len], .{}) catch return -1;
    const obj  = switch (root.value) { .object => |o| o, else => return -1 };
    const hints_val = obj.get("hints") orelse return -1;
    const hints_arr = switch (hints_val) { .array => |arr| arr.items, else => return -1 };

    var diags: std.ArrayList(lsp.types.Diagnostic) = .empty;

    for (hints_arr) |hint_val| {
        const hint = std.json.parseFromValue(
            ParserHint, a, hint_val, .{ .ignore_unknown_fields = true },
        ) catch continue;

        if (!std.mem.startsWith(u8, hint.value.text, "texture:")) continue;
        const src = hint.value.text["texture:".len..];

        const pt = parseProcTexture(src) orelse {
            diags.append(a, .{
                .range = .{
                    .start = .{ .line = hint.value.line, .character = hint.value.character },
                    .end   = .{ .line = hint.value.line, .character = hint.value.character + hint.value.length },
                },
                .severity = .Error,
                .message = "Procedural texture syntax error. Expected: #(format,w,h,mips)proc(args)",
            }) catch continue;
            continue;
        };

        if (pt.width <= 0 or pt.height <= 0 or pt.nMipmaps <= 0) {
            diags.append(a, .{
                .range = .{
                    .start = .{ .line = hint.value.line, .character = hint.value.character },
                    .end   = .{ .line = hint.value.line, .character = hint.value.character + hint.value.length },
                },
                .severity = .Error,
                .message = "Invalid texture dimensions: width, height, and mips must be positive.",
            }) catch continue;
        } else {
            if (!isPowerOfTwo(pt.width) or !isPowerOfTwo(pt.height)) {
                diags.append(a, .{
                    .range = .{
                        .start = .{ .line = hint.value.line, .character = hint.value.character },
                        .end   = .{ .line = hint.value.line, .character = hint.value.character + hint.value.length },
                    },
                    .severity = .Error,
                    .message = "Texture dimensions must be powers of 2.",
                }) catch continue;
            }

            const max_dim = @max(pt.width, pt.height);
            if (pt.nMipmaps > 0 and (@as(u31, 1) << @intCast(pt.nMipmaps - 1)) > max_dim) {
                diags.append(a, .{
                    .range = .{
                        .start = .{ .line = hint.value.line, .character = hint.value.character },
                        .end   = .{ .line = hint.value.line, .character = hint.value.character + hint.value.length },
                    },
                    .severity = .Error,
                    .message = "Too many mipmaps for given dimensions.",
                }) catch continue;
            }
        }
    }

    return jsonWrite(a, diags.items, .{ .emit_null_optional_fields = false }, out_ptr, out_max);
}

const SemanticToken = struct {
    line: u32,
    character: u32,
    length: u32,
    type: u32,
    modifier: u32 = 0,
};

fn addToken(arena: std.mem.Allocator, tokens: *std.ArrayList(u32), tok: SemanticToken, prev_line: *u32, prev_char: *u32) !void {
    const delta_line = tok.line - prev_line.*;
    const delta_char = if (delta_line == 0) tok.character - prev_char.* else tok.character;

    try tokens.append(arena, delta_line);
    try tokens.append(arena, delta_char);
    try tokens.append(arena, tok.length);
    try tokens.append(arena, tok.type);
    try tokens.append(arena, tok.modifier);

    prev_line.* = tok.line;
    prev_char.* = tok.character;
}

export fn textDocument_semanticTokens_full(in_ptr: [*]const u8, in_len: usize, out_ptr: [*]u8, out_max: usize) i32 {
    var arena_alloc = std.heap.ArenaAllocator.init(alloc);
    defer arena_alloc.deinit();
    const a = arena_alloc.allocator();

    const root = std.json.parseFromSlice(std.json.Value, a, in_ptr[0..in_len], .{}) catch return -1;
    const obj  = switch (root.value) { .object => |o| o, else => return -1 };
    
    const hints_val = obj.get("hints") orelse return -1;
    const hints_arr = switch (hints_val) { .array => |arr| arr.items, else => return -1 };
    
    const lo_val = obj.get("lineOffsets") orelse return -1;
    const lo_arr = switch (lo_val) { .array => |arr| arr.items, else => return -1 };
    const line_offsets = a.alloc(u32, lo_arr.len) catch return -1;
    for (lo_arr, 0..) |v, i| line_offsets[i] = @intCast(switch (v) { .integer => |n| n, else => 0 });

    var data = std.ArrayList(u32).empty;
    var prev_line: u32 = 0;
    var prev_char: u32 = 0;

    for (hints_arr) |hint_val| {
        const hint = std.json.parseFromValue(
            ParserHint, a, hint_val, .{ .ignore_unknown_fields = true },
        ) catch continue;

        if (!std.mem.startsWith(u8, hint.value.text, "texture:")) continue;
        const src = hint.value.text["texture:".len..];

        const quoted = hint.value.length > src.len;
        const base_off = hint.value.offset + if (quoted) @as(u32, 1) else 0;

        // punctuation: #(
        const pos_start = resolvePos(base_off, line_offsets);
        addToken(a, &data, .{ .line = pos_start.line, .character = pos_start.character, .length = 2, .type = 4 }, &prev_line, &prev_char) catch continue;

        const pt = parseProcTexture(src) orelse continue;

        // format
        const pos_format = resolvePos(base_off + pt.format_off, line_offsets);
        addToken(a, &data, .{ .line = pos_format.line, .character = pos_format.character, .length = @intCast(pt.format.len), .type = 0 }, &prev_line, &prev_char) catch continue;

        // width, height, mips
        const dims = [_]struct { off: u32, val: []const u8 }{
            .{ .off = pt.width_off, .val = std.mem.trim(u8, src[pt.width_off..pt.height_off - 1], " ") },
            .{ .off = pt.height_off, .val = std.mem.trim(u8, src[pt.height_off..pt.mips_off - 1], " ") },
            .{ .off = pt.mips_off, .val = std.mem.trim(u8, src[pt.mips_off..std.mem.indexOfScalar(u8, src, ')').?], " ") },
        };

        for (dims) |d| {
            const pos = resolvePos(base_off + d.off, line_offsets);
            addToken(a, &data, .{ .line = pos.line, .character = pos.character, .length = @intCast(d.val.len), .type = 5 }, &prev_line, &prev_char) catch continue;
        }

        // )
        const first_close = std.mem.indexOfScalar(u8, src, ')').?;
        const pos_close = resolvePos(base_off + @as(u32, @intCast(first_close)), line_offsets);
        addToken(a, &data, .{ .line = pos_close.line, .character = pos_close.character, .length = 1, .type = 4 }, &prev_line, &prev_char) catch continue;

        // procedure
        const pos_proc = resolvePos(base_off + pt.proc_off, line_offsets);
        addToken(a, &data, .{ .line = pos_proc.line, .character = pos_proc.character, .length = @intCast(pt.procedure.len), .type = 0 }, &prev_line, &prev_char) catch continue;

        // (
        const pos_args_open = resolvePos(base_off + pt.proc_off + @as(u32, @intCast(pt.procedure.len)), line_offsets);
        addToken(a, &data, .{ .line = pos_args_open.line, .character = pos_args_open.character, .length = 1, .type = 4 }, &prev_line, &prev_char) catch continue;

        // args
        var it = std.mem.tokenizeAny(u8, pt.args, ", ");
        while (it.next()) |tok| {
            const tok_off = @as(u32, @intCast(@intFromPtr(tok.ptr) - @intFromPtr(src.ptr)));
            const pos = resolvePos(base_off + tok_off, line_offsets);
            const is_num = if (tok.len > 0 and (std.ascii.isDigit(tok[0]) or tok[0] == '-' or tok[0] == '.')) true else false;
            addToken(a, &data, .{ .line = pos.line, .character = pos.character, .length = @intCast(tok.len), .type = if (is_num) @as(u32, 5) else @as(u32, 3) }, &prev_line, &prev_char) catch continue;
        }

        // )
        const last_close = std.mem.lastIndexOfScalar(u8, src, ')').?;
        const pos_last_close = resolvePos(base_off + @as(u32, @intCast(last_close)), line_offsets);
        addToken(a, &data, .{ .line = pos_last_close.line, .character = pos_last_close.character, .length = 1, .type = 4 }, &prev_line, &prev_char) catch continue;
    }

    const result = struct { data: []u32 }{ .data = data.items };
    return jsonWrite(a, result, .{}, out_ptr, out_max);
}
