const std = @import("std");

pub fn build(b: *std.Build) void {

    const build_lib    = b.option(bool, "lib",        "Build paramlib (lib + CLI + bench)")     orelse true;
    const build_lsp    = b.option(bool, "lsp-server", "Build the native LSP-server binary")     orelse true;
    const build_vscode = b.option(bool, "vscode",     "Build the VS Code extension (.vsix)")    orelse true;
    const check_bun    = b.option(bool, "check-bun",  "Gate VS Code build on bun availability") orelse true;

    const fwd_target   = b.option([]const u8, "target",   "Target triple forwarded to sub-builds");
    const fwd_optimize = b.option([]const u8, "optimize", "Optimize mode forwarded to sub-builds");

    const root_path = b.build_root.path orelse ".";

    if (build_lib) {
        const lib_step = b.step("lib", "Build paramlib sub-project");

        const lib_build = subBuild(b, "lib", fwd_target, fwd_optimize, &.{});
        const cp_bin    = copyDir(b, root_path, "lib/zig-out/bin",
                                     b.fmt("{s}/zig-out/paramlib", .{root_path}));
        cp_bin.dependOn(&lib_build.step);

        const rm = removeDir(b, b.fmt("{s}/lib/zig-out", .{root_path}));
        rm.dependOn(cp_bin);

        lib_step.dependOn(rm);
        b.getInstallStep().dependOn(lib_step);
    }

    if (build_lsp) {
        const lsp_step = b.step("lsp-server", "Build paramlsp sub-project");

        const lsp_build = subBuild(b, "lsp", fwd_target, fwd_optimize, &.{});
        const cp_bin    = copyDir(b, root_path, "lsp/zig-out/bin",
                                     b.fmt("{s}/zig-out/paramlsp", .{root_path}));
        cp_bin.dependOn(&lsp_build.step);

        const rm = removeDir(b, b.fmt("{s}/lsp/zig-out", .{root_path}));
        rm.dependOn(cp_bin);

        lsp_step.dependOn(rm);
        b.getInstallStep().dependOn(lsp_step);
    }

    if (build_vscode) {
        const vsc_dir  = b.path("extensions/vsc");
        const vsc_step = b.step("vscode", "Build VS Code extension (WASM + bun bundle)");

        if (check_bun) {
            const bun_install = b.addSystemCommand(&.{ "bun", "install" });
            bun_install.setCwd(vsc_dir);

            const out_dir = b.fmt("{s}/zig-out/paramkit/vsc", .{root_path});
            const mk_out  = b.addSystemCommand(&.{ "sh", "-c", b.fmt("mkdir -p {s}", .{out_dir}) });
            mk_out.step.dependOn(&bun_install.step);

            const bun_package = b.addSystemCommand(&.{ "bun", "run", "package" });
            bun_package.setCwd(vsc_dir);
            bun_package.setEnvironmentVariable("PARAM_OPTIMIZE", fwd_optimize orelse "ReleaseSmall");
            bun_package.step.dependOn(&mk_out.step);

            const rename_vsix = b.addSystemCommand(&.{ "sh", "-c",
                b.fmt("mv {s}/paramkit.vsix {s}/paramkit.vsc", .{ out_dir, out_dir }) });
            rename_vsix.step.dependOn(&bun_package.step);

            const cp_wasm = copyDir(b, root_path,
                                    "extensions/vsc/zig-out/bin",
                                    b.fmt("{s}/internal", .{out_dir}));
            cp_wasm.dependOn(&rename_vsix.step);

            const rm = removeDir(b, b.fmt("{s}/extensions/vsc/zig-out", .{root_path}));
            rm.dependOn(cp_wasm);

            vsc_step.dependOn(rm);
        }
        b.getInstallStep().dependOn(vsc_step);
    }

    {
        const test_step = b.step("test", "Run all tests (lib + lsp)");

        if (build_lib) {
            const t = subBuild(b, "lib", fwd_target, fwd_optimize, &.{"test"});
            test_step.dependOn(&t.step);
        }
        if (build_lsp) {
            const t = subBuild(b, "lsp", fwd_target, fwd_optimize, &.{"test"});
            test_step.dependOn(&t.step);
        }
    }

    {
        const docs_step = b.step("docs", "Generate documentation (Doxygen + Sphinx)");

        const modules = [_][]const u8{ "paramlib", "paramlsp", "paramkit_vsc", "paramkit_modules" };

        var last_doxy_step: ?*std.Build.Step = null;

        for (modules) |mod| {
            const doxy_cmd = b.addSystemCommand(&.{ "doxygen", "Doxyfile" });
            const doxy_path = b.fmt("docs/doxygen/{s}", .{mod});
            doxy_cmd.setCwd(b.path(doxy_path));

            if (last_doxy_step) |prev| {
                doxy_cmd.step.dependOn(prev);
            }
            last_doxy_step = &doxy_cmd.step;
        }

        const sphinx_cmd = b.addSystemCommand(&.{
            "sphinx-build", "-b", "html", "docs", "zig-out/docs",
        });

        if (last_doxy_step) |doxy| {
            sphinx_cmd.step.dependOn(doxy);
        }

        docs_step.dependOn(&sphinx_cmd.step);
    }
}

fn subBuild(
    b:           *std.Build,
    sub_dir:     []const u8,
    target:      ?[]const u8,
    optimize:    ?[]const u8,
    extra_steps: []const []const u8,
) *std.Build.Step.Run {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(b.allocator, &.{ "zig", "build" }) catch @panic("OOM");
    for (extra_steps) |s| argv.append(b.allocator, s) catch @panic("OOM");
    if (target)   |t| argv.append(b.allocator, b.fmt("-Dtarget={s}",   .{t})) catch @panic("OOM");
    if (optimize) |o| argv.append(b.allocator, b.fmt("-Doptimize={s}", .{o})) catch @panic("OOM");

    const cmd = b.addSystemCommand(argv.toOwnedSlice(b.allocator) catch @panic("OOM"));
    cmd.setCwd(b.path(sub_dir));
    return cmd;
}

fn removeDir(b: *std.Build, dir_abs: []const u8) *std.Build.Step {
    const sh_cmd = b.fmt("rm -rf {s}", .{dir_abs});
    const cmd = b.addSystemCommand(&.{ "sh", "-c", sh_cmd });
    return &cmd.step;
}

fn copyDir(
    b:        *std.Build,
    root_abs: []const u8,
    src_rel:  []const u8,
    dst_abs:  []const u8,
) *std.Build.Step {
    const sh_cmd = b.fmt(
        "mkdir -p {s} && [ -d {s}/{s} ] && cp -rT {s}/{s} {s} || true",
        .{ dst_abs, root_abs, src_rel, root_abs, src_rel, dst_abs },
    );
    const cmd = b.addSystemCommand(&.{ "sh", "-c", sh_cmd });
    return &cmd.step;
}
