const std = @import("std");
const paths = @import("paths.zig");

const FnvOffsetBasis: u64 = 0xcbf29ce484222325;
const FnvPrime: u64 = 0x100000001b3;

pub inline fn hash(name: []const u8) u64 {
    var h: u64 = FnvOffsetBasis;
    for (name) |c| {
        const byte = std.ascii.toLower(c);
        h ^= byte;
        h *%= FnvPrime;
    }
    return h;
}

pub const IncrementalHasher = struct {
    inner: u64,

    pub fn init() IncrementalHasher {
        return load(FnvOffsetBasis);
    }

    pub fn load(value: u64) IncrementalHasher {
        return .{ .inner = value };
    }

    pub fn update(self: *IncrementalHasher, data: []const u8) *IncrementalHasher {
        var buf: [512]u8 = undefined;
        var i: usize = 0;

        while (i < data.len) {
            const end = @min(i + buf.len, data.len);
            const chunk = data[i..end];

            for (buf[0..chunk.len], chunk) |*dst, src| {
                dst.* = std.ascii.toLower(src);
            }

            for (buf[0..chunk.len]) |byte| {
                self.inner ^= byte;
                self.inner *%= FnvPrime;
            }

            i = end;
        }
        return self;
    }

    pub fn updateSep(self: *IncrementalHasher) *IncrementalHasher {
        self.update(paths.PathSeparator);

        return self;
    }

    pub inline fn final(self: *const IncrementalHasher) u64 {
        return self.inner;
    }
};