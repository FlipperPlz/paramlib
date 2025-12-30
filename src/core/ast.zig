const std = @import("std");
const value_mod = @import("../data/value.zig");
const id_mod = @import("../core/identifiers.zig");
const pools_mod = @import("../utils/pools.zig");

const Allocator = std.mem.Allocator;
const Value = value_mod.Value;
const SourceFile = @import("../data/source.zig").Source;
const AstDatastore = @import("../storage/datastores.zig").AstDatastore;
const StringId = id_mod.StringId;
const ValueId = id_mod.ValueId;

const NodeId = id_mod.ValueId;

const SlabPool = pools_mod.SlabPool;

pub const NodeTag = enum(u8) {
    Class,
    Delete,
    Parameter
};

pub const NodeData = struct {
    tag: NodeTag,
    name: StringId,

    parent: NodeId,
    first_child: NodeId,
    next_sibling: NodeId,

    base_class: id_mod.ClassId,
    param_start: id_mod.ParamId,
    param_count: u32,

    value: ValueId,
};

pub const Parameter = struct {
    name: StringId,
    value: ValueId,
};

pub const ParamFile = struct {
    source: SourceFile,
    store:  *anyopaque,
    store_owner: bool,
    parameters: SlabPool(Parameter, 64),
    values: SlabPool(Value, 64),
    nodes: SlabPool(NodeData, 128),

    pub fn init(source: SourceFile, store: ?*AstDatastore, allocator: Allocator) !ParamFile {
        if(store) |s| {
            return .{
                .source = source,
                .store = s,
                .store_owner = false,
                .parameters = SlabPool(Parameter, 64).empty,
                .values = SlabPool(Value, 64).empty,
                .nodes = SlabPool(NodeData, 128).empty,
            };
        }


        const owned_source = try allocator.create(AstDatastore);
        owned_source.*  = try AstDatastore.init(allocator);

        return .{
            .source = source,
            .store = owned_source,
            .store_owner = true,
            .parameters = SlabPool(Parameter, 64).empty,
            .values = SlabPool(Value, 64).empty,
            .nodes = SlabPool(NodeData, 128).empty,
        };
    }

    pub fn deinit(self: *ParamFile, allocator: Allocator) void {
        self.arena.deinit();
        if (self.store_owner) {
            self.store.deinit(allocator);
        }
        self.source.deinit(allocator);
    }
};