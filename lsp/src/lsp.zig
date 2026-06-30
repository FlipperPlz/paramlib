const std      = @import("std");
const lsp      = @import("lsp");
const paramlib = @import("paramlib");
const builtin  = @import("builtin");

// Logging sink shared by all paramlsp consumers (native LSP server, WASM
// bridge, and standalone tests). A single real definition here avoids
// duplicate-symbol issues across build targets.
export fn custom_log(ptr: [*]const u8, len: usize) void {
    // std.debug.print pulls in the default threaded Io backend, which needs
    // OS support (getrandom, IOV_MAX, ...) that freestanding targets like
    // wasm32-freestanding don't have. The WASM build bridges logging through
    // its own host import instead (see extensions/vsc core.zig's hostLog),
    // so this is a no-op there.
    if (builtin.os.tag == .freestanding) return;
    std.debug.print("{s}\n", .{ptr[0..len]});
}

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    custom_log(msg.ptr, msg.len);
}

pub const StringCompletionRule = struct {
    path:   []const u8,
    values: []const []const u8,
    source: []const u8 = "",
};

pub const ArrayInlaysRule = struct {
    path:   []const u8,
    labels: []const []const u8,
    source: []const u8 = "",
};

pub const ParserRule = struct {
    pattern:     []const u8,
    wasm_source: []const u8,
    source:      []const u8 = "",
};

pub const ParamDocRule = struct {
    path:   []const u8,
    doc:    []const u8,
    source: []const u8 = "",
};

pub const PrecomputedParserHint = struct {
    line: u32,
    character: u32,
    text: []const u8,
    length: u32 = 0,
};

pub const ParserHintsParams = struct {
    uri: []const u8,
    hints: []const PrecomputedParserHint,
};

pub const GetDocumentParams = struct {
    textDocument: lsp.types.TextDocument.Identifier,
};

pub const Position = struct {
    line: u32,
    character: u32,
};

pub const DocumentParam = struct {
    path: []const u8,
    value: []const u8,
    line: u32,
    character: u32,
    value_line: u32,
    value_character: u32,
    elem_positions: []const Position = &.{},
};

pub const GetDocumentParamsResult = struct {
    params: []const DocumentParam,
};

pub const SchemaManager = struct {
    schemas: std.StringArrayHashMapUnmanaged(SchemaState) = .empty,
    documentHints: std.StringArrayHashMapUnmanaged([]const PrecomputedParserHint) = .empty,

    pub const empty: SchemaManager = .{};

    pub fn deinit(self: *SchemaManager, alloc: std.mem.Allocator) void {
        var it = self.schemas.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            entry.value_ptr.deinit(alloc);
        }
        self.schemas.deinit(alloc);

        var hint_it = self.documentHints.iterator();
        while (hint_it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |h| alloc.free(h.text);
            alloc.free(entry.value_ptr.*);
        }
        self.documentHints.deinit(alloc);
        self.* = .empty;
    }

    pub fn getSchemaForUri(self: *const SchemaManager, uri: []const u8) *const SchemaState {
        var best_match: ?*const SchemaState = null;
        var best_len: usize = 0;

        var it = self.schemas.iterator();
        while (it.next()) |entry| {
            const schemaUri = entry.key_ptr.*;
            const has_slash = schemaUri.len > 0 and schemaUri[schemaUri.len - 1] == '/';
            
            if (std.mem.startsWith(u8, uri, schemaUri)) {
                if (schemaUri.len > best_len) {
                    best_len = schemaUri.len;
                    best_match = entry.value_ptr;
                }
            } else if (!has_slash) {
                var buf: [1024]u8 = undefined;
                if (schemaUri.len < 1023) {
                    @memcpy(buf[0..schemaUri.len], schemaUri);
                    buf[schemaUri.len] = '/';
                    const with_slash = buf[0 .. schemaUri.len + 1];
                    if (std.mem.startsWith(u8, uri, with_slash)) {
                        if (with_slash.len > best_len) {
                            best_len = with_slash.len;
                            best_match = entry.value_ptr;
                        }
                    }
                }
            }
        }

        if (best_match) |bm| return bm;
        if (self.schemas.count() > 0) return &self.schemas.values()[0];
        return &SchemaState.empty;
    }

    pub fn getSchemaKeyForUri(self: *const SchemaManager, uri: []const u8) ?[]const u8 {
        var best_match: ?[]const u8 = null;
        var best_len: usize = 0;

        var it = self.schemas.iterator();
        while (it.next()) |entry| {
            const schemaUri = entry.key_ptr.*;
            const has_slash = schemaUri.len > 0 and schemaUri[schemaUri.len - 1] == '/';
            
            if (std.mem.startsWith(u8, uri, schemaUri)) {
                if (schemaUri.len > best_len) {
                    best_len = schemaUri.len;
                    best_match = schemaUri;
                }
            } else if (!has_slash) {
                var buf: [1024]u8 = undefined;
                if (schemaUri.len < 1023) {
                    @memcpy(buf[0..schemaUri.len], schemaUri);
                    buf[schemaUri.len] = '/';
                    const with_slash = buf[0 .. schemaUri.len + 1];
                    if (std.mem.startsWith(u8, uri, with_slash)) {
                        if (with_slash.len > best_len) {
                            best_len = with_slash.len;
                            best_match = schemaUri;
                        }
                    }
                }
            }
        }

        if (best_match) |bm| return bm;
        if (self.schemas.count() > 0) return self.schemas.keys()[0];
        return null;
    }

    pub fn findGlobalSchemaState(self: *const SchemaManager, name: []const u8) ?*const SchemaState {
        var it = self.schemas.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.pushedSchemas.getPtr(name)) |s| return s;
        }
        return null;
    }

    pub fn collectAllSchemaClassNames(self: *const SchemaManager, alloc: std.mem.Allocator) ![]const []const u8 {
        var names = std.StringArrayHashMapUnmanaged(void).empty;
        defer names.deinit(alloc);

        var it = self.schemas.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.schemaClasses) |name| {
                try names.put(alloc, name, {});
            }
        }

        const result = try alloc.alloc([]const u8, names.count());
        errdefer alloc.free(result);

        for (names.keys(), 0..) |name, i| {
            result[i] = try alloc.dupe(u8, name);
        }

        std.mem.sort([]const u8, result, {}, struct {
            pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        return result;
    }

    pub fn updateSchema(self: *SchemaManager, alloc: std.mem.Allocator, schema_uri: []const u8, content: []const u8, class_name: ?[]const u8) !void {
        const dir = if (std.mem.lastIndexOfScalar(u8, schema_uri, '/')) |idx|
            schema_uri[0 .. idx + 1]
        else
            schema_uri;

        if (self.schemas.getPtr(dir)) |existing| {
            try existing.updateFromContent(self, alloc, content, class_name);
        } else {
            const key = try alloc.dupe(u8, dir);
            errdefer alloc.free(key);
            var state = SchemaState.empty;
            try state.updateFromContent(self, alloc, content, class_name);
            errdefer state.deinit(alloc);
            try self.schemas.put(alloc, key, state);
        }
    }
};

pub const SchemaState = struct {
    stringCompletions: []StringCompletionRule = &.{},
    arrayInlays: []ArrayInlaysRule = &.{},
    parserRules: []ParserRule = &.{},
    paramDocs: []ParamDocRule = &.{},
    schemaClasses: []const []const u8 = &.{},
    projectName:   []const u8          = "",
    selectedClass: []const u8          = "",
    base_class:    []const u8          = "",
    pushedSchemas: std.StringArrayHashMapUnmanaged(SchemaState) = .empty,

    pub const empty: SchemaState = .{};

    pub fn updateFromContent(self: *SchemaState, manager: *const SchemaManager, alloc: std.mem.Allocator, content: []const u8, class_name: ?[]const u8) !void {
        const src = try alloc.dupeZ(u8, content);
        defer alloc.free(src);
        var errored = false;
        var root = try paramlib.cpp.parser.parseSource(alloc, src, &errored, .none());
        defer root.deinit(alloc);

        const members = root.members orelse return;

        var it_pushed = self.pushedSchemas.iterator();
        while (it_pushed.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            entry.value_ptr.deinit(alloc);
        }
        self.pushedSchemas.clearRetainingCapacity();

        for (members.items) |*m| {
            if (m.* != .class) continue;
            const cfg = m.class;
            if (cfg.name == null or !std.mem.eql(u8, cfg.name.?, "CfgSchemas")) continue;
            const cfg_members = cfg.members orelse continue;

            for (cfg_members.items) |*cm| {
                if (cm.* != .class or cm.class.members == null) continue;
                const name = cm.class.name orelse continue;

                const state = try buildFromSchemaClass(manager, &root, cm.class, alloc, &self.pushedSchemas, name);
                errdefer { var s = state; s.deinit(alloc); }

                if (self.pushedSchemas.fetchOrderedRemove(name)) |entry| {
                    alloc.free(entry.key);
                    var s = entry.value;
                    s.deinit(alloc);
                }

                const key = try alloc.dupe(u8, name);
                errdefer alloc.free(key);
                try self.pushedSchemas.put(alloc, key, state);
            }
        }

        const sc = findSchemaClass(&root, alloc, class_name) orelse return;
        var new_state = try buildFromSchemaClass(manager, sc.root_ptr, sc.class_ptr, alloc, &self.pushedSchemas, sc.class_ptr.name orelse "");
        errdefer new_state.deinit(alloc);

        new_state.pushedSchemas = self.pushedSchemas;
        self.pushedSchemas = .empty;

        new_state.schemaClasses = try collectSchemaClassNames(&root, alloc);
        new_state.selectedClass = try alloc.dupe(u8, sc.class_ptr.name orelse "");

        self.deinit(alloc);
        self.* = new_state;
    }

    pub fn extractFromDocuments(
        self:      *SchemaState,
        manager:   *const SchemaManager,
        alloc:     std.mem.Allocator,
        documents: *const std.StringArrayHashMapUnmanaged([]const u8),
        dir_uri:   []const u8,
    ) !void {
        log("[SchemaState.extractFromDocuments] extracting from {d} documents (dir={s})", .{documents.count(), dir_uri});
        const pushed = self.pushedSchemas;
        const selected = try alloc.dupe(u8, self.selectedClass);
        defer alloc.free(selected);

        self.pushedSchemas = .empty;
        self.deinit(alloc);
        self.pushedSchemas = pushed;

        var named = std.StringArrayHashMapUnmanaged(SchemaState).empty;
        defer {
            var it = named.iterator();
            while (it.next()) |entry| {
                alloc.free(entry.key_ptr.*);
                entry.value_ptr.deinit(alloc);
            }
            named.deinit(alloc);
        }

        var all_names = std.ArrayList([]const u8).empty;
        defer {
            for (all_names.items) |n| alloc.free(n);
            all_names.deinit(alloc);
        }

        var pushed_it = self.pushedSchemas.iterator();
        while (pushed_it.next()) |entry| {
            const name = entry.key_ptr.*;
            const key = try alloc.dupe(u8, name);
            errdefer alloc.free(key);
            const state = try cloneSchemaState(entry.value_ptr.*, alloc);
            errdefer { var s = state; s.deinit(alloc); }
            try named.put(alloc, key, state);

            const n = try alloc.dupe(u8, name);
            errdefer alloc.free(n);
            try all_names.append(alloc, n);
        }

        var doc_it = documents.iterator();
        var any_has_cfg_schemas = false;

        while (doc_it.next()) |entry| {
            const uri  = entry.key_ptr.*;
            const text = entry.value_ptr.*;
            if (dir_uri.len > 0 and !std.mem.startsWith(u8, uri, dir_uri)) continue;

            const src = try alloc.dupeZ(u8, text);
            defer alloc.free(src);
            var errored = false;
            var root = try paramlib.cpp.parser.parseSource(alloc, src, &errored, .none());
            defer root.deinit(alloc);

            if (getCfgSchemasMembers(&root)) |_| {
                any_has_cfg_schemas = true;
                break;
            }
        }

        var active: SchemaState = .empty;
        errdefer active.deinit(alloc);
        doc_it = documents.iterator();
        var last_class_def_name: ?[]const u8 = null;
        var last_is_primary = false;
        defer if (last_class_def_name) |n| alloc.free(n);

        while (doc_it.next()) |entry| {
            const uri  = entry.key_ptr.*;
            const text = entry.value_ptr.*;
            if (dir_uri.len > 0 and !std.mem.startsWith(u8, uri, dir_uri)) continue;

            const src = try alloc.dupeZ(u8, text);
            defer alloc.free(src);
            var errored = false;
            var root = try paramlib.cpp.parser.parseSource(alloc, src, &errored, .none());
            defer root.deinit(alloc);

            const has_cfg = getCfgSchemasMembers(&root) != null;
            if (any_has_cfg_schemas and !has_cfg) continue;

            const is_primary = std.mem.endsWith(u8, uri, "/paramlib.cpp") or std.mem.eql(u8, uri, "paramlib.cpp");

            const names = try collectSchemaClassNames(&root, alloc);
            defer {
                for (names) |n| alloc.free(n);
                alloc.free(names);
            }

            for (names) |name| {
                var already = false;
                for (all_names.items) |n| {
                    if (std.mem.eql(u8, n, name)) { already = true; break; }
                }
                if (!already) {
                    const n = try alloc.dupe(u8, name);
                    errdefer alloc.free(n);
                    try all_names.append(alloc, n);
                }

                if (findSchemaClass(&root, alloc, name)) |sc| {
                    if (sc.class_ptr.members != null) {
                        const state = try buildFromSchemaClass(manager, sc.root_ptr, sc.class_ptr, alloc, &named, name);
                        errdefer { var s = state; s.deinit(alloc); }
                        if (named.fetchOrderedRemove(name)) |entry_rem| {
                            alloc.free(entry_rem.key);
                            var s = entry_rem.value;
                            s.deinit(alloc);
                        }
                        const key = try alloc.dupe(u8, name);
                        errdefer alloc.free(key);
                        try named.put(alloc, key, state);

                        const is_better = if (last_class_def_name == null) true else blk: {
                            if (is_primary and !last_is_primary) break :blk true;
                            if (is_primary == last_is_primary) break :blk true;
                            break :blk false;
                        };

                        if (is_better) {
                            if (last_class_def_name) |lcn| alloc.free(lcn);
                            last_class_def_name = try alloc.dupe(u8, name);
                            last_is_primary = is_primary;
                        }
                    }
                }
            }
        }

        var final_selected_class: []const u8 = "";
        if (selected.len > 0) {
            final_selected_class = try alloc.dupe(u8, selected);
        } else if (last_class_def_name) |lcdn| {
            final_selected_class = try alloc.dupe(u8, lcdn);
        }
        errdefer if (final_selected_class.len > 0) alloc.free(final_selected_class);

        if (final_selected_class.len > 0) {
            if (named.get(final_selected_class)) |state| {
                active.deinit(alloc);
                active = try cloneSchemaState(state, alloc);
            }
        }

        active.schemaClasses = try all_names.toOwnedSlice(alloc);

        const SortCtx = struct {
            named: *const std.StringArrayHashMapUnmanaged(SchemaState),
            pub fn lessThan(ctx: @This(), a: []const u8, b: []const u8) bool {
                const state_a = ctx.named.get(a);
                const state_b = ctx.named.get(b);
                const a_is_def = if (state_a) |s| s.stringCompletions.len > 0 or s.parserRules.len > 0 or s.paramDocs.len > 0 or s.pushedSchemas.count() > 0 or s.selectedClass.len > 0 else false;
                const b_is_def = if (state_b) |s| s.stringCompletions.len > 0 or s.parserRules.len > 0 or s.paramDocs.len > 0 or s.pushedSchemas.count() > 0 or s.selectedClass.len > 0 else false;
                if (a_is_def != b_is_def) return !a_is_def;
                return std.mem.lessThan(u8, a, b);
            }
        };
        const classes = @constCast(active.schemaClasses);
        std.mem.sort([]const u8, classes, SortCtx{ .named = &named }, SortCtx.lessThan);

        if (active.selectedClass.len > 0) alloc.free(active.selectedClass);
        active.selectedClass = final_selected_class;

        if (active.projectName.len > 0) alloc.free(active.projectName);
        active.projectName = try alloc.dupe(u8, self.projectName);

        active.pushedSchemas = self.pushedSchemas;
        self.pushedSchemas = .empty;

        self.deinit(alloc);
        self.* = active;
        log("[SchemaState.extractFromDocuments] final state: {d} paramDocs, {d} stringCompletions, projectName='{s}', selectedClass='{s}'", .{active.paramDocs.len, active.stringCompletions.len, active.projectName, active.selectedClass});
    }

    const SchemaClass = struct {
        root_ptr:  *const paramlib.cpp.ast.ClassAst,
        class_ptr: *const paramlib.cpp.ast.ClassAst,
    };

    fn findSchemaClass(
        root:       *const paramlib.cpp.ast.ClassAst,
        alloc:      std.mem.Allocator,
        class_name: ?[]const u8,
    ) ?SchemaClass {
        _ = alloc;
        const members = root.members orelse return null;
        var last_def: ?*const paramlib.cpp.ast.ClassAst = null;
        var last_any: ?*const paramlib.cpp.ast.ClassAst = null;

        var found_cfg = false;
        for (members.items) |*m| {
            if (m.* != .class or m.class.name == null) continue;
            if (!std.mem.eql(u8, m.class.name.?, "CfgSchemas")) continue;
            found_cfg = true;

            if (m.class.members) |cfg_members| {
                for (cfg_members.items) |*cm| {
                    if (cm.* != .class) continue;
                    const inner = cm.class;
                    const name = inner.name orelse continue;

                    if (class_name) |cn| {
                        if (std.mem.eql(u8, cn, name))
                            return .{ .root_ptr = root, .class_ptr = inner };
                    } else {
                        if (inner.members != null) last_def = inner;
                        last_any = inner;
                    }
                }
            }
        }

        if (!found_cfg) {
            for (members.items) |*m| {
                if (m.* != .class) continue;
                const cls = m.class;
                const name = cls.name orelse continue;

                if (class_name) |cn| {
                    if (std.mem.eql(u8, cn, name))
                        return .{ .root_ptr = root, .class_ptr = cls };
                } else {
                    if (cls.members != null) last_def = cls;
                    last_any = cls;
                }
            }
        }

        if (class_name == null) {
            if (last_def) |ld| return .{ .root_ptr = root, .class_ptr = ld };
            if (last_any) |la| return .{ .root_ptr = root, .class_ptr = la };
        }
        return null;
    }

    fn collectSchemaClassNames(
        root:  *const paramlib.cpp.ast.ClassAst,
        alloc: std.mem.Allocator,
    ) ![]const []const u8 {
        const members = root.members orelse return &.{};
        var list = std.ArrayList([]const u8).empty;
        errdefer {
            for (list.items) |n| alloc.free(n);
            list.deinit(alloc);
        }

        for (members.items) |*m| {
            if (m.* != .class) continue;
            const cls = m.class;
            const name = cls.name orelse continue;

            if (std.mem.eql(u8, name, "CfgSchemas")) {
                const cfg_members = cls.members orelse continue;
                for (cfg_members.items) |*cm| {
                    if (cm.* != .class) continue;
                    const inner_name = cm.class.name orelse continue;
                    const duped = try alloc.dupe(u8, inner_name);
                    try list.append(alloc, duped);
                }
            }
        }

        var i: usize = 0;
        while (i < list.items.len) {
            var j: usize = i + 1;
            while (j < list.items.len) {
                if (std.mem.eql(u8, list.items[i], list.items[j])) {
                    const removed = list.orderedRemove(j);
                    alloc.free(removed);
                } else {
                    j += 1;
                }
            }
            i += 1;
        }

        const items = try list.toOwnedSlice(alloc);

        const SortCtx = struct {
            root: *const paramlib.cpp.ast.ClassAst,
            alloc: std.mem.Allocator,
            pub fn lessThan(ctx: @This(), a: []const u8, b: []const u8) bool {
                const sc_a = findSchemaClass(ctx.root, ctx.alloc, a);
                const sc_b = findSchemaClass(ctx.root, ctx.alloc, b);
                const a_is_def = if (sc_a) |s| s.class_ptr.members != null else false;
                const b_is_def = if (sc_b) |s| s.class_ptr.members != null else false;
                if (a_is_def != b_is_def) return !a_is_def; // non-definitions first
                return std.mem.lessThan(u8, a, b);
            }
        };
        std.mem.sort([]const u8, items, SortCtx{ .root = root, .alloc = alloc }, SortCtx.lessThan);

        return items;
    }

    fn getCfgSchemasMembers(root: *const paramlib.cpp.ast.ClassAst) ?*std.ArrayList(paramlib.cpp.ast.MemberAst) {
        const top = root.members orelse return null;
        for (top.items) |*m| {
            if (m.* != .class) continue;
            const cfg = m.class;
            if (cfg.name == null or !std.mem.eql(u8, cfg.name.?, "CfgSchemas")) continue;
            if (cfg.members) |*members| return members;
        }
        return null;
    }

    fn cloneSchemaState(src: SchemaState, alloc: std.mem.Allocator) !SchemaState {
        var dst: SchemaState = .{
            .stringCompletions = try alloc.alloc(StringCompletionRule, src.stringCompletions.len),
            .arrayInlays       = try alloc.alloc(ArrayInlaysRule, src.arrayInlays.len),
            .parserRules       = try alloc.alloc(ParserRule, src.parserRules.len),
            .paramDocs         = try alloc.alloc(ParamDocRule, src.paramDocs.len),
            .schemaClasses     = &.{},
            .projectName       = try alloc.dupe(u8, src.projectName),
            .selectedClass     = try alloc.dupe(u8, src.selectedClass),
            .base_class        = try alloc.dupe(u8, src.base_class),
            .pushedSchemas     = .empty,
        };
        errdefer dst.deinit(alloc);

        for (src.stringCompletions, 0..) |s, i| {
            const values = try alloc.alloc([]const u8, s.values.len);
            errdefer {
                for (values[0..0]) |v| alloc.free(v);
                alloc.free(values);
            }
            for (s.values, 0..) |v, j| {
                values[j] = try alloc.dupe(u8, v);
            }
            dst.stringCompletions[i] = .{
                .path   = try alloc.dupe(u8, s.path),
                .values = values,
                .source = try alloc.dupe(u8, s.source),
            };
        }

        for (src.arrayInlays, 0..) |a, i| {
            const labels = try alloc.alloc([]const u8, a.labels.len);
            errdefer {
                for (labels[0..0]) |l| alloc.free(l);
                alloc.free(labels);
            }
            for (a.labels, 0..) |l, j| {
                labels[j] = try alloc.dupe(u8, l);
            }
            dst.arrayInlays[i] = .{
                .path   = try alloc.dupe(u8, a.path),
                .labels = labels,
                .source = try alloc.dupe(u8, a.source),
            };
        }

        for (src.parserRules, 0..) |p, i| {
            dst.parserRules[i] = .{
                .pattern     = try alloc.dupe(u8, p.pattern),
                .wasm_source = try alloc.dupe(u8, p.wasm_source),
                .source      = try alloc.dupe(u8, p.source),
            };
        }

        for (src.paramDocs, 0..) |p, i| {
            dst.paramDocs[i] = .{
                .path   = try alloc.dupe(u8, p.path),
                .doc    = try alloc.dupe(u8, p.doc),
                .source = try alloc.dupe(u8, p.source),
            };
        }

        var sc_list = std.ArrayList([]const u8).empty;
        errdefer {
            for (sc_list.items) |name| alloc.free(name);
            sc_list.deinit(alloc);
        }
        for (src.schemaClasses) |name| {
            try sc_list.append(alloc, try alloc.dupe(u8, name));
        }
        dst.schemaClasses = try sc_list.toOwnedSlice(alloc);

        var pushed_it = src.pushedSchemas.iterator();
        while (pushed_it.next()) |entry| {
            const key = try alloc.dupe(u8, entry.key_ptr.*);
            errdefer alloc.free(key);
            const state = try cloneSchemaState(entry.value_ptr.*, alloc);
            errdefer { var s = state; s.deinit(alloc); }
            try dst.pushedSchemas.put(alloc, key, state);
        }

        return dst;
    }

    fn buildFromSchemaClass(
        manager:     *const SchemaManager,
        root:        *const paramlib.cpp.ast.ClassAst,
        schema:      *const paramlib.cpp.ast.ClassAst,
        alloc:       std.mem.Allocator,
        named:       *const std.StringArrayHashMapUnmanaged(SchemaState),
        name_for_log: []const u8,
    ) !SchemaState {
        var base_state: SchemaState = if (schema.base) |base| blk: {
            var bs = if (findSchemaClass(root, alloc, base.name)) |sc| b2: {
                if (sc.class_ptr.members != null) {
                    break :b2 try buildFromSchemaClass(manager, root, sc.class_ptr, alloc, named, base.name orelse "");
                }
                break :b2 SchemaState.empty;
            } else SchemaState.empty;

            if (bs.projectName.len == 0) {
                if (named.get(base.name orelse "")) |existing| {
                    bs = try cloneSchemaState(existing, alloc);
                } else if (manager.findGlobalSchemaState(base.name orelse "")) |existing| {
                    bs = try cloneSchemaState(existing.*, alloc);
                }
            }

            if (bs.base_class.len > 0) alloc.free(bs.base_class);
            bs.base_class = if (base.name) |n| try alloc.dupe(u8, n) else "";
            break :blk bs;
        } else .empty;

        if (base_state.projectName.len > 0) alloc.free(base_state.projectName);
        base_state.projectName = alloc.dupe(u8, name_for_log) catch "";

        var stringCompletions = std.ArrayList(StringCompletionRule).empty;
        var arrayInlays       = std.ArrayList(ArrayInlaysRule).empty;
        var parserRules       = std.ArrayList(ParserRule).empty;
        var paramDocs         = std.ArrayList(ParamDocRule).empty;

        stringCompletions.appendSlice(alloc, base_state.stringCompletions) catch {};
        arrayInlays.appendSlice(alloc, base_state.arrayInlays) catch {};
        parserRules.appendSlice(alloc, base_state.parserRules) catch {};
        paramDocs.appendSlice(alloc, base_state.paramDocs) catch {};

        alloc.free(base_state.stringCompletions);
        alloc.free(base_state.arrayInlays);
        alloc.free(base_state.parserRules);
        alloc.free(base_state.paramDocs);
        base_state.stringCompletions = &.{};
        base_state.arrayInlays = &.{};
        base_state.parserRules = &.{};
        base_state.paramDocs = &.{};

        const members = schema.members orelse {
            base_state.stringCompletions = stringCompletions.toOwnedSlice(alloc) catch &.{};
            base_state.arrayInlays       = arrayInlays.toOwnedSlice(alloc) catch &.{};
            base_state.parserRules       = parserRules.toOwnedSlice(alloc) catch &.{};
            base_state.paramDocs         = paramDocs.toOwnedSlice(alloc) catch &.{};
            return base_state;
        };

        for (members.items) |*m| {
            switch (m.*) {
                .param => |*p| {
                    if (std.mem.eql(u8, p.name, "paramDocs")) {
                        if (p.operator == .assign) {
                            for (paramDocs.items) |rule| {
                                alloc.free(rule.path);
                                alloc.free(rule.doc);
                                alloc.free(rule.source);
                            }
                            paramDocs.clearRetainingCapacity();
                        }
                        const outer_arr = switch (p.value) { .array => |a| a, else => continue };
                        for (outer_arr) |*v| {
                            const inner = switch (v.*) { .array => |a| a, else => continue };
                            if (inner.len < 2) continue;
                            const path = switch (inner[0]) { .string => |s| s, else => continue };
                            const doc  = switch (inner[1]) { .string => |s| s, else => continue };

                            if (p.operator == .subAssign) {
                                var i: usize = 0;
                                while (i < paramDocs.items.len) {
                                    if (std.mem.eql(u8, paramDocs.items[i].path, path)) {
                                        const entry = paramDocs.orderedRemove(i);
                                        alloc.free(entry.path);
                                        alloc.free(entry.doc);
                                        alloc.free(entry.source);
                                    } else i += 1;
                                }
                            } else {
                                paramDocs.append(alloc, .{
                                    .path   = alloc.dupe(u8, path) catch "",
                                    .doc    = alloc.dupe(u8, doc) catch "",
                                    .source = alloc.dupe(u8, name_for_log) catch "",
                                }) catch {};
                            }
                        }
                        continue;
                    }

                    if (std.mem.eql(u8, p.name, "stringCompletions")) {
                        if (p.operator == .assign) {
                            for (stringCompletions.items) |rule| {
                                alloc.free(rule.path);
                                for (rule.values) |v| alloc.free(v);
                                alloc.free(rule.values);
                                alloc.free(rule.source);
                            }
                            stringCompletions.clearRetainingCapacity();
                        }
                        const outer_arr = switch (p.value) { .array => |a| a, else => continue };
                        for (outer_arr) |*v| {
                            const inner = switch (v.*) { .array => |a| a, else => continue };
                            if (inner.len < 2) continue;
                            const path = switch (inner[0]) { .string => |s| s, else => continue };
                            const vals = switch (inner[1]) { .array  => |a| a, else => continue };

                            if (p.operator == .subAssign) {
                                var i: usize = 0;
                                while (i < stringCompletions.items.len) {
                                    if (std.mem.eql(u8, stringCompletions.items[i].path, path)) {
                                        const entry = stringCompletions.orderedRemove(i);
                                        alloc.free(entry.path);
                                        for (entry.values) |val| alloc.free(val);
                                        alloc.free(entry.values);
                                        alloc.free(entry.source);
                                    } else i += 1;
                                }
                            } else {
                                var values = std.ArrayList([]const u8).empty;
                                for (vals) |*val| {
                                    switch (val.*) { .string => |s| values.append(alloc, alloc.dupe(u8, s) catch "") catch {}, else => {} }
                                }
                                stringCompletions.append(alloc, .{
                                    .path   = alloc.dupe(u8, path) catch "",
                                    .values = values.toOwnedSlice(alloc) catch &.{},
                                    .source = alloc.dupe(u8, name_for_log) catch "",
                                }) catch {};
                            }
                        }
                        continue;
                    }

                    if (std.mem.eql(u8, p.name, "arrayInlays")) {
                        if (p.operator == .assign) {
                            for (arrayInlays.items) |rule| {
                                alloc.free(rule.path);
                                for (rule.labels) |l| alloc.free(l);
                                alloc.free(rule.labels);
                                alloc.free(rule.source);
                            }
                            arrayInlays.clearRetainingCapacity();
                        }
                        const outer_arr = switch (p.value) { .array => |a| a, else => continue };
                        for (outer_arr) |*v| {
                            const inner = switch (v.*) { .array => |a| a, else => continue };
                            if (inner.len < 2) continue;
                            const path = switch (inner[0]) { .string => |s| s, else => continue };
                            const labs = switch (inner[1]) { .array  => |a| a, else => continue };

                            if (p.operator == .subAssign) {
                                var i: usize = 0;
                                while (i < arrayInlays.items.len) {
                                    if (std.mem.eql(u8, arrayInlays.items[i].path, path)) {
                                        const entry = arrayInlays.orderedRemove(i);
                                        alloc.free(entry.path);
                                        for (entry.labels) |l| alloc.free(l);
                                        alloc.free(entry.labels);
                                        alloc.free(entry.source);
                                    } else i += 1;
                                }
                            } else {
                                var labels = std.ArrayList([]const u8).empty;
                                for (labs) |*lab| {
                                    switch (lab.*) { .string => |s| labels.append(alloc, alloc.dupe(u8, s) catch "") catch {}, else => {} }
                                }
                                arrayInlays.append(alloc, .{
                                    .path   = alloc.dupe(u8, path) catch "",
                                    .labels = labels.toOwnedSlice(alloc) catch &.{},
                                    .source = alloc.dupe(u8, name_for_log) catch "",
                                }) catch {};
                            }
                        }
                        continue;
                    }

                    if (std.mem.eql(u8, p.name, "modules")) {
                        if (p.operator == .assign) {
                            for (parserRules.items) |rule| {
                                alloc.free(rule.pattern);
                                alloc.free(rule.wasm_source);
                                alloc.free(rule.source);
                            }
                            parserRules.clearRetainingCapacity();
                        }
                        const outer_arr = switch (p.value) { .array => |a| a, else => continue };
                        for (outer_arr) |*v| {
                            const inner = switch (v.*) { .array => |a| a, else => continue };
                            if (inner.len < 2) continue;
                            const pattern = switch (inner[0]) { .string => |s| s, else => continue };
                            const wasm    = switch (inner[1]) { .string => |s| s, else => continue };

                            if (p.operator == .subAssign) {
                                var i: usize = 0;
                                while (i < parserRules.items.len) {
                                    if (std.mem.eql(u8, parserRules.items[i].pattern, pattern)) {
                                        const entry = parserRules.orderedRemove(i);
                                        alloc.free(entry.pattern);
                                        alloc.free(entry.wasm_source);
                                        alloc.free(entry.source);
                                    } else i += 1;
                                }
                            } else {
                                parserRules.append(alloc, .{
                                    .pattern     = alloc.dupe(u8, pattern) catch "",
                                    .wasm_source = alloc.dupe(u8, wasm) catch "",
                                    .source      = alloc.dupe(u8, name_for_log) catch "",
                                }) catch {};
                            }
                        }
                        continue;
                    }

                    if (std.mem.startsWith(u8, p.name, "doc_")) {
                        const path = p.name[4..];
                        if (p.operator == .subAssign) {
                            var i: usize = 0;
                            while (i < paramDocs.items.len) {
                                if (std.mem.eql(u8, paramDocs.items[i].path, path)) {
                                    const entry = paramDocs.orderedRemove(i);
                                    alloc.free(entry.path);
                                    alloc.free(entry.doc);
                                    alloc.free(entry.source);
                                } else i += 1;
                            }
                        } else {
                            if (p.operator == .assign) {
                                var i: usize = 0;
                                while (i < paramDocs.items.len) {
                                    if (std.mem.eql(u8, paramDocs.items[i].path, path)) {
                                        const entry = paramDocs.orderedRemove(i);
                                        alloc.free(entry.path);
                                        alloc.free(entry.doc);
                                        alloc.free(entry.source);
                                    } else i += 1;
                                }
                            }
                            const doc  = switch (p.value) {
                                .string => |s| s,
                                else    => continue,
                            };
                            paramDocs.append(alloc, .{
                                .path   = alloc.dupe(u8, path) catch "",
                                .doc    = alloc.dupe(u8, doc) catch "",
                                .source = alloc.dupe(u8, name_for_log) catch "",
                            }) catch {};
                        }
                        continue;
                    }

                    if (std.mem.startsWith(u8, p.name, "parser_")) {
                        const pattern = p.name[7..];
                        if (p.operator == .subAssign) {
                            var i: usize = 0;
                            while (i < parserRules.items.len) {
                                if (std.mem.eql(u8, parserRules.items[i].pattern, pattern)) {
                                    const entry = parserRules.orderedRemove(i);
                                    alloc.free(entry.pattern);
                                    alloc.free(entry.wasm_source);
                                    alloc.free(entry.source);
                                } else i += 1;
                            }
                        } else {
                            if (p.operator == .assign) {
                                var i: usize = 0;
                                while (i < parserRules.items.len) {
                                    if (std.mem.eql(u8, parserRules.items[i].pattern, pattern)) {
                                        const entry = parserRules.orderedRemove(i);
                                        alloc.free(entry.pattern);
                                        alloc.free(entry.wasm_source);
                                        alloc.free(entry.source);
                                    } else i += 1;
                                }
                            }
                            const wasm    = switch (p.value) {
                                .string => |s| s,
                                else    => continue,
                            };
                            parserRules.append(alloc, .{
                                .pattern     = alloc.dupe(u8, pattern) catch "",
                                .wasm_source = alloc.dupe(u8, wasm) catch "",
                                .source      = alloc.dupe(u8, name_for_log) catch "",
                            }) catch {};
                        }
                        continue;
                    }

                    const arr = switch (p.value) {
                        .array => |a| a,
                        else   => continue,
                    };
                    var values = std.ArrayList([]const u8).empty;
                    for (arr) |*v| {
                        switch (v.*) {
                            .string => |s| values.append(alloc, alloc.dupe(u8, s) catch "") catch {},
                            else    => {},
                        }
                    }

                    if (std.mem.startsWith(u8, p.name, "inlay_")) {
                        const path = p.name[6..];
                        if (p.operator == .subAssign) {
                            var i: usize = 0;
                            while (i < arrayInlays.items.len) {
                                if (std.mem.eql(u8, arrayInlays.items[i].path, path)) {
                                    const entry = arrayInlays.orderedRemove(i);
                                    alloc.free(entry.path);
                                    for (entry.labels) |l| alloc.free(l);
                                    alloc.free(entry.labels);
                                    alloc.free(entry.source);
                                } else i += 1;
                            }
                            for (values.items) |v| alloc.free(v);
                            values.deinit(alloc);
                        } else {
                            if (p.operator == .assign) {
                                var i: usize = 0;
                                while (i < arrayInlays.items.len) {
                                    if (std.mem.eql(u8, arrayInlays.items[i].path, path)) {
                                        const entry = arrayInlays.orderedRemove(i);
                                        alloc.free(entry.path);
                                        for (entry.labels) |l| alloc.free(l);
                                        alloc.free(entry.labels);
                                        alloc.free(entry.source);
                                    } else i += 1;
                                }
                            }
                            arrayInlays.append(alloc, .{
                                .path   = alloc.dupe(u8, path) catch "",
                                .labels = values.toOwnedSlice(alloc) catch &.{},
                                .source = alloc.dupe(u8, name_for_log) catch "",
                            }) catch {};
                        }
                    } else {
                        if (p.operator == .subAssign) {
                            var i: usize = 0;
                            while (i < stringCompletions.items.len) {
                                if (std.mem.eql(u8, stringCompletions.items[i].path, p.name)) {
                                    const entry = stringCompletions.orderedRemove(i);
                                    alloc.free(entry.path);
                                    for (entry.values) |v| alloc.free(v);
                                    alloc.free(entry.values);
                                    alloc.free(entry.source);
                                } else i += 1;
                            }
                            for (values.items) |v| alloc.free(v);
                            values.deinit(alloc);
                        } else {
                            if (p.operator == .assign) {
                                var i: usize = 0;
                                while (i < stringCompletions.items.len) {
                                    if (std.mem.eql(u8, stringCompletions.items[i].path, p.name)) {
                                        const entry = stringCompletions.orderedRemove(i);
                                        alloc.free(entry.path);
                                        for (entry.values) |v| alloc.free(v);
                                        alloc.free(entry.values);
                                        alloc.free(entry.source);
                                    } else i += 1;
                                }
                            }
                            stringCompletions.append(alloc, .{
                                .path   = alloc.dupe(u8, p.name) catch "",
                                .values = values.toOwnedSlice(alloc) catch &.{},
                                .source = alloc.dupe(u8, name_for_log) catch "",
                            }) catch {};
                        }
                    }
                },
                .delete => |*d| {
                    const name = d.* orelse continue;
                    if (std.mem.startsWith(u8, name, "doc_")) {
                        const path = name[4..];
                        var i: usize = 0;
                        while (i < paramDocs.items.len) {
                            if (std.mem.eql(u8, paramDocs.items[i].path, path)) {
                                const entry = paramDocs.orderedRemove(i);
                                alloc.free(entry.path);
                                alloc.free(entry.doc);
                                alloc.free(entry.source);
                            } else i += 1;
                        }
                    } else if (std.mem.startsWith(u8, name, "parser_")) {
                        const pattern = name[7..];
                        var i: usize = 0;
                        while (i < parserRules.items.len) {
                            if (std.mem.eql(u8, parserRules.items[i].pattern, pattern)) {
                                const entry = parserRules.orderedRemove(i);
                                alloc.free(entry.pattern);
                                alloc.free(entry.wasm_source);
                                alloc.free(entry.source);
                            } else i += 1;
                        }
                    } else if (std.mem.startsWith(u8, name, "inlay_")) {
                        const path = name[6..];
                        var i: usize = 0;
                        while (i < arrayInlays.items.len) {
                            if (std.mem.eql(u8, arrayInlays.items[i].path, path)) {
                                const entry = arrayInlays.orderedRemove(i);
                                alloc.free(entry.path);
                                for (entry.labels) |l| alloc.free(l);
                                alloc.free(entry.labels);
                                alloc.free(entry.source);
                            } else i += 1;
                        }
                    } else if (std.mem.eql(u8, name, "paramDocs")) {
                        for (paramDocs.items) |entry| {
                            alloc.free(entry.path);
                            alloc.free(entry.doc);
                            alloc.free(entry.source);
                        }
                        paramDocs.clearRetainingCapacity();
                    } else if (std.mem.eql(u8, name, "stringCompletions")) {
                        for (stringCompletions.items) |entry| {
                            alloc.free(entry.path);
                            for (entry.values) |v| alloc.free(v);
                            alloc.free(entry.values);
                            alloc.free(entry.source);
                        }
                        stringCompletions.clearRetainingCapacity();
                    } else if (std.mem.eql(u8, name, "arrayInlays")) {
                        for (arrayInlays.items) |entry| {
                            alloc.free(entry.path);
                            for (entry.labels) |l| alloc.free(l);
                            alloc.free(entry.labels);
                            alloc.free(entry.source);
                        }
                        arrayInlays.clearRetainingCapacity();
                    } else if (std.mem.eql(u8, name, "modules")) {
                        for (parserRules.items) |entry| {
                            alloc.free(entry.pattern);
                            alloc.free(entry.wasm_source);
                            alloc.free(entry.source);
                        }
                        parserRules.clearRetainingCapacity();
                    } else {
                        var i: usize = 0;
                        while (i < stringCompletions.items.len) {
                            if (std.mem.eql(u8, stringCompletions.items[i].path, name)) {
                                const entry = stringCompletions.orderedRemove(i);
                                alloc.free(entry.path);
                                for (entry.values) |v| alloc.free(v);
                                alloc.free(entry.values);
                                alloc.free(entry.source);
                            } else i += 1;
                        }
                    }
                },
                else => {},
            }
        }

        base_state.stringCompletions = stringCompletions.toOwnedSlice(alloc) catch &.{};
        base_state.arrayInlays       = arrayInlays.toOwnedSlice(alloc) catch &.{};
        base_state.parserRules       = parserRules.toOwnedSlice(alloc) catch &.{};
        base_state.paramDocs         = paramDocs.toOwnedSlice(alloc) catch &.{};

        return base_state;
    }

    pub fn deinit(self: *SchemaState, alloc: std.mem.Allocator) void {
        for (self.stringCompletions) |rule| {
            alloc.free(rule.path);
            for (rule.values) |v| alloc.free(v);
            alloc.free(rule.values);
            if (rule.source.len > 0) alloc.free(rule.source);
        }
        if (self.stringCompletions.len > 0) alloc.free(self.stringCompletions);
        self.stringCompletions = &.{};

        for (self.arrayInlays) |rule| {
            alloc.free(rule.path);
            for (rule.labels) |l| alloc.free(l);
            alloc.free(rule.labels);
            if (rule.source.len > 0) alloc.free(rule.source);
        }
        if (self.arrayInlays.len > 0) alloc.free(self.arrayInlays);
        self.arrayInlays = &.{};

        for (self.parserRules) |rule| {
            alloc.free(rule.pattern);
            alloc.free(rule.wasm_source);
            if (rule.source.len > 0) alloc.free(rule.source);
        }
        if (self.parserRules.len > 0) alloc.free(self.parserRules);
        self.parserRules = &.{};

        for (self.paramDocs) |rule| {
            alloc.free(rule.path);
            alloc.free(rule.doc);
            if (rule.source.len > 0) alloc.free(rule.source);
        }
        if (self.paramDocs.len > 0) alloc.free(self.paramDocs);
        self.paramDocs = &.{};

        for (self.schemaClasses) |name| alloc.free(name);
        if (self.schemaClasses.len > 0) alloc.free(self.schemaClasses);
        self.schemaClasses = &.{};

        if (self.projectName.len > 0) alloc.free(self.projectName);
        self.projectName = "";
        if (self.selectedClass.len > 0) alloc.free(self.selectedClass);
        self.selectedClass = "";
        if (self.base_class.len > 0) alloc.free(self.base_class);
        self.base_class = "";

        var pushed_it = self.pushedSchemas.iterator();
        while (pushed_it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            entry.value_ptr.deinit(alloc);
        }
        self.pushedSchemas.deinit(alloc);
        self.pushedSchemas = .empty;
    }

    pub fn collectInheritanceChain(self: *const SchemaState, manager: ?*const SchemaManager, alloc: std.mem.Allocator) ![]const []const u8 {
        var list = std.ArrayList([]const u8).empty;
        errdefer {
            for (list.items) |n| alloc.free(n);
            list.deinit(alloc);
        }

        var current_name = self.selectedClass;
        while (current_name.len > 0) {
            try list.insert(alloc, 0, try alloc.dupe(u8, current_name));
            
            if (self.pushedSchemas.get(current_name)) |state| {
                current_name = state.base_class;
            } else if (manager) |m| {
                if (m.findGlobalSchemaState(current_name)) |state| {
                    current_name = state.base_class;
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        return list.toOwnedSlice(alloc);
    }

    pub fn valuesFor(self: *const SchemaState, param_path: []const u8) ?[]const []const u8 {
        var i: usize = self.stringCompletions.len;
        while (i > 0) {
            i -= 1;
            const rule = self.stringCompletions[i];
            if (globMatch(rule.path, param_path)) return rule.values;
        }
        return null;
    }

    pub fn labelsFor(self: *const SchemaState, param_path: []const u8) ?[]const []const u8 {
        var i: usize = self.arrayInlays.len;
        while (i > 0) {
            i -= 1;
            const rule = self.arrayInlays[i];
            const pat = stripArraySuffix(rule.path);
            if (globMatch(pat, param_path)) return rule.labels;
        }
        return null;
    }

    pub fn docFor(self: *const SchemaState, param_path: []const u8) ?[]const u8 {
        if (self.docRuleFor(param_path)) |rule| return rule.doc;
        return null;
    }

    pub fn docRuleFor(self: *const SchemaState, param_path: []const u8) ?ParamDocRule {
        log("[docFor] searching for '{s}', have {d} paramDocs rules", .{ param_path, self.paramDocs.len });
        var i: usize = self.paramDocs.len;
        while (i > 0) {
            i -= 1;
            const rule = self.paramDocs[i];
            log("[docFor]   rule.path='{s}' vs param_path='{s}' -> match={}", .{ rule.path, param_path, globMatch(rule.path, param_path) });
            if (globMatch(rule.path, param_path)) {
                log("[docFor]   MATCHED! returning doc='{s}' source='{s}'", .{rule.doc, rule.source});
                return rule;
            }
        }
        return null;
    }

    test "rule inheritance and operators" {
        const alloc = std.testing.allocator;

        const schema_src =
            \\class CfgSchemas {
            \\    class Base {
            \\        stringCompletions[] = {
            \\            {"Base/Path", {"V1", "V2"}}
            \\        };
            \\        doc_Base = "Base doc";
            \\    };
            \\    class Derived : Base {
            \\        stringCompletions[] += {
            \\            {"Derived/Path", {"V3"}}
            \\        };
            \\        doc_Base = "Derived doc override";
            \\        doc_Derived = "Derived doc";
            \\    };
            \\    class DerivedReplace : Base {
            \\        stringCompletions[] = {
            \\            {"New/Path", {"V4"}}
            \\        };
            \\    };
            \\    class DerivedSub : Base {
            \\        stringCompletions[] -= {
            \\            {"Base/Path", {}}
            \\        };
            \\        delete doc_Base;
            \\    };
            \\};
        ;

        var manager = SchemaManager.empty;
        defer manager.deinit(alloc);

        try manager.updateSchema(alloc, "file:///path/to/schema.cpp", schema_src, "Derived");
        const state = manager.getSchemaForUri("file:///path/to/data.rvmat");

        try std.testing.expect(state.valuesFor("Base/Path") != null);
        try std.testing.expectEqual(@as(usize, 2), state.valuesFor("Base/Path").?.len);
        try std.testing.expect(state.valuesFor("Derived/Path") != null);
        try std.testing.expectEqual(@as(usize, 1), state.valuesFor("Derived/Path").?.len);

        try std.testing.expectEqualStrings("Derived doc override", state.docFor("Base").?);
        try std.testing.expectEqualStrings("Derived doc", state.docFor("Derived").?);

        try manager.updateSchema(alloc, "file:///path/to/schema.cpp", schema_src, "DerivedReplace");
        const state2 = manager.getSchemaForUri("file:///path/to/data.rvmat");
        try std.testing.expect(state2.valuesFor("Base/Path") == null);
        try std.testing.expect(state2.valuesFor("New/Path") != null);

        try manager.updateSchema(alloc, "file:///path/to/schema.cpp", schema_src, "DerivedSub");
        const state3 = manager.getSchemaForUri("file:///path/to/data.rvmat");
        try std.testing.expect(state3.valuesFor("Base/Path") == null);
        try std.testing.expect(state3.docFor("Base") == null);
    }

    test "collectInheritanceChain works" {
        const alloc = std.testing.allocator;
        const schema_src =
            \\class CfgSchemas {
            \\    class DayZ { rules = 1; };
            \\    class MyProject : DayZ { rules = 2; };
            \\};
        ;
        var manager = SchemaManager.empty;
        defer manager.deinit(alloc);

        try manager.updateSchema(alloc, "file:///root/paramlib.cpp", schema_src, "MyProject");
        const state = manager.getSchemaForUri("file:///root/data.rvmat");

        const chain = try state.collectInheritanceChain(&manager, alloc);
        defer {
            for (chain) |n| alloc.free(n);
            alloc.free(chain);
        }

        try std.testing.expectEqual(@as(usize, 2), chain.len);
        try std.testing.expectEqualStrings("DayZ", chain[0]);
        try std.testing.expectEqualStrings("MyProject", chain[1]);
    }

    test "inheritance chain across files" {
        const alloc = std.testing.allocator;
        const root_src =
            \\class CfgSchemas {
            \\    class DayZ { rules = 1; };
            \\    class MyProject : DayZ { rules = 2; };
            \\};
        ;
        const leaf_src =
            \\class CfgSchemas {
            \\    class MyProject;
            \\    class NextProject : MyProject { rules = 3; };
            \\};
        ;

        var manager = SchemaManager.empty;
        defer manager.deinit(alloc);

        try manager.updateSchema(alloc, "file:///root/paramlib.cpp", root_src, "MyProject");
        try manager.updateSchema(alloc, "file:///root/next/paramlib.cpp", leaf_src, "NextProject");

        const state = manager.getSchemaForUri("file:///root/next/data.rvmat");
        try std.testing.expectEqualStrings("NextProject", state.selectedClass);

        const chain = try state.collectInheritanceChain(&manager, alloc);
        defer {
            for (chain) |n| alloc.free(n);
            alloc.free(chain);
        }

        try std.testing.expectEqual(@as(usize, 3), chain.len);
        try std.testing.expectEqualStrings("DayZ", chain[0]);
        try std.testing.expectEqualStrings("MyProject", chain[1]);
        try std.testing.expectEqualStrings("NextProject", chain[2]);
    }
};
fn globMatch(pattern: []const u8, str: []const u8) bool {
    return globMatchAt(pattern, 0, str, 0);
}

fn globMatchAt(pat: []const u8, pi_start: usize, str: []const u8, si_start: usize) bool {
    var pi = pi_start;
    var si = si_start;
    while (true) {
        while (pi < pat.len and si < str.len) {
            const double_star = pi + 1 < pat.len and pat[pi] == '*' and pat[pi + 1] == '*';
            if (pat[pi] == '*' and !double_star) break;
            if (double_star) break;
            if (pat[pi] == '?' or pat[pi] == str[si]) {
                pi += 1;
                si += 1;
            } else return false;
        }

        if (pi == pat.len and si == str.len) return true;

        if (si == str.len) {
            var ri = pi;
            while (ri < pat.len) : (ri += 1) {
                if (pat[ri] != '*') return false;
            }
            return true;
        }

        if (pi == pat.len) return false;

        if (pi + 1 < pat.len and pat[pi] == '*' and pat[pi + 1] == '*') {
            const after = pi + 2;
            var rest = after;
            if (rest < pat.len and pat[rest] == '.') rest += 1;
            var ti = si;
            while (true) {
                if (globMatchAt(pat, rest, str, ti)) return true;
                if (ti == str.len) break;
                ti += 1;
            }
            return false;
        }

        if (pat[pi] == '*') {
            const after = pi + 1;
            var ti = si + 1;
            while (true) {
                if (globMatchAt(pat, after, str, ti)) return true;
                if (ti == str.len or str[ti] == '.') break;
                ti += 1;
            }
            return false;
        }

        return false;
    }
}

fn stripArraySuffix(path: []const u8) []const u8 {
    if (path.len > 0 and path[path.len - 1] == ']') {
        if (std.mem.lastIndexOfScalar(u8, path, '[')) |i| {
            return path[0..i];
        }
    }
    return path;
}

const RequestMethods = union(enum) {
    initialize:                           lsp.types.InitializeParams,
    shutdown,
    @"textDocument/hover":                lsp.types.Hover.Params,
    @"textDocument/documentSymbol":       lsp.types.DocumentSymbol.Params,
    @"textDocument/definition":           lsp.types.Definition.Params,
    @"textDocument/references":           lsp.types.reference.Params,
    @"textDocument/semanticTokens/full":  lsp.types.semantic_tokens.Params,
    @"textDocument/completion":           lsp.types.completion.Params,
    @"textDocument/inlayHint":            lsp.types.InlayHint.Params,
    other:                                lsp.MethodWithParams,
};

const NotificationMethods = union(enum) {
    initialized:                       lsp.types.InitializedParams,
    exit,
    @"textDocument/didOpen":           lsp.types.TextDocument.DidOpenParams,
    @"textDocument/didChange":         lsp.types.TextDocument.DidChangeParams,
    @"textDocument/didSave":           lsp.types.TextDocument.DidSaveParams,
    @"textDocument/didClose":          lsp.types.TextDocument.DidCloseParams,
    other:                             lsp.MethodWithParams,
};

pub const Message = lsp.Message(RequestMethods, NotificationMethods, .{});

pub fn handleMessage(
    documents:      *std.StringArrayHashMapUnmanaged([]const u8),
    schema_manager: *SchemaManager,
    allocator:      std.mem.Allocator,
    io:             std.Io,
    message:        std.json.Parsed(Message),
    transport:      *lsp.Transport,
) !void {
    switch (message.value) {
        .request => |req| switch (req.params) {
            .initialize => {
                try transport.writeResponse(io, allocator, req.id,
                    lsp.types.InitializeResult,
                    .{
                        .serverInfo  = .{ .name = "paramlib-lsp" },
                        .capabilities = .{
                            .textDocumentSync = .{ .text_document_sync_options = .{
                                .openClose = true,
                                .change    = .Full,
                                .save      = .{ .bool = true },
                            }},
                            .hoverProvider          = .{ .bool = true },
                            .documentSymbolProvider = .{ .bool = true },
                            .definitionProvider     = .{ .bool = true },
                            .referencesProvider     = .{ .bool = true },
                            .completionProvider     = .{
                                .triggerCharacters  = &.{" ", "\t"},
                            },
                            .inlayHintProvider     = .{ .inlay_hint_options = .{ .resolveProvider = false } },
                            .colorProvider         = .{ .bool = true },
                            .semanticTokensProvider = .{ .semantic_tokens_options = .{
                                .legend = .{
                                    .tokenTypes     = &.{
                                        "keyword", "comment", "variable",
                                        "string", "operator", "number"
                                    },
                                    .tokenModifiers = &.{}
                                },
                                .full   = .{ .bool = true }
                            }}
                        },
                    },
                    .{ .emit_null_optional_fields = false },
                );
            },

            .shutdown => {
                try transport.writeResponse(io, allocator, req.id, void, {}, .{});
            },

            .@"textDocument/hover" => |params| {
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const schema = schema_manager.getSchemaForUri(params.textDocument.uri);
                const result = hover(documents, schema, arena.allocator(), params);
                try transport.writeResponse(io, allocator, req.id,
                    ?lsp.types.Hover, result,
                    .{ .emit_null_optional_fields = false },
                );
            },

            .@"textDocument/definition" => |params| {
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const result = definition(documents, arena.allocator(), params);

                try transport.writeResponse(io, allocator, req.id,
                    ?lsp.types.Definition.Result, result,
                    .{ .emit_null_optional_fields = false },
                );
            },

            .@"textDocument/references" => |params| {
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const result = references(documents, arena.allocator(), params);
                try transport.writeResponse(io, allocator, req.id,
                    ?[]const lsp.types.Location, result,
                    .{ .emit_null_optional_fields = false },
                );
            },

            .@"textDocument/documentSymbol" => |params| {
                const result = documentSymbols(documents, allocator, params);
                defer if (result) |syms| {
                    for (syms) |sym| allocator.free(sym.name);
                    allocator.free(syms);
                };
                try transport.writeResponse(io, allocator, req.id,
                    ?[]const lsp.types.SymbolInformation, result,
                    .{ .emit_null_optional_fields = false },
                );
            },

            .@"textDocument/semanticTokens/full" => |params| {
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const result = semanticTokensFull(io, documents, arena.allocator(), params);
                try transport.writeResponse(io, allocator, req.id,
                    ?lsp.types.semantic_tokens.Result, result,
                    .{ .emit_null_optional_fields = false },
                );
            },

            .@"textDocument/completion" => |params| {
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const schema = schema_manager.getSchemaForUri(params.textDocument.uri);
                const result = completion(documents, schema, arena.allocator(), params);
                try transport.writeResponse(io, allocator, req.id,
                    ?lsp.types.completion.Result, result,
                    .{ .emit_null_optional_fields = false },
                );
            },

            .@"textDocument/inlayHint" => |params| {
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const schema = schema_manager.getSchemaForUri(params.textDocument.uri);
                const result = inlayHints(documents, schema, &schema_manager.documentHints, arena.allocator(), params);
                try transport.writeResponse(io, allocator, req.id,
                    ?[]const lsp.types.InlayHint, result,
                    .{ .emit_null_optional_fields = false },
                );
            },

            .other => |method_params| {
                if (std.mem.eql(u8, method_params.method, "$/paramlib/listSchemaClasses")) {
                    const uri = if (method_params.params) |pars| blk: {
                        const Pars = struct { textDocument: lsp.types.TextDocument.Identifier };
                        const parsed = std.json.parseFromValue(Pars, allocator, pars, .{ .ignore_unknown_fields = true }) catch null;
                        if (parsed) |p| {
                            defer p.deinit();
                            break :blk try allocator.dupe(u8, p.value.textDocument.uri);
                        }
                        break :blk null;
                    } else null;
                    defer if (uri) |u| allocator.free(u);

                    const schema = if (uri) |u| schema_manager.getSchemaForUri(u) else &SchemaState.empty;
                    const names = if (schema != &SchemaState.empty and schema.selectedClass.len > 0)
                        try schema.collectInheritanceChain(schema_manager, allocator)
                    else
                        try schema_manager.collectAllSchemaClassNames(allocator);

                    defer {
                        for (names) |n| allocator.free(n);
                        allocator.free(names);
                    }
                    try transport.writeResponse(io, allocator, req.id,
                        []const []const u8, names,
                        .{ .emit_null_optional_fields = false },
                    );
                } else if (std.mem.eql(u8, method_params.method, "$/paramlib/listClassesInContent")) {
                    var list = std.ArrayList([]const u8).empty;
                    defer {
                        for (list.items) |n| allocator.free(n);
                        list.deinit(allocator);
                    }

                    if (method_params.params) |pars| {
                        const Pars = struct { content: []const u8 };
                        const parsed = std.json.parseFromValue(Pars, allocator, pars, .{ .ignore_unknown_fields = true }) catch null;
                        if (parsed) |p| {
                            defer p.deinit();
                            const src: ?[:0]const u8 = allocator.dupeZ(u8, p.value.content) catch null;
                            defer if (src) |s| allocator.free(s);

                            if (src) |s| {
                                var errored = false;
                                var root = paramlib.cpp.parser.parseSource(allocator, s, &errored, .none()) catch return;
                                defer root.deinit(allocator);

                                const names = SchemaState.collectSchemaClassNames(&root, allocator) catch &.{};
                                defer {
                                    for (names) |n| allocator.free(n);
                                    allocator.free(names);
                                }
                                for (names) |n| {
                                    try list.append(allocator, try allocator.dupe(u8, n));
                                }
                            }
                        }
                    }

                    try transport.writeResponse(io, allocator, req.id,
                        []const []const u8, list.items,
                        .{ .emit_null_optional_fields = false },
                    );
                } else if (std.mem.eql(u8, method_params.method, "$/paramlib/getDebugInfo")) {
                    if (method_params.params) |pars| {
                        const Pars = struct { uri: []const u8 };
                        const parsed = std.json.parseFromValue(Pars, allocator, pars, .{ .ignore_unknown_fields = true }) catch null;
                        if (parsed) |p| {
                            defer p.deinit();
                            const schema = schema_manager.getSchemaForUri(p.value.uri);
                            const chain = try schema.collectInheritanceChain(schema_manager, allocator);
                            defer {
                                for (chain) |n| allocator.free(n);
                                allocator.free(chain);
                            }
                            const result = .{
                                .uri = p.value.uri,
                                .rules = schema.parserRules,
                                .hintsCount = if (schema_manager.documentHints.get(p.value.uri)) |h| h.len else 0,
                                .selectedClass = schema.selectedClass,
                                .availableClasses = chain,
                                .instances = &.{},
                            };
                            try transport.writeResponse(io, allocator, req.id,
                                @TypeOf(result), result,
                                .{ .emit_null_optional_fields = false },
                            );
                        }
                    }
                } else if (std.mem.eql(u8, method_params.method, "$/paramlib/ping")) {
                    try transport.writeResponse(io, allocator, req.id, []const u8, "pong", .{});
                } else if (std.mem.eql(u8, method_params.method, "$/paramlib/getParserRules")) {
                    var list = std.ArrayListUnmanaged(ParserRule).empty;
                    defer list.deinit(allocator);
                    var it = schema_manager.schemas.iterator();
                    while (it.next()) |entry| {
                        try list.appendSlice(allocator, entry.value_ptr.parserRules);
                    }
                    try transport.writeResponse(io, allocator, req.id,
                        []const ParserRule, list.items,
                        .{ .emit_null_optional_fields = false },
                    );
                } else if (std.mem.eql(u8, method_params.method, "$/paramlib/getDocumentParams")) {
                    if(method_params.params) |pars| {
                        const params = std.json.parseFromValue(GetDocumentParams, allocator, pars, .{}) catch {
                            try transport.writeResponse(io, allocator, req.id, void, {}, .{});
                            return;
                        };
                        defer params.deinit();

                        const text = documents.get(params.value.textDocument.uri) orelse {
                            try transport.writeResponse(io, allocator, req.id, void, {}, .{});
                            return;
                        };
                        const src = allocator.dupeZ(u8, text) catch {
                            try transport.writeResponse(io, allocator, req.id, void, {}, .{});
                            return;
                        };
                        defer allocator.free(src);

                        const line_table = paramlib.cpp.lines.LineTable.build(allocator, src) catch {
                            try transport.writeResponse(io, allocator, req.id, void, {}, .{});
                            return;
                        };
                        defer line_table.deinit(allocator);

                        var errored = false;
                        var root = paramlib.cpp.parser.parseSource(allocator, src, &errored, .none()) catch {
                            try transport.writeResponse(io, allocator, req.id, void, {}, .{});
                            return;
                        };
                        defer root.deinit(allocator);

                        var list = std.ArrayList(DocumentParam).empty;
                        collectDocumentParams(&root, &root, &line_table, allocator, &list);

                        try transport.writeResponse(io, allocator, req.id,
                            GetDocumentParamsResult, .{ .params = list.items },
                            .{ .emit_null_optional_fields = false },
                        );
                    }
                } else if (std.mem.eql(u8, method_params.method, "$/paramlib/publishAllDiagnostics")) {
                    for (documents.keys()) |uri| {
                        try publishDiagnostics(transport, io, allocator, documents, uri);
                    }
                    try transport.writeResponse(io, allocator, req.id, void, {}, .{});
                } else if (std.mem.eql(u8, method_params.method, "$/paramlib/resetSchema")) {
                    var hint_it = schema_manager.documentHints.iterator();
                    while (hint_it.next()) |entry| {
                        allocator.free(entry.key_ptr.*);
                        for (entry.value_ptr.*) |h| allocator.free(h.text);
                        allocator.free(entry.value_ptr.*);
                    }
                    schema_manager.documentHints.deinit(allocator);
                    schema_manager.documentHints = .empty;

                    var it = schema_manager.schemas.iterator();
                    while (it.next()) |entry| {
                        allocator.free(entry.key_ptr.*);
                        entry.value_ptr.deinit(allocator);
                    }
                    schema_manager.schemas.deinit(allocator);
                    schema_manager.schemas = .empty;

                    for (documents.keys()) |uri| {
                        try publishDiagnostics(transport, io, allocator, documents, uri);
                    }
                    try transport.writeResponse(io, allocator, req.id, void, {}, .{});
                } else {
                    try transport.writeResponse(io, allocator, req.id, void, {}, .{});
                }
            },
        },

        .notification => |note| switch (note.params) {

            .initialized => {},
            .exit        => return,

            .@"textDocument/didOpen" => |params| {
                const uri  = try allocator.dupe(u8, params.textDocument.uri);
                const text = try allocator.dupe(u8, params.textDocument.text);
                try documents.put(allocator, uri, text);
                
                if (schema_manager.getSchemaKeyForUri(params.textDocument.uri)) |key| {
                    const schema = schema_manager.schemas.getPtr(key).?;
                    try schema.extractFromDocuments(schema_manager, allocator, documents, key);
                }
                try publishDiagnostics(transport, io, allocator, documents, params.textDocument.uri);
            },

            .@"textDocument/didChange" => |params| {
                if (params.contentChanges.len > 0) {
                    const change = params.contentChanges[params.contentChanges.len - 1];
                    const new_text = switch (change) {
                        .text_document_content_change_whole_document => |c| c.text,
                        .text_document_content_change_partial        => |c| c.text,
                    };
                    if (documents.getPtr(params.textDocument.uri)) |slot| {
                        allocator.free(slot.*);
                        slot.* = try allocator.dupe(u8, new_text);
                    }
                }
                if (schema_manager.getSchemaKeyForUri(params.textDocument.uri)) |key| {
                    const schema = schema_manager.schemas.getPtr(key).?;
                    try schema.extractFromDocuments(schema_manager, allocator, documents, key);
                }
                try publishDiagnostics(transport, io, allocator, documents, params.textDocument.uri);
            },

            .@"textDocument/didSave" => |params| {
                if (params.text) |text| {
                    if (documents.getPtr(params.textDocument.uri)) |slot| {
                        allocator.free(slot.*);
                        slot.* = try allocator.dupe(u8, text);
                    }
                }
                if (schema_manager.getSchemaKeyForUri(params.textDocument.uri)) |key| {
                    const schema = schema_manager.schemas.getPtr(key).?;
                    try schema.extractFromDocuments(schema_manager, allocator, documents, key);
                }
                try publishDiagnostics(transport, io, allocator, documents, params.textDocument.uri);
            },

            .@"textDocument/didClose" => |params| {
                if (documents.fetchOrderedRemove(params.textDocument.uri)) |kv| {
                    allocator.free(kv.key);
                    allocator.free(kv.value);
                }
            },

            .other => |method_params| {
                if (std.mem.eql(u8, method_params.method, "$/paramlib/parserHints")) {
                    if(method_params.params == null) return;
                    const parsed = std.json.parseFromValue(ParserHintsParams, allocator, method_params.params.?, .{ .ignore_unknown_fields = true }) catch return;
                    defer parsed.deinit();

                    if (schema_manager.documentHints.fetchOrderedRemove(parsed.value.uri)) |entry| {
                        allocator.free(entry.key);
                        for (entry.value) |h| allocator.free(h.text);
                        allocator.free(entry.value);
                    }

                    const uri = allocator.dupe(u8, parsed.value.uri) catch return;
                    const hints = allocator.alloc(PrecomputedParserHint, parsed.value.hints.len) catch {
                        allocator.free(uri);
                        return;
                    };
                    for (parsed.value.hints, 0..) |h, i| {
                        hints[i] = .{
                            .line = h.line,
                            .character = h.character,
                            .text = allocator.dupe(u8, h.text) catch "",
                        };
                    }
                    schema_manager.documentHints.put(allocator, uri, hints) catch {
                        allocator.free(uri);
                        for (hints) |hint| allocator.free(hint.text);
                        allocator.free(hints);
                    };
                } else if (std.mem.eql(u8, method_params.method, "$/paramlib/schemaUpdate")) {
                    if (method_params.params == null) return;
                    const UpdateParams = struct { uri: []const u8, content: []const u8, className: ?[]const u8 = null };
                    const parsed = std.json.parseFromValue(UpdateParams, allocator, method_params.params.?, .{ .ignore_unknown_fields = true }) catch return;
                    defer parsed.deinit();
                    schema_manager.updateSchema(allocator, parsed.value.uri, parsed.value.content, parsed.value.className) catch return;
                    
                    const dir = if (std.mem.lastIndexOfScalar(u8, parsed.value.uri, '/')) |idx|
                        parsed.value.uri[0 .. idx + 1]
                    else
                        parsed.value.uri;
                    
                    if (schema_manager.schemas.getPtr(dir)) |s| {
                        s.extractFromDocuments(schema_manager, allocator, documents, dir) catch {};
                    }
                }
            },
        },

        .response => {},
    }
}

const HoverNode = union(enum) {
    class: *const paramlib.cpp.ast.ClassAst,
    param: *const paramlib.cpp.ast.ParameterAst,
};

fn findNodeAtOffset(cls: *const paramlib.cpp.ast.ClassAst, offset: u32) ?HoverNode {
    const members = cls.members orelse return null;
    for (members.items) |*member| {
        switch (member.*) {
            .class => |c| {
                if (c.name) |name| {
                    const name_end = c.namePos + @as(u32, @intCast(name.len));
                    if (offset >= c.namePos and offset < name_end)
                        return HoverNode{ .class = c };
                }
                if (findNodeAtOffset(c, offset)) |found| return found;
            },
            .param => |*p| {
                const name_end = p.namePos + @as(u32, @intCast(p.name.len));
                if (offset >= p.namePos and offset < name_end)
                    return HoverNode{ .param = p };
            },
            .delete    => {},
            .enumerable => {},
        }
    }
    return null;
}

fn tokenLength(src: [:0]const u8, tok: paramlib.cpp.lexer.Token) u32 {
    return switch (tok.data) {
        .text   => |t| @intCast(t.len),
        .string => |s| @intCast(s.text.len + 2),
        else => blk: {
            var end = tok.pos;
            while (end < src.len) : (end += 1) {
                switch (src[end]) {
                    0, ' ', '\t', '\r', '\n', ';', '}', ',' => break,
                    else => {},
                }
            }
            const len = end - tok.pos;
            break :blk if (len > 0) @intCast(len) else 1;
        },
    };
}

fn semanticTokensFull(
    io:        std.Io,
    documents: *const std.StringArrayHashMapUnmanaged([]const u8),
    arena:     std.mem.Allocator,
    params:    lsp.types.semantic_tokens.Params,
) ?lsp.types.semantic_tokens.Result {
    _ = io;
    const text = documents.get(params.textDocument.uri) orelse return null;
    const src   = arena.dupeZ(u8, text) catch return null;

    const line_table = paramlib.cpp.lines.LineTable.build(arena, src) catch return null;

    var data = std.ArrayList(u32).empty;

    var tokenizer = paramlib.cpp.lexer.Tokenizer.init(src);
    var prev_line: u32 = 0;
    var prev_char: u32 = 0;

    while (true) {
        const tok = tokenizer.nextSemantic() catch break;
        if (tok.kind == .eof) break;

        const token_type: ?u32 = switch (tok.kind) {
            .classKeyword,
            .deleteKeyword,
            .enumKeyword,
            .execKeyword,
            .evalKeyword      => 0,
            .comment          => 1,
            .identifier       => 2,
            .stringLiteral    => 3,
            .equals,
            .addAssign,
            .subAssign        => 4,
            .intLiteral,
            .floatLiteral,
            .int64Literal     => 5,
            else              => null,
        };

        const tt = token_type orelse continue;

        const pos    = lspPos(&line_table, tok.pos);
        const length: u32 = tokenLength(src, tok);

        const delta_line = pos.line - prev_line;
        const delta_char = if (delta_line == 0) pos.character - prev_char
        else pos.character;

        data.append(arena, delta_line) catch break;
        data.append(arena, delta_char) catch break;
        data.append(arena, length)     catch break;
        data.append(arena, tt)         catch break;
        data.append(arena, 0)          catch break;

        prev_line = pos.line;
        prev_char = pos.character;
    }

    return .{ .data = data.items };
}

fn findParamInBase(
    base:       *const paramlib.cpp.ast.ClassAst,
    param_name: []const u8,
) ?*const paramlib.cpp.ast.ParameterAst {
    var current: ?*const paramlib.cpp.ast.ClassAst = base;
    while (current) |cls| {
        if (cls.members) |members| {
            for (members.items) |*m| {
                if (m.* == .param and std.mem.eql(u8, m.param.name, param_name))
                    return &m.param;
            }
        }
        current = cls.base;
    }
    return null;
}

fn definition(
    documents: *const std.StringArrayHashMapUnmanaged([]const u8),
    arena:     std.mem.Allocator,
    params:    lsp.types.Definition.Params,
) ?lsp.types.Definition.Result {
    const text = documents.get(params.textDocument.uri) orelse return null;
    const src   = arena.dupeZ(u8, text) catch return null;

    const line_table = paramlib.cpp.lines.LineTable.build(arena, src) catch return null;

    const offset = offsetOf(
        line_table, src,
        @as(u32, @intCast(params.position.line))      + 1,
        @as(u32, @intCast(params.position.character)) + 1,
    );

    var errored = false;
    var root = paramlib.cpp.parser.parseSource(arena, src, &errored, .none()) catch return null;
    defer root.deinit(arena);

    if (findBaseRefAtOffset(&root, offset)) |base_class| {
        const base_name = base_class.name orelse return null;
        const start = lspPos(&line_table, base_class.namePos);
        const end   = lsp.types.Position{
            .line      = start.line,
            .character = start.character + @as(u32, @intCast(base_name.len)),
        };
        return lsp.types.Definition.Result{ .definition = .{ .location = .{
            .uri   = params.textDocument.uri,
            .range = .{ .start = start, .end = end },
        }}};
    }

    const node = findNodeAtOffset(&root, offset) orelse return null;
    if (node != .param) return null;

    const enclosing = findClassAtOffset(&root, offset) orelse return null;
    const base_param = findParamInBase(enclosing.base orelse return null, node.param.name) orelse return null;

    const start = lspPos(&line_table, base_param.namePos);
    const end   = lsp.types.Position{
        .line      = start.line,
        .character = start.character + @as(u32, @intCast(base_param.name.len)),
    };
    return lsp.types.Definition.Result{ .definition = .{ .location = .{
        .uri   = params.textDocument.uri,
        .range = .{ .start = start, .end = end },
    }}};
}

fn findBaseRefAtOffset(
    class:  *const paramlib.cpp.ast.ClassAst,
    offset: u32,
) ?*const paramlib.cpp.ast.ClassAst {
    const members = class.members orelse return null;
    for (members.items) |*m| {
        if (m.* != .class) continue;
        const c = m.class;

        if (c.base) |base| {
            if (base.name) |bname| {
                const ref_end = c.baseRefPos + @as(u32, @intCast(bname.len));
                if (offset >= c.baseRefPos and offset < ref_end) {
                    return base;
                }
            }
        }

        if (findBaseRefAtOffset(c, offset)) |found| return found;
    }
    return null;
}

fn collectClassOverrides(
    class:      *const paramlib.cpp.ast.ClassAst,
    base_name:  []const u8,
    uri:        []const u8,
    line_table: *const paramlib.cpp.lines.LineTable,
    list:       *std.ArrayList(lsp.types.Location),
    arena:      std.mem.Allocator,
) void {
    const members = class.members orelse return;
    for (members.items) |*m| {
        if (m.* != .class) continue;
        const c = m.class;
        if (c.base) |base| {
            if (base.name) |bname| {
                if (std.mem.eql(u8, bname, base_name) and c.baseRefPos > 0) {
                    const start = lspPos(line_table, c.baseRefPos);
                    const end   = lsp.types.Position{
                        .line      = start.line,
                        .character = start.character + @as(u32, @intCast(bname.len)),
                    };
                    list.append(arena, .{ .uri = uri, .range = .{ .start = start, .end = end } }) catch {};
                }
            }
        }
        collectClassOverrides(c, base_name, uri, line_table, list, arena);
    }
}

fn collectParamOverrides(
    class:      *const paramlib.cpp.ast.ClassAst,
    param_name: []const u8,
    owner_name: []const u8,
    uri:        []const u8,
    line_table: *const paramlib.cpp.lines.LineTable,
    list:       *std.ArrayList(lsp.types.Location),
    arena:      std.mem.Allocator,
) void {
    const members = class.members orelse return;
    for (members.items) |*m| {
        switch (m.*) {
            .param => |*p| {
                if (std.mem.eql(u8, p.name, param_name)) {
                    if (class.name == null or !std.mem.eql(u8, class.name.?, owner_name)) {
                        const start = lspPos(line_table, p.namePos);
                        const end   = lsp.types.Position{
                            .line      = start.line,
                            .character = start.character + @as(u32, @intCast(p.name.len)),
                        };
                        list.append(arena, .{ .uri = uri, .range = .{ .start = start, .end = end } }) catch {};
                    }
                }
            },
            .class => |c| {
                collectParamOverrides(c, param_name, owner_name, uri, line_table, list, arena);
            },
            else => {},
        }
    }
}

fn references(
    documents: *const std.StringArrayHashMapUnmanaged([]const u8),
    arena:     std.mem.Allocator,
    params:    lsp.types.reference.Params,
) ?[]const lsp.types.Location {
    const text = documents.get(params.textDocument.uri) orelse return null;
    const src   = arena.dupeZ(u8, text) catch return null;
    const line_table = paramlib.cpp.lines.LineTable.build(arena, src) catch return null;
    const offset = offsetOf(
        line_table, src,
        @as(u32, @intCast(params.position.line))      + 1,
        @as(u32, @intCast(params.position.character)) + 1,
    );
    var errored = false;
    var root = paramlib.cpp.parser.parseSource(arena, src, &errored, .none()) catch return null;
    defer root.deinit(arena);

    const cursor_node = findNodeAtOffset(&root, offset);
    const cursor_base = if (cursor_node == null) findBaseRefAtOffset(&root, offset) else null;
    if (cursor_node == null and cursor_base == null) return null;

    const cursor_enclosing: ?*const paramlib.cpp.ast.ClassAst = blk: {
        if (cursor_node) |node| switch (node) {
            .param => break :blk findClassAtOffset(&root, offset),
            else   => {},
        };
        break :blk null;
    };

    var list = std.ArrayList(lsp.types.Location).empty;
    const doc_uri = params.textDocument.uri;

    if (cursor_node) |node| {
        switch (node) {
            .class => |c| {
                const class_name = c.name orelse return null;
                collectClassOverrides(&root, class_name, doc_uri, &line_table, &list, arena);
            },
            .param => |p| {
                const owner = if (cursor_enclosing) |ce| ce.name orelse "" else "";
                collectParamOverrides(&root, p.name, owner, doc_uri, &line_table, &list, arena);
            },
        }
    } else if (cursor_base) |base| {
        const base_name = base.name orelse return null;
        collectClassOverrides(&root, base_name, doc_uri, &line_table, &list, arena);
    }

    if (list.items.len == 0) return null;
    return list.toOwnedSlice(arena) catch null;
}

fn hover(
    documents: *const std.StringArrayHashMapUnmanaged([]const u8),
    schema:    *const SchemaState,
    arena:     std.mem.Allocator,
    params:    lsp.types.Hover.Params,
) ?lsp.types.Hover {
    log("[hover] called for uri={s}, schema has {d} paramDocs", .{params.textDocument.uri, schema.paramDocs.len});
    const text = documents.get(params.textDocument.uri) orelse return null;

    const src = arena.dupeZ(u8, text) catch return null;

    const line_table = paramlib.cpp.lines.LineTable.build(arena, src) catch return null;

    const offset = offsetOf(
        line_table, src,
        @as(u32, @intCast(params.position.line))      + 1,
        @as(u32, @intCast(params.position.character)) + 1,
    );

    var errored = false;
    var root = paramlib.cpp.parser.parseSource(arena, src, &errored, .none()) catch return null;
    defer root.deinit(arena);

    const node = findNodeAtOffset(&root, offset) orelse return null;

    const content: []const u8 = switch (node) {

        .class => |c| blk: {
            const name         = c.name orelse break :blk null;
            const member_count = if (c.members) |m| m.items.len else 0;
            if (c.base) |base| {
                const base_name = base.name orelse "?";
                break :blk std.fmt.allocPrint(
                    arena,
                    "**class** `{s}` : `{s}`\n\n*{d} member(s)*",
                    .{ name, base_name, member_count },
                ) catch return null;
            }
            break :blk std.fmt.allocPrint(
                arena,
                "**class** `{s}`\n\n*{d} member(s)*",
                .{ name, member_count },
            ) catch return null;
        },

        .param => |p| blk: {
            const op = switch (p.operator) {
                .assign    => "=",
                .addAssign => "+=",
                .subAssign => "-=",
            };
            const val = switch (p.value) {
                .integer    => |v| std.fmt.allocPrint(arena, "**int** `{d}`",       .{v}) catch return null,
                .i64        => |v| std.fmt.allocPrint(arena, "**i64** `{d}`",       .{v}) catch return null,
                .float      => |v| std.fmt.allocPrint(arena, "**float** `{d}`",     .{v}) catch return null,
                .string     => |v| std.fmt.allocPrint(arena, "**string** `\"{s}\"`",.{v}) catch return null,
                .expression => |v| std.fmt.allocPrint(arena, "**expression** `@{s}`",.{v}) catch return null,
                .array      => |v| std.fmt.allocPrint(arena, "**array**[{d}]",      .{v.len}) catch return null,
            };
            const type_line = std.fmt.allocPrint(
                arena, "**param** `{s}` {s} {s}", .{ p.name, op, val },
            ) catch return null;

            const enclosing = findClassAtOffset(&root, offset);
            log("[hover] param.name={s}, enclosing={?s}", .{ p.name, if (enclosing) |enc| enc.name else null });
            const doc_str: ?[]const u8 = if (enclosing) |enc| doc_blk: {
                var path_parts = std.ArrayList([]const u8).empty;
                _ = buildPathToClass(arena, &root, enc, &path_parts);
                const class_dot_path = std.mem.join(arena, ".", path_parts.items) catch break :doc_blk null;
                const dot_path = if (class_dot_path.len > 0)
                    std.fmt.allocPrint(arena, "{s}.{s}", .{ class_dot_path, p.name }) catch break :doc_blk null
                else
                    p.name;
                log("[hover] computed dot_path={s}", .{dot_path});
                const rule = schema.docRuleFor(dot_path) orelse break :doc_blk null;
                log("[hover] docRuleFor({s}) matched source='{s}'", .{ dot_path, rule.source });
                if (rule.source.len > 0) {
                    break :doc_blk std.fmt.allocPrint(arena, "{s}\n\n*Source: {s}*", .{ rule.doc, rule.source }) catch rule.doc;
                }
                break :doc_blk rule.doc;
            } else null;

            log("[hover] final: doc_str={?s}, using={s}", .{ doc_str, if (doc_str != null) "paramDoc" else "type_line" });
            break :blk doc_str orelse type_line;
        },
    } orelse return null;

    return lsp.types.Hover{
        .contents = .{ .markup_content = .{ .kind = .markdown, .value = content } },
    };
}

fn collectDocumentParams(
    root:       *const paramlib.cpp.ast.ClassAst,
    class:      *const paramlib.cpp.ast.ClassAst,
    line_table: *const paramlib.cpp.lines.LineTable,
    arena:      std.mem.Allocator,
    list:       *std.ArrayList(DocumentParam),
) void {
    var path_parts = std.ArrayList([]const u8).empty;
    _ = buildPathToClass(arena, root, class, &path_parts);
    const class_dot_path = std.mem.join(arena, ".", path_parts.items) catch "";

    const members = class.members orelse return;
    for (members.items) |*m| {
        switch (m.*) {
            .param => |*p| {
                const dot_path = if (class_dot_path.len > 0)
                    std.fmt.allocPrint(arena, "{s}.{s}", .{ class_dot_path, p.name }) catch p.name
                else p.name;

                const pos     = lspPos(line_table, p.namePos);
                const val_pos = lspPos(line_table, p.valuePos);
                const val_str = fmtValue(arena, p.value);

                var elem_ps: []Position = &.{};
                if (p.elemPositions) |eps| {
                    elem_ps = arena.alloc(Position, eps.len) catch &.{};
                    for (eps, 0..) |ep, i| {
                        const lp = lspPos(line_table, ep);
                        elem_ps[i] = .{ .line = lp.line, .character = lp.character };
                    }
                }

                list.append(arena, .{
                    .path            = dot_path,
                    .value           = val_str,
                    .line            = pos.line,
                    .character       = pos.character,
                    .value_line      = val_pos.line,
                    .value_character = val_pos.character,
                    .elem_positions  = elem_ps,
                }) catch {};
            },
            .class => |c| {
                collectDocumentParams(root, c, line_table, arena, list);
            },
            else => {},
        }
    }
}

fn collectSymbols(
    gpa:        std.mem.Allocator,
    class:      *const paramlib.cpp.ast.ClassAst,
    uri:        []const u8,
    line_table: *const paramlib.cpp.lines.LineTable,
    list:       *std.ArrayList(lsp.types.SymbolInformation),
) void {
    const members = class.members orelse return;
    for (members.items) |*member| {
        switch (member.*) {
            .class => |c| {
                if (c.name) |name| {
                    const start = lspPos(line_table, c.namePos);
                    const end   = lsp.types.Position{
                        .line      = start.line,
                        .character = start.character + @as(u32, @intCast(name.len)),
                    };
                    list.append(gpa, .{
                        .name     = gpa.dupe(u8, name) catch continue,
                        .kind     = .Class,
                        .location = .{ .uri = uri, .range = .{ .start = start, .end = end } },
                    }) catch {};
                }
                collectSymbols(gpa, c, uri, line_table, list);
            },
            .param => |*p| {
                const start = lspPos(line_table, p.namePos);
                const end   = lsp.types.Position{
                    .line      = start.line,
                    .character = start.character + @as(u32, @intCast(p.name.len)),
                };
                list.append(gpa, .{
                    .name     = gpa.dupe(u8, p.name) catch continue,
                    .kind     = .Field,
                    .location = .{ .uri = uri, .range = .{ .start = start, .end = end } },
                }) catch {};
            },
            .delete    => {},
            .enumerable => {},
        }
    }
}

fn documentSymbols(
    documents: *const std.StringArrayHashMapUnmanaged([]const u8),
    gpa:       std.mem.Allocator,
    params:    lsp.types.DocumentSymbol.Params,
) ?[]const lsp.types.SymbolInformation {
    const text = documents.get(params.textDocument.uri) orelse return null;

    const src = gpa.dupeZ(u8, text) catch return null;
    defer gpa.free(src);

    const line_table = paramlib.cpp.lines.LineTable.build(gpa, src) catch return null;
    defer line_table.deinit(gpa);

    var errored = false;
    var root = paramlib.cpp.parser.parseSource(gpa, src, &errored, .none()) catch return null;

    defer root.deinit(gpa);

    var list = std.ArrayList(lsp.types.SymbolInformation).empty;
    errdefer {
        for (list.items) |sym| gpa.free(sym.name);
        list.deinit(gpa);
    }

    collectSymbols(gpa, &root, params.textDocument.uri, &line_table, &list);

    if (list.items.len == 0) {
        list.deinit(gpa);
        return null;
    }
    return list.toOwnedSlice(gpa) catch null;
}

fn publishDiagnostics(
    transport: *lsp.Transport,
    io:        std.Io,
    gpa:       std.mem.Allocator,
    documents: *const std.StringArrayHashMapUnmanaged([]const u8),
    uri:       []const u8,
) !void {
    const text = documents.get(uri) orelse return;

    const src = try gpa.dupeZ(u8, text);
    defer gpa.free(src);

    const line_table = try paramlib.cpp.lines.LineTable.build(gpa, src);
    defer line_table.deinit(gpa);

    var raw_diags: std.ArrayListUnmanaged(paramlib.cpp.logger.DiagEntry) = .empty;
    defer raw_diags.deinit(gpa);

    var errored = false;
    var root = paramlib.cpp.parser.parseSource(gpa, src, &errored, paramlib.cpp.logger.DiagType.sink(gpa, &raw_diags, uri, &line_table, null)) catch |err| {
        try transport.writeNotification(io, gpa,
            "textDocument/publishDiagnostics",
            lsp.types.publish_diagnostics.Params,
            .{ .uri = uri, .diagnostics = &.{
                .{
                    .range    = .{ .start = .{ .line = 0, .character = 0 },
                                   .end   = .{ .line = 0, .character = 0 } },
                    .severity = .Error,
                    .message  = @errorName(err),
                },
            }},
            .{ .emit_null_optional_fields = false },
        );
        return;
    };
    root.deinit(gpa);

    var diags = std.ArrayList(lsp.types.Diagnostic).empty;
    defer diags.deinit(gpa);

    for (raw_diags.items) |entry| {
        const start = lspPos(&line_table, entry.token_pos);
        const end   = lsp.types.Position{
            .line      = start.line,
            .character = start.character + entry.span,
        };
        const severity: lsp.types.Diagnostic.Severity = switch (entry.level) {
            .err     => .Error,
            .warning => .Warning,
            .note    => .Information,
            .hint    => .Hint,
        };
        try diags.append(gpa, .{
            .range    = .{ .start = start, .end = end },
            .severity = severity,
            .message  = entry.message,
        });
    }

    try transport.writeNotification(io, gpa,
        "textDocument/publishDiagnostics",
        lsp.types.publish_diagnostics.Params,
        .{ .uri = uri, .diagnostics = diags.items },
        .{ .emit_null_optional_fields = false },
    );
}

fn offsetOf(lt: paramlib.cpp.lines.LineTable, src: [:0]const u8, line: u32, col: u32) u32 {
    const line_start: u32 = if (line <= 1) 0
        else lt.newline_offsets[@min(line - 2, lt.newline_offsets.len -| 1)] + 1;
    return @min(line_start + col - 1, @as(u32, @intCast(src.len)));
}

fn lspPos(lt: *const paramlib.cpp.lines.LineTable, offset: u32) lsp.types.Position {
    const r = lt.resolve(offset);
    const line: u32 = if (r.line > 0) r.line - 1 else 0;
    const character: u32 = if (r.column > 0) r.column - 1 else 0;
    return .{ .line = line, .character = character };
}

fn findClassAtOffset(class: *const paramlib.cpp.ast.ClassAst, offset: u32) ?*const paramlib.cpp.ast.ClassAst {
    const members = class.members orelse return null;

    for (members.items) |*m| {
        if (m.* != .class) continue;
        const c = m.class;
        if (c.name == null or c.members == null) continue;
        if (offset > c.namePos and offset <= c.bodyEndPos) {
            return findClassAtOffset(c, offset) orelse c;
        }
    }
    return null;
}

fn fmtValue(arena: std.mem.Allocator, value: paramlib.cpp.ast.ValueAst) []const u8 {
    return switch (value) {
        .integer    => |v| std.fmt.allocPrint(arena, "{d}",     .{v}) catch "?",
        .i64        => |v| std.fmt.allocPrint(arena, "{d}",     .{v}) catch "?",
        .float      => |v| std.fmt.allocPrint(arena, "{d}",     .{v}) catch "?",
        .string     => |v| std.fmt.allocPrint(arena, "\"{s}\"", .{v}) catch "?",
        .expression => |v| std.fmt.allocPrint(arena, "@{s}",    .{v}) catch "?",
        .array      => |v| fmtArray(arena, v),
    };
}

fn fmtArray(arena: std.mem.Allocator, elems: []const paramlib.cpp.ast.ValueAst) []const u8 {
    var buf = std.ArrayList(u8).empty;
    buf.append(arena, '{') catch return "?";
    for (elems, 0..) |elem, i| {
        if (i > 0) buf.appendSlice(arena, ", ") catch return "?";
        buf.appendSlice(arena, fmtValue(arena, elem)) catch return "?";
    }
    buf.append(arena, '}') catch return "?";
    return buf.toOwnedSlice(arena) catch "?";
}

fn buildPathToClass(
    allocator: std.mem.Allocator,
    class:     *const paramlib.cpp.ast.ClassAst,
    target:    *const paramlib.cpp.ast.ClassAst,
    path:      *std.ArrayList([]const u8),
) bool {
    if (class == target) return true;
    const members = class.members orelse return false;
    for (members.items) |*m| {
        if (m.* != .class) continue;
        const name = m.class.name orelse continue;
        path.append(allocator, name) catch return false;
        if (buildPathToClass(allocator, m.class, target, path)) return true;
        _ = path.pop();
    }
    return false;
}

fn navigateClassPath(
    class: *const paramlib.cpp.ast.ClassAst,
    path:  []const []const u8,
) ?*const paramlib.cpp.ast.ClassAst {
    if (path.len == 0) return class;
    const members = class.members orelse return null;
    for (members.items) |*m| {
        if (m.* != .class) continue;
        if (m.class.name) |name| {
            if (std.mem.eql(u8, name, path[0]))
                return navigateClassPath(m.class, path[1..]);
        }
    }
    return null;
}

fn resolveImplicitBase(
    root:      *const paramlib.cpp.ast.ClassAst,
    enclosing: *const paramlib.cpp.ast.ClassAst,
    arena:     std.mem.Allocator,
) ?*const paramlib.cpp.ast.ClassAst {
    var path = std.ArrayList([]const u8).empty;
    if (!buildPathToClass(arena, root, enclosing, &path)) return null;

    if (path.items.len < 2) return null;

    const top_name = path.items[0];
    const sub_path = path.items[1..];

    const top: *const paramlib.cpp.ast.ClassAst = blk: {
        const members = root.members orelse return null;
        for (members.items) |*m| {
            if (m.* != .class) continue;
            if (m.class.name) |n|
                if (std.mem.eql(u8, n, top_name)) break :blk m.class;
        }
        return null;
    };

    var cur = top.base;
    while (cur) |base| {
        if (navigateClassPath(base, sub_path)) |found| return found;
        cur = base.base;
    }
    return null;
}

fn findElemPositionsAt(
    class:  *const paramlib.cpp.ast.ClassAst,
    offset: u32,
) ?[]const u32 {
    const members = class.members orelse return null;
    for (members.items) |*m| {
        switch (m.*) {
            .param => |*p| {
                if (p.value == .array and p.valuePos == offset)
                    return p.elemPositions;
            },
            .class => |c| {
                if (findElemPositionsAt(c, offset)) |pos| return pos;
            },
            else => {},
        }
    }
    return null;
}

fn inlayHints(
    documents: *const std.StringArrayHashMapUnmanaged([]const u8),
    schema:    *const SchemaState,
    documentHints: *const std.StringArrayHashMapUnmanaged([]const PrecomputedParserHint),
    arena:     std.mem.Allocator,
    params:    lsp.types.InlayHint.Params,
) ?[]const lsp.types.InlayHint {
    const text = documents.get(params.textDocument.uri) orelse return null;
    const src   = arena.dupeZ(u8, text) catch return null;

    const line_table = paramlib.cpp.lines.LineTable.build(arena, src) catch return null;

    var errored = false;
    var root = paramlib.cpp.parser.parseSource(arena, src, &errored, .none()) catch return null;
    defer root.deinit(arena);

    var hints = std.ArrayList(lsp.types.InlayHint).empty;

    collectArrayInlayHints(&root, &root, schema, &line_table, arena, &hints);

    if (documentHints.get(params.textDocument.uri)) |precomputed| {
        for (precomputed) |ph| {
            if (std.mem.startsWith(u8, ph.text, "texture:")) continue;
            if (std.mem.startsWith(u8, ph.text, "color:")) continue;

            hints.append(arena, lsp.types.InlayHint{
                .position     = .{ .line = ph.line, .character = ph.character },
                .label        = .{ .string = ph.text },
                .kind         = .Parameter,
                .paddingRight = true,
            }) catch {};
        }
    }

    if (hints.items.len == 0) return null;
    return hints.toOwnedSlice(arena) catch null;
}

fn collectArrayInlayHints(
    root:       *const paramlib.cpp.ast.ClassAst,
    class:      *const paramlib.cpp.ast.ClassAst,
    schema:     *const SchemaState,
    line_table: *const paramlib.cpp.lines.LineTable,
    arena:      std.mem.Allocator,
    hints:      *std.ArrayList(lsp.types.InlayHint),
) void {
    var path_parts = std.ArrayList([]const u8).empty;
    _ = buildPathToClass(arena, root, class, &path_parts);
    const class_dot_path = std.mem.join(arena, ".", path_parts.items) catch "";

    const members = class.members orelse return;
    for (members.items) |*m| {
        switch (m.*) {
            .param => |*p| {
                const arr = switch (p.value) {
                    .array => |a| a,
                    else   => continue,
                };
                const dot_path = if (class_dot_path.len > 0)
                    std.fmt.allocPrint(arena, "{s}.{s}", .{ class_dot_path, p.name }) catch p.name
                else p.name;

                const labels = schema.labelsFor(dot_path) orelse continue;
                const positions = p.elemPositions orelse continue;

                for (0..@min(arr.len, @min(labels.len, positions.len))) |idx| {
                    const lbl = labels[idx];
                    if (lbl.len == 0) continue;

                    const pos = lspPos(line_table, positions[idx]);
                    const label_text = std.fmt.allocPrint(arena, "{s}:", .{lbl}) catch continue;
                    hints.append(arena, lsp.types.InlayHint{
                        .position = pos,
                        .label    = .{ .string = label_text },
                        .kind     = .Parameter,
                        .paddingRight = true,
                    }) catch {};
                }
            },
            .class => |c| {
                collectArrayInlayHints(root, c, schema, line_table, arena, hints);
            },
            else => {},
        }
    }
}


fn completion(
    documents: *const std.StringArrayHashMapUnmanaged([]const u8),
    schema:    *const SchemaState,
    arena:     std.mem.Allocator,
    params:    lsp.types.completion.Params,
) ?lsp.types.completion.Result {
    const text = documents.get(params.textDocument.uri) orelse return null;
    const src   = arena.dupeZ(u8, text) catch return null;

    const lineTable = paramlib.cpp.lines.LineTable.build(arena, src) catch return null;

    const offset = offsetOf(
        lineTable, src,
        @as(u32, @intCast(params.position.line))      + 1,
        @as(u32, @intCast(params.position.character)) + 1,
    );

    var errored = false;
    var root = paramlib.cpp.parser.parseSource(arena, src, &errored, .none()) catch return null;
    defer root.deinit(arena);


    const enclosing = findClassAtOffset(&root, offset) orelse return null;

    var enc_path_parts = std.ArrayList([]const u8).empty;
    _ = buildPathToClass(arena, &root, enclosing, &enc_path_parts);
    const enc_dot_path = std.mem.join(arena, ".", enc_path_parts.items) catch "";

    var items = std.ArrayList(lsp.types.completion.Item).empty;

    value_pass: {
        const members = enclosing.members orelse break :value_pass;

        var vp: ?*const paramlib.cpp.ast.ParameterAst = null;
        for (members.items) |*m| {
            if (m.* != .param) continue;
            const p = &m.param;
            if (offset < p.valuePos) continue;
            var blocked = false;
            for (members.items) |*m2| {
                if (m2.* != .param) continue;
                if (m2.param.namePos > p.valuePos and m2.param.namePos <= offset) {
                    blocked = true;
                    break;
                }
            }
            if (!blocked) vp = p;
        }

        const p = vp orelse break :value_pass;
        const dot_path = if (enc_dot_path.len > 0)
            std.fmt.allocPrint(arena, "{s}.{s}", .{ enc_dot_path, p.name }) catch p.name
        else p.name;
        const allowed = schema.valuesFor(dot_path) orelse break :value_pass;
        for (allowed) |val| {
            items.append(arena, lsp.types.completion.Item{
                .label      = val,
                .kind       = .Value,
                .insertText = val,
                .detail     = "schema value",
            }) catch {};
        }
        if (items.items.len > 0) return .{ .completion_items = items.items };
    }

    const effective_base = enclosing.base orelse resolveImplicitBase(&root, enclosing, arena);
    if (effective_base == null) return null;

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(arena);

    if (enclosing.members) |em| {
        for (em.items) |*m| {
            switch (m.*) {
                .param => seen.put(arena, m.param.name, {}) catch {},
                .class => if (m.class.name) |n| seen.put(arena, n, {}) catch {},
                else   => {},
            }
        }
    }

    var current_base: ?*const paramlib.cpp.ast.ClassAst = effective_base;

    while (current_base) |base| {
        const baseName    = base.name orelse "?";
        const baseMembers = base.members orelse {
            current_base = base.base;
            continue;
        };

        for (baseMembers.items) |*m| {
            switch (m.*) {

                .param => |*p| {
                    if (seen.contains(p.name)) continue;
                    seen.put(arena, p.name, {}) catch {};

                    const op_str: []const u8 = switch (p.operator) {
                        .assign    => "=",
                        .addAssign => "+=",
                        .subAssign => "-=",
                    };
                    const dot_path = if (enc_dot_path.len > 0)
                        std.fmt.allocPrint(arena, "{s}.{s}", .{ enc_dot_path, p.name }) catch p.name
                    else p.name;

                    if (schema.valuesFor(dot_path)) |allowed| {
                        for (allowed) |val| {
                            const insert = std.fmt.allocPrint(
                                arena, "{s} {s} {s};", .{ p.name, op_str, val },
                            ) catch continue;
                            const label = std.fmt.allocPrint(
                                arena, "{s} = {s}", .{ p.name, val },
                            ) catch p.name;
                            const detail = std.fmt.allocPrint(
                                arena, "schema value  (from {s})", .{baseName},
                            ) catch "";
                            items.append(arena, lsp.types.completion.Item{
                                .label      = label,
                                .kind       = .Field,
                                .detail     = detail,
                                .insertText = insert,
                            }) catch {};
                        }
                    } else {
                        const value_str = fmtValue(arena, p.value);
                        const insert = std.fmt.allocPrint(
                            arena, "{s} {s} {s};", .{ p.name, op_str, value_str },
                        ) catch continue;
                        const detail = std.fmt.allocPrint(
                            arena, "{s} {s} {s}  (from {s})", .{ p.name, op_str, value_str, baseName },
                        ) catch continue;
                        items.append(arena, lsp.types.completion.Item{
                            .label      = p.name,
                            .kind       = .Field,
                            .detail     = detail,
                            .insertText = insert,
                        }) catch continue;
                    }
                },

               .class => |c| {
                    const name = c.name orelse continue;
                    if (seen.contains(name)) continue;
                    seen.put(arena, name, {}) catch {};

                    const insert = std.fmt.allocPrint(
                        arena, "class {s} : {s} {{\n\t\n}};", .{ name, name },
                    ) catch continue;

                    const detail = std.fmt.allocPrint(
                        arena, "class {s}  (from {s})", .{ name, baseName },
                    ) catch continue;

                    items.append(arena, lsp.types.completion.Item{
                        .label      = name,
                        .kind       = .Class,
                        .detail     = detail,
                        .insertText = insert,
                    }) catch continue;
                },

                else => {},
            }
        }

        current_base = base.base;
    }

    if (items.items.len == 0) return null;

    return lsp.types.completion.Result{
        .completion_items = items.items,
    };
}


test "inheritance chain with multiple CfgSchemas blocks" {
    const alloc = std.testing.allocator;
    const merged_src =
        \\class CfgSchemas {
        \\    class DayZ { rules = 1; };
        \\    class MyProject : DayZ { rules = 2; };
        \\};
        \\class CfgSchemas {
        \\    class MyProject;
        \\    class NextProject : MyProject { rules = 3; };
        \\};
    ;

    var manager = SchemaManager.empty;
    defer manager.deinit(alloc);

    try manager.updateSchema(alloc, "file:///root/next/paramlib.cpp", merged_src, null);

    const state = manager.getSchemaForUri("file:///root/next/data.rvmat");
    
    try std.testing.expectEqualStrings("NextProject", state.selectedClass);

    const chain = try state.collectInheritanceChain(&manager, alloc);
    defer {
        for (chain) |n| alloc.free(n);
        alloc.free(chain);
    }

    try std.testing.expectEqual(@as(usize, 3), chain.len);
    try std.testing.expectEqualStrings("DayZ", chain[0]);
    try std.testing.expectEqualStrings("MyProject", chain[1]);
    try std.testing.expectEqualStrings("NextProject", chain[2]);
}
