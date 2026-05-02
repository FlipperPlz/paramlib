const std      = @import("std");
const lsp      = @import("lsp");
const paramlib = @import("paramlib");

pub const StringCompletionRule = struct {
    path:   []const u8,
    values: []const []const u8,
};

pub const ArrayInlaysRule = struct {
    path:   []const u8,
    labels: []const []const u8,
};

pub const ParserRule = struct {
    pattern: []const u8,
    wasm_source: []const u8,
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

pub const SchemaState = struct {
    stringCompletions: []StringCompletionRule = &.{},
    arrayInlays: []ArrayInlaysRule = &.{},
    parserRules: []ParserRule = &.{},
    documentHints: std.StringArrayHashMapUnmanaged([]const PrecomputedParserHint) = .empty,
    schemaClasses: []const []const u8 = &.{},

    pub const empty: SchemaState = .{};

    pub fn updateFromContent(self: *SchemaState, alloc: std.mem.Allocator, content: []const u8, class_name: ?[]const u8) void {
        const src = alloc.dupeZ(u8, content) catch return;
        defer alloc.free(src);
        var errored = false;
        var root = paramlib.cpp.parser.parseSource(alloc, src, &errored, .none()) catch return;
        defer root.deinit(alloc);
        const new_classes = collectSchemaClassNames(&root, alloc);
        const sc = findSchemaClass(&root, alloc, class_name) orelse {
            self.deinit(alloc);
            self.schemaClasses = new_classes;
            return;
        };
        const empty_named: std.StringArrayHashMapUnmanaged(SchemaState) = .empty;
        var new_state = buildFromSchemaClass(sc.root_ptr, sc.class_ptr, alloc, &empty_named);
        new_state.schemaClasses = new_classes;
        self.deinit(alloc);
        self.* = new_state;
    }

    pub fn extractFromDocuments(
        self:      *SchemaState,
        alloc:     std.mem.Allocator,
        documents: *const std.StringArrayHashMapUnmanaged([]const u8),
    ) void {
        self.deinit(alloc);

        var named = std.StringArrayHashMapUnmanaged(SchemaState).empty;
        defer {
            var it = named.iterator();
            while (it.next()) |entry| {
                alloc.free(entry.key_ptr.*);
                entry.value_ptr.deinit(alloc);
            }
            named.deinit(alloc);
        }

        for (documents.values()) |text| {
            const src = alloc.dupeZ(u8, text) catch continue;
            defer alloc.free(src);
            var errored = false;
            var root = paramlib.cpp.parser.parseSource(alloc, src, &errored, .none()) catch continue;
            defer root.deinit(alloc);
            const cfg = getCfgSchemasMembers(&root) orelse continue;
            for (cfg.items) |*cm| {
                if (cm.* != .class or cm.class.members == null) continue;
                const name = cm.class.name orelse continue;
                if (named.contains(name)) continue;
                const state = buildFromSchemaClass(&root, &cm.class, alloc, &named);
                const key = alloc.dupe(u8, name) catch { var s = state; s.deinit(alloc); continue; };
                named.put(alloc, key, state) catch { alloc.free(key); var s = state; s.deinit(alloc); };
            }
        }

        var all_names = std.ArrayList([]const u8).empty;
        defer {
            for (all_names.items) |n| alloc.free(n);
            all_names.deinit(alloc);
        }
        var active: SchemaState = .empty;

        for (documents.values()) |text| {
            const src = alloc.dupeZ(u8, text) catch continue;
            defer alloc.free(src);
            var errored = false;
            var root = paramlib.cpp.parser.parseSource(alloc, src, &errored, .none()) catch continue;
            defer root.deinit(alloc);
            const cfg = getCfgSchemasMembers(&root) orelse continue;

            for (cfg.items) |*cm| {
                if (cm.* != .class) continue;
                const name = cm.class.name orelse continue;
                var already = false;
                for (all_names.items) |n| {
                    if (std.mem.eql(u8, n, name)) { already = true; break; }
                }
                if (!already) {
                    const n = alloc.dupe(u8, name) catch continue;
                    all_names.append(alloc, n) catch { alloc.free(n); };
                }
            }

            for (cfg.items) |*cm| {
                if (cm.* != .class or cm.class.members == null) continue;
                const cls  = &cm.class;
                const name = cls.name orelse continue;

                const needs_rebuild: bool = blk: {
                    const base = cls.base orelse break :blk false;
                    if (base.members != null) break :blk false;
                    const bname = base.name orelse break :blk false;
                    break :blk named.contains(bname);
                };
                if (needs_rebuild) {
                    const new_state = buildFromSchemaClass(&root, cls, alloc, &named);
                    if (named.getPtr(name)) |slot| {
                        slot.deinit(alloc);
                        slot.* = new_state;
                    }
                }

                if (named.get(name)) |state| {
                    active.deinit(alloc);
                    active = cloneSchemaState(state, alloc);
                }
            }
        }

        active.schemaClasses = all_names.toOwnedSlice(alloc) catch &.{};
        all_names = .empty;
        self.* = active;
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
        for (members.items) |*m| {
            if (m.* != .class) continue;
            const cfg = &m.class;
            if (cfg.name == null or !std.mem.eql(u8, cfg.name.?, "CfgSchemas")) continue;
            const cfg_members = cfg.members orelse continue;
            var last: ?*const paramlib.cpp.ast.ClassAst = null;
            for (cfg_members.items) |*cm| {
                if (cm.* != .class) continue;
                if (class_name) |name| {
                    if (cm.class.name != null and std.mem.eql(u8, cm.class.name.?, name))
                        return .{ .root_ptr = root, .class_ptr = &cm.class };
                } else {
                    last = &cm.class;
                }
            }
            if (class_name == null) {
                if (last) |l| return .{ .root_ptr = root, .class_ptr = l };
            }
            return null;
        }
        return null;
    }

    fn collectSchemaClassNames(
        root:  *const paramlib.cpp.ast.ClassAst,
        alloc: std.mem.Allocator,
    ) []const []const u8 {
        const members = root.members orelse return &.{};
        for (members.items) |*m| {
            if (m.* != .class) continue;
            const cfg = &m.class;
            if (cfg.name == null or !std.mem.eql(u8, cfg.name.?, "CfgSchemas")) continue;
            const cfg_members = cfg.members orelse return &.{};
            var list = std.ArrayList([]const u8).empty;
            for (cfg_members.items) |*cm| {
                if (cm.* != .class) continue;
                const name = cm.class.name orelse continue;
                const duped = alloc.dupe(u8, name) catch continue;
                list.append(alloc, duped) catch { alloc.free(duped); };
            }
            return list.toOwnedSlice(alloc) catch &.{};
        }
        return &.{};
    }


    fn getCfgSchemasMembers(root: *const paramlib.cpp.ast.ClassAst) ?*std.ArrayList(paramlib.cpp.ast.MemberAst) {
        const top = root.members orelse return null;
        for (top.items) |*m| {
            if (m.* != .class) continue;
            const cfg = &m.class;
            if (cfg.name == null or !std.mem.eql(u8, cfg.name.?, "CfgSchemas")) continue;
            if (cfg.members) |*members| return members;
        }
        return null;
    }

    fn cloneSchemaState(src: SchemaState, alloc: std.mem.Allocator) SchemaState {
        var comps = std.ArrayList(StringCompletionRule).empty;
        for (src.stringCompletions) |rule| {
            const path = alloc.dupe(u8, rule.path) catch continue;
            const vs   = alloc.alloc([]const u8, rule.values.len) catch { alloc.free(path); continue; };
            for (rule.values, 0..) |v, i| vs[i] = alloc.dupe(u8, v) catch "";
            comps.append(alloc, .{ .path = path, .values = vs }) catch {
                alloc.free(path);
                for (vs) |v| alloc.free(v);
                alloc.free(vs);
            };
        }
        var arrays = std.ArrayList(ArrayInlaysRule).empty;
        for (src.arrayInlays) |rule| {
            const path = alloc.dupe(u8, rule.path) catch continue;
            const ls   = alloc.alloc([]const u8, rule.labels.len) catch { alloc.free(path); continue; };
            for (rule.labels, 0..) |l, i| ls[i] = alloc.dupe(u8, l) catch "";
            arrays.append(alloc, .{ .path = path, .labels = ls }) catch {
                alloc.free(path);
                for (ls) |l| alloc.free(l);
                alloc.free(ls);
            };
        }
        var parsers = std.ArrayList(ParserRule).empty;
        for (src.parserRules) |rule| {
            const pattern = alloc.dupe(u8, rule.pattern) catch continue;
            const wasm    = alloc.dupe(u8, rule.wasm_source) catch { alloc.free(pattern); continue; };
            parsers.append(alloc, .{ .pattern = pattern, .wasm_source = wasm }) catch {
                alloc.free(pattern);
                alloc.free(wasm);
            };
        }
        var docHints = std.StringArrayHashMapUnmanaged([]const PrecomputedParserHint).empty;
        var it = src.documentHints.iterator();
        while (it.next()) |entry| {
            const uri = alloc.dupe(u8, entry.key_ptr.*) catch continue;
            const hints = alloc.alloc(PrecomputedParserHint, entry.value_ptr.*.len) catch { alloc.free(uri); continue; };
            for (entry.value_ptr.*, 0..) |h, i| {
                hints[i] = .{
                    .line = h.line,
                    .character = h.character,
                    .text = alloc.dupe(u8, h.text) catch "",
                };
            }
            docHints.put(alloc, uri, hints) catch {
                alloc.free(uri);
                for (hints) |h| alloc.free(h.text);
                alloc.free(hints);
            };
        }
        return .{
            .stringCompletions = comps.toOwnedSlice(alloc)  catch &.{},
            .arrayInlays       = arrays.toOwnedSlice(alloc) catch &.{},
            .parserRules       = parsers.toOwnedSlice(alloc) catch &.{},
            .documentHints     = docHints,
            .schemaClasses     = &.{},
        };
    }

    fn buildFromSchemaClass(
        root:   *const paramlib.cpp.ast.ClassAst,
        schema: *const paramlib.cpp.ast.ClassAst,
        alloc:  std.mem.Allocator,
        named:  *const std.StringArrayHashMapUnmanaged(SchemaState),
    ) SchemaState {
        var base_state: SchemaState = if (schema.base) |base| blk: {
            if (base.members != null) {
                break :blk buildFromSchemaClass(root, base, alloc, named);
            }
            if (base.name) |bname| {
                if (named.get(bname)) |existing| {
                    break :blk cloneSchemaState(existing, alloc);
                }
            }
            break :blk .empty;
        } else .empty;

        var completions = std.ArrayList(StringCompletionRule).fromOwnedSlice(base_state.stringCompletions);
        var arrays      = std.ArrayList(ArrayInlaysRule).fromOwnedSlice(base_state.arrayInlays);
        var parsers     = std.ArrayList(ParserRule).fromOwnedSlice(base_state.parserRules);
        const docHints  = base_state.documentHints;
        base_state.stringCompletions = &.{};
        base_state.arrayInlays       = &.{};
        base_state.parserRules       = &.{};
        base_state.documentHints     = .empty;
        base_state.deinit(alloc);

        const members = schema.members orelse {
            return .{
                .stringCompletions = completions.toOwnedSlice(alloc) catch &.{},
                .arrayInlays       = arrays.toOwnedSlice(alloc)      catch &.{},
                .parserRules       = parsers.toOwnedSlice(alloc)     catch &.{},
                .documentHints     = docHints,
            };
        };

        for (members.items) |*m| {
            if (m.* != .param) continue;
            const p = &m.param;
            const arr = switch (p.value) {
                .array => |a| a,
                else   => continue,
            };
            const is_completions  = std.mem.eql(u8, p.name, "stringCompletions");
            const is_array_inlays = std.mem.eql(u8, p.name, "arrayInlays");
            const is_parsers      = std.mem.eql(u8, p.name, "parsers") or std.mem.eql(u8, p.name, "parserRules");
            if (!is_completions and !is_array_inlays and !is_parsers) continue;

            if (p.operator == .assign) {
                if (is_completions) {
                    for (completions.items) |r| {
                        alloc.free(r.path);
                        for (r.values) |v| alloc.free(v);
                        alloc.free(r.values);
                    }
                    completions.clearRetainingCapacity();
                } else if (is_array_inlays) {
                    for (arrays.items) |r| {
                        alloc.free(r.path);
                        for (r.labels) |l| alloc.free(l);
                        alloc.free(r.labels);
                    }
                    arrays.clearRetainingCapacity();
                } else {
                    for (parsers.items) |r| {
                        alloc.free(r.pattern);
                        alloc.free(r.wasm_source);
                    }
                    parsers.clearRetainingCapacity();
                }
            }

            for (arr) |*entry| {
                const pair = switch (entry.*) {
                    .array => |a| a,
                    else   => continue,
                };
                if (pair.len < 2) continue;

                if (is_parsers) {
                    const pat = switch (pair[0]) {
                        .string => |s| s,
                        else    => continue,
                    };
                    const wasm = switch (pair[1]) {
                        .string => |s| s,
                        else    => continue,
                    };
                    parsers.append(alloc, .{
                        .pattern = alloc.dupe(u8, pat) catch continue,
                        .wasm_source = alloc.dupe(u8, wasm) catch continue,
                    }) catch {};
                    continue;
                }

                const path_str = switch (pair[0]) {
                    .string => |s| s,
                    else    => continue,
                };
                const inner = switch (pair[1]) {
                    .array => |a| a,
                    else   => continue,
                };
                const path = alloc.dupe(u8, path_str) catch continue;
                if (is_completions) {
                    const vs = alloc.alloc([]const u8, inner.len) catch { alloc.free(path); continue; };
                    for (inner, 0..) |*el, i| {
                        vs[i] = switch (el.*) {
                            .string => |s| alloc.dupe(u8, s) catch "",
                            else    => "",
                        };
                    }
                    completions.append(alloc, .{ .path = path, .values = vs }) catch {
                        alloc.free(path);
                        for (vs) |v| alloc.free(v);
                        alloc.free(vs);
                    };
                } else if (is_array_inlays) {
                    const ls = alloc.alloc([]const u8, inner.len) catch { alloc.free(path); continue; };
                    for (inner, 0..) |*el, i| {
                        ls[i] = switch (el.*) {
                            .string => |s| alloc.dupe(u8, s) catch "",
                            else    => "",
                        };
                    }
                    arrays.append(alloc, .{ .path = path, .labels = ls }) catch {
                        alloc.free(path);
                        for (ls) |l| alloc.free(l);
                        alloc.free(ls);
                    };
                }
            }
        }

        return .{
            .stringCompletions = completions.toOwnedSlice(alloc) catch &.{},
            .arrayInlays       = arrays.toOwnedSlice(alloc)      catch &.{},
            .parserRules       = parsers.toOwnedSlice(alloc)     catch &.{},
            .documentHints     = docHints,
        };
    }

    pub fn deinit(self: *SchemaState, alloc: std.mem.Allocator) void {
        for (self.stringCompletions) |rule| {
            alloc.free(rule.path);
            for (rule.values) |v| alloc.free(v);
            alloc.free(rule.values);
        }
        if (self.stringCompletions.len > 0) alloc.free(self.stringCompletions);
        self.stringCompletions = &.{};

        for (self.arrayInlays) |rule| {
            alloc.free(rule.path);
            for (rule.labels) |l| alloc.free(l);
            alloc.free(rule.labels);
        }
        if (self.arrayInlays.len > 0) alloc.free(self.arrayInlays);
        self.arrayInlays = &.{};

        for (self.parserRules) |rule| {
            alloc.free(rule.pattern);
            alloc.free(rule.wasm_source);
        }
        if (self.parserRules.len > 0) alloc.free(self.parserRules);
        self.parserRules = &.{};

        var it = self.documentHints.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |h| alloc.free(h.text);
            alloc.free(entry.value_ptr.*);
        }
        self.documentHints.deinit(alloc);

        for (self.schemaClasses) |name| alloc.free(name);
        if (self.schemaClasses.len > 0) alloc.free(self.schemaClasses);
        self.schemaClasses = &.{};
    }

    pub fn valuesFor(self: *const SchemaState, param_path: []const u8) ?[]const []const u8 {
        for (self.stringCompletions) |rule| {
            if (globMatch(rule.path, param_path)) return rule.values;
        }
        return null;
    }

    pub fn labelsFor(self: *const SchemaState, param_path: []const u8) ?[]const []const u8 {
        for (self.arrayInlays) |rule| {
            const pat = stripArraySuffix(rule.path);
            if (globMatch(pat, param_path)) return rule.labels;
        }
        return null;
    }
};

test "schema: forward decl base resolved from same document" {
    const src =
        \\class CfgSchemas {
        \\    class DayZ {
        \\        stringCompletions[] = {{"Foo.bar", {"a", "b"}}};
        \\    };
        \\    class DayZ;
        \\    class MyProject : DayZ {
        \\        stringCompletions[] += {{"Foo.baz", {"x"}}};
        \\    };
        \\};
    ;
    var docs: std.StringArrayHashMapUnmanaged([]const u8) = .{};
    defer docs.deinit(std.testing.allocator);
    try docs.put(std.testing.allocator, "file://a.cpp", src);

    var state: SchemaState = .empty;
    defer state.deinit(std.testing.allocator);
    state.extractFromDocuments(std.testing.allocator, &docs);

    try std.testing.expect(state.valuesFor("Foo.bar") != null);
    try std.testing.expect(state.valuesFor("Foo.baz") != null);
}

test "schema: forward decl base resolved across two documents" {
    const base_src =
        \\class CfgSchemas {
        \\    class DayZ {
        \\        stringCompletions[] = {{"Weapon.type", {"Rifle", "Pistol"}}};
        \\    };
        \\};
    ;
    const proj_src =
        \\class CfgSchemas {
        \\    class DayZ;
        \\    class MyProject : DayZ {
        \\        stringCompletions[] += {{"Vehicle.type", {"Car", "Truck"}}};
        \\    };
        \\};
    ;

    var docs: std.StringArrayHashMapUnmanaged([]const u8) = .{};
    defer docs.deinit(std.testing.allocator);
    try docs.put(std.testing.allocator, "file://dayz.cpp",   base_src);
    try docs.put(std.testing.allocator, "file://mymod.cpp",  proj_src);

    var state: SchemaState = .empty;
    defer state.deinit(std.testing.allocator);
    state.extractFromDocuments(std.testing.allocator, &docs);

    try std.testing.expect(state.valuesFor("Weapon.type") != null);
    try std.testing.expect(state.valuesFor("Vehicle.type") != null);

    var saw_dayz = false;
    var saw_myproject = false;
    for (state.schemaClasses) |name| {
        if (std.mem.eql(u8, name, "DayZ"))      saw_dayz      = true;
        if (std.mem.eql(u8, name, "MyProject")) saw_myproject = true;
    }
    try std.testing.expect(saw_dayz);
    try std.testing.expect(saw_myproject);
}

test "schema: forward decl base resolved when base doc added after derived doc" {
    const base_src =
        \\class CfgSchemas {
        \\    class DayZ {
        \\        stringCompletions[] = {{"Item.slot", {"Primary", "Secondary"}}};
        \\    };
        \\};
    ;
    const proj_src =
        \\class CfgSchemas {
        \\    class DayZ;
        \\    class MyMod : DayZ {};
        \\};
    ;

    var docs: std.StringArrayHashMapUnmanaged([]const u8) = .{};
    defer docs.deinit(std.testing.allocator);
    try docs.put(std.testing.allocator, "file://mymod.cpp",  proj_src);
    try docs.put(std.testing.allocator, "file://dayz.cpp",   base_src);

    var state: SchemaState = .empty;
    defer state.deinit(std.testing.allocator);
    state.extractFromDocuments(std.testing.allocator, &docs);

    try std.testing.expect(state.valuesFor("Item.slot") != null);
}

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
            var ti = si + 1;
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
    @"textDocument/documentColor":        lsp.types.DocumentColor.Params,
    @"textDocument/colorPresentation":    lsp.types.ColorPresentation.Params,
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
    documents: *std.StringArrayHashMapUnmanaged([]const u8),
    schema:    *SchemaState,
    allocator: std.mem.Allocator,
    io:        std.Io,
    message:   std.json.Parsed(Message),
    transport: *lsp.Transport,
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
                const result = hover(documents, arena.allocator(), params);
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
                const result = completion(documents, schema, arena.allocator(), params);
                try transport.writeResponse(io, allocator, req.id,
                    ?lsp.types.completion.Result, result,
                    .{ .emit_null_optional_fields = false },
                );
            },

            .@"textDocument/inlayHint" => |params| {
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const result = inlayHints(documents, schema, arena.allocator(), params);
                try transport.writeResponse(io, allocator, req.id,
                    ?[]const lsp.types.InlayHint, result,
                    .{ .emit_null_optional_fields = false },
                );
            },

            .@"textDocument/documentColor" => |params| {
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const result = documentColors(schema, arena.allocator(), params);
                try transport.writeResponse(io, allocator, req.id,
                    ?[]const lsp.types.DocumentColor, result,
                    .{ .emit_null_optional_fields = false },
                );
            },

            .@"textDocument/colorPresentation" => |params| {
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const result = colorPresentations(arena.allocator(), params);
                try transport.writeResponse(io, allocator, req.id,
                    ?[]const lsp.types.ColorPresentation, result,
                    .{ .emit_null_optional_fields = false },
                );
            },

            .other => |method_params| {
                if (std.mem.eql(u8, method_params.method, "$/paramlib/listSchemaClasses")) {
                    try transport.writeResponse(io, allocator, req.id,
                        []const []const u8, schema.schemaClasses,
                        .{ .emit_null_optional_fields = false },
                    );
                } else if (std.mem.eql(u8, method_params.method, "$/paramlib/getParserRules")) {
                    try transport.writeResponse(io, allocator, req.id,
                        []const ParserRule, schema.parserRules,
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

                        const line_table = paramlib.cpp.lexer.LineTable.build(allocator, src) catch {
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
                try publishDiagnostics(transport, io, allocator, documents, params.textDocument.uri);
            },

            .@"textDocument/didSave" => |params| {
                if (params.text) |text| {
                    if (documents.getPtr(params.textDocument.uri)) |slot| {
                        allocator.free(slot.*);
                        slot.* = try allocator.dupe(u8, text);
                    }
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

                    if (schema.documentHints.fetchOrderedRemove(parsed.value.uri)) |entry| {
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
                    schema.documentHints.put(allocator, uri, hints) catch {
                        allocator.free(uri);
                        for (hints) |hint| allocator.free(hint.text);
                        allocator.free(hints);
                    };
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

fn findNodeAtOffset(class: *const paramlib.cpp.ast.ClassAst, offset: u32) ?HoverNode {
    const members = class.members orelse return null;
    for (members.items) |*member| {
        switch (member.*) {
            .class => |*c| {
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

    const line_table = paramlib.cpp.lexer.LineTable.build(arena, src) catch return null;

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

    const line_table = paramlib.cpp.lexer.LineTable.build(arena, src) catch return null;

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
        const c = &m.class;

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
    line_table: *const paramlib.cpp.lexer.LineTable,
    list:       *std.ArrayList(lsp.types.Location),
    arena:      std.mem.Allocator,
) void {
    const members = class.members orelse return;
    for (members.items) |*m| {
        if (m.* != .class) continue;
        const c = &m.class;
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
    line_table: *const paramlib.cpp.lexer.LineTable,
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
            .class => |*c| {
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
    const line_table = paramlib.cpp.lexer.LineTable.build(arena, src) catch return null;
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
    arena:     std.mem.Allocator,
    params:    lsp.types.Hover.Params,
) ?lsp.types.Hover {
    const text = documents.get(params.textDocument.uri) orelse return null;

    const src = arena.dupeZ(u8, text) catch return null;

    const line_table = paramlib.cpp.lexer.LineTable.build(arena, src) catch return null;

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
            break :blk std.fmt.allocPrint(
                arena, "**param** `{s}` {s} {s}", .{ p.name, op, val },
            ) catch return null;
        },
    } orelse return null;

    return lsp.types.Hover{
        .contents = .{ .markup_content = .{ .kind = .markdown, .value = content } },
    };
}

fn collectDocumentParams(
    root:       *const paramlib.cpp.ast.ClassAst,
    class:      *const paramlib.cpp.ast.ClassAst,
    line_table: *const paramlib.cpp.lexer.LineTable,
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
            .class => |*c| {
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
    line_table: *const paramlib.cpp.lexer.LineTable,
    list:       *std.ArrayList(lsp.types.SymbolInformation),
) void {
    const members = class.members orelse return;
    for (members.items) |*member| {
        switch (member.*) {
            .class => |*c| {
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

    const line_table = paramlib.cpp.lexer.LineTable.build(gpa, src) catch return null;
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

    const line_table = try paramlib.cpp.lexer.LineTable.build(gpa, src);
    defer line_table.deinit(gpa);

    var raw_diags: std.ArrayListUnmanaged(paramlib.cpp.logger.DiagEntry) = .empty;
    defer raw_diags.deinit(gpa);

    var errored = false;
    var root = paramlib.cpp.parser.parseSource(gpa, src, &errored, .{ .Sink = .{ .list = &raw_diags, .alloc = gpa } }) catch |err| {
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

fn offsetOf(lt: paramlib.cpp.lexer.LineTable, src: [:0]const u8, line: u32, col: u32) u32 {
    const line_start: u32 = if (line <= 1) 0
        else lt.newline_offsets[@min(line - 2, lt.newline_offsets.len -| 1)] + 1;
    return @min(line_start + col - 1, @as(u32, @intCast(src.len)));
}

fn lspPos(lt: *const paramlib.cpp.lexer.LineTable, offset: u32) lsp.types.Position {
    const r = lt.resolve(offset);
    const line: u32 = if (r.line > 0) r.line - 1 else 0;
    const character: u32 = if (r.column > 0) r.column - 1 else 0;
    return .{ .line = line, .character = character };
}

fn findClassAtOffset(class: *const paramlib.cpp.ast.ClassAst, offset: u32) ?*const paramlib.cpp.ast.ClassAst {
    const members = class.members orelse return null;

    for (members.items) |*m| {
        if (m.* != .class) continue;
        const c = &m.class;
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
        if (buildPathToClass(allocator, &m.class, target, path)) return true;
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
                return navigateClassPath(&m.class, path[1..]);
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
                if (std.mem.eql(u8, n, top_name)) break :blk &m.class;
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
            .class => |*c| {
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
    arena:     std.mem.Allocator,
    params:    lsp.types.InlayHint.Params,
) ?[]const lsp.types.InlayHint {
    const text = documents.get(params.textDocument.uri) orelse return null;
    const src   = arena.dupeZ(u8, text) catch return null;

    const line_table = paramlib.cpp.lexer.LineTable.build(arena, src) catch return null;

    var errored = false;
    var root = paramlib.cpp.parser.parseSource(arena, src, &errored, .none()) catch return null;
    defer root.deinit(arena);

    var hints = std.ArrayList(lsp.types.InlayHint).empty;

    collectArrayInlayHints(&root, &root, schema, &line_table, arena, &hints);

    if (schema.documentHints.get(params.textDocument.uri)) |precomputed| {
        for (precomputed) |ph| {
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
    line_table: *const paramlib.cpp.lexer.LineTable,
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
            .class => |*c| {
                collectArrayInlayHints(root, c, schema, line_table, arena, hints);
            },
            else => {},
        }
    }
}

fn parseRgbaFromHint(text: []const u8, out: *[4]u8) bool {
    var it = std.mem.tokenizeScalar(u8, text, ',');
    var i: usize = 0;
    while (it.next()) |part| {
        if (i >= 4) break;
        out[i] = std.fmt.parseInt(u8, std.mem.trim(u8, part, " "), 10) catch return false;
        i += 1;
    }
    return i >= 3;
}

fn documentColors(
    schema: *const SchemaState,
    arena:  std.mem.Allocator,
    params: lsp.types.DocumentColor.Params,
) ?[]const lsp.types.DocumentColor {
    const precomputed = schema.documentHints.get(params.textDocument.uri) orelse return null;
    var colors = std.ArrayList(lsp.types.DocumentColor).empty;
    for (precomputed) |hint| {
        if (!std.mem.startsWith(u8, hint.text, "color:")) continue;
        var rgba: [4]u8 = .{ 0, 0, 0, 255 };
        if (!parseRgbaFromHint(hint.text["color:".len..], &rgba)) continue;
        colors.append(arena, .{
            .range = .{
                .start = .{ .line = hint.line, .character = hint.character },
                .end   = .{ .line = hint.line, .character = hint.character + hint.length },
            },
            .color = .{
                .red   = @as(f32, @floatFromInt(rgba[0])) / 255.0,
                .green = @as(f32, @floatFromInt(rgba[1])) / 255.0,
                .blue  = @as(f32, @floatFromInt(rgba[2])) / 255.0,
                .alpha = @as(f32, @floatFromInt(rgba[3])) / 255.0,
            },
        }) catch continue;
    }
    if (colors.items.len == 0) return null;
    return colors.toOwnedSlice(arena) catch null;
}

fn colorPresentations(
    arena:  std.mem.Allocator,
    params: lsp.types.ColorPresentation.Params,
) ?[]const lsp.types.ColorPresentation {
    const c = params.color;
    const r: u8 = @intFromFloat(@round(c.red   * 255.0));
    const g: u8 = @intFromFloat(@round(c.green * 255.0));
    const b: u8 = @intFromFloat(@round(c.blue  * 255.0));
    const a: u8 = @intFromFloat(@round(c.alpha * 255.0));
    const label = std.fmt.allocPrint(arena, "{{{d}, {d}, {d}, {d}}}", .{ r, g, b, a }) catch return null;
    const list  = arena.alloc(lsp.types.ColorPresentation, 1) catch return null;
    list[0] = .{ .label = label };
    return list;
}

fn completion(
    documents: *const std.StringArrayHashMapUnmanaged([]const u8),
    schema:    *const SchemaState,
    arena:     std.mem.Allocator,
    params:    lsp.types.completion.Params,
) ?lsp.types.completion.Result {
    const text = documents.get(params.textDocument.uri) orelse return null;
    const src   = arena.dupeZ(u8, text) catch return null;

    const lineTable = paramlib.cpp.lexer.LineTable.build(arena, src) catch return null;

    const offset = offsetOf(
        lineTable, src,
        @as(u32, @intCast(params.position.line))      + 1,
        @as(u32, @intCast(params.position.character)) + 1,
    );

    var errored = false;
    var root = paramlib.cpp.parser.parseSource(arena, src, &errored, .none()) catch return null;
    defer root.deinit(arena);


    const enclosing = findClassAtOffset(&root, offset) orelse return null;

    const effective_base = enclosing.base orelse resolveImplicitBase(&root, enclosing, arena);
    if (effective_base == null) return null;

    var items = std.ArrayList(lsp.types.completion.Item).empty;
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

    var enc_path_parts = std.ArrayList([]const u8).empty;
    _ = buildPathToClass(arena, &root, enclosing, &enc_path_parts);
    const enc_dot_path = std.mem.join(arena, ".", enc_path_parts.items) catch "";

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

               .class => |*c| {
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
