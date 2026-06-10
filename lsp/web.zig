const std = @import("std");
const lsp    = @import("lsp");
const parLsp = @import("lsp.zig");

var allocator = std.heap.wasm_allocator;

const RX_SIZE = 8 * 1024 * 1024;
const TX_SIZE = 8 * 1024 * 1024;
var tx_buf: [TX_SIZE]u8 = undefined;
var rx_buf: [RX_SIZE]u8 = undefined;
var tx_len: usize = 0;

var reader: std.Io.Reader = undefined;
var writer: std.Io.Writer = undefined;
var documents: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
var schema_manager: parLsp.SchemaManager = .empty;

fn readJsonMessage(
    _: *lsp.Transport,
    _: std.Io,
    _: std.mem.Allocator,
) lsp.Transport.ReadError![]u8 {
    return lsp.readJsonMessage(&reader, allocator) catch |err| switch (err) {
        error.ReadFailed => error.Unexpected,
        else => |e| e,
    };
}

fn writeJsonMessage(
    _: *lsp.Transport,
    _: std.Io,
    json_message: []const u8,
) lsp.Transport.WriteError!void {
    writer = std.Io.Writer.fixed(tx_buf[tx_len..]);
    lsp.writeJsonMessage(&writer, json_message) catch |err| switch (err) {
        error.WriteFailed => return error.Unexpected,
    };
    tx_len += writer.end;
}

const vtable = lsp.Transport.VTable{
    .readJsonMessage  = readJsonMessage,
    .writeJsonMessage = writeJsonMessage,
};

var wasm_transport = lsp.Transport{
    .vtable = &vtable,
};


extern fn clientSend(ptr: [*]const u8, len: u32) void;

export fn alloc(len: u32) u32 {
    const buf = allocator.alloc(u8, len) catch return 0;
    return @intCast(@intFromPtr(buf.ptr));
}

export fn free(ptr: u32, len: u32) void {
    const p: [*]u8 = @ptrFromInt(ptr);
    allocator.free(p[0..len]);
}

pub export fn custom_log(ptr: [*]const u8, len: usize) void {
    wasm_log(ptr, len);
}

extern fn wasm_log(ptr: [*]const u8, len: usize) void;

export fn serverSend(ptr: [*]const u8, len: u32) u32 {
    @memcpy(rx_buf[0..len], ptr[0..len]);
    reader = std.Io.Reader.fixed(rx_buf[0..RX_SIZE]);
    tx_len = 0;

    const json_message = wasm_transport.readJsonMessage(undefined, allocator) catch return 1;
    defer allocator.free(json_message);

    const msg = parLsp.Message.parseFromSlice(
        allocator, json_message, .{ .ignore_unknown_fields = true },
    ) catch return 2;
    defer msg.deinit();

    parLsp.handleMessage(&documents, &schema_manager, allocator, undefined, msg, &wasm_transport) catch return 3;

    if (tx_len > 0) clientSend(tx_buf[0..tx_len].ptr, @intCast(tx_len));

    return 0;
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
    for (documents.keys())   |k| allocator.free(k);
    for (documents.values()) |v| allocator.free(v);
    documents.deinit(allocator);
    schema_manager.deinit(allocator);
}