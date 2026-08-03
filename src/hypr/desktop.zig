//! Freedesktop integration: discover .desktop files across the XDG
//! application dirs (including Flatpak), resolve the icon / name / exec of a
//! window class, and launch applications with posix_spawnp (no fork() in a
//! multithreaded GTK process — safe).
const std = @import("std");
const c = @import("c"); // named module (build.zig)
const fs = @import("fs"); // named module (build.zig)
const log = @import("../core/log.zig");
const state = @import("../core/state.zig");

pub const DesktopEntry = struct {
    name: []const u8 = "",
    icon: []const u8 = "",
    exec: []const u8 = "",
};

var app_dirs: []const []const u8 = &.{};

// Resolved .desktop entries, cached in the PERMANENT arena keyed by class.
// Without this, every dock rebuild would re-list every application dir and
// re-parse .desktop files for every item — the single biggest source of
// unbounded memory growth (and needless disk I/O) in the hot path.
// Lazily initialized with the permanent allocator on first use (getEntry is
// only ever called after main() has set state.alloc).
//
// Each entry also remembers the .desktop path it came from and that file's
// mtime, so the cache can be invalidated by modification time: `pacman -S`
// (or any hot install/upgrade) rewrites the .desktop with a fresh mtime, and
// the next lookup re-resolves it — no dock restart needed. Negative entries
// (class not found anywhere) carry an empty path and are re-searched on a
// short TTL so a newly installed app is picked up too.
const CachedEntry = struct {
    entry: DesktopEntry = .{},
    path: []const u8 = "", // resolved .desktop path ("" = negative entry)
    mtime_sec: i64 = 0, // st_mtim of the .desktop at cache time
    mtime_nsec: i64 = 0,
    stale_at_ms: i64 = 0, // monotonic ms when this entry must be re-checked
};

const CACHE_REVALIDATE_MS: i64 = 1000; // positive entries: re-stat the file at most 1/s
const NEGATIVE_TTL_MS: i64 = 5000; // not-found entries: re-search after 5 s

const Mtime = struct { sec: i64, nsec: i64 };

var entry_cache: std.StringHashMap(CachedEntry) = undefined;
var entry_cache_ready = false;

fn ensureCache() void {
    if (!entry_cache_ready) {
        entry_cache = std.StringHashMap(CachedEntry).init(state.alloc);
        entry_cache_ready = true;
    }
}

fn monoMs() i64 {
    var ts: c.Timespec = .{};
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// stat a .desktop path and return its mtime as (sec, nsec), or null when the
/// file is gone or stat fails (treat as "changed" so the entry re-resolves).
/// The path is copied into a STACK buffer: state.alloc is an arena whose free
/// is a no-op, so a dupeZ there would leak one path-length allocation per
/// re-stat (1/s per entry, forever) — the exact slow RSS creep the memory
/// watchdog exists to fight. .desktop paths are far below 1024 bytes.
fn fileMtime(path: []const u8) ?Mtime {
    var zbuf: [1024:0]u8 = undefined;
    if (path.len >= zbuf.len) return null;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    var st: c.Stat = undefined;
    if (c.stat(zbuf[0..path.len :0].ptr, &st) != 0) return null;
    return .{ .sec = st.st_mtim.sec, .nsec = st.st_mtim.nsec };
}

/// Re-resolve `class` from disk (findDesktopFile + parseDesktopFile) and
/// cache the fresh result in the permanent arena. Returns the entry.
fn resolveAndCache(alloc: std.mem.Allocator, class: []const u8) DesktopEntry {
    var entry: DesktopEntry = .{};
    var path: []const u8 = "";
    if (findDesktopFile(alloc, class)) |p| {
        const parsed = parseDesktopFile(alloc, p) catch null;
        if (parsed) |pe| {
            path = p;
            entry = pe;
        }
        // Parse failure: cache as a NEGATIVE entry (path stays "") so the
        // 5s TTL re-searches instead of re-reading the broken .desktop on
        // every single rebuild.
    }
    // An explicit icon path beats everything.
    if (std.mem.startsWith(u8, class, "/")) {
        entry.icon = class;
    }

    var mtime: ?Mtime = null;
    if (path.len > 0) mtime = fileMtime(path);

    // Persist in the permanent arena: key + strings must outlive rebuilds.
    const key = state.alloc.dupe(u8, class) catch return entry;
    const cached = CachedEntry{
        .entry = .{
            .name = if (entry.name.len > 0) state.alloc.dupe(u8, entry.name) catch "" else "",
            .icon = if (entry.icon.len > 0) state.alloc.dupe(u8, entry.icon) catch "" else "",
            .exec = if (entry.exec.len > 0) state.alloc.dupe(u8, entry.exec) catch "" else "",
        },
        .path = if (path.len > 0) state.alloc.dupe(u8, path) catch "" else "",
        .mtime_sec = if (mtime) |m| m.sec else 0,
        .mtime_nsec = if (mtime) |m| m.nsec else 0,
        .stale_at_ms = monoMs(), // TTL counts from NOW, not from process start
    };
    entry_cache.put(key, cached) catch {};
    return cached.entry;
}

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
    if (class.len == 0) return .{};

    // Cached (case-insensitive on the class). The cached strings live in the
    // permanent arena, so they survive every ui_arena reset.
    ensureCache();
    const now_ms = monoMs();

    var cached_key: []const u8 = "";
    if (entry_cache.get(class)) |_| {
        cached_key = class;
    } else {
        var it = entry_cache.keyIterator();
        while (it.next()) |k| {
            if (std.ascii.eqlIgnoreCase(k.*, class)) {
                cached_key = k.*;
                break;
            }
        }
    }

    if (cached_key.len > 0) {
        const ce_ptr = entry_cache.getPtr(cached_key) orelse return resolveAndCache(alloc, class);
        const ce = ce_ptr.*;
        // mtime-based invalidation:
        //  - positive entry: if enough time passed, re-stat the .desktop; when
        //    its mtime changed (or the file vanished — app removed/upgraded)
        //    the entry is stale and must be re-resolved. While it's unchanged
        //    we refresh stale_at_ms so the re-stat stays throttled to ~1/s.
        //  - negative entry: re-search after the TTL so a hot `pacman -S`
        //    install appears without restarting the dock.
        var stale = false;
        if (ce.path.len > 0) {
            if (now_ms - ce.stale_at_ms >= CACHE_REVALIDATE_MS) {
                const mt = fileMtime(ce.path);
                stale = (mt == null) or
                    mt.?.sec != ce.mtime_sec or
                    mt.?.nsec != ce.mtime_nsec;
                ce_ptr.stale_at_ms = now_ms; // throttle the next re-stat
            }
        } else {
            if (now_ms - ce.stale_at_ms >= NEGATIVE_TTL_MS) stale = true;
        }
        if (!stale) return ce.entry;
        // stale: drop and re-resolve from disk (also covers a negative entry
        // that now resolves — put() overwrites the old value).
        if (log.debug_enabled) log.debug("desktop: re-resolving {s} (cache stale)", .{class});
        _ = entry_cache.remove(cached_key);
        return resolveAndCache(alloc, class);
    }

    return resolveAndCache(alloc, class);
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
