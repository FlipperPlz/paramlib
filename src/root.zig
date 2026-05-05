pub const cpp = struct {
    pub const parser = @import("private/cpp/parser.zig");
    pub const lexer = @import("private/cpp/lexer.zig");
    pub const logger = @import("private/common/log.zig");
    pub const lines = @import("private/common/lines.zig");
    pub const ast = @import("private/cpp/ast.zig");
    pub const preprocessor = @import("private/cpp/processor.zig");
};

pub const slabs = struct {
    pub const array = @import("private/slabs/array.zig");
    pub const class = @import("private/slabs/class.zig");
    pub const enumeration = @import("private/slabs/enum.zig");
    pub const parameter = @import("private/slabs/parameter.zig");
    pub const source = @import("private/slabs/source.zig");
};

pub const utils = struct {
    pub const factory = @import("private/tree/factory.zig");
    pub const query = @import("private/tree/query.zig");
    pub const references = @import("private/tree/references.zig");
};