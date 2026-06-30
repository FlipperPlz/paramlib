const std = @import("std");
const lsp = @import("lsp");
const paramlib = @import("paramlib");
const paramlsp = @import("paramlsp");

const allocator = std.heap.wasm_allocator;

var documents: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
var schema_manager: paramlsp.SchemaManager = .empty;

extern fn wasm_log(ptr: [*]const u8, len: usize) void;
extern fn reportError(ptr: [*]const u8, len: usize) void;

fn hostLog(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    wasm_log(msg.ptr, msg.len);
}

fn hostError(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    reportError(msg.ptr, msg.len);
}

const WasmTransport = struct {
    reader: std.Io.Reader,
    writer: std.Io.Writer,
    bytes_written: usize = 0,
    transport: lsp.Transport = .{ .vtable = &vtable },

    const vtable = lsp.Transport.VTable{
        .readJsonMessage  = readJsonMessage,
        .writeJsonMessage = writeJsonMessage,
    };

    fn readJsonMessage(
        ctx: *lsp.Transport,
        _: std.Io,
        _: std.mem.Allocator,
    ) lsp.Transport.ReadError![]u8 {
        const self: *WasmTransport = @fieldParentPtr("transport", ctx);
        return lsp.readJsonMessage(&self.reader, allocator) catch |err| switch (err) {
            error.ReadFailed => error.Unexpected,
            else => |e| e,
        };
    }

    fn writeJsonMessage(
        ctx: *lsp.Transport,
        _: std.Io,
        json_message: []const u8,
    ) lsp.Transport.WriteError!void {
        const self: *WasmTransport = @fieldParentPtr("transport", ctx);
        lsp.writeJsonMessage(&self.writer, json_message) catch |err| switch (err) {
            error.WriteFailed => return error.Unexpected,
        };
        self.bytes_written += self.writer.end;
    }
};

export fn alloc(len: u32) u32 {
    const buf = allocator.alloc(u8, len) catch return 0;
    return @intCast(@intFromPtr(buf.ptr));
}

export fn free(ptr: u32, len: u32) void {
    const p: [*]u8 = @ptrFromInt(ptr);
    allocator.free(p[0..len]);
}
export fn parse(in_ptr: [*]const u8, in_len: usize, out_ptr: [*]u8, out_max: usize) i32 {
    var wt = WasmTransport{
        .reader = std.Io.Reader.fixed(in_ptr[0..in_len]),
        .writer = std.Io.Writer.fixed(out_ptr[0..out_max]),
    };

    const json_message = wt.transport.readJsonMessage(undefined, allocator) catch |err| {
        hostError("core: parse: readJsonMessage failed: {s}", .{@errorName(err)});
        return -1;
    };
    defer allocator.free(json_message);

    const msg = paramlsp.Message.parseFromSlice(
        allocator, json_message, .{ .ignore_unknown_fields = true },
    ) catch |err| {
        hostError("core: parse: Message.parseFromSlice failed: {s}", .{@errorName(err)});
        return -1;
    };
    defer msg.deinit();

    paramlsp.handleMessage(
        &documents, &schema_manager, allocator, undefined, msg, &wt.transport,
    ) catch |err| {
        hostError("core: parse: handleMessage failed: {s}", .{@errorName(err)});
        return -1;
    };

    return @intCast(wt.bytes_written);
}

export fn schemaUpdate(uri_ptr: [*]const u8, uri_len: u32, content_ptr: [*]const u8, content_len: u32, class_ptr: [*]const u8, class_len: u32) void {
    const class_name: ?[]const u8 = if (class_len > 0) class_ptr[0..class_len] else null;
    const uri = uri_ptr[0..uri_len];
    schema_manager.updateSchema(allocator, uri, content_ptr[0..content_len], class_name) catch return;

    const dir = if (std.mem.lastIndexOfScalar(u8, uri, '/')) |idx|
        uri[0 .. idx + 1]
    else
        uri;

    if (schema_manager.schemas.getPtr(dir)) |s| {
        s.extractFromDocuments(&schema_manager, allocator, &documents, dir) catch return;
    }
}

export fn deinit() void {
    for (documents.keys()) |k| allocator.free(k);
    for (documents.values()) |v| allocator.free(v);
    documents.deinit(allocator);
    schema_manager.deinit(allocator);
}
