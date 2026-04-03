const std = @import("std");
const cpp_lexer = @import("private/formats/cpp/lexer.zig");

pub fn main(init: std.process.Init) !void {
    const BENCH_ITERS: u64 = 100;

    const BENCH_SRC: *const [210147:0]u8 = @embedFile("private/formats/cpp/tests/game.cpp");
    var totalTokens: usize = 0;

    const start = std.Io.Timestamp.now(init.io, .real).nanoseconds;
    var iter: u64 = 0;
    while (iter < BENCH_ITERS) : (iter += 1) {
        var t = cpp_lexer.Tokenizer.init(BENCH_SRC);
        while (true) {
            const tok = t.next() catch break;
            totalTokens += 1;
            if (tok.kind == .eof) break;
        }
    }
    const elapsed_ns: u64 = @intCast(std.Io.Timestamp.now(init.io, .real).nanoseconds - start);
    const ns_per_token = elapsed_ns / totalTokens;

    std.debug.print(
        "\n[bench] tokenizer: {} tokens in {} iters - {d} ns/token\n",
        .{ totalTokens / BENCH_ITERS, BENCH_ITERS, ns_per_token },
    );
}