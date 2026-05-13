const std = @import("std");
const Allocator = std.mem.Allocator;
const TokenKind = lexer.TokenKind;
const lexer = @import("./lexer.zig");
const logger = @import("../common/log.zig");
const lines = @import("../common/lines.zig");
const ast = @import("ast.zig");
const database = @import("../../api/database.zig");
const preprocessor = @import("./processor.zig");
const pp = @import("../common/preprocessor.zig");

const ParseError = error{
    UnexpectedToken,
    ParseError,
    UnexpectedEndOfFile,
    OutOfMemory,

    UnterminatedString,
    InvalidEscape,
    UnterminatedComment,
    Overflow,
};

fn z(comptime s: []const u8) [:0]const u8 {
    return s ++ [_:0]u8{};
}

test "parse: integer parameter" {
    const src = z("value = 42;");
    var errored: bool = false;
    const lineTable = try lines.LineTable.build(std.testing.allocator, src);
    const log = logger.DiagType.stdErr(std.testing.io, &lineTable, src, "test.cpp", true);
    var result = try parseSource(std.testing.allocator, src, &errored, log);
    defer result.deinit(std.testing.allocator);

    const members = result.members.?.items;
    try std.testing.expectEqual(@as(usize, 1), members.len);
    const param = members[0].param;
    try std.testing.expectEqualStrings("value", param.name);
    try std.testing.expectEqual(ast.OperatorAst.assign, param.operator);
    try std.testing.expectEqual(@as(i32, 42), param.value.integer);
    try std.testing.expect(!errored);
}

test "parse: float parameter" {
    const src = z("ratio = 3.14;");
    var errored: bool = false;
    const lineTable = try lines.LineTable.build(std.testing.allocator, src);
    const log = logger.DiagType.stdErr(std.testing.io, &lineTable, src, "test.cpp", true);
    var result = try parseSource(std.testing.allocator, src, &errored, log);
    defer result.deinit(std.testing.allocator);

    const param = result.members.?.items[0].param;
    try std.testing.expectEqualStrings("ratio", param.name);
    try std.testing.expectApproxEqAbs(@as(f32, 3.14), param.value.float, 0.001);
    try std.testing.expect(!errored);

}

test "parse: string parameter" {
    const src = z(
        \\name = "hello";
    );
    var errored: bool = false;
    const lineTable = try lines.LineTable.build(std.testing.allocator, src);
    const log = logger.DiagType.stdErr(std.testing.io, &lineTable, src, "test.cpp", true);
    var result = try parseSource(std.testing.allocator, src, &errored, log);
    defer result.deinit(std.testing.allocator);

    const param = result.members.?.items[0].param;
    try std.testing.expectEqualStrings("name", param.name);
    try std.testing.expectEqualStrings("hello", param.value.string);
    try std.testing.expect(!errored);

}

test "parse: string without escapes (literal content preserved)" {
    const src = z(
        \\msg = "hello world";
    );
    var errored: bool = false;
    const lineTable = try lines.LineTable.build(std.testing.allocator, src);
    const log = logger.DiagType.stdErr(std.testing.io, &lineTable, src, "test.cpp", true);
    var result = try parseSource(std.testing.allocator, src, &errored, log);
    defer result.deinit(std.testing.allocator);

    const param = result.members.?.items[0].param;
    try std.testing.expectEqualStrings("hello world", param.value.string);
    try std.testing.expect(!errored);

}

test "parse: with comments" {
    const src = z(
        \\/* Block comment */
        \\class CfgSchemas {
        \\    // Line comment
        \\    value = 42;
        \\};
    );
    var errored: bool = false;
    const lineTable = try lines.LineTable.build(std.testing.allocator, src);
    const log = logger.DiagType.stdErr(std.testing.io, &lineTable, src, "test.cpp", true);
    var result = try parseSource(std.testing.allocator, src, &errored, log);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!errored);
    const members = result.members.?.items;
    try std.testing.expectEqual(@as(usize, 1), members.len);
    const cls = members[0].class;
    try std.testing.expectEqualStrings("CfgSchemas", cls.name.?);
}

test "parse: with preprocessor macro" {
    const allocator = std.testing.allocator;
    const src = z(
        \\#define VAL 42
        \\value = VAL;
    );
    var errored: bool = false;
    const log = logger.DiagType.none();
    var cpp = preprocessor.CppPreprocessor.empty;
    defer cpp.deinit(allocator);

    var result = try parseSourceWithPreprocessor(allocator, src, &errored, log, &cpp);
    defer result.deinit(allocator);

    const members = result.ast.members.?.items;
    try std.testing.expectEqual(@as(usize, 1), members.len);
    const param = members[0].param;
    const name = try allocator.dupe(u8, param.name);
    defer allocator.free(name);
    try std.testing.expectEqualStrings("value", name);
    try std.testing.expectEqual(@as(i32, 42), param.value.integer);
    try std.testing.expect(!errored);
}

test "parse: with preprocessor include" {
    const allocator = std.testing.allocator;
    const src = z(
        \\#include "other.h"
        \\value = VAL;
    );
    
    const Mock = struct {
        pub fn processInclude(path: []const u8, alloc: std.mem.Allocator, _: *const logger.DiagType, _: *preprocessor.IncludeError) [:0]const u8 {
            if (std.mem.eql(u8, path, "other.h")) {
                return alloc.dupeZ(u8, "#define VAL 100") catch unreachable;
            }
            return alloc.dupeZ(u8, "") catch unreachable;
        }
    };

    var errored: bool = false;
    const log = logger.DiagType.none();
    var cpp = preprocessor.CppPreprocessor.empty;
    cpp.processInclude = Mock.processInclude;
    defer cpp.deinit(allocator);

    var result = try parseSourceWithPreprocessor(allocator, src, &errored, log, &cpp);
    defer result.deinit(allocator);

    const members = result.ast.members.?.items;
    try std.testing.expectEqual(@as(usize, 1), members.len);
    const param = members[0].param;
    const name = try allocator.dupe(u8, param.name);
    defer allocator.free(name);
    try std.testing.expectEqualStrings("value", name);
    try std.testing.expectEqual(@as(i32, 100), param.value.integer);
    try std.testing.expect(!errored);
}

test "parse: class forward declaration" {
    const src = z("class MyClass;");
    var errored: bool = false;
    const lineTable = try lines.LineTable.build(std.testing.allocator, src);
    const log = logger.DiagType.stdErr(std.testing.io, &lineTable, src, "test.cpp", true);
    var result = try parseSource(std.testing.allocator, src, &errored, log);
    defer result.deinit(std.testing.allocator);

    const members = result.members.?.items;
    try std.testing.expectEqual(@as(usize, 1), members.len);
    const cls = members[0].class;
    try std.testing.expectEqualStrings("MyClass", cls.name.?);
    try std.testing.expect(cls.members == null);
    try std.testing.expect(!errored);
}

test "parse: class with body and parameters" {
    const src = z(
        \\class MyClass {
        \\    value = 42;
        \\    name  = "hello";
        \\};
    );
    var errored: bool = false;
    const lineTable = try lines.LineTable.build(std.testing.allocator, src);
    defer lineTable.deinit(std.testing.allocator);
    const log = logger.DiagType.stdErr(std.testing.io, &lineTable, src, "test.cpp", true);
    var result = try parseSource(std.testing.allocator, src, &errored, log);
    defer result.deinit(std.testing.allocator);

    const class = result.members.?.items[0].class;

    try std.testing.expectEqualStrings("MyClass", class.name.?);
    try std.testing.expect(result.base == null);


    const members = class.members.?.items;
    try std.testing.expectEqual(@as(usize, 2), members.len);
    try std.testing.expectEqualStrings("value", members[0].param.name);
    try std.testing.expectEqual(@as(i32, 42), members[0].param.value.integer);
    try std.testing.expectEqualStrings("name", members[1].param.name);
    try std.testing.expectEqualStrings("hello", members[1].param.value.string);
    try std.testing.expect(!errored);

}

test "parse: delete declaration" {
    const src = z("delete someField;");
    var errored: bool = false;
    const lineTable = try lines.LineTable.build(std.testing.allocator, src);
    const log = logger.DiagType.stdErr(std.testing.io, &lineTable, src, "test.cpp", true);
    var result = try parseSource(std.testing.allocator, src, &errored, log);
    defer result.deinit(std.testing.allocator);

    const members = result.members.?.items;
    try std.testing.expectEqual(@as(usize, 1), members.len);
    try std.testing.expectEqualStrings("someField", members[0].delete.?);
    try std.testing.expect(!errored);

}

test "parse: array value" {
    const src = z("items = {1, 2, 3};");
    var errored: bool = false;
    const lineTable = try lines.LineTable.build(std.testing.allocator, src);
    const log = logger.DiagType.stdErr(std.testing.io, &lineTable, src, "test.cpp", true);
    var result = try parseSource(std.testing.allocator, src, &errored, log);
    const arr = result.members.?.items[0].param.value.array;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqual(@as(i32, 1), arr[0].integer);
    try std.testing.expectEqual(@as(i32, 2), arr[1].integer);
    try std.testing.expectEqual(@as(i32, 3), arr[2].integer);
    try std.testing.expect(!errored);

}

test "parse: empty array" {
    const src = z("items[] = {};");
    var errored: bool = false;
    const lineTable = try lines.LineTable.build(std.testing.allocator, src);
    const log = logger.DiagType.stdErr(std.testing.io, &lineTable, src, "test.cpp", true);
    var result = try parseSource(std.testing.allocator, src, &errored, log);
    defer result.deinit(std.testing.allocator);

    const arr = result.members.?.items[0].param.value.array;
    try std.testing.expectEqual(@as(usize, 0), arr.len);
    try std.testing.expect(!errored);

}

test "parse: array += operator" {
    const src = z("items[] += {10, 20};");
    var errored: bool = false;

    const lineTable = try lines.LineTable.build(std.testing.allocator, src);
    const log = logger.DiagType.stdErr(std.testing.io, &lineTable, src, "test.cpp", true);
    var result = try parseSource(std.testing.allocator, src, &errored, log);
    const arr = result.members.?.items[0].param.value.array;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(ast.OperatorAst.addAssign, result.members.?.items[0].param.operator);
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expect(!errored);

}

test "parse: array -= operator" {
    const src = z("items[] -= {10, 20};");
    var errored: bool = false;
    const lineTable = try lines.LineTable.build(std.testing.allocator, src);
    const log = logger.DiagType.stdErr(std.testing.io, &lineTable, src, "test.cpp", true);
    var result = try parseSource(std.testing.allocator, src, &errored, log);
    const arr = result.members.?.items[0].param.value.array;
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!errored);

    try std.testing.expectEqual(ast.OperatorAst.subAssign, result.members.?.items[0].param.operator);
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqual(@as(i32, 10), arr[0].integer);
    try std.testing.expectEqual(@as(i32, 20), arr[1].integer);
}

test "parse: multiple top-level members" {
    const src = z(
        \\x = 1;
        \\y = 2;
        \\delete z;
    );
    var errored: bool = false;

    const lineTable = try lines.LineTable.build(std.testing.allocator, src);
    defer lineTable.deinit(std.testing.allocator);
    const log = logger.DiagType.stdErr(std.testing.io, &lineTable, src, "test.cpp", true);
    var result = try parseSource(std.testing.allocator, src, &errored, log);
    defer result.deinit(std.testing.allocator);

    const members = result.members.?.items;
    try std.testing.expectEqual(@as(usize, 3), members.len);
    try std.testing.expectEqualStrings("x", members[0].param.name);
    try std.testing.expectEqualStrings("y", members[1].param.name);
    try std.testing.expectEqualStrings("z", members[2].delete.?);
    try std.testing.expect(!errored);

}

test "parse error: unexpected token at top level" {
    const src = z("= oops;");
    var errored: bool = false;
    const lineTable = try lines.LineTable.build(std.testing.allocator, src);
    const log = logger.DiagType.stdErr(std.testing.io, &lineTable, src, "test.cpp", true);
    var result = try parseSource(std.testing.allocator, src, &errored, log);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(errored);
    try std.testing.expectEqual(@as(usize, 0), result.members.?.items.len);
}

test "parse error: missing semicolon after parameter" {
    const src = z("value = 42");
    var errored: bool = false;
    const lineTable = try lines.LineTable.build(std.testing.allocator, src);
    const log = logger.DiagType.stdErr(std.testing.io, &lineTable, src, "test.cpp", true);
    var result = try parseSource(std.testing.allocator, src, &errored, log);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(errored);
    try std.testing.expectEqual(@as(usize, 0), result.members.?.items.len);
}

test "parse error: unmatched right brace" {
    const src = z("};");
    var errored: bool = false;
    const lineTable = try lines.LineTable.build(std.testing.allocator, src);
    const log = logger.DiagType.stdErr(std.testing.io, &lineTable, src, "test.cpp", true);
    var result = try parseSource(std.testing.allocator, src, &errored, log);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(errored);
    try std.testing.expectEqual(@as(usize, 0), result.members.?.items.len);
}

test "parse error: += on non-array parameter" {
    const src = z("value += 42;");
    var errored: bool = false;
    const lineTable = try lines.LineTable.build(std.testing.allocator, src);
    const log = logger.DiagType.stdErr(std.testing.io, &lineTable, src, "test.cpp", true);
    var result = try parseSource(std.testing.allocator, src, &errored, log);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(errored);
    try std.testing.expectEqual(@as(usize, 0), result.members.?.items.len);
}

test "parse error: missing identifier after delete" {
    const src = z("delete ;");
    var errored: bool = false;
    const lineTable = try lines.LineTable.build(std.testing.allocator, src);
    const log = logger.DiagType.stdErr(std.testing.io, &lineTable, src, "test.cpp", true);
    var result = try parseSource(std.testing.allocator, src, &errored, log);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(errored);
    try std.testing.expectEqual(@as(usize, 0), result.members.?.items.len);
}

test "parse error: missing identifier after class" {
    const src = z("class {");
    var errored: bool = false;
    const lineTable = try lines.LineTable.build(std.testing.allocator, src);
    const log = logger.DiagType.stdErr(std.testing.io, &lineTable, src, "test.cpp", true);
    var result = try parseSource(std.testing.allocator, src, &errored, log);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(errored);
    try std.testing.expectEqual(@as(usize, 0), result.members.?.items.len);
}

test "parse error: class with undefined base class" {
    const src = z("class Foo : UndefinedBase { };");
    var errored: bool = false;
    const lineTable = try lines.LineTable.build(std.testing.allocator, src);
    const log = logger.DiagType.stdErr(std.testing.io, &lineTable, src, "test.cpp", true);
    var result = try parseSource(std.testing.allocator, src, &errored, log);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(errored);
    try std.testing.expectEqual(@as(usize, 0), result.members.?.items.len);
}

test "parse recovery: valid declarations after bad one are collected" {
    const src = z(
        \\x = 42
        \\y = 2;
        \\delete z;
    );
    var errored: bool = false;
    const lineTable = try lines.LineTable.build(std.testing.allocator, src);
    defer lineTable.deinit(std.testing.allocator);
    const log = logger.DiagType.stdErr(std.testing.io, &lineTable, src, "test.cpp", true);
    var result = try parseSource(std.testing.allocator, src, &errored, log);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(errored);
    const members = result.members.?.items;
    try std.testing.expectEqual(@as(usize, 2), members.len);
    try std.testing.expectEqualStrings("y", members[0].param.name);
    try std.testing.expectEqualStrings("z", members[1].delete.?);
}

test "parse recovery: multiple missing semicolons" {
    const src = z(
        \\x = 42
        \\y = 2
        \\delete z
    );
    var errored: bool = false;
    const lineTable = try lines.LineTable.build(std.testing.allocator, src);
    defer lineTable.deinit(std.testing.allocator);
    const log = logger.DiagType.stdErr(std.testing.io, &lineTable, src, "test.cpp", true);
    var result = try parseSource(std.testing.allocator, src, &errored, log);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(errored);
    try std.testing.expectEqual(@as(usize, 0), result.members.?.items.len);
}

fn isStatementStart(kind: lexer.TokenKind) bool {
    return switch (kind) {
        .identifier, .classKeyword, .deleteKeyword, .enumKeyword, .execKeyword => true,
        else => false,
    };
}


fn synchronize(tokenizer: *lexer.Tokenizer, next: *lexer.Token) ParseError!void {
    if (isStatementStart(next.kind) or next.kind == .rightBrace or next.kind == .eof) return;
    var depth: usize = 0;
    while (next.kind != .eof) {
        switch (next.kind) {
            .leftBrace => {
                depth += 1;
                next.* = try tokenizer.next();
            },
            .rightBrace => {
                if (depth == 0) return;
                depth -= 1;
                next.* = try tokenizer.next();
                if (depth == 0) {
                    if (next.kind == .semicolon) next.* = try tokenizer.next();
                    return;
                }
            },
            .semicolon => {
                if (depth == 0) {
                    next.* = try tokenizer.next();
                    return;
                }
                next.* = try tokenizer.next();
            },
            else => {
                next.* = try tokenizer.next();
            },
        }
    }
}

pub const ParseWithPreprocessorResult = struct {
    ast: ast.ClassAst,
    pp_res: pp.PreprocessedResult,
    pp_lt: lines.LineTable,

    pub fn deinit(self: *ParseWithPreprocessorResult, allocator: Allocator) void {
        self.ast.deinit(allocator);
        self.pp_lt.deinit(allocator);
        self.pp_res.deinit(allocator);
    }
};

pub fn parseSourceWithPreprocessor(allocator: Allocator, data: [:0]const u8, errored: *bool, log: logger.DiagType, cpp: *preprocessor.CppPreprocessor) !ParseWithPreprocessorResult {
    const pp_res = try cpp.preprocess(allocator, data, &log);
    errdefer pp_res.deinit(allocator);

    const pp_lt = try lines.LineTable.build(allocator, pp_res.source);
    errdefer pp_lt.deinit(allocator);

    const pp_log = logger.DiagType.stdErrMapped(
        log.io orelse std.testing.io,
        &pp_lt,
        pp_res.source,
        log.filename,
        log.use_color,
        &pp_res,
    );

    const class_ast = try parseSource(allocator, pp_res.source, errored, pp_log);
    return ParseWithPreprocessorResult{
        .ast = class_ast,
        .pp_res = pp_res,
        .pp_lt = pp_lt,
    };
}

pub fn parseSource(allocator: Allocator, data: [:0]const u8, errored: *bool, log: logger.DiagType) ParseError!ast.ClassAst {
    var l = lexer.Tokenizer.init(data);

    var root = ast.ClassAst {
        .base     = null,
        .members  = std.ArrayList(ast.MemberAst).empty,
        .name     = "",
        .namePos = 0,
        .parent   = null,
    };

    var topAst: *ast.ClassAst = &root;
    var next = try l.next();
    while (next.kind != .eof)  {
        const tokenKind: lexer.TokenKind = next.kind;

        switch (tokenKind) {
            .rightBrace => {
                if(topAst == &root) {
                    log.emit(.err, "U03", &next, "Invalid '}' no class or array to exit.", null);
                    errored.* = true;
                }
                topAst.bodyEndPos = next.pos;
                next = try l.next();

                if(next.kind != .semicolon) {
                    log.emit(.err, "U02", &next, "Expected ';' after right brace to end class segment.", null);
                    errored.* = true;
                    continue;
                }

                while (next.kind == .semicolon) next = try l.next();

                if(topAst.parent) |parent| {
                    try parent.members.?.append(allocator, .{ .class = topAst });
                    topAst = parent;
                }
                continue;
            },
            .deleteKeyword => parseDelete(allocator, &l, &next, &log, topAst) catch {
                errored.* = true;
                try synchronize(&l, &next);
                continue;
            },
            .classKeyword => {
                topAst = parseClass(allocator, &l, &next, &log, topAst) catch {
                    errored.* = true;
                    try synchronize(&l, &next);
                    continue;
                };
            },
            // .enumKeyword => try mergeEnum(allocator, io, store, srcHandle, &l, &next, &log),
            // .execKeyword => try mergeExex(log, l),
            .identifier => parseParameter(allocator, &l, &next, &log, topAst) catch {
                errored.* = true;
                try synchronize(&l, &next);
                continue;
            },
            else => {
                log.emit(.err, "U01", &next, "Unexpected token. Expected 'class', '__EXEC()', 'enum', 'delete' or parameter declaration.", null);
                errored.* = true;
                try synchronize(&l, &next);
                continue;
            }
        }
        next = try l.next();
    }

    return root;
}

fn parseDelete(allocator: Allocator, tokenizer: *lexer.Tokenizer, next: *lexer.Token, log: *const logger.DiagType, topAst: *ast.ClassAst) ParseError!void {
    next.* = try tokenizer.next();

    if(next.kind != TokenKind.identifier) {
        log.emit(.err, "D02", next, "Expected identifier after 'delete' keyword", null);
        return error.UnexpectedToken;
    }

    const name = next.data.text;

    next.* = try tokenizer.next();

    if(next.kind != TokenKind.semicolon) {
        log.emit(.err, "D03", next, "Expected ';' after delete declaration", null);
        return error.UnexpectedToken;
    }

    topAst.members.?.append(allocator, .{ .delete = name }) catch {
        log.emit(.err, "D04", next, "Failed to add delete declaration to AST stack", null);
        return error.ParseError;
    };
}

fn parseClass(allocator: Allocator, tokenizer: *lexer.Tokenizer, next: *lexer.Token, log: *const logger.DiagType, top: *ast.ClassAst) !*ast.ClassAst {
    next.* = try tokenizer.next();

    const heapClass = try allocator.create(ast.ClassAst);
    errdefer allocator.destroy(heapClass);

    heapClass.* = ast.ClassAst {
        .base     = null,
        .members  = null,
        .name     = null,
        .namePos = 0,
        .parent   = top,
    };

    if(next.kind != TokenKind.identifier) {
        log.emit(.err, "C02", next, "Expected identifier after 'class' keyword", null);
        return error.UnexpectedToken;
    } else {
        heapClass.name     = next.data.text;
        heapClass.namePos  = next.pos;
    }

    next.* = try tokenizer.next();

    switch (next.kind) {
        TokenKind.colon => {
            next.* = try tokenizer.next();
            heapClass.members = std.ArrayList(ast.MemberAst).empty;

            if(next.kind != .identifier) {
                log.emit(.err, "C04", next, "Expected identifier after ':' in class declaration", null);
                return error.UnexpectedToken;
            }

            heapClass.baseRefPos = next.pos;
            heapClass.base = top.find(next.data.text, true, true, false) orelse {
                log.emit(.err, "C06", next, "Undefined base class set.", null);
                next.* = try tokenizer.next();
                return error.ParseError;
            };

            next.* = try tokenizer.next();

            if(next.kind != .leftBrace) {
                log.emit(.err, "C04", next, "Expected  '{' after base class", null);
                return error.UnexpectedToken;
            }
        },
        TokenKind.semicolon => {
            top.members.?.append(allocator, .{ .class = heapClass }) catch {
                log.emit(.err, "C05", next, "Failed to add external class declaration to AST stack", null);
                return error.ParseError;
            };
            return top;
        },
        TokenKind.leftBrace => {
            heapClass.members = std.ArrayList(ast.MemberAst).empty;
        },
        else => {
            log.emit(.err, "C03", next, "Expected ':', '{' or a ';' after class name", null);
            return error.UnexpectedToken;
        }
    }

    return heapClass;
}

fn parseParameter(allocator: Allocator, tokenizer: *lexer.Tokenizer, next: *lexer.Token, log: *const logger.DiagType, top: *ast.ClassAst) !void{
    var astParam = ast.ParameterAst {
        .name     = next.data.text,
        .namePos = next.pos,
        .operator = undefined,
        .value    = undefined,
    };

    var elem_pos_list = std.ArrayList(u32).empty;

    next.* = try tokenizer.next();

    const isArray: bool = blk: {
        if (next.kind != TokenKind.leftBracket) {
            break :blk false;
        }

        next.* = try tokenizer.next();

        if (next.kind != TokenKind.rightBracket) {
            log.emit(.err, "P02", next, "Expected ']' after '[' in parameter declaration.", null);
            return error.UnexpectedToken;
        }
        next.* = try tokenizer.next();
        break :blk true;
    };

    astParam.operator = switch (next.kind) {
        TokenKind.equals => ast.OperatorAst.assign,
        TokenKind.addAssign => blk: {
            if(!isArray) {
                log.emit(.err, "P03", next, "'+=' operator is not valid for non-array parameters.", null);
                return error.UnexpectedToken;
            }
            break :blk ast.OperatorAst.addAssign;
        },
        TokenKind.subAssign => blk: {
            if(!isArray) {
                log.emit(.err, "P03", next, "'-=' operator is not valid for non-array parameters.", null);
                return error.UnexpectedToken;
            }
            break :blk ast.OperatorAst.subAssign;
        },
        else => {
            log.emit(.err, "P06", next, "Expected brackets or operation after parameter name.", null);
            return error.UnexpectedToken;
        }
    };

    next.* = try tokenizer.next();
    astParam.valuePos = next.pos;
    astParam.value = parseValue(allocator, tokenizer, log, next, &elem_pos_list) catch {
        log.emit(.err, "P01", next, "Expected value after operator in parameter declaration.", null);
        return error.ParseError;
    } orelse {
        log.emit(.err, "P01", next, "Expected value after operator in parameter declaration.", null);
        return error.UnexpectedToken;
    };

    if(isArray and astParam.value != .array) {
        log.emit(.err, "P01", next, "Expected array after operator in parameter declaration.", null);
        return error.UnexpectedToken;
    }
    const valueToken = next.*;
    next.* = try tokenizer.next();

    if(next.kind != TokenKind.semicolon) {
        log.emit(.err, "P04", &valueToken, "Expected ';' after value in parameter declaration.", null);
        return error.UnexpectedToken;
    }

    if (elem_pos_list.items.len > 0) {
        astParam.elemPositions = elem_pos_list.toOwnedSlice(allocator) catch null;
    }

    top.members.?.append(allocator, .{ .param = astParam }) catch {
        log.emit(.err, "P05", next, "Failed to add parameter declaration to AST stack", null);
        return error.ParseError;
    };
}


fn parseValue(allocator: Allocator, tokenizer: *lexer.Tokenizer, log: *const logger.DiagType, token: *lexer.Token, elem_positions: ?*std.ArrayList(u32)) !?ast.ValueAst {
    if (token.kind == .rightBrace) return null;
    return switch (token.kind) {
        TokenKind.leftBrace => try parseArray(allocator, tokenizer, log, token, elem_positions),
        TokenKind.floatLiteral => ast.ValueAst { .float = token.data.float },
        TokenKind.int64Literal => ast.ValueAst { .i64 = token.data.int64 },
        TokenKind.intLiteral => ast.ValueAst { .integer = token.data.int },
        TokenKind.expression => ast.ValueAst { .expression = token.data.text },
        TokenKind.stringLiteral => blk: {
            const str = switch (token.data) {
                .string => |s| blk2: {
                    if (s.needsUnescape) {
                        break :blk2 try lexer.Tokenizer.unescapeString(allocator, s.text);
                    }
                    break :blk2 try allocator.dupe(u8, s.text);
                },
                .text => |t| try allocator.dupe(u8, t),
                else => unreachable,
            };
            break :blk ast.ValueAst{ .string = str };
        },
        else => {
            log.emit(.err, "P01", token, "Expected value after operator in parameter declaration.", null);

            return error.UnexpectedToken;
        }
    };
}

fn parseArray(allocator: Allocator, tokenizer: *lexer.Tokenizer, log: *const logger.DiagType, start: *lexer.Token, elem_positions: ?*std.ArrayList(u32)) ParseError!ast.ValueAst {
    var values = std.ArrayList(ast.ValueAst).empty;
    errdefer {
        for (values.items) |*item| item.deinit(allocator);
    }
    defer values.deinit(allocator);

    var expectComma = false;
    start.* = try tokenizer.next();
    while (true) {
        if(expectComma) {
            switch (start.kind) {
                TokenKind.comma => {
                    expectComma = false;
                    start.* = try tokenizer.next();
                    continue;
                },
                TokenKind.rightBrace => break,
                else => {
                    log.emit(.err, "A01", start, "Expected ',' or '}' in array literal.", null);
                    return error.UnexpectedToken;
                }
            }
        } else {
            const elem_pos = start.pos;
            const val = try parseValue(allocator, tokenizer, log, start, null);
            if (val) |value| {
                if (elem_positions) |ep| ep.append(allocator, elem_pos) catch {};
                values.append(allocator, value) catch {
                    log.emit(.err, "A01", start, "Failed to add value to array literal.", null);
                    return error.ParseError;
                };
                expectComma = true;
                start.* = try tokenizer.next();
                continue;
            }

            break;
        }

    }
    return ast.ValueAst{ .array = try values.toOwnedSlice(allocator) };
}