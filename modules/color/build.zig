const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    _ = b.standardTargetOptions(.{});

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const lsp_mod = b.dependency("lsp_kit", .{ .target = wasm_target, .optimize = optimize }).module("lsp");

    const paramlib_mod = b.dependency("paramlib", .{ .target = wasm_target, .optimize = optimize }).module("paramlib");

    const mod = b.addModule("color", .{
        .target = wasm_target,
        .optimize = optimize,
        .root_source_file = b.path("src/module.zig"),
        .imports = &.{
            .{ .name = "lsp",      .module = lsp_mod      },
            .{ .name = "paramlib", .module = paramlib_mod },
        },
    });
    const color_wasm = b.addExecutable(.{
        .name = "color",
        .root_module = mod,
    });
    color_wasm.entry = .disabled;
    color_wasm.rdynamic = true;

    const install_wasm = b.addInstallFile(
        color_wasm.getEmittedBin(),
        "parsers/color.wasm",
    );
    install_wasm.step.dependOn(&color_wasm.step);

    b.getInstallStep().dependOn(&install_wasm.step);
}
