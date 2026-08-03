//! dockh — a GTK4 layer-shell dock for Hyprland, written in Zig.
//! Rewrite of nwg-dock-hyprland (Go/GTK3) with the modern stack:
//!   * GTK4 + GSK (hardware rendering, CSS transforms/transitions)
//!   * gtk4-layer-shell (wlr-layer-shell via GTK4)
//!   * Hyprland IPC through UNIX sockets, event-driven via the GLib main loop
//!     (no polling)
//!   * Hand-written C-ABI declarations (src/c.zig) — no GC, no bindings layer.
//!
//! Module layout:
//!   core/  — config, state, log, fs (libc file I/O)
//!   hypr/  — Hyprland IPC (ipc.zig) and freedesktop .desktop entries (desktop.zig)
//!   ui/    — dock widgets (widgets.zig) and theming (theme.zig)
const std = @import("std");
const c = @import("c.zig");
const config_mod = @import("core/config.zig");
const hypr = @import("hypr/ipc.zig");
const desktop = @import("hypr/desktop.zig");
const widgets = @import("ui/widgets.zig");
const blur = @import("ui/blur.zig");
const status_mod = @import("ui/status.zig");
const cssmod = @import("ui/theme.zig");
const fs = @import("core/fs.zig");
const log = @import("core/log.zig");
const state = @import("core/state.zig");

const version = "0.1.0";

const default_css = @embedFile("defaults/style.css");
const default_toml = @embedFile("defaults/config.toml");

var perm_arena: std.heap.ArenaAllocator = undefined;
var scratch_arena: std.heap.ArenaAllocator = undefined;

var sig_pipe: [2]c_int = .{ -1, -1 };
var event_fd: c_int = -1;
var event_source: c_uint = 0;
var event_buf: [65536]u8 = undefined;
var event_buf_len: usize = 0;

var allow_multiple = false;
var cfg_file_override: []const u8 = "";

var main_loop: ?*anyopaque = null;

// ---------------------------------------------------------------------------
// Paths & env helpers
// ---------------------------------------------------------------------------

fn homeDir() []const u8 {
    return desktop.getEnv(state.alloc, "HOME") orelse "/";
}

pub fn configDir() []const u8 {
    if (desktop.getEnv(state.alloc, "XDG_CONFIG_HOME")) |d| {
        return std.fmt.allocPrint(state.alloc, "{s}/dockh", .{d}) catch "/tmp/dockh-config";
    }
    return std.fmt.allocPrint(state.alloc, "{s}/.config/dockh", .{homeDir()}) catch "/tmp/dockh-config";
}

fn cacheDir() []const u8 {
    if (desktop.getEnv(state.alloc, "XDG_CACHE_HOME")) |d| {
        return std.fmt.allocPrint(state.alloc, "{s}/dockh", .{d}) catch "/tmp/dockh-cache";
    }
    return std.fmt.allocPrint(state.alloc, "{s}/.cache/dockh", .{homeDir()}) catch "/tmp/dockh-cache";
}

pub fn pinnedFilePath() []const u8 {
    return std.fmt.allocPrint(state.alloc, "{s}/pinned", .{cacheDir()}) catch "/tmp/dockh-pinned";
}

fn cssFilePath() []const u8 {
    return std.fmt.allocPrint(state.alloc, "{s}/{s}", .{ configDir(), state.cfg.css_file }) catch "";
}

fn cfgPath() []const u8 {
    if (cfg_file_override.len > 0) return cfg_file_override;
    return std.fmt.allocPrint(state.alloc, "{s}/config.toml", .{configDir()}) catch "";
}

// ---------------------------------------------------------------------------
// CLI parsing (same flags as nwg-dock-hyprland, plus -cfg)
// ---------------------------------------------------------------------------

fn printUsage() void {
    std.debug.print(
        \\dockh {s} — GTK4 layer-shell dock for Hyprland (written in Zig)
        \\
        \\Usage: dockh [options]
        \\  -a <start|center|end>    alignment in full width/height (default center)
        \\  -d                       auto-hide: show on hotspot hover, hide on leave
        \\  -ha                      intellihide: hide while the active workspace has windows
        \\  -r                       resident mode (no hotspot)
        \\  -p <bottom|top|left|right>  dock position (default bottom)
        \\  -f                       take full screen width/height
        \\  -l <overlay|top|bottom>  layer (default bottom — behind windows)
        \\  -x                       exclusive zone (reserve space), forces top layer
        \\  -i <px>                  icon size (default 32)
        \\  -o <output>              target output name, e.g. DP-1
        \\  -c <cmd>                 launcher command (default nwg-drawer)
        \\  -ico <icon>              launcher icon name or path
        \\  -nolauncher              don't show the launcher button
        \\  -lp <start|end>          launcher button position
        \\  -s <file>                CSS file name in the config dir (default style.css)
        \\  -hd <ms>                 hotspot delay in ms (default 20)
        \\  -hl <overlay|top>        hotspot layer
        \\  -mb/-ml/-mr/-mt <px>     margins
        \\  -w <n>                   number of workspaces (default 10)
        \\  -g <classes>             space-separated classes to ignore
        \\  -iw <list>               ignore running apps on these workspaces, e.g. special,10
        \\  -cfg <path>              config file (default $XDG_CONFIG_HOME/dockh/config.toml)
        \\  -m                       allow multiple instances (skip the lock check)
        \\  -debug                   verbose logging
        \\  -v                       print version and exit
        \\  -h                       this help
        \\
        \\Signals: SIGRTMIN+1 toggle, SIGRTMIN+2 show, SIGRTMIN+3 hide.
        \\
    , .{version});
}

fn splitArgs(alloc: std.mem.Allocator, v: []const u8, sep: u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, v, sep);
    while (it.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t");
        if (t.len == 0) continue;
        out.append(alloc, alloc.dupe(u8, t) catch continue) catch continue;
    }
    return out.toOwnedSlice(alloc) catch &.{};
}

fn parseArgs(args: []const [:0]const u8) void {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--version")) {
            std.debug.print("dockh {s}\n", .{version});
            std.process.exit(0);
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, a, "-d")) {
            state.cfg.autohide = true;
        } else if (std.mem.eql(u8, a, "-ha")) {
            state.cfg.hide_on_activity = true;
        } else if (std.mem.eql(u8, a, "-r")) {
            state.cfg.resident = true;
        } else if (std.mem.eql(u8, a, "-f")) {
            state.cfg.full = true;
        } else if (std.mem.eql(u8, a, "-x")) {
            state.cfg.exclusive = true;
        } else if (std.mem.eql(u8, a, "-nolauncher")) {
            state.cfg.no_launcher = true;
        } else if (std.mem.eql(u8, a, "-m")) {
            allow_multiple = true;
        } else if (std.mem.eql(u8, a, "-debug")) {
            log.debug_enabled = true;
        } else if (std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "-p") or std.mem.eql(u8, a, "-l") or
            std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "-ico") or
            std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "-hl") or std.mem.eql(u8, a, "-lp") or
            std.mem.eql(u8, a, "-cfg") or std.mem.eql(u8, a, "-g") or std.mem.eql(u8, a, "-iw"))
        {
            if (i + 1 >= args.len) {
                log.err("missing value for {s}", .{a});
                std.process.exit(1);
            }
            i += 1;
            const v = args[i];
            if (std.mem.eql(u8, a, "-a")) {
                state.cfg.alignment = state.alloc.dupe(u8, v) catch "";
            } else if (std.mem.eql(u8, a, "-p")) {
                state.cfg.position = state.alloc.dupe(u8, v) catch "";
            } else if (std.mem.eql(u8, a, "-l")) {
                state.cfg.layer = state.alloc.dupe(u8, v) catch "";
            } else if (std.mem.eql(u8, a, "-o")) {
                state.cfg.target_output = state.alloc.dupe(u8, v) catch "";
            } else if (std.mem.eql(u8, a, "-c")) {
                state.cfg.launcher_cmd = state.alloc.dupe(u8, v) catch "";
            } else if (std.mem.eql(u8, a, "-ico")) {
                state.cfg.launcher_icon = state.alloc.dupe(u8, v) catch "";
            } else if (std.mem.eql(u8, a, "-s")) {
                state.cfg.css_file = state.alloc.dupe(u8, v) catch "";
            } else if (std.mem.eql(u8, a, "-hl")) {
                state.cfg.hotspot_layer = state.alloc.dupe(u8, v) catch "";
            } else if (std.mem.eql(u8, a, "-lp")) {
                state.cfg.launcher_pos = state.alloc.dupe(u8, v) catch "";
            } else if (std.mem.eql(u8, a, "-cfg")) {
                cfg_file_override = state.alloc.dupe(u8, v) catch "";
            } else if (std.mem.eql(u8, a, "-g")) {
                state.cfg.ignore_classes = splitArgs(state.alloc, v, ' ');
            } else if (std.mem.eql(u8, a, "-iw")) {
                state.cfg.ignore_workspaces = splitArgs(state.alloc, v, ',');
            }
        } else if (std.mem.eql(u8, a, "-i") or std.mem.eql(u8, a, "-hd") or std.mem.eql(u8, a, "-w") or
            std.mem.eql(u8, a, "-mb") or std.mem.eql(u8, a, "-ml") or std.mem.eql(u8, a, "-mr") or
            std.mem.eql(u8, a, "-mt"))
        {
            if (i + 1 >= args.len) {
                log.err("missing value for {s}", .{a});
                std.process.exit(1);
            }
            i += 1;
            const v = args[i];
            const n: i64 = std.fmt.parseInt(i64, v, 10) catch {
                log.err("invalid number for {s}: {s}", .{ a, v });
                std.process.exit(1);
            };
            if (std.mem.eql(u8, a, "-i")) {
                state.cfg.icon_size = @intCast(n);
            } else if (std.mem.eql(u8, a, "-hd")) {
                state.cfg.hotspot_delay_ms = n;
            } else if (std.mem.eql(u8, a, "-w")) {
                state.cfg.num_workspaces = @intCast(n);
            } else if (std.mem.eql(u8, a, "-mb")) {
                state.cfg.margin_bottom = @intCast(n);
            } else if (std.mem.eql(u8, a, "-ml")) {
                state.cfg.margin_left = @intCast(n);
            } else if (std.mem.eql(u8, a, "-mr")) {
                state.cfg.margin_right = @intCast(n);
            } else if (std.mem.eql(u8, a, "-mt")) {
                state.cfg.margin_top = @intCast(n);
            }
        } else {
            log.err("unknown argument: {s}", .{a});
            printUsage();
            std.process.exit(1);
        }
    }
}

// ---------------------------------------------------------------------------
// Single instance (flock lock + SIGRTMIN toggle)
// ---------------------------------------------------------------------------

fn singleInstanceCheck() void {
    const lock_path = std.fmt.allocPrint(state.alloc, "/tmp/dockh-{d}.lock", .{c.getuid()}) catch return;
    const pz = state.alloc.dupeZ(u8, lock_path) catch return;

    const fd = c.open(pz.ptr, c.O_CREAT | c.O_RDWR | c.O_CLOEXEC, @as(c_uint, 0o644));
    if (fd < 0) return;
    if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) {
        // Another instance is running.
        var pid_buf: [32]u8 = undefined;
        const n = c.read(fd, &pid_buf, pid_buf.len);
        if (n > 0) {
            const pid_str = std.mem.trim(u8, pid_buf[0..@intCast(n)], " \t\r\n");
            if (std.fmt.parseInt(c_int, pid_str, 10)) |pid| {
                const rtmin = c.__libc_current_sigrtmin();
                if (state.cfg.autohide or state.cfg.resident) {
                    log.info("dockh already running; exiting", .{});
                } else {
                    log.info("dockh already running; toggling visibility and exiting", .{});
                    _ = c.kill(pid, rtmin + 1);
                }
            } else |_| {}
        }
        std.process.exit(0);
    }
    // We hold the lock: record our pid. (fd stays open for process lifetime.)
    _ = c.ftruncate(fd, 0);
    _ = c.lseek(fd, 0, c.SEEK_SET);
    var pid_buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&pid_buf, "{d}\n", .{c.getpid()}) catch return;
    _ = c.write(fd, s.ptr, s.len);
}

// ---------------------------------------------------------------------------
// GTK window + layer shell
// ---------------------------------------------------------------------------

fn setDockAnchors(win: ?*anyopaque) void {
    const pos = state.cfg.position;
    const full: c_int = if (state.cfg.full) 1 else 0;
    if (std.mem.eql(u8, pos, "bottom")) {
        c.gtk_layer_set_anchor(win, c.EDGE_BOTTOM, 1);
        c.gtk_layer_set_anchor(win, c.EDGE_LEFT, full);
        c.gtk_layer_set_anchor(win, c.EDGE_RIGHT, full);
    } else if (std.mem.eql(u8, pos, "top")) {
        c.gtk_layer_set_anchor(win, c.EDGE_TOP, 1);
        c.gtk_layer_set_anchor(win, c.EDGE_LEFT, full);
        c.gtk_layer_set_anchor(win, c.EDGE_RIGHT, full);
    } else if (std.mem.eql(u8, pos, "left")) {
        c.gtk_layer_set_anchor(win, c.EDGE_LEFT, 1);
        c.gtk_layer_set_anchor(win, c.EDGE_TOP, full);
        c.gtk_layer_set_anchor(win, c.EDGE_BOTTOM, full);
    } else if (std.mem.eql(u8, pos, "right")) {
        c.gtk_layer_set_anchor(win, c.EDGE_RIGHT, 1);
        c.gtk_layer_set_anchor(win, c.EDGE_TOP, full);
        c.gtk_layer_set_anchor(win, c.EDGE_BOTTOM, full);
    }
}

fn applyLayer(win: ?*anyopaque, layer: []const u8) void {
    if (std.mem.eql(u8, layer, "top")) {
        c.gtk_layer_set_layer(win, c.LAYER_TOP);
    } else if (std.mem.eql(u8, layer, "bottom")) {
        c.gtk_layer_set_layer(win, c.LAYER_BOTTOM);
    } else {
        c.gtk_layer_set_layer(win, c.LAYER_OVERLAY);
        c.gtk_layer_set_exclusive_zone(win, -1);
    }
}

fn setMargins(win: ?*anyopaque) void {
    c.gtk_layer_set_margin(win, c.EDGE_TOP, state.cfg.margin_top);
    c.gtk_layer_set_margin(win, c.EDGE_BOTTOM, state.cfg.margin_bottom);
    c.gtk_layer_set_margin(win, c.EDGE_LEFT, state.cfg.margin_left);
    c.gtk_layer_set_margin(win, c.EDGE_RIGHT, state.cfg.margin_right);
}

/// Returns a GdkMonitor* with an owned reference (unref after use).
fn monitorByConnector(connector: []const u8) ?*anyopaque {
    const display = c.gdk_display_get_default() orelse return null;
    const list = c.gdk_display_get_monitors(display);
    // NOTE: the list returned by gdk_display_get_monitors is transfer-none
    // (owned by the display, which stores a borrowed pointer) — never unref it.
    const n = c.g_list_model_get_n_items(list);
    var found: ?*anyopaque = null;
    var i: c_uint = 0;
    while (i < n) : (i += 1) {
        const item = c.g_list_model_get_item(list, i);
        if (item == null) continue;
        const conn = c.gdk_monitor_get_connector(item);
        if (conn != null and std.mem.eql(u8, std.mem.span(conn.?), connector)) {
            found = item;
            break;
        }
        c.g_object_unref(item);
    }
    return found;
}

fn setupMainWindow() void {
    const win = c.gtk_window_new();
    state.win = win;
    c.gtk_widget_set_name(win, "dockh-window");
    // GTK4 defaults new windows to a 200x200 min size; layer-shell should hug
    // its content or the glass box shows dead space at the edge.
    c.gtk_window_set_default_size(win, -1, -1);

    c.gtk_layer_init_for_window(win);
    c.gtk_layer_set_namespace(win, "dockh");

    if (state.cfg.target_output.len > 0) {
        if (monitorByConnector(state.cfg.target_output)) |m| {
            c.gtk_layer_set_monitor(win, m);
            c.g_object_unref(m);
        } else {
            log.warn("target output '{s}' not found; using focused monitor", .{state.cfg.target_output});
        }
    }

    setDockAnchors(win);
    if (state.cfg.exclusive) {
        c.gtk_layer_auto_exclusive_zone_enable(win);
        state.cfg.layer = "top";
    }
    applyLayer(win, state.cfg.layer);
    setMargins(win);

    state.vertical = std.mem.eql(u8, state.cfg.position, "left") or std.mem.eql(u8, state.cfg.position, "right");
    const outer_orientation = if (state.vertical) c.ORIENTATION_HORIZONTAL else c.ORIENTATION_VERTICAL;
    const inner_orientation = if (state.vertical) c.ORIENTATION_VERTICAL else c.ORIENTATION_HORIZONTAL;

    const outer_box = c.gtk_box_new(outer_orientation, 0);
    c.gtk_widget_set_name(outer_box, "dockh-box");
    const alignment_box = c.gtk_box_new(inner_orientation, 0);
    const main_box = c.gtk_box_new(inner_orientation, 0);
    c.gtk_widget_set_name(main_box, "dockh-main");
    c.gtk_box_set_spacing(main_box, 4);

    c.gtk_box_append(outer_box, alignment_box);
    c.gtk_box_append(alignment_box, main_box);
    c.gtk_window_set_child(win, outer_box);

    state.outer_box = outer_box;
    state.alignment_box = alignment_box;
    state.main_box = main_box;

    // alignment: expand the filler, align the content box
    const gtk_align: c.GtkAlign = if (std.mem.eql(u8, state.cfg.alignment, "start"))
        c.ALIGN_START
    else if (std.mem.eql(u8, state.cfg.alignment, "end"))
        c.ALIGN_END
    else
        c.ALIGN_CENTER;
    if (state.vertical) {
        c.gtk_widget_set_vexpand(alignment_box, 1);
        c.gtk_widget_set_valign(main_box, gtk_align);
        c.gtk_widget_set_halign(main_box, c.ALIGN_CENTER);
    } else {
        c.gtk_widget_set_hexpand(alignment_box, 1);
        c.gtk_widget_set_halign(main_box, gtk_align);
        c.gtk_widget_set_valign(main_box, c.ALIGN_CENTER);
    }

    // quit when destroyed
    _ = c.g_signal_connect(win, "destroy", @ptrCast(&onDestroy), null);

    // enter/leave on the dock itself (needed by autohide and by intellihide,
    // so it never yanks the dock from under the cursor)
    if (state.cfg.autohide or state.cfg.hide_on_activity) {
        const motion = c.gtk_event_controller_motion_new();
        c.gtk_widget_add_controller(win, motion);
        _ = c.g_signal_connect(motion, "enter", @ptrCast(&onDockEnter), null);
        _ = c.g_signal_connect(motion, "leave", @ptrCast(&onDockLeave), null);
    }

    // macOS proximity magnification: track the pointer over the icons row.
    if (state.cfg.magnify_enabled) {
        const mag_motion = c.gtk_event_controller_motion_new();
        c.gtk_widget_add_controller(main_box, mag_motion);
        _ = c.g_signal_connect(mag_motion, "enter", @ptrCast(&onMagEnter), null);
        _ = c.g_signal_connect(mag_motion, "motion", @ptrCast(&onMagMotion), null);
        _ = c.g_signal_connect(mag_motion, "leave", @ptrCast(&onMagLeave), null);
    }
}

fn onDestroy(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (main_loop) |ml| c.g_main_loop_quit(ml);
}

// ---------------------------------------------------------------------------
// Autohide: hotspot windows (GTK4 event controllers, no GTK3 signals)
// ---------------------------------------------------------------------------

fn nowMs() i64 {
    var ts: c.Timespec = .{};
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

fn showDock() void {
    if (state.win) |w| c.gtk_widget_show(w);
}

fn hideDock() void {
    if (state.win) |w| c.gtk_widget_hide(w);
}

fn scheduleHide(ms: c_uint) void {
    if (state.hide_timer != 0) {
        _ = c.g_source_remove(state.hide_timer);
        state.hide_timer = 0;
    }
    state.hide_timer = c.g_timeout_add(ms, @ptrCast(&onHideTimeout), null);
}

fn cancelHide() void {
    if (state.hide_timer != 0) {
        _ = c.g_source_remove(state.hide_timer);
        state.hide_timer = 0;
    }
}

fn onHideTimeout(_: ?*anyopaque) callconv(.c) c_int {
    state.hide_timer = 0;
    if (!state.mouse_in_dock and !state.mouse_in_hotspot) {
        // intellihide keeps the dock out while the workspace is empty.
        if (state.cfg.hide_on_activity and !state.workspace_has_windows) {
            showDock();
        } else {
            hideDock();
        }
    }
    return 0; // G_SOURCE_REMOVE
}

fn onDockEnter(_: ?*anyopaque, _: f64, _: f64, _: ?*anyopaque) callconv(.c) void {
    state.mouse_in_dock = true;
    cancelHide();
}

// macOS proximity magnification: GtkEventControllerMotion on the main box.
// The motion signal delivers (x, y) in main_box coordinates, which is exactly
// what widgets.applyMagnify expects. On leave we reset every icon to 1.0.
fn onMagMotion(_: ?*anyopaque, x: f64, y: f64, _: ?*anyopaque) callconv(.c) void {
    widgets.applyMagnify(x, y);
}

fn onMagEnter(_: ?*anyopaque, x: f64, y: f64, _: ?*anyopaque) callconv(.c) void {
    widgets.applyMagnify(x, y);
}

fn onMagLeave(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    widgets.resetMagnify();
}

fn onDockLeave(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    state.mouse_in_dock = false;
    scheduleHide(1000);
}

fn onHotspotWindowEnter(_: ?*anyopaque, _: f64, _: f64, _: ?*anyopaque) callconv(.c) void {
    state.mouse_in_hotspot = true;
    cancelHide();
}

fn onHotspotWindowLeave(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    state.mouse_in_hotspot = false;
    scheduleHide(1000);
}

fn onDetectorEnter(_: ?*anyopaque, _: f64, _: f64, _: ?*anyopaque) callconv(.c) void {
    state.detector_entered_ms = nowMs();
}

fn onHotspotStripEnter(_: ?*anyopaque, _: f64, _: f64, _: ?*anyopaque) callconv(.c) void {
    const delay = nowMs() - state.detector_entered_ms;
    log.debug("hotspot delay {d}ms (limit {d}ms)", .{ delay, state.cfg.hotspot_delay_ms });
    if (delay <= state.cfg.hotspot_delay_ms or state.cfg.hotspot_delay_ms == 0) {
        showDock();
        state.mouse_in_hotspot = true;
        cancelHide();
    }
}

fn createHotspotWindow(monitor: ?*anyopaque) void {
    const win = c.gtk_window_new();
    c.gtk_widget_set_name(win, "dockh-hotspot-window");

    c.gtk_layer_init_for_window(win);
    c.gtk_layer_set_namespace(win, "dockh-hotspot");
    c.gtk_layer_set_monitor(win, monitor);

    setDockAnchors(win);
    applyLayer(win, state.cfg.hotspot_layer);
    c.gtk_layer_set_exclusive_zone(win, -1);

    var rect: c.GdkRect = .{};
    c.gdk_monitor_get_geometry(monitor, &rect);
    const mw: i32 = rect.width;
    const mh: i32 = rect.height;

    const horizontal = !state.vertical;
    const det_size: i32 = if (state.cfg.hotspot_size > 0) state.cfg.hotspot_size else (if (horizontal) @divTrunc(mh, 3) else @divTrunc(mw, 3));
    const det_w: i32 = if (horizontal) mw else det_size;
    const det_h: i32 = if (horizontal) det_size else mh;
    const strip_w: i32 = if (horizontal) mw else 2;
    const strip_h: i32 = if (horizontal) 2 else mh;

    const orientation = if (horizontal) c.ORIENTATION_VERTICAL else c.ORIENTATION_HORIZONTAL;
    const box = c.gtk_box_new(orientation, 0);

    const detector = c.gtk_box_new(orientation, 0);
    c.gtk_widget_add_css_class(detector, "dockh-hotspot-detector");
    c.gtk_widget_set_size_request(detector, det_w, det_h);

    const strip = c.gtk_box_new(orientation, 0);
    c.gtk_widget_add_css_class(strip, "dockh-hotspot-strip");
    c.gtk_widget_set_size_request(strip, strip_w, strip_h);

    // strip faces the screen edge: bottom/right → detector first
    const bottom = std.mem.eql(u8, state.cfg.position, "bottom");
    const right = std.mem.eql(u8, state.cfg.position, "right");
    if (bottom or right) {
        c.gtk_box_append(box, detector);
        c.gtk_box_append(box, strip);
    } else {
        c.gtk_box_append(box, strip);
        c.gtk_box_append(box, detector);
    }
    c.gtk_window_set_child(win, box);

    const det_motion = c.gtk_event_controller_motion_new();
    c.gtk_widget_add_controller(detector, det_motion);
    _ = c.g_signal_connect(det_motion, "enter", @ptrCast(&onDetectorEnter), null);

    const strip_motion = c.gtk_event_controller_motion_new();
    c.gtk_widget_add_controller(strip, strip_motion);
    _ = c.g_signal_connect(strip_motion, "enter", @ptrCast(&onHotspotStripEnter), null);

    const win_motion = c.gtk_event_controller_motion_new();
    c.gtk_widget_add_controller(win, win_motion);
    _ = c.g_signal_connect(win_motion, "enter", @ptrCast(&onHotspotWindowEnter), null);
    _ = c.g_signal_connect(win_motion, "leave", @ptrCast(&onHotspotWindowLeave), null);

    c.gtk_widget_show(win);
}

fn setupHotspots() void {
    const display = c.gdk_display_get_default() orelse return;
    const list = c.gdk_display_get_monitors(display);
    const n = c.g_list_model_get_n_items(list);
    var i: c_uint = 0;
    while (i < n) : (i += 1) {
        const item = c.g_list_model_get_item(list, i);
        if (item == null) continue;
        if (state.cfg.target_output.len > 0) {
            const conn = c.gdk_monitor_get_connector(item);
            if (conn == null or !std.mem.eql(u8, std.mem.span(conn.?), state.cfg.target_output)) {
                c.g_object_unref(item);
                continue;
            }
        }
        createHotspotWindow(item);
        c.g_object_unref(item);
    }
}

// ---------------------------------------------------------------------------
// Signals → self-pipe → GLib main loop (async-signal-safe)
// ---------------------------------------------------------------------------

fn signalHandler(sig: c_int) callconv(.c) void {
    const b: u8 = @intCast(sig);
    var buf: [1]u8 = .{b};
    _ = c.write(sig_pipe[1], &buf, 1);
}

fn setupSignals() void {
    if (c.pipe(&sig_pipe) != 0) return;
    _ = c.fcntl(sig_pipe[0], c.F_SETFL, c.fcntl(sig_pipe[0], c.F_GETFL) | c.O_NONBLOCK);

    var act: c.Sigaction = .{ .handler = signalHandler };
    _ = c.sigemptyset(&act.mask);
    act.flags = 0;

    _ = c.sigaction(c.SIGTERM, &act, null);
    const rtmin = c.__libc_current_sigrtmin();
    _ = c.sigaction(rtmin + 1, &act, null);
    _ = c.sigaction(rtmin + 2, &act, null);
    _ = c.sigaction(rtmin + 3, &act, null);

    _ = c.g_unix_fd_add(sig_pipe[0], c.G_IO_IN, @ptrCast(&onSignalReady), null);
}

fn onSignalReady(fd: c_int, _: c_int, _: ?*anyopaque) callconv(.c) c_int {
    var buf: [16]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        for (buf[0..@intCast(n)]) |b| {
            handleSignal(@intCast(b));
        }
    }
    return 1; // keep the source
}

fn handleSignal(sig: c_int) void {
    const rtmin = c.__libc_current_sigrtmin();
    if (sig == c.SIGTERM) {
        log.info("SIGTERM received, goodbye", .{});
        if (main_loop) |ml| c.g_main_loop_quit(ml);
        return;
    }
    if (state.cfg.autohide or state.cfg.resident) {
        const visible = if (state.win) |w| c.gtk_widget_is_visible(w) != 0 else false;
        if (sig == rtmin + 1) {
            if (visible) hideDock() else showDock();
        } else if (sig == rtmin + 2) {
            if (!visible) showDock();
        } else if (sig == rtmin + 3) {
            if (visible) hideDock();
        }
    } else {
        log.debug("signal received, but not resident/autohide; ignoring", .{});
    }
}

// ---------------------------------------------------------------------------
// Hyprland event socket (event-driven via GLib, no polling)
// ---------------------------------------------------------------------------

fn connectEventSocket() bool {
    const fd = hypr.connectEventSocket(&state.ctx) catch {
        log.warn("couldn't connect to Hyprland event socket; retrying in 3s", .{});
        _ = c.g_timeout_add(3000, @ptrCast(&onRetryEvent), null);
        return false;
    };
    event_fd = fd;
    event_source = c.g_unix_fd_add(fd, c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR, @ptrCast(&onHyprEvent), null);
    log.info("watching Hyprland event socket", .{});
    return true;
}

fn onRetryEvent(_: ?*anyopaque) callconv(.c) c_int {
    if (event_fd < 0) {
        _ = connectEventSocket();
    }
    return 0;
}

fn onHyprEvent(fd: c_int, cond: c_int, _: ?*anyopaque) callconv(.c) c_int {
    if ((cond & (c.G_IO_HUP | c.G_IO_ERR)) != 0) {
        // Hyprland restarted / socket gone: reconnect shortly.
        _ = c.close(fd);
        event_fd = -1;
        event_source = 0;
        _ = c.g_timeout_add(3000, @ptrCast(&onRetryEvent), null);
        return 0; // G_SOURCE_REMOVE
    }

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        if (event_buf_len + @as(usize, @intCast(n)) > event_buf.len) {
            event_buf_len = 0;
        }
        @memcpy(event_buf[event_buf_len .. event_buf_len + @as(usize, @intCast(n))], buf[0..@intCast(n)]);
        event_buf_len += @as(usize, @intCast(n));
    }

    var start: usize = 0;
    while (start < event_buf_len) {
        const line_end = std.mem.indexOfScalar(u8, event_buf[start..event_buf_len], '\n') orelse break;
        const line = event_buf[start .. start + line_end];
        handleHyprEventLine(line);
        start = start + line_end + 1;
    }
    // keep the unconsumed tail
    if (start > 0 and start < event_buf_len) {
        const remaining = event_buf_len - start;
        std.mem.copyForwards(u8, event_buf[0..remaining], event_buf[start..event_buf_len]);
        event_buf_len = remaining;
    } else if (start >= event_buf_len) {
        event_buf_len = 0;
    }
    return 1;
}

fn handleHyprEventLine(line: []const u8) void {
    if (line.len == 0) return;
    log.debug("hypr event: {s}", .{line});

    if (std.mem.startsWith(u8, line, "activewindowv2>>")) {
        const addr = std.mem.trim(u8, line["activewindowv2>>".len..], " \r");
        if (!std.mem.eql(u8, addr, state.last_win_addr) and !std.mem.containsAtLeast(u8, addr, 1, ">>")) {
            state.last_win_addr = state.alloc.dupe(u8, addr) catch "";
            refreshClients();
        }
    } else if (std.mem.startsWith(u8, line, "workspacev2>>")) {
        // workspacev2>>ID,NAME
        const rest = std.mem.trim(u8, line["workspacev2>>".len..], " \r");
        if (std.mem.indexOfScalar(u8, rest, ',')) |comma| {
            const id_part = std.mem.trim(u8, rest[0..comma], " ");
            state.active_ws_id = std.fmt.parseInt(i32, id_part, 10) catch state.active_ws_id;
        }
        refreshClients();
    } else if (std.mem.startsWith(u8, line, "focusedmon>>")) {
        // focusedmon>>MONITOR,WORKSPACEID
        const rest = std.mem.trim(u8, line["focusedmon>>".len..], " \r");
        if (std.mem.lastIndexOfScalar(u8, rest, ',')) |comma| {
            const id_part = std.mem.trim(u8, rest[comma + 1 ..], " ");
            state.active_ws_id = std.fmt.parseInt(i32, id_part, 10) catch state.active_ws_id;
        }
        refreshClients();
    } else if (std.mem.startsWith(u8, line, "openwindow>>") or
        std.mem.startsWith(u8, line, "closewindow>>") or
        std.mem.startsWith(u8, line, "movewindow>>") or
        std.mem.startsWith(u8, line, "fullscreen>>"))
    {
        refreshClients();
    }
}

/// Any mapped, non-hidden client on the active workspace (ignoring the
/// workspaces listed in `ignore_workspaces`)?
fn workspaceOccupied() bool {
    for (state.clients) |cl| {
        if (!cl.mapped or cl.hidden) continue;
        if (cl.workspace.id != state.active_ws_id) continue;
        if (widgets.wsIgnored(cl.workspace)) continue;
        return true;
    }
    return false;
}

/// hide_on_activity ("intellihide"): the dock hides while the active
/// workspace has windows and reappears when it's empty.
fn updateActivityVisibility() void {
    if (!state.cfg.hide_on_activity) return;
    if (state.mouse_in_dock or state.mouse_in_hotspot) return; // don't yank the dock from under the cursor
    if (state.workspace_has_windows) {
        log.debug("intellihide: ws {d} occupied → hide", .{state.active_ws_id});
        hideDock();
    } else {
        log.debug("intellihide: ws {d} empty → show", .{state.active_ws_id});
        showDock();
        cancelHide();
    }
}

fn refreshClients() void {
    _ = scratch_arena.reset(.retain_capacity);
    state.scratch = scratch_arena.allocator();

    state.clients = hypr.listClients(state.scratch, &state.ctx) catch {
        log.err("couldn't list clients", .{});
        // The scratch arena was already reset above — old pointers are dead.
        state.clients = &.{};
        state.active_class = "";
        // Don't leave stale visibility: an empty workspace means show.
        state.workspace_has_windows = false;
        updateActivityVisibility();
        return;
    };
    const active = hypr.activeWindow(state.scratch, &state.ctx) catch hypr.Client{};
    state.active_class = active.class;
    // Fallback: before the first workspace event, derive the active ws from
    // the focused window (0 = none yet, e.g. empty desktop at startup).
    if (state.active_ws_id == 0 and active.workspace.id != 0) {
        state.active_ws_id = active.workspace.id;
    }
    state.workspace_has_windows = workspaceOccupied();
    widgets.rebuildMainBox();
    updateActivityVisibility();
}

pub fn requestRebuild() void {
    refreshClients();
}

// ---------------------------------------------------------------------------
// Config & first-run files
// ---------------------------------------------------------------------------

fn loadConfigFile() void {
    const path = cfgPath();
    if (fs.pathExists(path)) {
        config_mod.parseFile(state.alloc, path, &state.cfg) catch |e| switch (e) {
            error.ConfigFileNotFound => {},
            else => log.warn("error reading {s}: {any}", .{ path, e }),
        };
        log.info("loaded config from {s}", .{path});
    }
}

fn loadPinned() void {
    const path = pinnedFilePath();
    if (fs.pathExists(path)) {
        const data = fs.readFileAlloc(state.alloc, path, 1 << 20) catch return;
        defer state.alloc.free(data);
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |raw| {
            const p = std.mem.trim(u8, raw, " \t\r");
            if (p.len == 0) continue;
            state.pinned.append(state.alloc, state.alloc.dupe(u8, p) catch continue) catch continue;
        }
    } else {
        for (state.cfg.pinned) |p| {
            if (p.len == 0) continue;
            state.pinned.append(state.alloc, state.alloc.dupe(u8, p) catch continue) catch continue;
        }
        widgets.savePinned();
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init.Minimal) void {
    perm_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer perm_arena.deinit();
    state.alloc = perm_arena.allocator();

    scratch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_arena.deinit();
    state.scratch = scratch_arena.allocator();

    const args = init.args.toSlice(state.alloc) catch &.{};

    // Config file first, then CLI overrides win. Pass 1: locate `-cfg` before
    // anything else so loadConfigFile() reads the overridden file; otherwise
    // the flag is silently ignored (the default path wins).
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-cfg")) {
            if (i + 1 < args.len) {
                cfg_file_override = state.alloc.dupe(u8, args[i + 1]) catch "";
            }
            break;
        }
    }
    loadConfigFile();
    parseArgs(args);

    if (state.cfg.autohide and state.cfg.resident) {
        log.warn("autohide and resident are mutually exclusive; disabling autohide", .{});
        state.cfg.autohide = false;
    }

    const his = desktop.getEnv(state.alloc, "HYPRLAND_INSTANCE_SIGNATURE") orelse {
        log.err("HYPRLAND_INSTANCE_SIGNATURE not set — is Hyprland running?", .{});
        std.process.exit(1);
    };
    state.ctx.his = his;

    const runtime = desktop.getEnv(state.alloc, "XDG_RUNTIME_DIR");
    const runtime_hypr = if (runtime) |r| std.fmt.allocPrint(state.alloc, "{s}/hypr", .{r}) catch "" else "";
    if (runtime_hypr.len > 0 and fs.pathExists(runtime_hypr)) {
        state.ctx.hypr_dir = runtime_hypr;
    } else {
        state.ctx.hypr_dir = "/tmp/hypr";
    }
    log.debug("hypr dir: {s}", .{state.ctx.hypr_dir});

    if (!allow_multiple) singleInstanceCheck();

    _ = fs.ensureDir(configDir());
    _ = fs.ensureDir(cacheDir());

    // first-run defaults
    const css_path = cssFilePath();
    if (!fs.pathExists(css_path)) {
        fs.writeFile(css_path, default_css) catch {};
        log.info("wrote default style.css to {s}", .{css_path});
    }
    const toml_path = cfgPath();
    if (!fs.pathExists(toml_path)) {
        fs.writeFile(toml_path, default_toml) catch {};
        log.info("wrote default config.toml to {s}", .{toml_path});
    }

    loadPinned();

    desktop.initAppDirs(state.alloc);
    if (log.debug_enabled) log.debug("debug logging enabled", .{});

    // GTK
    c.gtk_init();

    const css_z = state.alloc.dupeZ(u8, css_path) catch "";
    if (css_z.len > 0) {
        _ = cssmod.loadFile(css_z);
        cssmod.setupWatch(css_z); // hot reload: edits apply without restart
    }
    cssmod.loadAnimation(&state.cfg);

    setupMainWindow();
    setupSignals();
    setupMemoryTrim();

    // Scene-graph blur backend + status polls (media progress / badges) are
    // independent of the window being mapped, so arm them early.
    blur.init();
    status_mod.setup();

    refreshClients();

    if (state.cfg.autohide or state.cfg.hide_on_activity) {
        setupHotspots();
        // start hidden (autohide), unless intellihide has an empty desktop
        _ = c.g_timeout_add(500, @ptrCast(&onInitialHide), null);
    }

    if (state.win) |w| c.gtk_widget_show(w);

    // The window must be mapped before intellihide can decide to hide it.
    updateActivityVisibility();

    // Rebuild once the layer surface exists: the in-dock blur (glow) needs a
    // realized surface to create its offscreen renderer, and the first
    // refreshClients() ran before the window was mapped.
    _ = c.g_timeout_add(250, @ptrCast(&onMappedRebuild), null);

    _ = connectEventSocket();

    log.info("dockh {s} started (position={s}, autohide={any}, resident={any})", .{ version, state.cfg.position, state.cfg.autohide, state.cfg.resident });

    main_loop = c.g_main_loop_new(null, 0);
    if (main_loop) |ml| c.g_main_loop_run(ml);
    if (main_loop) |ml| c.g_main_loop_unref(ml);
}

fn onMappedRebuild(_: ?*anyopaque) callconv(.c) c_int {
    // The first refreshClients() ran before the window was mapped; once the
    // layer surface exists, rebuild once more so the glow (scene-graph blur,
    // which needs no offscreen renderer) and the status widgets line up.
    blur.init();
    refreshClients();
    return 0; // one-shot
}

fn onInitialHide(_: ?*anyopaque) callconv(.c) c_int {
    // intellihide on an empty desktop must not hide on startup.
    if (state.cfg.hide_on_activity and !state.workspace_has_windows) {
        return 0;
    }
    hideDock();
    return 0;
}

// ---------------------------------------------------------------------------
// Memory: GTK4 frees a lot of transient allocations (CSS, render nodes, icon
// textures); glibc keeps the pages in the heap. Trim periodically so the RSS
// actually drops instead of staying at the peak.
// ---------------------------------------------------------------------------

fn onMemoryTrim(_: ?*anyopaque) callconv(.c) c_int {
    _ = c.malloc_trim(0);
    return 1; // keep the timer
}

fn onEarlyMemoryTrim(_: ?*anyopaque) callconv(.c) c_int {
    _ = c.malloc_trim(0);
    return 0; // one-shot: remove this source after the first trim
}

fn setupMemoryTrim() void {
    // periodic trim: GTK4 frees transient memory on every dock rebuild, but
    // glibc keeps the pages in the heap — returning them keeps RSS low.
    _ = c.g_timeout_add(30_000, @ptrCast(&onMemoryTrim), null);
    // one early trim after startup churn settles (CSS, icons, first refresh)
    _ = c.g_timeout_add(5_000, @ptrCast(&onEarlyMemoryTrim), null);
}
