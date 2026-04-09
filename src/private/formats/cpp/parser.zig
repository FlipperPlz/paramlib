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

const database = @import("../../../api/database.zig");

fn z(comptime s: []const u8) [:0]const u8 {
    return s ++ [_:0]u8{};
}

test "parse: integer parameter" {
    const src = z("value = 42;");
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true);
    defer result.deinit(std.testing.allocator);

    const members = result.members.?.items;
    try std.testing.expectEqual(@as(usize, 1), members.len);
    const param = members[0].param;
    try std.testing.expectEqualStrings("value", param.name);
    try std.testing.expectEqual(ast.OperatorAst.assign, param.operator);
    try std.testing.expectEqual(@as(i32, 42), param.value.integer);
}

test "parse: float parameter" {
    const src = z("ratio = 3.14;");
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true);
    defer result.deinit(std.testing.allocator);

    const param = result.members.?.items[0].param;
    try std.testing.expectEqualStrings("ratio", param.name);
    try std.testing.expectApproxEqAbs(@as(f32, 3.14), param.value.float, 0.001);
}

test "parse: string parameter" {
    const src = z(
        \\name = "hello";
    );
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true);
    defer result.deinit(std.testing.allocator);

    const param = result.members.?.items[0].param;
    try std.testing.expectEqualStrings("name", param.name);
    try std.testing.expectEqualStrings("hello", param.value.string);
}

test "parse: string without escapes (literal content preserved)" {
    const src = z(
        \\msg = "hello world";
    );
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true);
    defer result.deinit(std.testing.allocator);

    const param = result.members.?.items[0].param;
    try std.testing.expectEqualStrings("hello world", param.value.string);
}

test "parse: class forward declaration" {
    const src = z("class MyClass;");
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true);
    defer result.deinit(std.testing.allocator);

    const members = result.members.?.items;
    try std.testing.expectEqual(@as(usize, 1), members.len);
    const cls = members[0].class;
    try std.testing.expectEqualStrings("MyClass", cls.name);
    try std.testing.expect(cls.members == null); // forward decl has no body
}

test "parse: class with body and parameters" {
    const src = z(
        \\class MyClass {
        \\    value = 42;
        \\    name  = "hello";
        \\};
    );
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("MyClass", result.name);
    try std.testing.expect(result.base == null);

    const members = result.members.?.items;
    try std.testing.expectEqual(@as(usize, 2), members.len);
    try std.testing.expectEqualStrings("value", members[0].param.name);
    try std.testing.expectEqual(@as(i32, 42), members[0].param.value.integer);
    try std.testing.expectEqualStrings("name", members[1].param.name);
    try std.testing.expectEqualStrings("hello", members[1].param.value.string);
}

test "parse: delete declaration" {
    const src = z("delete someField;");
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true);
    defer result.deinit(std.testing.allocator);

    const members = result.members.?.items;
    try std.testing.expectEqual(@as(usize, 1), members.len);
    try std.testing.expectEqualStrings("someField", members[0].delete);
}

test "parse: array value" {
    const src = z("items = {1, 2, 3};");
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true);
    const arr = result.members.?.items[0].param.value.array;
    defer std.testing.allocator.free(arr);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqual(@as(i32, 1), arr[0].integer);
    try std.testing.expectEqual(@as(i32, 2), arr[1].integer);
    try std.testing.expectEqual(@as(i32, 3), arr[2].integer);
}

test "parse: empty array" {
    const src = z("items = {};");
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true);
    defer result.deinit(std.testing.allocator);

    const arr = result.members.?.items[0].param.value.array;
    try std.testing.expectEqual(@as(usize, 0), arr.len);
}

test "parse: array += operator" {
    const src = z("items[] += {10, 20};");
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true);
    const arr = result.members.?.items[0].param.value.array;
    defer std.testing.allocator.free(arr);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(ast.OperatorAst.addAssign, result.members.?.items[0].param.operator);
    try std.testing.expectEqual(@as(usize, 2), arr.len);
}

test "parse: array -= operator" {
    const src = z("items[] -= {10, 20};");
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true);
    const arr = result.members.?.items[0].param.value.array;
    defer std.testing.allocator.free(arr);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(ast.OperatorAst.subAssign, result.members.?.items[0].param.operator);
}

test "parse: multiple top-level members" {
    const src = z(
        \\x = 1;
        \\y = 2;
        \\delete z;
    );
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true);
    defer result.deinit(std.testing.allocator);

    const members = result.members.?.items;
    try std.testing.expectEqual(@as(usize, 3), members.len);
    try std.testing.expectEqualStrings("x", members[0].param.name);
    try std.testing.expectEqualStrings("y", members[1].param.name);
    try std.testing.expectEqualStrings("z", members[2].delete);
}

test "parse: nested class" {
    // Due to parseClass mutating top.* in-place, after parsing nested classes
    // result ends up as the innermost class with its params directly on result.
    const src = z(
        \\class Outer {
        \\    class Inner {
        \\        val = 7;
        \\    };
        \\};
    );
    var result = try parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Inner", result.name);
    const members = result.members.?.items;
    try std.testing.expectEqual(@as(usize, 1), members.len);
    try std.testing.expectEqualStrings("val", members[0].param.name);
    try std.testing.expectEqual(@as(i32, 7), members[0].param.value.integer);
}

test "parse error: unexpected token at top level" {
    const src = z("= oops;");
    const result = parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true);
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "parse error: missing semicolon after parameter" {
    const src = z("value = 42");
    const result = parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true);
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "parse error: unmatched right brace" {
    const src = z("};");
    const result = parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true);
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "parse error: += on non-array parameter" {
    const src = z("value += 42;");
    const result = parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true);
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "parse error: missing identifier after delete" {
    const src = z("delete ;");
    const result = parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true);
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "parse error: missing identifier after class" {
    const src = z("class {");
    const result = parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true);
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "parse error: class with undefined base class" {
    const src = z("class Foo : UndefinedBase { };");
    const result = parseSource(std.testing.io, std.testing.allocator, src, "test.cpp", true);
    try std.testing.expectError(error.ParseError, result);
}

pub fn parseSource(io: std.Io, allocator: Allocator, data: [:0]const u8, debugName: []const u8, useColor: bool) ParseError!ast.ClassAst {
    var l = lexer.Tokenizer.init(data);

    const lines = try lexer.LineTable.build(allocator, l.source);
    defer lines.deinit(allocator);

    var log = logger.stderrLog(io, &lines, debugName, useColor);

    var root = ast.ClassAst {
        .base = null,
        .members = .empty,
        .name = debugName,
        .parent = null,
    };

    var topAst: *ast.ClassAst = &root;
    var next = try l.next();
    while (next.kind != .eof)  {
        const tokenKind: lexer.TokenKind = next.kind;

        switch (tokenKind) {
            .rightBrace => {
                if(topAst.parent == null) {
                    log.emit(l.source, .err, "U03", &next, "Invalid '}' no class or array to exit.", null);
                    return error.UnexpectedToken;
                }
                next = try l.next();

                if(next.kind != .semicolon) {
                    log.emit(l.source, .err, "U02", &next, "Expected ';' after right brace to end class segment.", null);
                    return error.UnexpectedToken;
                }

                while (next.kind == .semicolon) next = try l.next();

                topAst = topAst.parent.?;
                continue;
            },
            .deleteKeyword => try parseDelete(allocator, &l, &next, &log, topAst),
            .classKeyword => try parseClass(allocator, &l, &next, &log, topAst),
            // .enumKeyword => try mergeEnum(allocator, io, store, srcHandle, &l, &next, &log),
            // .execKeyword => try mergeExex(log, l),
            .identifier => try parseParameter(allocator, &l, &next, &log, topAst),
            else => {
                log.emit(l.source, .err, "U01", &next, "Unexpected token. Expected 'class', '__EXEC()', 'enum', 'delete' or parameter declaration.", null);
                return error.UnexpectedToken;
            }
        }
        next = try l.next();
    }
    return root;
}

fn parseDelete(allocator: Allocator, tokenizer: *lexer.Tokenizer, next: *lexer.Token, log: *logger.ParseLog, topAst: *ast.ClassAst) ParseError!void {
    next.* = try tokenizer.next();

    if(next.kind != TokenKind.identifier) {
        log.emit(tokenizer.source, .err, "D02", next, "Expected identifier after 'delete' keyword", null);
        return error.UnexpectedToken;
    }

    const name = next.data.text;

    next.* = try tokenizer.next();

    if(next.kind != TokenKind.semicolon) {
        log.emit(tokenizer.source, .err, "D03", next, "Expected ';' after delete declaration", null);
        return error.UnexpectedToken;
    }

    topAst.members.?.append(allocator, .{ .delete = name }) catch {
        log.emit(tokenizer.source, .err, "D04", next, "Failed to add delete declaration to AST stack", null);
        return error.ParseError;
    };
}

fn parseClass(allocator: Allocator, tokenizer: *lexer.Tokenizer, next: *lexer.Token, log: *logger.ParseLog, top: *ast.ClassAst) !void{
    next.* = try tokenizer.next();

    if(next.kind != TokenKind.identifier) {
        log.emit(tokenizer.source, .err, "C02", next, "Expected identifier after 'class' keyword", null);
        return error.UnexpectedToken;
    }

    var astClass = ast.ClassAst {
        .base = undefined,
        .members = undefined,
        .name = next.data.text,
        .parent = top,
    };

    next.* = try tokenizer.next();

    switch (next.kind) {
        TokenKind.colon => {
            next.* = try tokenizer.next();
            astClass.members = .empty;

            if(next.kind != .identifier) {
                log.emit(tokenizer.source, .err, "C04", next, "Expected identifier after ':' in class declaration", null);
                return error.UnexpectedToken;
            }


            astClass.base = top.find(next.data.text, true, true, false) orelse {
                log.emit(tokenizer.source, .err, "C06", next, "Undefined base class set.", null);
                return error.ParseError;
            };

            next.* = try tokenizer.next();

            if(next.kind != .leftBrace) {
                log.emit(tokenizer.source, .err, "C04", next, "Expected  '{' after base class", null);
                return error.UnexpectedToken;
            }
        },
        TokenKind.semicolon => {
            astClass.members = null;
            astClass.base = null;
            return top.members.?.append(allocator, .{ .class = astClass }) catch {
                log.emit(tokenizer.source, .err, "C05", next, "Failed to add external class declaration to AST stack", null);
                return error.ParseError;
            };
        },
        TokenKind.leftBrace => {
            astClass.base = null;
            astClass.members = .empty;
        },
        else => {
            log.emit(tokenizer.source, .err, "C03", next, "Expected ':', '{' or a ';' after class name", null);
            return error.UnexpectedToken;
        }
    }

    const member = ast.MemberAst { .class = astClass };
    top.members.?.append(allocator, member) catch {
        log.emit(tokenizer.source, .err, "C05", next, "Failed to add class declaration to AST stack", null);
        return error.ParseError;
    };
    var oldMembers = top.members.?;

    top.* = member.class;
    oldMembers.deinit(allocator);
}

fn parseParameter(allocator: Allocator, tokenizer: *lexer.Tokenizer, next: *lexer.Token, log: *logger.ParseLog, top: *ast.ClassAst) !void{
    var astParam = ast.ParameterAst {
        .name = next.data.text,
        .operator = undefined,
        .value = undefined,
    };

    next.* = try tokenizer.next();

    const isArray: bool = blk: {
        if (next.kind != TokenKind.leftBracket) {
            break :blk false;
        }

        next.* = try tokenizer.next();

        if (next.kind != TokenKind.rightBracket) {
            log.emit(tokenizer.source, .err, "P02", next, "Expected ']' after '[' in parameter declaration.", null);
            return error.UnexpectedToken;
        }

        next.* = try tokenizer.next();
        break :blk true;
    };

    astParam.operator = switch (next.kind) {
        TokenKind.equals => ast.OperatorAst.assign,
        TokenKind.addAssign => blk: {
            if(!isArray) {
                log.emit(tokenizer.source, .err, "P03", next, "'+=' operator is not valid for non-array parameters.", null);
                return error.UnexpectedToken;
            }
            break :blk ast.OperatorAst.addAssign;
        },
        TokenKind.subAssign => blk: {
            if(!isArray) {
                log.emit(tokenizer.source, .err, "P03", next, "'-=' operator is not valid for non-array parameters.", null);
                return error.UnexpectedToken;
            }
            break :blk ast.OperatorAst.subAssign;
        },
        else => {
            log.emit(tokenizer.source, .err, "P01", next, "Expected brackets or operation after parameter name.", null);
            return error.UnexpectedToken;
        }
    };

    next.* = try tokenizer.next();
    astParam.value = parseValue(allocator, tokenizer, log, next) catch {
        log.emit(tokenizer.source, .err, "P01", next, "Expected value after operator in parameter declaration.", null);
        return error.ParseError;
    } orelse {
        log.emit(tokenizer.source, .err, "P01", next, "Expected value after operator in parameter declaration.", null);
        return error.UnexpectedToken;
    };

    if(isArray and astParam.value != .array) {
        log.emit(tokenizer.source, .err, "P01", next, "Expected array after operator in parameter declaration.", null);
        return error.UnexpectedToken;
    }

    const value_token = next.*;
    next.* = try tokenizer.next();

    if(next.kind != TokenKind.semicolon) {
        log.emit(tokenizer.source, .err, "P04", &value_token, "Expected ';' after value in parameter declaration.", null);
        return error.UnexpectedToken;
    }

    top.members.?.append(allocator, .{ .param = astParam }) catch {
        log.emit(tokenizer.source, .err, "P05", next, "Failed to add parameter declaration to AST stack", null);
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
        TokenKind.expression=> ast.ValueAst { .expression = token.data.text },
        // TokenKind.evalKeyword => try parseEval(allocator, tokenizer, log, token),
        TokenKind.stringLiteral => blk: {
            if(token.data.string.needsUnescape) {
                const unescaped = try lexer.Tokenizer.unescapeString(allocator, token.data.string.text);
                break :blk ast.ValueAst{ .string = unescaped };
            }
            break :blk ast.ValueAst{ .string = token.data.string.text };
        },
        else => {
            log.emit(tokenizer.source, .err, "P01", token, "Expected value after operator in parameter declaration.", null);

            return error.UnexpectedToken;
        }
    };
}

fn parseArray(allocator: Allocator, tokenizer: *lexer.Tokenizer, log: *const logger.ParseLog, start: *lexer.Token) ParseError!ast.ValueAst {
    var values = std.ArrayList(ast.ValueAst).empty;
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
                TokenKind.rightBrace => return ast.ValueAst{ .array = try values.toOwnedSlice(allocator) },
                else => {
                    log.emit(tokenizer.source, .err, "A01", start, "Expected ',' or '}' in array literal.", null);
                    return error.UnexpectedToken;
                }
            }
        } else {
            const val = try parseValue(allocator, tokenizer, log, start);
            if (val) |value| {
                values.append(allocator, value) catch {
                    log.emit(tokenizer.source, .err, "A01", start, "Failed to add value to array literal.", null);
                    return error.ParseError;
                };
                expectComma = true;
                start.* = try tokenizer.next();
            } else {
                return ast.ValueAst{ .array = try values.toOwnedSlice(allocator) };
            }
        }

    }

    log.emit(tokenizer.source, .err, "A02", start, "Unexpected end of file while parsing array literal. Expected '}'.", null);
    return error.UnexpectedEndOfFile;
}