const std      = @import("std");
const testing  = std.testing;
const Allocator = std.mem.Allocator;

const identifiers = @import("private/utils/identifiers.zig");
const handles     = @import("private/utils/handles.zig");
const cpp_lexer   = @import("private/formats/cpp/lexer.zig");
const hasher      = @import("private/utils/hasher.zig");
const value       = @import("private/data/value.zig");
const strings     = @import("private/utils/strings.zig");
const memory      = @import("private/utils/memory.zig");
const paths       = @import("private/utils/paths.zig");
const storage     = @import("private/data/storage.zig");

test "paths tests" {
    std.testing.refAllDecls(paths);
}

test "storage tests" {
    std.testing.refAllDecls(storage);
}

test "identifiers tests" {
    std.testing.refAllDecls(identifiers);
}

test "slabpool tests" {
    std.testing.refAllDecls(memory);
}

test "stringpool tests" {
    std.testing.refAllDecls(strings);
}

test "hasher tests" {
    std.testing.refAllDecls(hasher);
}

test "handle tests" {
    std.testing.refAllDecls(handles);
}

test "cpp lexer tests" {
    std.testing.refAllDecls(cpp_lexer);
}

test "value tests" {
    std.testing.refAllDecls(value);
}