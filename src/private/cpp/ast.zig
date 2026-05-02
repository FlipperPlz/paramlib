const std = @import("std");
const clazz = @import("../slabs/class.zig");

pub const MemberAst = union(enum) {
    class: ClassAst,
    param: ParameterAst,
    delete: ?[]const u8,
    enumerable: EnumerableAst,
};

pub const EnumerableAst = struct {
    values: []const struct {name: []const u8, value: f32}
};

pub const ClassAst = struct {
    parent:       ?*ClassAst,
    name:         ?[]const u8,
    namePos:      u32,
    base:         ?*ClassAst,
    baseRefPos:   u32 = 0,
    members:      ?std.ArrayList(MemberAst),
    bodyEndPos:   u32 = 0,

    pub fn deinit(self: *ClassAst, allocator: std.mem.Allocator) void {
        if (self.members) |*members| {
            for (members.items) |*item| {
                switch (item.*) {
                    .class => |*c| c.deinit(allocator),
                    else => {},
                }
            }
            members.deinit(allocator);
        }
    }

    pub fn find(self: *const ClassAst, name: []const u8, scanParent: bool, scanBase: bool, protect: bool) ?*ClassAst {
        if(self.members) |members| {
            for (members.items) |*v| {
                //todo visibility testing and normalization
                if (v.* == .class and std.mem.eql(u8, v.class.name.?, name)) {
                    return &v.class;
                }
            }
        }

        if(scanBase) {
            if(self.base) |base| {
                const found = base.find(name, false, true, protect);
                if(found) |f| return f;
            }
        }
        if(scanParent) {
            if(self.parent) |base| {
                const found = base.find(name, true, scanBase, protect);
                if(found) |f| return f;
            }
        }
        return null;
    }
};

pub const OperatorAst = enum {
    assign,
    addAssign,
    subAssign
};

pub const ParameterAst = struct {
    name:          []const u8,
    namePos:       u32,
    operator:      OperatorAst,
    value:         ValueAst,
    valuePos:      u32 = 0,
    elemPositions: ?[]const u32 = null,
};

pub const ValueAst = union(enum) {
    float: f32,
    integer: i32,
    i64: i64,
    array: []const ValueAst,
    expression: []const u8,
    string: []const u8,
};



