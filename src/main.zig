const std = @import("std");
const cpp_lexer = @import("private/formats/cpp/lexer.zig");
const cpp_parser = @import("private/formats/cpp/parser.zig");

pub fn main(init: std.process.Init) !void {
    const BENCH_ITERS: u64 = 100;

    const src = \\
            \\class MyBase;
            \\class MyClass : MyBase {
            \\    value = 42
            \\    name  = "hello";
            \\};
        ++ [_:0]u8{};
    const start = std.Io.Timestamp.now(init.io, .real).nanoseconds;
    var iter: u64 = 0;
    while (iter < BENCH_ITERS) : (iter += 1) {

        var parsed = try cpp_parser.parseSource(init.io, init.arena.allocator(), src, "MyClass.cpp", true);
        defer parsed.deinit(init.arena.allocator());
    }
    const elapsed_ns: u64 = @intCast(std.Io.Timestamp.now(init.io, .real).nanoseconds - start);

    std.debug.print(
        "\n[bench] tokenizer: {}  -\n",
        .{ elapsed_ns },
    );
}