const std   = @import("std");
const lexer = @import("../lexer.zig");

const ESC    = "\x1b[";
const Color = struct {
    const reset  = ESC ++ "0m";
    const bold   = ESC ++ "1m";
    const red    = ESC ++ "1;31m";
    const yellow = ESC ++ "1;33m";
    const cyan   = ESC ++ "1;36m";
    const blue   = ESC ++ "1;34m";
    const green  = ESC ++ "1;32m";
};

pub const Level = enum {
    err,
    warning,
    note,
    hint,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .err     => "error",
            .warning => "warning",
            .note    => "note",
            .hint    => "hint",
        };
    }

    pub fn color(self: Level) []const u8 {
        return switch (self) {
            .err     => Color.red,
            .warning => Color.yellow,
            .note    => Color.cyan,
            .hint    => Color.green,
        };
    }
};

pub const ParseLog = struct {
    const Self = @This();

    writer:     std.Io.Writer,
    line_table: *const lexer.LineTable,
    filename:   []const u8,
    use_color: bool,

    pub fn init(
        writer:     std.Io.Writer,
        line_table: *const lexer.LineTable,
        filename:   []const u8,
        use_color: bool,
    ) Self {
        return .{
            .writer     = writer,
            .line_table = line_table,
            .filename   = filename,
            .use_color = use_color,
        };
    }

    inline fn ansi(self: Self, seq: []const u8) []const u8 {
        return if (self.use_color) seq else "";
    }

    pub fn emit(
        self:       *const Self,
        source:     [:0]const u8,
        level:      Level,
        err_code:   ?[]const u8,
        token:      *const lexer.Token,
        message:    []const u8,
        label_text: ?[]const u8,
    ) void {
        var w   = self.writer;
        const pos = self.line_table.resolve(token.pos);

        if (err_code) |c| {
            w.print("{s}{s}[{s}]{s}: {s}{s}{s}\n", .{
                self.ansi(level.color()), level.label(), c,
                self.ansi(Color.reset),
                self.ansi(Color.bold), message, self.ansi(Color.reset),
            }) catch return;
        } else {
            w.print("{s}{s}{s}: {s}{s}{s}\n", .{
                self.ansi(level.color()), level.label(),
                self.ansi(Color.reset),
                self.ansi(Color.bold), message, self.ansi(Color.reset),
            }) catch return;
        }

        const margin = digitWidth(pos.line);
        w.print("{s} {s}-->{s} {s}:{d}:{d}\n", .{
            spaces(margin),
            self.ansi(Color.blue), self.ansi(Color.reset),
            self.filename, pos.line, pos.column,
        }) catch return;

        const line_text = lineSlice(source, self.line_table, pos.line);

        w.print("{s} {s}|{s}\n", .{
            spaces(margin),
            self.ansi(Color.blue), self.ansi(Color.reset),
        }) catch return;
        w.print("{s}{d}{s} {s}|{s} {s}\n", .{
            self.ansi(Color.blue), pos.line, self.ansi(Color.reset),
            self.ansi(Color.blue), self.ansi(Color.reset),
            line_text,
        }) catch return;
        w.print("{s} {s}|{s} ", .{
            spaces(margin),
            self.ansi(Color.blue), self.ansi(Color.reset),
        }) catch return;

        const col0: usize = pos.column - 1;
        const span        = tokenSpan(token, line_text, col0);

        writeRepeat(&w, ' ', col0) catch return;
        w.print("{s}", .{ self.ansi(level.color()) }) catch return;
        writeRepeat(&w, '^', span) catch return;

        const lbl = label_text orelse message;
        w.print(" {s}{s}\n\n", .{ lbl, self.ansi(Color.reset) }) catch return;
    }

    pub fn err(self: *const Self, source: [:0]const u8, code: ?[]const u8, token: lexer.Token, msg: []const u8) void {
        self.emit(source, .err, code, token, msg, null);
    }

    pub fn warn(self: *const Self, source: [:0]const u8, code: ?[]const u8, token: lexer.Token, msg: []const u8) void {
        self.emit(source, .warning, code, token, msg, null);
    }

    pub fn note(self: *const Self, source: [:0]const u8, token: lexer.Token, msg: []const u8) void {
        self.emit(source, .note, null, token, msg, null);
    }

    pub fn hint(self: *const Self, source: [:0]const u8, token: lexer.Token, msg: []const u8) void {
        self.emit(source, .hint, null, token, msg, null);
    }
};


fn lineSlice(source: []const u8, lt: *const lexer.LineTable, line: u32) []const u8 {
    const offsets = lt.newline_offsets;
    const lo: usize = line - 1;

    const start: usize =
        if (lo == 0) 0 else @as(usize, offsets[lo - 1]) + 1;
    const raw_end: usize =
        if (lo < offsets.len) @as(usize, offsets[lo]) else source.len;

    var end = raw_end;
    while (end > start and
        (source[end - 1] == '\r' or source[end - 1] == '\n')) end -= 1;

    return source[start..end];
}

fn tokenSpan(token: lexer.Token, line_text: []const u8, col0: usize) usize {
    switch (token.data) {
        .text => |t| {
            const extra: usize = switch (token.kind) {
                .stringLiteral => 2,
                .expression    => 1,
                else           => 0,
            };
            if (t.len + extra > 0) return t.len + extra;
        },
        else => {},
    }

    if (col0 < line_text.len) {
        var end = col0;
        while (end < line_text.len) : (end += 1) {
            const c = line_text[end];
            if (c == ' ' or c == '\t' or c == ';' or c == '}' or c == ',') break;
        }
        if (end > col0) return end - col0;
    }

    return 1;
}

fn digitWidth(n: u32) usize {
    if (n < 10)    return 1;
    if (n < 100)   return 2;
    if (n < 1000)  return 3;
    if (n < 10000) return 4;
    return 5;
}

const SPACES = "                    ";

fn spaces(n: usize) []const u8 {
    return SPACES[0..@min(n, SPACES.len)];
}

fn writeRepeat(writer: *std.Io.Writer, ch: u8, n: usize) !void {
    const count = if (n == 0) 1 else n;
    var i: usize = 0;
    while (i < count) : (i += 1) try writer.writeByte(ch);
}


pub fn stderrLog(
    io: std.Io,
    line_table: *const lexer.LineTable,
    filename:   []const u8,
    use_color: bool,
) ParseLog {
    var buffer: [4096]u8 = undefined;
    const stderr = std.Io.File.stderr().writer(io, &buffer);

    const interface: std.Io.Writer = stderr.interface;

    return ParseLog.init(
        interface,
        line_table,
        filename,
        use_color,
    );
}
