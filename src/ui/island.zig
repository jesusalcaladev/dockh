//! Dynamic Island — macOS-style floating pill at the top-center of the screen.
//!
//! The island is ALWAYS visible as a small pill (showing the current time and
//! battery), like the iPhone/MacBook notch. It expands in place to show:
//!   * Music playback: album art, song title, artist, playback controls and a
//!     thin progress bar (fed by status.zig playerctl polls).
//!   * Notifications: app icon, title and body — popped out of the pill,
//!     click-to-dismiss, auto-dismissed after a few seconds (mako detection).
//!   * OSD: volume / brightness changes pop a slim slider with an icon
//!     (wpctl / brightnessctl), auto-dismissing like macOS.
//!   * Low battery: a warning notification when the charge crosses 20%.
//!
//! Layout is a single layer-shell window anchored to the top edge (wlr
//! auto-centers unanchored horizontal edges). The pill never leaves the screen
//! and only the pill itself is interactive — the rest is compositor clickable.
//!
//! The module owns its window, widget tree, inline CSS and state machine —
//! self-contained on purpose: the dock core only calls the small public API
//! (setup / updateMusic / updateMusicProgress / showNotification / showOsd /
//! setBattery / deinit).
const std = @import("std");
const c = @import("c");
const fs = @import("fs");
const state = @import("../core/state.zig");
const log = @import("../core/log.zig");

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

const Mode = enum { idle, music, notif, osd, screenshot };

var island_win: ?*anyopaque = null;
var root_box: ?*anyopaque = null;
var mode: Mode = .idle;

// Idle pill (clock + battery)
var clock_label: ?*anyopaque = null;
var battery_label: ?*anyopaque = null;
var idle_box: ?*anyopaque = null;

// Music section
var music_box: ?*anyopaque = null;
var art_image: ?*anyopaque = null;
var art_wrap: ?*anyopaque = null;
var music_title_label: ?*anyopaque = null;
var music_artist_label: ?*anyopaque = null;
var music_play_btn: ?*anyopaque = null;
var music_prev_btn: ?*anyopaque = null;
var music_next_btn: ?*anyopaque = null;
var music_progress_bar: ?*anyopaque = null;

// Notification section
var notif_box: ?*anyopaque = null;
var notif_icon: ?*anyopaque = null;
var notif_app_label: ?*anyopaque = null;
var notif_title_label: ?*anyopaque = null;
var notif_body_label: ?*anyopaque = null;

// OSD section (volume / brightness)
var osd_box: ?*anyopaque = null;
var osd_icon: ?*anyopaque = null;
var osd_title_label: ?*anyopaque = null;
var osd_progress: ?*anyopaque = null;

// Screenshot section
var shot_box: ?*anyopaque = null;
var shot_image: ?*anyopaque = null;
var shot_title_label: ?*anyopaque = null;
var shot_body_label: ?*anyopaque = null;
var last_shot_path: []const u8 = "";

// State machine — the *_last slices are OWNED copies (state.alloc is a
// permanent arena, so storing dupes here is safe and the comparisons against
// the polled (scratch) strings never read freed memory).
var last_title: []const u8 = "";
var last_artist: []const u8 = "";
var last_art_path: []const u8 = "";
var last_playing = false;
var was_playing = false;
var notif_timer: c_uint = 0;
var clock_timer: c_uint = 0;
var battery_warned = false;
var last_battery_pct: i32 = -1;
var last_battery_charging = false;

// ---------------------------------------------------------------------------
// Sizing (logical px)
// ---------------------------------------------------------------------------

const IDLE_W: c_int = 200;
const IDLE_H: c_int = 40;
const EXPANDED_W: c_int = 440;
const EXPANDED_H: c_int = 118;

// ---------------------------------------------------------------------------
// CSS — the island ships its own stylesheet so it looks right even before the
// user has a config/style.css, and overrides (ID selectors) win naturally.
// ---------------------------------------------------------------------------

const island_css =
    \\#dockh-island {
    \\    background-image: linear-gradient(180deg, rgba(255, 255, 255, 0.07), rgba(255, 255, 255, 0) 38%),
    \\                      linear-gradient(180deg, rgba(24, 27, 34, 0.97), rgba(11, 13, 18, 0.97));
    \\    border: 1px solid rgba(255, 255, 255, 0.13);
    \\    border-radius: 999px;
    \\    box-shadow: 0 14px 44px rgba(0, 0, 0, 0.62), 0 0 0 1px rgba(0, 0, 0, 0.35),
    \\                inset 0 1px 0 rgba(255, 255, 255, 0.10);
    \\    transition: all 280ms cubic-bezier(0.34, 1.4, 0.64, 1);
    \\}
    \\#dockh-island.expanded {
    \\    border-radius: 26px;
    \\    background-image: linear-gradient(180deg, rgba(255, 255, 255, 0.05), rgba(255, 255, 255, 0) 30%),
    \\                      linear-gradient(180deg, rgba(26, 29, 37, 0.98), rgba(13, 15, 21, 0.98));
    \\}
    \\
    \\@keyframes island-pop {
    \\    from { opacity: 0; }
    \\    to   { opacity: 1; }
    \\}
    \\#island-music.show, #island-notif.show, #island-osd.show {
    \\    animation: island-pop 220ms ease-out;
    \\}
    \\
    \\#island-clock {
    \\    color: #f2f4f8;
    \\    font-weight: 600;
    \\    font-size: 14px;
    \\    letter-spacing: 0.5px;
    \\}
    \\#island-battery {
    \\    color: rgba(255, 255, 255, 0.55);
    \\    font-size: 12px;
    \\    margin-left: 8px;
    \\    padding-left: 8px;
    \\    border-left: 1px solid rgba(255, 255, 255, 0.14);
    \\}
    \\#island-battery.low {
    \\    color: #ff9f0a;
    \\}
    \\#island-battery.critical {
    \\    color: #ff453a;
    \\    font-weight: 700;
    \\}
    \\
    \\#island-art-wrap {
    \\    border-radius: 12px;
    \\    background-color: rgba(255, 255, 255, 0.08);
    \\    border: 1px solid rgba(255, 255, 255, 0.08);
    \\    box-shadow: 0 2px 10px rgba(0, 0, 0, 0.4);
    \\}
    \\#island-song-title {
    \\    color: #ffffff;
    \\    font-weight: 700;
    \\    font-size: 14px;
    \\}
    \\#island-song-artist {
    \\    color: rgba(255, 255, 255, 0.55);
    \\    font-size: 12px;
    \\}
    \\
    \\#island-music-controls button, #island-shot-controls button {
    \\    background-color: transparent;
    \\    background-image: none;
    \\    border: none;
    \\    box-shadow: none;
    \\    color: rgba(255, 255, 255, 0.85);
    \\    min-width: 30px;
    \\    min-height: 30px;
    \\    border-radius: 999px;
    \\    padding: 4px;
    \\    transition: background-color 140ms ease;
    \\}
    \\#island-music-controls button:hover, #island-shot-controls button:hover {
    \\    background-color: rgba(255, 255, 255, 0.12);
    \\}
    \\#island-music-controls #island-play-btn {
    \\    background-color: rgba(255, 255, 255, 0.15);
    \\}
    \\#island-music-controls #island-play-btn:hover {
    \\    background-color: rgba(255, 255, 255, 0.24);
    \\}
    \\
    \\#island-progress {
    \\    min-height: 3px;
    \\    margin: 10px 0 2px 0;
    \\    background-color: rgba(255, 255, 255, 0.10);
    \\    border-radius: 999px;
    \\}
    \\#island-progress > trough > progress {
    \\    background-color: #5ac8fa;
    \\    border-radius: 999px;
    \\    min-height: 3px;
    \\}
    \\
    \\#island-notif-icon {
    \\    border-radius: 10px;
    \\}
    \\#island-notif-app {
    \\    color: #5ac8fa;
    \\    font-size: 10px;
    \\    font-weight: 700;
    \\    text-transform: uppercase;
    \\    letter-spacing: 0.8px;
    \\}
    \\#island-notif-title {
    \\    color: #ffffff;
    \\    font-weight: 600;
    \\    font-size: 13px;
    \\}
    \\#island-notif-body {
    \\    color: rgba(255, 255, 255, 0.55);
    \\    font-size: 12px;
    \\}
    \\
    \\#island-osd-title {
    \\    color: rgba(255, 255, 255, 0.75);
    \\    font-weight: 600;
    \\    font-size: 12px;
    \\    letter-spacing: 0.4px;
    \\}
    \\#island-osd-progress {
    \\    min-height: 6px;
    \\    margin: 8px 0 2px 0;
    \\    background-color: rgba(255, 255, 255, 0.10);
    \\    border-radius: 999px;
    \\}
    \\#island-osd-progress > trough > progress {
    \\    background-color: #5ac8fa;
    \\    border-radius: 999px;
    \\    min-height: 6px;
    \\}
    \\
    \\#island-shot-image {
    \\    border-radius: 12px;
    \\    background-color: rgba(255, 255, 255, 0.06);
    \\    border: 1px solid rgba(255, 255, 255, 0.10);
    \\    box-shadow: 0 2px 10px rgba(0, 0, 0, 0.4);
    \\}
    \\#island-shot-title {
    \\    color: #ffffff;
    \\    font-weight: 700;
    \\    font-size: 13px;
    \\}
    \\#island-shot-body {
    \\    color: rgba(255, 255, 255, 0.55);
    \\    font-size: 12px;
    \\}
;

var css_provider: ?*anyopaque = null;
var css_loaded = false;

fn loadCss() void {
    if (css_loaded) return;
    css_loaded = true;
    css_provider = c.gtk_css_provider_new();
    const css_z = state.alloc.dupeZ(u8, island_css) catch return;
    if (css_z.len > 0) c.gtk_css_provider_load_from_string(css_provider.?, css_z.ptr);
    const display = c.gdk_display_get_default();
    if (display != null and css_z.len > 0) {
        c.gtk_style_context_add_provider_for_display(display, css_provider.?, c.PROVIDER_PRIORITY_APPLICATION);
    }
}

// ---------------------------------------------------------------------------
// Custom SVG icons
//
// Every island icon can be overridden with a user SVG placed at
//   $XDG_CONFIG_HOME/dockh/icons/<name>.svg   (e.g. ~/.config/dockh/icons/)
// When the file exists it is loaded from disk (GTK4 renders SVG natively);
// otherwise the island falls back to the named icon from the theme. Keep the
// SVGs monochrome (white fill) for the controls/OSD to match the dark pill.
// ---------------------------------------------------------------------------

fn envVal(name: [*:0]const u8) ?[]const u8 {
    const v = c.getenv(name) orelse return null;
    return std.mem.span(v);
}

/// Directory where user SVGs live: $XDG_CONFIG_HOME/dockh/icons (default
/// ~/.config/dockh/icons). Always valid (falls back to /tmp on OOM).
fn iconsDir() []const u8 {
    if (envVal("XDG_CONFIG_HOME")) |d| {
        return std.fmt.allocPrint(state.alloc, "{s}/dockh/icons", .{d}) catch "/tmp/dockh-icons";
    }
    const home = envVal("HOME") orelse "/";
    return std.fmt.allocPrint(state.alloc, "{s}/.config/dockh/icons", .{home}) catch "/tmp/dockh-icons";
}

/// Resolve `name.svg` inside the icons dir; null when the file doesn't exist.
fn svgPath(name: []const u8) ?[]const u8 {
    const p = std.fmt.allocPrint(state.alloc, "{s}/{s}.svg", .{ iconsDir(), name }) catch return null;
    if (fs.pathExists(p)) return p;
    return null;
}

/// Set an image from a custom SVG when present, else from the theme icon
/// name. `px` is the rendered pixel size (SVG viewBox is scaled to fit).
fn setImageIcon(img: ?*anyopaque, svg_name: []const u8, fallback_icon: []const u8, px: c_int) void {
    if (img == null) return;
    if (svgPath(svg_name)) |path| {
        const z = state.alloc.dupeZ(u8, path) catch "";
        if (z.len > 0) {
            c.gtk_image_set_from_file(img, z.ptr);
            c.gtk_image_set_pixel_size(img, px);
            return;
        }
    }
    const z = state.alloc.dupeZ(u8, fallback_icon) catch return;
    c.gtk_image_set_from_icon_name(img, z.ptr);
    c.gtk_image_set_pixel_size(img, px);
}

/// Build a button whose child image prefers the custom SVG.
fn makeIconButton(svg_name: []const u8, fallback_icon: []const u8, px: c_int) ?*anyopaque {
    const btn = c.gtk_button_new();
    const img = c.gtk_image_new();
    c.gtk_widget_set_size_request(img, px, px);
    setImageIcon(img, svg_name, fallback_icon, px);
    c.gtk_button_set_child(btn, img);
    return btn;
}

// ---------------------------------------------------------------------------
// Monitor helpers (mirror main.zig's: owned reference, unref after use)
// ---------------------------------------------------------------------------

fn monitorByConnector(connector: []const u8) ?*anyopaque {
    const display = c.gdk_display_get_default() orelse return null;
    const list = c.gdk_display_get_monitors(display);
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

/// The monitor the island should live on: the dock's target output, else the
/// first (primary) monitor. Returns an owned reference or null.
fn islandMonitor() ?*anyopaque {
    if (state.cfg.target_output.len > 0) {
        if (monitorByConnector(state.cfg.target_output)) |m| return m;
    }
    const display = c.gdk_display_get_default() orelse return null;
    const list = c.gdk_display_get_monitors(display);
    const n = c.g_list_model_get_n_items(list);
    if (n == 0) return null;
    return c.g_list_model_get_item(list, 0);
}

/// The window is anchored only to the TOP edge; wlr-layer-shell auto-centers
/// surfaces with no horizontal anchors (Hyprland honors this), so the pill is
/// always centered regardless of its current width. The only margin we need is
/// the small top gap. (Left/right margins on unanchored edges are ignored by
/// the protocol — computing them was dead arithmetic.)
fn recenter() void {
    if (island_win == null) return;
    c.gtk_layer_set_margin(island_win, c.EDGE_TOP, 10);
}

// ---------------------------------------------------------------------------
// Widget creation
// ---------------------------------------------------------------------------

fn createIdleSection() ?*anyopaque {
    const box = c.gtk_box_new(c.ORIENTATION_HORIZONTAL, 0);
    idle_box = box;
    // Layer-shell windows size to content; a fixed size request keeps the
    // pill shape even if the compositor ignores gtk_window_set_default_size.
    c.gtk_widget_set_size_request(box, IDLE_W, IDLE_H);
    c.gtk_widget_set_halign(box, c.ALIGN_CENTER);
    c.gtk_widget_set_valign(box, c.ALIGN_CENTER);

    clock_label = c.gtk_label_new("--:--");
    c.gtk_widget_set_name(clock_label, "island-clock");
    c.gtk_box_append(box, clock_label);

    battery_label = c.gtk_label_new("");
    c.gtk_widget_set_name(battery_label, "island-battery");
    c.gtk_widget_set_visible(battery_label, 0);
    c.gtk_box_append(box, battery_label);
    return box;
}

fn createMusicSection() ?*anyopaque {
    const box = c.gtk_box_new(c.ORIENTATION_VERTICAL, 0);
    music_box = box;
    c.gtk_widget_set_name(box, "island-music");
    // The window is a fixed-size pill; center the content vertically inside it.
    c.gtk_widget_set_size_request(box, EXPANDED_W, EXPANDED_H);
    c.gtk_widget_set_valign(box, c.ALIGN_CENTER);
    c.gtk_widget_set_hexpand(box, 1);

    // content row: art | info(+controls)
    const row = c.gtk_box_new(c.ORIENTATION_HORIZONTAL, 14);
    c.gtk_widget_set_halign(row, c.ALIGN_CENTER);
    c.gtk_widget_set_valign(row, c.ALIGN_CENTER);

    // album art, wrapped for rounded clipping
    art_wrap = c.gtk_box_new(c.ORIENTATION_HORIZONTAL, 0);
    c.gtk_widget_set_name(art_wrap, "island-art-wrap");
    c.gtk_widget_set_size_request(art_wrap, 56, 56);
    art_image = c.gtk_image_new();
    c.gtk_widget_set_size_request(art_image, 56, 56);
    // placeholder: a music-note icon until real art arrives (custom SVG or
    // theme fallback)
    setImageIcon(art_image, "island-album-placeholder", "audio-x-generic-symbolic", 24);
    c.gtk_box_append(art_wrap, art_image);
    c.gtk_box_append(row, art_wrap);

    // info + controls
    const mid = c.gtk_box_new(c.ORIENTATION_VERTICAL, 6);
    c.gtk_widget_set_valign(mid, c.ALIGN_CENTER);

    const info = c.gtk_box_new(c.ORIENTATION_VERTICAL, 1);
    music_title_label = c.gtk_label_new("");
    c.gtk_widget_set_name(music_title_label, "island-song-title");
    c.gtk_widget_set_halign(music_title_label, c.ALIGN_START);
    c.gtk_label_set_ellipsize(music_title_label, c.PANGO_ELLIPSIZE_END);
    c.gtk_box_append(info, music_title_label);

    music_artist_label = c.gtk_label_new("");
    c.gtk_widget_set_name(music_artist_label, "island-song-artist");
    c.gtk_widget_set_halign(music_artist_label, c.ALIGN_START);
    c.gtk_label_set_ellipsize(music_artist_label, c.PANGO_ELLIPSIZE_END);
    c.gtk_box_append(info, music_artist_label);
    c.gtk_box_append(mid, info);

    // controls
    const controls = c.gtk_box_new(c.ORIENTATION_HORIZONTAL, 6);
    c.gtk_widget_set_name(controls, "island-music-controls");
    c.gtk_widget_set_halign(controls, c.ALIGN_START);

    music_prev_btn = makeIconButton("island-prev", "media-skip-backward-symbolic", 18);
    _ = c.g_signal_connect(music_prev_btn, "clicked", @ptrCast(&onPrevClicked), null);
    c.gtk_box_append(controls, music_prev_btn);

    music_play_btn = makeIconButton("island-play", "media-playback-start-symbolic", 22);
    c.gtk_widget_set_name(music_play_btn, "island-play-btn");
    _ = c.g_signal_connect(music_play_btn, "clicked", @ptrCast(&onPlayClicked), null);
    c.gtk_box_append(controls, music_play_btn);

    music_next_btn = makeIconButton("island-next", "media-skip-forward-symbolic", 18);
    _ = c.g_signal_connect(music_next_btn, "clicked", @ptrCast(&onNextClicked), null);
    c.gtk_box_append(controls, music_next_btn);

    c.gtk_box_append(mid, controls);
    c.gtk_box_append(row, mid);

    c.gtk_box_append(box, row);

    // progress bar (full width)
    music_progress_bar = c.gtk_progress_bar_new();
    c.gtk_widget_set_name(music_progress_bar, "island-progress");
    c.gtk_widget_set_hexpand(music_progress_bar, 1);
    c.gtk_progress_bar_set_fraction(music_progress_bar, 0);
    c.gtk_progress_bar_set_show_text(music_progress_bar, 0);
    c.gtk_box_append(box, music_progress_bar);

    return box;
}

fn createNotifSection() ?*anyopaque {
    const box = c.gtk_box_new(c.ORIENTATION_HORIZONTAL, 12);
    notif_box = box;
    c.gtk_widget_set_name(box, "island-notif");
    // Center vertically inside the fixed-size pill; stretch horizontally.
    c.gtk_widget_set_size_request(box, EXPANDED_W, EXPANDED_H);
    c.gtk_widget_set_hexpand(box, 1);
    c.gtk_widget_set_valign(box, c.ALIGN_CENTER);

    notif_icon = c.gtk_image_new();
    c.gtk_widget_set_name(notif_icon, "island-notif-icon");
    c.gtk_widget_set_size_request(notif_icon, 40, 40);
    setImageIcon(notif_icon, "island-notif", "dialog-information-symbolic", 22);
    c.gtk_box_append(box, notif_icon);

    const text_box = c.gtk_box_new(c.ORIENTATION_VERTICAL, 2);
    c.gtk_widget_set_valign(text_box, c.ALIGN_CENTER);
    c.gtk_widget_set_hexpand(text_box, 1);

    notif_app_label = c.gtk_label_new("");
    c.gtk_widget_set_name(notif_app_label, "island-notif-app");
    c.gtk_widget_set_halign(notif_app_label, c.ALIGN_START);
    c.gtk_label_set_ellipsize(notif_app_label, c.PANGO_ELLIPSIZE_END);
    c.gtk_box_append(text_box, notif_app_label);

    notif_title_label = c.gtk_label_new("");
    c.gtk_widget_set_name(notif_title_label, "island-notif-title");
    c.gtk_widget_set_halign(notif_title_label, c.ALIGN_START);
    c.gtk_label_set_ellipsize(notif_title_label, c.PANGO_ELLIPSIZE_END);
    c.gtk_box_append(text_box, notif_title_label);

    notif_body_label = c.gtk_label_new("");
    c.gtk_widget_set_name(notif_body_label, "island-notif-body");
    c.gtk_widget_set_halign(notif_body_label, c.ALIGN_START);
    c.gtk_label_set_ellipsize(notif_body_label, c.PANGO_ELLIPSIZE_END);
    c.gtk_box_append(text_box, notif_body_label);

    c.gtk_box_append(box, text_box);

    // Click anywhere on the notification to dismiss it immediately.
    const gesture = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(gesture, 1);
    c.gtk_widget_add_controller(notif_box, gesture);
    _ = c.g_signal_connect(gesture, "pressed", @ptrCast(&onNotifClicked), null);

    return box;
}

fn createOsdSection() ?*anyopaque {
    const box = c.gtk_box_new(c.ORIENTATION_HORIZONTAL, 14);
    osd_box = box;
    c.gtk_widget_set_name(box, "island-osd");
    c.gtk_widget_set_size_request(box, EXPANDED_W, EXPANDED_H);
    c.gtk_widget_set_hexpand(box, 1);
    c.gtk_widget_set_valign(box, c.ALIGN_CENTER);
    c.gtk_widget_set_halign(box, c.ALIGN_CENTER);

    osd_icon = c.gtk_image_new();
    setImageIcon(osd_icon, "island-volume-high", "audio-volume-high-symbolic", 30);
    c.gtk_box_append(box, osd_icon);

    const right = c.gtk_box_new(c.ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_hexpand(right, 1);
    c.gtk_widget_set_valign(right, c.ALIGN_CENTER);

    osd_title_label = c.gtk_label_new("");
    c.gtk_widget_set_name(osd_title_label, "island-osd-title");
    c.gtk_widget_set_halign(osd_title_label, c.ALIGN_START);
    c.gtk_box_append(right, osd_title_label);

    osd_progress = c.gtk_progress_bar_new();
    c.gtk_widget_set_name(osd_progress, "island-osd-progress");
    c.gtk_widget_set_hexpand(osd_progress, 1);
    c.gtk_progress_bar_set_fraction(osd_progress, 0);
    c.gtk_progress_bar_set_show_text(osd_progress, 0);
    c.gtk_box_append(right, osd_progress);

    c.gtk_box_append(box, right);
    return box;
}

fn createShotSection() ?*anyopaque {
    const box = c.gtk_box_new(c.ORIENTATION_HORIZONTAL, 12);
    shot_box = box;
    c.gtk_widget_set_name(box, "island-shot");
    c.gtk_widget_set_size_request(box, EXPANDED_W, EXPANDED_H);
    c.gtk_widget_set_hexpand(box, 1);
    c.gtk_widget_set_valign(box, c.ALIGN_CENTER);

    // Screenshot thumbnail (rounded via the border-radius clip of GTK4).
    shot_image = c.gtk_image_new();
    c.gtk_widget_set_name(shot_image, "island-shot-image");
    c.gtk_widget_set_size_request(shot_image, 96, 96);
    setImageIcon(shot_image, "island-screenshot", "camera-photo-symbolic", 28);
    c.gtk_box_append(box, shot_image);

    // Right column: app label, title (filename), body, actions.
    const right = c.gtk_box_new(c.ORIENTATION_VERTICAL, 2);
    c.gtk_widget_set_valign(right, c.ALIGN_CENTER);
    c.gtk_widget_set_hexpand(right, 1);

    const app_lbl = c.gtk_label_new("Screenshot");
    c.gtk_widget_set_name(app_lbl, "island-notif-app"); // same blue caps label
    c.gtk_widget_set_halign(app_lbl, c.ALIGN_START);
    c.gtk_box_append(right, app_lbl);

    shot_title_label = c.gtk_label_new("");
    c.gtk_widget_set_name(shot_title_label, "island-shot-title");
    c.gtk_widget_set_halign(shot_title_label, c.ALIGN_START);
    c.gtk_label_set_ellipsize(shot_title_label, c.PANGO_ELLIPSIZE_END);
    c.gtk_box_append(right, shot_title_label);

    shot_body_label = c.gtk_label_new("");
    c.gtk_widget_set_name(shot_body_label, "island-shot-body");
    c.gtk_widget_set_halign(shot_body_label, c.ALIGN_START);
    c.gtk_label_set_ellipsize(shot_body_label, c.PANGO_ELLIPSIZE_END);
    c.gtk_box_append(right, shot_body_label);

    const controls = c.gtk_box_new(c.ORIENTATION_HORIZONTAL, 6);
    c.gtk_widget_set_name(controls, "island-shot-controls");
    c.gtk_widget_set_halign(controls, c.ALIGN_START);

    const copy_btn = makeIconButton("island-copy", "edit-copy-symbolic", 16);
    _ = c.g_signal_connect(copy_btn, "clicked", @ptrCast(&onShotCopy), null);
    c.gtk_box_append(controls, copy_btn);

    const open_btn = makeIconButton("island-open", "document-open-symbolic", 16);
    _ = c.g_signal_connect(open_btn, "clicked", @ptrCast(&onShotOpen), null);
    c.gtk_box_append(controls, open_btn);

    c.gtk_box_append(right, controls);
    c.gtk_box_append(box, right);
    return box;
}

/// Build the whole window and all sections. Safe to call once.
fn createIslandWindow() void {
    if (island_win != null) return;
    loadCss();

    const win = c.gtk_window_new();
    island_win = win;
    c.gtk_widget_set_name(win, "dockh-island");
    c.gtk_window_set_default_size(win, IDLE_W, IDLE_H);

    c.gtk_layer_init_for_window(win);
    c.gtk_layer_set_namespace(win, "dockh-island");
    c.gtk_layer_set_layer(win, c.LAYER_OVERLAY);
    c.gtk_layer_set_exclusive_zone(win, -1); // don't reserve space
    c.gtk_layer_set_anchor(win, c.EDGE_TOP, 1);

    if (islandMonitor()) |m| {
        c.gtk_layer_set_monitor(win, m);
        c.g_object_unref(m);
    }

    root_box = c.gtk_box_new(c.ORIENTATION_VERTICAL, 0);

    _ = createIdleSection();
    c.gtk_box_append(root_box, idle_box);

    _ = createMusicSection();
    c.gtk_widget_set_visible(music_box, 0);
    c.gtk_box_append(root_box, music_box);

    _ = createNotifSection();
    c.gtk_widget_set_visible(notif_box, 0);
    c.gtk_box_append(root_box, notif_box);

    _ = createOsdSection();
    c.gtk_widget_set_visible(osd_box, 0);
    c.gtk_box_append(root_box, osd_box);

    _ = createShotSection();
    c.gtk_widget_set_visible(shot_box, 0);
    c.gtk_box_append(root_box, shot_box);

    c.gtk_window_set_child(win, root_box);

    // Always visible from the start: a small pill with the clock.
    c.gtk_widget_show(win);
    // Center it NOW — setMode(.idle) would early-return (mode is already
    // .idle), leaving the pill stuck at the top-left corner.
    recenter();
    startClock();
}

// ---------------------------------------------------------------------------
// State machine
// ---------------------------------------------------------------------------

fn setMode(new_mode: Mode) void {
    if (mode == new_mode and island_win != null) return;
    mode = new_mode;

    if (island_win) |w| {
        if (new_mode == .idle) {
            c.gtk_widget_remove_css_class(w, "expanded");
            c.gtk_window_set_default_size(w, IDLE_W, IDLE_H);
        } else {
            c.gtk_widget_add_css_class(w, "expanded");
            c.gtk_window_set_default_size(w, EXPANDED_W, EXPANDED_H);
        }
    }

    const show_class: [:0]const u8 = "show";
    if (idle_box) |b| {
        c.gtk_widget_set_visible(b, if (new_mode == .idle) 1 else 0);
        if (new_mode != .idle) c.gtk_widget_remove_css_class(b, show_class.ptr);
    }
    if (music_box) |b| {
        c.gtk_widget_set_visible(b, if (new_mode == .music) 1 else 0);
        if (new_mode == .music) c.gtk_widget_add_css_class(b, show_class.ptr) else c.gtk_widget_remove_css_class(b, show_class.ptr);
    }
    if (notif_box) |b| {
        c.gtk_widget_set_visible(b, if (new_mode == .notif) 1 else 0);
        if (new_mode == .notif) c.gtk_widget_add_css_class(b, show_class.ptr) else c.gtk_widget_remove_css_class(b, show_class.ptr);
    }
    if (osd_box) |b| {
        c.gtk_widget_set_visible(b, if (new_mode == .osd) 1 else 0);
        if (new_mode == .osd) c.gtk_widget_add_css_class(b, show_class.ptr) else c.gtk_widget_remove_css_class(b, show_class.ptr);
    }
    if (shot_box) |b| {
        c.gtk_widget_set_visible(b, if (new_mode == .screenshot) 1 else 0);
        if (new_mode == .screenshot) c.gtk_widget_add_css_class(b, show_class.ptr) else c.gtk_widget_remove_css_class(b, show_class.ptr);
    }

    recenter();
}

fn cancelNotifTimer() void {
    if (notif_timer != 0) {
        _ = c.g_source_remove(notif_timer);
        notif_timer = 0;
    }
}

fn returnToPrev() void {
    // Return to music if a track is still playing, else the idle pill.
    if (was_playing) setMode(.music) else setMode(.idle);
}

fn onNotifTimeout(_: ?*anyopaque) callconv(.c) c_int {
    notif_timer = 0;
    returnToPrev();
    return 0;
}

fn onNotifClicked(_: ?*anyopaque, _: c_int, _: f64, _: f64, _: ?*anyopaque) callconv(.c) void {
    if (mode != .notif) return;
    cancelNotifTimer();
    returnToPrev();
}

// ---------------------------------------------------------------------------
// Idle clock
// ---------------------------------------------------------------------------

fn tickClock() void {
    if (clock_label == null) return;
    var now: i64 = 0;
    _ = c.time(&now);
    var tm: c.Tm = .{};
    if (c.localtime_r(&now, &tm) == null) return;
    var buf: [8]u8 = undefined;
    const n = c.strftime(&buf, buf.len, "%H:%M", &tm);
    if (n == 0) return;
    const z = state.alloc.dupeZ(u8, buf[0..n]) catch return;
    c.gtk_label_set_text(clock_label, z.ptr);
}

fn onClockTick(_: ?*anyopaque) callconv(.c) c_int {
    tickClock();
    return 1; // keep the timer
}

fn startClock() void {
    if (clock_timer != 0) return;
    tickClock();
    clock_timer = c.g_timeout_add(30_000, @ptrCast(&onClockTick), null);
}

// ---------------------------------------------------------------------------
// Playback controls
// ---------------------------------------------------------------------------

fn onPrevClicked(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    spawnArgv(&.{"playerctl", "previous"});
}

fn onPlayClicked(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    spawnArgv(&.{"playerctl", "play-pause"});
}

fn onNextClicked(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    spawnArgv(&.{"playerctl", "next"});
}

/// Run a shell command for a screenshot action: wl-copy feeds the file on
/// stdin, xdg-open takes the path as an argument. The path is embedded in
/// single quotes with POSIX escaping (' -> '\''), so a quote anywhere in
/// HOME/XDG dirs can't break or inject into the command.
fn shotShellCmd(comptime prefix: []const u8) void {
    if (last_shot_path.len == 0) return;
    var buf: [2048]u8 = undefined;
    var pos: usize = 0;
    if (prefix.len >= buf.len) return;
    @memcpy(buf[0..prefix.len], prefix);
    pos += prefix.len;
    buf[pos] = '\'';
    pos += 1;
    for (last_shot_path) |ch| {
        if (ch == '\'') {
            const esc = "'\\''";
            if (pos + esc.len >= buf.len) return;
            @memcpy(buf[pos .. pos + esc.len], esc);
            pos += esc.len;
        } else {
            if (pos + 1 >= buf.len) return;
            buf[pos] = ch;
            pos += 1;
        }
    }
    buf[pos] = '\'';
    pos += 1;
    buf[pos] = 0;
    spawnArgv(&.{ "sh", "-c", buf[0..pos :0] });
}

fn onShotCopy(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    shotShellCmd("wl-copy < ");
}

fn onShotOpen(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    shotShellCmd("xdg-open ");
}

fn spawnArgv(argv: []const []const u8) void {
    const launcher = c.g_subprocess_launcher_new(c.G_SPAWN_SEARCH_PATH);
    if (launcher == null) return;
    defer c.g_object_unref(launcher);

    var args: std.ArrayList(?[*:0]const u8) = .empty;
    defer args.deinit(state.alloc);
    for (argv) |a| {
        const z = state.alloc.dupeZ(u8, a) catch return;
        args.append(state.alloc, z.ptr) catch return;
    }
    args.append(state.alloc, null) catch {};

    var err: ?*anyopaque = null;
    const sub = c.g_subprocess_launcher_spawnv(launcher, args.items.ptr, &err);
    if (sub) |s| {
        c.g_object_unref(s);
    } else if (err) |e| {
        c.g_error_free(e);
    }
}

// ---------------------------------------------------------------------------
// Public API — called from status.zig and main.zig
// ---------------------------------------------------------------------------

/// Create the window up front so the pill is on screen immediately. Called
/// once from main.zig after the dock window is set up.
pub fn setup() void {
    if (!state.cfg.island_enabled) return;
    createIslandWindow();
    log.debug("island: always-visible pill up (clock + battery + music/notif/osd)", .{});
}

/// Load album art from a `file://` path (playerctl mpris:artUrl). Non-file
/// URLs (http) are skipped — the placeholder stays. Returns true when the
/// image changed.
fn setAlbumArt(path: []const u8) bool {
    if (art_image == null) return false;
    if (std.mem.eql(u8, last_art_path, path)) return false;
    if (std.mem.startsWith(u8, path, "file://")) {
        const p = path["file://".len..];
        if (p.len == 0) return false;
        // Keep an OWNED copy of the path for the next comparison — the input
        // slice lives in status.zig's scratch buffer.
        last_art_path = state.alloc.dupe(u8, path) catch return false;
        const z = state.alloc.dupeZ(u8, p) catch return false;
        c.gtk_image_set_from_file(art_image, z.ptr);
        c.gtk_image_set_pixel_size(art_image, 56);
        return true;
    }
    // Empty or non-file: reset to the placeholder.
    last_art_path = "";
    setImageIcon(art_image, "island-album-placeholder", "audio-x-generic-symbolic", 24);
    return true;
}

/// Update the island with new music metadata. `status` is the playerctl
/// status ("Playing", "Paused", "Stopped"); `album_art` is mpris:artUrl.
pub fn updateMusic(title: []const u8, artist: []const u8, status: []const u8, album_art: []const u8) void {
    if (!state.cfg.island_enabled) return;
    if (island_win == null) createIslandWindow();

    const playing = std.mem.eql(u8, status, "Playing");
    const has_track = title.len > 0 or playing;

    // Refresh labels only when they actually change (avoids per-second
    // arena churn from the 1s playerctl poll). Keep owned copies.
    if (music_title_label) |lbl| {
        if (!std.mem.eql(u8, last_title, title)) {
            last_title = state.alloc.dupe(u8, title) catch return;
            const shown = if (title.len > 0) last_title else "Not playing";
            const z = state.alloc.dupeZ(u8, shown) catch return;
            c.gtk_label_set_text(lbl, z.ptr);
        }
    }
    if (music_artist_label) |lbl| {
        if (!std.mem.eql(u8, last_artist, artist)) {
            last_artist = state.alloc.dupe(u8, artist) catch return;
            const z = state.alloc.dupeZ(u8, last_artist) catch return;
            c.gtk_label_set_text(lbl, z.ptr);
        }
    }
    _ = setAlbumArt(album_art);

    // Play/pause icon follows the player state — only touch it on a toggle.
    if (playing != last_playing) {
        last_playing = playing;
        if (music_play_btn) |btn| {
            const child = c.gtk_widget_get_first_child(btn);
            if (child) |img| {
                if (playing) {
                    setImageIcon(img, "island-pause", "media-playback-pause-symbolic", 22);
                } else {
                    setImageIcon(img, "island-play", "media-playback-start-symbolic", 22);
                }
            }
        }
    }

    // Transient modes (notif/osd) keep the stage until their timer fires —
    // the music data updates underneath them.
    if (mode == .notif or mode == .osd) {
        was_playing = playing;
        return;
    }
    if (has_track) {
        was_playing = playing;
        if (mode != .music) setMode(.music);
    } else if (mode == .music and !playing) {
        was_playing = false;
        setMode(.idle);
    }
}

/// Update the music progress bar (0.0 – 1.0).
pub fn updateMusicProgress(fraction: f64) void {
    if (!state.cfg.island_enabled) return;
    if (music_progress_bar) |bar| {
        c.gtk_progress_bar_set_fraction(bar, @max(0.0, @min(1.0, fraction)));
    }
}

/// Pop a notification out of the island. `icon` is the icon id (mako's
/// app-icon, or the app name as fallback); `app` is the app name shown as a
/// small label. Auto-dismisses after 5s, click to dismiss immediately.
pub fn showNotification(app: []const u8, icon: []const u8, title_text: []const u8, body: []const u8) void {
    if (!state.cfg.island_enabled) return;
    if (island_win == null) createIslandWindow();
    log.info("island: notification from {s}: {s}", .{ app, title_text });

    if (notif_app_label) |lbl| {
        const z = state.alloc.dupeZ(u8, app) catch return;
        c.gtk_label_set_text(lbl, z.ptr);
    }
    if (notif_title_label) |lbl| {
        const z = state.alloc.dupeZ(u8, title_text) catch return;
        c.gtk_label_set_text(lbl, z.ptr);
    }
    if (notif_body_label) |lbl| {
        const z = state.alloc.dupeZ(u8, body) catch return;
        c.gtk_label_set_text(lbl, z.ptr);
    }

    // Icon: prefer a custom SVG for the well-known slots (battery warning),
    // else use the app icon by name; a generic bell is the last resort.
    // When the icon is a FILE PATH (mako app-icon can carry one, e.g. the
    // omarchy screenshot script passes the screenshot path) load the image
    // instead of resolving an icon name.
    if (notif_icon) |img| {
        if (icon.len > 0) {
            if (std.mem.eql(u8, icon, "battery-low-symbolic")) {
                setImageIcon(img, "island-battery-low", icon, 22);
            } else if (isImagePath(icon)) {
                const z = state.alloc.dupeZ(u8, icon) catch "";
                if (z.len > 0) c.gtk_image_set_from_file(img, z.ptr);
                c.gtk_image_set_pixel_size(img, 22);
            } else {
                const z = state.alloc.dupeZ(u8, icon) catch "";
                if (z.len > 0) c.gtk_image_set_from_icon_name(img, z.ptr);
                c.gtk_image_set_pixel_size(img, 22);
            }
        } else {
            setImageIcon(img, "island-notif", "dialog-information-symbolic", 22);
        }
    }

    was_playing = mode == .music;
    setMode(.notif);
    cancelNotifTimer();
    notif_timer = c.g_timeout_add(5000, @ptrCast(&onNotifTimeout), null);
}

/// Show a slim OSD slider (volume / brightness). Auto-dismisses after 1.5s.
pub fn showOsd(icon: []const u8, title_text: []const u8, fraction: f64) void {
    if (!state.cfg.island_enabled) return;
    if (island_win == null) createIslandWindow();

    if (osd_icon) |img| {
        // OSD icons: volume (muted/low/high) and brightness each have a custom
        // SVG slot, with the theme icon as fallback.
        const svg_name: []const u8 = if (std.mem.indexOf(u8, icon, "muted") != null)
            "island-volume-muted"
        else if (std.mem.indexOf(u8, icon, "low") != null)
            "island-volume-low"
        else if (std.mem.indexOf(u8, icon, "brightness") != null)
            "island-brightness"
        else
            "island-volume-high";
        setImageIcon(img, svg_name, icon, 30);
    }
    if (osd_title_label) |lbl| {
        const z = state.alloc.dupeZ(u8, title_text) catch return;
        c.gtk_label_set_text(lbl, z.ptr);
    }
    if (osd_progress) |bar| {
        c.gtk_progress_bar_set_fraction(bar, @max(0.0, @min(1.0, fraction)));
    }

    was_playing = mode == .music;
    setMode(.osd);
    cancelNotifTimer();
    notif_timer = c.g_timeout_add(1500, @ptrCast(&onNotifTimeout), null);
}

/// True when `s` looks like a file path rather than an icon name: an absolute
/// path, a home-relative path or a file:// URL.
fn isImagePath(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "/") or
        std.mem.startsWith(u8, s, "~/") or
        std.mem.startsWith(u8, s, "file://");
}

/// Pop the screenshot state out of the island: thumbnail preview of the new
/// screenshot, the filename, and copy/open actions. Deduped by path so the
/// two detection paths (screenshot-file poll + mako app-icon path) race
/// safely — the second call for the same file is a no-op. Auto-dismisses
/// after 6s back to music (if playing) or the idle pill.
/// True when `path` exists and already has content (grim may still be
/// writing the file when the mako notification lands — refuse to render a
/// partial PNG; the file poll retries a second later).
fn fileNonEmpty(path: []const u8) bool {
    const z = state.alloc.dupeZ(u8, path) catch return false;
    const f = c.fopen(z.ptr, "r") orelse return false;
    defer _ = c.fclose(f);
    if (c.fseek(f, 0, c.SEEK_END) != 0) return false;
    return c.ftell(f) > 0;
}

pub fn showScreenshot(path: []const u8) void {
    if (!state.cfg.island_enabled) return;
    if (island_win == null) createIslandWindow();
    if (std.mem.eql(u8, last_shot_path, path)) return; // already shown
    // Refuse to show a file that isn't there yet (grim may still be writing
    // when the notification lands) — don't mark it shown, so the retry via
    // the file poll picks it up a second later.
    if (!fileNonEmpty(path)) return;

    log.info("island: screenshot {s}", .{path});
    last_shot_path = state.alloc.dupe(u8, path) catch return;

    const base = std.fs.path.basename(path);
    if (shot_title_label) |lbl| {
        const z = state.alloc.dupeZ(u8, base) catch return;
        c.gtk_label_set_text(lbl, z.ptr);
    }
    if (shot_body_label) |lbl| {
        const z = state.alloc.dupeZ(u8, "Saved to clipboard and file") catch return;
        c.gtk_label_set_text(lbl, z.ptr);
    }
    if (shot_image) |img| {
        const z = state.alloc.dupeZ(u8, path) catch return;
        c.gtk_image_set_from_file(img, z.ptr);
        c.gtk_image_set_pixel_size(img, 96);
    }

    was_playing = mode == .music;
    setMode(.screenshot);
    cancelNotifTimer();
    notif_timer = c.g_timeout_add(6000, @ptrCast(&onNotifTimeout), null);
}

/// Update the idle battery label and warn once when crossing 20% while
/// discharging. `pct` in 0..100, `present` false hides the label entirely.
pub fn setBattery(pct: i32, charging: bool, present: bool) void {
    if (!state.cfg.island_enabled) return;
    if (battery_label == null) return;

    const same = pct == last_battery_pct and charging == last_battery_charging;
    if (same and !charging) return; // unchanged
    last_battery_pct = pct;
    last_battery_charging = charging;

    if (!present) {
        c.gtk_widget_set_visible(battery_label, 0);
        battery_warned = false;
        return;
    }

    c.gtk_widget_set_visible(battery_label, 1);
    const txt = std.fmt.allocPrint(state.alloc, "{d}%", .{pct}) catch return;
    const z = state.alloc.dupeZ(u8, txt) catch return;
    c.gtk_label_set_text(battery_label, z.ptr);

    // Color states: normal / low (< 20%) / critical (< 10%).
    if (battery_label) |lbl| {
        c.gtk_widget_remove_css_class(lbl, "low");
        c.gtk_widget_remove_css_class(lbl, "critical");
        if (pct <= 10) {
            c.gtk_widget_add_css_class(lbl, "critical");
        } else if (pct <= 20) {
            c.gtk_widget_add_css_class(lbl, "low");
        }
    }

    // One-shot low-battery warning when crossing 20% while discharging.
    if (pct <= 20 and !charging and !battery_warned) {
        battery_warned = true;
        // "battery-low-symbolic" maps to the island-battery-low.svg slot inside
        // showNotification; falls back to the theme icon when no SVG exists.
        showNotification("battery", "battery-low-symbolic", "Battery low", std.fmt.allocPrint(state.alloc, "{d}% remaining — plug in soon.", .{pct}) catch "");
    } else if (pct > 25 or charging) {
        battery_warned = false;
    }
}

/// Tear down timers. The window is destroyed with the process.
pub fn deinit() void {
    cancelNotifTimer();
    if (clock_timer != 0) {
        _ = c.g_source_remove(clock_timer);
        clock_timer = 0;
    }
}
