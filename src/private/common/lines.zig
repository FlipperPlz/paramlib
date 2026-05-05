const std = @import("std");
const source = @import("../slabs/source.zig");

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