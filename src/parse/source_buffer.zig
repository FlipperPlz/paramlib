const std = @import("std");
const SourceFile = @import("../data/source.zig").Source;
const Allocator = std.mem.Allocator;

pub const SourceBuffer = struct {
    source: SourceFile,
    ref_count: std.atomic.Value(usize),

    pub fn init(path: []const u8, allocator: Allocator) !*SourceBuffer {
        const source = try SourceFile.init_file(path, allocator);
        const buffer = try allocator.create(SourceBuffer);

        buffer.* = .{
            .source = source,
            .ref_count = std.atomic.Value(usize).init(1),
        };

        return buffer;
    }

    pub fn initFromMemory(name: []const u8, data: []const u8, allocator: Allocator) !*SourceBuffer {
        const source = try SourceFile.init_memory(name, data, allocator);

        const buffer = try allocator.create(SourceBuffer);
        buffer.* = .{
            .source = source,
            .ref_count = std.atomic.Value(usize).init(1),
        };

        return buffer;
    }

    pub fn retain(self: *SourceBuffer) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *SourceBuffer, allocator: Allocator) void {
        const old_count = self.ref_count.fetchSub(1, .acq_rel);
        if (old_count == 1) {
            self.source.deinit(allocator);
            allocator.destroy(self);
        }
    }
};