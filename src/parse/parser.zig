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
const Operator = scanner.Operator;
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
        parent: Class
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
        );
    }
};

pub const Parser = struct {
    tree: *ParamTree,
    store: *DataStore,
    mutex: std.Thread.Mutex,
    active_parsers: std.AutoHashMapUnmanaged(std.Thread.Id, ActiveParserInfo),

    job_queue: JobQueue,
    worker_threads: std.ArrayList(std.Thread),
    shutdown: AtomicBool,
    
    sequence_counter: AtomicUsize,

    pub fn init(tree: *ParamTree, num_threads: ?usize, allocator: Allocator, io: std.Io) !Parser {
        const thread_count = num_threads orelse @max(1, std.Thread.getCpuCount() catch 4);

        var parser = Parser{
            .tree = tree,
            .store = tree.store,
            .mutex = .{},
            .active_parsers = .empty,
            .job_queue = JobQueue.init(),
            .worker_threads = std.ArrayList(std.Thread).empty,
            .shutdown = AtomicBool.init(false),
            .sequence_counter = AtomicUsize.init(1),
        };

        try parser.worker_threads.ensureTotalCapacity(allocator, thread_count, );
        var i: usize = 0;
        while (i < thread_count) : (i += 1) {
            const thread = try std.Thread.spawn(.{}, workerThreadFn, .{&parser, allocator, io});
            try parser.worker_threads.append(allocator, thread);
        }

        return parser;
    }

    pub fn deinit(self: *Parser, allocator: Allocator) void {
        self.shutdown.store(true, .release);
        self.job_queue.broadcast();

        for (self.worker_threads.items) |thread| {
            thread.join();
        }

        self.worker_threads.deinit(allocator);
        self.job_queue.deinit(allocator);
        self.active_parsers.deinit(allocator);
    }

    pub fn parseFile(self: *Parser, file_path: []const u8, parent: Class, allocator: Allocator, io: std.Io) !void {
        const file_buffer = try SourceBuffer.init(file_path, io, allocator);
        defer file_buffer.release(io, allocator);

        try self.parseBuffer(file_buffer, file_buffer, parent, allocator, io);
    }

    pub fn parseMemory(self: *Parser, name: []const u8, data: []const u8, parent: Class, allocator: Allocator, io: std.Io) !void {
        const file_buffer = try SourceBuffer.initFromMemory(name, data, allocator);
        defer file_buffer.release(undefined, self.allocator);

        try self.parseBuffer(file_buffer, file_buffer, parent, allocator, io);
    }

    pub fn registerParserThread(self: *Parser, sequence: usize, allocator: Allocator) !void {
        const thread_id = std.Thread.getCurrentId();
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.active_parsers.put(allocator, thread_id, sequence);
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

    fn parseBuffer(self: *Parser, file_buffer: *SourceBuffer, parent: Class, pos: ?*SourcePosition, allocator: Allocator, io: std.Io) !void {
        try self.registerParserThread(std.math.maxInt(usize), allocator);
        defer self.unregisterParserThread();

        const input = try file_buffer.source.contents(io, allocator);
        defer allocator.free(input);

        try self.parseInput(input, file_buffer, parent, &pos, allocator, io);
    }

    fn parseInput(self: *Parser, input: []const u8, buf: *SourceBuffer, parent: Class, pos: *SourcePosition, allocator: Allocator, io: std.Io) !void {
        var position: SourcePosition = pos orelse .{
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
                try handleClass(self, input, buf, parent, &position);
            } else if (std.mem.eql(u8, word, "delete")) {
                try handleDelete(input, buf.source.name, parent, &position, allocator);
            } else if (std.mem.eql(u8, word, "enum")) {
                try handleEnum(self, input, buf, parent, &position, allocator, io);
            }  else if (std.mem.eql(u8, word, "__EXEC")) {
                try handleExecute(self, input, buf, parent, &position);
            } else {
                try handleParam(self, input, buf.source.name, parent, word, &position, allocator, io);
            }
        }
    }

    fn parseArray(self: *Parser, input: []const u8, dbg_name: []const u8, parent: Class, name: []const u8, op: Operator, pos: *SourcePosition, allocator: Allocator, io: std.Io) !void {
        const arr_stack = std.ArrayList(ArrayData).empty;
        defer arr_stack .deinit(allocator);
        var curr = ArrayData.empty;
        arr_stack.append(allocator, curr);
        const expect_separator: ?bool = false;

        while (true) {
            lexer.skipWhitespace(input, pos);
            switch (input[pos.index]) {
                '{' =>{
                    const new_array = ArrayData.empty;
                    try arr_stack.append(allocator, new_array);
                    curr = new_array;
                    pos.index += 1;
                },
                '#' => {
                    pos.index += 1;
                    continue;
                },
                '}' => {
                    pos.index += 1;
                    if (arr_stack.items.len == 1) {
                        break;
                    }

                    const completed_array = arr_stack.pop().?;
                    curr = arr_stack.getLast();
                    try curr.append(
                        Value.initArray(try self.store.allocArray(completed_array, allocator)),
                        allocator,
                    );
                },
                '@' => {
                    pos.index += 1;
                    std.log.err("[{s}] Array param expressions not yet implemented", .{dbg_name});
                    return error.ExpressionsNotImplemented;
                },
                else => {
                    var found_quote: bool = false;
                    const value_string = try lexer.getWord(
                        input,
                        dbg_name,
                        pos,
                        ",;}",
                        &found_quote,
                        allocator,
                    );

                    const next = input[pos.index];
                    expect_separator = null;

                    if(next == ',' or next == ';') {
                        expect_separator = true;
                    }

                    if(!found_quote) {
                        if(value_string.len > 7 and std.mem.eql(u8, value_string[0..6], "__EVAL")) {
                            std.log.err("[{s}] Array param evaluation not yet implemented", .{dbg_name});
                            return error.ExpressionsNotImplemented;
                        }

                        const scanned_value = try scanner.scanInt(value_string) orelse
                            try scanner.scanFloat(input) orelse
                            Value.initString(try self.store.internString(value_string, allocator));
                        try curr.append(scanned_value, allocator);

                    } else {
                        try curr.append(
                            Value.initString(try self.store.internString(value_string, allocator)),
                            allocator,
                        );
                    }
                },
            }

            lexer.skipWhitespace(input, &pos);
            const next = input[pos.index];
            pos.index+= 1;
            if(next != ',' or next != ';') {
                pos.index += 1;
                std.log.err("[{s}] Expected ',' or ';' after array value", .{dbg_name});
                return error.ExpectedArraySeparator;
            }
        }
        lexer.skipWhitespace(input, pos);

        //todo handle operator
        _ = op;

        return parent.setValue(
            name,
            Value.initArray(try self.store.allocArray(curr, allocator)),
            allocator,
            io
        );
    }

    fn handleParam(self: *Parser, input: []const u8, dbg_name: []const u8, parent: Class, name: []const u8, pos: *SourcePosition, allocator: Allocator, io: std.Io) !void {
        if(input[pos.index] == '[') {
            return self.handleArray(input, dbg_name, parent, name, pos, allocator, io);
        }

        lexer.skipWhitespace(input, pos);
        if(input[pos.index] != '=') {
            std.log.err("[{s}] Expected '=' after param name '{s}'", .{dbg_name, name});
            return error.ExpectedEqualsSign;
        }
        pos.index += 1;
        lexer.skipWhitespace(input, pos);

        const expression = input[pos.index] == '@';
        if (expression) {
            pos.index += 1;
            return error.ExpressionsNotImplemented;
        }

        var found_quote: bool = false;
        const value_string = try lexer.getWord(
            input,
            dbg_name,
            pos,
            ";}",
            &found_quote,
            allocator,
        );

        const next = input[pos.index];
        if(next == '}') {
            std.log.err("[{s}] Expected ';' after param value for '{s}'", .{dbg_name, name});
        } else if (next != ';') {
            if(next != '\n' and next != '\r' and !found_quote) {
                std.log.err("[{s}] Expected ';' after param value for '{s}'", .{dbg_name, name});
                return error.MissingSemicolon;
            }
            std.log.err("[{s}] Expected ';' after param value for '{s}'", .{dbg_name, name});
        } else {
            pos.index += 1;
        }

        if(!found_quote) {
            if(value_string.len > 7 and std.mem.eql(u8, value_string[0..6], "__EVAL")) {
                std.log.warn("[{s}] Param evaluation not yet implemented", .{dbg_name});
                return error.ExpressionsNotImplemented;
            }

            const scanned_value = try scanner.scanInt(value_string) orelse
                try scanner.scanInt64(input) orelse
                try scanner.scanFloat(input);
            if(scanned_value) |sv| {
                try parent.setValue(name, sv, allocator, io);
            }

            return;
        }

        try parent.setValue(
            name,
            Value.initString(try self.store.internString(value_string, allocator)),
            allocator,
            io
        );
    }

    fn handleArray(self: *Parser, input: []const u8, dbg_name: []const u8, parent: Class, name: []const u8, pos: *SourcePosition, allocator: Allocator, io: std.Io) !void {
        lexer.skipWhitespace(input, &pos);
        if(input[pos.index] != ']') {
            std.log.err("[{s}] Expected ']' after '[' in param array for '{s}'", .{dbg_name, name});
            return error.ExpectedCloseBracket;
        }
        pos.index += 1;
        lexer.skipWhitespace(input, &pos);

        const operator = try scanner.scanOperator(input, dbg_name, &pos);
        lexer.skipWhitespace(input, &pos);

        try self.parseArray(input, dbg_name, parent, name, operator, &pos, allocator, io);
    }

    fn handleExecute(self: *Parser, input: []const u8, buf: *SourceBuffer, parent: Class, pos: *SourcePosition) !void {
        _ = self;
        _ = input;
        _ = parent;
        _ = pos;

        std.log.err("[{s}] __EXEC directive not yet implemented", .{buf.source.name});
        return error.ExecuteNotImplemented;
    }

    fn handleEnum(self: *Parser, input: []const u8, buf: *SourceBuffer, pos: *SourcePosition, allocator: Allocator, io: std.Io) !void {
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
            try self.tree.setEnum(word, enum_value, allocator, io);
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

    fn handleDelete(input: []const u8, debug_name: []const u8, parent: Class, pos: *SourcePosition, allocator: Allocator ) !void {
        const target_name = lexer.getAlphaWord(input, &pos);
        lexer.skipWhitespace(input, &pos);

        if(input[pos.index] != ';') {
            std.log.err("[{s}] Expected ';' after delete statement for class '{s}'", .{debug_name, target_name});
            return error.ExpectedSemicolon;
        }
        pos.index += 1;
        
        try parent.deleteClass(target_name, allocator);
    }

    fn handleClass(self: *Parser, input: []const u8, buf: *SourceBuffer, parent: Class, pos: *SourcePosition, ) !void {
        const start_index = pos.index;
        const class_def = try lexer.extractClassDefinition(input, pos);
        buf.retain();
        const sequence = self.sequence_counter.fetchAdd(1, .monotonic);

        var job_def = class_def;
        job_def.start_index = start_index;

        const job = try job_def.toJob(sequence, buf, parent);
        try self.job_queue.push(job);
    }

    fn workerThreadFn(self: *Parser, allocator: Allocator, io: std.Io) void {
        while (true) {
            if (self.shutdown.load(.acquire)) break;

            var job = self.job_queue.waitForJob(&self.shutdown) orelse break;
            const sequence = job.sequence;
            defer {
                job.deinit(self.allocator);
                job.file_buffer.release(self.io, self.allocator);
            }

            self.registerParserThread(sequence) catch continue;
            defer self.unregisterParserThread();

            self.processClassJob(&job, allocator, io) catch |err| {
                std.log.err("[{s}] Error processing class '{s}': {}", .{
                    job.debug_name,
                    job.class_name,
                    err,
                });
            };
        }
    }

    fn processClassJob(self: *Parser, job: *const ClassJob, allocator: Allocator, io: std.Io) !void {
        const class = try job.parent.getOrCreateChild(job.class_name, allocator, io);

        if (job.base_name) |base_name| {
            class.setBase(try self.waitForBase(base_name, job), allocator, io);
        }

        if (job.body) |body| {
            var body_positon = SourcePosition{
                .index = 0,
                .line = job.start_line,
                .line_start = 0,
            };

            try self.parseInput(
                body,
                job.file_buffer,
                class,
                &body_positon,
                allocator,
                io
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
};