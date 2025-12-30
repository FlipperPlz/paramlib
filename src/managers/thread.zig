const std = @import("std");

pub const ThreadManager = struct {
    condition: std.Thread.Condition,

    pub fn init() ThreadManager {
        return .{
            .condition = .{},
        };
    }

    pub fn notifyAll(self: *ThreadManager) void {
        self.condition.broadcast();
    }

    pub fn wait(self: *ThreadManager, mutex: *std.Thread.Mutex) void {
        self.condition.wait(mutex);
    }
};
