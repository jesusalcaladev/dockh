//! Real-time status polling for the dock:
//!   * media progress  — playerctl (MPRIS): macOS-style bar under the icon
//!   * notification count — makoctl: badge on the app's icon
//!
//! Runs on GLib timers inside the main loop using GSubprocess (GLib spawns
//! with posix_spawn — safe in a multithreaded GTK process, no fork()).
//! Each poll updates the per-class status widgets in widgets.zig without
//! rebuilding the dock, so nothing flickers.
const std = @import("std");
const c = @import("../c.zig");
const state = @import("../core/state.zig");
const widgets = @import("widgets.zig");
const log = @import("../core/log.zig");

/// Run `argv` and return its stdout (allocated in `alloc`), or null on any
/// failure. stdout/stderr from GSubprocess are g_malloc'd — always g_free'd.
fn runCapture(alloc: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    const launcher = c.g_subprocess_launcher_new(c.G_SPAWN_SEARCH_PATH);
    if (launcher == null) return null;
    defer c.g_object_unref(launcher);

    var args: std.ArrayList(?[*:0]const u8) = .empty;
    defer args.deinit(alloc);
    for (argv) |a| {
        const z = alloc.dupeZ(u8, a) catch return null;
        args.append(alloc, z.ptr) catch return null;
    }
    args.append(alloc, null) catch return null;

    var err: ?*anyopaque = null;
    const sub = c.g_subprocess_launcher_spawnv(launcher, args.items.ptr, &err);
    if (sub == null) {
        if (err) |e| c.g_error_free(e);
        return null;
    }
    defer c.g_object_unref(sub);

    var out: ?[*:0]const u8 = null;
    var err_out: ?[*:0]const u8 = null;
    var exit_status: c_int = 0;
    const ok = c.g_subprocess_communicate_utf8(sub, null, null, &out, &err_out, &exit_status);
    const freeStr = struct {
        fn f(p: ?[*:0]const u8) void {
            if (p) |s| c.g_free(@ptrCast(@constCast(s)));
        }
    }.f;
    if (ok == 0 or out == null) {
        freeStr(out);
        freeStr(err_out);
        return null;
    }
    defer freeStr(out);
    freeStr(err_out);
    return alloc.dupe(u8, std.mem.span(out.?)) catch null;
}

// ---------------------------------------------------------------------------
// Media progress (playerctl / MPRIS)
// ---------------------------------------------------------------------------

/// Poll the active MPRIS player and push its playback fraction to the dock.
/// Fraction 0 hides the bar. Matched by mpris:desktopEntry (e.g. "firefox"),
/// falling back to the focused app when the player is the focused one.
fn pollProgress() void {
    if (!state.cfg.progress_enabled) return;

    // status|position(s)|length(us)|desktopEntry
    const meta = runCapture(state.scratch, &.{
        "playerctl", "metadata", "--format", "{{status}}|{{position}}|{{mpris:length}}|{{mpris:desktopEntry}}",
    }) orelse {
        widgets.setProgress("", 0); // no player → hide all
        return;
    };
    defer state.scratch.free(meta);

    const line = std.mem.trim(u8, meta, " \t\r\n");
    if (line.len == 0) {
        widgets.setProgress("", 0);
        return;
    }
    var it = std.mem.splitScalar(u8, line, '|');
    const status = it.next() orelse "";
    const pos_str = it.next() orelse "0";
    const len_str = it.next() orelse "0";
    const entry = std.mem.trim(u8, it.next() orelse "", " \t");

    if (!std.mem.eql(u8, status, "Playing")) {
        widgets.setProgress("", 0);
        return;
    }
    const pos = std.fmt.parseFloat(f64, pos_str) catch 0;
    const len_us = std.fmt.parseFloat(f64, len_str) catch 0;
    if (len_us <= 0) {
        widgets.setProgress("", 0);
        return;
    }
    const fraction = @max(0.0, @min(1.0, pos / (len_us / 1_000_000.0)));

    // Show the bar on the app that owns the player (matched by desktopEntry,
    // e.g. "firefox"), falling back to the focused app when the entry doesn't
    // match anything in the dock (e.g. player "chromium" vs class
    // "Google-chrome"). setProgress("", …) with an empty class hides all.
    var target = entry;
    var matched = false;
    const classes = widgets.statusClasses(state.scratch);
    defer state.scratch.free(classes);
    for (classes) |cl| {
        if (appMatchesClass(entry, cl)) {
            matched = true;
            break;
        }
    }
    if (!matched and state.active_class.len > 0) {
        target = state.active_class;
    }
    widgets.setProgress(target, fraction);
}

// ---------------------------------------------------------------------------
// Notifications (makoctl)
// ---------------------------------------------------------------------------

const Notification = struct { app: []const u8 = "" };

/// Parse `makoctl list` into a flat list of app identifiers. Accepts both
/// output formats across mako versions:
///   * modern: JSON  {"notifications": [{"app-name": "firefox", ...}]}
///   * legacy: plain text  "Notification 12: Title\n  App name: firefox"
fn parseMakoList(alloc: std.mem.Allocator, data: []const u8) []Notification {
    var out: std.ArrayList(Notification) = .empty;

    if (std.mem.indexOfScalar(u8, data, '{') == 0) {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch return &.{};
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return &.{};
        const notifs = root.object.get("notifications") orelse return &.{};
        if (notifs != .array) return &.{};
        for (notifs.array.items) |n| {
            if (n != .object) continue;
            var app: []const u8 = "";
            if (n.object.get("app-name")) |v| {
                if (v == .string) app = v.string;
            }
            if (app.len == 0) {
                if (n.object.get("app-icon")) |v| {
                    if (v == .string) app = v.string;
                }
            }
            if (app.len > 0) {
                out.append(alloc, .{ .app = alloc.dupe(u8, app) catch continue }) catch {};
            }
        }
        return out.toOwnedSlice(alloc) catch &.{};
    }

    // Plain text: "Notification <id>: <summary>" then indented key: value
    // lines. Each block contributes exactly one app: the first "App name:"
    // (falling back to "app-icon:"), pushed when the next block starts.
    var pending: ?[]const u8 = null; // app of the notification block being read
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "Notification ")) {
            if (pending) |app| {
                if (app.len > 0) {
                    out.append(alloc, .{ .app = alloc.dupe(u8, app) catch continue }) catch {};
                }
            }
            pending = null; // start a fresh block
        } else if (pending == null and std.mem.startsWith(u8, line, "App name: ")) {
            if (std.mem.indexOfScalar(u8, line, ':')) |i| {
                pending = std.mem.trim(u8, line[i + 1 ..], " \t");
            }
        } else if (pending == null and std.mem.startsWith(u8, line, "app-icon: ")) {
            if (std.mem.indexOfScalar(u8, line, ':')) |i| {
                pending = std.mem.trim(u8, line[i + 1 ..], " \t");
            }
        }
    }
    // flush the last block
    if (pending) |app| {
        if (app.len > 0) {
            if (alloc.dupe(u8, app)) |dup| {
                out.append(alloc, .{ .app = dup }) catch {};
            } else |_| {}
        }
    }
    return out.toOwnedSlice(alloc) catch &.{};
}

/// Does a mako app string match a dock class? Case-insensitive, plus:
///   * dotted-suffix form, on EITHER side: mako "org.mozilla.firefox" matches
///     class "firefox", and a pinned desktop id "com.obsidian.Obsidian"
///     matches mako "obsidian" — the LAST dot is the segment boundary, so
///     "com.obsidian.Obsidian" -> "Obsidian" (not "obsidian.Obsidian").
///   * prefix form (mako "brave" matches class "brave-browser") — min 3
///     chars so short app names like "x" can't match "xterm".
fn appMatchesClass(app: []const u8, class: []const u8) bool {
    if (app.len < 3) return false;
    if (std.ascii.eqlIgnoreCase(app, class)) return true;
    if (std.ascii.startsWithIgnoreCase(class, app)) return true;
    if (std.mem.lastIndexOfScalar(u8, app, '.')) |i| {
        if (std.ascii.eqlIgnoreCase(app[i + 1 ..], class)) return true;
    }
    if (std.mem.lastIndexOfScalar(u8, class, '.')) |i| {
        if (std.ascii.eqlIgnoreCase(class[i + 1 ..], app)) return true;
    }
    return false;
}

/// Poll makoctl list, count notifications per app and push the badge counts.
fn pollBadges() void {
    if (!state.cfg.badge_enabled) return;
    const data = runCapture(state.scratch, &.{ "makoctl", "list" }) orelse return;
    defer state.scratch.free(data);

    const notifs = parseMakoList(state.scratch, data);
    defer state.scratch.free(notifs);

    // classes currently shown in the dock
    const classes = widgets.statusClasses(state.scratch);
    defer state.scratch.free(classes);

    for (classes) |class| {
        var count: usize = 0;
        for (notifs) |n| {
            if (appMatchesClass(n.app, class)) count += 1;
        }
        widgets.setBadge(class, count);
    }
}

// ---------------------------------------------------------------------------
// Timers
// ---------------------------------------------------------------------------

fn onProgressTimer(_: ?*anyopaque) callconv(.c) c_int {
    pollProgress();
    return 1; // keep the timer
}

fn onBadgeTimer(_: ?*anyopaque) callconv(.c) c_int {
    pollBadges();
    return 1;
}

/// Start the polling timers. Call after the main loop is set up.
pub fn setup() void {
    if (state.cfg.progress_enabled) {
        _ = c.g_timeout_add(1000, @ptrCast(&onProgressTimer), null);
        log.debug("status: media progress polling on (playerctl, 1s)", .{});
    }
    if (state.cfg.badge_enabled) {
        _ = c.g_timeout_add(2000, @ptrCast(&onBadgeTimer), null);
        log.debug("status: notification polling on (makoctl, 2s)", .{});
    }
}
