const std = @import("std");

// Build dockh: a GTK4 layer-shell dock for Hyprland, written in Zig.
//
// Dependencies (Arch / CachyOS):
//   sudo pacman -S gtk4 gtk4-layer-shell zig
//
// The C bindings in src/c.zig are hand-written extern declarations, so the
// build only needs pkg-config to discover the shared libraries (direct +
// transitive deps like glib/gobject are required at link time for symbol
// resolution) — no header parsing, works on any distro.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "dockh",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    // Release builds: strip debug info (smaller binary, less resident RAM).
    if (optimize != .Debug) {
        exe.root_module.strip = true;
    }
    const mod = exe.root_module;

    // Clear errors instead of a cryptic mid-build failure when deps are missing.
    const pc_check = b.run(&.{ "sh", "-c", "pkg-config --exists gtk4 gtk4-layer-shell-0 || echo MISSING" });
    if (std.mem.indexOf(u8, pc_check, "MISSING") != null) {
        std.debug.print("\nERROR: gtk4 or gtk4-layer-shell not found.\n" ++
            "Install them first, e.g. on Arch/CachyOS:\n" ++
            "  sudo pacman -S gtk4 gtk4-layer-shell\n" ++
            "(gtk4-layer-shell provides the pkg-config module gtk4-layer-shell-0)\n\n", .{});
        std.process.exit(1);
    }

    const libs = b.run(&.{ "pkg-config", "--libs", "gtk4", "gtk4-layer-shell-0" });
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

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the dock");
    run_step.dependOn(&run_cmd.step);

    const version_step = b.step("version", "Print version");
    const vc = b.addRunArtifact(exe);
    vc.addArg("-v");
    version_step.dependOn(&vc.step);
}
