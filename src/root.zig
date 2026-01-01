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
    const allocator = testing.allocator;
    const io = testing.io;

    var tree = try ParamTree.init(testing.allocator, testing.io);
    defer tree.deinit(io, allocator);

    const root = tree.facade();
    const obj = try root.createChild("TestObject", allocator, io);

    try obj.setI32("count", 42, allocator, io);
    try obj.setF32("speed", 5.5, allocator, io);
    try obj.setString("name", "Test", allocator, io);

    try testing.expectEqual(@as(i32, 42), (try obj.getI32("count")).?);
    try testing.expectEqual(@as(f32, 5.5), (try obj.getF32("speed")).?);
    try testing.expectEqualStrings("Test", (try obj.getString("name")).?);
}

test "facade hierarchy" {
    const testing = std.testing;

    var tree = try ParamTree.init(testing.allocator, testing.io);
    defer tree.deinit(testing.io, testing.allocator);

    const root = tree.facade();
    const parent = try root.createChild("Parent", testing.allocator, testing.io);
    const child = try parent.createChild("Child", testing.allocator, testing.io);

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

    var tree = try ParamTree.init(testing.allocator, testing.io);
    defer tree.deinit(testing.io, testing.allocator);

    const root = tree.facade();
    const base = try root.createChild("Base", testing.allocator, testing.io);
    const derived = try root.createChild("Derived", testing.allocator, testing.io);

    try base.setI32("value", 100, testing.allocator, testing.io);
    try derived.setBase(base, testing.allocator, testing.io);

    const inherited = try derived.getI32("value");
    try testing.expectEqual(@as(i32, 100), inherited.?);
}

test "facade recursive find child" {
    const testing = std.testing;

    var tree = try ParamTree.init(testing.allocator, testing.io);
    defer tree.deinit(testing.io, testing.allocator);

    const root = tree.facade();

    const parent = try root.createChild("Parent", testing.allocator, testing.io);
    const child = try parent.createChild("Child", testing.allocator, testing.io);
    const target = try root.createChild("Target",testing.allocator, testing.io);

    const found1 = try child.findChild("Target", .{ .look_in_parent = true });
    try testing.expect(found1 != null);
    try testing.expect(found1.?.sameClass(target));
    
    const base = try root.createChild("Base", testing.allocator, testing.io);
    const inherited_target = try base.createChild("InheritedTarget", testing.allocator, testing.io);
    const derived = try root.createChild("Derived", testing.allocator, testing.io);
    try derived.setBase(base, testing.allocator, testing.io);

    const found2 = try derived.findChild("InheritedTarget", .{ .look_in_base = true });
    try testing.expect(found2 != null);
    try testing.expect(found2.?.sameClass(inherited_target));

    const gp_base = try root.createChild("BaseOfGP", testing.allocator, testing.io);
    const gp_target = try gp_base.createChild("GPTarget", testing.allocator, testing.io);
    const gp = try root.createChild("GP", testing.allocator, testing.io);
    try gp.setBase(gp_base, testing.allocator, testing.io);
    const p_of_t = try gp.createChild("ParentOfTest", testing.allocator, testing.io);
    const test_cls = try p_of_t.createChild("TestClass", testing.allocator, testing.io);

    const found3 = try test_cls.findChild("GPTarget", .{ .look_in_parent = true, .look_in_base = true });
    try testing.expect(found3 != null);
    try testing.expect(found3.?.sameClass(gp_target));
}

test "facade getOrDefault" {
    const testing = std.testing;

    var tree = try ParamTree.init(testing.allocator, testing.io);
    defer tree.deinit(testing.io, testing.allocator);

    const root = tree.facade();
    const obj = try root.createChild("Object", testing.allocator, testing.io);

    const default_value = try obj.getI32OrDefault("missing", 42);
    try testing.expectEqual(@as(i32, 42), default_value);

    try obj.setI32("existing", 100, testing.allocator, testing.io);
    const actual_value = try obj.getI32OrDefault("existing", 42);
    try testing.expectEqual(@as(i32, 100), actual_value);
}

test "complete workflow" {
    const alloc = std.testing.allocator;
    const testing = std.testing;

    var tree = try ParamTree.init(alloc, std.testing.io);
    defer tree.deinit(testing.io, alloc);

    const src = try Source.init_runtime("test", std.testing.io, alloc);
    const src_id = try tree.source.registerSource(src, alloc);
    tree.source.setCurrentSource(src_id);

    const root = tree.facade();
    const game = try root.createChild("Game", testing.allocator, testing.io);
    const player = try game.createChild("Player", testing.allocator, testing.io);

    try player.setI32("health", 100, testing.allocator, testing.io);
    try player.setString("name", "TestPlayer", testing.allocator, testing.io);

    const hp = try player.getI32("health");
    try std.testing.expectEqual(@as(i32, 100), hp.?);

    const name = try player.getString("name");
    try std.testing.expectEqualStrings("TestPlayer", name.?);

    const template = try root.createChild("Template", testing.allocator, testing.io);
    try template.setI32("default_hp", 50, testing.allocator, testing.io);

    const enemy = try game.createChild("Enemy", testing.allocator, testing.io);
    try enemy.setBase(template, testing.allocator, testing.io);

    const inherited = try enemy.getI32("default_hp");
    try std.testing.expectEqual(@as(i32, 50), inherited.?);

    const parent = try player.getParent();
    try std.testing.expect(parent != null);

    var children = try game.getChildren(alloc);
    defer children.deinit(alloc);
    try std.testing.expect(children.items.len >= 2);
}

test "source tracking" {
    const testing = std.testing;
    const alloc = std.testing.allocator;

    var tree = try ParamTree.init(alloc, std.testing.io);
    defer tree.deinit(testing.io, alloc);

    const src1 = try Source.init_memory("source1", "data1", std.testing.io, alloc);
    const id1 = try tree.source.registerSource(src1, alloc);

    const src2 = try Source.init_memory("source2", "data2", std.testing.io, alloc);
    const id2 = try tree.source.registerSource(src2, alloc);

    tree.source.setCurrentSource(id1);
    const root = tree.facade();
    const obj = try root.createChild("Object", testing.allocator, testing.io);
    try obj.setI32("value", 10, testing.allocator, testing.io);

    tree.source.setCurrentSource(id2);
    try obj.setI32("value", 20, testing.allocator, testing.io);

    const source = try obj.getSource();
    try std.testing.expectEqual(id2, source);
}

test "inheritance chain" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tree = try ParamTree.init(alloc, std.testing.io);
    defer tree.deinit(io, alloc);

    const root = tree.facade();

    const a = try root.createChild("A", alloc, io);
    try a.setI32("a_val", 1, alloc, io);

    const b = try root.createChild("B", alloc, io);
    try b.setBase(a, alloc, io);
    try b.setI32("b_val", 2, alloc, io);

    const c = try root.createChild("C", alloc, io);
    try c.setBase(b, alloc, io);
    try c.setI32("c_val", 3, alloc, io);

    try std.testing.expectEqual(@as(i32, 1), (try c.getI32("a_val")).?);
    try std.testing.expectEqual(@as(i32, 2), (try c.getI32("b_val")).?);
    try std.testing.expectEqual(@as(i32, 3), (try c.getI32("c_val")).?);
}

test "circular inheritance detection" {
    const testing = std.testing;
    const alloc = std.testing.allocator;

    var tree = try ParamTree.init(alloc, std.testing.io);
    defer tree.deinit(testing.io, alloc);

    const root = tree.facade();

    const a = try root.createChild("A", alloc, testing.io);
    const b = try root.createChild("B", alloc, testing.io);

    try a.setBase(b, alloc, testing.io);

    const result = b.setBase(a, alloc, testing.io);
    try std.testing.expectError(error.CircularInheritance, result);
}

test "value types" {
    const alloc = std.testing.allocator;

    var tree = try ParamTree.init(alloc, std.testing.io);
    defer tree.deinit(std.testing.io, alloc);

    const root = tree.facade();
    const obj = try root.createChild("Object", alloc, std.testing.io);

    try obj.setI32("i32_val", 42, alloc, std.testing.io);
    try obj.setI64("i64_val", 9223372036854775807, alloc, std.testing.io);
    try obj.setF32("f32_val", 3.14, alloc, std.testing.io);
    try obj.setF64("f64_val", 2.718281828459045, alloc, std.testing.io);
    try obj.setString("str_val", "hello", alloc, std.testing.io);

    try std.testing.expectEqual(@as(i32, 42), (try obj.getI32("i32_val")).?);
    try std.testing.expectEqual(@as(i64, 9223372036854775807), (try obj.getI64("i64_val")).?);
    try std.testing.expectEqual(@as(f32, 3.14), (try obj.getF32("f32_val")).?);
    try std.testing.expectEqual(@as(f64, 2.718281828459045), (try obj.getF64("f64_val")).?);
    try std.testing.expectEqualStrings("hello", (try obj.getString("str_val")).?);
}

test "navigation operations" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tree = try ParamTree.init(alloc, std.testing.io);
    defer tree.deinit(io, alloc);

    const root = tree.facade();

    const a = try root.createChild("A", alloc, io);
    const b = try a.createChild("B", alloc, io);
    const c = try b.createChild("C", alloc, io);

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

    var tree = try ParamTree.init(alloc, std.testing.io);
    defer tree.deinit(std.testing.io, alloc);

    const src = try Source.init_runtime("test", std.testing.io, alloc);
    const src_id = try tree.source.registerSource(src, alloc);
    tree.source.setCurrentSource(src_id);

    const root = tree.facade();
    const obj = try root.createChild("Object", alloc, std.testing.io);

    try obj.setI32("value", 10, alloc, std.testing.io);
    try obj.setI32("value", 20, alloc, std.testing.io);
    try obj.setI32("other", 30, alloc, std.testing.io);

    const history = tree.modification.getModificationHistory();
    try std.testing.expect(history.len > 0);
}

test "handle validation" {
    const alloc = std.testing.allocator;

    var tree = try ParamTree.init(alloc, std.testing.io);
    defer tree.deinit(std.testing.io, alloc);

    const root = tree.facade();
    const obj = try root.createChild("Object", alloc, std.testing.io);

    try std.testing.expect(obj.isValid());

    const handle = obj.getHandle();
    try std.testing.expect(handle.isValid());
}

test "stats collection" {
    const alloc = std.testing.allocator;

    var tree = try ParamTree.init(alloc, std.testing.io);
    defer tree.deinit(std.testing.io, alloc);

    const root = tree.facade();

    for (0..10) |i| {
        const name = try std.fmt.allocPrint(alloc, "Object{d}", .{i});
        defer alloc.free(name);
        const obj = try root.createChild(name, alloc, std.testing.io);
        try obj.setI32("value", @intCast(i), alloc, std.testing.io);
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

    var tree = try ParamTree.init(allocator, std.testing.io);
    defer tree.deinit(testing.io, allocator);

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


    const created = try root.createChild("LateClass", std.testing.allocator, std.testing.io);
    _ = created;

    thread.join();

    if (ctx.err) |e| return e;
    try testing.expect(ctx.result != null);
    try testing.expectEqualStrings("LateClass", try ctx.result.?.getName());
}

test "thread safe base setting and waiting" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tree = try ParamTree.init(allocator, testing.io);
    defer tree.deinit(testing.io, allocator);

    const root = tree.facade();
    const derived = try root.createChild("Derived", allocator, testing.io);
    const base = try root.createChild("Base", allocator, testing.io);

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

    try time_mod.sleep(0, std.testing.io);

    try derived.setBase(base, allocator, std.testing.io);

    thread.join();

    if (ctx.err) |e| return e;
    try testing.expect(ctx.result != null);
    try testing.expect(ctx.result.?.sameClass(base));
}

test "thread safe parameter waiting" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tree = try ParamTree.init(allocator, testing.io);
    defer tree.deinit(testing.io, allocator);

    const root = tree.facade();
    const obj = try root.createChild("Object", allocator, testing.io);

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

    try time_mod.sleep(10, testing.io);

    try obj.setI32("health", 100, allocator, std.testing.io);

    thread.join();

    if (ctx.err) |e| return e;
    try testing.expectEqual(@as(i32, 100), ctx.result.?);
}
