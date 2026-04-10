/// LSP server entry point.
///
/// The main loop is intentionally boring:
///
///   loop:
///     1. read one framed message from stdin
///     2. parse the JSON-RPC envelope (method + id)
///     3. dispatch to the correct handler
///     4. if the handler returned a result, write a response
///     5. free everything and go to 1
///
/// All state lives in DocumentStore.  All I/O is synchronous on a single
/// thread — correct and simple for an LSP that parses fast enough to keep
/// up with keystroke events (your benchmarks show <100µs per file).

const std       = @import("std");
const transport = @import("transport.zig");
const handlers  = @import("handlers.zig");
const store_mod = @import("document_store.zig");
const types     = @import("types.zig");

pub fn main(init: std.process.Init) !void {
    // ── Allocator ─────────────────────────────────────────────────────────
    // GPA catches leaks in debug builds.  In release you could swap to a
    // page allocator for lower overhead, but GPA is fine here.
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // ── Document store ────────────────────────────────────────────────────
    var store = store_mod.DocumentStore.init(gpa);
    store.io  = init.io;          // stash io so doParse can forward it
    defer store.deinit();

    // ── Handler context ───────────────────────────────────────────────────
    var ctx = handlers.Context{
        .allocator = gpa,
        .store     = &store,
    };

    log("cpp-lsp started", .{});

    // ── Main loop ─────────────────────────────────────────────────────────
    while (!ctx.exit_requested) {
        // 1. Read one message (blocking).
        const raw = transport.readMessage(gpa) catch |e| {
            log("transport error: {s}", .{@errorName(e)});
            break;
        };
        defer gpa.free(raw);

        // 2. Parse envelope.
        const envelope = parseEnvelope(gpa, raw) catch |e| {
            log("envelope parse error: {s}", .{@errorName(e)});
            // Send parse error back — but we don't have an id, so use null.
            transport.writeError(gpa, "null",
                transport.RpcError.parse_error, "invalid JSON");
            continue;
        };
        defer envelope.arena.deinit();

        const method = envelope.method orelse {
            // Response message (no method) — we never send requests, so ignore.
            continue;
        };

        // Serialize id back to JSON for use in response.
        const id_json = serializeId(gpa, envelope.id) catch "null";
        defer gpa.free(id_json);

        log("-> {s}", .{method});

        // 3. Dispatch.
        const is_notification = envelope.id == null;
        const result = dispatch(&ctx, method, envelope.params) catch |e| {
            log("handler error [{s}]: {s}", .{ method, @errorName(e) });
            if (!is_notification) {
                transport.writeError(gpa, id_json,
                    transport.RpcError.internal_error, @errorName(e));
            }
            continue;
        };

        // 4. Write response (only for requests, not notifications).
        if (!is_notification) {
            if (result) |res| {
                defer gpa.free(res);
                transport.writeResult(gpa, id_json, res);
            } else {
                // Handler returned null for a request -- respond with null result.
                transport.writeResult(gpa, id_json, "null");
            }
        }
        // Notifications that return null produce no output (correct per spec).
    }

    log("cpp-lsp exiting", .{});
}

// -- Dispatcher ----------------------------------------------------------------

fn dispatch(ctx: *handlers.Context, method: []const u8, params: ?std.json.Value) !?[]u8 {
    const p = params orelse std.json.Value{ .null = {} };

    // Requests
    if (std.mem.eql(u8, method, "initialize"))               return handlers.handleInitialize(ctx, p);
    if (std.mem.eql(u8, method, "shutdown"))                 return handlers.handleShutdown(ctx, p);

    // Notifications (handlers return null)
    if (std.mem.eql(u8, method, "initialized"))              return handlers.handleInitialized(ctx, p);
    if (std.mem.eql(u8, method, "exit"))                     return handlers.handleExit(ctx, p);
    if (std.mem.eql(u8, method, "textDocument/didOpen"))     return handlers.handleDidOpen(ctx, p);
    if (std.mem.eql(u8, method, "textDocument/didChange"))   return handlers.handleDidChange(ctx, p);
    if (std.mem.eql(u8, method, "textDocument/didClose"))    return handlers.handleDidClose(ctx, p);

    // Hover request
    if (std.mem.eql(u8, method, "textDocument/hover"))       return handlers.handleHover(ctx, p);

    // Unknown -- for requests we must respond with method-not-found.
    // For notifications ($/...) we can silently ignore.
    if (std.mem.startsWith(u8, method, "$/")) return null;

    log("unknown method: {s}", .{method});
    return error.MethodNotFound;
}

// -- Envelope parsing ----------------------------------------------------------

const Envelope = struct {
    arena:  std.heap.ArenaAllocator,
    id:     ?std.json.Value,
    method: ?[]const u8,
    params: ?std.json.Value,
};

fn parseEnvelope(allocator: std.mem.Allocator, raw: []const u8) !Envelope {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    // Parse the entire JSON document into the arena -- all slices live there.
    const doc = try std.json.parseFromSlice(std.json.Value, arena.allocator(), raw, .{});
    const root = doc.value;

    if (root != .object) return error.InvalidRequest;
    const obj = root.object;

    const id     = obj.get("id");
    const method = if (obj.get("method")) |m| (if (m == .string) m.string else null) else null;
    const params = obj.get("params");

    return Envelope{
        .arena  = arena,
        .id     = id,
        .method = method,
        .params = params,
    };
}

fn serializeId(allocator: std.mem.Allocator, id: ?std.json.Value) ![]u8 {
    const v = id orelse return allocator.dupe(u8, "null");
    return std.json.stringifyAlloc(allocator, v, .{});
}

// -- Logging (stderr only) -----------------------------------------------------

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[cpp-lsp] " ++ fmt ++ "\n", args);
}
