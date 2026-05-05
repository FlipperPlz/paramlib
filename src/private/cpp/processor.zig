const std = @import("std");
const pp = @import("../common/preprocessor.zig");
const logger = @import("../common/log.zig");
const cpp_token = @import("lexer.zig").Token;

const PreProcessError = error {
    IncludeError,
    IncludeNotFound,
};

const CppPreLexer = struct {
    source:        [:0]const u8,
    index:         u32,
    pre_offset:    u32 = 0,
    mappings:      std.ArrayList(pp.SourceMapping),
    log:           *const logger.DiagType,
    newline:       bool = true,

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
        while (d <= '9') : (d += 1) t[d] |= CF_IDENT_CONTINUE;

        var c: u8 = 'a';
        while (c <= 'z') : (c += 1) t[c] |= CF_IDENT_START | CF_IDENT_CONTINUE;
        c = 'A';
        while (c <= 'Z') : (c += 1) t[c] |= CF_IDENT_START | CF_IDENT_CONTINUE;
        t['_'] |= CF_IDENT_START | CF_IDENT_CONTINUE;

        break :blk t;
    };

    pub inline fn isWhitespace(c: u8) bool            { return CHAR_TABLE[c] & CF_WHITESPACE != 0; }
    pub inline fn isIdentifierStart(c: u8) bool       { return CHAR_TABLE[c] & CF_IDENT_START != 0; }
    pub inline fn isIdentifierContinue(c: u8) bool    { return CHAR_TABLE[c] & CF_IDENT_CONTINUE != 0; }
    pub inline fn isLineContinue(c: u8) bool          { return CHAR_TABLE[c] & CF_LINE_CONTINUE != 0; }

    const Token = struct {
        kind:   TokenKind,
        text:   []const u8,
        offset: usize,
        len:    usize,
    };


    const TokenKind = enum {
        Define, Undef, Include, IfDef, IfNDef, Else, EndIf,
        LeftParen, RightParen, Comma, Hash, NewLine, NewFile,
        BeginLineComment, BeginBlockComment, LineContinue,
        Quote, LeftAngle, RightAngle, DoubleHash, Text, Unknown,
    };

    const SYMBOLS = std.StaticStringMap(TokenKind).initComptime(.{
        .{ "define", .Define },
        .{ "undef", .Undef },
        .{ "include", .Include },
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

    fn init(source: [:0]const u8, log: *const logger.DiagType) CppPreLexer {
        return .{
            .source = source,
            .index = 0,
            .mappings = std.ArrayList(pp.SourceMapping).empty,
            .log = log,
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
        while (predicate(self.source[self.index])) {
            self.index += 1;
        }
    }

    pub inline fn skipLexedWhileInline(self: *CppPreLexer, allocator: std.mem.Allocator, pre_offset: u32, comptime predicate: fn (u8) callconv(.@"inline") bool) void {
        while (predicate(peekLexed(*CppPreLexer, pre_offset))) {
            _ = try self.nextLexed(allocator, pre_offset);
        }
    }

    inline fn isCarriageReturn(char: u8) bool {
        return char == '\r';
    }

    fn nextLexed(self: *CppPreLexer, allocator: std.mem.Allocator, pre_offset: u32) !?u8 {
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
                    const tok = cpp_token{ .kind = .invalid, .data = .{ .none = {} }, .pos = self.index };
                    self.log.emit(.warning, "PPL01", &tok, "Backslash followed by non-newline is treated as literal backslash.", null);
                }
            }
            break;
        }

        if (self.index >= self.source.len) return null;

        const c = self.source[self.index];
        if (had_skip or self.mappings.items.len == 0 or
            self.index != self.mappings.items[self.mappings.items.len - 1].orig_offset + self.mappings.items[self.mappings.items.len - 1].length)
            {
                try self.mappings.append(allocator, .{
                    .pre_offset = pre_offset,
                    .orig_offset = self.index,
                    .length = 1,
                });
            } else {
            self.mappings.items[self.mappings.items.len - 1].length += 1;
        }

        self.index += 1;
        return c;
    }

    test "CppPreLexer - nextLexed and mappings" {
        const allocator = std.testing.allocator;
        const log = logger.DiagType.none();
        const src = "a\\\n b\nc" ++ [_:0]u8{};
        var lexer_inst = CppPreLexer.init(src, &log);
        defer lexer_inst.mappings.deinit(allocator);

        var out = std.ArrayList(u8).empty;
        defer out.deinit(allocator);

        while (try lexer_inst.nextLexed(allocator, @intCast(out.items.len))) |c| {
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

    fn scanName(self: *CppPreLexer, allocator: std.mem.Allocator, pre_offset_ptr: *u32) ![]const u8 {
        const first = self.peekLexed() orelse return error.EndOfFile;
        if (!isIdentifierStart(first)) return error.InvalidIdentifier;

        var name = std.ArrayList(u8).empty;
        errdefer name.deinit(allocator);

        while (name.items.len < 128) {
            const c = self.peekLexed() orelse break;
            if (!isIdentifierContinue(c)) break;
            _ = try self.nextLexed(allocator, pre_offset_ptr.*);
            pre_offset_ptr.* += 1;
            try name.append(allocator, c);
        }

        return try name.toOwnedSlice(allocator);
    }

    test "CppPreLexer - scanName" {
        const allocator = std.testing.allocator;
        const log = logger.DiagType.none();

        {
            const src = "myVar123" ++ [_:0]u8{};
            var lexer_inst = CppPreLexer.init(src, &log);
            defer lexer_inst.mappings.deinit(allocator);
            var pre_offset: u32 = 0;
            const name = try lexer_inst.scanName(allocator, &pre_offset);
            defer allocator.free(name);
            try std.testing.expectEqualStrings("myVar123", name);
            try std.testing.expectEqual(@as(u32, 8), pre_offset);
        }

        {
            const src = "my\\\nVar" ++ [_:0]u8{};
            var lexer_inst = CppPreLexer.init(src, &log);
            defer lexer_inst.mappings.deinit(allocator);
            var pre_offset: u32 = 0;
            const name = try lexer_inst.scanName(allocator, &pre_offset);
            defer allocator.free(name);
            try std.testing.expectEqualStrings("myVar", name);
            try std.testing.expectEqual(@as(u32, 5), pre_offset);
            try std.testing.expectEqual(@as(usize, 2), lexer_inst.mappings.items.len);
        }

        {
            const src = "foo = 1;" ++ [_:0]u8{};
            var lexer_inst = CppPreLexer.init(src, &log);
            defer lexer_inst.mappings.deinit(allocator);
            var pre_offset: u32 = 0;
            const name = try lexer_inst.scanName(allocator, &pre_offset);
            defer allocator.free(name);
            try std.testing.expectEqualStrings("foo", name);
            try std.testing.expectEqual(@as(u32, 3), pre_offset);
            try std.testing.expectEqual(@as(u8, ' '), lexer_inst.peekLexed().?);
        }
    }

    fn scanString(self: *CppPreLexer, allocator: std.mem.Allocator, terminators: []const u8, pre_offset_ptr: *u32) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        while (self.peekLexed()) |c| {
            if (std.mem.indexOfScalar(u8, terminators, c) != null) break;
            _ = try self.nextLexed(allocator, pre_offset_ptr.*);
            pre_offset_ptr.* += 1;
            try result.append(allocator, c);
        }

        return try result.toOwnedSlice(allocator);
    }

    test "CppPreLexer - scanString" {
        const allocator = std.testing.allocator;
        const log = logger.DiagType.none();

        {
            const src = "hello world;next" ++ [_:0]u8{};
            var lexer_inst = CppPreLexer.init(src, &log);
            defer lexer_inst.mappings.deinit(allocator);
            var pre_offset: u32 = 0;
            const s = try lexer_inst.scanString(allocator, ";", &pre_offset);
            defer allocator.free(s);
            try std.testing.expectEqualStrings("hello world", s);
            try std.testing.expectEqual(@as(u32, 11), pre_offset);
            try std.testing.expectEqual(@as(u8, ';'), lexer_inst.peekLexed().?);
        }

        {
            const src = "line1\\\nline2\"rest" ++ [_:0]u8{};
            var lexer_inst = CppPreLexer.init(src, &log);
            defer lexer_inst.mappings.deinit(allocator);
            var pre_offset: u32 = 0;
            const s = try lexer_inst.scanString(allocator, "\"", &pre_offset);
            defer allocator.free(s);
            try std.testing.expectEqualStrings("line1line2", s);
            try std.testing.expectEqual(@as(u32, 10), pre_offset);
            try std.testing.expectEqual(@as(u8, '\"'), lexer_inst.peekLexed().?);
        }

        {
            const src = ";next" ++ [_:0]u8{};
            var lexer_inst = CppPreLexer.init(src, &log);
            defer lexer_inst.mappings.deinit(allocator);
            var pre_offset: u32 = 0;
            const s = try lexer_inst.scanString(allocator, ";", &pre_offset);
            defer allocator.free(s);
            try std.testing.expectEqualStrings("", s);
            try std.testing.expectEqual(@as(u32, 0), pre_offset);
        }

        {
            const src = "abc(def" ++ [_:0]u8{};
            var lexer_inst = CppPreLexer.init(src, &log);
            defer lexer_inst.mappings.deinit(allocator);
            var pre_offset: u32 = 0;
            const s = try lexer_inst.scanString(allocator, "()", &pre_offset);
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
        for (SYMBOLS) |entry| {
            if(std.mem.eql(u8, entry.key, text)) {
                return entry.value;
            }
        }
        return null;
    }

    pub fn lex(self: *CppPreLexer, allocator: std.mem.Allocator) ?Token{
        const start_pre = self.pre_offset;
        self.skipLexedWhileInline(allocator, &self.pre_offset, isCarriageReturn);
        const next = self.peekLexed() orelse return null;

        if(isIdentifierStart(next)) {
            const text = self.scanName(allocator, &self.pre_offset);
            const symbol = findSymbol(text) orelse TokenKind.Text;
            if(symbol != .Text) return .{
                .kind = symbol,
                .data = text,
                .offset = start_pre,
                .len = self.pre_offset - start_pre,
            };

            return .{
                .kind = .Text,
                .data = text,
                .offset = start_pre,
                .len = self.pre_offset - start_pre,
            };
        }
        const buffer: [3:0] u8 = [_:0]u8{ next, 0, 0 };

        if(next == '/' or next == '\\') {
            _ = self.nextLexed(allocator, &self.pre_offset);
            self.skipLexedWhileInline(allocator, self.pre_offset, isCarriageReturn);
            const n = self.peekLexed() orelse return null;
            if(isIdentifierStart(n)) {
                buffer[1] = n;
                _ = self.nextLexed(allocator, &self.pre_offset);
            }
        } else if (next == '#') {
            _ = self.nextLexed(allocator, &self.pre_offset);
            if (self.peekLexed() == '#') {
                buffer[1] = '#';
            }
        }
        return .{
            .kind =  findSymbol(buffer) orelse TokenKind.Unknown,
            .data = allocator.dupe(u8, buffer) ,
            .offset = start_pre,
            .len = self.pre_offset - start_pre,
        };
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
    recursion_depth: u32 = 0,
    max_recursion: u32 = 100,
    processInclude: ?fn (path: []const u8, log: *const logger.DiagType, errored: *IncludeError) []const u8,

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
    };

    fn preprocess(self: *CppPreprocessor, allocator: std.mem.Allocator, source: [:0]const u8, log: *const logger.DiagType) anyerror!pp.PreprocessedResult {
        const lex = CppPreLexer.init(source, log);
        const out = std.ArrayList(u8).empty;

        var quoted = false;
        var t = lex.lex(allocator);
        while(t) |token| : (t = lex.lex(allocator)) {

            if(token.kind == .Quote ) {
                quoted = !quoted;
                lex.prevTokenKind = .Quote;
                try out.append(allocator, '"');
            } else if(quoted) {
                try out.appendSlice(allocator, token.data.text);
            } else if (token.kind == CppPreLexer.TokenKind.NewLine or token.kind == CppPreLexer.TokenKind.NewFile) {
                if(token.kind == CppPreLexer.TokenKind.NewLine) try out.append(allocator, '\n');
                lex.skipWhileInline(CppPreLexer.isWhitespace);

                t = lex.lex(allocator) orelse break;
                if(t.?.kind == .Hash) {
                    t = lex.lex(allocator) orelse break;
                    lex.skipWhileInline(CppPreLexer.isWhitespace);
                    switch (t.?.kind) {
                        CppPreLexer.TokenKind.Include => try handleInclude(self, allocator, &lex, log),
                        CppPreLexer.TokenKind.Define => {

                        },
                        CppPreLexer.TokenKind.IfDef => {

                        },
                        CppPreLexer.TokenKind.IfNDef => {

                        },
                        CppPreLexer.TokenKind.EndIf => {

                        },
                        CppPreLexer.TokenKind.Else => {

                        },
                        CppPreLexer.TokenKind.Undef => {

                        },
                        else => {
                            log.emit(.err, "PPP01", &token, "Unexpected preprocessor directive.", null);
                        }
                    }
                }
            }
        }
    }


    fn handleInclude(self: *CppPreprocessor, allocator: std.mem.Allocator, lex: *CppPreLexer, log: *const logger.DiagType) !void {
        if (self.recursion_depth >= self.max_recursion) {
            return PreProcessError.IncludeMaxRecursion;
        }

        const next = lex.peekLexed() orelse {
            log.emit(.err, "PPP01", null, "Unexpected end of file in include directive.", null);
            return PreProcessError.InvalidIncludePath;
        };
        const path: []const u8 = pth: {
            if (next == '"') {
                _ = lex.nextLexed(allocator, &lex.pre_offset);
                break :pth try lex.scanString(allocator, "\"", &lex.pre_offset);
            } else if (next == '<') {
                _ = lex.nextLexed(allocator, &lex.pre_offset);
                break :pth try lex.scanString(allocator, ">", &lex.pre_offset);
            } else {
                log.emit(.err, "PPP02", null, "Invalid include path, use `<>` or `\"\"`", null);
                //todo recover by skipping to end of line
                return PreProcessError.InvalidIncludePath;
            }
        };

        var err: IncludeError = .None;
        const content = self.processInclude(path, log, &err);
        defer allocator.free(content);

        if(err == .PathNotFound) {
            log.emit(.err, "PPP03", null, "Failed to include file. Not found", null);
            //todo recover by skipping to end of line
            return PreProcessError.IncludeNotFound;
        } else if (err == .ReadError) {
            //todo recover by skipping to end of line
            log.emit(.err, "PPP04", null, "Failed to read included file.", null);
            return PreProcessError.IncludeError;
        } else if (err != .None) {
            //todo recover by skipping to end of line
            log.emit(.err, "PPP05", null, "Unknown/undocumented error while including file.", null);
            return;
        }
        return self.preprocess(allocator,  log);
    }

    pub fn deinit(self: *CppPreprocessor, allocator: std.mem.Allocator) void {
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

test "Macro setup" {
    const allocator = std.testing.allocator;
    var cpp = CppPreprocessor.empty;
    defer cpp.deinit(allocator);

    try cpp.define(allocator, "FOO", "BAR", &.{}, false);
    const foo = cpp.defines.get("FOO").?;
    try std.testing.expectEqualStrings("BAR", foo.value);
    try std.testing.expect(!foo.has_params);

    const bar_params = [_][]const u8{ "a", "b" };
    try cpp.define(allocator, "BAR", "a + b", &bar_params, true);
    
    const bar = cpp.defines.get("BAR").?;
    try std.testing.expect(bar.has_params);
    try std.testing.expectEqual(@as(usize, 2), bar.params.len);
    try std.testing.expectEqualStrings("a", bar.params[0]);
    try std.testing.expectEqualStrings("b", bar.params[1]);
}
