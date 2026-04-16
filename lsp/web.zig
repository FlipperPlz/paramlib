const std = @import("std");
const lsp    = @import("lsp");
const parLsp = @import("lsp.zig");

var allocator = std.heap.wasm_allocator;

const RX_SIZE = 8 * 1024 * 1024;
const TX_SIZE = 8 * 1024 * 1024;
var tx_buf: [TX_SIZE]u8 = undefined;
var rx_buf: [RX_SIZE]u8 = undefined;
var rx_head: usize = 0;
var tx_head: usize = 0;
var rx_tail: usize = 0;
var tx_tail: usize = 0;

var reader: std.Io.Reader = undefined;
var writer: std.Io.Writer = undefined;

extern fn clientSend(ptr: [*]const u8, len: u32) void;

export fn serverSend(ptr: [*]const u8, len: u32) void {
    const data = ptr[0..len];
    for (data) |b| {
        rx_buf[rx_tail % RX_SIZE] = b;
        rx_tail += 1;
    }
}

export fn wasmInit() void {
    reader = std.Io.Reader.fixed(&rx_buf);
    writer = std.Io.Writer.fixed(&tx_buf);

    parLsp.startServer(undefined, allocator, &wasm_transport) catch unreachable;
}

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
    lsp.writeJsonMessage(&writer, json_message) catch |err| switch (err) {
        error.WriteFailed => return error.Unexpected,
    };
    if (tx_head == tx_tail) return;
    serverSend(tx_buf[tx_head..tx_tail].ptr, @intCast(tx_tail - tx_head));
    tx_head = tx_tail;
}


const vtable = lsp.Transport.VTable{
    .readJsonMessage  = readJsonMessage,
    .writeJsonMessage = writeJsonMessage,
};

var wasm_transport = lsp.Transport{
    .vtable = &vtable,
};
