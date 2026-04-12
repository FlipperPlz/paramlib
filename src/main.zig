const std = @import("std");
const cpp_lexer = @import("private/formats/cpp/lexer.zig");
const cpp_parser = @import("private/formats/cpp/parser.zig");

pub fn main(init: std.process.Init) !void {
    const BENCH_ITERS: u64 = 100;

    const src = @embedFile("private/formats/cpp/tests/game.cpp") ++ [_:0]u8{};

    const start = std.Io.Timestamp.now(init.io, .real).nanoseconds;
    var iter: u64 = 0;
    while (iter < BENCH_ITERS) : (iter += 1) {
        var _err = false;
        var parsed = try cpp_parser.parseSource(init.io, init.gpa, src, "game.cpp", true, &_err);
        defer parsed.deinit(init.gpa);
    }
    const elapsed_ns: u64 = @intCast(std.Io.Timestamp.now(init.io, .real).nanoseconds - start);
    const avg_ns: u64 = elapsed_ns / BENCH_ITERS;

    std.debug.print(
        "\n[bench] parsed game.cpp x{d}: total={d}ms  avg={d}us\n",
        .{ BENCH_ITERS, elapsed_ns / std.time.ns_per_ms, avg_ns / std.time.ns_per_us },
    );
}