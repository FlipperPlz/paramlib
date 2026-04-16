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

export fn serverSend(ptr: [*]const u8, len: u32) u32 {
    @memcpy(rx_buf[0..len], ptr[0..len]);
    reader = std.Io.Reader.fixed(rx_buf[0..len]);
    tx_len = 0;

    const json_message = wasm_transport.readJsonMessage(undefined, allocator) catch return 1;
    defer allocator.free(json_message);

    const msg = parLsp.Message.parseFromSlice(
        allocator, json_message, .{ .ignore_unknown_fields = true },
    ) catch return 2;
    defer msg.deinit();

    parLsp.handleMessage(&documents, allocator, undefined, msg, &wasm_transport) catch return 3;

    if (tx_len > 0) clientSend(tx_buf[0..tx_len].ptr, @intCast(tx_len));

    return 0;
}

export fn deinit() void {
    for (documents.keys())   |k| allocator.free(k);
    for (documents.values()) |v| allocator.free(v);
    documents.deinit(allocator);
}