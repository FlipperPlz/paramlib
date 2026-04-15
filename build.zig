const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_vscode = b.option(bool, "vscode", "Build VS Code extension") orelse false;
    const check_bun = b.option(bool, "check-bun", "Check if bun is available") orelse true;

    const mod = b.addModule("paramlib", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);
    mod.addOptions("config", options);

    const exe = b.addExecutable(.{
        .name = "paramlib",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "paramlib", .module = mod },
            },
        }),
    });

    const bench = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "paramlib", .module = mod },
            },
            .link_libc = true,
        })
    });

    b.installArtifact(exe);
    b.installArtifact(bench);

    const lsp_mod = b.dependency("lsp_kit", .{})
        .module("lsp");

    const lsp_exe = b.addExecutable(.{
        .name = "paramlib-lsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/private/formats/cpp/lsp/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "paramlib", .module = mod },
                .{ .name = "lsp", .module = lsp_mod }
            },
        }),
    });
    b.installArtifact(lsp_exe);

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi
    });

    const lsp_wasm = b.addExecutable(.{
        .name = "paramlib-lsp",
        .root_module = b.createModule(.{
            .target = wasm_target,
            .optimize = optimize,
            .root_source_file = b.path("src/private/formats/cpp/lsp/main.zig"),
            .imports = &.{
                .{ .name = "paramlib", .module = mod },
                .{ .name = "lsp", .module = lsp_mod }
            },
        }),
    });

    const lsp_run = b.addRunArtifact(lsp_exe);
    const lsp_run_step = b.step("lsp", "Run the LSP server");
    lsp_run_step.dependOn(&lsp_run.step);

    const install_wasm = b.addInstallFile(
        lsp_wasm.getEmittedBin(),
        "wasm/paramlib-lsp.wasm",
    );
    install_wasm.step.dependOn(&lsp_wasm.step);
    const default_step = b.getInstallStep();

    if (build_vscode) {
        const vscode_dir = "src/private/formats/cpp/lsp/vscode-wrapper";

        if (!check_bun) {
            _ = b.step("vscode", "Build VS Code extension (skipped: bun not found)");
            return;
        }

        const vscode_install = b.addSystemCommand(&.{ "bun", "install" });
        vscode_install.step.dependOn(&install_wasm.step);
        vscode_install.setCwd(b.path(vscode_dir));

        const vscode_compile_ts = b.addSystemCommand(&.{ "bun", "run", "compile" });
        vscode_compile_ts.step.dependOn(&vscode_install.step);
        vscode_compile_ts.setCwd(b.path(vscode_dir));

        const vscode_compile = b.addSystemCommand(&.{ "bun", "x", "vsce", "package", "--no-dependencies", "--out", "./out/", zon.version });
        vscode_compile.step.dependOn(&vscode_compile_ts.step);
        vscode_compile.setCwd(b.path(vscode_dir));

        const vsix_filename = b.fmt("vscode/{s}-lsp-{s}.vsix", .{ @tagName(zon.name), zon.version });
        const vsix_src = b.fmt("{s}/out/{s}-lsp-{s}.vsix", .{ vscode_dir, @tagName(zon.name), zon.version });
        const install_vsix = b.addInstallFile(
            b.path(vsix_src),
            vsix_filename,
        );
        install_vsix.step.dependOn(&vscode_compile.step);
        default_step.dependOn(&install_vsix.step);
    }

    default_step.dependOn(&install_wasm.step);
}
