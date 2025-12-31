const std = @import("std");

pub fn getTimeMs(io: std.Io) i64 {
    const timestamp: std.Io.Timestamp = std.Io.Clock.real.now(io) catch {
        @panic("unsupported clock");
    };

    return timestamp.toMilliseconds();
}

pub fn sleep(ms: i64, io: std.Io ) !void {
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), std.Io.Clock.real);
}

pub fn sleepNs(ns: i96, io: std.Io ) !void {
    try std.Io.sleep(io, std.Io.Duration.fromNanoseconds(ns), std.Io.Clock.real);
}