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
            .imports = &.{},
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
            .root_source_file = b.path("lsp/native.zig"),
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
        .os_tag = .freestanding,
    });

    const lsp_wasm = b.addExecutable(.{
        .name = "paramlib-lsp",
        .root_module = b.createModule(.{
            .target = wasm_target,
            .optimize = optimize,
            .root_source_file = b.path("lsp/web.zig"),
            .imports = &.{
                .{ .name = "paramlib", .module = mod },
                .{ .name = "lsp", .module = lsp_mod }
            },
        }),
    });
    lsp_wasm.entry = .disabled;
    lsp_wasm.rdynamic = true;

    const unit_tests = b.addTest(.{
        .name = "paramlib-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "paramlib", .module = mod },
            },
        }),
    });
    unit_tests.root_module.addOptions("config", options);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const lsp_tests = b.addTest(.{
        .name = "lsp-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("lsp/lsp.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "paramlib", .module = mod },
                .{ .name = "lsp", .module = lsp_mod }
            },
        }),
    });
    const run_lsp_tests = b.addRunArtifact(lsp_tests);
    const lsp_test_step = b.step("test-lsp", "Run LSP tests");
    lsp_test_step.dependOn(&run_lsp_tests.step);

    const lsp_run = b.addRunArtifact(lsp_exe);
    const lsp_run_step = b.step("lsp", "Run the LSP server");
    lsp_run_step.dependOn(&lsp_run.step);

    const install_wasm = b.addInstallFile(
        lsp_wasm.getEmittedBin(),
        "wasm/paramlib-lsp.wasm",
    );
    install_wasm.step.dependOn(&lsp_wasm.step);

    const color_parser_wasm = b.addExecutable(.{
        .name = "color",
        .root_module = b.createModule(.{
            .target = wasm_target,
            .optimize = optimize,
            .root_source_file = b.path("parsers/color/src/main.zig"),
            .imports = &.{
                .{ .name = "lsp", .module = lsp_mod },
            },
        }),
    });
    color_parser_wasm.entry = .disabled;
    color_parser_wasm.rdynamic = true;

    const install_color_wasm = b.addInstallFile(
        color_parser_wasm.getEmittedBin(),
        "parsers/color.wasm",
    );
    install_color_wasm.step.dependOn(&color_parser_wasm.step);

    const texture_source_wasm = b.addExecutable(.{
        .name = "texture_source",
        .root_module = b.createModule(.{
            .target = wasm_target,
            .optimize = optimize,
            .root_source_file = b.path("parsers/texture_source/src/main.zig"),
            .imports = &.{
                .{ .name = "lsp", .module = lsp_mod },
                .{ .name = "paramlib", .module = mod },
            },
        }),
    });
    texture_source_wasm.entry = .disabled;
    texture_source_wasm.rdynamic = true;

    const install_texture_source_wasm = b.addInstallFile(
        texture_source_wasm.getEmittedBin(),
        "parsers/texture_source.wasm"
    );
    install_texture_source_wasm.step.dependOn(&texture_source_wasm.step);

    const default_step = b.getInstallStep();

    if (build_vscode) {
        const vscode_dir = "vscode";

        if (!check_bun) {
            _ = b.step("vscode", "Build VS Code extension (skipped: bun not found)");
            return;
        }

        const vscode_install = b.addSystemCommand(&.{ "bun", "install" });
        vscode_install.step.dependOn(&install_wasm.step);
        vscode_install.step.dependOn(&install_color_wasm.step);
        vscode_install.step.dependOn(&install_texture_source_wasm.step);
        vscode_install.setCwd(b.path(vscode_dir));

        const vscode_compile_ts = b.addSystemCommand(&.{ "bun", "run", "compile" });
        vscode_compile_ts.step.dependOn(&vscode_install.step);
        vscode_compile_ts.setCwd(b.path(vscode_dir));

        const vscode_mkdir = b.addSystemCommand(&.{ "bun", "-e", "import fs from 'fs'; fs.mkdirSync('./out', { recursive: true })" });
        vscode_mkdir.step.dependOn(&vscode_compile_ts.step);
        vscode_mkdir.setCwd(b.path(vscode_dir));

        const vscode_compile = b.addSystemCommand(&.{ "bun", "x", "vsce", "package", "--no-dependencies", "--out", "./out/", zon.version });
        vscode_compile.step.dependOn(&vscode_mkdir.step);
        vscode_compile.setCwd(b.path(vscode_dir));

        const vsix_filename = b.fmt("vscode/paramkit-{s}.vsix", .{ zon.version });
        const vsix_src = b.fmt("{s}/out/paramkit-{s}.vsix", .{ vscode_dir, zon.version });
        const install_vsix = b.addInstallFile(
            b.path(vsix_src),
            vsix_filename,
        );
        install_vsix.step.dependOn(&vscode_compile.step);

        // Make native LSP build depend on vscode compilation being done
        lsp_exe.step.dependOn(&vscode_compile_ts.step);

        default_step.dependOn(&install_vsix.step);
    }

    default_step.dependOn(&install_wasm.step);
    default_step.dependOn(&install_color_wasm.step);
    default_step.dependOn(&install_texture_source_wasm.step);
}
