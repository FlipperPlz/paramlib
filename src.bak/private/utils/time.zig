pub const std = @import("std");

pub fn getTimeMs(io: std.Io, clock: std.Io.Clock) i64 {
    const timestamp: std.Io.Timestamp = clock.now(io) catch {
        @panic("unsupported clock");
    };

    return timestamp.toMilliseconds();
}