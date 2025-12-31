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
const AtomicUsize = std.atomic.Value(usize);
const AtomicBool = std.atomic.Value(bool);
const time_mod = @import("../utils/time.zig");

const ActiveParserInfo = struct {
    sequence: usize,
    file_buffer: *SourceBuffer,
    source_index: usize,
};


pub const ClassDefinition = struct {
    class_name: []const u8,
    base_name: ?[]const u8,
    body: ?[]const u8,
    start_line: usize,
    start_col: usize,
    start_index: usize,

    pub fn toJob(
        self: ClassDefinition,
        sequence: usize,
        file_buffer: *SourceBuffer,
        parent: Class,
        allocator: Allocator,
    ) !ClassJob {
        return ClassJob.init(
            sequence,
            self.class_name,
            self.base_name,
            self.body,
            file_buffer,
            parent,
            file_buffer.source.name,
            self.start_line,
            self.start_col,
            self.start_index,
            allocator,
        );
    }
};

pub const Parser = struct {
    tree: *ParamTree,
    store: *DataStore,
    mutex: std.Thread.Mutex,
    active_parsers: std.AutoHashMapUnmanaged(std.Thread.Id, ActiveParserInfo),
    allocator: Allocator,
    io: std.Io,

    job_queue: JobQueue,
    worker_threads: std.ArrayList(std.Thread),
    shutdown: AtomicBool,
    
    sequence_counter: AtomicUsize,

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
            .worker_threads = std.ArrayList(std.Thread).empty,
            .shutdown = AtomicBool.init(false),
            .sequence_counter = AtomicUsize.init(1),
            .io = tree.store.io,
        };

        try parser.worker_threads.ensureTotalCapacity(allocator, thread_count, );
        var i: usize = 0;
        while (i < thread_count) : (i += 1) {
            const thread = try std.Thread.spawn(.{}, workerThreadFn, .{&parser});
            try parser.worker_threads.append(allocator, thread);
        }

        return parser;
    }

    pub fn deinit(self: *Parser) void {
        self.shutdown.store(true, .release);
        self.job_queue.broadcast();

        for (self.worker_threads.items) |thread| {
            thread.join();
        }

        self.worker_threads.deinit(self.allocator);
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

    pub fn registerParserThread(self: *Parser, sequence: usize) !void {
        const thread_id = std.Thread.getCurrentId();
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.active_parsers.put(self.allocator, thread_id, sequence);
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

    pub fn hasPreviousJobs(self: *Parser, job: *const ClassJob) bool {
        if (self.job_queue.hasLowerSequence(job.sequence)) return true;

        self.mutex.lock();
        defer self.mutex.unlock();
        
        var iter = self.active_parsers.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* < job.sequence) return true;
        }
        
        return false;
    }

    pub fn hasPreviousJobsInBuffer(self: *Parser, job: *const ClassJob) bool {
        if (self.job_queue.hasEarlierJobsInBuffer(job)) return true;

        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.active_parsers.iterator();
        while (iter.next()) |entry| {
            const info = entry.value_ptr.*;
            if (info.file_buffer != job.file_buffer) continue;
            if (info.source_index < job.source_index) return true;
        }

        return false;
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
        try self.registerParserThread(std.math.maxInt(usize));
        defer self.unregisterParserThread();

        const input = try file_buffer.source.contents(self.allocator, self.io);
        defer self.allocator.free(input);

        var position: SourcePosition = .{
           .index = 0,
           .line = 1,
           .line_start = 0,
        };

        while (position.index < input.len) {
            lexer.skipWhitespace(input, &position);
            if (position.index >= input.len) break;

            if(input[position.index] == '#') {
                //todo
                return error.DirectivesNotImplemented;
            }

            const word = lexer.getAlphaWord(input, &position);

            if (std.mem.eql(u8, word, "class")) {
                try handleClass(self, input, file_buffer, parent, &position);
            } else if (std.mem.eql(u8, word, "delete")) {
                try handleDelete(input, file_buffer.source.name, parent, &position);
            } else if (std.mem.eql(u8, word, "enum")) {
                try handleEnum(self, input, file_buffer, parent, &position);
            } else {
                try handleParam(self, input, file_buffer.source.name, parent, word, &position);
            }
        }
    }

    fn handleEnum(self: *Parser, input: []const u8, buf: *SourceBuffer, pos: *SourcePosition) !void {
        const c = input[pos.index];
        // check len vs pos
        lexer.skipWhitespace(input, &pos);
        if (c != '{') {
            std.log.err("[{s}] Expected '{' after enum keyword", .{buf.source.name});
            return error.ExpectedOpenBrace;
        }
        pos.index += 1;

        var enum_value: i32 = 0;
        while (true) {
            const word = lexer.getAlphaWord(input, &pos);
            lexer.skipWhitespace(input, &pos);
            if (input[pos.index] == '=') {
                pos.index += 1;
                lexer.skipWhitespace(input, &pos);
                const value_string = try lexer.getWord(input, buf.source.name, pos, ",}", null, self.allocator);
                enum_value = try scanner.scanFloatPlain(value_string); //catch
            }
            try self.tree.setEnum(word, enum_value);
            enum_value += 1;


            pos.index += 1;
            if (input[pos.index] != ',') break;
        }

        if(input[pos.index] != '}') {
            std.log.err("[{s}] Expected '}' at end of enum definition", .{buf.source.name});
            return error.ExpectedCloseBrace;
        }
        pos.index += 1;

        //lexer.skipWhitespace(input, &pos);
        while(c == ';') : (pos.index += 1) {
            lexer.skipWhitespace(input, &pos);
        }
    }

    fn handleDelete(input: []const u8, debug_name: []const u8, parent: Class, pos: *SourcePosition ) !void {
        const target_name = lexer.getAlphaWord(input, &pos);
        lexer.skipWhitespace(input, &pos);

        if(input[pos.index] != ';') {
            std.log.err("[{s}] Expected ';' after delete statement for class '{s}'", .{debug_name, target_name});
            return error.ExpectedSemicolon;
        }
        pos.index += 1;
        
        try parent.deleteClass(target_name);
    }

    fn handleClass(self: *Parser, input: []const u8, buf: *SourceBuffer, parent: Class, pos: *SourcePosition) !void {
        const start_index = pos.index;
        const class_def = try lexer.extractClassDefinition(input, pos);
        buf.retain();
        const sequence = self.sequence_counter.fetchAdd(1, .monotonic);

        var job_def = class_def;
        job_def.start_index = start_index;

        const job = try job_def.toJob(sequence, buf, parent, self.allocator);
        try self.job_queue.push(job);
    }

    fn workerThreadFn(self: *Parser) void {
        while (true) {
            if (self.shutdown.load(.acquire)) break;

            var job = self.job_queue.waitForJob(&self.shutdown) orelse break;
            const sequence = job.sequence;
            defer {
                job.deinit(self.allocator);
                job.file_buffer.release(self.allocator);
            }

            self.registerParserThread(sequence) catch continue;
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
            class.setBase(try self.waitForBase(base_name, job));
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

    fn waitForBase(self: *Parser, name: []const u8, job: *const ClassJob) !?Class {
        while (true) {
            const class_id = try self.tree.validateHandle(job.parent);

            if (try self.tree.navigation.findChild(class_id, name, .{ .look_in_parent = true })) |base| {
                return base;
            } else {
                if (self.hasPreviousJobsInBuffer(job.sequence)) {
                    self.tree.mutex.lock();
                    self.tree.thread_manager.wait(&self.tree.mutex);
                    self.tree.mutex.unlock();
                    continue;
                }
                return error.BaseClassNotFound;
            }
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