const std = @import("std");
const DataStore = @import("../storage/datastores.zig").DataStore;

pub const SnapshotManager = struct {
    store: *DataStore,

    pub fn init(store: *DataStore) SnapshotManager {
        return .{ .store = store };
    }
};