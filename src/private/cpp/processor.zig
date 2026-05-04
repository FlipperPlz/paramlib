const std = @import("std");
const pp = @import("../common/preprocessor.zig");
const lexer = @import("lexer.zig");
const logger = @import("utils/log.zig");

const PreProcessError = error {
    IncludeError,
    IncludeMaxRecursion
};



const CppPreLexer = struct {
    source:       [:0]const u8,
    index:        u32,
    mappings:     std.ArrayList(pp.SourceMapping),
    log:          *const logger.DiagType,

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

    inline fn isWhitespace(c: u8) bool            { return CHAR_TABLE[c] & CF_WHITESPACE != 0; }
    inline fn isIdentifierStart(c: u8) bool       { return CHAR_TABLE[c] & CF_IDENT_START != 0; }
    inline fn isIdentifierContinue(c: u8) bool    { return CHAR_TABLE[c] & CF_IDENT_CONTINUE != 0; }
    inline fn isLineContinue(c: u8) bool          { return CHAR_TABLE[c] & CF_LINE_CONTINUE != 0; }

    const Token = struct {
        kind: TokenKind,
        data: TokenData,
        offset: usize,
        len: usize,
    };

    const TokenData = union(enum) {
        text: []const u8,
        comment: []const u8,
        symbol: void,
        keyword: void,
    };

    const TokenKind = enum {
        Define, Undef, Include, IfDef, IfNDef, Else, EndIf,
        LeftParen, RightParen, Comma, Hash, NewLine, NewFile,
        BeginLineComment, BeginBlockComment, LineContinue,
        Quote, LeftAngle, RightAngle, DoubleHash, Text, Unknown,
    };

    const SYMBOLS = std.StaticStringMap(TokenKind) {
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
    };

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
                    const tok = lexer.Token{ .kind = .invalid, .data = .{ .none = {} }, .pos = self.index };
                    self.log.emit(.warning, "P01", &tok, "Backslash followed by non-newline is treated as literal backslash.", null);
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
                } else {
                    const tok = lexer.Token{ .kind = .invalid, .data = .{ .none = {} }, .pos = idx };
                    self.log.emit(.warning, "P01", &tok, "Backslash followed by non-newline is treated as literal backslash.", null);
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

        while (self.peekLexed()) |c| {
            if (!isIdentifierContinue(c)) break;
            _ = try self.nextLexed(allocator, pre_offset_ptr.*);
            pre_offset_ptr.* += 1;
            try name.append(allocator, c);
        }

        return try name.toOwnedSlice(allocator);
    }
};

test "CppPreLexer - scanName" {
    const allocator = std.testing.allocator;
    const log = logger.DiagType.none();

    // Test basic name
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

    // Test name with line continuation
    {
        const src = "my\\\nVar" ++ [_:0]u8{};
        var lexer_inst = CppPreLexer.init(src, &log);
        defer lexer_inst.mappings.deinit(allocator);
        var pre_offset: u32 = 0;
        const name = try lexer_inst.scanName(allocator, &pre_offset);
        defer allocator.free(name);
        try std.testing.expectEqualStrings("myVar", name);
        try std.testing.expectEqual(@as(u32, 5), pre_offset);
        // Mapping should have gap
        try std.testing.expectEqual(@as(usize, 2), lexer_inst.mappings.items.len);
    }

    // Test name followed by something else
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
    try std.testing.expectEqual(@as(u32, 4), lexer_inst.mappings.items[1].length); // ' ', 'b', '\n', and 'c'
}

const CppPreParser = struct {


};

pub const CppPreprocessor = struct {
    defines: std.StringHashMapUnmanaged(Macro),
    arg_scope: ?*ArgumentScope = null,
    recursion_depth: u32 = 0,
    max_recursion: u32 = 100,

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

    fn preprocessWrapper(ptr: *anyopaque, allocator: std.mem.Allocator, source: [:0]const u8) anyerror!pp.PreprocessedResult {
        const self: *CppPreprocessor = @ptrCast(@alignCast(ptr));
        return self.preprocess(allocator, source);
    }

    fn preprocess(self: *CppPreprocessor, allocator: std.mem.Allocator, source: [:0]const u8) anyerror!pp.PreprocessedResult {
        _ = self;
        _ = source;
        const out = std.ArrayList(u8).empty;
        const mappings = std.ArrayList(pp.SourceMapping).empty;

        return .{
            .source = out.toOwnedSlice(allocator),
            .mappings = mappings.toOwnedSlice(allocator)
        };
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
