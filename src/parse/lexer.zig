const std = @import("std");
const SourcePosition = @import("position.zig").SourcePosition;
const ClassDefinition = @import("parser.zig").ClassDefinition;

pub fn skipWhitespace(input: []const u8, pos: *SourcePosition) void {
    while (pos.index < input.len) {
        const c = input[pos.index];
        if (c == '\n') {
            pos.line += 1;
            pos.index += 1;
            pos.line_start = pos.index;
        } else if (std.ascii.isWhitespace(c)) {
            pos.index += 1;
        } else {
            break;
        }
    }
}

pub fn getAlphaWord(input: []const u8, pos: *SourcePosition) []const u8 {
    skipWhitespace(input, pos);

    const word_start = pos.index;

    while (pos.index < input.len) {
        const c = input[pos.index];
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) {
            break;
        }
        pos.index += 1;
    }

    return input[word_start..pos.index];
}

pub fn getUnquotedSlice(input: []const u8, pos: *SourcePosition, terminators: []const u8,) []const u8 {
    skipWhitespace(input, pos);
    const start = pos.index;

    while (pos.index < input.len) {
        const c = input[pos.index];
        if (std.mem.indexOfScalar(u8, terminators, c) != null) break;
        if (c == '\n') {
            pos.line += 1;
            pos.index += 1;
            pos.line_start = pos.index;
            break;
        } else if (c == '\r') {
            pos.index += 1;
            break;
        } else {
            pos.index += 1;
        }
    }

    return input[start..pos.index];
}

pub fn getWord( input: []const u8, src_name: []const u8, pos: *SourcePosition, terminators: []const u8, found_quote: ?*bool, allocator: std.mem.Allocator) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    skipWhitespace(input, pos);

    if (input[pos.index] == '"') {
        pos.index += 1;
        if(found_quote) found_quote.* = true;

        while (pos.index < input.len) {
            const c = input[pos.index];
            if (c == '"') {
                pos.index += 1;
                if (pos.index < input.len and input[pos.index] != '"') {
                    skipWhitespace(input, pos);

                    if (pos.index < input.len and input[pos.index] != '\\') {
                        return try result.toOwnedSlice(allocator);
                    }
                    pos.index += 1;
                    if (pos.index < input.len and input[pos.index] != 'n') {
                        std.log.warn("[{s}] Error at line {}, col {}: invalid escape sequence", .{
                            src_name,
                            pos.line,
                            pos.index - pos.line_start,
                        });
                        return error.SyntaxError;
                    }
                    skipWhitespace(input, pos);

                    if (pos.index < input.len and input[pos.index] != '"') {
                        std.log.warn("[{s}] Error at line {}, col {}: expected '\"' after escape sequence", .{
                            src_name,
                            pos.line,
                            pos.index - pos.line_start,
                        });
                        return error.SyntaxError;
                    }

                    pos.index += 1;
                    try result.append(allocator, '\n');
                } else {
                    pos.index += 1;
                    try result.append(allocator, '"');
                }
            } else {
                if (c == '\n' or c == '\r') {
                    std.log.warn("[{s}] Error at line {}, col {}: End of line encountered", .{
                        src_name,
                        pos.line,
                        pos.index - pos.line_start,
                    });
                    return error.SyntaxError;
                }
                try result.append(allocator, c);
                pos.index += 1;
                continue;
            }
        }
        std.log.warn("[{s}] Error at line {}, col {}: unterminated string literal", .{
            src_name,
            pos.line,
            pos.index - pos.line_start,
        });
        return error.SyntaxError;
    } else {
        if(found_quote) found_quote.* = false;
        var c = input[pos.index];
        while (pos.index < input.len and std.mem.indexOfScalar(u8, terminators, c) == null) {
            if (c == '\n' or c == '\r') {
                while (true) {
                    skipWhitespace(input, pos);
                    if (input[pos.index] != '#') {
                        break;
                    }
                    std.log.warn("[{s}] Error at line {}, col {}: Directives not implemented", .{
                        src_name,
                        pos.line,
                        pos.index - pos.line_start,
                    });
                    return error.NotImplemented;
                }
                c = input[pos.index];
                if (std.mem.indexOfScalar(u8, terminators, c) == null) {
                    std.log.warn("[{s}] Error at line {}, col {}: Expected unquoted terminator got '{}'", .{
                        src_name,
                        pos.line,
                        pos.index - pos.line_start,
                        c,
                    });
                }
            } else {
                pos.index += 1;
                if (pos.index >= input.len) break;
                try result.append(allocator, c);
                c = input[pos.index];
            }
        }

        return try result.toOwnedSlice(allocator);
    }
}

pub fn skipToStmtBoundary(input: []const u8, pos: *SourcePosition) void {
    while (pos.index < input.len) : (pos.index += 1) {
        const c = input[pos.index];
        if (c == ';') {
            pos.index += 1;
            break;
        }
        if (c == '}') {
            break;
        }
        if (c == '\n') {
            pos.line += 1;
            pos.index += 1;
            pos.line_start = pos.index;
            break;
        }
        if (c == '\r') {
            pos.index += 1;
        }
    }
}

pub fn extractClassDefinition(input: []const u8, pos: *SourcePosition) !ClassDefinition {
    const start_line = pos.line;
    const start_col = pos.index - pos.line_start;

    const class_name = getAlphaWord(input, pos);

    skipWhitespace(input, pos);

    var base_name: ?[]const u8 = null;
    if (pos.index < input.len and input[pos.index] == ':') {
        pos.index += 1;
        base_name = getAlphaWord(input, pos);
        skipWhitespace(input, pos);
    }

    if (pos.index >= input.len or input[pos.index] == ';') {
        if (pos.index < input.len) pos.index += 1;
        return ClassDefinition{
            .class_name = class_name,
            .base_name = base_name,
            .body = null,
            .start_line = start_line,
            .start_col = start_col,
        };
    }

    if (input[pos.index] != '{') {
        return error.ExpectedOpenBrace;
    }
    pos.index += 1;

    const body_start = pos.index;
    var brace_count: usize = 1;

    while (pos.index < input.len and brace_count > 0) {
        const c = input[pos.index];

        if (c == '{') {
            brace_count += 1;
        } else if (c == '}') {
            brace_count -= 1;
        } else if (c == '\n') {
            pos.line += 1;
            pos.line_start = pos.index + 1;
        }

        pos.index += 1;
    }

    if (brace_count != 0) {
        return error.UnmatchedBrace;
    }

    const body = input[body_start .. pos.index - 1];

    skipWhitespace(input, pos);
    if (pos.index < input.len and input[pos.index] == ';') {
        pos.index += 1;
    }

    return ClassDefinition{
        .class_name = class_name,
        .base_name = base_name,
        .body = body,
        .start_line = start_line,
        .start_col = start_col,
    };
}