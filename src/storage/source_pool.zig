const std = @import("std");
const Source = @import("../data/source.zig").Source;
const SourceId = @import("../core/identifiers.zig").SourceId;
const Allocator = std.mem.Allocator;
const log = @import("../utils/log.zig");

pub const SourcePool = struct {
    sources: std.ArrayList(Source),
    name_to_id: std.StringHashMapUnmanaged(SourceId),

    pub const empty: SourcePool = .{
        .sources = std.ArrayList(Source).empty,
        .name_to_id = std.StringHashMapUnmanaged(SourceId).empty,
    };

    pub fn deinit(self: *SourcePool, io: std.Io, allocator: Allocator) void {
        for (self.sources.items) |*source| {
            source.deinit(io, allocator);
        }
        self.sources.deinit(allocator);
        self.name_to_id.deinit(allocator);
    }

    pub fn register(self: *SourcePool, source: Source, allocator: Allocator) !SourceId {
        if (self.name_to_id.get(source.name)) |existing_id| {
            return existing_id;
        }

        const id: SourceId = @enumFromInt(@as(u32, @intCast(self.sources.items.len)));
        log.debug("SourcePool: register source '{s}' as id={}", .{ source.name, id });
        var src = source;
        src.id = id;

        try self.sources.append(allocator, src);
        try self.name_to_id.put(allocator, src.name, id);

        return id;
    }

    pub fn get(self: *const SourcePool, id: SourceId) ?*const Source {
        const idx = id.toIndex() orelse return null;
        if (idx >= self.sources.items.len) return null;
        return &self.sources.items[idx];
    }

    pub fn getByName(self: *const SourcePool, name: []const u8) ?SourceId {
        return self.name_to_id.get(name);
    }
};
