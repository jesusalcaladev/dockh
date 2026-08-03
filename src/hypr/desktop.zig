//! Freedesktop integration: discover .desktop files across the XDG
//! application dirs (including Flatpak), resolve the icon / name / exec of a
//! window class, and launch applications with posix_spawnp (no fork() in a
//! multithreaded GTK process — safe).
const std = @import("std");
const c = @import("../c.zig");
const fs = @import("../core/fs.zig");
const log = @import("../core/log.zig");

pub const DesktopEntry = struct {
    name: []const u8 = "",
    icon: []const u8 = "",
    exec: []const u8 = "",
};

var app_dirs: []const []const u8 = &.{};

fn allocPrint(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(alloc, fmt, args);
}

pub fn initAppDirs(alloc: std.mem.Allocator) void {
    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(alloc);

    const home = getEnv(alloc, "HOME") orelse "";
    const xdg_data_home = getEnv(alloc, "XDG_DATA_HOME");
    const xdg_data_dirs = getEnv(alloc, "XDG_DATA_DIRS") orelse "/usr/local/share/:/usr/share/";

    const pushDir = struct {
        fn push(list: *std.ArrayList([]const u8), a: std.mem.Allocator, p: []const u8) void {
            if (p.len > 0) list.append(a, p) catch {};
        }
    }.push;

    if (xdg_data_home) |d| {
        pushDir(&dirs, alloc, allocPrint(alloc, "{s}/applications", .{d}) catch "");
    } else if (home.len > 0) {
        pushDir(&dirs, alloc, allocPrint(alloc, "{s}/.local/share/applications", .{home}) catch "");
    }
    var it = std.mem.splitScalar(u8, xdg_data_dirs, ':');
    while (it.next()) |d| {
        if (d.len == 0) continue;
        pushDir(&dirs, alloc, allocPrint(alloc, "{s}/applications", .{d}) catch "");
    }
    // Flatpak
    if (home.len > 0) {
        pushDir(&dirs, alloc, allocPrint(alloc, "{s}/.local/share/flatpak/exports/share/applications", .{home}) catch "");
    }
    dirs.append(alloc, "/var/lib/flatpak/exports/share/applications") catch {};

    app_dirs = dirs.toOwnedSlice(alloc) catch &.{};
}

pub fn getEnv(alloc: std.mem.Allocator, name: [:0]const u8) ?[]const u8 {
    const v = c.getenv(name) orelse return null;
    return alloc.dupe(u8, std.mem.span(v)) catch null;
}

fn lowerDup(alloc: std.mem.Allocator, s: []const u8) []const u8 {
    const out = alloc.dupe(u8, s) catch return s;
    for (out) |*ch| ch.* = std.ascii.toLower(ch.*);
    return out;
}

/// Parse a .desktop file and pull out Name / Icon / Exec.
pub fn parseDesktopFile(alloc: std.mem.Allocator, path: []const u8) !DesktopEntry {
    var entry: DesktopEntry = .{};
    const data = fs.readFileAlloc(alloc, path, 1 << 20) catch return error.Unreadable;
    defer alloc.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.ascii.startsWithIgnoreCase(line, "NAME=") and entry.name.len == 0) {
            entry.name = try alloc.dupe(u8, line[5..]);
        } else if (std.ascii.startsWithIgnoreCase(line, "ICON=") and entry.icon.len == 0) {
            entry.icon = try alloc.dupe(u8, line[5..]);
        } else if (std.ascii.startsWithIgnoreCase(line, "EXEC=") and entry.exec.len == 0) {
            entry.exec = try alloc.dupe(u8, trimExec(line[5..]));
        }
        if (entry.name.len > 0 and entry.icon.len > 0 and entry.exec.len > 0) break;
    }
    return entry;
}

/// Strip %f %u %i %c %k field codes and surrounding quotes from an Exec line.
fn trimExec(s: []const u8) []const u8 {
    var out = std.mem.trim(u8, s, " \t");
    if (std.mem.indexOfScalar(u8, out, '%')) |i| {
        out = std.mem.trim(u8, out[0..i], " \t");
    }
    if (out.len >= 2 and out[0] == '"' and out[out.len - 1] == '"') {
        out = out[1 .. out.len - 1];
    }
    return out;
}

/// Exact matches first: <class>.desktop and <lower(class)>.desktop.
fn findExact(alloc: std.mem.Allocator, class: []const u8) ?[]const u8 {
    for (app_dirs) |d| {
        const candidates = [_][]const u8{ class, lowerDup(alloc, class) };
        for (candidates) |cand| {
            if (cand.len == 0) continue;
            const p = allocPrint(alloc, "{s}/{s}.desktop", .{ d, cand }) catch continue;
            if (fs.pathExists(p)) return p; // caller owns; arena keeps it alive
        }
    }
    return null;
}

/// Best-effort fuzzy match between a Hyprland window class and a .desktop id:
/// split on '-' and ' ', try "org.*" ids, then StartupWMClass.
fn searchDesktopDirs(alloc: std.mem.Allocator, class: []const u8) ?[]const u8 {
    const sep = if (std.mem.indexOfScalar(u8, class, '-')) |i| class[0..i] else class;
    const space_sep = if (std.mem.indexOfScalar(u8, class, ' ')) |i| class[0..i] else class;

    for (app_dirs) |d| {
        const names = fs.listDirFiles(alloc, d) orelse continue;
        defer alloc.free(names);
        for (names) |name| {
            if (!std.mem.endsWith(u8, name, ".desktop")) continue;
            const base = name[0 .. name.len - 8];
            if (std.mem.eql(u8, base, class)) {
                return allocPrint(alloc, "{s}/{s}", .{ d, name }) catch continue;
            }
            if (std.mem.startsWith(u8, base, "org.") and
                (std.ascii.indexOfIgnoreCase(name, sep) != null or
                    std.ascii.indexOfIgnoreCase(name, space_sep) != null))
            {
                return allocPrint(alloc, "{s}/{s}", .{ d, name }) catch continue;
            }
            if (std.mem.eql(u8, base, sep)) {
                return allocPrint(alloc, "{s}/{s}", .{ d, name }) catch continue;
            }
        }
    }
    // StartupWMClass fallback: scan files for the key.
    for (app_dirs) |d| {
        const names = fs.listDirFiles(alloc, d) orelse continue;
        defer alloc.free(names);
        for (names) |name| {
            if (!std.mem.endsWith(u8, name, ".desktop")) continue;
            const full = allocPrint(alloc, "{s}/{s}", .{ d, name }) catch continue;
            const data = fs.readFileAlloc(alloc, full, 1 << 20) catch continue;
            if (std.ascii.indexOfIgnoreCase(data, "StartupWMClass=") != null and
                std.ascii.indexOfIgnoreCase(data, sep) != null)
            {
                return full; // caller owns; arena keeps it alive
            }
        }
    }
    return null;
}

fn findDesktopFile(alloc: std.mem.Allocator, class: []const u8) ?[]const u8 {
    return findExact(alloc, class) orelse searchDesktopDirs(alloc, class);
}

pub fn getEntry(alloc: std.mem.Allocator, class: []const u8) DesktopEntry {
    var entry: DesktopEntry = .{};
    if (class.len == 0) return entry;

    if (findDesktopFile(alloc, class)) |path| {
        const parsed = parseDesktopFile(alloc, path) catch return entry;
        entry = parsed;
        alloc.free(path);
    }
    // An explicit icon path beats everything.
    if (std.mem.startsWith(u8, class, "/")) {
        entry.icon = class;
    }
    return entry;
}

pub fn getIconName(alloc: std.mem.Allocator, class: []const u8) []const u8 {
    const e = getEntry(alloc, class);
    if (e.icon.len > 0) return e.icon;
    return class;
}

pub fn getAppName(alloc: std.mem.Allocator, class: []const u8) []const u8 {
    const e = getEntry(alloc, class);
    if (e.name.len > 0) return e.name;
    return class;
}

/// Resolve the command for a window class and spawn it. Returns true if a
/// process was spawned.
pub fn launch(alloc: std.mem.Allocator, class: []const u8) bool {
    const e = getEntry(alloc, class);
    if (e.exec.len > 0) return spawnCommand(alloc, e.exec);
    return spawnCommand(alloc, class);
}

/// Spawn an arbitrary command line (used by the launcher button and by
/// `launch`). Handles "KEY=value" env prefixes and quoted tokens.
pub fn spawnCommand(alloc: std.mem.Allocator, cmdline: []const u8) bool {
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(alloc);
    var env_list: std.ArrayList([]const u8) = .empty;
    defer env_list.deinit(alloc);

    var it = std.mem.splitScalar(u8, cmdline, ' ');
    var seen_binary = false;
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (!seen_binary and std.mem.indexOfScalar(u8, tok, '=') != null and !std.mem.startsWith(u8, tok, "-")) {
            env_list.append(alloc, tok) catch {};
            continue;
        }
        seen_binary = true;
        argv_list.append(alloc, tok) catch {};
    }
    if (argv_list.items.len == 0) return false;

    const bin = stripQuotes(argv_list.items[0]);
    const bin_z = alloc.dupeZ(u8, bin) catch return false;
    defer alloc.free(bin_z);

    var c_argv: std.ArrayList(?[*:0]u8) = .empty;
    defer c_argv.deinit(alloc);
    for (argv_list.items) |arg| {
        const z = alloc.dupeZ(u8, stripQuotes(arg)) catch return false;
        c_argv.append(alloc, z.ptr) catch return false;
    }
    c_argv.append(alloc, null) catch return false;

    var c_env: std.ArrayList(?[*:0]u8) = .empty;
    defer c_env.deinit(alloc);
    for (env_list.items) |e| {
        const z = alloc.dupeZ(u8, e) catch return false;
        c_env.append(alloc, z.ptr) catch return false;
    }
    c_env.append(alloc, null) catch return false;

    var pid: c_int = 0;
    const envp: [*:null]?[*:0]u8 = if (env_list.items.len > 0)
        @ptrCast(c_env.items.ptr)
    else
        c.environ;

    const rc = c.posix_spawnp(&pid, bin_z.ptr, null, null, c_argv.items.ptr, envp);
    if (rc != 0) {
        log.err("posix_spawnp failed for '{s}': {s}", .{ bin, c.strerror(rc) });
        return false;
    }
    log.debug("spawned pid {d}: {s}", .{ @as(i64, pid), cmdline });
    return true;
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}
