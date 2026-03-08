const std = @import("std");

const storage = @import("../data/storage.zig");
const handle = @import("../data/handles.zig");
const identifiers = @import("../data/identifiers.zig");

pub const ParamDatabase = struct {
    store: storage.ParamStorage,
    root: handle.ClassHandle,
    firstEnum: handle.EnumHandle = .invalid,
    mutex: std.Io.Mutex = .init
    //
    // pub fn init()
};