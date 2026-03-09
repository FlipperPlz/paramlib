pub const ParameterData = @import("parameter.zig").ParameterData;
pub const ClassData = @import("class.zig").ClassData;
pub const EnumData = @import("enum.zig").EnumData;
pub const ArrayData = @import("array.zig").ArrayData;
pub const SourceData = @import("source.zig").SourceData;
const identifiers = @import("../data/identifiers.zig");
const storage = @import("../data/storage.zig");

pub const SlabType = enum {
    parameter,
    class,
    enumeration,
    array,
    source
};

pub const SlabIdentifier = union(SlabType) {
    parameter: ParameterData.Id,
    class: identifiers.ClassId,
    enumeration: identifiers.EnumId,
    array: identifiers.ArrayId,
    source: identifiers.SourceId,

    pub fn isValid(self: SlabIdentifier) bool {
        return switch (self) {
            .parameter =>| d | d.isValid(),
            .class => | d | d.isValid(),
            .enumeration => | d | d.isValid(),
            .array => | d | d.isValid(),
            .source => |d| d.isValid()
        };
    }

    pub fn toIndex(self: SlabIdentifier) ?u32 {
        return switch (self) {
            .parameter =>| d | d.toIndex(),
            .class => | d | d.toIndex(),
            .enumeration => | d | d.toIndex(),
            .array => | d | d.toIndex(),
            .source => | d | d.toIndex()
        };
    }

    pub fn toStorageIdentifier(self: *SlabIdentifier) storage.StorageIdentifier {
        return storage.StorageIdentifier {
            .slab = self
        };
    }
};

pub const SlabInit = union(SlabType) {
    parameter: ?ParameterData.Init,
    class: ?ClassData.Init,
    enumeration: ?EnumData.Init,
    array: ?ArrayData.Init,
    source: ?SourceData.Init,

    pub fn nullSlab(t: SlabType) SlabInit{
        return switch (t) {
            .parameter => ParameterData.Init.toSlabInit(null),
            .class => ClassData.Init.toSlabInit(null),
            .enumeration => EnumData.Init.toSlabInit(null),
            .array => ArrayData.Init.toSlabInit(null),
            .source => SourceData.Init.toSlabInit(null)
        };
    }

    pub fn toStorageInit(self: *SlabInit) storage.StorageInit {
        return storage.StorageInit {
            .slab = self
        };
    }
};

