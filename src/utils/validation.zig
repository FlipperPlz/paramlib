const std = @import("std");

pub fn validateName(name: []const u8) !void {
    if (name.len == 0) return error.EmptyName;
    if (name.len > 255) return error.NameTooLong;

    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') {
            return error.InvalidNameCharacter;
        }
    }
}

pub fn validateRefCount(count: u32) !void {
    if (count == 0) return error.InvalidRefCount;
    if (count > 1000000) return error.RefCountOverflow;
}

pub fn validateIndex(index: u32, max: u32) !void {
    if (index >= max) return error.IndexOutOfBounds;
}

pub fn validateGeneration(generation: u32) !void {
    if (generation == 0) return error.InvalidGeneration;
}

pub fn validateRange(value: anytype, min: @TypeOf(value), max: @TypeOf(value)) !void {
    if (value < min or value > max) return error.OutOfRange;
}

pub fn validateUtf8(str: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(str)) {
        return error.InvalidUtf8;
    }
}

pub fn sanitizeName(name: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var sanitized = std.ArrayList(u8).init(allocator);
    errdefer sanitized.deinit();

    for (name) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.') {
            try sanitized.append(c);
        } else {
            try sanitized.append('_');
        }
    }

    if (sanitized.items.len == 0) {
        try sanitized.appendSlice("unnamed");
    }

    return sanitized.toOwnedSlice();
}

pub fn matchesPattern(name: []const u8, pattern: []const u8) bool {
    var name_idx: usize = 0;
    var pat_idx: usize = 0;

    while (pat_idx < pattern.len and name_idx < name.len) {
        const p = pattern[pat_idx];

        if (p == '*') {
            if (pat_idx == pattern.len - 1) return true;

            pat_idx += 1;
            const next = pattern[pat_idx];

            while (name_idx < name.len) : (name_idx += 1) {
                if (name[name_idx] == next) {
                    if (matchesPattern(name[name_idx..], pattern[pat_idx..])) {
                        return true;
                    }
                }
            }
            return false;
        } else if (p == '?') {
            name_idx += 1;
            pat_idx += 1;
        } else {
            if (name[name_idx] != p) return false;
            name_idx += 1;
            pat_idx += 1;
        }
    }

    return name_idx == name.len and pat_idx == pattern.len;
}

pub fn validatePath(path: []const u8) !void {
    _ = path;

}

pub const Validator = struct {
    errors: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) Validator {
        return .{
            .errors = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Validator) void {
        for (self.errors.items) |err| {
            self.errors.allocator.free(err);
        }
        self.errors.deinit();
    }

    pub fn addError(self: *Validator, err: []const u8) !void {
        const owned = try self.errors.allocator.dupe(u8, err);
        try self.errors.append(owned);
    }

    pub fn checkName(self: *Validator, name: []const u8) !void {
        validateName(name) catch |err| {
            try self.addError(switch (err) {
                error.EmptyName => "Name cannot be empty",
                error.NameTooLong => "Name is too long (max 255 characters)",
                error.InvalidNameCharacter => "Name contains invalid characters",
                else => "Invalid name",
            });
        };
    }

    pub fn checkPath(self: *Validator, path: []const u8) !void {
        _ = path;
        _ = self;

    }

    pub fn isValid(self: *const Validator) bool {
        return self.errors.items.len == 0;
    }

    pub fn getErrors(self: *const Validator) []const []const u8 {
        return self.errors.items;
    }
};