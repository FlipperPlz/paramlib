const std = @import("std");
const Allocator = std.mem.Allocator;
const Class = @import("../core/facade.zig").Class;
const SourceBuffer = @import("source_buffer.zig").SourceBuffer;
const SourcePosition = @import("position.zig").SourcePosition;

pub const ClassJob = struct {
    sequence: usize,
    class_name: []const u8,
    base_name: ?[]const u8,
    body: ?[]const u8,

    parent: Class,
    file_buffer: *SourceBuffer,
    debug_name: []const u8,

    start_line: usize,
    start_col: usize,
    start_index: usize,

    pub fn init(
        sequence: usize,
        class_name: []const u8,
        base_name: ?[]const u8,
        body: ?[]const u8,
        file_buffer: *SourceBuffer,
        parent: Class,
        debug_name: []const u8,
        start_line: usize,
        start_col: usize,
        start_index: usize,
        allocator: Allocator,
    ) !ClassJob {
        return .{
            .sequence = sequence,
            .class_name = try allocator.dupe(u8, class_name),
            .base_name = if (base_name) |bn| try allocator.dupe(u8, bn) else null,
            .body = if (body) |b| try allocator.dupe(u8, b) else null,
            .parent = parent,
            .file_buffer = file_buffer,
            .debug_name = try allocator.dupe(u8, debug_name),
            .start_index = start_index,
            .start_line = start_line,
            .start_col = start_col,
        };
    }

    pub fn deinit(self: *ClassJob, allocator: Allocator) void {
        allocator.free(self.class_name);
        if (self.base_name) |bn| allocator.free(bn);
        if (self.body) |b| allocator.free(b);
        allocator.free(self.debug_name);
    }
};

pub const JobQueue = struct {
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    jobs: std.ArrayList(ClassJob),

    pub fn init() JobQueue {
        return .{
            .mutex = .{},
            .condition = .{},
            .jobs = std.ArrayList(ClassJob).empty,
        };
    }

    pub fn deinit(self: *JobQueue, allocator: Allocator) void {
        for (self.jobs.items) |*job| {
            job.deinit(allocator);
        }
        self.jobs.deinit(allocator);
    }

    pub fn push(self: *JobQueue, job: ClassJob, allocator: Allocator) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.jobs.append(job, allocator);
        self.condition.signal();
    }

    pub fn waitForJob(self: *JobQueue, shutdown: *std.atomic.Value(bool)) ?ClassJob {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.jobs.items.len == 0) {
            if (shutdown.load(.acquire)) return null;

            self.condition.wait(&self.mutex);

            if (shutdown.load(.acquire)) return null;
        }

        return self.jobs.orderedRemove(0);
    }

    pub fn isEmpty(self: *JobQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.jobs.items.len == 0;
    }

    pub fn hasLowerSequence(self: *JobQueue, sequence: usize) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.jobs.items) |job| {
            if (job.sequence < sequence) return true;
        }
        return false;
    }

    pub fn hasEarlierJobsInBuffer(self: *JobQueue, current_job: *const ClassJob) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.jobs.items) |*job| {
            if (job.file_buffer != current_job.file_buffer) continue;

            if (job.start_index < current_job.start_index) return true;
        }

        return false;
    }

    pub fn broadcast(self: *JobQueue) void {
        self.condition.broadcast();
    }
};