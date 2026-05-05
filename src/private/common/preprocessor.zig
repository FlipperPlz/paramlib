const std = @import("std");
const logger = @import("log.zig");
const lines = @import("lines.zig");

pub const SourceMapping = struct {
    pre_offset: u32,
    orig_offset: u32,
    length: u32,
};

pub const PreprocessedResult = struct {
    source: [:0]const u8,
    mappings: []const SourceMapping,

    pub fn deinit(self: PreprocessedResult, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        allocator.free(self.mappings);
    }

    pub fn resolveOffset(self: PreprocessedResult, pre_offset: u32) u32 {
        if (self.mappings.len == 0) return pre_offset;

        var left: usize = 0;
        var right: usize = self.mappings.len;
        while (left < right) {
            const mid = left + (right - left) / 2;
            const m = self.mappings[mid];
            if (pre_offset >= m.pre_offset and pre_offset < m.pre_offset + m.length) {
                return m.orig_offset + (pre_offset - m.pre_offset);
            }
            if (pre_offset < m.pre_offset) {
                right = mid;
            } else {
                left = mid + 1;
            }
        }

        if (left > 0) {
            const m = self.mappings[left - 1];
            if (pre_offset >= m.pre_offset) {
                return m.orig_offset + (pre_offset - m.pre_offset);
            }
        }
        
        return pre_offset;
    }
};

pub const Preprocessor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        preprocess: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, source: [:0]const u8, log: *const logger.DiagType) anyerror!PreprocessedResult,
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn preprocess(self: Preprocessor, allocator: std.mem.Allocator, source: [:0]const u8, log: *const logger.DiagType) !PreprocessedResult {
        return self.vtable.preprocess(self.ptr, allocator, source, log);
    }

    pub fn deinit(self: Preprocessor, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }
};

pub const PassthroughPreprocessor = struct {
    pub fn preprocessor(self: *PassthroughPreprocessor) Preprocessor {
        return .{
            .ptr = self,
            .vtable = &.{
                .preprocess = preprocess,
                .deinit = deinit,
            },
        };
    }

    fn preprocess(_: *anyopaque, allocator: std.mem.Allocator, source: [:0]const u8, log: *const logger.DiagType) anyerror!PreprocessedResult {
        _ = log;
        const copy = try allocator.dupeZ(u8, source);
        return .{
            .source = copy,
            .mappings = &.{},
            .allocator = allocator,
        };
    }

    fn deinit(_: *anyopaque) void {}
};

test "Preprocessor: simple mapping" {
    const allocator = std.testing.allocator;

    const src = "foo = 42;\n#ignore\nbar = 24;";
    _ = src;

    const pre_src = "foo = 42;\n//ignore\nbar = 24;";
    
    var mappings = try allocator.alloc(SourceMapping, 2);
    defer allocator.free(mappings);
    
    mappings[0] = .{ .pre_offset = 0, .orig_offset = 0, .length = 10 };
    mappings[1] = .{ .pre_offset = 10, .orig_offset = 10, .length = 19 };
    
    const result = PreprocessedResult{
        .source = try allocator.dupeZ(u8, pre_src),
        .mappings = try allocator.dupe(SourceMapping, mappings),
    };
    defer result.deinit(allocator);
    
    try std.testing.expectEqual(@as(u32, 5), result.resolveOffset(5));
    try std.testing.expectEqual(@as(u32, 11), result.resolveOffset(11));
    try std.testing.expectEqual(@as(u32, 20), result.resolveOffset(20));
}
