const std = @import("std");
const source = @import("../slabs/source.zig");

const CF_WHITESPACE:          u8 = 1 << 0;
const CF_STRING_WHITESPACE:   u8 = 1 << 1;
const CF_IDENT_START:         u8 = 1 << 2;
const CF_IDENT_CONTINUE:      u8 = 1 << 3;
const CF_UNQUOTED_TERMINATOR: u8 = 1 << 4;
const CF_DIGIT:               u8 = 1 << 5;
const CF_SPACE:               u8 = 1 << 6;
const CF_NEWLINE:             u8 = 1 << 7;

const CHAR_TABLE: [256]u8 = blk: {
    var t = [_]u8{0} ** 256;

    t[' ']  |= CF_WHITESPACE | CF_STRING_WHITESPACE | CF_SPACE;
    t['\t'] |= CF_WHITESPACE | CF_STRING_WHITESPACE;
    t['\r'] |= CF_WHITESPACE | CF_STRING_WHITESPACE | CF_UNQUOTED_TERMINATOR;
    t['\n'] |= CF_WHITESPACE | CF_UNQUOTED_TERMINATOR | CF_NEWLINE;
    t[';']  |= CF_UNQUOTED_TERMINATOR;
    t['}']  |= CF_UNQUOTED_TERMINATOR;
    t[',']  |= CF_UNQUOTED_TERMINATOR;

    var d: u8 = '0';
    while (d <= '9') : (d += 1) t[d] |= CF_DIGIT | CF_IDENT_CONTINUE;

    var c: u8 = 'a';
    while (c <= 'z') : (c += 1) t[c] |= CF_IDENT_START | CF_IDENT_CONTINUE;
    c = 'A';
    while (c <= 'Z') : (c += 1) t[c] |= CF_IDENT_START | CF_IDENT_CONTINUE;
    t['_'] |= CF_IDENT_START | CF_IDENT_CONTINUE;

    break :blk t;
};

inline fn isSpace(c: u8) bool                 { return CHAR_TABLE[c] & CF_SPACE != 0; }
inline fn isWhitespace(c: u8) bool            { return CHAR_TABLE[c] & CF_WHITESPACE != 0; }
inline fn isNotNewLine(c: u8) bool            { return CHAR_TABLE[c] & CF_NEWLINE == 0; }
inline fn isStringWhitespace(c: u8) bool      { return CHAR_TABLE[c] & CF_STRING_WHITESPACE != 0; }
inline fn isNotUnquotedTerminator(c: u8) bool { return CHAR_TABLE[c] & CF_UNQUOTED_TERMINATOR == 0; }
inline fn isIdentifierStart(c: u8) bool       { return CHAR_TABLE[c] & CF_IDENT_START != 0; }
inline fn isIdentifierContinue(c: u8) bool    { return CHAR_TABLE[c] & CF_IDENT_CONTINUE != 0; }
inline fn isDigit(c: u8) bool                 { return CHAR_TABLE[c] & CF_DIGIT != 0; }

const KEYWORDS = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "class",  .classKeyword  },
    .{ "delete", .deleteKeyword },
    .{ "enum",   .enumKeyword   },
    .{ "__EXEC", .execKeyword   },
    .{ "__EVAL", .evalKeyword   },
});

const StringResult = struct {
    text:          []const u8,
    needsUnescape: bool,
};

pub const LineTable = struct {
    newline_offsets: []const u32,

    pub fn build(allocator: std.mem.Allocator, src: []const u8) !LineTable {
        var count: usize = 0;
        for (src) |c| if (c == '\n') { count += 1; };

        const offsets = try allocator.alloc(u32, count);
        var i: usize = 0;
        var pos: usize = 0;
        while (std.mem.indexOfScalarPos(u8, src, pos, '\n')) |idx| {
            offsets[i] = @intCast(idx);
            i += 1;
            pos = idx + 1;
        }
        return .{ .newline_offsets = offsets };
    }

    pub fn deinit(self: LineTable, allocator: std.mem.Allocator) void {
        allocator.free(self.newline_offsets);
    }

    pub const ResolvedPosition = struct {
        line:   u32,
        column: u32,
    };


    pub fn resolve(self: *const LineTable, offset: u32) ResolvedPosition {
        var lo: usize = 0;
        var hi: usize = self.newline_offsets.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.newline_offsets[mid] < offset) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        const line: u32 = @intCast(lo + 1);
        const line_start: u32 = if (lo == 0) 0 else self.newline_offsets[lo - 1] + 1;
        return .{
            .line   = line,
            .column = offset - line_start + 1,
        };
    }

    test "bench - LineTable.build" {
        const allocator = std.testing.allocator;

        var bigSrcBuf: [4096]u8 = undefined;
        var idx: usize = 0;
        var line: usize = 0;
        while (idx < bigSrcBuf.len - 1) {
            const ch: u8 = if (line % 40 == 39) '\n' else 'x';
            bigSrcBuf[idx] = ch;
            idx += 1;
            if (ch == '\n') line += 1;
        }
        bigSrcBuf[idx] = 0;
        const src = bigSrcBuf[0..idx];

        const iters: u64 = 1_000;
        const start = std.Io.Timestamp.now(std.testing.io, .real).nanoseconds;
        var i: u64 = 0;
        while (i < iters) : (i += 1) {
            const lt = try LineTable.build(allocator, src);
            lt.deinit(allocator);
        }
        const elapsedNs: u64 = @intCast(std.Io.Timestamp.now(std.testing.io, .real).nanoseconds - start);
        const nsPerIter = elapsedNs / iters;

        std.debug.print(
            "\n[bench] LineTable.build: {} ns/iter ({} bytes source)\n",
            .{ nsPerIter, src.len },
        );
    }

    test "bench - LineTable.resolve" {
        const allocator = std.testing.allocator;
        const src = "line1\nline2\nline3\nline4\nline5\n";
        const lt = try LineTable.build(allocator, src);
        defer lt.deinit(allocator);

        const iters: u64 = 1_000_000;
        const start = std.Io.Timestamp.now(std.testing.io, .real).nanoseconds;
        var i: u64 = 0;
        var sink: u32 = 0;
        while (i < iters) : (i += 1) {
            const r = lt.resolve(@intCast(i % src.len));
            sink +%= r.line;
        }
        const elapsedNs: u64 = @intCast(std.Io.Timestamp.now(std.testing.io, .real).nanoseconds - start);
        const nsPerCall = elapsedNs / iters;

        std.debug.print(
            "\n[bench] LineTable.resolve: {} ns/call (sink={})\n",
            .{ nsPerCall, sink },
        );
    }

    pub fn toSourcePosition(self: *const LineTable, offset: u32) source.SourcePosition {
        const r = self.resolve(offset);
        return .{
            .index  = offset,
            .line   = r.line,
            .column = r.column,
        };
    }
};

test "LineTable - empty source" {
    const allocator = std.testing.allocator;
    const lt = try LineTable.build(allocator, "");
    defer lt.deinit(allocator);
    const r = lt.resolve(0);
    try std.testing.expectEqual(@as(u32, 1), r.line);
    try std.testing.expectEqual(@as(u32, 1), r.column);
}

test "LineTable - newline character itself" {
    const allocator = std.testing.allocator;
    const src = "ab\ncd";
    const lt = try LineTable.build(allocator, src);
    defer lt.deinit(allocator);

    const r2 = lt.resolve(2);
    try std.testing.expectEqual(@as(u32, 1), r2.line);

    const r3 = lt.resolve(3);
    try std.testing.expectEqual(@as(u32, 2), r3.line);
    try std.testing.expectEqual(@as(u32, 1), r3.column);
}

test "LineTable - single line, no newlines" {
    const allocator = std.testing.allocator;
    const src = "hello world";
    const lt = try LineTable.build(allocator, src);
    defer lt.deinit(allocator);

    const r = lt.resolve(6);
    try std.testing.expectEqual(@as(u32, 1), r.line);
    try std.testing.expectEqual(@as(u32, 7), r.column);
}

test "LineTable - multiple lines" {
    const allocator = std.testing.allocator;
    const src = "line1\nline2\nline3";
    const lt = try LineTable.build(allocator, src);
    defer lt.deinit(allocator);

    const r = lt.resolve(6);
    try std.testing.expectEqual(@as(u32, 2), r.line);
    try std.testing.expectEqual(@as(u32, 1), r.column);
}

pub const TokenKind = enum {
    intLiteral,
    int64Literal,
    floatLiteral,
    stringLiteral,
    expression,
    identifier,

    classKeyword,
    deleteKeyword,
    enumKeyword,
    execKeyword,
    evalKeyword,

    leftBrace,
    rightBrace,
    leftBracket,
    rightBracket,
    leftParenthesis,
    rightParenthesis,
    equals,
    addAssign,
    subAssign,
    semicolon,
    comma,
    colon,

    eof,
    invalid,
    comment,
};

pub const TokenData = union(enum) {
    none:  void,
    int:   i32,
    int64: i64,
    float: f32,
    text:  []const u8,
    string: StringResult,
    hash:  u64,
};

pub const Token = struct {
    kind: TokenKind,
    data: TokenData,
    pos:  u32,

    pub fn isKeyword(self: Token) bool {
        return switch (self.kind) {
            .classKeyword,
            .deleteKeyword,
            .enumKeyword,
            .evalKeyword,
            .execKeyword => true,
            else => false,
        };
    }

    test "Token.isKeyword" {
        var buf: [4]Token = undefined;
        _ = try Tokenizer.tokenizeAll("class\x00", &buf);
        try std.testing.expect(buf[0].isKeyword());

        _ = try Tokenizer.tokenizeAll("myVar\x00", &buf);
        try std.testing.expect(!buf[0].isKeyword());
    }

    pub fn text(self: Token) []const u8 {
        return switch (self.data) {
            .text => |t| t,
            else  => "",
        };
    }

    test "Token.text - non-text token returns empty string" {
        var buf: [4]Token = undefined;
        _ = try Tokenizer.tokenizeAll("42\x00", &buf);
        try std.testing.expectEqualStrings("", buf[0].text());
    }
};

pub const TokenizerError = error{
    UnterminatedString,
    InvalidEscape,
    UnterminatedComment,
    Overflow,
};

pub const Tokenizer = struct {
    source:       [:0]const u8,
    index:        u32,
    after_equals: bool,

    pub fn init(src: [:0]const u8) Tokenizer {
        return .{ .source = src, .index = 0, .after_equals = false };
    }

    inline fn peek(self: *const Tokenizer) u8 {
        return self.source[self.index];
    }

    inline fn peekForward(self: *const Tokenizer, offset: u32) u8 {
        const i = self.index + offset;
        if (i >= self.source.len) return 0;
        return self.source[i];
    }

    inline fn advance(self: *Tokenizer) void {
        self.index += 1;
    }

    pub inline fn skipWhileInline(self: *Tokenizer, comptime predicate: fn (u8) callconv(.@"inline") bool) void {
        while (true) {
            const c = self.peek();
            if (c == 0 or !predicate(c)) break;
            self.index += 1;
        }
    }

    pub inline fn skipWhile(self: *Tokenizer, comptime predicate: fn (u8) bool) void {
        while (true) {
            const c = self.peek();
            if (c == 0 or !predicate(c)) break;
            self.index += 1;
        }
    }

    test "token positions are byte offsets" {
        var buf: [8]Token = undefined;
        _ = try tokenizeAll("ab = 1\x00", &buf);
        try std.testing.expectEqual(@as(u32, 0), buf[0].pos);
        try std.testing.expectEqual(@as(u32, 3), buf[1].pos);
        try std.testing.expectEqual(@as(u32, 5), buf[2].pos);
    }

    //   unescape-string   ::= { unescape-char }
    //   unescape-char     ::= '""'
    pub fn unescapeString(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
        var out = try std.ArrayList(u8).initCapacity(allocator, raw.len);
        errdefer out.deinit(allocator);

        var i: usize = 0;
        while (i < raw.len) {
            if (i + 1 < raw.len and raw[i] == '"' and raw[i + 1] == '"') {
                try out.append(allocator, '"');
                i += 2;
                continue;
            }
            if (raw[i] == '"') {
                var j = i + 1;
                while (j < raw.len and (raw[j] == ' ' or raw[j] == '\t')) j += 1;
                if (j < raw.len and raw[j] == '\n') {
                    j += 1;
                    while (j < raw.len and (raw[j] == ' ' or raw[j] == '\t')) j += 1;
                    if (j < raw.len and raw[j] == '"') {
                        i = j + 1;
                        continue;
                    }
                }
                try out.append(allocator, '"');
                i += 1;
                continue;
            }
            try out.append(allocator, raw[i]);
            i += 1;
        }
        return out.toOwnedSlice(allocator);
    }

    test "bench - unescapeString" {
        const allocator = std.testing.allocator;
        const raw = "hello \"\"world\"\", this \"\"is\"\" a test string";

        const iters: u64 = 50_000;
        const start = std.Io.Timestamp.now(std.testing.io, .real).nanoseconds;
        var i: u64 = 0;
        while (i < iters) : (i += 1) {
            const out = try unescapeString(allocator, raw);
            allocator.free(out);
        }
        const elapsed_ns: u64 = @intCast(std.Io.Timestamp.now(std.testing.io, .real).nanoseconds - start);
        const nsPerIter = elapsed_ns / iters;

        std.debug.print(
            "\n[bench] unescapeString: {} ns/iter ({} bytes input)\n",
            .{ nsPerIter, raw.len },
        );
    }

    test "unescapeString - no escapes" {
        const allocator = std.testing.allocator;
        const result = try unescapeString(allocator, "hello");
        defer allocator.free(result);
        try std.testing.expectEqualStrings("hello", result);
    }

    test "unescapeString - single escaped quote" {
        const allocator = std.testing.allocator;
        const result = try unescapeString(allocator, "say \"\"hi\"\"");
        defer allocator.free(result);
        try std.testing.expectEqualStrings("say \"hi\"", result);
    }

    test "unescapeString - only escaped quotes" {
        const allocator = std.testing.allocator;
        const result = try unescapeString(allocator, "\"\"");
        defer allocator.free(result);
        try std.testing.expectEqualStrings("\"", result);
    }

    test "unescapeString - empty input" {
        const allocator = std.testing.allocator;
        const result = try unescapeString(allocator, "");
        defer allocator.free(result);
        try std.testing.expectEqualStrings("", result);
    }

    test "unescapeString - trailing lone quote" {
        const allocator = std.testing.allocator;
        const result = try unescapeString(allocator, "abc\"");
        defer allocator.free(result);
        try std.testing.expectEqualStrings("abc\"", result);
    }


    //   quoted-string     ::= '"' string-body '"'
    //   string-body       ::= { string-char }
    //   string-char       ::= escaped-quote | continuation | any-non-null-non-quote
    //   escaped-quote     ::= '""'
    //   continuation      ::= doc-todo
    //   string-whitespace ::= ' ' | '\t' | '\r'
    fn scanQuotedString(self: *Tokenizer) TokenizerError!StringResult {
        std.debug.assert(self.peek() == '"');
        self.advance();

        const start        = self.index;
        var  needsUnescape = false;

        while (true) {
            const c = self.peek();
            if (c == 0) return TokenizerError.UnterminatedString;

            if (c == '"') {
                const end = self.index;
                self.advance();

                if (self.peek() == '"') {
                    needsUnescape = true;
                    self.advance();
                    continue;
                }

                const savedIndex = self.index;
                self.skipWhileInline(isStringWhitespace);

                if (self.peek() == '\n') {
                    self.advance();
                    self.skipWhileInline(isStringWhitespace);

                    if (self.peek() == '"') {
                        needsUnescape = true;
                        self.advance();
                        continue;
                    }

                    self.index = savedIndex;
                    return .{ .text = self.source[start..end], .needsUnescape = needsUnescape };
                }

                return .{ .text = self.source[start..end], .needsUnescape = needsUnescape };
            }

            self.advance();
        }
    }

    test "quoted string - simple" {
        var buf: [4]Token = undefined;
        _ = try tokenizeAll("\"hello\"\x00", &buf);
        try std.testing.expectEqual(TokenKind.stringLiteral, buf[0].kind);
        try std.testing.expectEqualStrings("hello", buf[0].data.string.text);
    }

    test "quoted string - escaped inner quote (\"\")" {
        var buf: [4]Token = undefined;
        _ = try tokenizeAll("\"say \"\"hi\"\"\"\x00", &buf);
        try std.testing.expectEqual(TokenKind.stringLiteral, buf[0].kind);
        try std.testing.expectEqualStrings("say \"\"hi\"\"",  buf[0].data.string.text);
    }

    test "quoted string - empty" {
        var buf: [4]Token = undefined;
        _ = try tokenizeAll("\"\"\x00", &buf);
        try std.testing.expectEqual(TokenKind.stringLiteral, buf[0].kind);
        try std.testing.expectEqualStrings("",  buf[0].data.string.text);
    }

    test "quoted string - line continuation" {
        var buf: [4]Token = undefined;
        _ = try tokenizeAll("\"foo\"\n\"bar\"\x00", &buf);
        try std.testing.expectEqual(TokenKind.stringLiteral, buf[0].kind);
        try std.testing.expect(buf[0].data.string.needsUnescape);
        const data = try unescapeString(std.testing.allocator, buf[0].data.string.text);
        defer std.testing.allocator.free(data);
        try std.testing.expectEqualStrings(data, "foobar");

    }

    test "quoted string - line continuation joins segments" {
        const allocator = std.testing.allocator;
        var buf: [4]Token = undefined;
        _ = try tokenizeAll("\"foo\"\n\"bar\"\x00", &buf);
        try std.testing.expectEqual(TokenKind.stringLiteral, buf[0].kind);
        try std.testing.expect(buf[0].data.string.needsUnescape);
        const joined = try unescapeString(allocator, buf[0].data.string.text);
        defer allocator.free(joined);
        try std.testing.expectEqualStrings("foobar", joined);
    }

    test "quoted string - line continuation with whitespace" {
        const allocator = std.testing.allocator;
        var buf: [4]Token = undefined;
        _ = try tokenizeAll("\"hello\"  \n  \"world\"\x00", &buf);
        try std.testing.expectEqual(TokenKind.stringLiteral, buf[0].kind);
        const joined = try unescapeString(allocator, buf[0].data.string.text);
        defer allocator.free(joined);
        try std.testing.expectEqualStrings("helloworld", joined);
    }

    test "quoted string - unterminated returns error" {
        var t = Tokenizer.init("\"unterminated\x00");
        const result = t.next();
        try std.testing.expectError(TokenizerError.UnterminatedString, result);
    }

    //   skippable         ::= { whitespace | line-comment | block-comment | line-directive }
    //   whitespace        ::= ' ' | '\t' | '\r' | '\n'
    //   line-comment      ::= '//' { !'\n\ } ( '\n' | EOF )
    //   block-comment     ::= '/*' { . } '*/' | '/*/'
    //   line-directive    ::= doc-todo
    fn skipWhiteSpaceAndComments(self: *Tokenizer) TokenizerError!void {
        while (true) {
            self.skipWhileInline(isWhitespace);

            const c0 = self.peek();
            const c1 = self.peekForward(1);

            if (c0 == '/' and c1 == '/') {
                self.index += 2;
                const rest = self.source[self.index..];
                if (std.mem.indexOfScalar(u8, rest, '\n')) |rel| {
                    self.index += @intCast(rel + 1);
                } else {
                    self.index = @intCast(self.source.len);
                }
                continue;
            }

            if (c0 == '/' and c1 == '*') {
                self.index += 2;
                const rest = self.source[self.index..];
                if (std.mem.indexOf(u8, rest, "*/")) |rel| {
                    self.index += @intCast(rel + 2);
                } else {
                    return TokenizerError.UnterminatedComment;
                }
                continue;
            }

            if (c0 == '#') {
                const saved = self.index;
                self.advance();
                var matches = true;
                for ("line") |ch| {
                    if (self.peek() != ch) { matches = false; break; }
                    self.advance();
                }
                if (matches) {
                    skipWhileInline(self, isSpace);
                    self.index = saved;
                    const numStart = self.index;
                    skipWhileInline(self, isDigit);
                    if (self.index > numStart) {
                        const numStr = self.source[numStart..self.index];
                        if (std.fmt.parseInt(u32, numStr, 10)) |n| {
                            //TODO line/source masking
                            _ = n;
                        } else |_| {}
                    }
                    skipWhileInline(self, isNotNewLine);
                    continue;
                }
                self.index = saved;
                break;
            }
            break;
        }
    }

    test "line comment skipped" {
        var buf: [4]Token = undefined;
        const n = try tokenizeAll("// comment\n42\x00", &buf);
        try std.testing.expectEqual(@as(usize, 2), n);
        try std.testing.expectEqual(TokenKind.intLiteral, buf[0].kind);
    }

    test "block comment skipped" {
        var buf: [4]Token = undefined;
        const n = try tokenizeAll("/* block */99\x00", &buf);
        try std.testing.expectEqual(@as(usize, 2), n);
        try std.testing.expectEqual(TokenKind.intLiteral, buf[0].kind);
        try std.testing.expectEqual(@as(i32, 99), buf[0].data.int);
    }

    test "block comment - multi-line" {
        var buf: [4]Token = undefined;
        const n = try tokenizeAll("/* line1\nline2\n*/1\x00", &buf);
        try std.testing.expectEqual(@as(usize, 2), n);
        try std.testing.expectEqual(TokenKind.intLiteral, buf[0].kind);
    }

    test "block comment - unterminated returns error" {
        var t = Tokenizer.init("/* no end\x00");
        const result = t.next();
        try std.testing.expectError(TokenizerError.UnterminatedComment, result);
    }

    test "nested-looking block comments are not recursive" {
        var buf: [4]Token = undefined;
        const n = try tokenizeAll("/* /* inner */ 1\x00", &buf);

        try std.testing.expectEqual(@as(usize, 2), n);
        try std.testing.expectEqual(TokenKind.intLiteral, buf[0].kind);
    }

    test "multiple comments and whitespace" {
        var buf: [8]Token = undefined;
        const n = try tokenizeAll("// c1\n /* c2 */ foo\x00", &buf);
        try std.testing.expectEqual(@as(usize, 2), n);
        try std.testing.expectEqual(TokenKind.identifier, buf[0].kind);
    }

    //   unquoted-value    ::= unquoted-body-char+ { ' ' | '\t' }
    //   unquoted-body-char::= !('\r' | '\n' | ';' | '}' | ',')
    fn scanUnquotedValue(self: *Tokenizer) []const u8 {
        const start = self.index;
        self.skipWhileInline(isNotUnquotedTerminator);
        var end = self.index;
        while (end > start and (self.source[end - 1] == ' ' or self.source[end - 1] == '\t')) {
            end -= 1;
        }
        return self.source[start..end];
    }

    //   identifier        ::= ident-start ident-continue*
    //   ident-start       ::= [a-zA-Z_]
    //   ident-continue    ::= [a-zA-Z_0-9]
    fn scanIdentifier(self: *Tokenizer) []const u8 {
        const start = self.index;
        self.skipWhileInline(isIdentifierContinue);
        return self.source[start..self.index];
    }

    test "identifier - simple" {
        var buf: [4]Token = undefined;
        const n = try tokenizeAll("fooBar\x00", &buf);
        try std.testing.expectEqual(@as(usize, 2), n);
        try std.testing.expectEqual(TokenKind.identifier, buf[0].kind);
    }

    test "identifier - leading underscore with digits" {
        var buf: [4]Token = undefined;
        const n = try tokenizeAll("_var1\x00", &buf);
        try std.testing.expectEqual(@as(usize, 2), n);
        try std.testing.expectEqual(TokenKind.identifier, buf[0].kind);
    }

    test "char predicates - whitespace" {
        for (" \t\r\n") |c| {
            _ = c;
        }
        var buf: [4]Token = undefined;
        const n = try tokenizeAll("  \t\r\n42" ++ [_:0]u8{}, &buf);
        try std.testing.expectEqual(@as(usize, 2), n);
        try std.testing.expectEqual(TokenKind.intLiteral, buf[0].kind);
    }

    test "char predicates - identifier start vs continue" {
        var buf: [4]Token = undefined;
        var n = try tokenizeAll("_abc123" ++ [_:0]u8{}, &buf);
        try std.testing.expectEqual(@as(usize, 2), n);
        try std.testing.expectEqual(TokenKind.identifier, buf[0].kind);

        n = try tokenizeAll("9abc" ++ [_:0]u8{}, &buf);
        try std.testing.expectEqual(TokenKind.stringLiteral, buf[0].kind);
    }

    const NumericResult = union(enum) {
        int:        i32,
        int64:      i64,
        float:      f32,
        notNumeric,
    };

    //   numeric           ::= hex-literal | db-literal | decimal-int | int64 | float
    //   hex-literal       ::= '0x' hex-digit+  |  '0X' hex-digit+
    //   hex-digit         ::= [0-9a-fA-F]
    //   db-literal        ::= ('d'|'D') ('b'|'B') float-body                            (* dB -> linear amplitude *)
    //   decimal-int       ::= [+-]? digit+                                              (* fits i32 *)
    //   int64             ::= [+-]? digit+                                              (* fits i64, not i32 *)
    //   float             ::= [+-]? digit* '.' digit+ ( [eE] [+-]? digit+ )?
    //   not-numeric       ::= !(numeric)
    fn detectNumeric(raw: []const u8) NumericResult {
        if (raw.len == 0) return .notNumeric;

        if (raw.len > 2 and raw[0] == '0' and (raw[1] == 'x' or raw[1] == 'X')) {
            if (std.fmt.parseInt(i32, raw[2..], 16)) |v| return .{ .int   = v } else |_| {}
            if (std.fmt.parseInt(i64, raw[2..], 16)) |v| return .{ .int64 = v } else |_| {}
            return .notNumeric;
        }

        if (raw.len > 2 and
            std.ascii.toLower(raw[0]) == 'd' and
            std.ascii.toLower(raw[1]) == 'b')
            {
                if (std.fmt.parseFloat(f32, raw[2..])) |db| {
                    return .{ .float = std.math.pow(f32, 10.0, db / 20.0) };
                } else |_| {}
                return .notNumeric;
            }

        if (std.fmt.parseInt(i32, raw, 10)) |v| return .{ .int   = v } else |_| {}
        if (std.fmt.parseInt(i64, raw, 10)) |v| return .{ .int64 = v } else |_| {}
        if (std.fmt.parseFloat(f32, raw))   |v| return .{ .float = v } else |_| {}

        return .notNumeric;
    }

    test "int literal - positive" {
        var buf: [4]Token = undefined;
        _ = try tokenizeAll("42\x00", &buf);
        try std.testing.expectEqual(TokenKind.intLiteral, buf[0].kind);
        try std.testing.expectEqual(@as(i32, 42), buf[0].data.int);
    }

    test "int literal - negative" {
        var buf: [4]Token = undefined;
        _ = try tokenizeAll("-7\x00", &buf);
        try std.testing.expectEqual(TokenKind.intLiteral, buf[0].kind);
        try std.testing.expectEqual(@as(i32, -7), buf[0].data.int);
    }

    test "int literal - zero" {
        var buf: [4]Token = undefined;
        _ = try tokenizeAll("0\x00", &buf);
        try std.testing.expectEqual(TokenKind.intLiteral, buf[0].kind);
        try std.testing.expectEqual(@as(i32, 0), buf[0].data.int);
    }

    test "int64 literal - large value beyond i32" {
        var buf: [4]Token = undefined;
        _ = try tokenizeAll("3000000000\x00", &buf);
        try std.testing.expectEqual(TokenKind.int64Literal, buf[0].kind);
        try std.testing.expectEqual(@as(i64, 3_000_000_000), buf[0].data.int64);
    }

    test "float literal - decimal" {
        var buf: [4]Token = undefined;
        _ = try tokenizeAll("3.14\x00", &buf);
        try std.testing.expectEqual(TokenKind.floatLiteral, buf[0].kind);
        try std.testing.expectApproxEqAbs(@as(f32, 3.14), buf[0].data.float, 1e-4);
    }

    test "float literal - negative decimal" {
        var buf: [4]Token = undefined;
        _ = try tokenizeAll("-0.5\x00", &buf);
        try std.testing.expectEqual(TokenKind.floatLiteral, buf[0].kind);
        try std.testing.expectApproxEqAbs(@as(f32, -0.5), buf[0].data.float, 1e-6);
    }

    test "hex literal - lowercase 0x" {
        var buf: [4]Token = undefined;
        _ = try tokenizeAll("0xFF\x00", &buf);
        try std.testing.expectEqual(TokenKind.intLiteral, buf[0].kind);
        try std.testing.expectEqual(@as(i32, 255), buf[0].data.int);
    }

    test "hex literal - uppercase 0X" {
        var buf: [4]Token = undefined;
        _ = try tokenizeAll("0X1A\x00", &buf);
        try std.testing.expectEqual(TokenKind.intLiteral, buf[0].kind);
        try std.testing.expectEqual(@as(i32, 26), buf[0].data.int);
    }

    test "hex literal - large (i64)" {
        var buf: [4]Token = undefined;
        _ = try tokenizeAll("0xFFFFFFFF\x00", &buf);
        try std.testing.expectEqual(TokenKind.int64Literal, buf[0].kind);
        try std.testing.expectEqual(@as(i64, 0xFFFF_FFFF), buf[0].data.int64);
    }

    test "numeric fallback - non-numeric string from digit start" {
        var buf: [4]Token = undefined;
        _ = try tokenizeAll("9abc\x00", &buf);
        try std.testing.expectEqual(TokenKind.stringLiteral, buf[0].kind);
    }

    //   token             ::= EOF
    //                       | '{' | '}' | '[' | ']' | '(' | ')'
    //                       | '=' | ';' | ',' | ':'
    //                       | quoted-string
    //                       | '@' unquoted-value
    //                       | keyword
    //                       | identifier
    //                       | numeric
    //                       | invalid-char
    //   keyword           ::= 'class' | 'delete' | 'enum' | '__EXEC' | '__EVAL'
    //   numeric-token     ::= ( digit | '+' | '-' ) unquoted-value
    pub fn next(self: *Tokenizer) TokenizerError!Token {
        try self.skipWhiteSpaceAndComments();
        return self.scanToken();
    }

    //   token             ::= EOF
    //                       | comment
    //                       | '{' | '}' | '[' | ']' | '(' | ')'
    //                       | '=' | ';' | ',' | ':'
    //                       | quoted-string
    //                       | '@' unquoted-value
    //                       | keyword
    //                       | identifier
    //                       | numeric
    //                       | invalid-char
    //   keyword           ::= 'class' | 'delete' | 'enum' | '__EXEC' | '__EVAL'
    //   numeric-token     ::= ( digit | '+' | '-' ) unquoted-value
    //   comment           ::= (line-comment | block-comment)
    //   line-comment      ::= '//' .* EOL
    //   block-comment     ::= '/*/' | '/*' .* '*/'
    pub fn nextSemantic(self: *Tokenizer) TokenizerError!Token {
        while (true) {
            self.skipWhileInline(isWhitespace);

            const pos = self.index;
            const c0  = self.peek();
            const c1  = self.peekForward(1);

            if (c0 == '/' and c1 == '/') {
                self.index += 2;
                const rest = self.source[self.index..];
                if (std.mem.indexOfScalar(u8, rest, '\n')) |rel| {
                    self.index += @intCast(rel);
                } else {
                    self.index = @intCast(self.source.len);
                }
                return .{ .kind = .comment, .data = .{ .none = {} }, .pos = pos };
            }

            if (c0 == '/' and c1 == '*') {
                self.index += 2;
                const rest = self.source[self.index..];
                if (std.mem.indexOf(u8, rest, "*/")) |rel| {
                    self.index += @intCast(rel + 2);
                } else {
                    return TokenizerError.UnterminatedComment;
                }
                return .{ .kind = .comment, .data = .{ .none = {} }, .pos = pos };
            }

            return self.scanToken();
        }
    }

    fn scanToken(self: *Tokenizer) TokenizerError!Token {
        const pos = self.index;
        const c   = self.peek();

        if (c == 0) return Token{ .kind = .eof, .data = .{ .none = {} }, .pos = pos };

        switch (c) {
            '{' => { self.advance(); self.after_equals = false; return .{ .kind = .leftBrace,        .data = .{ .none = {} }, .pos = pos }; },
            '}' => { self.advance(); self.after_equals = false; return .{ .kind = .rightBrace,       .data = .{ .none = {} }, .pos = pos }; },
            '[' => { self.advance(); self.after_equals = false; return .{ .kind = .leftBracket,      .data = .{ .none = {} }, .pos = pos }; },
            ']' => { self.advance(); self.after_equals = false; return .{ .kind = .rightBracket,     .data = .{ .none = {} }, .pos = pos }; },
            '(' => { self.advance(); self.after_equals = false; return .{ .kind = .leftParenthesis,  .data = .{ .none = {} }, .pos = pos }; },
            ')' => { self.advance(); self.after_equals = false; return .{ .kind = .rightParenthesis, .data = .{ .none = {} }, .pos = pos }; },
            '=' => { self.advance(); self.after_equals = true;  return .{ .kind = .equals,           .data = .{ .none = {} }, .pos = pos }; },
            ';' => { self.advance(); self.after_equals = false; return .{ .kind = .semicolon,        .data = .{ .none = {} }, .pos = pos }; },
            ',' => { self.advance(); self.after_equals = false; return .{ .kind = .comma,            .data = .{ .none = {} }, .pos = pos }; },
            ':' => { self.advance(); self.after_equals = false; return .{ .kind = .colon,            .data = .{ .none = {} }, .pos = pos }; },
            '"' => {
                const result = try self.scanQuotedString();
                return .{ .kind = .stringLiteral, .data = .{ .string = result }, .pos = pos };
            },
            '@' => {
                self.advance();
                return .{ .kind = .expression, .data = .{ .text = self.scanUnquotedValue() }, .pos = pos };
            },
            else => {
                if (c == '+' and self.peekForward(1) == '=') {
                    self.index += 2;
                    self.after_equals = false;
                    return .{ .kind = .addAssign, .data = .{ .none = {} }, .pos = pos };
                }

                if (c == '-' and self.peekForward(1) == '=') {
                    self.index += 2;
                    self.after_equals = false;
                    return .{ .kind = .subAssign, .data = .{ .none = {} }, .pos = pos };
                }

                if (self.after_equals) {
                    self.after_equals = false;
                    const raw = self.scanUnquotedValue();
                    return getNumeric(raw, pos);
                }

                if (isIdentifierStart(c)) {
                    const identText = self.scanIdentifier();
                    const kind      = KEYWORDS.get(identText) orelse .identifier;
                    return .{ .kind = kind, .data = .{ .text = identText }, .pos = pos };
                }

                if (isDigit(c) or c == '-' or c == '+') {
                    const raw = self.scanUnquotedValue();
                    return getNumeric(raw, pos);
                }

                self.advance();
                return .{ .kind = .invalid, .data = .{ .none = {} }, .pos = pos };
            },
        }
    }

    fn getNumeric(raw: []const u8, pos: u32) Token {
        //fixme: this is doing multiple passes over the same text
        //can we do better by integrating detection into the scanning loop?
        return switch (detectNumeric(raw)) {
            .int        => |v| .{ .kind = .intLiteral,    .data = .{ .int   = v   }, .pos = pos },
            .int64      => |v| .{ .kind = .int64Literal,  .data = .{ .int64 = v   }, .pos = pos },
            .float      => |v| .{ .kind = .floatLiteral,  .data = .{ .float = v   }, .pos = pos },
            .notNumeric =>     .{ .kind = .stringLiteral, .data = .{ .text  = raw }, .pos = pos },
        };
    }
    test "keyword tokens" {
        const cases = .{
            .{ "class",  TokenKind.classKeyword  },
            .{ "delete", TokenKind.deleteKeyword },
            .{ "enum",   TokenKind.enumKeyword   },
            .{ "__EXEC", TokenKind.execKeyword   },
            .{ "__EVAL", TokenKind.evalKeyword   },
        };
        inline for (cases) |c| {
            const src: [:0]const u8 = c[0] ++ [_:0]u8{};
            var buf: [4]Token = undefined;
            const n = try tokenizeAll(src, &buf);
            try std.testing.expectEqual(@as(usize, 2), n);
            try std.testing.expectEqual(c[1], buf[0].kind);
            try std.testing.expect(buf[0].isKeyword());
        }
    }

    test "keyword look-alikes are plain identifiers" {
        const cases = [_][:0]const u8{
            "Class\x00", "DELETE\x00", "Enum\x00", "_EXEC\x00", "eval\x00",
        };
        for (cases) |src| {
            var buf: [4]Token = undefined;
            _ = try tokenizeAll(src, &buf);
            try std.testing.expectEqual(TokenKind.identifier, buf[0].kind);
            try std.testing.expect(!buf[0].isKeyword());
        }
    }

    test "expression token" {
        var buf: [4]Token = undefined;
        _ = try tokenizeAll("@someExpr\x00", &buf);
        try std.testing.expectEqual(TokenKind.expression, buf[0].kind);
        try std.testing.expectEqualStrings("someExpr", buf[0].text());
    }

    test "expression token - trailing whitespace stripped" {
        var buf: [4]Token = undefined;
        _ = try tokenizeAll("@value  \n\x00", &buf);
        try std.testing.expectEqual(TokenKind.expression, buf[0].kind);
        try std.testing.expectEqualStrings("value", buf[0].text());
    }

    test "punctuation tokens" {
        const cases = .{
            .{ "{",  TokenKind.leftBrace        },
            .{ "}",  TokenKind.rightBrace       },
            .{ "[",  TokenKind.leftBracket      },
            .{ "]",  TokenKind.rightBracket     },
            .{ "(",  TokenKind.leftParenthesis  },
            .{ ")",  TokenKind.rightParenthesis },
            .{ "=",  TokenKind.equals           },
            .{ ";",  TokenKind.semicolon        },
            .{ ",",  TokenKind.comma            },
            .{ ":",  TokenKind.colon            },
        };
        inline for (cases) |c| {
            const src: [:0]const u8 = c[0] ++ [_:0]u8{};
            var buf: [4]Token = undefined;
            const n = try tokenizeAll(src, &buf);
            try std.testing.expectEqual(@as(usize, 2), n);
            try std.testing.expectEqual(c[1], buf[0].kind);
            try std.testing.expectEqual(@as(u32, 0), buf[0].pos);
        }
    }

    test "bench - tokenizer throughput" {
        const BENCH_ITERS: u64 = 100;

        const BENCH_SRC: *const [210143:0]u8 = @embedFile("tests/game.cpp");
        var totalTokens: usize = 0;

        const start = std.Io.Timestamp.now(std.testing.io, .real).nanoseconds;
        var iter: u64 = 0;
        while (iter < BENCH_ITERS) : (iter += 1) {
            var t = Tokenizer.init(BENCH_SRC);
            while (true) {
                const tok = t.next() catch break;
                totalTokens += 1;
                if (tok.kind == .eof) break;
            }
        }
        const elapsed_ns: u64 = @intCast(std.Io.Timestamp.now(std.testing.io, .real).nanoseconds - start);
        const ns_per_token = elapsed_ns / totalTokens;

        std.debug.print(
            "\n[bench] tokenizer: {} tokens in {} iters - {d} ns/token\n",
            .{ totalTokens / BENCH_ITERS, BENCH_ITERS, ns_per_token },
        );
    }

    test "end-to-end - class declaration" {
        const src: [:0]const u8 =
            \\class MyClass {
            \\    value = 42;
            \\    name  = "hello";
            \\}
        ++ [_:0]u8{};

        var buf: [32]Token = undefined;
        const n = try tokenizeAll(src, &buf);
        // class  MyClass  {  value  =  42  ;  name  =  "hello"  ;  }  EOF
        try std.testing.expectEqual(TokenKind.classKeyword,  buf[0].kind);
        try std.testing.expectEqual(TokenKind.identifier,    buf[1].kind);
        try std.testing.expectEqual(TokenKind.leftBrace,     buf[2].kind);
        try std.testing.expectEqual(TokenKind.identifier,    buf[3].kind);
        try std.testing.expectEqual(TokenKind.equals,        buf[4].kind);
        try std.testing.expectEqual(TokenKind.intLiteral,    buf[5].kind);
        try std.testing.expectEqual(TokenKind.semicolon,     buf[6].kind);
        try std.testing.expectEqual(TokenKind.identifier,    buf[7].kind);
        try std.testing.expectEqual(TokenKind.equals,        buf[8].kind);
        try std.testing.expectEqual(TokenKind.stringLiteral, buf[9].kind);
        try std.testing.expectEqual(TokenKind.semicolon,     buf[10].kind);
        try std.testing.expectEqual(TokenKind.rightBrace,    buf[11].kind);
        try std.testing.expectEqual(TokenKind.eof,           buf[12].kind);
        _ = n;
    }

    fn kinds(src: [:0]const u8, out: []TokenKind) !usize {
        var buf: [256]Token = undefined;
        const n = try tokenizeAll(src, &buf);
        const count = if (n > 0) n - 1 else 0;
        for (0..count) |i| out[i] = buf[i].kind;
        return count;
    }

    pub fn tokenizeAll(src: [:0]const u8, buf: []Token) !usize {
        var t   = Tokenizer.init(src);
        var n: usize = 0;
        while (n < buf.len) {
            const tok = try t.next();
            buf[n] = tok;
            n += 1;
            if (tok.kind == .eof) break;
        }
        return n;
    }

    test "invalid character" {
        var buf: [4]Token = undefined;
        _ = try tokenizeAll("^\x00", &buf);
        try std.testing.expectEqual(TokenKind.invalid, buf[0].kind);
    }

    test "empty source → immediate EOF" {
        var t = Tokenizer.init("\x00");
        const tok = try t.next();
        try std.testing.expectEqual(TokenKind.eof, tok.kind);
        try std.testing.expectEqual(@as(u32, 0), tok.pos);
    }

    test "only whitespace → EOF" {
        var buf: [4]Token = undefined;
        const n = try tokenizeAll("   \t\n\x00", &buf);
        try std.testing.expectEqual(@as(usize, 1), n);
        try std.testing.expectEqual(TokenKind.eof, buf[0].kind);
    }

    // benchmark helper
    fn benchRun(comptime f: fn () void, iters: u64) u64 {
        const start = std.time.nanoTimestamp();
        var i: u64 = 0;
        while (i < iters) : (i += 1) f();
        const end = std.time.nanoTimestamp();
        return @intCast(end - start);
    }

    pub fn peekToken(self: *Tokenizer) TokenizerError!Token {
        const saved = self.index;
        const tok   = try self.next();
        self.index  = saved;
        return tok;
    }

    test "peekToken does not advance index" {
        var t = Tokenizer.init("foo\x00");
        const before = t.index;
        const peeked = try t.peekToken();
        try std.testing.expectEqual(before, t.index);
        try std.testing.expectEqual(TokenKind.identifier, peeked.kind);

        const actual = try t.next();
        try std.testing.expectEqual(peeked.kind, actual.kind);
    }
};

test {
    std.testing.refAllDecls(@This());
}
