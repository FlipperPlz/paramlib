const std = @import("std");

const clazz = @import("class.zig");
const external = @import("external.zig");
const delete = @import("delete.zig");
const param = @import("parameter.zig");
const enumeration = @import("enumerable.zig");


const MemberAST = union(enum) {
    external: external.ExternalClassAST,
    class: clazz.ClassAST,
    delete: delete.DeleteAST,
    parameter: param.ParameterAST,
    enumeration: enumeration.EnumerableAST,
};