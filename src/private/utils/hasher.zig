const std = @import("std");
const paths = @import("paths.zig");

pub inline fn hash(name: []const u8) u64 {
    var buf: [512]u8 = undefined;
    const bulk = @min(name.len, buf.len);
    for (buf[0..bulk], name[0..bulk]) |*dst, src| dst.* = std.ascii.toLower(src);

    if (name.len <= buf.len) {
        return std.hash.Wyhash.hash(0, buf[0..bulk]);
    }

    var h = std.hash.Wyhash.init(0);
    h.update(buf[0..bulk]);
    var i: usize = bulk;
    while (i < name.len) {
        const end = @min(i + buf.len, name.len);
        const chunk = name[i..end];
        for (buf[0..chunk.len], chunk) |*dst, src| dst.* = std.ascii.toLower(src);
        h.update(buf[0..chunk.len]);
        i = end;
    }
    return h.final();
}

pub const IncrementalHasher = struct {
    inner: std.hash.Wyhash,

    pub fn init() IncrementalHasher {
        return .{ .inner = std.hash.Wyhash.init(0) };
    }

    pub fn update(self: *IncrementalHasher, data: []const u8) void {
        var buf: [512]u8 = undefined;
        var i: usize = 0;
        while (i < data.len) {
            const end   = @min(i + buf.len, data.len);
            const chunk = data[i..end];
            for (buf[0..chunk.len], chunk) |*dst, src| dst.* = std.ascii.toLower(src);
            self.inner.update(buf[0..chunk.len]);
            i = end;
        }
    }

    pub fn updateSep(self: *IncrementalHasher) void {
        self.update(paths.PathSeparator);
    }

    pub fn final(self: *const IncrementalHasher) u64 {
        var copy = self.inner;
        return copy.final();
    }
};
