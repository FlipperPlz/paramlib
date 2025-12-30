const std = @import("std");
const Allocator = std.mem.Allocator;

const ParamTree = @import("../core/tree.zig").ParamTree;
const DataStore = @import("../storage/datastores.zig").DataStore;
const Class = @import("../core/facade.zig").Class;
const Value = @import("../data/value.zig").Value;
const ArrayData = @import("../data/value.zig").ArrayData;
const ClassId = @import("../core/identifiers.zig").ClassId;
const SearchOptions = @import("../managers/navigation.zig").SearchOptions;
const SourcePosition = @import("position.zig").SourcePosition;

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
            const thread = try std.Thread.spawn(.{}, workerThreadFn, .{&parser});
            try parser.worker_threads.append(thread);
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

    pub fn parseFile(self: *Parser, file_path: []const u8, parent: Class) !void {
        const file_buffer = try SourceBuffer.init(file_path, self.allocator);
        defer file_buffer.release(self.allocator);

        try self.parseBuffer(file_buffer, parent);
    }

    pub fn parseMemory(self: *Parser, name: []const u8, data: []const u8, parent: Class) !void {
        const file_buffer = try SourceBuffer.initFromMemory(name, data, self.allocator);
        defer file_buffer.release(self.allocator);

        try self.parseBuffer(file_buffer, parent);
    }

    pub fn registerParserThread(self: *Parser) !void {
        const thread_id = std.Thread.getCurrentId();
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.active_parsers.put(self.allocator, thread_id, {});
    }

    pub fn unregisterParserThread(self: *Parser) void {
        const thread_id = std.Thread.getCurrentId();
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.active_parsers.remove(thread_id);
        self.tree.thread_manager.notifyAll();
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

    fn parseBuffer(self: *Parser, file_buffer: *SourceBuffer, parent: Class) !void {
        try self.registerParserThread();
        defer self.unregisterParserThread();

        const input = try file_buffer.source.contents(self.allocator);
        defer self.allocator.free(input);

        var position: SourcePosition = .{
           .index = 0,
           .line = 1,
           .line_start = 0,
        };

        while (position.index < input.len) {
            lexer.skipWhitespace(input, &position);
            if (position.index >= position.input.len) break;

            const c = input[position.index];

            if (c == '#') {
                // TODO: Handle directives
                continue;
            }

            if (c == '}') {
                position.index += 1;
                if (position.index < input.len and input[position.index] == ';') {
                    position.index += 1;
                } else {
                    std.log.warn("[{s}] Error at line {}, col {}: expected ';' after class ending.", .{
                        file_buffer.source.name,
                        position.line,
                        position.index - position.line_start,
                    });
                    return error.SyntaxError;
                }
                break;
            }

            const word = lexer.getAlphaWord(input, &position);

            if (std.mem.eql(u8, word, "class")) {
                try self.handleClass(input, file_buffer, parent, &position);
            } else if (std.mem.eql(u8, word, "delete")) {
                try self.handleDelete(input, file_buffer.source.name, parent, &position);
            } else {
                try self.handleParam(input, file_buffer.source.name, parent, word, &position);
            }
        }
    }

    fn handleDelete(self: *Parser, input: []const u8, debug_name: []const u8, parent: Class, pos: SourcePosition ) !void {
        _ = self;
        _ = input;
        _ = parent;
        _ = pos;
        std.log.warn("[{s}] Delete not yet implemented", .{debug_name});
        return error.NotImplemented;
    }

    fn handleClass(self: *Parser, input: []const u8, buf: *SourceBuffer, parent: Class, pos: *SourcePosition ) !void {
        const class_def = try lexer.extractClassDefinition(input, pos);
        buf.retain();
        const job = try class_def.toJob(buf, parent, self.allocator);
        try self.job_queue.push(job);
    }

    fn workerThreadFn(self: *Parser) void {
        while (true) {
            if (self.shutdown.load(.acquire)) break;

            var job = self.job_queue.waitForJob(&self.shutdown) orelse break;
            defer {
                job.deinit(self.allocator);
                job.file_buffer.release(self.allocator);
            }

            self.registerParserThread() catch continue;
            defer self.unregisterParserThread();

            self.processClassJob(&job) catch |err| {
                std.log.err("[{s}] Error processing class '{s}': {}", .{
                    job.debug_name,
                    job.class_name,
                    err,
                });
            };
        }
    }

    fn processClassJob(self: *Parser, job: *const ClassJob) !void {
        const class = try job.parent.getOrCreateChild(job.class_name);

        if (job.base_name) |base_name| {
            if (try job.parent.findChild(base_name, .{ .recursive = true })) |base| {
                try class.setBase(base);
            } else {
                if (try job.parent.waitForChild(base_name, self, .{ .recursive = true })) |base| {
                    try class.setBase(base);
                } else {
                    std.log.warn("[{s}:{d}] Base class '{s}' not found for '{s}'", .{
                        job.debug_name,
                        job.start_line,
                        base_name,
                        job.class_name,
                    });
                }
            }
        }

        if (job.body) |body| {
            var body_positon = SourcePosition{
                .index = 0,
                .line = job.start_line,
                .line_start = 0,
            };


            try self.parseClassBody(
                body,
                job.file_buffer,
                class,
                &body_positon,
            );
        }
    }

    fn parseClassBody(self: *Parser, input: []const u8, buf: *SourceBuffer, parent: Class, pos: *SourcePosition) !void {
        while (pos.index < input.len) {
            lexer.skipWhitespace(input, pos);
            if (pos.index >= input.len) break;

            const word = lexer.getAlphaWord(input, pos);

            if (std.mem.eql(u8, word, "class")) {
                try self.handleClass(input, buf, parent, pos);
            } else if (std.mem.eql(u8, word, "delete")) {
                try self.handleDelete(input, buf.source.name, parent, pos);
            } else {
                try self.handleParam(input, buf.source.name, parent, word, pos);
            }
        }
    }

    fn handleParam(self: *Parser, input: []const u8, dbg_name: []const u8, parent: Class, name: []const u8, pos: *SourcePosition) !void {
        _ = pos;
        _ = name;
        _ = parent;
        _ = input;
        _ = self;
        std.log.warn("[{s}] Param not yet implemented", .{dbg_name});
        return error.NotImplemented;
    }

};