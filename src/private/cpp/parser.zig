const std = @import("std");
const Allocator = std.mem.Allocator;
const TokenKind = lexer.TokenKind;
const lexer = @import("./lexer.zig");
const logger = @import("utils/log.zig");
const ast = @import("ast.zig");

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

const database = @import("../../api/database.zig");

fn z(comptime s: []const u8) [:0]const u8 {
    return s ++ [_:0]u8{};
}

test "parse: integer parameter" {
    const src = z("value = 42;");
    var errored: bool = false;
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true, &errored);
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

    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true, &errored);
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

    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true, &errored);
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

    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true, &errored);
    defer result.deinit(std.testing.allocator);

    const param = result.members.?.items[0].param;
    try std.testing.expectEqualStrings("hello world", param.value.string);
    try std.testing.expect(!errored);

}

test "parse: class forward declaration" {
    const src = z("class MyClass;");
    var errored: bool = false;
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true, &errored);
    defer result.deinit(std.testing.allocator);

    const members = result.members.?.items;
    try std.testing.expectEqual(@as(usize, 1), members.len);
    const cls = members[0].class;
    try std.testing.expectEqualStrings("MyClass", cls.name.?);
    try std.testing.expect(cls.members == null); // forward decl has no body
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

    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true, &errored);
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

    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true, &errored);
    defer result.deinit(std.testing.allocator);

    const members = result.members.?.items;
    try std.testing.expectEqual(@as(usize, 1), members.len);
    try std.testing.expectEqualStrings("someField", members[0].delete.?);
    try std.testing.expect(!errored);

}

test "parse: array value" {
    const src = z("items = {1, 2, 3};");
    var errored: bool = false;

    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true, &errored);
    const arr = result.members.?.items[0].param.value.array;
    defer std.testing.allocator.free(arr);
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

    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true, &errored);
    defer result.deinit(std.testing.allocator);

    const arr = result.members.?.items[0].param.value.array;
    try std.testing.expectEqual(@as(usize, 0), arr.len);
    try std.testing.expect(!errored);

}

test "parse: array += operator" {
    const src = z("items[] += {10, 20};");
    var errored: bool = false;

    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true, &errored);
    const arr = result.members.?.items[0].param.value.array;
    defer std.testing.allocator.free(arr);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(ast.OperatorAst.addAssign, result.members.?.items[0].param.operator);
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expect(!errored);

}

test "parse: array -= operator" {
    const src = z("items[] -= {10, 20};");
    var errored: bool = false;
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true, &errored);
    const arr = result.members.?.items[0].param.value.array;
    defer std.testing.allocator.free(arr);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!errored);

    try std.testing.expectEqual(ast.OperatorAst.subAssign, result.members.?.items[0].param.operator);
}

test "parse: multiple top-level members" {
    const src = z(
        \\x = 1;
        \\y = 2;
        \\delete z;
    );
    var errored: bool = false;

    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true, &errored);
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
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true, &errored);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(errored);
    try std.testing.expectEqual(@as(usize, 0), result.members.?.items.len);
}

test "parse error: missing semicolon after parameter" {
    const src = z("value = 42");
    var errored: bool = false;
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true, &errored);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(errored);
    try std.testing.expectEqual(@as(usize, 0), result.members.?.items.len);
}

test "parse error: unmatched right brace" {
    const src = z("};");
    var errored: bool = false;
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true, &errored);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(errored);
    try std.testing.expectEqual(@as(usize, 0), result.members.?.items.len);
}

test "parse error: += on non-array parameter" {
    const src = z("value += 42;");
    var errored: bool = false;
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true, &errored);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(errored);
    try std.testing.expectEqual(@as(usize, 0), result.members.?.items.len);
}

test "parse error: missing identifier after delete" {
    const src = z("delete ;");
    var errored: bool = false;
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true, &errored);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(errored);
    try std.testing.expectEqual(@as(usize, 0), result.members.?.items.len);
}

test "parse error: missing identifier after class" {
    const src = z("class {");
    var errored: bool = false;
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true, &errored);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(errored);
    try std.testing.expectEqual(@as(usize, 0), result.members.?.items.len);
}

test "parse error: class with undefined base class" {
    const src = z("class Foo : UndefinedBase { };");
    var errored: bool = false;
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true, &errored);
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
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true, &errored);
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
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true, &errored);
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

pub fn parseSource(io: std.Io, allocator: Allocator, data: [:0]const u8, debugName: []const u8, useColor: bool, errored: *bool) ParseError!ast.ClassAst {
    return parseSourceFull(io, allocator, data, debugName, useColor, errored, null);
}

pub fn parseSourceFull(io: std.Io, allocator: Allocator, data: [:0]const u8, debugName: []const u8, useColor: bool, errored: *bool, diag_sink: ?logger.DiagSink) ParseError!ast.ClassAst {
    var l = lexer.Tokenizer.init(data);

    const lines = try lexer.LineTable.build(allocator, l.source);
    defer lines.deinit(allocator);

    var log = logger.stderrLog(io, &lines, l.source, debugName, useColor);
    log.diag_sink = diag_sink;

    var root = ast.ClassAst {
        .base     = null,
        .members  = .empty,
        .name     = debugName,
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
                    try parent.members.?.append(allocator, .{ .class = topAst.* });
                    allocator.destroy(topAst);
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

fn parseDelete(allocator: Allocator, tokenizer: *lexer.Tokenizer, next: *lexer.Token, log: *logger.ParseLog, topAst: *ast.ClassAst) ParseError!void {
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

fn parseClass(allocator: Allocator, tokenizer: *lexer.Tokenizer, next: *lexer.Token, log: *logger.ParseLog, top: *ast.ClassAst) !*ast.ClassAst {
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
            heapClass.members = .empty;

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
            defer allocator.destroy(heapClass);
            top.members.?.append(allocator, .{ .class = heapClass.* }) catch {
                log.emit(.err, "C05", next, "Failed to add external class declaration to AST stack", null);
                return error.ParseError;
            };
            return top;
        },
        TokenKind.leftBrace => {
            heapClass.members = .empty;
        },
        else => {
            log.emit(.err, "C03", next, "Expected ':', '{' or a ';' after class name", null);
            return error.UnexpectedToken;
        }
    }

    return heapClass;
}

fn parseParameter(allocator: Allocator, tokenizer: *lexer.Tokenizer, next: *lexer.Token, log: *logger.ParseLog, top: *ast.ClassAst) !void{
    var astParam = ast.ParameterAst {
        .name     = next.data.text,
        .namePos = next.pos,
        .operator = undefined,
        .value    = undefined,
    };

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
    astParam.value = parseValue(allocator, tokenizer, log, next) catch {
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

    top.members.?.append(allocator, .{ .param = astParam }) catch {
        log.emit(.err, "P05", next, "Failed to add parameter declaration to AST stack", null);
        return error.ParseError;
    };
}


fn parseValue(allocator: Allocator, tokenizer: *lexer.Tokenizer, log: *const logger.ParseLog, token: *lexer.Token) !?ast.ValueAst {
    if (token.kind == .rightBrace) return null;
    return switch (token.kind) {
        TokenKind.leftBrace => try parseArray(allocator, tokenizer, log, token),
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
                    break :blk2 s.text;
                },
                .text => |t| t,
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

fn freeValue(allocator: Allocator, value: ast.ValueAst) void {
    switch (value) {
        .string => |s| allocator.free(s),
        .array => |a| {
            for (a) |item| freeValue(allocator, item);
            allocator.free(a);
        },
        else => {},
    }
}

fn parseArray(allocator: Allocator, tokenizer: *lexer.Tokenizer, log: *const logger.ParseLog, start: *lexer.Token) ParseError!ast.ValueAst {
    var values = std.ArrayList(ast.ValueAst).empty;
    errdefer {
        for (values.items) |item| freeValue(allocator, item);
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
            const val = try parseValue(allocator, tokenizer, log, start);
            if (val) |value| {
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