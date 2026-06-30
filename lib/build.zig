const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zon = @import("build.zig.zon");

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
            .target   = target,
            .optimize = optimize,
            .imports  = &.{
                .{ .name = "paramlib", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const bench = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target   = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    b.installArtifact(bench);

    const unit_tests = b.addTest(.{
        .name = "paramlib-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target   = target,
            .optimize = optimize,
            .imports  = &.{
                .{ .name = "paramlib", .module = mod },
            },
        }),
    });
    unit_tests.root_module.addOptions("config", options);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
