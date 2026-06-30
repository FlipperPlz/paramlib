const std = @import("std");
const pp = @import("../common/preprocessor.zig");
const logger = @import("../common/log.zig");
const lines = @import("../common/lines.zig");
const lexer = @import("lexer.zig");

const PreProcessError = error {
    IncludeError,
    IncludeNotFound,
    IncludeMaxRecursion,
    InvalidIncludePath,
    IncompleteDirective,
    InvalidIdentifier,
    EndOfFile,
    ControlFlowElse,
    ControlFlowEndIf,
};

const CppPreLexer = struct {
    source:        [:0]const u8,
    index:         u32,
    pre_offset:    u32 = 0,
    mappings:      std.ArrayList(pp.SourceMapping),
    log:           *const logger.DiagType,
    filename:      []const u8,
    line_table:    ?*const lines.LineTable = null,

    const CF_WHITESPACE:          u8 = 1 << 0;
    const CF_IDENT_START:         u8 = 1 << 2;
    const CF_IDENT_CONTINUE:      u8 = 1 << 3;
    const CF_LINE_CONTINUE:       u8 = 1 << 5;

    const CHAR_TABLE: [256]u8 = blk: {
        var t = [_]u8{0} ** 256;

        var a: u8 = 0;
        while (a < 33) : (a += 1) {
            if(a == '\n') continue;
            t[a] |= CF_WHITESPACE;
        }

        t['\\'] |= CF_LINE_CONTINUE;
        t['/'] |= CF_LINE_CONTINUE;

        var d: u8 = '0';
        while (d <= '9') : (d += 1) t[d] |= CF_IDENT_START | CF_IDENT_CONTINUE;

        var c: u8 = 'a';
        while (c <= 'z') : (c += 1) t[c] |= CF_IDENT_START | CF_IDENT_CONTINUE;
        c = 'A';
        while (c <= 'Z') : (c += 1) t[c] |= CF_IDENT_START | CF_IDENT_CONTINUE;
        t['_'] |= CF_IDENT_START | CF_IDENT_CONTINUE;

        break :blk t;
    };

    pub inline fn isWhitespace(c: u8) bool            { return CHAR_TABLE[c] & CF_WHITESPACE != 0; }
    pub inline fn isIdentifierStart(c: u8) bool       { return (CHAR_TABLE[c] & (CF_IDENT_START | CF_IDENT_CONTINUE)) != 0; }
    pub inline fn isIdentifierContinue(c: u8) bool    { return CHAR_TABLE[c] & CF_IDENT_CONTINUE != 0; }
    pub inline fn isLineContinue(c: u8) bool          { return CHAR_TABLE[c] & CF_LINE_CONTINUE != 0; }

    const Token = struct {
        kind:   TokenKind,
        text:   []const u8,
        offset: u32,
        len:    u32,

        fn toLexerToken(self: Token) lexer.Token {
            return .{
                .kind = .invalid,
                .data = .{ .text = self.text },
                .pos = self.offset,
            };
        }
    };


    const TokenKind = enum {
        Define, Undef, Include, Line, IfDef, IfNDef, Else, EndIf,
        LeftParen, RightParen, Comma, Hash, NewLine, NewFile,
        BeginLineComment, BeginBlockComment, LineContinue,
        Quote, LeftAngle, RightAngle, DoubleHash, Text, Unknown,
    };

    const SYMBOLS = std.StaticStringMap(TokenKind).initComptime(.{
        .{ "define", .Define },
        .{ "undef", .Undef },
        .{ "include", .Include },
        .{ "line", .Line },
        .{ "ifdef", .IfDef },
        .{ "ifndef", .IfNDef },
        .{ "else", .Else },
        .{ "endif", .EndIf },
        .{ "(", .LeftParen },
        .{ ")", .RightParen },
        .{ ",", .Comma },
        .{ "#", .Hash },
        .{ "\n", .NewLine },
        .{ "//", .BeginLineComment },
        .{ "/*", .BeginBlockComment },
        .{ "\\\n", .LineContinue },
        .{ "\"", .Quote },
        .{ "<", .LeftAngle },
        .{ ">", .RightAngle },
        .{ "##", .DoubleHash },
    });

    fn init(source: [:0]const u8, log: *const logger.DiagType, filename: []const u8, line_table: ?*const lines.LineTable) CppPreLexer {
        return .{
            .source = source,
            .index = 0,
            .mappings = std.ArrayList(pp.SourceMapping).empty,
            .log = log,
            .filename = filename,
            .line_table = line_table,
        };
    }

    inline fn advance(self: *CppPreLexer) void {
        self.index += 1;
    }

    pub fn peek(self: *CppPreLexer) ?u8 {
        if (self.index >= self.source.len) return null;
        return self.source[self.index];
    }

    inline fn peekForward(self: *const CppPreLexer, offset: u32) u8 {
        const i = self.index + offset;
        if (i >= self.source.len) return 0;
        return self.source[i];
    }

    pub inline fn skipWhileInline(self: *CppPreLexer, comptime predicate: fn (u8) callconv(.@"inline") bool) void {
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (!predicate(c)) break;
            self.index += 1;
        }
    }

    pub inline fn skipLexedWhileInline(self: *CppPreLexer, allocator: std.mem.Allocator, comptime predicate: fn (u8) callconv(.@"inline") bool) void {
        while (true) {
            const c = self.peekLexed() orelse break;
            if (!predicate(c)) break;
            _ = self.nextLexed(allocator) catch break;
        }
    }

    inline fn isCarriageReturn(char: u8) bool {
        return char == '\r';
    }

    fn nextLexed(self: *CppPreLexer, allocator: std.mem.Allocator) !?u8 {
        var had_skip = false;
        while (true) {
            if (self.index >= self.source.len) return null;

            const c = self.source[self.index];
            if (c == '\r') {
                self.index += 1;
                had_skip = true;
                continue;
            }

            if (c == '\\') {
                var i: u32 = 1;
                while (self.peekForward(i) == '\r') : (i += 1) {}
                if (self.peekForward(i) == '\n') {
                    self.index += i + 1;
                    had_skip = true;
                    continue;
                } else {
                    const tok = lexer.Token{ .kind = .invalid, .data = .{ .none = {} }, .pos = self.index };
                    self.log.emit(.warning, "PPL01", &tok, "Backslash followed by non-newline is treated as literal backslash.", null);
                }
            }
            break;
        }

        if (self.index >= self.source.len) return null;

        const c = self.source[self.index];
        if (had_skip or self.mappings.items.len == 0 or
            self.index != self.mappings.items[self.mappings.items.len - 1].orig_offset + self.mappings.items[self.mappings.items.len - 1].length or
            self.pre_offset != self.mappings.items[self.mappings.items.len - 1].pre_offset + self.mappings.items[self.mappings.items.len - 1].length)
            {
                try self.mappings.append(allocator, .{
                    .pre_offset = self.pre_offset,
                    .orig_offset = self.index,
                    .length = 1,
                });
            } else {
            self.mappings.items[self.mappings.items.len - 1].length += 1;
        }

        self.index += 1;
        self.pre_offset += 1;
        return c;
    }

    test "CppPreLexer - nextLexed and mappings" {
        const allocator = std.testing.allocator;
        const log = logger.DiagType.none();
        const src = "a\\\n b\nc" ++ [_:0]u8{};
        var lexer_inst = CppPreLexer.init(src, &log, "", null);
        defer lexer_inst.mappings.deinit(allocator);

        var out = std.ArrayList(u8).empty;
        defer out.deinit(allocator);

        while (try lexer_inst.nextLexed(allocator)) |c| {
            try out.append(allocator, c);
        }

        try std.testing.expectEqualStrings("a b\nc", out.items);

        try std.testing.expectEqual(@as(usize, 2), lexer_inst.mappings.items.len);

        try std.testing.expectEqual(@as(u32, 0), lexer_inst.mappings.items[0].pre_offset);
        try std.testing.expectEqual(@as(u32, 0), lexer_inst.mappings.items[0].orig_offset);
        try std.testing.expectEqual(@as(u32, 1), lexer_inst.mappings.items[0].length);

        try std.testing.expectEqual(@as(u32, 1), lexer_inst.mappings.items[1].pre_offset);
        try std.testing.expectEqual(@as(u32, 3), lexer_inst.mappings.items[1].orig_offset);
        try std.testing.expectEqual(@as(u32, 4), lexer_inst.mappings.items[1].length);
    }

    fn peekLexed(self: *const CppPreLexer) ?u8 {
        var idx = self.index;
        while (true) {
            if (idx >= self.source.len) return null;
            const c = self.source[idx];
            if (c == '\r') {
                idx += 1;
                continue;
            }
            if (c == '\\') {
                var i: u32 = 1;
                while (idx + i < self.source.len and self.source[idx + i] == '\r') : (i += 1) {}
                if (idx + i < self.source.len and self.source[idx + i] == '\n') {
                    idx += i + 1;
                    continue;
                }
            }
            break;
        }
        if (idx >= self.source.len) return null;
        return self.source[idx];
    }

    fn scanName(self: *CppPreLexer, allocator: std.mem.Allocator) ![]const u8 {
        const first = self.peekLexed() orelse return error.EndOfFile;
        if (!isIdentifierStart(first)) return error.InvalidIdentifier;

        var name = std.ArrayList(u8).empty;
        errdefer name.deinit(allocator);

        while (name.items.len < 128) {
            const c = self.peekLexed() orelse break;
            if (!isIdentifierContinue(c)) break;
            _ = try self.nextLexed(allocator);
            try name.append(allocator, c);
        }

        return try name.toOwnedSlice(allocator);
    }

    test "CppPreLexer - scanName" {
        const allocator = std.testing.allocator;
        const log = logger.DiagType.none();

        {
            const src = "myVar123" ++ [_:0]u8{};
            var lexer_inst = CppPreLexer.init(src, &log, "", null);
            defer lexer_inst.mappings.deinit(allocator);
            const name = try lexer_inst.scanName(allocator);
            defer allocator.free(name);
            try std.testing.expectEqualStrings("myVar123", name);
            try std.testing.expectEqual(@as(u32, 8), lexer_inst.pre_offset);
        }

        {
            const src = "my\\\nVar" ++ [_:0]u8{};
            var lexer_inst = CppPreLexer.init(src, &log, "", null);
            defer lexer_inst.mappings.deinit(allocator);
            const name = try lexer_inst.scanName(allocator);
            defer allocator.free(name);
            try std.testing.expectEqualStrings("myVar", name);
            try std.testing.expectEqual(@as(u32, 5), lexer_inst.pre_offset);
            try std.testing.expectEqual(@as(usize, 2), lexer_inst.mappings.items.len);
        }

        {
            const src = "foo = 1;" ++ [_:0]u8{};
            var lexer_inst = CppPreLexer.init(src, &log, "", null);
            defer lexer_inst.mappings.deinit(allocator);
            const name = try lexer_inst.scanName(allocator);
            defer allocator.free(name);
            try std.testing.expectEqualStrings("foo", name);
            try std.testing.expectEqual(@as(u32, 3), lexer_inst.pre_offset);
            try std.testing.expectEqual(@as(u8, ' '), lexer_inst.peekLexed().?);
        }
    }

    fn scanString(self: *CppPreLexer, allocator: std.mem.Allocator, terminators: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        while (self.peekLexed()) |c| {
            if (std.mem.indexOfScalar(u8, terminators, c) != null) break;
            _ = try self.nextLexed(allocator);
            try result.append(allocator, c);
        }

        return try result.toOwnedSlice(allocator);
    }

    test "CppPreLexer - scanString" {
        const allocator = std.testing.allocator;
        const log = logger.DiagType.none();

        {
            const src = "hello world;next" ++ [_:0]u8{};
            var lexer_inst = CppPreLexer.init(src, &log, "", null);
            defer lexer_inst.mappings.deinit(allocator);
            const s = try lexer_inst.scanString(allocator, ";");
            defer allocator.free(s);
            try std.testing.expectEqualStrings("hello world", s);
            try std.testing.expectEqual(@as(u32, 11), lexer_inst.pre_offset);
            try std.testing.expectEqual(@as(u8, ';'), lexer_inst.peekLexed().?);
        }

        {
            const src = "line1\\\nline2\"rest" ++ [_:0]u8{};
            var lexer_inst = CppPreLexer.init(src, &log, "", null);
            defer lexer_inst.mappings.deinit(allocator);
            const s = try lexer_inst.scanString(allocator, "\"");
            defer allocator.free(s);
            try std.testing.expectEqualStrings("line1line2", s);
            try std.testing.expectEqual(@as(u32, 10), lexer_inst.pre_offset);
            try std.testing.expectEqual(@as(u8, '\"'), lexer_inst.peekLexed().?);
        }

        {
            const src = ";next" ++ [_:0]u8{};
            var lexer_inst = CppPreLexer.init(src, &log, "", null);
            defer lexer_inst.mappings.deinit(allocator);
            const s = try lexer_inst.scanString(allocator, ";");
            defer allocator.free(s);
            try std.testing.expectEqualStrings("", s);
            try std.testing.expectEqual(@as(u32, 0), lexer_inst.pre_offset);
        }

        {
            const src = "abc(def" ++ [_:0]u8{};
            var lexer_inst = CppPreLexer.init(src, &log, "", null);
            defer lexer_inst.mappings.deinit(allocator);
            const s = try lexer_inst.scanString(allocator, "()");
            defer allocator.free(s);
            try std.testing.expectEqualStrings("abc", s);
            try std.testing.expectEqual(@as(u8, '('), lexer_inst.peekLexed().?);
        }
    }

    test "CppPreLexer - findSymbol" {
        try std.testing.expectEqual(TokenKind.Define, findSymbol("define").?);
        try std.testing.expectEqual(TokenKind.Include, findSymbol("include").?);
        try std.testing.expectEqual(TokenKind.LeftParen, findSymbol("(").?);
        try std.testing.expectEqual(@as(?TokenKind, null), findSymbol("not_a_symbol"));
    }

    pub fn findSymbol(text: []const u8) ?TokenKind {
        return SYMBOLS.get(text);
    }

    pub fn lex(self: *CppPreLexer, allocator: std.mem.Allocator) ?Token{
        self.skipLexedWhileInline(allocator, isCarriageReturn);
        const start_pre = self.pre_offset;
        const next = self.peekLexed() orelse return null;

        if(isIdentifierStart(next)) {
            const text = self.scanName(allocator) catch return null;
            const symbol = findSymbol(text) orelse TokenKind.Text;
            return .{
                .kind = symbol,
                .text = text,
                .offset = start_pre,
                .len = self.pre_offset - start_pre,
            };
        }
        var buffer_len: usize = 0;
        var buffer: [3:0] u8 = [_:0]u8{ 0, 0, 0 };

        if(next == '/' or next == '\\') {
            buffer[0] = next;
            buffer_len = 1;
            _ = self.nextLexed(allocator) catch return null;
            self.skipLexedWhileInline(allocator, isCarriageReturn);
            const n = self.peekLexed() orelse {
                return .{
                    .kind = findSymbol(buffer[0..1]) orelse findCharSymbol(buffer[0]),
                    .text = allocator.dupe(u8, buffer[0..1]) catch return null,
                    .offset = start_pre,
                    .len = self.pre_offset - start_pre,
                };
            };
            if(n == '/' or n == '*') {
                buffer[1] = n;
                buffer_len = 2;
                _ = self.nextLexed(allocator) catch return null;
            }
        } else if (next == '#') {
            buffer[0] = '#';
            buffer_len = 1;
            _ = self.nextLexed(allocator) catch return null;
            if (self.peekLexed() == '#') {
                buffer[1] = '#';
                buffer_len = 2;
                _ = self.nextLexed(allocator) catch return null;
            }
        } else {
            buffer[0] = next;
            buffer_len = 1;
            _ = self.nextLexed(allocator) catch return null;
        }

        const text = buffer[0..buffer_len];
        return .{
            .kind = findSymbol(text) orelse findCharSymbol(text[0]),
            .text = allocator.dupe(u8, text) catch return null,
            .offset = start_pre,
            .len = self.pre_offset - start_pre,
        };
    }

    fn findCharSymbol(c: u8) TokenKind {
        return switch (c) {
            '\"' => .Quote,
            '<' => .LeftAngle,
            '>' => .RightAngle,
            '(' => .LeftParen,
            ')' => .RightParen,
            ',' => .Comma,
            '#' => .Hash,
            '\n' => .NewLine,
            else => .Unknown,
        };
    }

    pub fn peekToken(self: *CppPreLexer, allocator: std.mem.Allocator) ?Token {
        const saved_index = self.index;
        const saved_pre = self.pre_offset;
        const saved_mappings_len = self.mappings.items.len;
        const tok = self.lex(allocator);
        self.index = saved_index;
        self.pre_offset = saved_pre;
        self.mappings.items.len = saved_mappings_len;
        return tok;
    }

    pub fn peekTokenKind(self: *CppPreLexer, allocator: std.mem.Allocator) ?TokenKind {
        const saved_index = self.index;
        const saved_pre = self.pre_offset;
        const saved_mappings_len = self.mappings.items.len;

        const tok = self.lex(allocator) orelse return null;
        allocator.free(tok.text);

        self.index = saved_index;
        self.pre_offset = saved_pre;
        self.mappings.items.len = saved_mappings_len;
        return tok.kind;
    }

    pub fn skipToEndOfLine(self: *CppPreLexer, allocator: std.mem.Allocator) void {
        while (self.peekLexed()) |c| {
            if (c == '\n') break;
            _ = self.nextLexed(allocator) catch break;
        }
    }
    };


pub const IncludeError = enum {
    None,
    PathNotFound,
    ReadError,
};

pub const CppPreprocessor = struct {
    defines: std.StringHashMapUnmanaged(Macro),
    arg_scope: ?*ArgumentScope = null,
    processInclude: ?*const fn (path: []const u8, allocator: std.mem.Allocator, log: *const logger.DiagType, errored: *IncludeError) [:0]const u8 = null,
    conditionals: std.ArrayListUnmanaged(ConditionalState) = .empty,

    pub const ConditionalState = struct {
        condition_met: bool,
        active: bool,
        any_branch_met: bool,
    };

    fn shouldEmit(self: *const CppPreprocessor) bool {
        if (self.conditionals.items.len == 0) return true;
        return self.conditionals.items[self.conditionals.items.len - 1].active;
    }

    pub const Macro = struct {
        value: []const u8,
        params: []const []const u8 = &.{},
        has_params: bool = false,
        blocked_count: u32 = 0,

        pub fn isBlocked(self: Macro) bool {
            return self.blocked_count > 0;
        }

        pub fn block(self: *Macro) void {
            self.blocked_count += 1;
        }

        pub fn unblock(self: *Macro) void {
            if (self.blocked_count > 0) {
                self.blocked_count -= 1;
            }
        }
    };

    pub const ArgumentScope = struct {
        args: std.StringHashMap([]const u8),
        parent: ?*const ArgumentScope = null,

        pub fn init(allocator: std.mem.Allocator, parent: ?*const ArgumentScope) ArgumentScope {
            return .{
                .args = std.StringHashMap([]const u8).init(allocator),
                .parent = parent,
            };
        }

        pub fn deinit(self: *ArgumentScope) void {
            self.args.deinit();
        }

        pub fn get(self: ArgumentScope, name: []const u8) ?[]const u8 {
            if (self.args.get(name)) |val| return val;
            if (self.parent) |p| return p.get(name);
            return null;
        }
    };

    pub const empty: CppPreprocessor = .{
        .defines = std.StringHashMapUnmanaged(Macro).empty,
        .processInclude = null,
    };

    pub fn preprocess(self: *CppPreprocessor, allocator: std.mem.Allocator, source: [:0]const u8, log: *const logger.DiagType) anyerror!pp.PreprocessedResult {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);

        var final_mappings = std.ArrayList(pp.SourceMapping).empty;
        errdefer final_mappings.deinit(allocator);

        var line_overrides = std.ArrayList(pp.LineOverride).empty;
        errdefer {
            for (line_overrides.items) |lo| {
                if (lo.file_name) |fname| allocator.free(fname);
            }
            line_overrides.deinit(allocator);
        }

        try line_overrides.append(allocator, .{
            .pre_offset = 0,
            .line_number = 1,
            .file_name = if (log.filename.len > 0) try allocator.dupe(u8, log.filename) else null,
        });

        var lex = CppPreLexer.init(source, log, log.filename, log.lineTable());
        defer lex.mappings.deinit(allocator);

        try self.preprocessInternal(allocator, &lex, log, &out, &final_mappings, &line_overrides, false);

        try out.ensureTotalCapacityPrecise(allocator, out.items.len + 1);
        out.appendAssumeCapacity(0);
        const source_owned = try out.toOwnedSlice(allocator);

        return .{
            .source = source_owned[0 .. source_owned.len - 1 :0],
            .mappings = try final_mappings.toOwnedSlice(allocator),
            .line_overrides = try line_overrides.toOwnedSlice(allocator),
        };
    }

    fn preprocessInternal(self: *CppPreprocessor, allocator: std.mem.Allocator, lex: *CppPreLexer, log: *const logger.DiagType, out: *std.ArrayList(u8), final_mappings: *std.ArrayList(pp.SourceMapping), line_overrides: *std.ArrayList(pp.LineOverride), crashControlFlow: bool) anyerror!void {
        var quoted = false;
        var start_of_line = true;

        while(true) {
            const t = lex.lex(allocator) orelse break;
            defer allocator.free(t.text);

            if (start_of_line and t.kind == .Hash) {
                lex.skipWhileInline(CppPreLexer.isWhitespace);
                const dir_tok = lex.lex(allocator) orelse break;
                defer allocator.free(dir_tok.text);

                switch (dir_tok.kind) {
                    CppPreLexer.TokenKind.Include => if (self.shouldEmit()) self.handleInclude(allocator, lex, log, out, final_mappings, line_overrides) catch lex.skipToEndOfLine(allocator) else lex.skipToEndOfLine(allocator),
                    CppPreLexer.TokenKind.Define => if (self.shouldEmit()) self.handleDefine(allocator, lex, log) catch lex.skipToEndOfLine(allocator) else lex.skipToEndOfLine(allocator),
                    CppPreLexer.TokenKind.Undef => if (self.shouldEmit()) self.handleUndef(allocator, lex, log) catch lex.skipToEndOfLine(allocator) else lex.skipToEndOfLine(allocator),
                    CppPreLexer.TokenKind.Line => if (self.shouldEmit()) self.handleLine(allocator, lex, log, out, line_overrides) catch lex.skipToEndOfLine(allocator) else lex.skipToEndOfLine(allocator),
                    CppPreLexer.TokenKind.IfDef => self.handleIfDef(allocator, lex, log, false, out, final_mappings, line_overrides) catch lex.skipToEndOfLine(allocator),
                    CppPreLexer.TokenKind.IfNDef => self.handleIfDef(allocator, lex, log, true, out, final_mappings, line_overrides) catch lex.skipToEndOfLine(allocator),
                    CppPreLexer.TokenKind.Else  => {
                        if (!crashControlFlow) log.emit(.err, "PPP03", &dir_tok.toLexerToken(), "Missplaced controlflow.", null);
                        lex.skipToEndOfLine(allocator);
                        if(crashControlFlow) {
                            return error.ControlFlowElse;
                        }
                    },
                    CppPreLexer.TokenKind.EndIf => {
                        if (!crashControlFlow) log.emit(.err, "PPP03", &dir_tok.toLexerToken(), "Missplaced controlflow.", null);
                        lex.skipToEndOfLine(allocator);
                        if(crashControlFlow) {
                            return error.ControlFlowEndIf;
                        }
                    },
                    else => {
                        if (self.shouldEmit()) {
                            const lxt = dir_tok.toLexerToken();
                            log.emit(.err, "PPP01", &lxt, "Unexpected preprocessor directive.", null);
                        }
                        lex.skipToEndOfLine(allocator);
                    }
                }

                start_of_line = true;
                continue;
            }

            if (!self.shouldEmit()) {
                if (t.kind == CppPreLexer.TokenKind.NewLine) {
                    start_of_line = true;
                } else if (t.kind != .Unknown or (t.text.len > 0 and !CppPreLexer.isWhitespace(t.text[0]))) {
                    start_of_line = false;
                }
                continue;
            }

            if(t.kind == .Quote ) {
                quoted = !quoted;
                const out_start: u32 = @intCast(out.items.len);
                try out.append(allocator, '"');
                try commitMappings(final_mappings, lex.mappings.items, t.offset, 1, out_start, allocator);
                start_of_line = false;
            } else if(quoted) {
                const out_start: u32 = @intCast(out.items.len);
                try out.appendSlice(allocator, t.text);
                try commitMappings(final_mappings, lex.mappings.items, t.offset, t.len, out_start, allocator);
            } else if (t.kind == CppPreLexer.TokenKind.NewLine) {
                const out_start: u32 = @intCast(out.items.len);
                try out.append(allocator, '\n');
                try commitMappings(final_mappings, lex.mappings.items, t.offset, 1, out_start, allocator);
                start_of_line = true;
            } else if (t.kind == CppPreLexer.TokenKind.BeginLineComment) {
                try self.skipLineComment(allocator, lex);
                const out_start: u32 = @intCast(out.items.len);
                try out.append(allocator, '\n');
                try commitMappings(final_mappings, lex.mappings.items, lex.pre_offset - 1, 1, out_start, allocator);
                start_of_line = true;
            } else if (t.kind == CppPreLexer.TokenKind.BeginBlockComment) {
                _ = try self.skipBlockComment(allocator, lex, out, final_mappings);
            } else if (t.kind == CppPreLexer.TokenKind.Text) {
                if (std.mem.eql(u8, t.text, "__FILE__") or std.mem.eql(u8, t.text, "__LINE__")) {
                    const expanded = self.tryExpandMacro(allocator, t.text, log, lex, out, line_overrides).?;
                    defer allocator.free(expanded);
                    const out_start: u32 = @intCast(out.items.len);
                    try out.appendSlice(allocator, expanded);
                    try commitMacroMappings(final_mappings, lex.mappings.items, t.offset, t.len, @intCast(expanded.len), out_start, allocator);
                } else if (self.defines.getPtr(t.text)) |macro| {
                    if (macro.isBlocked()) {
                        const out_start: u32 = @intCast(out.items.len);
                        try out.appendSlice(allocator, t.text);
                        try commitMappings(final_mappings, lex.mappings.items, t.offset, t.len, out_start, allocator);
                    } else {
                        macro.block();
                        defer macro.unblock();

                        const expanded = self.tryExpandMacro(allocator, t.text, log, lex, out, line_overrides).?;
                        defer allocator.free(expanded);

                        var nested_lt = try lines.LineTable.build(allocator, expanded);
                        defer nested_lt.deinit(allocator);
                        var nested_lex = CppPreLexer.init(expanded, log, lex.filename, &nested_lt);
                        defer nested_lex.mappings.deinit(allocator);

                        const mappings_before = final_mappings.items.len;
                        try self.preprocessInternal(allocator, &nested_lex, log, out, final_mappings, line_overrides, false);
                        const mappings_after = final_mappings.items.len;

                        var orig_start: u32 = 0;
                        for (lex.mappings.items) |m| {
                            if (t.offset >= m.pre_offset and t.offset < m.pre_offset + m.length) {
                                orig_start = m.orig_offset + (t.offset - m.pre_offset);
                                break;
                            }
                        }

                        for (final_mappings.items[mappings_before..mappings_after]) |*m| {
                            m.orig_offset = orig_start;
                        }
                    }
                } else {
                    const out_start: u32 = @intCast(out.items.len);
                    try out.appendSlice(allocator, t.text);
                    try commitMappings(final_mappings, lex.mappings.items, t.offset, t.len, out_start, allocator);
                }
                start_of_line = false;
            } else {
                const out_start: u32 = @intCast(out.items.len);
                try out.appendSlice(allocator, t.text);
                try commitMappings(final_mappings, lex.mappings.items, t.offset, t.len, out_start, allocator);

                if (t.kind != .Unknown or (t.text.len > 0 and !CppPreLexer.isWhitespace(t.text[0]))) {
                    start_of_line = false;
                }
            }
        }
    }

    fn commitMacroMappings(
        final_mappings: *std.ArrayList(pp.SourceMapping),
        internal_mappings: []const pp.SourceMapping,
        token_offset: u32,
        token_len: u32,
        expansion_len: u32,
        out_offset: u32,
        allocator: std.mem.Allocator,
    ) !void {
        _ = token_len;
        if (expansion_len == 0) return;

        var orig_start: u32 = 0;
        var found = false;
        for (internal_mappings) |m| {
            if (token_offset >= m.pre_offset and token_offset < m.pre_offset + m.length) {
                orig_start = m.orig_offset + (token_offset - m.pre_offset);
                found = true;
                break;
            }
        }
        if (!found) return;

        try final_mappings.append(allocator, .{
            .pre_offset = out_offset,
            .orig_offset = orig_start,
            .length = expansion_len,
        });
    }

    fn commitMappings(
        final_mappings: *std.ArrayList(pp.SourceMapping),
        internal_mappings: []const pp.SourceMapping,
        start_internal: u32,
        len: u32,
        out_offset: u32,
        allocator: std.mem.Allocator,
    ) !void {
        if (len == 0) return;
        const end_internal = start_internal + len;

        for (internal_mappings) |m| {
            if (m.pre_offset + m.length <= start_internal) continue;
            if (m.pre_offset >= end_internal) break;

            const intersect_start = @max(m.pre_offset, start_internal);
            const intersect_end = @min(m.pre_offset + m.length, end_internal);
            const intersect_len = intersect_end - intersect_start;

            const mapped_pre = out_offset + (intersect_start - start_internal);
            const mapped_orig = m.orig_offset + (intersect_start - m.pre_offset);

            if (final_mappings.items.len > 0) {
                var last = &final_mappings.items[final_mappings.items.len - 1];
                if (last.pre_offset + last.length == mapped_pre and last.orig_offset + last.length == mapped_orig) {
                    last.length += intersect_len;
                    continue;
                }
            }
            try final_mappings.append(allocator, .{
                .pre_offset = mapped_pre,
                .orig_offset = mapped_orig,
                .length = intersect_len,
            });
        }
    }

    fn handleUndef(self: *CppPreprocessor, allocator: std.mem.Allocator, lex: *CppPreLexer, log: *const logger.DiagType) !void {
        lex.skipWhileInline(CppPreLexer.isWhitespace);
        const next_kind = lex.peekTokenKind(allocator) orelse {
            log.emit(.err, "PPP01", null, "Unexpected end of file in undef directive.", null);
            return PreProcessError.IncompleteDirective;
        };
        if (next_kind != .Text) {
            log.emit(.err, "PPP06", null, "Expected identifier after `#undef`.", null);
            return PreProcessError.IncompleteDirective;
        }

        const next = lex.lex(allocator).?;
        defer allocator.free(next.text);
        self.undef(allocator, next.text);
        lex.skipToEndOfLine(allocator);
    }

    fn handleDefine(self: *CppPreprocessor, allocator: std.mem.Allocator, lex: *CppPreLexer, log: *const logger.DiagType) !void {
        lex.skipWhileInline(CppPreLexer.isWhitespace);
        const next_kind = lex.peekTokenKind(allocator) orelse {
            log.emit(.err, "PPP01", null, "Unexpected end of file in define directive.", null);
            return PreProcessError.IncompleteDirective;
        };
        if (next_kind != .Text) {
            log.emit(.err, "PPP06", null, "Expected identifier after `#define`.", null);
            return PreProcessError.IncompleteDirective;
        }

        const next = lex.lex(allocator).?;
        defer allocator.free(next.text);
        const name = try allocator.dupe(u8, next.text);
        errdefer allocator.free(name);

        var def = Macro {
            .value = &.{},
            .params = &.{},
            .has_params = false,
            .blocked_count = 0,
        };
        errdefer {
            for (def.params) |p| allocator.free(p);
            allocator.free(def.params);
            allocator.free(def.value);
        }

        if(lex.peekLexed() == '(') {
            const lp = lex.lex(allocator).?;
            allocator.free(lp.text);

            def.has_params = true;
            def.params = self.readDefineParams(allocator, lex, log) catch {
                log.emit(.err, "PPP07", null, "Invalid macro parameters.", null);
                return PreProcessError.IncompleteDirective;
            };

            const rp = lex.lex(allocator) orelse {
                log.emit(.err, "PPP09", null, "Missing ending parenthesis.", null);
                return PreProcessError.IncompleteDirective;
            };
            defer allocator.free(rp.text);
            if(rp.kind != CppPreLexer.TokenKind.RightParen) {
                log.emit(.err, "PPP09", null, "Missing ending parenthesis.", null);
                return PreProcessError.IncompleteDirective;
            }
        } else def.has_params = false;

        lex.skipWhileInline(CppPreLexer.isWhitespace);

        def.value = self.readDefineText(allocator, lex) catch {
            log.emit(.err, "PPP10", null, "Invalid macro replacement list.", null);
            return PreProcessError.IncompleteDirective;
        };
        def.unblock();
        try self.defines.put(allocator, name, def);

        return;
    }

    fn readDefineText(self: *CppPreprocessor, allocator: std.mem.Allocator, lex: *CppPreLexer) ![]const u8 {
        var value = std.ArrayList(u8).empty;
        errdefer value.deinit(allocator);

        while (true) {
            if (lex.peekTokenKind(allocator)) |k| {
                if (k == .NewLine) break;
            } else break;

            const tok = lex.lex(allocator).?;
            defer allocator.free(tok.text);

            if (tok.kind == CppPreLexer.TokenKind.BeginLineComment) try self.skipLineComment(allocator, lex)
            else if (tok.kind == CppPreLexer.TokenKind.BeginBlockComment) _ = try self.skipBlockComment(allocator, lex, null, null)
            else try value.appendSlice(allocator, tok.text);
        }

        return value.toOwnedSlice(allocator);
    }

    fn readDefineParams(self: *CppPreprocessor, allocator: std.mem.Allocator, lex: *CppPreLexer, log: *const logger.DiagType) ![]const [] const u8 {
        _ = self;
        var params = std.ArrayList([]const u8).empty;
        errdefer {
            for (params.items) |p| allocator.free(p);
            params.deinit(allocator);
        }

        while (true) {
            lex.skipWhileInline(CppPreLexer.isWhitespace);
            const next_c = lex.peekLexed() orelse break;
            if (next_c == ')') break;

            const t = lex.lex(allocator) orelse break;
            defer allocator.free(t.text);

            if (t.kind == .Text) {
                try params.append(allocator, try allocator.dupe(u8, t.text));
            } else if (t.kind == .Comma) {
                continue;
            } else {
                const lxt = t.toLexerToken();
                log.emit(.err, "PPP07", &lxt, "Unexpected token in macro parameters.", null);
                return PreProcessError.IncompleteDirective;
            }
        }

        return try params.toOwnedSlice(allocator);
    }

    fn skipBlockComment(self: *CppPreprocessor, allocator: std.mem.Allocator, lex: *CppPreLexer, out: ?*std.ArrayList(u8), final_mappings: ?*std.ArrayList(pp.SourceMapping)) !i32 {
        _ = self;
        var line_count: i32 = 0;
        var last: u8 = 0;
        while (try lex.nextLexed(allocator)) |c| {
            if (last == '*' and c == '/') break;
            if (c == '\n') {
                line_count += 1;
                if (out) |o| {
                    const out_start: u32 = @intCast(o.items.len);
                    try o.append(allocator, '\n');
                    if (final_mappings) |fm| {
                        try commitMappings(fm, lex.mappings.items, lex.pre_offset - 1, 1, out_start, allocator);
                    }
                }
            }
            last = c;
        }
        return line_count;
    }

    fn skipLineComment(self: *CppPreprocessor, allocator: std.mem.Allocator, lex: *CppPreLexer) !void {
        _ = self;
        while (try lex.nextLexed(allocator)) |c| {
            if (c == '\n') break;
        }
    }

    fn getCurrentLogicalLine(self: *CppPreprocessor, overrides: []const pp.LineOverride, out: *std.ArrayList(u8), lex: *CppPreLexer) u32 {
        _ = self;
        var line: u32 = 1;
        var start_offset: u32 = 0;
        if (overrides.len > 0) {
            const ov = overrides[overrides.len - 1];
            line = ov.line_number;
            start_offset = ov.pre_offset;
        } else {
            if (lex.line_table) |lt| {
                return lt.resolve(lex.index).line;
            }
        }

        var line_delta: u32 = 0;
        var i: usize = start_offset;
        while (i < out.items.len) : (i += 1) {
            if (out.items[i] == '\n') line_delta += 1;
        }
        return line + line_delta;
    }

    fn getCurrentLogicalFile(self: *CppPreprocessor, overrides: []const pp.LineOverride, lex: *CppPreLexer) []const u8 {
        _ = self;
        var i: usize = overrides.len;
        while (i > 0) {
            i -= 1;
            if (overrides[i].file_name) |fname| return fname;
        }
        return lex.filename;
    }

    fn tryExpandMacro(self: *CppPreprocessor, allocator: std.mem.Allocator, name: []const u8, log: *const logger.DiagType, lex: *CppPreLexer, out: *std.ArrayList(u8), line_overrides: *std.ArrayList(pp.LineOverride)) ?[:0]const u8 {
        _ = log;
        if (std.mem.eql(u8, name, "__FILE__")) {
            const current_file = self.getCurrentLogicalFile(line_overrides.items, lex);

            var escaped = std.ArrayList(u8).empty;
            defer escaped.deinit(allocator);
            escaped.append(allocator, '"') catch return null;
            for (current_file) |c| {
                if (c == '\\' or c == '"') {
                    escaped.append(allocator, '\\') catch return null;
                }
                escaped.append(allocator, c) catch return null;
            }
            escaped.append(allocator, '"') catch return null;
            return escaped.toOwnedSliceSentinel(allocator, 0) catch null;
        }

        if (std.mem.eql(u8, name, "__LINE__")) {
            const line = self.getCurrentLogicalLine(line_overrides.items, out, lex);
            const s = std.fmt.allocPrint(allocator, "{d}", .{line}) catch return null;
            defer allocator.free(s);
            return allocator.dupeZ(u8, s) catch null;
        }

        if (self.defines.get(name)) |macro| {
            if (!macro.has_params) {
                return allocator.dupeZ(u8, macro.value) catch null;
            }
        }
        return null;
    }


    fn handleInclude(self: *CppPreprocessor, allocator: std.mem.Allocator, lex: *CppPreLexer, log: *const logger.DiagType, out: *std.ArrayList(u8), final_mappings: *std.ArrayList(pp.SourceMapping), line_overrides: *std.ArrayList(pp.LineOverride)) !void {
        lex.skipWhileInline(CppPreLexer.isWhitespace);
        const next_c = lex.peekLexed() orelse {
            log.emit(.err, "PPP01", null, "Unexpected end of file in include directive.", null);
            return PreProcessError.InvalidIncludePath;
        };
        if (next_c == '\n') {
            log.emit(.err, "PPP02", null, "Missing include path.", null);
            return PreProcessError.InvalidIncludePath;
        }
        const path: []const u8 = pth: {
            if (next_c == '"') {
                _ = try lex.nextLexed(allocator);
                const s = try lex.scanString(allocator, "\"");
                if (lex.peekLexed() == '"') _ = try lex.nextLexed(allocator);
                break :pth s;
            } else if (next_c == '<') {
                _ = try lex.nextLexed(allocator);
                const s = try lex.scanString(allocator, ">");
                if (lex.peekLexed() == '>') _ = try lex.nextLexed(allocator);
                break :pth s;
            } else {
                log.emit(.err, "PPP02", null, "Invalid include path, use `<>` or `\"\"`", null);
                return PreProcessError.InvalidIncludePath;
            }
        };
        defer allocator.free(path);

        var err: IncludeError = .None;
        if(self.processInclude) |preproc| {
            const content = preproc(path, allocator, log, &err);
            defer allocator.free(content);

            if(err == .PathNotFound) {
                log.emit(.err, "PPP03", null, "Failed to include file. Not found", null);
            return PreProcessError.IncludeNotFound;
            } else if (err == .ReadError) {
                log.emit(.err, "PPP04", null, "Failed to read included file.", null);
                return PreProcessError.IncludeError;
            } else if (err != .None) {
                log.emit(.err, "PPP05", null, "Unknown/undocumented error while including file.", null);
                return PreProcessError.IncludeError;
            }

            const parent_logical_line = self.getCurrentLogicalLine(line_overrides.items, out, lex);
            const parent_logical_file = self.getCurrentLogicalFile(line_overrides.items, lex);

            try line_overrides.append(allocator, .{
                .pre_offset = @intCast(out.items.len),
                .line_number = 1,
                .file_name = try allocator.dupe(u8, path),
            });

            const nested_lt = try lines.LineTable.build(allocator, content);
            defer nested_lt.deinit(allocator);

            var nested_lex = CppPreLexer.init(content, log, path, &nested_lt);
            defer nested_lex.mappings.deinit(allocator);

            try self.preprocessInternal(allocator, &nested_lex, log, out, final_mappings, line_overrides, false);

            try line_overrides.append(allocator, .{
                .pre_offset = @intCast(out.items.len),
                .line_number = parent_logical_line,
                .file_name = if (parent_logical_file.len > 0) try allocator.dupe(u8, parent_logical_file) else null,
            });

            lex.skipToEndOfLine(allocator);
            return;
        }
        log.emit(.err, "PPP06", null, "Process include not available ", null);
        return PreProcessError.IncludeError;
    }

    fn handleLine(self: *CppPreprocessor, allocator: std.mem.Allocator, lex: *CppPreLexer, log: *const logger.DiagType, out: *std.ArrayList(u8), line_overrides: *std.ArrayList(pp.LineOverride)) !void {
        _ = self;
        lex.skipWhileInline(CppPreLexer.isWhitespace);

        const line_tok = lex.lex(allocator) orelse {
            log.emit(.err, "PPP11", null, "Unexpected end of file in line directive.", null);
            return PreProcessError.IncompleteDirective;
        };
        defer allocator.free(line_tok.text);

        if (line_tok.kind != .Text) {
             log.emit(.err, "PPP11", null, "Expected line number in #line directive.", null);
             return PreProcessError.IncompleteDirective;
        }

        const line_num = std.fmt.parseInt(u32, line_tok.text, 10) catch {
            log.emit(.err, "PPP11", null, "Invalid line number in #line directive.", null);
            return PreProcessError.IncompleteDirective;
        };

        lex.skipWhileInline(CppPreLexer.isWhitespace);

        var filename: ?[]const u8 = null;
        if (lex.peekLexed() == '"') {
            _ = try lex.nextLexed(allocator);
            filename = try lex.scanString(allocator, "\"");
            if (lex.peekLexed() == '"') {
                _ = try lex.nextLexed(allocator);
            }
        }

        lex.skipToEndOfLine(allocator);

        try line_overrides.append(allocator, .{
            .pre_offset = @intCast(out.items.len),
            .line_number = if (line_num > 0) line_num - 1 else 0,
            .file_name = filename,
        });
    }

    fn handleIfDef(self: *CppPreprocessor, allocator: std.mem.Allocator, lex: *CppPreLexer, log: *const logger.DiagType, is_ifndef: bool, out: *std.ArrayList(u8), final_mappings: *std.ArrayList(pp.SourceMapping), line_overrides: *std.ArrayList(pp.LineOverride)) !void {
        lex.skipWhileInline(CppPreLexer.isWhitespace);
        const name_tok = lex.lex(allocator) orelse {
            log.emit(.err, "PPP12", null, "Unexpected end of file in #ifdef directive.", null);
            return PreProcessError.IncompleteDirective;
        };
        defer allocator.free(name_tok.text);

        if (name_tok.kind != .Text) {
            log.emit(.err, "PPP13", null, "Expected identifier in #ifdef directive.", null);
            return PreProcessError.IncompleteDirective;
        }

        const parent_active = self.shouldEmit();
        const condition_met = self.defines.contains(name_tok.text) != is_ifndef;

        const idx = self.conditionals.items.len;
        try self.conditionals.append(allocator, .{
            .condition_met = condition_met,
            .active = parent_active and condition_met,
            .any_branch_met = condition_met,
        });
        defer {
            _ = self.conditionals.pop();
        }

        lex.skipToEndOfLine(allocator);

        var result = self.preprocessInternal(allocator, lex, log, out, final_mappings, line_overrides, true);

        if (result == error.ControlFlowElse) {
            self.conditionals.items[idx].active = parent_active and !self.conditionals.items[idx].any_branch_met;
            self.conditionals.items[idx].any_branch_met = true;

            result = self.preprocessInternal(allocator, lex, log, out, final_mappings, line_overrides, true);
        }

        if (result == error.ControlFlowEndIf) {
            return;
        } else if (result == error.ControlFlowElse) {
            log.emit(.err, "PPP03", null, "Duplicate #else directive.", null);
            return;
        } else {
            return result;
        }
    }

    pub fn undef(self: *CppPreprocessor, allocator: std.mem.Allocator, name: []const u8) void {
        if (self.defines.fetchRemove(name)) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value.value);
            for (entry.value.params) |param| {
                allocator.free(param);
            }
            allocator.free(entry.value.params);
        }
    }

    pub fn deinit(self: *CppPreprocessor, allocator: std.mem.Allocator) void {
        self.conditionals.deinit(allocator);
        var it = self.defines.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.value);
            for (entry.value_ptr.params) |param| {
                allocator.free(param);
            }
            allocator.free(entry.value_ptr.params);
        }
        self.defines.deinit(allocator);
    }

    pub fn define(self: *CppPreprocessor, allocator: std.mem.Allocator, name: []const u8, value: []const u8, params: []const []const u8, has_params: bool) !void {
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        const value_copy = try allocator.dupe(u8, value);
        errdefer allocator.free(value_copy);

        const params_copy = try allocator.alloc([]const u8, params.len);
        errdefer allocator.free(params_copy);

        var i: usize = 0;
        errdefer {
            for (0..i) |j| allocator.free(params_copy[j]);
        }
        while (i < params.len) : (i += 1) {
            params_copy[i] = try allocator.dupe(u8, params[i]);
        }

        const res = try self.defines.getOrPut(allocator, name_copy);
        if (res.found_existing) {
            allocator.free(name_copy);
            allocator.free(res.value_ptr.value);
            for (res.value_ptr.params) |param| {
                allocator.free(param);
            }
            allocator.free(res.value_ptr.params);
        }

        res.value_ptr.* = .{
            .value = value_copy,
            .params = params_copy,
            .has_params = has_params,
        };
    }

    pub fn preprocessor(self: *CppPreprocessor) pp.Preprocessor {
        return .{
            .ptr = self,
            .vtable = &.{
                .preprocess = preprocessWrapper,
                .deinit = deinitWrapper,
            },
        };
    }

    fn deinitWrapper(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *CppPreprocessor = @ptrCast(@alignCast(ptr));
        deinit(self, allocator);
    }

    fn preprocessWrapper(ptr: *anyopaque, allocator: std.mem.Allocator, source: [:0]const u8, log: *logger.DiagType) anyerror!pp.PreprocessedResult {
        const self: *CppPreprocessor = @ptrCast(@alignCast(ptr));
        return self.preprocess(allocator, source, log);
    }
};

test "CppPreprocessor - comprehensive" {
    const allocator = std.testing.allocator;
    const log = logger.DiagType.none();
    var cpp = CppPreprocessor.empty;
    defer cpp.deinit(allocator);

    try cpp.define(allocator, "FOO", "42", &.{}, false);
    try std.testing.expect(cpp.defines.contains("FOO"));
    cpp.undef(allocator, "FOO");
    try std.testing.expect(!cpp.defines.contains("FOO"));

    try cpp.define(allocator, "BAR", "100", &.{}, false);
    const src1 = "x = BAR;" ++ [_:0]u8{};
    const res1 = try cpp.preprocess(allocator, src1, &log);
    defer res1.deinit(allocator);
    try std.testing.expectEqualStrings("x = 100;", res1.source);
    try std.testing.expectEqual(@as(u32, 4), res1.resolveOffset(4));
    try std.testing.expectEqual(@as(u32, 5), res1.resolveOffset(5));
    try std.testing.expectEqual(@as(u32, 6), res1.resolveOffset(6));

    const src2 = "#define BAZ 200\ny = BAZ;\n#undef BAZ\nz = BAZ;" ++ [_:0]u8{};
    const res2 = try cpp.preprocess(allocator, src2, &log);
    defer res2.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, res2.source, "y = 200;") != null);
    try std.testing.expect(std.mem.indexOf(u8, res2.source, "z = BAZ;") != null);

    const src3 = "val = \\\n123;" ++ [_:0]u8{};
    const res3 = try cpp.preprocess(allocator, src3, &log);
    defer res3.deinit(allocator);

    try std.testing.expectEqualStrings("val = 123;", res3.source);
    try std.testing.expectEqual(@as(u32, 8), res3.resolveOffset(6));

    const src4 = "a = /* comment */ b;" ++ [_:0]u8{};
    const res4 = try cpp.preprocess(allocator, src4, &log);
    defer res4.deinit(allocator);
    try std.testing.expectEqualStrings("a =  b;", res4.source);
    try std.testing.expectEqual(@as(u32, 18), res4.resolveOffset(5));
}

fn z(comptime s: []const u8) [:0]const u8 {
    return s ++ [_:0]u8{};
}

test "CppPreprocessor - conditional compilation" {
    const allocator = std.testing.allocator;
    const log = logger.DiagType.none();
    var cpp = CppPreprocessor.empty;
    defer cpp.deinit(allocator);

    const src = z(
        \\#define YES
        \\#ifdef YES
        \\    keep = 1;
        \\#else
        \\    drop = 1;
        \\#endif
        \\#ifndef YES
        \\    drop2 = 1;
        \\#else
        \\    keep2 = 1;
        \\#endif
    );

    const res = try cpp.preprocess(allocator, src, &log);
    defer res.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, res.source, "keep = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.source, "drop = 1;") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.source, "keep2 = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.source, "drop2 = 1;") == null);
}


test "CppPreprocessor - recovery from invalid directive" {
    const allocator = std.testing.allocator;
    const log = logger.DiagType.none();
    var cpp = CppPreprocessor.empty;
    defer cpp.deinit(allocator);

    const src = 
        \\#invalid directive with args
        \\#define FOO 42
        \\result = FOO;
    ++ [_:0]u8{};

    const res = try cpp.preprocess(allocator, src, &log);
    defer res.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, res.source, "result = 42;") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.source, "invalid") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.source, "directive") == null);
}

test "CppPreprocessor - recovery from invalid define" {
    const allocator = std.testing.allocator;
    const log = logger.DiagType.none();
    var cpp = CppPreprocessor.empty;
    defer cpp.deinit(allocator);

    const src = 
        \\#define 
        \\#define FOO 42
        \\result = FOO;
    ++ [_:0]u8{};

    const res = try cpp.preprocess(allocator, src, &log);
    defer res.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, res.source, "result = 42;") != null);
}

test "CppPreprocessor - recovery from invalid undef" {
    const allocator = std.testing.allocator;
    const log = logger.DiagType.none();
    var cpp = CppPreprocessor.empty;
    defer cpp.deinit(allocator);

    const src = 
        \\#define FOO 42
        \\#undef 
        \\result = FOO;
    ++ [_:0]u8{};

    const res = try cpp.preprocess(allocator, src, &log);
    defer res.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, res.source, "result = 42;") != null);
}

test "CppPreprocessor - recovery from invalid include" {
    const allocator = std.testing.allocator;
    const log = logger.DiagType.none();
    
    const Mock = struct {
        pub fn processInclude(_: []const u8, _: std.mem.Allocator, _: *const logger.DiagType, errored: *IncludeError) [:0]const u8 {
            errored.* = .PathNotFound;
            return std.testing.allocator.dupeZ(u8, "") catch unreachable;
        }
    };

    var cpp = CppPreprocessor.empty;
    cpp.processInclude = Mock.processInclude;
    defer cpp.deinit(allocator);

    const src = 
        \\#include <missing_file.h>
        \\#define BAR 100
        \\val = BAR;
    ++ [_:0]u8{};

    const res = try cpp.preprocess(allocator, src, &log);
    defer res.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, res.source, "val = 100;") != null);
}

test "CppPreprocessor - include" {
    const allocator = std.testing.allocator;
    const log = logger.DiagType.none();
    
    const Mock = struct {
        pub fn processInclude(path: []const u8, _: std.mem.Allocator, _: *const logger.DiagType, _: *IncludeError) [:0]const u8 {
            if (std.mem.eql(u8, path, "test.h")) {
                return std.testing.allocator.dupeZ(u8, "included = 1;") catch unreachable;
            }
            unreachable;
        }
    };

    var cpp = CppPreprocessor.empty;
    cpp.processInclude = Mock.processInclude;
    defer cpp.deinit(allocator);

    const src = "start = 0;\n#include \"test.h\"\nend = 1;" ++ [_:0]u8{};
    const res = try cpp.preprocess(allocator, src, &log);
    defer res.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, res.source, "included = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.source, "start = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.source, "end = 1;") != null);
}

test "CppPreprocessor - line directive logical mapping" {
    const allocator = std.testing.allocator;
    const log = logger.DiagType.none();
    var cpp = CppPreprocessor.empty;
    defer cpp.deinit(allocator);

    const src = 
        \\#line 100 "virtual.h"
        \\int x = 42;
    ++ [_:0]u8{};

    const res = try cpp.preprocess(allocator, src, &log);
    defer res.deinit(allocator);

    const x_pos = std.mem.indexOf(u8, res.source, "int x").?;
    
    const lt = try lines.LineTable.build(allocator, src);
    defer lt.deinit(allocator);

    const loc = res.resolveLocation(@intCast(x_pos), "original.cpp", &lt);
    
    try std.testing.expectEqualStrings("virtual.h", loc.file_name);
    try std.testing.expectEqual(@as(u32, 100), loc.line);
}
const MockIo = struct {
    output: std.ArrayList(u8),
    
    fn write(ptr: *anyopaque, buf: []const u8) anyerror!usize {
        const self: *MockIo = @ptrCast(@alignCast(ptr));
        self.output.appendSlice(buf) catch return error.SystemResources;
        return buf.len;
    }
    
    fn read(_: *anyopaque, _: []u8) anyerror!usize { return 0; }
    fn flush(_: *anyopaque) anyerror!void {}
    
    fn io(self: *MockIo) std.Io {
        return .{
            .ptr = self,
            .read_fn = read,
            .write_fn = write,
            .flush_fn = flush,
        };
    }
};

test "CppPreprocessor - include updates line overrides" {
    const allocator = std.testing.allocator;
    const log_none = logger.DiagType.none();
    
    const Mock = struct {
        pub fn processInclude(path: []const u8, alloc: std.mem.Allocator, _: *const logger.DiagType, err: *IncludeError) [:0]const u8 {
            if (std.mem.eql(u8, path, "inc.h")) {
                return alloc.dupeZ(u8, "included_val = 1;") catch unreachable;
            }
            err.* = .PathNotFound;
            return alloc.dupeZ(u8, "") catch unreachable;
        }
    };

    var cpp = CppPreprocessor.empty;
    cpp.processInclude = Mock.processInclude;
    defer cpp.deinit(allocator);

    const src = 
        \\#include "inc.h"
        \\root_val = 2;
    ++ [_:0]u8{};

    const res = try cpp.preprocess(allocator, src, &log_none);
    defer res.deinit(allocator);

    const inc_pos = std.mem.indexOf(u8, res.source, "included_val").?;
    const root_pos = std.mem.indexOf(u8, res.source, "root_val").?;
    
    const lt = try lines.LineTable.build(allocator, src);
    defer lt.deinit(allocator);

    const inc_loc = res.resolveLocation(@intCast(inc_pos), "original.cpp", &lt);
    const root_loc = res.resolveLocation(@intCast(root_pos), "original.cpp", &lt);
    
    try std.testing.expectEqualStrings("inc.h", inc_loc.file_name);
    try std.testing.expectEqual(@as(u32, 1), inc_loc.line);
    
    try std.testing.expectEqualStrings("original.cpp", root_loc.file_name);
    try std.testing.expectEqual(@as(u32, 2), root_loc.line);
}

test "CppPreprocessor - __LINE__ after include with #line override" {
    const allocator = std.testing.allocator;
    const log_none = logger.DiagType.none();
    
    const Mock = struct {
        pub fn processInclude(path: []const u8, alloc: std.mem.Allocator, _: *const logger.DiagType, err: *IncludeError) [:0]const u8 {
            if (std.mem.eql(u8, path, "inc.h")) {
                return alloc.dupeZ(u8, "/* nothing */") catch unreachable;
            }
            err.* = .PathNotFound;
            return alloc.dupeZ(u8, "") catch unreachable;
        }
    };

    var cpp = CppPreprocessor.empty;
    cpp.processInclude = Mock.processInclude;
    defer cpp.deinit(allocator);

    const src = 
        \\#line 100 "virtual.h"
        \\#include "inc.h"
        \\line = __LINE__;
    ++ [_:0]u8{};

    const res = try cpp.preprocess(allocator, src, &log_none);
    defer res.deinit(allocator);
    
    try std.testing.expect(std.mem.indexOf(u8, res.source, "line = 101;") != null);
}

test "CppPreprocessor - __FILE__ with backslashes" {
    const allocator = std.testing.allocator;
    var log = logger.DiagType.none();
    log.filename = "C:\\path\\to\\file.cpp";
    var cpp = CppPreprocessor.empty;
    defer cpp.deinit(allocator);

    const src = "file = __FILE__;" ++ [_:0]u8{};
    const res = try cpp.preprocess(allocator, src, &log);
    defer res.deinit(allocator);

    try std.testing.expectEqualStrings("file = \"C:\\\\path\\\\to\\\\file.cpp\";", res.source);
}

test "CppPreprocessor - __FILE__ and __LINE__" {
    const allocator = std.testing.allocator;
    const log = logger.DiagType.none();
    var cpp = CppPreprocessor.empty;
    defer cpp.deinit(allocator);

    const src = 
        \\#define FOO __FILE__
        \\#define BAR __LINE__
        \\file = FOO;
        \\line = BAR;
        \\#line 100 "new_file.h"
        \\new_file = __FILE__;
        \\new_line = __LINE__;
    ++ [_:0]u8{};

    const res = try cpp.preprocess(allocator, src, &log);
    defer res.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, res.source, "file = \"\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.source, "line = 4;") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.source, "new_file = \"new_file.h\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.source, "new_line = 101;") != null);
}
