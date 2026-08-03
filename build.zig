const std = @import("std");

// Build dockh (the dock) + dockh-config (the graphical config editor), both
// GTK4 apps written in Zig.
//
// Dependencies (Arch / CachyOS):
//   sudo pacman -S gtk4 gtk4-layer-shell zig
//
// The C bindings in src/c.zig are hand-written extern declarations, so the
// build only needs pkg-config to discover the shared libraries (direct +
// transitive deps like glib/gobject are required at link time for symbol
// resolution) — no header parsing, works on any distro.
//
// Module wiring: src/core/fs.zig imports the C bindings through the NAMED
// import "c" (not a ../ relative path), because dockh-config's module is
// rooted at src/config-gui/ where a ../ path would leave the module
// directory. Every module that compiles fs.zig — the dock executable and the
// editor's submodules — therefore registers the "c" module below.

fn addPkgLibs(b: *std.Build, mod: *std.Build.Module, pkg: []const u8) void {
    const libs = b.run(&.{ "pkg-config", "--libs", pkg });
    var it = std.mem.splitScalar(u8, libs, ' ');
    while (it.next()) |tok_raw| {
        const tok = std.mem.trim(u8, tok_raw, " \t\r\n");
        if (tok.len == 0) continue;
        if (std.mem.startsWith(u8, tok, "-l")) {
            mod.linkSystemLibrary(tok[2..], .{});
        } else if (std.mem.startsWith(u8, tok, "-L")) {
            mod.addLibraryPath(.{ .cwd_relative = tok[2..] });
        }
    }
}

fn addExe(
    b: *std.Build,
    name: []const u8,
    root: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    pkg: []const u8,
    imports: []const std.Build.Module.Import,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = imports,
        }),
    });
    // Release builds: strip debug info (smaller binary, less resident RAM).
    if (optimize != .Debug) {
        exe.root_module.strip = true;
    }
    addPkgLibs(b, exe.root_module, pkg);
    return exe;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Clear errors instead of a cryptic mid-build failure when deps are missing.
    // `gl` (Mesa) provides the GL entry points for the liquid-glass shader;
    // epoxy is pulled transitively by gtk4 but we link the GL functions direct.
    const pc_check = b.run(&.{ "sh", "-c", "pkg-config --exists gtk4 gtk4-layer-shell-0 gl || echo MISSING" });
    if (std.mem.indexOf(u8, pc_check, "MISSING") != null) {
        std.debug.print("\nERROR: gtk4, gtk4-layer-shell or gl not found.\n" ++
            "Install them first, e.g. on Arch/CachyOS:\n" ++
            "  sudo pacman -S gtk4 gtk4-layer-shell mesa\n" ++
            "(gtk4-layer-shell provides the pkg-config module gtk4-layer-shell-0)\n\n", .{});
        std.process.exit(1);
    }

    // Shared C bindings module — every module below registers it as "c".
    const c_mod = b.createModule(.{
        .root_source_file = b.path("src/c.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // libc file I/O (imports "c").
    const fs_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/core/fs.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "c", .module = c_mod } },
    });

    // TOML-lite config loader (imports the fs submodule — and config.zig's
    // own graph needs no "c" since fs.zig resolves its own).
    const cfg_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/core/config.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "fs", .module = fs_lib_mod } },
    });

    // dockh: the dock itself. Its root sits at src/, so relative imports
    // (core/config.zig, ui/*.zig, hypr/*.zig) work — but every file uses the
    // NAMED imports "c" and "fs" (src/c.zig and src/core/fs.zig are pulled
    // in through submodules below), so register both on this module.
    const exe = addExe(
        b,
        "dockh",
        "src/main.zig",
        target,
        optimize,
        "gtk4 gtk4-layer-shell-0 gl",
        &.{
            .{ .name = "c", .module = c_mod },
            .{ .name = "fs", .module = fs_lib_mod },
        },
    );

    // The default config.toml, embedded from its own directory (a ../ embed
    // from src/config-gui/ would leave the module's package path).
    const defaults_mod = b.createModule(.{
        .root_source_file = b.path("src/defaults/toml.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // dockh-config: the graphical config editor. Its root file sits in
    // src/config-gui/, so it can't reach ../c.zig etc. directly — expose the
    // shared modules as named imports.
    const cfg_gui_mod = b.createModule(.{
        .root_source_file = b.path("src/config-gui/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = c_mod },
            .{ .name = "cfg", .module = cfg_lib_mod },
            .{ .name = "fs", .module = fs_lib_mod },
            .{ .name = "defaults", .module = defaults_mod },
        },
    });
    const cfg_gui = b.addExecutable(.{
        .name = "dockh-config",
        .root_module = cfg_gui_mod,
    });
    if (optimize != .Debug) {
        cfg_gui.root_module.strip = true;
    }
    addPkgLibs(b, cfg_gui.root_module, "gtk4");

    b.installArtifact(exe);
    b.installArtifact(cfg_gui);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the dock");
    run_step.dependOn(&run_cmd.step);

    const run_cfg = b.addRunArtifact(cfg_gui);
    run_cfg.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cfg.addArgs(args);

    const run_cfg_step = b.step("config", "Run dockh-config (graphical config editor)");
    run_cfg_step.dependOn(&run_cfg.step);

    const version_step = b.step("version", "Print version");
    const vc = b.addRunArtifact(exe);
    vc.addArg("-v");
    version_step.dependOn(&vc.step);

    // Unit tests (src/core/config_test.zig): TOML serializer roundtrip.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/core/config_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = c_mod },
            .{ .name = "fs", .module = fs_lib_mod },
            .{ .name = "config", .module = cfg_lib_mod },
        },
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    addPkgLibs(b, tests.root_module, "gtk4");
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
