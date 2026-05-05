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

export fn parse(in_ptr: [*]const u8, in_len: usize, out_ptr: [*]u8, out_max: usize) i32 {
    const input = std.mem.trim(u8, in_ptr[0..in_len], " \t\r\n");
    var rgba: [4]u8 = .{ 0, 0, 0, 255 };
    if (!parseRgbaToU8(input, &rgba)) return -1;
    const result = std.fmt.bufPrint(out_ptr[0..out_max], "color:{d},{d},{d},{d}", .{
        rgba[0], rgba[1], rgba[2], rgba[3],
    }) catch return -1;
    return @intCast(result.len);
}

const ParserHint = struct {
    line:      u32,
    character: u32,
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

export fn textDocument_documentColor(in_ptr: [*]const u8, in_len: usize, out_ptr: [*]u8, out_max: usize) i32 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const root = std.json.parseFromSlice(std.json.Value, a, in_ptr[0..in_len], .{}) catch return -1;
    const obj  = switch (root.value) { .object => |o| o, else => return -1 };
    const hints_val = obj.get("hints") orelse return -1;
    const hints_arr = switch (hints_val) { .array => |arr| arr.items, else => return -1 };

    var colors: std.ArrayList(lsp.types.DocumentColor) = .empty;

    for (hints_arr) |hint_val| {
        const hint = std.json.parseFromValue(
            ParserHint, a, hint_val, .{ .ignore_unknown_fields = true },
        ) catch continue;

        if (!std.mem.startsWith(u8, hint.value.text, "color:")) continue;

        var rgba_u8: [4]u8 = .{ 0, 0, 0, 255 };
        if (!parseRgbaToU8(hint.value.text["color:".len..], &rgba_u8)) continue;

        colors.append(a, .{
            .range = .{
                .start = .{ .line = hint.value.line, .character = hint.value.character },
                .end   = .{ .line = hint.value.line, .character = hint.value.character + hint.value.length },
            },
            .color = .{
                .red   = @as(f32, @floatFromInt(rgba_u8[0])) / 255.0,
                .green = @as(f32, @floatFromInt(rgba_u8[1])) / 255.0,
                .blue  = @as(f32, @floatFromInt(rgba_u8[2])) / 255.0,
                .alpha = @as(f32, @floatFromInt(rgba_u8[3])) / 255.0,
            },
        }) catch continue;
    }

    return jsonWrite(a, colors.items, .{ .emit_null_optional_fields = false }, out_ptr, out_max);
}

export fn textDocument_colorPresentation(in_ptr: [*]const u8, in_len: usize, out_ptr: [*]u8, out_max: usize) i32 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const root = std.json.parseFromSlice(std.json.Value, a, in_ptr[0..in_len], .{}) catch return -1;
    const obj  = switch (root.value) { .object => |o| o, else => return -1 };
    const params_val = obj.get("params") orelse return -1;

    const params = std.json.parseFromValue(
        lsp.types.ColorPresentation.Params, a, params_val, .{ .ignore_unknown_fields = true },
    ) catch return -1;
    const c = params.value.color;

    var label_buf: [256]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "{{{d:.4}, {d:.4}, {d:.4}, {d:.4}}}", .{
        c.red, c.green, c.blue, c.alpha,
    }) catch return -1;

    const presentations = [_]lsp.types.ColorPresentation{
        .{ .label = label },
    };

    return jsonWrite(a, &presentations, .{ .emit_null_optional_fields = false }, out_ptr, out_max);
}

const InlayHintOut = struct {
    position:     lsp.types.Position,
    label:        []const u8,
    kind:         u8   = 1,
    paddingRight: bool = true,
};

export fn textDocument_inlayHint(in_ptr: [*]const u8, in_len: usize, out_ptr: [*]u8, out_max: usize) i32 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const root = std.json.parseFromSlice(std.json.Value, a, in_ptr[0..in_len], .{}) catch return -1;
    const obj  = switch (root.value) { .object => |o| o, else => return -1 };

    const hints_val     = obj.get("hints")     orelse return -1;
    const hints         = switch (hints_val)     { .array => |arr| arr.items, else => return -1 };
    const docParams_val = obj.get("docParams") orelse return -1;
    const docParams     = switch (docParams_val) { .array => |arr| arr.items, else => return -1 };

    var result: std.ArrayList(InlayHintOut) = .empty;

    const color_labels = [_][]const u8{ "red:", "green:", "blue:", "alpha:" };

    for (hints) |hint_val| {
        const h    = switch (hint_val) { .object => |o| o, else => continue };
        const text = switch (h.get("text") orelse continue) { .string => |s| s, else => continue };
        if (!std.mem.startsWith(u8, text, "color:")) continue;

        const h_line = jsonInt(h.get("line"))      orelse continue;
        const h_char = jsonInt(h.get("character")) orelse continue;

        for (docParams) |dp_val| {
            const dp = switch (dp_val) { .object => |o| o, else => continue };
            if (jsonInt(dp.get("value_line"))      != h_line) continue;
            if (jsonInt(dp.get("value_character")) != h_char) continue;

            const elem_positions = switch (dp.get("elem_positions") orelse continue) {
                .array => |arr| arr.items, else => continue,
            };

            for (elem_positions, 0..) |ep_val, i| {
                if (i >= color_labels.len) break;
                const ep   = switch (ep_val) { .object => |o| o, else => continue };
                const line = jsonInt(ep.get("line"))      orelse continue;
                const char = jsonInt(ep.get("character")) orelse continue;

                result.append(a, .{
                    .position = .{ .line = @intCast(line), .character = @intCast(char) },
                    .label    = color_labels[i],
                }) catch continue;
            }
        }
    }

    return jsonWrite(a, result.items, .{ .emit_null_optional_fields = false }, out_ptr, out_max);
}



extern fn wasm_log(ptr: [*]const u8, len: usize) void;

fn log_fmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    wasm_log(msg.ptr, msg.len);
}

fn parseRgbaToU8(input: []const u8, out: *[4]u8) bool {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len < 2) return false;

    const content = if (trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}')
        trimmed[1 .. trimmed.len - 1]
    else
        trimmed;

    var vals: [4]f32 = .{ 0, 0, 0, 1.0 };
    var it = std.mem.tokenizeAny(u8, content, ", \t");
    var count: usize = 0;
    var any_gt_one = false;
    while (it.next()) |tok| {
        if (count >= 4) break;
        const v = std.fmt.parseFloat(f32, tok) catch {
            return false;
        };
        vals[count] = v;
        if (v > 1.0) any_gt_one = true;
        count += 1;
    }
    if (count < 3) {
        return false;
    }

    if (count == 3) {
        vals[3] = if (any_gt_one) 255.0 else 1.0;
    }


    for (0..4) |i| {
        if (any_gt_one) {
            out[i] = @intFromFloat(@max(0, @min(255, @round(vals[i]))));
        } else {
            out[i] = @intFromFloat(@max(0, @min(255, @round(vals[i] * 255.0))));
        }
    }
    //log_fmt("result: {d},{d},{d},{d}", .{ out[0], out[1], out[2], out[3] });
    return true;
}

fn jsonInt(v: ?std.json.Value) ?i64 {
    return switch (v orelse return null) {
        .integer => |n| n,
        else     => null,
    };
}
