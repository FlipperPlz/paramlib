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

    const mod = b.addModule("texture_source", .{
        .target = wasm_target,
        .optimize = optimize,
        .root_source_file = b.path("src/module.zig"),
        .imports = &.{
            .{ .name = "lsp",      .module = lsp_mod      },
            .{ .name = "paramlib", .module = paramlib_mod },
        },
    });
    const texture_source_wasm = b.addExecutable(.{
        .name = "texture_source",
        .root_module = mod
    });
    texture_source_wasm.entry = .disabled;
    texture_source_wasm.rdynamic = true;

    const install_wasm = b.addInstallFile(
        texture_source_wasm.getEmittedBin(),
        "parsers/texture_source.wasm",
    );
    install_wasm.step.dependOn(&texture_source_wasm.step);

    b.getInstallStep().dependOn(&install_wasm.step);
}
