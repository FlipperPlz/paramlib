const std = @import("std");
const lsp = @import("lsp");
const builtin = @import("builtin");

const wasm_allocator = if (builtin.target.cpu.arch == .wasm32) std.heap.wasm_allocator else std.heap.page_allocator;

extern fn wasm_log(ptr: [*]const u8, len: usize) void;

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    wasm_log(msg.ptr, msg.len);
}

pub fn alloc(len: usize) callconv(.c) [*]u8 {
    const slice = wasm_allocator.alloc(u8, len) catch return undefined;
    return slice.ptr;
}

pub fn free(ptr: [*]u8, len: usize) callconv(.c) void {
    wasm_allocator.free(ptr[0..len]);
}

pub fn deinit() callconv(.c) void {}

const ProcTextureToken = enum {
    Comma,
    OpenParen,
    CloseParen,
    Hash,
    Chunk,
    String,
    Whitespace,

    AI,
    ARGB,
    RGB,
    A,
    I,

    Irradiance,
    Color,
    Dither,
    PerlinNoise,
    WaterIrradiance,
    FresnelGlass,
    TreeCrown,
    TreeCrownAmb,
    Point,
    Fresnel,
    R2T,
    Text,
    UI,
    UIEx,
    Extension,

    Co,
    Ca,
    No,
    Ns,
    Dt,
    Mc,
    Sm,
    Smdi,
};

pub const TOKENS = std.StaticStringMap(ProcTextureToken).initComptime(.{
    .{ ",", .Comma },
    .{ "(", .OpenParen },
    .{ ")", .CloseParen },
    .{ "#", .Hash },
    .{ "ai", .AI },
    .{ "argb", .ARGB },
    .{ "rgb", .RGB },
    .{ "a", .A },
    .{ "i", .I },
    .{ "irradiance", .Irradiance },
    .{ "color", .Color },
    .{ "dither", .Dither },
    .{ "perlinnoise", .PerlinNoise },
    .{ "waterirradiance", .WaterIrradiance },
    .{ "fresnelglass", .FresnelGlass },
    .{ "treecrown", .TreeCrown },
    .{ "treecrownamb", .TreeCrownAmb },
    .{ "point", .Point },
    .{ "fresnel", .Fresnel },
    .{ "r2t", .R2T },
    .{ "text", .Text },
    .{ "ui", .UI },
    .{ "uiex", .UIEx },
    .{ "extension", .Extension },
    .{ "co", .Co },
    .{ "ca", .Ca },
    .{ "no", .No },
    .{ "ns", .Ns },
    .{ "dt", .Dt },
    .{ "mc", .Mc },
    .{ "sm", .Sm },
    .{ "smdi", .Smdi },
});

const Token = struct {
    type: ProcTextureToken,
    text: []const u8,
    offset: u32,
};

const Lexer = struct {
    src: []const u8,
    pos: u32 = 0,

    fn next(self: *Lexer) ?Token {
        if (self.pos >= self.src.len) return null;

        const start = self.pos;
        const char = self.src[self.pos];

        if (std.ascii.isWhitespace(char)) {
            while (self.pos < self.src.len and std.ascii.isWhitespace(self.src[self.pos])) : (self.pos += 1) {}
            return .{ .type = .Whitespace, .text = self.src[start..self.pos], .offset = start };
        }

        if (char == '#' or char == '(' or char == ')' or char == ',') {
            self.pos += 1;
            const text = self.src[start..self.pos];
            return .{ .type = TOKENS.get(text).?, .text = text, .offset = start };
        }

        if (char == '"') {
            self.pos += 1;
            while (self.pos < self.src.len and self.src[self.pos] != '"') : (self.pos += 1) {}
            if (self.pos < self.src.len) self.pos += 1;
            return .{ .type = .String, .text = self.src[start..self.pos], .offset = start };
        }

        while (self.pos < self.src.len) : (self.pos += 1) {
            const c = self.src[self.pos];
            if (c == '#' or c == '(' or c == ')' or c == ',' or std.ascii.isWhitespace(c) or c == '"') break;
        }
        const text = self.src[start..self.pos];
        return .{ .type = TOKENS.get(text) orelse .Chunk, .text = text, .offset = start };
    }

    fn peek(self: Lexer) ?Token {
        var copy = self;
        return copy.next();
    }
};

const DiagProcTexture = struct {
    texture: ProcTexture,
    format_off: u32,
    width_off: u32,
    height_off: u32,
    mips_off: u32,
    proc_off: u32,
    args_off: u32,

    procedure_name: []const u8,
    args_text: []const u8,
};

const ProcTextureId = enum {
    Irradiance,
    Color,
    Dither,
    PerlinNoise,
    WaterIrradiance,
    FresnelGlass,
    TreeCrown,
    TreeCrownAmb,
    Point,
    Fresnel,
    R2T,
    Text,
    UI,
    UIEx,
    Extension,
    Unknown,
};

const ProcTextureFormat = enum { AI, ARGB, RGB, A, I };

const TextureMapType = enum { Co, Ca, No, Ns, Dt, Mc, Sm, Smdi };

const ProcTexture = struct {
    format: ProcTextureFormat,
    width: i32,
    height: i32,
    nMipmaps: i32,
    args: ProcTextureArgs,
};

const Parser = struct {
    lexer: Lexer,
    diags: *std.ArrayListUnmanaged(lsp.types.Diagnostic),
    allocator: std.mem.Allocator,
    hint: ParserHint,
    hp: HintPos,

    fn next(self: *Parser) ?Token {
        const tok = self.lexer.next();
        if (tok) |t| {
            if (t.type == .Whitespace) {
                self.errorAt(t.offset, t.text.len, "Spaces are not allowed in procedural textures", .{});
                return self.next();
            }
            return t;
        }
        return null;
    }

    fn expect(self: *Parser, tok_type: ProcTextureToken) ?Token {
        const tok = self.next();
        if (tok) |t| {
            if (t.type == tok_type) return t;
            if (tok_type != .Chunk and tok_type != .String and t.type == .Chunk) {
                if (TOKENS.get(t.text)) |tt| {
                    if (tt == tok_type) return t;
                }
            }
            self.errorAt(t.offset, t.text.len, "Expected {s}, found '{s}'", .{ @tagName(tok_type), t.text });
        } else {
            self.errorAt(self.lexer.pos, 1, "Expected {s}, found end of string", .{@tagName(tok_type)});
        }
        return null;
    }

    fn errorAt(self: *Parser, offset: u32, len: u32, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "Syntax error";
        self.diags.append(self.allocator, .{
            .range = .{
                .start = .{ .line = self.hint.line, .character = self.hp.base_char + offset },
                .end = .{ .line = self.hint.line, .character = self.hp.base_char + offset + len },
            },
            .severity = .Error,
            .message = msg,
        }) catch {};
    }

    fn parseFloat(self: *Parser, tok: Token) f32 {
        if (tok.type != .Chunk) {
            self.errorAt(tok.offset, tok.text.len, "Expected a number", .{});
            return 0.0;
        }
        return std.fmt.parseFloat(f32, tok.text) catch blk: {
            log("failed to parse float: '{s}' at offset {d}", .{ tok.text, tok.offset });
            self.errorAt(tok.offset, tok.text.len, "Invalid float value", .{});
            break :blk 0.0;
        };
    }

    fn parseInt(self: *Parser, tok: Token) i32 {
        if (tok.type != .Chunk) {
            self.errorAt(tok.offset, tok.text.len, "Expected an integer", .{});
            return 0;
        }
        return std.fmt.parseInt(i32, tok.text, 10) catch blk: {
            self.errorAt(tok.offset, tok.text.len, "Invalid integer value", .{});
            break :blk 0;
        };
    }

    fn parseProcTexture(self: *Parser) ?DiagProcTexture {
        const src = self.lexer.src;
        if (!std.mem.startsWith(u8, src, "#(")) return null;

        _ = self.expect(.Hash) orelse return null;
        _ = self.expect(.OpenParen) orelse return null;

        const f_tok = self.next() orelse {
            self.errorAt(self.lexer.pos, 1, "Expected format (ai, argb, rgb, a, i)", .{});
            return null;
        };
        const format = switch (f_tok.type) {
            .AI => ProcTextureFormat.AI,
            .ARGB => ProcTextureFormat.ARGB,
            .RGB => ProcTextureFormat.RGB,
            .A => ProcTextureFormat.A,
            .I => ProcTextureFormat.I,
            else => blk: {
                self.errorAt(f_tok.offset, f_tok.text.len, "Invalid texture format. Expected: ai, argb, rgb, a, i", .{});
                break :blk ProcTextureFormat.AI;
            },
        };

        _ = self.expect(.Comma) orelse {};

        const w_tok = self.expect(.Chunk) orelse Token{ .type = .Chunk, .text = "-1", .offset = self.lexer.pos };
        const w = self.parseInt(w_tok);

        _ = self.expect(.Comma) orelse {};

        const h_tok = self.expect(.Chunk) orelse Token{ .type = .Chunk, .text = "-1", .offset = self.lexer.pos };
        const h = self.parseInt(h_tok);

        _ = self.expect(.Comma) orelse {};

        const m_tok = self.expect(.Chunk) orelse Token{ .type = .Chunk, .text = "-1", .offset = self.lexer.pos };
        const m = self.parseInt(m_tok);

        _ = self.expect(.CloseParen) orelse {};

        const p_tok = self.next() orelse {
            self.errorAt(self.lexer.pos, 1, "Expected procedure name", .{});
            return null;
        };

        const proc_id = switch (p_tok.type) {
            .Irradiance => ProcTextureId.Irradiance,
            .Color => ProcTextureId.Color,
            .Dither => ProcTextureId.Dither,
            .PerlinNoise => ProcTextureId.PerlinNoise,
            .WaterIrradiance => ProcTextureId.WaterIrradiance,
            .FresnelGlass => ProcTextureId.FresnelGlass,
            .TreeCrown => ProcTextureId.TreeCrown,
            .TreeCrownAmb => ProcTextureId.TreeCrownAmb,
            .Point => ProcTextureId.Point,
            .Fresnel => ProcTextureId.Fresnel,
            .R2T => ProcTextureId.R2T,
            .Text => ProcTextureId.Text,
            .UI => ProcTextureId.UI,
            .UIEx => ProcTextureId.UIEx,
            .Extension => ProcTextureId.Extension,
            else => blk: {
                self.errorAt(p_tok.offset, p_tok.text.len, "Unknown procedural texture", .{});
                break :blk ProcTextureId.Unknown;
            },
        };

        _ = self.expect(.OpenParen) orelse {};
        const args_off = self.lexer.pos;
        const args_start = self.lexer.pos;

        const args: ProcTextureArgs = switch (proc_id) {
            .Color => blk: {
                const r_tok = self.expect(.Chunk) orelse Token{ .type = .Chunk, .text = "0", .offset = self.lexer.pos };
                const r = self.parseFloat(r_tok);
                _ = self.expect(.Comma) orelse {};
                const g_tok = self.expect(.Chunk) orelse Token{ .type = .Chunk, .text = "0", .offset = self.lexer.pos };
                const g = self.parseFloat(g_tok);
                _ = self.expect(.Comma) orelse {};
                const b_tok = self.expect(.Chunk) orelse Token{ .type = .Chunk, .text = "0", .offset = self.lexer.pos };
                const b = self.parseFloat(b_tok);
                _ = self.expect(.Comma) orelse {};
                const a_tok = self.expect(.Chunk) orelse Token{ .type = .Chunk, .text = "0", .offset = self.lexer.pos };
                const a = self.parseFloat(a_tok);

                var map: ?TextureMapType = null;
                var map_off: u32 = 0;
                if (self.lexer.peek()) |peek| {
                    if (peek.type == .Comma) {
                        _ = self.lexer.next();
                        const m_tok_val = self.next() orelse Token{ .type = .Chunk, .text = "", .offset = self.lexer.pos };
                        map_off = m_tok_val.offset;
                        map = switch (m_tok_val.type) {
                            .Co => .Co,
                            .Ca => .Ca,
                            .No => .No,
                            .Ns => .Ns,
                            .Dt => .Dt,
                            .Mc => .Mc,
                            .Sm => .Sm,
                            .Smdi => .Smdi,
                            else => null,
                        };
                        if (map == null) self.errorAt(m_tok_val.offset, m_tok_val.text.len, "Invalid texture map type", .{});
                    }
                }
                break :blk .{ .Color = .{
                    .args = .{ .r = r, .g = g, .b = b, .a = a, .map = map },
                    .r_off = r_tok.offset,
                    .g_off = g_tok.offset,
                    .b_off = b_tok.offset,
                    .a_off = a_tok.offset,
                    .map_off = map_off,
                } };
            },
            .R2T => blk: {
                const s_tok = self.expect(.Chunk) orelse Token{ .type = .Chunk, .text = "", .offset = self.lexer.pos };
                const surface = s_tok.text;
                _ = self.expect(.Comma) orelse {};
                const a_tok = self.expect(.Chunk) orelse Token{ .type = .Chunk, .text = "1", .offset = self.lexer.pos };
                const aspect = self.parseFloat(a_tok);
                break :blk .{ .R2T = .{
                    .args = .{ .surface = surface, .aspect = aspect },
                    .surface_off = s_tok.offset,
                    .aspect_off = a_tok.offset,
                } };
            },
            .PerlinNoise => blk: {
                const xs_tok = self.expect(.Chunk) orelse Token{ .type = .Chunk, .text = "0", .offset = self.lexer.pos };
                const xScale = self.parseInt(xs_tok);
                _ = self.expect(.Comma) orelse {};
                const ys_tok = self.expect(.Chunk) orelse Token{ .type = .Chunk, .text = "0", .offset = self.lexer.pos };
                const yScale = self.parseInt(ys_tok);
                _ = self.expect(.Comma) orelse {};
                const min_tok = self.expect(.Chunk) orelse Token{ .type = .Chunk, .text = "0", .offset = self.lexer.pos };
                const min = self.parseInt(min_tok);
                _ = self.expect(.Comma) orelse {};
                const max_tok = self.expect(.Chunk) orelse Token{ .type = .Chunk, .text = "0", .offset = self.lexer.pos };
                const max = self.parseInt(max_tok);
                break :blk .{ .PerlinNoise = .{
                    .args = .{ .xScale = xScale, .yScale = yScale, .min = min, .max = max },
                    .xScale_off = xs_tok.offset,
                    .yScale_off = ys_tok.offset,
                    .min_off = min_tok.offset,
                    .max_off = max_tok.offset,
                } };
            },
            .Irradiance, .WaterIrradiance => blk: {
                const s_tok = self.expect(.Chunk) orelse Token{ .type = .Chunk, .text = "0", .offset = self.lexer.pos };
                const spec = self.parseInt(s_tok);
                const diag: IrradianceArgsDiag = .{
                    .args = .{ .specularPower = spec },
                    .specularPower_off = s_tok.offset,
                };
                if (proc_id == .Irradiance) break :blk .{ .Irradiance = diag };
                break :blk .{ .WaterIrradiance = diag };
            },
            .Fresnel => blk: {
                const n_tok = self.expect(.Chunk) orelse Token{ .type = .Chunk, .text = "0", .offset = self.lexer.pos };
                const n = self.parseFloat(n_tok);
                _ = self.expect(.Comma) orelse {};
                const k_tok = self.expect(.Chunk) orelse Token{ .type = .Chunk, .text = "0", .offset = self.lexer.pos };
                const k = self.parseInt(k_tok);
                break :blk .{ .Fresnel = FresnelArgsDiag{
                    .args = .{ .refractiveIndex = n, .absorptionCoefficient = k },
                    .refractiveIndex_off = n_tok.offset,
                    .absorptionCoefficient_off = k_tok.offset,
                } };
            },
            .TreeCrown, .TreeCrownAmb => blk: {
                const d_tok = self.expect(.Chunk) orelse Token{ .type = .Chunk, .text = "0", .offset = self.lexer.pos };
                const density = self.parseFloat(d_tok);
                const diag: TreeCrownArgsDiag = .{
                    .args = .{ .density = density },
                    .density_off = d_tok.offset,
                };
                if (proc_id == .TreeCrown) break :blk .{ .TreeCrown = diag };
                break :blk .{ .TreeCrownAmb = diag };
            },
            .Dither => blk: {
                const min_tok = self.expect(.Chunk) orelse Token{ .type = .Chunk, .text = "0", .offset = self.lexer.pos };
                const min = self.parseInt(min_tok);
                _ = self.expect(.Comma) orelse {};
                const max_tok = self.expect(.Chunk) orelse Token{ .type = .Chunk, .text = "0", .offset = self.lexer.pos };
                const max = self.parseInt(max_tok);
                break :blk .{ .Dither = DitherArgsDiag{
                    .args = .{ .min = min, .max = max },
                    .min_off = min_tok.offset,
                    .max_off = max_tok.offset,
                } };
            },
            else => blk: {
                var depth: i32 = 1;
                while (self.lexer.pos < src.len and depth > 0) : (self.lexer.pos += 1) {
                    if (src[self.lexer.pos] == '(') depth += 1;
                    if (src[self.lexer.pos] == ')') depth -= 1;
                }
                break :blk switch (proc_id) {
                    .FresnelGlass => .FresnelGlass,
                    .Point => .Point,
                    .UI => .UI,
                    .UIEx => .UIEx,
                    .Extension => .Extension,
                    .Unknown => .Unknown,
                    .Text => .{ .Text = TextArgsDiag{
                        .args = .{
                            .vAlign = .Center,
                            .hAlign = .Center,
                            .fontName = "",
                            .fontSize = 0,
                            .backgroundColor = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                            .textColor = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                            .text = "",
                        },
                        .vAlign_off = 0,
                        .hAlign_off = 0,
                        .fontName_off = 0,
                        .fontSize_off = 0,
                        .backgroundColor_off = 0,
                        .textColor_off = 0,
                        .text_off = 0,
                    } },
                    else => .Point,
                };
            },
        };

        const args_end_off = self.lexer.pos;
        _ = self.expect(.CloseParen) orelse {};
        const args_text = src[args_start..args_end_off];

        return .{
            .texture = .{
                .format = format,
                .width = w,
                .height = h,
                .nMipmaps = m,
                .args = args,
            },
            .format_off = f_tok.offset,
            .width_off = w_tok.offset,
            .height_off = h_tok.offset,
            .mips_off = m_tok.offset,
            .proc_off = p_tok.offset,
            .args_off = args_off,
            .procedure_name = p_tok.text,
            .args_text = args_text,
        };
    }
};

fn parseProcTextureWithDiags(a: std.mem.Allocator, src: []const u8, diags: *std.ArrayListUnmanaged(lsp.types.Diagnostic), hint: ParserHint, hp: HintPos) ?DiagProcTexture {
    var parser = Parser{
        .lexer = .{ .src = src },
        .diags = diags,
        .allocator = a,
        .hint = hint,
        .hp = hp,
    };
    return parser.parseProcTexture();
}

const HintPos = struct {
    base_char: u32,
    quoted: bool,
};

fn getHintPos(hint: ParserHint, src: []const u8) HintPos {
    const quoted = hint.length > src.len;
    return .{
        .quoted = quoted,
        .base_char = hint.character + if (quoted) @as(u32, 1) else 0,
    };
}

const IrradianceArgs = struct {
    const Diag = IrradianceArgsDiag;
    specularPower: i32,
};
const IrradianceArgsDiag = struct {
    args: IrradianceArgs,
    specularPower_off: u32,
};

const ColorArgs = struct {
    const Diag = ColorArgsDiag;
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    map: ?TextureMapType,
};
const ColorArgsDiag = struct {
    args: ColorArgs,
    r_off: u32,
    g_off: u32,
    b_off: u32,
    a_off: u32,
    map_off: u32,
};

const DitherArgs = struct {
    const Diag = DitherArgsDiag;
    min: i32,
    max: i32,
};

const DitherArgsDiag = struct {
    args: DitherArgs,
    min_off: u32,
    max_off: u32,
};

const PerlinNoiseArgs = struct {
    const Diag = PerlinNoiseArgsDiag;
    xScale: i32,
    yScale: i32,
    min: i32,
    max: i32,
};
const PerlinNoiseArgsDiag = struct {
    args: PerlinNoiseArgs,
    xScale_off: u32,
    yScale_off: u32,
    min_off: u32,
    max_off: u32,
};

const TreeCrownArgs = struct {
    const Diag = TreeCrownArgsDiag;
    density: f32,
};
const TreeCrownArgsDiag = struct {
    args: TreeCrownArgs,
    density_off: u32,
};

const FresnelArgs = struct {
    const Diag = FresnelArgsDiag;
    refractiveIndex: f32,
    absorptionCoefficient: i32,
};
const FresnelArgsDiag = struct {
    args: FresnelArgs,
    refractiveIndex_off: u32,
    absorptionCoefficient_off: u32,
};

const Render2TextureArgs = struct {
    const Diag = Render2TextureArgsDiag;
    surface: []const u8,
    aspect: f32,
};
const Render2TextureArgsDiag = struct {
    args: Render2TextureArgs,
    surface_off: u32,
    aspect_off: u32,
};

const TextVerticalAlignment = enum { Top, Center, Bottom };

const TextHorizontalAlignment = enum { Left, Center, Right };

const HexColor = struct { r: u8, g: u8, b: u8, a: u8 = 255 };

const TextArgs = struct {
    const Diag = TextArgsDiag;
    vAlign: TextVerticalAlignment,
    hAlign: TextHorizontalAlignment,
    fontName: []const u8,
    fontSize: f32,
    backgroundColor: HexColor,
    textColor: HexColor,
    text: []const u8,
};
const TextArgsDiag = struct {
    args: TextArgs,
    vAlign_off: u32,
    hAlign_off: u32,
    fontName_off: u32,
    fontSize_off: u32,
    backgroundColor_off: u32,
    textColor_off: u32,
    text_off: u32,
};

const ProcTextureArgs = union(ProcTextureId) {
    Irradiance: IrradianceArgs.Diag,
    Color: ColorArgs.Diag,
    Dither: DitherArgs.Diag,
    PerlinNoise: PerlinNoiseArgs.Diag,
    WaterIrradiance: IrradianceArgs.Diag,
    FresnelGlass: void,
    TreeCrown: TreeCrownArgs.Diag,
    TreeCrownAmb: TreeCrownArgs.Diag,
    Point: void,
    Fresnel: FresnelArgs.Diag,
    R2T: Render2TextureArgs.Diag,
    Text: TextArgs.Diag,
    UI: void,
    UIEx: void,
    Extension: void,
    Unknown: void,
};

fn isPowerOfTwo(v: i32) bool {
    if (v <= 0) return false;
    const uv: u32 = @intCast(v);
    return (uv & (uv - 1)) == 0;
}

fn parseProcTexture(src: []const u8) ?ProcTexture {
    var temp_diags = std.ArrayListUnmanaged(lsp.types.Diagnostic).empty;
    defer temp_diags.deinit(wasm_allocator);
    const dpt = parseProcTextureWithDiags(wasm_allocator, src, &temp_diags, .{ .line = 0, .character = 0, .text = "", .length = 0 }, .{ .base_char = 0, .quoted = false });
    return if (dpt) |d| d.texture else null;
}

pub fn parse(in_ptr: [*]const u8, in_len: usize, out_ptr: [*]u8, out_max: usize) callconv(.c) i32 {
    const input = std.mem.trim(u8, in_ptr[0..in_len], " \t\r\n");
    const src = if (input.len >= 2 and input[0] == '"' and input[input.len - 1] == '"') input[1 .. input.len - 1] else input;
    if (parseProcTexture(src)) |_| {
        const result = std.fmt.bufPrint(out_ptr[0..out_max], "texture:{s}", .{src}) catch return -1;
        return @intCast(result.len);
    }
    return -1;
}

const ParserHint = struct {
    line: u32,
    character: u32,
    text: []const u8,
    length: u32,
    offset: ?u32 = null,
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
    position: lsp.types.Position,
    label: []const u8,
    kind: u8 = 1,
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
    return .{ .line = line, .character = offset - line_start };
}

fn offsetOf(line: u32, character: u32, line_offsets: []const u32) u32 {
    const line_start: u32 = if (line == 0) 0 else line_offsets[line - 1] + 1;
    return line_start + character;
}

fn getHintsArr(obj: std.json.ObjectMap) ?[]std.json.Value {
    const v = obj.get("hints") orelse return null;
    return switch (v) {
        .array => |a| a.items,
        else => null,
    };
}

fn parseLineOffsets(a: std.mem.Allocator, lo_arr: []const std.json.Value) []u32 {
    const offsets = a.alloc(u32, lo_arr.len) catch return &.{};
    for (lo_arr, 0..) |v, i|
        offsets[i] = @intCast(switch (v) {
            .integer => |n| n,
            else => 0,
        });
    return offsets;
}

const HintCtx = struct {
    hint: ParserHint,
    src: []const u8,
    hp: HintPos,

    fn init(a: std.mem.Allocator, hint_val: std.json.Value) ?HintCtx {
        const parsed = std.json.parseFromValue(
            ParserHint,
            a,
            hint_val,
            .{ .ignore_unknown_fields = true },
        ) catch return null;
        const h = parsed.value;
        if (!std.mem.startsWith(u8, h.text, "texture:")) return null;
        const src = h.text["texture:".len..];
        return .{ .hint = h, .src = src, .hp = getHintPos(h, src) };
    }

    fn parse(self: HintCtx, a: std.mem.Allocator) ?DiagProcTexture {
        var tmp: std.ArrayListUnmanaged(lsp.types.Diagnostic) = .empty;
        return parseProcTextureWithDiags(a, self.src, &tmp, self.hint, self.hp);
    }

    fn parseDiag(
        self: HintCtx,
        a: std.mem.Allocator,
        diags: *std.ArrayListUnmanaged(lsp.types.Diagnostic),
    ) ?DiagProcTexture {
        return parseProcTextureWithDiags(a, self.src, diags, self.hint, self.hp);
    }
};

const SemanticToken = struct { line: u32, character: u32, length: u32, type: u32, modifier: u32 = 0 };

fn addToken(
    arena: std.mem.Allocator,
    tokens: *std.ArrayListUnmanaged(u32),
    tok: SemanticToken,
    prev_line: *u32,
    prev_char: *u32,
) !void {
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

pub fn textDocument_inlayHint(in_ptr: [*]const u8, in_len: usize, out_ptr: [*]u8, out_max: usize) callconv(.c) i32 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = std.json.parseFromSlice(std.json.Value, a, in_ptr[0..in_len], .{}) catch return -1;
    const obj = switch (root.value) {
        .object => |o| o,
        else => return -1,
    };
    const hints_arr = getHintsArr(obj) orelse return -1;

    const labels = [_][]const u8{ "format:", "width:", "height:", "mips:", "proc:" };
    var result: std.ArrayListUnmanaged(InlayHintOut) = .empty;

    for (hints_arr) |hint_val| {
        const ctx = HintCtx.init(a, hint_val) orelse continue;
        const dpt = ctx.parse(a) orelse continue;

        const offsets = [_]u32{ dpt.format_off, dpt.width_off, dpt.height_off, dpt.mips_off, dpt.proc_off };
        for (labels, offsets) |label, off|
            result.append(a, .{ .position = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + off }, .label = label }) catch continue;

        switch (dpt.texture.args) {
            .Irradiance, .WaterIrradiance => |diag| {
                result.append(a, .{ .position = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + diag.specularPower_off }, .label = "specularPower:" }) catch {};
            },
            .Color => |diag| {
                result.append(a, .{ .position = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + diag.r_off }, .label = "r:" }) catch {};
                result.append(a, .{ .position = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + diag.g_off }, .label = "g:" }) catch {};
                result.append(a, .{ .position = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + diag.b_off }, .label = "b:" }) catch {};
                result.append(a, .{ .position = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + diag.a_off }, .label = "a:" }) catch {};
                if (diag.args.map != null)
                    result.append(a, .{ .position = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + diag.map_off }, .label = "map:" }) catch {};
            },
            .Dither => |diag| {
                result.append(a, .{ .position = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + diag.min_off }, .label = "min:" }) catch {};
                result.append(a, .{ .position = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + diag.max_off }, .label = "max:" }) catch {};
            },
            .PerlinNoise => |diag| {
                result.append(a, .{ .position = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + diag.xScale_off }, .label = "xScale:" }) catch {};
                result.append(a, .{ .position = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + diag.yScale_off }, .label = "yScale:" }) catch {};
                result.append(a, .{ .position = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + diag.min_off }, .label = "min:" }) catch {};
                result.append(a, .{ .position = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + diag.max_off }, .label = "max:" }) catch {};
            },
            .TreeCrown, .TreeCrownAmb => |diag| {
                result.append(a, .{ .position = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + diag.density_off }, .label = "density:" }) catch {};
            },
            .Fresnel => |diag| {
                result.append(a, .{ .position = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + diag.refractiveIndex_off }, .label = "refractiveIndex:" }) catch {};
                result.append(a, .{ .position = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + diag.absorptionCoefficient_off }, .label = "absorptionCoefficient:" }) catch {};
            },
            .R2T => |diag| {
                result.append(a, .{ .position = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + diag.surface_off }, .label = "surface:" }) catch {};
                result.append(a, .{ .position = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + diag.aspect_off }, .label = "aspect:" }) catch {};
            },
            else => {},
        }
    }
    return jsonWrite(a, result.items, .{ .emit_null_optional_fields = false }, out_ptr, out_max);
}

pub fn textDocument_completion(in_ptr: [*]const u8, in_len: usize, out_ptr: [*]u8, out_max: usize) callconv(.c) i32 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = std.json.parseFromSlice(std.json.Value, a, in_ptr[0..in_len], .{}) catch return -1;
    const obj = switch (root.value) {
        .object => |o| o,
        else => return -1,
    };
    const params_obj = switch (obj.get("params") orelse return -1) {
        .object => |o| o,
        else => return -1,
    };
    const pos_obj = switch (params_obj.get("position") orelse return -1) {
        .object => |o| o,
        else => return -1,
    };
    const pos_line = @as(u32, @intCast(switch (pos_obj.get("line") orelse return -1) {
        .integer => |n| n,
        else => return -1,
    }));
    const pos_char = @as(u32, @intCast(switch (pos_obj.get("character") orelse return -1) {
        .integer => |n| n,
        else => return -1,
    }));

    const hints_arr = getHintsArr(obj) orelse return -1;
    const lo_arr = switch (obj.get("lineOffsets") orelse return -1) {
        .array => |a_| a_.items,
        else => return -1,
    };
    const line_offsets = parseLineOffsets(a, lo_arr);
    const cur_off = offsetOf(pos_line, pos_char, line_offsets);

    var items: std.ArrayListUnmanaged(lsp.types.completion.Item) = .empty;

    for (hints_arr) |hint_val| {
        const ctx = HintCtx.init(a, hint_val) orelse continue;
        const hint_offset = ctx.hint.offset orelse offsetOf(ctx.hint.line, ctx.hint.character, line_offsets);
        const base_off = hint_offset + (ctx.hp.base_char - ctx.hint.character);
        if (cur_off < base_off or cur_off > base_off + ctx.src.len) continue;

        const dpt_opt = ctx.parse(a);
        const rel_off = cur_off - base_off;

        const in_format: bool = if (dpt_opt) |dpt| blk: {
            const end = dpt.format_off + @as(u32, @intCast(
                std.mem.indexOfScalar(u8, ctx.src[dpt.format_off..], ',') orelse ctx.src.len - dpt.format_off,
            ));
            break :blk rel_off >= dpt.format_off and rel_off <= end;
        } else blk: {
            const before = ctx.src[0..@min(rel_off, ctx.src.len)];
            break :blk rel_off >= 2 and std.mem.indexOfScalar(u8, before, ',') == null;
        };
        if (in_format) {
            for ([_][]const u8{ "ai", "argb", "rgb", "a", "i" }) |f|
                items.append(a, .{ .label = f, .kind = .EnumMember, .detail = "texture format" }) catch continue;
        }

        const in_proc: bool = if (dpt_opt) |dpt| blk: {
            break :blk rel_off >= dpt.proc_off and
                rel_off <= dpt.proc_off + @as(u32, @intCast(dpt.procedure_name.len));
        } else blk: {
            const before = ctx.src[0..@min(rel_off, ctx.src.len)];
            break :blk std.mem.indexOfScalar(u8, before, ')') != null;
        };
        if (in_proc) {
            for ([_][]const u8{
                "irradiance",      "color",        "dither",    "perlinnoise",
                "waterirradiance", "fresnelglass", "treecrown", "treecrownamb",
                "point",           "fresnel",      "r2t",       "text",
                "ui",              "uiex",         "extension",
            }) |p|
                items.append(a, .{ .label = p, .kind = .Function, .detail = "procedural texture" }) catch continue;
        }
    }

    return jsonWrite(a, lsp.types.completion.Result{ .completion_items = items.items }, .{ .emit_null_optional_fields = false }, out_ptr, out_max);
}

pub fn textDocument_documentColor(in_ptr: [*]const u8, in_len: usize, out_ptr: [*]u8, out_max: usize) callconv(.c) i32 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = std.json.parseFromSlice(std.json.Value, a, in_ptr[0..in_len], .{}) catch return -1;
    const obj = switch (root.value) {
        .object => |o| o,
        else => return -1,
    };
    const hints_arr = getHintsArr(obj) orelse return -1;

    var colors: std.ArrayListUnmanaged(lsp.types.DocumentColor) = .empty;

    for (hints_arr) |hint_val| {
        const ctx = HintCtx.init(a, hint_val) orelse continue;
        const dpt = ctx.parse(a) orelse continue;
        if (dpt.texture.args != .Color) continue;
        const c = dpt.texture.args.Color.args;
        colors.append(a, .{
            .range = .{
                .start = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + dpt.args_off },
                .end = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + dpt.args_off + @as(u32, @intCast(dpt.args_text.len)) },
            },
            .color = .{ .red = c.r, .green = c.g, .blue = c.b, .alpha = c.a },
        }) catch continue;
    }
    return jsonWrite(a, colors.items, .{ .emit_null_optional_fields = false }, out_ptr, out_max);
}

const ColorPresentation = struct { label: []const u8, textEdit: ?TextEdit = null };
const TextEdit = struct { range: lsp.types.Range, newText: []const u8 };

pub fn textDocument_colorPresentation(in_ptr: [*]const u8, in_len: usize, out_ptr: [*]u8, out_max: usize) callconv(.c) i32 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = std.json.parseFromSlice(std.json.Value, a, in_ptr[0..in_len], .{}) catch return -1;
    const obj = switch (root.value) {
        .object => |o| o,
        else => return -1,
    };
    const params_obj = switch (obj.get("params") orelse return -1) {
        .object => |o| o,
        else => return -1,
    };
    const color = (std.json.parseFromValue(lsp.types.Color, a, params_obj.get("color") orelse return -1, .{}) catch return -1).value;
    const range = (std.json.parseFromValue(lsp.types.Range, a, params_obj.get("range") orelse return -1, .{}) catch return -1).value;
    const hints_arr = getHintsArr(obj) orelse return -1;

    var label_buf: [256]u8 = undefined;
    const label = a.dupe(u8, std.fmt.bufPrint(
        &label_buf,
        "{d:.4},{d:.4},{d:.4},{d:.4}",
        .{ color.red, color.green, color.blue, color.alpha },
    ) catch return -1) catch return -1;

    var presentations: std.ArrayListUnmanaged(ColorPresentation) = .empty;

    for (hints_arr) |hint_val| {
        const ctx = HintCtx.init(a, hint_val) orelse continue;
        if (ctx.hint.line != range.start.line) continue;
        const dpt = ctx.parse(a) orelse continue;
        if (dpt.texture.args != .Color) continue;
        const base_args_char = ctx.hp.base_char + dpt.args_off;
        if (base_args_char != range.start.character) continue;
        presentations.append(a, .{
            .label = label,
            .textEdit = .{
                .range = .{
                    .start = .{ .line = ctx.hint.line, .character = base_args_char },
                    .end = .{ .line = ctx.hint.line, .character = base_args_char + @as(u32, @intCast(dpt.args_text.len)) },
                },
                .newText = label,
            },
        }) catch continue;
    }

    if (presentations.items.len == 0)
        presentations.append(a, .{ .label = label }) catch return -1;

    return jsonWrite(a, presentations.items, .{ .emit_null_optional_fields = false }, out_ptr, out_max);
}

pub fn textDocument_diagnostic(in_ptr: [*]const u8, in_len: usize, out_ptr: [*]u8, out_max: usize) callconv(.c) i32 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = std.json.parseFromSlice(std.json.Value, a, in_ptr[0..in_len], .{}) catch {
        log("textDocument_diagnostic: JSON parse failed", .{});
        return -1;
    };
    const obj = switch (root.value) {
        .object => |o| o,
        else => {
            log("textDocument_diagnostic: root is not an object", .{});
            return -1;
        },
    };
    const hints_arr = getHintsArr(obj) orelse {
        log("textDocument_diagnostic: no 'hints' key in input", .{});
        return -1;
    };

    log("textDocument_diagnostic: processing {d} hints", .{hints_arr.len});

    var diags: std.ArrayListUnmanaged(lsp.types.Diagnostic) = .empty;

    for (hints_arr) |hint_val| {
        const ctx = HintCtx.init(a, hint_val) orelse continue;
        const dpt = ctx.parseDiag(a, &diags) orelse {
            if (diags.items.len == 0) diags.append(a, .{
                .range = .{ .start = .{ .line = ctx.hint.line, .character = ctx.hint.character }, .end = .{ .line = ctx.hint.line, .character = ctx.hint.character + ctx.hint.length } },
                .severity = .Error,
                .message = "Procedural texture syntax error. Expected: #(format,w,h,mips)proc(args)",
            }) catch {};
            continue;
        };
        const pt = dpt.texture;
        if (pt.width > 0 and pt.height > 0) {
            if (!isPowerOfTwo(pt.width)) diags.append(a, .{
                .range = .{ .start = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + dpt.width_off }, .end = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + dpt.width_off + @as(u32, @intCast(std.mem.indexOfScalar(u8, ctx.src[dpt.width_off..], ',') orelse 0)) } },
                .severity = .Error,
                .message = "Texture width must be a power of 2.",
            }) catch {};
            if (!isPowerOfTwo(pt.height)) diags.append(a, .{
                .range = .{ .start = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + dpt.height_off }, .end = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + dpt.height_off + @as(u32, @intCast(std.mem.indexOfScalar(u8, ctx.src[dpt.height_off..], ',') orelse 0)) } },
                .severity = .Error,
                .message = "Texture height must be a power of 2.",
            }) catch {};
            const max_dim = @max(pt.width, pt.height);
            if (pt.nMipmaps > 0 and (@as(u31, 1) << @intCast(pt.nMipmaps - 1)) > max_dim) diags.append(a, .{
                .range = .{ .start = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + dpt.mips_off }, .end = .{ .line = ctx.hint.line, .character = ctx.hp.base_char + dpt.mips_off + @as(u32, @intCast(std.mem.indexOfScalar(u8, ctx.src[dpt.mips_off..], ')') orelse 0)) } },
                .severity = .Error,
                .message = "Too many mipmaps for given dimensions.",
            }) catch {};
        }
    }

    log("textDocument_diagnostic: emitting {d} diagnostics", .{diags.items.len});
    return jsonWrite(a, diags.items, .{ .emit_null_optional_fields = false }, out_ptr, out_max);
}

pub fn textDocument_semanticTokens_full(in_ptr: [*]const u8, in_len: usize, out_ptr: [*]u8, out_max: usize) callconv(.c) i32 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = std.json.parseFromSlice(std.json.Value, a, in_ptr[0..in_len], .{}) catch return -1;
    const obj = switch (root.value) {
        .object => |o| o,
        else => return -1,
    };
    const hints_arr = getHintsArr(obj) orelse return -1;
    const lo_arr = switch (obj.get("lineOffsets") orelse return -1) {
        .array => |a_| a_.items,
        else => return -1,
    };
    const line_offsets = parseLineOffsets(a, lo_arr);

    var data: std.ArrayListUnmanaged(u32) = .empty;
    var prev_line: u32 = 0;
    var prev_char: u32 = 0;

    for (hints_arr) |hint_val| {
        const ctx = HintCtx.init(a, hint_val) orelse continue;
        const hint_offset = ctx.hint.offset orelse offsetOf(ctx.hint.line, ctx.hint.character, line_offsets);
        const base_off = hint_offset + (ctx.hp.base_char - ctx.hint.character);

        var lexer: Lexer = .{ .src = ctx.src };
        while (lexer.next()) |tok| {
            if (tok.type == .Whitespace) continue;
            const tt: u32 = switch (tok.type) {
                .Hash, .OpenParen, .CloseParen, .Comma => 4,

                .AI, .ARGB, .RGB, .A, .I, .Irradiance, .Color, .Dither, .PerlinNoise, .WaterIrradiance, .FresnelGlass, .TreeCrown, .TreeCrownAmb, .Point, .Fresnel, .R2T, .Text, .UI, .UIEx, .Extension => 0,

                .Co, .Ca, .No, .Ns, .Dt, .Mc, .Sm, .Smdi, .String => 3,

                .Chunk => blk: {
                    const is_num = tok.text.len > 0 and
                        (std.ascii.isDigit(tok.text[0]) or tok.text[0] == '-' or tok.text[0] == '.');
                    break :blk if (is_num) @as(u32, 5) else @as(u32, 3);
                },
                .Whitespace => unreachable,
            };
            const pos = resolvePos(base_off + tok.offset, line_offsets);
            addToken(a, &data, .{
                .line = pos.line,
                .character = pos.character,
                .length = @intCast(tok.text.len),
                .type = tt,
            }, &prev_line, &prev_char) catch continue;
        }
    }

    return jsonWrite(a, .{ .data = data.items }, .{}, out_ptr, out_max);
}


const is_root = @import("root") == @This();
comptime {
    if (is_root) {
        @export(&alloc, .{ .name = "alloc", .linkage = .strong });
        @export(&free, .{ .name = "free", .linkage = .strong });
        @export(&deinit, .{ .name = "deinit", .linkage = .strong });
        @export(&parse, .{ .name = "parse", .linkage = .strong });
        @export(&textDocument_inlayHint, .{ .name = "textDocument/inlayHint", .linkage = .strong });
        @export(&textDocument_completion, .{ .name = "textDocument/completion", .linkage = .strong });
        @export(&textDocument_documentColor, .{ .name = "textDocument/documentColor", .linkage = .strong });
        @export(&textDocument_colorPresentation, .{ .name = "textDocument/colorPresentation", .linkage = .strong });
        @export(&textDocument_diagnostic, .{ .name = "textDocument/diagnostic", .linkage = .strong });
        @export(&textDocument_semanticTokens_full, .{ .name = "textDocument/semanticTokens/full", .linkage = .strong });
    }
}
