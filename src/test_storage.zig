const std = @import("std");
const storage = @import("private/data/storage.zig");

test "storage: basic allocation" {
    const allocator = std.testing.allocator;
    var store = storage.ParamStorage.empty;
    defer store.deinit(allocator);

    const str = try store.alloc(allocator, undefined, .createString("test string"));
    try std.testing.expect(str.index.isValid());
    
    const retrieved = try store.retrieve(str.index);
    const retrieved_ptr: *const []const u8 = @ptrCast(@alignCast(retrieved));
    const retrieved_str = retrieved_ptr.*;
    try std.testing.expectEqualStrings("test string", retrieved_str);
}
