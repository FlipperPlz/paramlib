const std = @import("std");

pub fn getTimeMs() i64 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io: std.Io = threaded.io();

    const timestamp: std.Io.Timestamp = std.Io.Clock.real.now(io) catch {
        @panic("unsupported clock");
    };

    return timestamp.toMilliseconds();
}

pub fn sleep(ms: i64) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io: std.Io = threaded.io();
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), std.Io.Clock.real);
}

pub fn sleepNs(ns: i96) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io: std.Io = threaded.io();
    try std.Io.sleep(io, std.Io.Duration.fromNanoseconds(ns), std.Io.Clock.real);
}