const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {

    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

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

    // --- LSP server ---------------------------------------------------------
    const lsp_exe = b.addExecutable(.{
        .name = "paramlib-lsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/private/formats/cpp/lsp/main.zig"),
            .target   = target,
            .optimize = optimize,
            .imports  = &.{
                .{ .name = "paramlib", .module = mod },
            },
        }),
    });
    b.installArtifact(lsp_exe);

    const lsp_run      = b.addRunArtifact(lsp_exe);
    const lsp_run_step = b.step("lsp", "Run the LSP server");
    lsp_run_step.dependOn(&lsp_run.step);
    // ------------------------------------------------------------------------

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    const bench_run = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run performance benchmarks");
    bench_step.dependOn(&bench_run.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addInstallArtifact(mod_tests, .{
        .dest_dir = .{ .override = .{ .custom = "tests"}}
    });


    const install_test_step = b.step("install_test", "Create test binaries for debugging");
    install_test_step.dependOn(&run_mod_tests.step);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "paramlib", .module = mod },
            },
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);


    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_unit_tests.step);
}
