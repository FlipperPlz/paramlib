const std = @import("std");
const logger = @import("log.zig");
const lines = @import("lines.zig");

pub const SourceMapping = struct {
    pre_offset: u32,
    orig_offset: u32,
    length: u32,
};

pub const LineOverride = struct {
    pre_offset: u32,
    line_number: u32,
    file_name: ?[]const u8,
};

pub const PreprocessedResult = struct {
    source: [:0]const u8,
    mappings: []const SourceMapping,
    line_overrides: []const LineOverride = &.{},

    pub fn deinit(self: PreprocessedResult, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        allocator.free(self.mappings);
        for (self.line_overrides) |lo| {
            if (lo.file_name) |fname| allocator.free(fname);
        }
        allocator.free(self.line_overrides);
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

    pub const ResolvedLocation = struct {
        file_name: []const u8,
        line: u32,
        column: u32,
    };

    pub fn resolveLocation(self: PreprocessedResult, pre_offset: u32, default_filename: []const u8, line_table: *const lines.LineTable) ResolvedLocation {
        const orig_offset = self.resolveOffset(pre_offset);
        const phys_loc = line_table.resolve(orig_offset);

        var best_override: ?LineOverride = null;
        for (self.line_overrides) |lo| {
            if (lo.pre_offset <= pre_offset) {
                if (best_override == null or lo.pre_offset >= best_override.?.pre_offset) {
                    best_override = lo;
                }
            }
        }

        if (best_override) |ov| {
            var line_delta: u32 = 0;
            var i = ov.pre_offset;
            while (i < pre_offset and i < self.source.len) : (i += 1) {
                if (self.source[i] == '\n') line_delta += 1;
            }

            return .{
                .file_name = ov.file_name orelse default_filename,
                .line = ov.line_number + line_delta,
                .column = phys_loc.column,
            };
        }

        return .{
            .file_name = default_filename,
            .line = phys_loc.line,
            .column = phys_loc.column,
        };
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
        };
    }

    fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
};

test "Preprocessor: simple mapping" {
    const allocator = std.testing.allocator;

    const src = "foo = 42;\n#ignore\nbar = 24;";
    _ = src;

    const pre_src = "foo = 42;\n//ignore\nbar = 24;";
    
    var mappings = try allocator.alloc(SourceMapping, 2);
    
    mappings[0] = .{ .pre_offset = 0, .orig_offset = 0, .length = 10 };
    mappings[1] = .{ .pre_offset = 10, .orig_offset = 18, .length = 10 };
    
    const result = PreprocessedResult{
        .source = try allocator.dupeZ(u8, pre_src),
        .mappings = mappings,
    };
    defer result.deinit(allocator);
    
    try std.testing.expectEqual(@as(u32, 5), result.resolveOffset(5));
    try std.testing.expectEqual(@as(u32, 18), result.resolveOffset(10));
    try std.testing.expectEqual(@as(u32, 23), result.resolveOffset(15));
}
