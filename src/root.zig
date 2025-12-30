const std = @import("std");


pub const ParamTree = @import("core/tree.zig").ParamTree;
pub const Class = @import("core/facade.zig").Class;
pub const Source = @import("data/source.zig").Source;

pub const core = struct {
    pub const ClassHandle = @import("core/identifiers.zig").ClassHandle;
    pub const ClassId = @import("core/identifiers.zig").ClassId;
    pub const ParamId = @import("core/identifiers.zig").ParamId;
    pub const ArrayId = @import("core/identifiers.zig").ArrayId;
};

pub const values = struct {
    pub const Value = @import("data/value.zig").Value;
    pub const ValueTag = @import("data/value.zig").ValueTag;
    pub const ArrayData = @import("data/value.zig").ArrayData;
};

test "facade basic operations" {
    const testing = std.testing;

    var tree = try ParamTree.init(testing.allocator);
    defer tree.deinit();

    const root = Class.init(tree, tree.root_handle);
    const obj = try root.createChild("TestObject");

    try obj.setI32("count", 42);
    try obj.setF32("speed", 5.5);
    try obj.setString("name", "Test");

    try testing.expectEqual(@as(i32, 42), (try obj.getI32("count")).?);
    try testing.expectEqual(@as(f32, 5.5), (try obj.getF32("speed")).?);
    try testing.expectEqualStrings("Test", (try obj.getString("name")).?);
}

test "facade hierarchy" {
    const testing = std.testing;

    var tree = try ParamTree.init(testing.allocator);
    defer tree.deinit();

    const root = Class.init(tree, tree.root_handle);
    const parent = try root.createChild("Parent");
    const child = try parent.createChild("Child");

    const found_parent = try child.getParent();
    try testing.expect(found_parent != null);
    try testing.expect(found_parent.?.sameClass(parent));

    var chain = try child.getParentChain(testing.allocator);
    defer chain.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), chain.items.len);
    try testing.expect(chain.items[0].sameClass(child));
    try testing.expect(chain.items[1].sameClass(parent));
    try testing.expect(chain.items[2].sameClass(root));
}

test "facade inheritance" {
    const testing = std.testing;

    var tree = try ParamTree.init(testing.allocator);
    defer tree.deinit();

    const root = Class.init(tree, tree.root_handle);
    const base = try root.createChild("Base");
    const derived = try root.createChild("Derived");

    try base.setI32("value", 100);
    try derived.setBase(base);

    const inherited = try derived.getI32("value");
    try testing.expectEqual(@as(i32, 100), inherited.?);
}

test "facade recursive find child" {
    const testing = std.testing;

    var tree = try ParamTree.init(testing.allocator);
    defer tree.deinit();

    const root = Class.init(tree, tree.root_handle);

    const parent = try root.createChild("Parent");
    const child = try parent.createChild("Child");
    const target = try root.createChild("Target");

    const found1 = try child.findChild("Target", .{ .look_in_parent = true });
    try testing.expect(found1 != null);
    try testing.expect(found1.?.sameClass(target));
    
    const base = try root.createChild("Base");
    const inherited_target = try base.createChild("InheritedTarget");
    const derived = try root.createChild("Derived");
    try derived.setBase(base);

    const found2 = try derived.findChild("InheritedTarget", .{ .look_in_base = true });
    try testing.expect(found2 != null);
    try testing.expect(found2.?.sameClass(inherited_target));

    const gp_base = try root.createChild("BaseOfGP");
    const gp_target = try gp_base.createChild("GPTarget");
    const gp = try root.createChild("GP");
    try gp.setBase(gp_base);
    const p_of_t = try gp.createChild("ParentOfTest");
    const test_cls = try p_of_t.createChild("TestClass");

    const found3 = try test_cls.findChild("GPTarget", .{ .look_in_parent = true, .look_in_base = true });
    try testing.expect(found3 != null);
    try testing.expect(found3.?.sameClass(gp_target));
}

test "facade getOrDefault" {
    const testing = std.testing;

    var tree = try ParamTree.init(testing.allocator);
    defer tree.deinit();

    const root = Class.init(tree, tree.root_handle);
    const obj = try root.createChild("Object");

    const default_value = try obj.getI32OrDefault("missing", 42);
    try testing.expectEqual(@as(i32, 42), default_value);

    try obj.setI32("existing", 100);
    const actual_value = try obj.getI32OrDefault("existing", 42);
    try testing.expectEqual(@as(i32, 100), actual_value);
}

test "complete workflow" {
    const alloc = std.testing.allocator;

    var tree = try ParamTree.init(alloc);
    defer tree.deinit();

    const src = try Source.init_runtime("test", alloc);
    const src_id = try tree.source.registerSource(src);
    tree.source.setCurrentSource(src_id);

    const root = Class.init(tree, tree.root());
    const game = try root.createChild("Game");
    const player = try game.createChild("Player");

    try player.setI32("health", 100);
    try player.setString("name", "TestPlayer");

    const hp = try player.getI32("health");
    try std.testing.expectEqual(@as(i32, 100), hp.?);

    const name = try player.getString("name");
    try std.testing.expectEqualStrings("TestPlayer", name.?);

    const template = try root.createChild("Template");
    try template.setI32("default_hp", 50);

    const enemy = try game.createChild("Enemy");
    try enemy.setBase(template);

    const inherited = try enemy.getI32("default_hp");
    try std.testing.expectEqual(@as(i32, 50), inherited.?);

    const parent = try player.getParent();
    try std.testing.expect(parent != null);

    var children = try game.getChildren(alloc);
    defer children.deinit(alloc);
    try std.testing.expect(children.items.len >= 2);
}

test "source tracking" {
    const alloc = std.testing.allocator;

    var tree = try ParamTree.init(alloc);
    defer tree.deinit();

    const src1 = try Source.init_memory("source1", "data1", alloc);
    const id1 = try tree.source.registerSource(src1);

    const src2 = try Source.init_memory("source2", "data2", alloc);
    const id2 = try tree.source.registerSource(src2);

    tree.source.setCurrentSource(id1);
    const root = tree.facade();
    const obj = try root.createChild("Object");
    try obj.setI32("value", 10);

    tree.source.setCurrentSource(id2);
    try obj.setI32("value", 20);

    const source = try obj.getSource();
    try std.testing.expectEqual(id2, source);
}

test "inheritance chain" {
    const alloc = std.testing.allocator;

    var tree = try ParamTree.init(alloc);
    defer tree.deinit();

    const root = tree.facade();

    const a = try root.createChild("A");
    try a.setI32("a_val", 1);

    const b = try root.createChild("B");
    try b.setBase(a);
    try b.setI32("b_val", 2);

    const c = try root.createChild("C");
    try c.setBase(b);
    try c.setI32("c_val", 3);

    try std.testing.expectEqual(@as(i32, 1), (try c.getI32("a_val")).?);
    try std.testing.expectEqual(@as(i32, 2), (try c.getI32("b_val")).?);
    try std.testing.expectEqual(@as(i32, 3), (try c.getI32("c_val")).?);
}

test "circular inheritance detection" {
    const alloc = std.testing.allocator;

    var tree = try ParamTree.init(alloc);
    defer tree.deinit();

    const root = Class.init(tree, tree.root());

    const a = try root.createChild("A");
    const b = try root.createChild("B");

    try a.setBase(b);

    const result = b.setBase(a);
    try std.testing.expectError(error.CircularInheritance, result);
}

test "value types" {
    const alloc = std.testing.allocator;

    var tree = try ParamTree.init(alloc);
    defer tree.deinit();

    const root = Class.init(tree, tree.root());
    const obj = try root.createChild("Object");

    try obj.setI32("i32_val", 42);
    try obj.setI64("i64_val", 9223372036854775807);
    try obj.setF32("f32_val", 3.14);
    try obj.setF64("f64_val", 2.718281828459045);
    try obj.setString("str_val", "hello");

    try std.testing.expectEqual(@as(i32, 42), (try obj.getI32("i32_val")).?);
    try std.testing.expectEqual(@as(i64, 9223372036854775807), (try obj.getI64("i64_val")).?);
    try std.testing.expectEqual(@as(f32, 3.14), (try obj.getF32("f32_val")).?);
    try std.testing.expectEqual(@as(f64, 2.718281828459045), (try obj.getF64("f64_val")).?);
    try std.testing.expectEqualStrings("hello", (try obj.getString("str_val")).?);
}

test "navigation operations" {
    const alloc = std.testing.allocator;

    var tree = try ParamTree.init(alloc);
    defer tree.deinit();

    const root = Class.init(tree, tree.root());

    const a = try root.createChild("A");
    const b = try a.createChild("B");
    const c = try b.createChild("C");

    const parent_of_c = try c.getParent();
    try std.testing.expect(parent_of_c != null);

    const parent_of_b = try b.getParent();
    try std.testing.expect(parent_of_b != null);

    var children = try root.getChildren(alloc);
    defer children.deinit(alloc);
    try std.testing.expect(children.items.len >= 1);

    const path = try c.getPath(alloc);
    defer alloc.free(path);
    try std.testing.expect(std.mem.indexOf(u8, path, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, path, "B") != null);
    try std.testing.expect(std.mem.indexOf(u8, path, "C") != null);
}


test "modification tracking" {
    const alloc = std.testing.allocator;

    var tree = try ParamTree.init(alloc);
    defer tree.deinit();

    const src = try Source.init_runtime("test", alloc);
    const src_id = try tree.source.registerSource(src);
    tree.source.setCurrentSource(src_id);

    const root = Class.init(tree, tree.root());
    const obj = try root.createChild("Object");

    try obj.setI32("value", 10);
    try obj.setI32("value", 20);
    try obj.setI32("other", 30);

    const history = tree.modification.getModificationHistory();
    try std.testing.expect(history.len > 0);
}

test "handle validation" {
    const alloc = std.testing.allocator;

    var tree = try ParamTree.init(alloc);
    defer tree.deinit();

    const root = Class.init(tree, tree.root());
    const obj = try root.createChild("Object");

    try std.testing.expect(obj.isValid());

    const handle = obj.getHandle();
    try std.testing.expect(handle.isValid());
}

test "stats collection" {
    const alloc = std.testing.allocator;

    var tree = try ParamTree.init(alloc);
    defer tree.deinit();

    const root = Class.init(tree, tree.root());

    for (0..10) |i| {
        const name = try std.fmt.allocPrint(alloc, "Object{d}", .{i});
        defer alloc.free(name);
        const obj = try root.createChild(name);
        try obj.setI32("value", @intCast(i));
    }

    const stats = tree.store.getStats();
    try std.testing.expect(stats.classes.used_count >= 10);
    try std.testing.expect(stats.params.used_count >= 10);
    try std.testing.expect(stats.strings_count > 0);
}

const time_mod = @import("utils/time.zig");

test "thread safe class creation and waiting" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tree = try ParamTree.init(allocator);
    defer tree.deinit();

    const root = tree.facade();

    const Context = struct {
        root: Class,
        name: []const u8,
        result: ?Class = null,
        err: ?anyerror = null,

        pub fn run(self: *@This()) void {
            self.result = self.root.waitForClass(self.name, null, .{}) catch |e| {
                self.err = e;
                return;
            };
        }
    };

    var ctx = Context{
        .root = root,
        .name = "LateClass",
    };

    const thread = try std.Thread.spawn(.{}, Context.run, .{&ctx});


    const created = try root.createChild("LateClass");
    _ = created;

    thread.join();

    if (ctx.err) |e| return e;
    try testing.expect(ctx.result != null);
    try testing.expectEqualStrings("LateClass", try ctx.result.?.getName());
}

test "thread safe base setting and waiting" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tree = try ParamTree.init(allocator);
    defer tree.deinit();

    const root = tree.facade();
    const derived = try root.createChild("Derived");
    const base = try root.createChild("Base");

    const Context = struct {
        derived: Class,
        result: ?Class = null,
        err: ?anyerror = null,

        pub fn run(self: *@This()) void {
            self.result = self.derived.waitForClass("Base", null, .{.look_in_parent = true}) catch |e| {
                self.err = e;
                return;
            };
        }
    };

    var ctx = Context{
        .derived = derived,
    };

    const thread = try std.Thread.spawn(.{}, Context.run, .{&ctx});

    try time_mod.sleep(0);

    try derived.setBase(base);

    thread.join();

    if (ctx.err) |e| return e;
    try testing.expect(ctx.result != null);
    try testing.expect(ctx.result.?.sameClass(base));
}

test "thread safe parameter waiting" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tree = try ParamTree.init(allocator);
    defer tree.deinit();

    const root = tree.facade();
    const obj = try root.createChild("Object");

    const Context = struct {
        obj: Class,
        result: ?i32 = null,
        err: ?anyerror = null,

        pub fn run(self: *@This()) void {
            const val = self.obj.waitForParam("health") catch |e| {
                self.err = e;
                return;
            };
            self.result = val.data.i32;
        }
    };

    var ctx = Context{
        .obj = obj,
    };

    const thread = try std.Thread.spawn(.{}, Context.run, .{&ctx});

    try time_mod.sleep(10);

    try obj.setI32("health", 100);

    thread.join();

    if (ctx.err) |e| return e;
    try testing.expectEqual(@as(i32, 100), ctx.result.?);
}
