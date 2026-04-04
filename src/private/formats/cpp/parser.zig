const std = @import("std");
const Allocator = std.mem.Allocator;
const TokenKind = lexer.TokenKind;
const lexer = @import("./lexer.zig");
const logger = @import("utils/log.zig");
const source = @import("../../slabs/source.zig");
const storage = @import("../../data/storage.zig");
const class = @import("../../slabs/class.zig");
const query = @import("../../tree/query.zig");
const hasher = @import("../../utils/hasher.zig");
const factory = @import("../../tree/factory.zig");
const value = @import("../../data/value.zig");
const params = @import("../../slabs/parameter.zig");
const paths = @import("../../utils/paths.zig");
const array = @import("../../slabs/array.zig");

const ParseError = error{
    UnexpectedToken,
    ParseError,
    UnexpectedEndOfFile,
    OutOfMemory,
    NotImplemented,

    UnterminatedString,
    InvalidEscape,
    UnterminatedComment,
    Overflow,
};


pub fn mergeSource(io: std.Io, allocator: Allocator, store: *storage.ParamAllocator, parent: class.ClassHandle, srcHandle: source.SourceHandle, useColor: bool) !void {
    const src: *source.SourceData = srcHandle.validateHandle(store).ptr;

    const sourceContents = src.read(store, allocator, io);
    defer allocator.free(sourceContents);

    var l = lexer.Tokenizer.init(sourceContents);

    const lines = try lexer.LineTable.build(allocator, sourceContents);
    defer lines.deinit(allocator);

    const log = logger.stderrLog(io, &lines, src.name, useColor);

    var topHandle = parent;
    var next = try l.next();
    while (next.kind != .eof)  {
        const tokenKind: lexer.TokenKind = next.kind;

        switch (tokenKind) {
            .rightBrace => {
                if(topHandle.eql(parent)) {
                    log.emit(sourceContents, .err, "U03", next, "Invalid '}' no class or array to exit.", null);
                    return error.UnexpectedToken;
                }
                next = try l.next();

                if(next.kind != .semicolon) {
                    log.emit(sourceContents, .err, "U02", next, "Expected ';' after right brace to end class segment.", null);
                    return error.UnexpectedToken;
                }

                while (next.kind == .semicolon) next = try l.next();

                const top: *const class.ClassData = topHandle.validateHandle(store).ptr;
                topHandle = top.parent;
                continue;
            },
            .deleteKeyword => try mergeDelete(allocator, store, &l, &next, &log, &topHandle),
            .classKeyword => try mergeClass(allocator, io, store, srcHandle, &l, &next, &log, &topHandle),
            .enumKeyword => try mergeEnum(allocator, store, srcHandle, &l, &next, &log, &topHandle),
            // .execKeyword => try mergeExex(log, l),
            .identifier => try mergeParameter(allocator, io, store, srcHandle, &l, &next, &log, topHandle),
            else => {
                log.emit(sourceContents, .err, "U01", next, "Unexpected token. Expected 'class', 'enum', 'delete' or parameter declaration.", null);
                return error.UnexpectedToken;
            }
        }
        next = try l.next();
    }
}

fn mergeParameter(
    allocator: Allocator,
    io: std.Io,
    store: *storage.ParamAllocator,
    srcHandle: source.SourceHandle,
    tokenizer: *lexer.Tokenizer,
    keyword_token: *lexer.Token,
    log: *const logger.ParseLog,
    top: *class.ClassHandle,
) !void {
    const paramName = keyword_token.data.text;
    const internedName = store.alloc(allocator, undefined, paths.SegmentInit.create(paramName));

    const paramHash = hasher.hash(internedName.ptr);
    const parent: *const class.ClassData = top.validateHandle(store).ptr;

    const pathHash = paths.getPathHash(parent.pathHash, internedName.ptr);
    const param = try factory.getOrCreateParameter(allocator, io, store, params.ParameterInit {
        .name = paramName,
        .nameHash = paramHash,
        .parent = top,
        .source = srcHandle,
        .pathHash = pathHash,
        .nameIdx = internedName.index,
        .value = undefined
    });
    errdefer store.free(allocator, param.id);

    const parameterHandle = params.ParameterHandle {
        .generation = param.ptr.generation,
        .id = param.id
    };

    keyword_token.* = try tokenizer.next();

    const isArray: bool = blk: {
        if(keyword_token.kind != TokenKind.leftBracket) {
            break :blk false;
        }

        keyword_token.* = try tokenizer.next();

        if(keyword_token.kind != .rightBracket) {
            log.emit(tokenizer.source, .err, "P01", keyword_token.*, "Expected ']' after '[' in parameter declaration.", null);
            return error.UnexpectedToken;
        }

        keyword_token.* = try tokenizer.next();
        break :blk true;
    };

    const operator = switch (keyword_token.kind) {
        TokenKind.equals => 0,
        TokenKind.addAssign => blk: {
            if(!isArray) {
                log.emit(tokenizer.source, .err, "P03", keyword_token.*, "'+=' operator is not valid for non-array parameters.", null);
                return error.UnexpectedToken;
            }
            break :blk 1;
        },
        TokenKind.subAssign => blk: {
            if(!isArray) {
                log.emit(tokenizer.source, .err, "P03", keyword_token.*, "'-=' operator is not valid for non-array parameters.", null);
                return error.UnexpectedToken;
            }
            break :blk 2;
        },
        else => {
            log.emit(tokenizer.source, .err, "P03", keyword_token.*, "Expected brackets or operation after parameter name.", null);
            return error.UnexpectedToken;
        }
    };
    keyword_token.* = try tokenizer.next();
    const found = try parseValue(allocator, io, store, srcHandle, tokenizer, keyword_token, parameterHandle, isArray, log) orelse {
        log.emit(tokenizer.source, .err, "P04", keyword_token.*, "Invalid '}' expexted value for parameter.", null);
        return error.UnexpectedToken;
    };
    const paramPtr: *params.ParameterData = try param.ptr.toMutable(store);

    switch (operator) {
        0 => paramPtr.value = found,
        1 => return error.NotImplemented,
        2 => return error.NotImplemented
    }

}

fn parseValue(
    allocator: Allocator,
    io: std.Io,
    store: *storage.ParamAllocator,
    srcHandle: *source.SourceHandle,
    tokenizer: *lexer.Tokenizer,
    token: *lexer.Token,
    parameter: params.ParameterHandle,
    allowArray: bool,
    log: *const logger.ParseLog,
) !?value.Value {
    return switch (token.kind) {
        .leftBrace and allowArray => try parseArray(allocator, io, store, srcHandle, tokenizer, parameter, token, log),
        .rightBrace => null,
        .floatLiteral => value.Value.initF32(token.data.float),
        .int64Literal => value.Value.initI64(token.data.int64),
        .intLiteral => value.Value.initI32(token.data.int),
        .stringLiteral => {},
        .expression => return error.NotImplemented,
        else => {
            log.emit(tokenizer.source, .err, "PV01", token.*, "Expected value after operator in parameter declaration.", null);
            return error.UnexpectedToken;
        }
    };
}

fn parseArray(
    allocator: Allocator,
    io: std.Io,
    store: *storage.ParamAllocator,
    srcHandle: *source.SourceHandle,
    tokenizer: *lexer.Tokenizer,
    token: *lexer.Token,
    parameter: params.ParameterHandle,
    parentArray: ?array.ArrayHandle,
    log: *const logger.ParseLog,
) !value.Value {
    const arr = try store.alloc(allocator, io, array.ArrayInit {
        .parentParam = parameter,
        .source = srcHandle,
        .parentArray = parentArray,
        .values = undefined
    });

    var expectComma = false;
    token.* = try tokenizer.next();

    while (true) {
        if(expectComma) { switch (token.kind) {
            TokenKind.comma => {
                expectComma = false;
                token.* = try tokenizer.next();
                continue;
            },
            TokenKind.rightBrace => {

            },
            else => {
                log.emit(tokenizer.source, .err, "A01", token, "Expected ',' or '}' in array literal.", null);
                return error.UnexpectedToken;
            }
        }}

        if (try parseValue(allocator, io, store, srcHandle, tokenizer, token, parameter, true, log)) |val| {
            _ = val;
            //todo add to array
            expectComma = true;
        } else {
            return value.Value.initArray(arr.index);
        }
    }
}

fn mergeEnum(
    allocator: Allocator,
    io: std.Io,
    store: *storage.ParamAllocator,
    srcHandle: source.SourceHandle,
    tokenizer: *lexer.Tokenizer,
    keyword_token: *lexer.Token,
    log: *const logger.ParseLog,
) !void {
    keyword_token.* = try tokenizer.next();

    if(keyword_token.kind == TokenKind.identifier) {
        log.emit(tokenizer.source, .hint, "EH01", keyword_token, "Enum names are ignored.", null);
        keyword_token.* = try tokenizer.next();
    }

    if(keyword_token.kind != .leftBrace) {
        log.emit(tokenizer.source, .err, "E01", keyword_token, "Invalid '}' no class or array to exit.", null);
        return error.UnexpectedToken;
    }
    //
    // var enumValue: i32 = 0;
    while (true) {
        keyword_token.* = try tokenizer.next();

        if(keyword_token.kind != TokenKind.identifier) {
            log.emit(tokenizer.source, .err, "E02", keyword_token, "Expected enum value name", null);
            return error.UnexpectedToken;
        }

        _ = keyword_token.data.text;
        //TODO: evaluator
        keyword_token.* = try tokenizer.next();
        _ = allocator;
        _ = io;
        _ = store;
        _ = srcHandle;
        if(keyword_token.kind != .comma) break;
    }
}

fn mergeClass(
    allocator: Allocator,
    io: std.Io,
    store: *storage.ParamAllocator,
    srcHandle: source.SourceHandle,
    tokenizer: *lexer.Tokenizer,
    keyword_token: *lexer.Token,
    log: *const logger.ParseLog,
    top: *class.ClassHandle
) !void {
    keyword_token.* = try tokenizer.next();

    if(keyword_token.kind == TokenKind.identifier) {
        log.emit(tokenizer.source, .hint, "C02", keyword_token, "Expected identifier after 'class' keyword", null);
        return error.UnexpectedToken;
    }

    const classname = keyword_token.text();

    keyword_token.* = try tokenizer.next();

    var base = null;
    switch (keyword_token.kind) {
        TokenKind.colon => {
            keyword_token.* = try tokenizer.next();

            if(keyword_token.kind != .identifier) {
                log.emit(tokenizer.source, .err, "C04", keyword_token, "Expected identifier after ':' in class declaration", null);
                return error.UnexpectedToken;
            }

            base = try query.findClassByNameHash(store, top, hasher.hash(keyword_token.data.text));

            keyword_token.* = try tokenizer.next();

            if(keyword_token.kind != .leftBrace) {
                log.emit(tokenizer.source, .err, "C04", keyword_token, "Expected  '{' after base class", null);
                return error.UnexpectedToken;
            }
            if (base) | b | {
                const baseClass: *class.ClassData = b.validateHandle(store).ptr.getMutable(store);
                _ = baseClass;
                //todo check modified by / make sure this source defined it somehow
            } else {
                log.emit(tokenizer.source, .err, "C04", keyword_token, "Cannot locate base.", null);
                return error.UnknownBase;
            }
        },
        TokenKind.semicolon => {
            _ = factory.getOrCreateClass(allocator, io, store, .{
                .source = srcHandle,
                .name = classname,
                .parent = top,
            }) catch {
                log.emit(tokenizer.source, .err, "C05", keyword_token, "Failed to add external class declaration to AST stack", null);
                return error.ParseError;
            };
            return;
        },
        TokenKind.leftBrace => {
            class.base = null;
        },
        else => {
            log.emit(tokenizer.source, .err, "C03", keyword_token, "Expected ':', '{' or a ';' after class name", null);
            return error.UnexpectedToken;
        }
    }
    top.* = factory.createClass(allocator, io, store, .{
        .name = classname,
        .source = srcHandle,
        .parent = top,
        .base = base
    });
    return;
}

fn mergeDelete(
    allocator: Allocator,
    store: *storage.ParamAllocator,
    tokenizer: *lexer.Tokenizer,
    keyword_token: *lexer.Token,
    log: *const logger.ParseLog,
    top: *class.ClassHandle
) !void {
    keyword_token.* = try tokenizer.next();

    if(keyword_token.kind != TokenKind.identifier) {
        log.emit(tokenizer.source, .err, "D01", keyword_token, "Expected identifier after 'delete' keyword", null);
        return error.UnexpectedToken;
    }

    const target = keyword_token.data.text;
    const targetHandle = try query.findClassByNameHash(store, top, hasher.hash(target)) orelse {
        log.emit(tokenizer.source, .err, "D02", keyword_token, "Expected target for delete statement. Not Found.", null);
        return error.UnknownTarget;
    };

    keyword_token.* = try tokenizer.next();
    if(keyword_token.kind != .semicolon) {
        log.emit(tokenizer.source, .err, "D03", keyword_token, "Expected ';' after right brace to end delete statement.", null);
        return error.UnexpectedToken;
    }
    //TODO: access
    factory.deleteClass(allocator, store, targetHandle) catch {
        log.emit(tokenizer.source, .err, "D04", keyword_token, "Failed to delete target, on merge", null);
        return error.UnexpectedToken;
    };
}
