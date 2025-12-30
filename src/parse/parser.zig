const std = @import("std");
const Allocator = std.mem.Allocator;

const ParamTree = @import("../core/tree.zig").ParamTree;
const DataStore = @import("../storage/datastores.zig").DataStore;
const Class = @import("../core/facade.zig").Class;
const Value = @import("../data/value.zig").Value;
const ArrayData = @import("../data/value.zig").ArrayData;
const ClassId = @import("../core/identifiers.zig").ClassId;
const SearchOptions = @import("../managers/navigation.zig").SearchOptions;

const lexer = @import("lexer.zig");
const scanner = @import("scanner.zig");
const SourceBuffer = @import("source_buffer.zig").SourceBuffer;
const job_system = @import("job_system.zig");
const ClassJob = job_system.ClassJob;
const JobQueue = job_system.JobQueue;

const time_mod = @import("../utils/time.zig");

pub const ClassDefinition = struct {
    class_name: []const u8,
    base_name: ?[]const u8,
    body: ?[]const u8,
    start_line: usize,
    start_col: usize,

    pub fn toJob(
        self: ClassDefinition,
        file_buffer: *SourceBuffer,
        parent: Class,
        allocator: Allocator,
    ) !ClassJob {
        return ClassJob.init(
            self.class_name,
            self.base_name,
            self.body,
            file_buffer,
            parent,
            file_buffer.source.name,
            self.start_line,
            self.start_col,
            allocator,
        );
    }
};

pub const Parser = struct {
    tree: *ParamTree,
    store: *DataStore,
    mutex: std.Thread.Mutex,
    active_parsers: std.AutoHashMapUnmanaged(std.Thread.Id, void),
    allocator: Allocator,

    job_queue: JobQueue,
    worker_threads: std.ArrayList(std.Thread),
    shutdown: std.atomic.Value(bool),

    pub fn init(tree: *ParamTree, num_threads: ?usize) !Parser {
        const thread_count = num_threads orelse @max(1, std.Thread.getCpuCount() catch 4);
        const allocator = tree.store.allocator;

        var parser = Parser{
            .tree = tree,
            .store = tree.store,
            .mutex = .{},
            .active_parsers = .empty,
            .allocator = allocator,
            .job_queue = JobQueue.init(allocator),
            .worker_threads = std.ArrayList(std.Thread).init(allocator),
            .shutdown = std.atomic.Value(bool).init(false),
        };

        try parser.worker_threads.ensureTotalCapacity(thread_count);
        var i: usize = 0;
        while (i < thread_count) : (i += 1) {
            // create thread, I have an old messier version to refer to. Will fix later just want a base first commit.
            // const thread = try std.Thread.spawn(.{}, workerThreadFn, .{&parser});
            // try parser.worker_threads.append(thread);
        }

        return parser;
    }

    pub fn deinit(self: *Parser) void {
        self.shutdown.store(true, .release);
        self.job_queue.broadcast();

        for (self.worker_threads.items) |thread| {
            thread.join();
        }

        self.worker_threads.deinit();
        self.job_queue.deinit(self.allocator);
        self.active_parsers.deinit(self.allocator);
    }

    pub fn registerParserThread(self: *Parser) !void {
        const thread_id = std.Thread.getCurrentId();
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.active_parsers.put(self.allocator, thread_id, {});
    }

    pub fn hasActiveParsers(self: *Parser) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.active_parsers.count() > 0;
    }

    pub fn waitForCompletion(self: *Parser) !void {
        while (true) {
            const has_jobs = !self.job_queue.isEmpty();
            const has_parsers = self.hasActiveParsers();

            if (!has_jobs and !has_parsers) break;

            try time_mod.sleepNs(1);
        }
    }
};