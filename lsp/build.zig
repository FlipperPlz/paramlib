const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const paramlib_dep = b.dependency("paramlib", .{
        .target   = target,
        .optimize = optimize,
    });
    const paramlib_mod = paramlib_dep.module("paramlib");

    const lsp_mod = b.dependency("lsp_kit", .{
        .target   = target,
        .optimize = optimize,
    }).module("lsp");

    const paramlsp_mod = b.addModule("paramlsp", .{
        .root_source_file = b.path("src/lsp.zig"),
        .target   = target,
        .optimize = optimize,
        .imports  = &.{
            .{ .name = "paramlib", .module = paramlib_mod },
            .{ .name = "lsp",      .module = lsp_mod      },
        },
    });

    const exe = b.addLibrary(.{
        .name = "paramlsp",
        .root_module = paramlsp_mod,
    });
    exe.root_module.addImport("paramlsp", paramlsp_mod);
    b.installArtifact(exe);

    const lsp_tests = b.addTest(.{
        .name = "lsp-tests",
        .root_module = paramlsp_mod,
    });

    const run_lsp_tests = b.addRunArtifact(lsp_tests);
    const test_step = b.step("test", "Run LSP tests");
    test_step.dependOn(&run_lsp_tests.step);
}
