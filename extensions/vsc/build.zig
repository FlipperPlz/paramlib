const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const wasm_step = b.step("wasm", "Build WASM sub-parser modules");
    buildWasm(b, wasm_step, optimize, "");
}

pub fn buildWasm(
    b: *std.Build,
    step: *std.Build.Step,
    optimize: std.builtin.OptimizeMode,
    comptime prefix: []const u8,
) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const paramlib_dep = b.dependency("paramlib", .{ .target = target, .optimize = optimize });
    const paramlib_mod = paramlib_dep.module("paramlib");
    const color_mod = b.dependency("color", .{ .target = target, .optimize = optimize }).module("color");
    const texture_source_mod = b.dependency("texture_source", .{ .target = target, .optimize = optimize }).module("texture_source");
    const lsp_mod = b.dependency("lsp_kit", .{ .target = target, .optimize = optimize }).module("lsp");
    const paramlsp_dep = b.dependency("paramlsp", .{ .target = target, .optimize = optimize });
    const paramlsp_mod = paramlsp_dep.module("paramlsp");

    const modules_sub = comptime srcPath(prefix, "src/zig/modules");
    var modules_dir = b.build_root.handle.openDir(b.graph.io, modules_sub, .{ .iterate = true }) catch |err| {
        std.debug.print("could not open {s}: {s}\n", .{ modules_sub, @errorName(err) });
        return;
    };
    defer modules_dir.close(b.graph.io);

    var it = modules_dir.iterate();
    while (it.next(b.graph.io) catch null) |entry| {
        const name: []const u8 = blk: {
            switch (entry.kind) {
                .file => {
                    if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                    break :blk b.dupe(entry.name[0 .. entry.name.len - 4]);
                },
                .directory => break :blk b.dupe(entry.name),
                else => continue,
            }
        };

        const source_rel = switch (entry.kind) {
            .file      => b.fmt("{s}/{s}.zig", .{ modules_sub, name }),
            .directory => b.fmt("{s}/{s}/{s}.zig", .{ modules_sub, name, name }),
            else       => unreachable,
        };

        const ModuleType = enum { color, texture_source, core, default };
        const mod_type = std.meta.stringToEnum(ModuleType, name) orelse .default;
        const base_imports = [_]std.Build.Module.Import {
            .{ .name = "lsp",      .module = lsp_mod      },
            .{ .name = "paramlib", .module = paramlib_mod },
        };
        const imports = switch (mod_type) {
            .color => &base_imports ++ [_]std.Build.Module.Import { .{ .name = "color", .module = color_mod } },
            .texture_source => &base_imports ++ [_]std.Build.Module.Import { .{ .name = "texture_source", .module = texture_source_mod } },
            .core => &base_imports ++ [_]std.Build.Module.Import { .{ .name = "paramlsp", .module = paramlsp_mod } },
            .default => &base_imports,
        };

        const module = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(source_rel),
                .target = target,
                .optimize = optimize,
                .imports = imports,
            }),
        });

        module.entry = .disabled;
        module.rdynamic = true;

        step.dependOn(&b.addInstallArtifact(module, .{}).step);
    }
}


fn srcPath(comptime prefix: []const u8, comptime sub: []const u8) []const u8 {
    return if (prefix.len == 0) sub else prefix ++ "/" ++ sub;
}
