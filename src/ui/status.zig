//! Real-time status polling for the dock:
//!   * media progress  — playerctl (MPRIS): macOS-style bar under the icon
//!   * notification count — makoctl: badge on the app's icon
//!
//! Runs on GLib timers inside the main loop using GSubprocess (GLib spawns
//! with posix_spawn — safe in a multithreaded GTK process, no fork()).
//! Each poll updates the per-class status widgets in widgets.zig without
//! rebuilding the dock, so nothing flickers.
const std = @import("std");
const c = @import("c"); // named module (build.zig)
const state = @import("../core/state.zig");
const widgets = @import("widgets.zig");
const island = @import("island.zig");
const log = @import("../core/log.zig");

/// Run `argv` and return its stdout (allocated in `alloc`), or null on any
/// failure. stdout/stderr from GSubprocess are g_malloc'd — always g_free'd.
fn runCapture(alloc: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    // STDOUT_PIPE lets communicate_utf8 capture the child's stdout; STDERR_SILENCE
    // stops playerctl's "No player could handle this command" from spamming the
    // dock's log on every 1s poll when no music is playing.
    const launcher = c.g_subprocess_launcher_new(c.G_SUBPROCESS_FLAGS_STDOUT_PIPE | c.G_SUBPROCESS_FLAGS_STDERR_SILENCE);
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
    // glib 2.88 changed communicate_utf8's last out-param from `int *exit_status`
    // to `GError **error` — we must pass a real GError** or glib writes an
    // 8-byte pointer into 4 bytes of stack (corrupting locals; surfaced as
    // g_object_unref assertions during the 2s badge polls). The exit status
    // isn't needed here: a failed spawn already returned null above.
    var comm_err: ?*anyopaque = null;
    const ok = c.g_subprocess_communicate_utf8(sub, null, null, &out, &err_out, &comm_err);
    if (comm_err) |e| c.g_error_free(e);
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
    if (!state.cfg.progress_enabled and !state.cfg.island_enabled) return;

    // status|position(s)|length(us)|desktopEntry|title|artist|artUrl
    const meta = runCapture(state.scratch, &.{
        "playerctl", "metadata", "--format", "{{status}}|{{position}}|{{mpris:length}}|{{mpris:desktopEntry}}|{{xesam:title}}|{{xesam:artist}}|{{mpris:artUrl}}",
    }) orelse {
        widgets.setProgress("", 0);
        island.updateMusic("", "", "", "");
        return;
    };
    defer state.scratch.free(meta);

    const line = std.mem.trim(u8, meta, " \t\r\n");
    if (line.len == 0) {
        widgets.setProgress("", 0);
        island.updateMusic("", "", "", "");
        return;
    }
    var it = std.mem.splitScalar(u8, line, '|');
    const status = it.next() orelse "";
    const pos_str = it.next() orelse "0";
    const len_str = it.next() orelse "0";
    const entry = std.mem.trim(u8, it.next() orelse "", " \t");
    const title = std.mem.trim(u8, it.next() orelse "", " \t");
    const artist = std.mem.trim(u8, it.next() orelse "", " \t");
    const art_url = std.mem.trim(u8, it.next() orelse "", " \t");

    // Update the Dynamic Island with music metadata (album art included)
    island.updateMusic(title, artist, status, art_url);

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

    // Update island progress bar
    island.updateMusicProgress(fraction);

    // Show the bar on the app that owns the player
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

const Notification = struct {
    app: []const u8 = "", // app-name (used for badge matching + island icon fallback)
    icon: []const u8 = "", // app-icon (the actual icon id, preferred for the island)
    id: u32 = 0,
    summary: []const u8 = "",
    body: []const u8 = "",
};

/// Get a string field from a notification object, accepting BOTH the
/// hyphenated keys newer mako emits ("app-name") and the underscored keys
/// mako 1.11 emits ("app_name").
fn jsonField(obj: std.json.ObjectMap, hyph: []const u8, under: []const u8) []const u8 {
    if (obj.get(hyph)) |v| {
        if (v == .string) return v.string;
    }
    if (obj.get(under)) |v| {
        if (v == .string) return v.string;
    }
    return "";
}

/// Parse `makoctl list` into a flat list of app identifiers. Accepts both
/// output formats across mako versions:
///   * JSON (preferred — `makoctl list -j`): either a BARE ARRAY of
///     notification objects (mako 1.11) or an object wrapping a
///     "notifications" array (newer mako); keys may be "app-name" OR
///     "app_name". Carries ids, so the island can detect NEW notifications.
///   * legacy plain text  "Notification 12: Title\n  App name: firefox" —
///     no ids (island pop-out unavailable), badges only.
fn parseMakoList(alloc: std.mem.Allocator, data: []const u8) []Notification {
    var out: std.ArrayList(Notification) = .empty;

    if (std.mem.indexOfScalar(u8, data, '[') == 0 or std.mem.indexOfScalar(u8, data, '{') == 0) {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch return &.{};
        defer parsed.deinit();
        const root = parsed.value;
        // Normalize to an array of notification objects (bare array OR
        // object with a "notifications" array key).
        var arr: []std.json.Value = undefined;
        if (root == .array) {
            arr = root.array.items;
        } else if (root == .object) {
            const notifs = root.object.get("notifications") orelse return &.{};
            if (notifs != .array) return &.{};
            arr = notifs.array.items;
        } else {
            return &.{};
        }
        for (arr) |n| {
            if (n != .object) continue;
            var app = jsonField(n.object, "app-name", "app_name");
            const icon = jsonField(n.object, "app-icon", "app_icon");
            var id: u32 = 0;
            var summary: []const u8 = "";
            var body: []const u8 = "";
            if (app.len == 0) app = icon; // last-resort app fallback
            if (n.object.get("id")) |v| {
                if (v == .integer and v.integer > 0) id = @intCast(v.integer);
            }
            if (n.object.get("summary")) |v| {
                if (v == .string) summary = v.string;
            }
            if (n.object.get("body")) |v| {
                if (v == .string) body = v.string;
            }
            if (app.len > 0 or id != 0) {
                out.append(alloc, .{
                    .app = alloc.dupe(u8, app) catch continue,
                    .icon = alloc.dupe(u8, icon) catch "",
                    .id = id,
                    .summary = alloc.dupe(u8, summary) catch "",
                    .body = alloc.dupe(u8, body) catch "",
                }) catch {};
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

/// Seen mako notification ids: a small ring so NEW notifications (ids we've
/// never seen before) pop out of the Dynamic Island exactly once, and the
/// badge poll doesn't re-fire old ones after a dockh restart or mako restart.
var seen_notif_ids: [64]u32 = [_]u32{0} ** 64;
var seen_notif_count: usize = 0;

fn isNewNotifId(id: u32) bool {
    if (id == 0) return false;
    for (seen_notif_ids[0..seen_notif_count]) |seen| {
        if (seen == id) return false;
    }
    if (seen_notif_count < seen_notif_ids.len) {
        seen_notif_ids[seen_notif_count] = id;
        seen_notif_count += 1;
    } else {
        // ring full: shift and drop the oldest
        for (1..seen_notif_ids.len) |i| seen_notif_ids[i - 1] = seen_notif_ids[i];
        seen_notif_ids[seen_notif_ids.len - 1] = id;
    }
    return true;
}

/// Poll makoctl list: count notifications per app for the dock badges AND
/// detect brand-new notifications (by id) to pop out of the Dynamic Island.
fn pollBadges() void {
    if (!state.cfg.badge_enabled and !state.cfg.island_enabled) return;
    // Prefer JSON (`makoctl list -j`) — it carries ids so the island can
    // detect NEW notifications. Older makoctl rejects the flag, so fall back
    // to the plain-text format (badges still work; island pop-out is then
    // unavailable because text output has no ids).
    const data = (runCapture(state.scratch, &.{ "makoctl", "list", "-j" }) orelse
        runCapture(state.scratch, &.{ "makoctl", "list" })) orelse return;
    defer state.scratch.free(data);

    const notifs = parseMakoList(state.scratch, data);
    defer state.scratch.free(notifs);

    // NEW notification -> Dynamic Island pop-out (most recent one wins).
    // Only meaningful from the JSON branch, which carries ids.
    if (state.cfg.island_enabled) {
        var new_id: u32 = 0;
        var newest_idx: ?usize = null;
        for (notifs, 0..) |n, i| {
            if (n.id != 0 and isNewNotifId(n.id)) {
                if (newest_idx == null or n.id > new_id) {
                    new_id = n.id;
                    newest_idx = i;
                }
            }
        }
        if (newest_idx) |idx| {
            const n = notifs[idx];
            const title = if (n.summary.len > 0) n.summary else n.app;
            // Pass the real icon id (app-icon) so the island shows the app's
            // icon instead of trying to resolve the desktop-entry name.
            const icon_name = if (n.icon.len > 0) n.icon else n.app;
            island.showNotification(n.app, icon_name, title, n.body);
        }
    }

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
// Volume / brightness OSD (wpctl / brightnessctl)
// ---------------------------------------------------------------------------
// Poll the current volume and brightness; when a value CHANGES, pop the OSD
// slider out of the Dynamic Island (macOS-style). The polls are cheap and run
// on the 1s progress timer only when the island is enabled.

var last_volume: f64 = -1;
var last_volume_muted = false;
var last_brightness: f64 = -1;

/// `wpctl get-volume @DEFAULT_AUDIO_SINK@` → "Volume: 0.45" / "…[MUTED]"
fn pollVolume() void {
    if (!state.cfg.island_enabled) return;
    const out = runCapture(state.scratch, &.{ "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@" }) orelse return;
    defer state.scratch.free(out);
    const line = std.mem.trim(u8, out, " \t\r\n");
    if (line.len == 0) return;
    const colon = std.mem.lastIndexOfScalar(u8, line, ':') orelse return;
    var val = std.mem.trim(u8, line[colon + 1 ..], " \t");
    const muted = std.mem.indexOf(u8, val, "[MUTED]") != null;
    if (muted) {
        val = std.mem.trim(u8, val[0 .. val.len - "[MUTED]".len], " \t");
    }
    const vol = std.fmt.parseFloat(f64, val) catch return;
    // First sample: seed the baseline WITHOUT popping the OSD — otherwise the
    // island flashes "Volume" on every dockh start with no user input.
    if (last_volume < 0) {
        last_volume = vol;
        last_volume_muted = muted;
        return;
    }
    if (vol == last_volume and muted == last_volume_muted) return; // unchanged
    last_volume = vol;
    last_volume_muted = muted;

    const icon = if (muted or vol <= 0.001)
        "audio-volume-muted-symbolic"
    else if (vol < 0.5)
        "audio-volume-low-symbolic"
    else
        "audio-volume-high-symbolic";
    island.showOsd(icon, if (muted) "Muted" else "Volume", vol);
}

/// `brightnessctl -m get` → "DEVICE,CLASS,PERCENT,VALUE,MAX" — take PERCENT.
fn pollBrightness() void {
    if (!state.cfg.island_enabled) return;
    const out = runCapture(state.scratch, &.{ "brightnessctl", "-m", "get" }) orelse return;
    defer state.scratch.free(out);
    const line = std.mem.trim(u8, out, " \t\r\n");
    if (line.len == 0) return;
    var it = std.mem.splitScalar(u8, line, ',');
    _ = it.next(); // device
    _ = it.next(); // class
    const pct_str = std.mem.trim(u8, it.next() orelse return, " \t");
    const pct = std.fmt.parseFloat(f64, pct_str) catch return;
    // First sample: baseline only, no startup pop (see pollVolume).
    if (last_brightness < 0) {
        last_brightness = pct;
        return;
    }
    if (pct == last_brightness) return; // unchanged
    last_brightness = pct;
    island.showOsd("display-brightness-symbolic", "Brightness", pct / 100.0);
}

// ---------------------------------------------------------------------------
// Battery (idle pill + low-battery warning)
// ---------------------------------------------------------------------------
// Reads /sys/class/power_supply/BAT*/capacity + status directly (no tools),
// on a slow 30s timer. Pushes the charge state to the island, which shows the
// percentage next to the clock and warns once below 20%.

fn batteryCapacity() ?i32 {
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        var path: [80:0]u8 = undefined;
        const p = std.fmt.bufPrint(&path, "/sys/class/power_supply/BAT{d}/capacity", .{i}) catch break;
        path[p.len] = 0;
        var buf: [32]u8 = undefined;
        const n = readFileBuf(path[0..p.len :0].ptr, &buf);
        if (n == 0) continue;
        const val = std.fmt.parseInt(i32, std.mem.trim(u8, buf[0..n], " \t\r\n"), 10) catch continue;
        return @max(0, @min(100, val));
    }
    return null;
}

fn batteryCharging() bool {
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        var path: [80:0]u8 = undefined;
        const p = std.fmt.bufPrint(&path, "/sys/class/power_supply/BAT{d}/status", .{i}) catch break;
        path[p.len] = 0;
        var buf: [32]u8 = undefined;
        const n = readFileBuf(path[0..p.len :0].ptr, &buf);
        if (n == 0) continue;
        const st = std.mem.trim(u8, buf[0..n], " \t\r\n");
        return std.mem.eql(u8, st, "Charging") or std.mem.eql(u8, st, "Full");
    }
    return false;
}

fn pollBattery() void {
    if (!state.cfg.island_enabled) return;
    const pct = batteryCapacity();
    // Skip the status file read entirely when no battery is present.
    const charging = if (pct != null) batteryCharging() else false;
    island.setBattery(pct orelse 0, charging, pct != null);
}

fn onBatteryTimer(_: ?*anyopaque) callconv(.c) c_int {
    pollBattery();
    return 1; // keep the timer
}

// ---------------------------------------------------------------------------
// System monitor (RAM / CPU / temperature)
// ---------------------------------------------------------------------------
// The optional in-dock system item (widgets.zig makeSystemItem) is fed by
// this poll, which runs on the SAME status timers as progress/badges. Unlike
// those it spawns nothing: RAM comes from /proc/meminfo, CPU from the
// /proc/stat first line (delta between two samples), temperature from the
// first readable /sys/class/thermal/thermal_zone*/temp. All reads use stack
// buffers — no per-poll allocation churn.

/// Read a whole small file (like /proc/meminfo) into `buf`; returns the byte
/// count, or 0 on any failure.
fn readFileBuf(path: [*:0]const u8, buf: []u8) usize {
    const fd = c.open(path, c.O_RDONLY);
    if (fd < 0) return 0;
    defer _ = c.close(fd);
    const n = c.read(fd, buf.ptr, buf.len);
    if (n <= 0) return 0;
    return @intCast(n);
}

/// Parse `Key:` lines from a /proc file buffer. Returns the value as i64 or
/// null when the key is missing/unparseable.
fn procKeyValue(data: []const u8, key: []const u8) ?i64 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        if (!std.mem.startsWith(u8, raw, key)) continue;
        const rest = std.mem.trim(u8, raw[key.len..], " \t:");
        var num = std.mem.trim(u8, rest, " \t");
        // /proc/meminfo values end in " kB"
        const space = std.mem.indexOfScalar(u8, num, ' ');
        if (space) |i| num = num[0..i];
        return std.fmt.parseInt(i64, num, 10) catch null;
    }
    return null;
}

/// Used RAM in MiB from /proc/meminfo (MemTotal - MemAvailable).
fn memUsedMiB() ?i64 {
    var buf: [8192]u8 = undefined;
    const n = readFileBuf("/proc/meminfo", &buf);
    if (n == 0) return null;
    const data = buf[0..n];
    const total = procKeyValue(data, "MemTotal:") orelse return null;
    const avail = procKeyValue(data, "MemAvailable:") orelse return null;
    const used_kb = total - avail;
    if (used_kb < 0) return null;
    return @divTrunc(used_kb, 1024); // kB -> MiB
}

// Previous /proc/stat sample — the CPU pct is a delta between two reads.
var cpu_prev_total: i64 = 0;
var cpu_prev_idle: i64 = 0;

/// CPU usage % (0-100) from the /proc/stat "cpu" aggregate line. First call
/// returns null (no baseline); afterwards it's the delta between samples.
fn cpuPct() ?f64 {
    var buf: [4096]u8 = undefined;
    const n = readFileBuf("/proc/stat", &buf);
    if (n == 0) return null;
    const data = buf[0..n];
    // first line: "cpu  user nice system idle iowait irq softirq steal ..."
    var lines = std.mem.splitScalar(u8, data, '\n');
    const line = lines.next() orelse return null;
    if (!std.mem.startsWith(u8, line, "cpu")) return null;
    var fields: [8]i64 = .{0} ** 8;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, line, ' ');
    _ = it.next(); // "cpu"
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (count >= 8) break;
        fields[count] = std.fmt.parseInt(i64, tok, 10) catch return null;
        count += 1;
    }
    if (count < 4) return null;
    // total = user+nice+system+idle+iowait+irq+softirq+steal; idle = idle+iowait
    var total: i64 = 0;
    for (fields) |f| total += f;
    const idle = fields[3] + fields[4];
    if (cpu_prev_total <= 0) {
        cpu_prev_total = total;
        cpu_prev_idle = idle;
        return null;
    }
    const d_total = total - cpu_prev_total;
    const d_idle = idle - cpu_prev_idle;
    cpu_prev_total = total;
    cpu_prev_idle = idle;
    if (d_total <= 0) return 0;
    const busy = d_total - d_idle;
    if (busy < 0) return 0;
    return @as(f64, @floatFromInt(busy)) / @as(f64, @floatFromInt(d_total)) * 100.0;
}

/// CPU package temperature in °C, or null when no thermal zone is readable.
/// Prefers CPU-type zones (x86_pkg_temp, coretemp, cpu-thermal, k10temp, …)
/// — the first acpitz/ambient zone is NOT the CPU — and falls back to the
/// first readable zone that reports a sane value. Reads millidegrees C.
fn cpuTempC() ?i32 {
    var i: usize = 0;
    var fallback: ?i32 = null;
    while (i < 24) : (i += 1) {
        var path: [64]u8 = undefined;
        const p = std.fmt.bufPrint(&path, "/sys/class/thermal/thermal_zone{d}", .{i}) catch break;
        var z: [64:0]u8 = undefined;
        const n = @min(p.len, 63);
        @memcpy(z[0..n], p[0..n]);
        z[n] = 0;
        const base = z[0..n :0];

        // zone type (e.g. "x86_pkg_temp", "acpitz") — empty if unreadable
        var tbuf: [64]u8 = undefined;
        var tpath: [96:0]u8 = undefined;
        const tp = std.fmt.bufPrint(&tpath, "{s}/type", .{base}) catch break;
        tpath[tp.len] = 0;
        const tn = readFileBuf(tpath[0..tp.len :0].ptr, &tbuf);
        const ttype = if (tn > 0) std.mem.trim(u8, tbuf[0..tn], " \t\r\n") else "";
        const is_cpu = ttype.len > 0 and
            (std.mem.indexOf(u8, ttype, "cpu") != null or
                std.mem.indexOf(u8, ttype, "pkg") != null or
                std.mem.indexOf(u8, ttype, "core") != null or
                std.mem.indexOf(u8, ttype, "k10") != null);

        var vpath: [96:0]u8 = undefined;
        const vp = std.fmt.bufPrint(&vpath, "{s}/temp", .{base}) catch break;
        vpath[vp.len] = 0;
        var buf: [64]u8 = undefined;
        const rn = readFileBuf(vpath[0..vp.len :0].ptr, &buf);
        if (rn == 0) continue;
        const val = std.fmt.parseInt(i64, std.mem.trim(u8, buf[0..rn], " \t\r\n"), 10) catch continue;
        // millidegrees C -> °C; ignore obviously bogus values
        if (val <= 0 or val > 150_000) continue;
        const deg: i32 = @intCast(@divTrunc(val, 1000));
        if (is_cpu) return deg; // preferred zone found
        if (fallback == null) fallback = deg;
    }
    return fallback;
}

/// Append a formatted segment to `buf` at `*pos`; returns false when it
/// doesn't fit (the 96-byte buffer is far more than the worst case).
fn appendSeg(buf: []u8, pos: *usize, comptime fmt: []const u8, args: anytype) bool {
    const out = std.fmt.bufPrint(buf[pos.*..], fmt, args) catch return false;
    pos.* += out.len;
    return true;
}

/// Build the "RAM 4.2G · CPU 23% · 52°C" string and push it to the label.
/// (Zig 0.16 has no std.io stream writers — a cursor into a stack buffer is
/// all this needs.)
fn pollSystem() void {
    if (!widgets.systemEnabled()) return;

    var buf: [96]u8 = undefined;
    var pos: usize = 0;
    var any = false;

    if (state.cfg.system_ram) {
        if (memUsedMiB()) |mib| {
            // >= 1 GiB -> GiB with one decimal, else MiB
            if (mib >= 1024) {
                if (!appendSeg(&buf, &pos, "RAM {d:.1}G", .{@as(f64, @floatFromInt(mib)) / 1024.0})) return;
            } else {
                if (!appendSeg(&buf, &pos, "RAM {d}M", .{mib})) return;
            }
            any = true;
        }
    }
    if (state.cfg.system_cpu) {
        if (cpuPct()) |pct| {
            if (any) {
                if (!appendSeg(&buf, &pos, "  ·  ", .{})) return;
            }
            if (!appendSeg(&buf, &pos, "CPU {d:.0}%", .{pct})) return;
            any = true;
        }
    }
    if (state.cfg.system_temp) {
        if (cpuTempC()) |deg| {
            if (any) {
                if (!appendSeg(&buf, &pos, "  ·  ", .{})) return;
            }
            if (!appendSeg(&buf, &pos, "{d}°C", .{deg})) return;
            any = true;
        }
    }

    if (any and pos > 0 and pos < buf.len) {
        buf[pos] = 0;
        widgets.setSystemText(buf[0..pos :0]);
        widgets.setSystemVisible(true);
    } else {
        // No segment produced data (all /proc reads failed) — don't leave an
        // empty pill with padding in the dock.
        widgets.setSystemVisible(false);
    }
}

// ---------------------------------------------------------------------------
// Timers
// ---------------------------------------------------------------------------

fn onProgressTimer(_: ?*anyopaque) callconv(.c) c_int {
    pollProgress();
    // OSD sliders ride the same 1s tick (each early-returns when its value
    // is unchanged, so they're idle-cheap).
    pollVolume();
    pollBrightness();
    return 1; // keep the timer
}

fn onBadgeTimer(_: ?*anyopaque) callconv(.c) c_int {
    pollBadges();
    return 1;
}

fn onSystemTimer(_: ?*anyopaque) callconv(.c) c_int {
    pollSystem();
    return 1; // keep the timer
}

/// Start the polling timers. Call after the main loop is set up.
///
/// The timers are ALWAYS armed (each poll early-returns when its option is
/// off) so a live config.toml hot-reload can toggle progress/badge/system on
/// without re-arming anything — the running polls simply pick up the new
/// state.cfg on their next tick.
pub fn setup() void {
    _ = c.g_timeout_add(1000, @ptrCast(&onProgressTimer), null);
    _ = c.g_timeout_add(2000, @ptrCast(&onBadgeTimer), null);
    const ms: c_uint = @intCast(@max(state.cfg.system_interval_ms, 500));
    _ = c.g_timeout_add(ms, @ptrCast(&onSystemTimer), null);
    // Battery is slow-moving: a 30s tick plus an immediate first read so the
    // idle pill shows the percentage from the start.
    _ = c.g_timeout_add(30_000, @ptrCast(&onBatteryTimer), null);
    pollBattery();
    if (state.cfg.progress_enabled) {
        log.debug("status: media progress polling on (playerctl, 1s)", .{});
    }
    if (state.cfg.badge_enabled) {
        log.debug("status: notification polling on (makoctl, 2s)", .{});
    }
    if (widgets.systemEnabled()) {
        // Pre-arm the CPU baseline so the % shows on the very first tick
        // instead of being blank for one interval (cpuPct returns null on its
        // first call by design — it has nothing to diff against yet).
        _ = cpuPct();
        log.debug("status: system monitor polling on ({d}ms)", .{ms});
    }
}
