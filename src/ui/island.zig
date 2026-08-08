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

const Mode = enum { idle, music, music_min, notif, osd, screenshot };

var island_win: ?*anyopaque = null;
var root_box: ?*anyopaque = null;
var mode: Mode = .idle;

// Idle pill — empty black capsule, like the macOS notch
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
var music_pos_label: ?*anyopaque = null;
var music_remain_label: ?*anyopaque = null;
var music_airplay_btn: ?*anyopaque = null;

// Compact music mode — wide banner: spinning round cover on the left,
// animated equalizer on the right (hover to expand)
var min_box: ?*anyopaque = null;
var min_art_image: ?*anyopaque = null;
var shrink_timer: c_uint = 0;
var hovering = false;

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
var last_art_path: []const u8 = ""; // art source currently handled (file:// path or http URL)
var last_art_file: []const u8 = ""; // cache file actually displayed (avoids re-decoding every poll)
var last_art_attempt: i64 = 0; // unix seconds of the last download attempt (retry backoff)
var art_dir_ready = false;
var last_playing = false;
var was_playing = false;
var notif_timer: c_uint = 0;
var battery_warned = false;
var last_battery_pct: i32 = -1;
var last_battery_charging = false;

// ---------------------------------------------------------------------------
// Sizing (logical px)
// ---------------------------------------------------------------------------

const IDLE_W: c_int = 132;
const IDLE_H: c_int = 36;
const EXPANDED_W: c_int = 380;
const EXPANDED_H: c_int = 176;
const MIN_W: c_int = 280; // compact banner: art left, equalizer right
const MIN_H: c_int = 52;
const MIN_ART: c_int = 52; // spinning round cover — full banner height

// ---------------------------------------------------------------------------
// CSS — the island ships its own stylesheet so it looks right even before the
// user has a config/style.css, and overrides (ID selectors) win naturally.
// ---------------------------------------------------------------------------

const island_css =
    \\/* OpenAI black/white: solid dark pill, no gradients, hairline border. */
    \\#dockh-island {
    \\    background-color: #0a0a0c;
    \\    border: 1px solid rgba(255, 255, 255, 0.12);
    \\    border-radius: 999px;
    \\    box-shadow: 0 10px 32px rgba(0, 0, 0, 0.55);
    \\    transition: all 280ms cubic-bezier(0.34, 1.4, 0.64, 1);
    \\    font-family: 'SF Pro Text', 'Inter', 'Noto Sans', sans-serif;
    \\}
    \\#dockh-island.expanded {
    \\    border-radius: 42px;
    \\}
    \\/* Sections fit content; padding keeps text off the capsule border. */
    \\#island-music, #island-notif, #island-osd, #island-shot {
    \\    padding: 12px;
    \\}
    \\
    \\@keyframes island-pop {
    \\    from { opacity: 0; }
    \\    to   { opacity: 1; }
    \\}
    \\#island-music.show, #island-notif.show, #island-osd.show,
    \\#island-shot.show, #island-music-min.show {
    \\    animation: island-pop 220ms ease-out;
    \\}
    \\
    \\#island-clock {
    \\    color: #ffffff;
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
    \\    border-radius: 10px;
    \\    background-color: rgba(255, 255, 255, 0.08);
    \\    border: 1px solid rgba(255, 255, 255, 0.10);
    \\}
    \\#island-song-title {
    \\    color: #ffffff;
    \\    font-weight: 600;
    \\    font-size: 16px;
    \\    letter-spacing: -0.4px;
    \\}
    \\#island-song-artist {
    \\    color: #9A9A9A;
    \\    font-size: 14px;
    \\}
    \\
    \\/* Equalizer: pink → light blue gradient bars, opacity pulse (GTK-safe). */
    \\#island-viz {
    \\    margin-top: 2px;
    \\}
    \\#island-viz-bar {
    \\    min-width: 3px;
    \\    min-height: 14px;
    \\    border-radius: 2px;
    \\    animation: island-viz 1.1s ease-in-out infinite;
    \\}
    \\#island-viz-bar:nth-child(1) { background-color: #F84BAB; animation-delay: 0ms; }
    \\#island-viz-bar:nth-child(2) { background-color: #EC5DB0; animation-delay: 180ms; }
    \\#island-viz-bar:nth-child(3) { background-color: #D475BC; animation-delay: 360ms; }
    \\#island-viz-bar:nth-child(4) { background-color: #B09CD7; animation-delay: 540ms; }
    \\#island-viz-bar:nth-child(5) { background-color: #B4CDFB; animation-delay: 720ms; }
    \\@keyframes island-viz {
    \\    0%, 100% { opacity: 0.3; }
    \\    50%      { opacity: 1; }
    \\}
    \\
    \\#island-time {
    \\    color: #9A9A9A;
    \\    font-size: 12px;
    \\    font-variant-numeric: tabular-nums;
    \\}
    \\#island-time.remaining {
    \\    color: #9A9A9A;
    \\}
    \\
    \\#island-music-controls button, #island-shot-controls button, #island-airplay-btn {
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
    \\#island-music-controls button:hover, #island-shot-controls button:hover, #island-airplay-btn:hover {
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
    \\    min-height: 6px;
    \\    margin: 2px 4px;
    \\    background-color: rgba(63, 63, 63, 0.7);
    \\    border-radius: 8px;
    \\}
    \\#island-progress > trough > progress {
    \\    background-color: rgba(255, 255, 255, 0.8);
    \\    border-radius: 8px;
    \\    min-height: 6px;
    \\}
    \\
    \\#island-notif-icon {
    \\    border-radius: 10px;
    \\}
    \\#island-notif-app {
    \\    color: rgba(255, 255, 255, 0.75);
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
    \\    background-color: rgba(255, 255, 255, 0.14);
    \\    border-radius: 999px;
    \\}
    \\#island-osd-progress > trough > progress {
    \\    background-color: #e8e8ea;
    \\    border-radius: 999px;
    \\    min-height: 6px;
    \\}
    \\
    \\#island-shot-image {
    \\    border-radius: 12px;
    \\    background-color: rgba(255, 255, 255, 0.06);
    \\    border: 1px solid rgba(255, 255, 255, 0.10);
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
    \\
    \\/* Compact banner: spinning round cover left, equalizer right. */
    \\#island-music-min {
    \\    background-color: #0a0a0c;
    \\    border: 1px solid rgba(255, 255, 255, 0.12);
    \\    border-radius: 999px;
    \\}
    \\#island-min-art {
    \\    border-radius: 999px;
    \\    animation: island-spin 8s linear infinite;
    \\}
    \\#island-music-min.paused #island-min-art {
    \\    animation-play-state: paused;
    \\}
    \\@keyframes island-spin {
    \\    from { transform: rotate(0deg); }
    \\    to   { transform: rotate(360deg); }
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
    // Empty black capsule — clean "nothing playing" state, like macOS.
    const box = c.gtk_box_new(c.ORIENTATION_HORIZONTAL, 0);
    idle_box = box;
    // Layer-shell windows size to content; a fixed size request keeps the
    // pill shape even if the compositor ignores gtk_window_set_default_size.
    c.gtk_widget_set_size_request(box, IDLE_W, IDLE_H);
    c.gtk_widget_set_halign(box, c.ALIGN_CENTER);
    c.gtk_widget_set_valign(box, c.ALIGN_CENTER);
    return box;
}

/// 5-bar animated equalizer, pink → light blue gradient (the island's one
/// accent element — the "audio" glyph from the SF Pro design, drawn as bars).
fn makeViz() ?*anyopaque {
    const viz = c.gtk_box_new(c.ORIENTATION_HORIZONTAL, 3);
    c.gtk_widget_set_name(viz, "island-viz");
    c.gtk_widget_set_valign(viz, c.ALIGN_CENTER);
    var vi: usize = 0;
    while (vi < 5) : (vi += 1) {
        const bar = c.gtk_box_new(c.ORIENTATION_HORIZONTAL, 0);
        c.gtk_widget_set_name(bar, "island-viz-bar");
        c.gtk_box_append(viz, bar);
    }
    return viz;
}

/// Expanded player (hover): per the Figma spec — black pill radius 42,
/// metadata row (art | title/artist | equalizer), progress row with times,
/// controls spread with space-between (prev/play/next centered + airplay).
fn createMusicSection() ?*anyopaque {
    const box = c.gtk_box_new(c.ORIENTATION_VERTICAL, 0);
    music_box = box;
    c.gtk_widget_set_name(box, "island-music");
    c.gtk_widget_set_valign(box, c.ALIGN_CENTER);

    // metadata row: art | title/artist | equalizer
    const row_top = c.gtk_box_new(c.ORIENTATION_HORIZONTAL, 12);
    c.gtk_widget_set_halign(row_top, c.ALIGN_CENTER);
    c.gtk_widget_set_valign(row_top, c.ALIGN_CENTER);

    art_wrap = c.gtk_box_new(c.ORIENTATION_HORIZONTAL, 0);
    c.gtk_widget_set_name(art_wrap, "island-art-wrap");
    c.gtk_widget_set_size_request(art_wrap, 56, 56);
    art_image = c.gtk_image_new();
    c.gtk_widget_set_size_request(art_image, 56, 56);
    setImageIcon(art_image, "island-album-placeholder", "audio-x-generic-symbolic", 24);
    c.gtk_box_append(art_wrap, art_image);
    c.gtk_box_append(row_top, art_wrap);

    const mid = c.gtk_box_new(c.ORIENTATION_VERTICAL, 2);
    c.gtk_widget_set_valign(mid, c.ALIGN_CENTER);
    c.gtk_widget_set_hexpand(mid, 1);

    music_title_label = c.gtk_label_new("");
    c.gtk_widget_set_name(music_title_label, "island-song-title");
    c.gtk_widget_set_halign(music_title_label, c.ALIGN_START);
    c.gtk_label_set_ellipsize(music_title_label, c.PANGO_ELLIPSIZE_END);
    c.gtk_label_set_max_width_chars(music_title_label, 26);
    c.gtk_box_append(mid, music_title_label);

    music_artist_label = c.gtk_label_new("");
    c.gtk_widget_set_name(music_artist_label, "island-song-artist");
    c.gtk_widget_set_halign(music_artist_label, c.ALIGN_START);
    c.gtk_label_set_ellipsize(music_artist_label, c.PANGO_ELLIPSIZE_END);
    c.gtk_label_set_max_width_chars(music_artist_label, 30);
    c.gtk_box_append(mid, music_artist_label);

    c.gtk_box_append(row_top, mid);
    c.gtk_box_append(row_top, makeViz());
    c.gtk_box_append(box, row_top);

    // progress row: current | bar | remaining
    const row_prog = c.gtk_box_new(c.ORIENTATION_HORIZONTAL, 9);
    c.gtk_widget_set_hexpand(row_prog, 1);
    c.gtk_widget_set_valign(row_prog, c.ALIGN_CENTER);
    c.gtk_widget_set_margin_top(row_prog, 9);
    music_pos_label = c.gtk_label_new("0:00");
    c.gtk_widget_set_name(music_pos_label, "island-time");
    c.gtk_widget_set_valign(music_pos_label, c.ALIGN_CENTER);
    c.gtk_box_append(row_prog, music_pos_label);

    music_progress_bar = c.gtk_progress_bar_new();
    c.gtk_widget_set_name(music_progress_bar, "island-progress");
    c.gtk_widget_set_hexpand(music_progress_bar, 1);
    c.gtk_progress_bar_set_fraction(music_progress_bar, 0);
    c.gtk_progress_bar_set_show_text(music_progress_bar, 0);
    c.gtk_box_append(row_prog, music_progress_bar);

    music_remain_label = c.gtk_label_new("-0:00");
    c.gtk_widget_set_name(music_remain_label, "island-time");
    c.gtk_widget_add_css_class(music_remain_label, "remaining");
    c.gtk_widget_set_valign(music_remain_label, c.ALIGN_CENTER);
    c.gtk_box_append(row_prog, music_remain_label);
    c.gtk_box_append(box, row_prog);

    // controls row: spacer | prev/play/next centered | airplay (space-between)
    const row_ctl = c.gtk_box_new(c.ORIENTATION_HORIZONTAL, 0);
    c.gtk_widget_set_margin_top(row_ctl, 9);

    const spacer = c.gtk_box_new(c.ORIENTATION_HORIZONTAL, 0);
    c.gtk_widget_set_size_request(spacer, 34, 1);
    c.gtk_box_append(row_ctl, spacer);

    const controls = c.gtk_box_new(c.ORIENTATION_HORIZONTAL, 36);
    c.gtk_widget_set_name(controls, "island-music-controls");
    c.gtk_widget_set_halign(controls, c.ALIGN_CENTER);
    c.gtk_widget_set_hexpand(controls, 1);

    music_prev_btn = makeIconButton("island-prev", "media-skip-backward-symbolic", 20);
    _ = c.g_signal_connect(music_prev_btn, "clicked", @ptrCast(&onPrevClicked), null);
    c.gtk_box_append(controls, music_prev_btn);

    music_play_btn = makeIconButton("island-play", "media-playback-start-symbolic", 30);
    c.gtk_widget_set_name(music_play_btn, "island-play-btn");
    _ = c.g_signal_connect(music_play_btn, "clicked", @ptrCast(&onPlayClicked), null);
    c.gtk_box_append(controls, music_play_btn);

    music_next_btn = makeIconButton("island-next", "media-skip-forward-symbolic", 20);
    _ = c.g_signal_connect(music_next_btn, "clicked", @ptrCast(&onNextClicked), null);
    c.gtk_box_append(controls, music_next_btn);

    c.gtk_box_append(row_ctl, controls);

    music_airplay_btn = makeIconButton("island-airplay", "network-wireless-symbolic", 20);
    c.gtk_widget_set_name(music_airplay_btn, "island-airplay-btn");
    c.gtk_widget_set_valign(music_airplay_btn, c.ALIGN_CENTER);
    c.gtk_box_append(row_ctl, music_airplay_btn);
    c.gtk_box_append(box, row_ctl);

    return box;
}

/// Compact music banner (the "normal" state with music): spinning round cover
/// on the left, blank middle, animated equalizer on the right — like the
/// reference. Hovering it expands the full player.
fn createMinSection() ?*anyopaque {
    const box = c.gtk_box_new(c.ORIENTATION_HORIZONTAL, 0);
    min_box = box;
    c.gtk_widget_set_name(box, "island-music-min");
    c.gtk_widget_set_size_request(box, MIN_W, MIN_H);
    c.gtk_widget_set_halign(box, c.ALIGN_CENTER);
    c.gtk_widget_set_valign(box, c.ALIGN_CENTER);

    min_art_image = c.gtk_image_new();
    c.gtk_widget_set_name(min_art_image, "island-min-art");
    c.gtk_widget_set_size_request(min_art_image, MIN_ART, MIN_ART);
    c.gtk_widget_set_margin_start(min_art_image, 4);
    setImageIcon(min_art_image, "island-album-placeholder", "audio-x-generic-symbolic", 24);
    c.gtk_box_append(box, min_art_image);

    // blank middle — the equalizer floats at the right edge
    const spacer = c.gtk_box_new(c.ORIENTATION_HORIZONTAL, 0);
    c.gtk_widget_set_hexpand(spacer, 1);
    c.gtk_box_append(box, spacer);

    const viz = makeViz();
    c.gtk_widget_set_margin_end(viz, 18);
    c.gtk_box_append(box, viz);
    return box;
}

fn createNotifSection() ?*anyopaque {
    const box = c.gtk_box_new(c.ORIENTATION_HORIZONTAL, 12);
    notif_box = box;
    c.gtk_widget_set_name(box, "island-notif");
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
    c.gtk_label_set_max_width_chars(notif_app_label, 12);
    c.gtk_box_append(text_box, notif_app_label);

    notif_title_label = c.gtk_label_new("");
    c.gtk_widget_set_name(notif_title_label, "island-notif-title");
    c.gtk_widget_set_halign(notif_title_label, c.ALIGN_START);
    c.gtk_label_set_ellipsize(notif_title_label, c.PANGO_ELLIPSIZE_END);
    c.gtk_label_set_max_width_chars(notif_title_label, 30);
    c.gtk_box_append(text_box, notif_title_label);

    notif_body_label = c.gtk_label_new("");
    c.gtk_widget_set_name(notif_body_label, "island-notif-body");
    c.gtk_widget_set_halign(notif_body_label, c.ALIGN_START);
    c.gtk_label_set_ellipsize(notif_body_label, c.PANGO_ELLIPSIZE_END);
    c.gtk_label_set_max_width_chars(notif_body_label, 34);
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
    c.gtk_widget_set_size_request(osd_progress, 200, -1); // usable slider width
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
    c.gtk_widget_set_valign(box, c.ALIGN_CENTER);

    // Screenshot thumbnail (rounded via the border-radius clip of GTK4).
    // Clicking it copies the image straight to the clipboard (macOS-style).
    shot_image = c.gtk_image_new();
    c.gtk_widget_set_name(shot_image, "island-shot-image");
    c.gtk_widget_set_size_request(shot_image, 96, 96);
    setImageIcon(shot_image, "island-screenshot", "camera-photo-symbolic", 28);
    c.gtk_widget_set_cursor_from_name(shot_image, "pointer");
    const shot_gesture = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(shot_gesture, 1);
    c.gtk_widget_add_controller(shot_image, shot_gesture);
    _ = c.g_signal_connect(shot_gesture, "pressed", @ptrCast(&onShotThumbClicked), null);
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
    c.gtk_label_set_max_width_chars(shot_title_label, 26);
    c.gtk_box_append(right, shot_title_label);

    shot_body_label = c.gtk_label_new("");
    c.gtk_widget_set_name(shot_body_label, "island-shot-body");
    c.gtk_widget_set_halign(shot_body_label, c.ALIGN_START);
    c.gtk_label_set_ellipsize(shot_body_label, c.PANGO_ELLIPSIZE_END);
    c.gtk_label_set_max_width_chars(shot_body_label, 34);
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

    _ = createMinSection();
    c.gtk_widget_set_visible(min_box, 0);
    c.gtk_box_append(root_box, min_box);

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

    // Hover: the compact spinning pill expands to the full player on hover,
    // and the full player shrinks back after a few seconds without hover.
    const motion = c.gtk_event_controller_motion_new();
    c.gtk_widget_add_controller(win, motion);
    _ = c.g_signal_connect(motion, "enter", @ptrCast(&onIslandEnter), null);
    _ = c.g_signal_connect(motion, "leave", @ptrCast(&onIslandLeave), null);

    // Always visible from the start: the small empty black pill.
    c.gtk_widget_show(win);
    // Center it NOW — setMode(.idle) would early-return (mode is already
    // .idle), leaving the pill stuck at the top-left corner.
    recenter();
}

// ---------------------------------------------------------------------------
// State machine
// ---------------------------------------------------------------------------

fn setMode(new_mode: Mode) void {
    if (mode == new_mode and island_win != null) return;
    log.debug("island: mode {} -> {}", .{ mode, new_mode });
    mode = new_mode;

    if (island_win) |w| {
        const expanded = new_mode != .idle and new_mode != .music_min;
        if (expanded) {
            c.gtk_widget_add_css_class(w, "expanded");
            // No fixed size: the window fits the section's content (8px
            // padding, capped by the CSS max-width rules).
            c.gtk_window_set_default_size(w, -1, -1);
        } else {
            c.gtk_widget_remove_css_class(w, "expanded");
            c.gtk_window_set_default_size(w, if (new_mode == .music_min) MIN_W else IDLE_W, if (new_mode == .music_min) MIN_H else IDLE_H);
        }
        // Behind apps normally (TOP layer = under windows); only transient
        // pop-outs (notif / osd / screenshot) rise to the overlay layer.
        const overlay = new_mode == .notif or new_mode == .osd or new_mode == .screenshot;
        c.gtk_layer_set_layer(w, if (overlay) c.LAYER_OVERLAY else c.LAYER_TOP);
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
    if (min_box) |b| {
        c.gtk_widget_set_visible(b, if (new_mode == .music_min) 1 else 0);
        if (new_mode == .music_min) c.gtk_widget_add_css_class(b, show_class.ptr) else c.gtk_widget_remove_css_class(b, show_class.ptr);
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

    // Auto-shrink: the full player collapses to the spinning cover after a
    // few seconds of no hover; any other mode cancels that plan.
    if (new_mode == .music) startShrinkTimer() else cancelShrinkTimer();

    recenter();
}

fn cancelNotifTimer() void {
    if (notif_timer != 0) {
        _ = c.g_source_remove(notif_timer);
        notif_timer = 0;
    }
}

fn cancelShrinkTimer() void {
    if (shrink_timer != 0) {
        _ = c.g_source_remove(shrink_timer);
        shrink_timer = 0;
    }
}

fn onShrinkTimeout(_: ?*anyopaque) callconv(.c) c_int {
    shrink_timer = 0;
    log.debug("island: shrink tick (mode={}, hovering={})", .{ mode, hovering });
    if (mode == .music and !hovering) setMode(.music_min);
    return 0;
}

/// Schedule the full player → spinning cover collapse, unless the pointer is
/// already resting on the island (then it stays expanded).
fn startShrinkTimer() void {
    cancelShrinkTimer();
    if (mode != .music or hovering) return;
    shrink_timer = c.g_timeout_add(4000, @ptrCast(&onShrinkTimeout), null);
}

fn onIslandEnter(_: ?*anyopaque, _: f64, _: f64, _: ?*anyopaque) callconv(.c) void {
    hovering = true;
    log.debug("island: hover enter (mode={})", .{mode});
    if (mode == .music_min) {
        setMode(.music); // hover the vinyl → full player
    } else if (mode == .music) {
        startShrinkTimer(); // keep it open while hovering
    }
}

fn onIslandLeave(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    hovering = false;
    log.debug("island: hover leave (mode={})", .{mode});
    if (mode == .music) startShrinkTimer(); // shrink again after the delay
}

fn returnToPrev() void {
    // Return to the player if a track is still playing, else the idle pill.
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
/// single quotes with POSIX escaping (via appendShellQuoted).
fn shotShellCmd(comptime prefix: []const u8) void {
    if (last_shot_path.len == 0) return;
    var buf: [2048]u8 = undefined;
    var pos: usize = 0;
    if (prefix.len >= buf.len) return;
    @memcpy(buf[0..prefix.len], prefix);
    pos += prefix.len;
    if (!appendShellQuoted(&buf, &pos, last_shot_path)) return;
    if (pos >= buf.len) return;
    buf[pos] = 0;
    spawnArgv(&.{ "sh", "-c", buf[0..pos :0] });
}

fn onShotCopy(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    shotShellCmd("wl-copy < ");
}

fn onShotOpen(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    shotShellCmd("xdg-open ");
}

/// Click on the screenshot thumbnail: copy the image to the clipboard and
/// dismiss the island (macOS behavior).
fn onShotThumbClicked(_: ?*anyopaque, _: c_int, _: f64, _: f64, _: ?*anyopaque) callconv(.c) void {
    if (mode != .screenshot) return;
    shotShellCmd("wl-copy < ");
    cancelNotifTimer();
    returnToPrev();
}

fn spawnArgv(argv: []const []const u8) void {
    // STDERR_SILENCE keeps command noise (curl progress, playerctl warnings)
    // out of the log. NO STDOUT_PIPE: this is a fire-and-forget spawn whose
    // GSubprocess is unref'd immediately — a stdout pipe would be closed on
    // finalize and (for a live child) risks SIGPIPE killing the download.
    const launcher = c.g_subprocess_launcher_new(c.G_SUBPROCESS_FLAGS_STDERR_SILENCE);
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
        const ge: *const c.GError = @ptrCast(@alignCast(e));
        log.info("island: spawn failed: {s}", .{std.mem.span(ge.message)});
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

/// Cache directory for downloaded album art: $XDG_CACHE_HOME/dockh (default
/// ~/.cache/dockh).
fn artCacheDir() []const u8 {
    if (envVal("XDG_CACHE_HOME")) |d| {
        return std.fmt.allocPrint(state.alloc, "{s}/dockh", .{d}) catch "/tmp";
    }
    const home = envVal("HOME") orelse "/";
    return std.fmt.allocPrint(state.alloc, "{s}/.cache/dockh", .{home}) catch "/tmp";
}

/// Deterministic cache path for a remote art URL: art-<wyhash-hex>. gdk-pixbuf
/// sniffs image content, so the extensionless file loads fine whatever the
/// format (png/jpeg/webp). Ensures the cache dir exists.
fn artCachePath(url: []const u8) ?[]const u8 {
    const dir = artCacheDir();
    if (!art_dir_ready) art_dir_ready = fs.ensureDir(dir); // mkdir once, not every poll
    var h = std.hash.Wyhash.init(0x5eed);
    h.update(url);
    const digest = h.final();
    return std.fmt.allocPrint(state.alloc, "{s}/art-{x:0>16}", .{ dir, digest }) catch null;
}

/// Download `url` into the cache with a DETACHED curl: the 1s status poll
/// picks the file up when it lands, so the download never blocks the GTK
/// main loop. curl writes to `<cache>.tmp` and only renames it to the final
/// path on success (mv && rm-f on failure), so the cache never holds a
/// partial download. Note: unref'ing the live GSubprocess drops glib's child
/// watch — the short-lived curl becomes a zombie until dockh exits (init
/// reaps it); harmless.
fn spawnArtDownload(url: []const u8, cache: []const u8) void {
    const tmp = std.fmt.allocPrint(state.alloc, "{s}.tmp", .{cache}) catch return;
    var cmd: [4096]u8 = undefined;
    var pos: usize = 0;
    const pre = "curl -sSL --fail --max-time 8 -o ";
    if (pre.len >= cmd.len) return;
    @memcpy(cmd[0..pre.len], pre);
    pos += pre.len;
    if (!appendShellQuoted(&cmd, &pos, tmp)) return;
    const sp = " ";
    if (pos + sp.len >= cmd.len) return;
    @memcpy(cmd[pos .. pos + sp.len], sp);
    pos += sp.len;
    if (!appendShellQuoted(&cmd, &pos, url)) return;
    const mv = " && mv ";
    if (pos + mv.len >= cmd.len) return;
    @memcpy(cmd[pos .. pos + mv.len], mv);
    pos += mv.len;
    if (!appendShellQuoted(&cmd, &pos, tmp)) return; // mv SOURCE (the .tmp)
    const mv_sp = " ";
    if (pos + mv_sp.len >= cmd.len) return;
    @memcpy(cmd[pos .. pos + mv_sp.len], mv_sp);
    pos += mv_sp.len;
    if (!appendShellQuoted(&cmd, &pos, cache)) return; // mv DESTINATION
    const rm = " || rm -f ";
    if (pos + rm.len >= cmd.len) return;
    @memcpy(cmd[pos .. pos + rm.len], rm);
    pos += rm.len;
    if (!appendShellQuoted(&cmd, &pos, tmp)) return;
    if (pos >= cmd.len) return;
    cmd[pos] = 0;
    spawnArgv(&.{ "sh", "-c", cmd[0..pos :0] });
}

/// Apply an image FILE to both the big player art and the compact cover.
/// `z_path` must be NUL-terminated (callers dupeZ first).
fn applyArtFile(z_path: [*:0]const u8, px: c_int) void {
    if (art_image) |i| {
        c.gtk_image_set_from_file(i, z_path);
        c.gtk_image_set_pixel_size(i, px);
    }
    if (min_art_image) |i| {
        c.gtk_image_set_from_file(i, z_path);
        c.gtk_image_set_pixel_size(i, MIN_ART);
    }
}

/// Apply the SVG/theme placeholder icon to both art widgets.
fn applyArtIcon(svg_name: []const u8, fallback_icon: []const u8, px: c_int) void {
    if (art_image) |i| setImageIcon(i, svg_name, fallback_icon, px);
    if (min_art_image) |i| setImageIcon(i, svg_name, fallback_icon, MIN_ART - 8);
}

/// Show the cached art unless it's already displayed (the 1s poll calls this
/// every tick — the `last_art_file` guard stops GTK from re-decoding the
/// image 60×/min). Ignores a missing or empty cache file.
fn loadArtCache(cache: []const u8) bool {
    if (std.mem.eql(u8, last_art_file, cache)) return true; // already shown
    if (!fs.pathExists(cache)) return false;
    if (!fileNonEmpty(cache)) return false;
    last_art_file = state.alloc.dupe(u8, cache) catch return false;
    log.info("island: album art loaded ({s})", .{cache});
    const z = state.alloc.dupeZ(u8, cache) catch return false;
    applyArtFile(z.ptr, 56);
    return true;
}

/// Handle an http(s) mpris:artUrl: serve it from the cache when downloaded,
/// otherwise kick off a background download (the placeholder stays until the
/// 1s poll sees the cached file land). A failed download retries every 30s,
/// so a transient network blip (or a dead URL that comes back later)
/// recovers without a dockh restart.
fn setRemoteArt(url: []const u8) bool {
    const cache = artCachePath(url) orelse return false;
    var now: i64 = 0;
    _ = c.time(&now);

    if (!std.mem.eql(u8, last_art_path, url)) {
        // First sight of this URL: serve from cache or start a download.
        last_art_path = state.alloc.dupe(u8, url) catch return false;
        last_art_file = "";
        last_art_attempt = 0;
        if (loadArtCache(cache)) return true;
        last_art_attempt = now;
        log.info("island: downloading album art into {s}", .{cache});
        spawnArtDownload(url, cache);
        return false;
    }

    // Same URL: show the art once the download lands; otherwise retry a
    // failed download after a 30s backoff.
    if (loadArtCache(cache)) return true;
    if (now - last_art_attempt >= 30) {
        last_art_attempt = now;
        log.info("island: retrying album art download into {s}", .{cache});
        spawnArtDownload(url, cache);
    }
    return false;
}

/// Load album art for the music view. Handles file:// paths (playerctl) and
/// http(s) URLs (downloaded + cached under ~/.cache/dockh). Returns true when
/// the image changed.
fn setAlbumArt(path: []const u8) bool {
    if (art_image == null) return false;
    // Remote art: async download + cache (dedups on the URL itself).
    if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) {
        return setRemoteArt(path);
    }
    if (std.mem.eql(u8, last_art_path, path)) return false;
    if (std.mem.startsWith(u8, path, "file://")) {
        const p = path["file://".len..];
        if (p.len == 0) return false;
        // Keep an OWNED copy of the path for the next comparison — the input
        // slice lives in status.zig's scratch buffer.
        last_art_path = state.alloc.dupe(u8, path) catch return false;
        const z = state.alloc.dupeZ(u8, p) catch return false;
        applyArtFile(z.ptr, 56);
        return true;
    }
    // Empty or non-file: reset to the placeholder.
    last_art_path = "";
    applyArtIcon("island-album-placeholder", "audio-x-generic-symbolic", 24);
    return true;
}

/// Update the island with new music metadata. `status` is the playerctl
/// status ("Playing", "Paused", "Stopped"); `album_art` is mpris:artUrl.
pub fn updateMusic(title: []const u8, artist: []const u8, status: []const u8, album_art: []const u8) void {
    if (!state.cfg.island_enabled) return;
    if (island_win == null) createIslandWindow();

    const playing = std.mem.eql(u8, status, "Playing");
    const has_track = title.len > 0 or playing;
    const resumed = playing and !last_playing; // pop out again on play
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

    // The compact vinyl stops spinning while paused (macOS behavior).
    if (min_box) |b| {
        if (playing) {
            c.gtk_widget_remove_css_class(b, "paused");
        } else {
            c.gtk_widget_add_css_class(b, "paused");
        }
    }

    // Transient modes (notif/osd/screenshot) keep the stage until their timer
    // fires — the music data updates underneath them.
    if (mode == .notif or mode == .osd or mode == .screenshot) {
        was_playing = playing;
        return;
    }
    if (has_track) {
        was_playing = playing;
        // Full player or compact vinyl — never force-expand from the compact
        // pill back to the big player just because the 1s poll fired, unless
        // playback just resumed (macOS pops the widget out on play).
        if (resumed or (mode != .music and mode != .music_min)) setMode(.music);
    } else if ((mode == .music or mode == .music_min) and !playing) {
        was_playing = false;
        setMode(.idle);
    }
}

/// m:ss time formatting into `buf`; returns "" when it doesn't fit.
fn fmtTime(secs: f64, buf: []u8) []const u8 {
    const s = @max(0, @as(i64, @intFromFloat(secs)));
    const m = s / 60;
    const ss = s % 60;
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ m, ss }) catch "";
}

/// Update the music progress bar + the current/remaining time labels.
/// `pos_us` / `len_us` are MPRIS values in MICROSECONDS (playerctl emits µs
/// for {{position}} — dividing naively produced an always-full bar).
pub fn updateMusicProgress(pos_us: f64, len_us: f64) void {
    if (!state.cfg.island_enabled) return;
    const len_s = len_us / 1_000_000.0;
    const pos_s = pos_us / 1_000_000.0;
    const fraction = if (len_s > 0) @max(0.0, @min(1.0, pos_s / len_s)) else 0;
    if (music_progress_bar) |bar| {
        c.gtk_progress_bar_set_fraction(bar, fraction);
    }
    var b1: [16]u8 = undefined;
    var b2: [16]u8 = undefined;
    if (music_pos_label) |lbl| {
        const t = fmtTime(pos_s, &b1);
        const z = state.alloc.dupeZ(u8, t) catch return;
        c.gtk_label_set_text(lbl, z.ptr);
    }
    if (music_remain_label) |lbl| {
        const t = fmtTime(len_s - pos_s, &b2); // positive remaining
        var mbuf: [32]u8 = undefined;
        const m = std.fmt.bufPrint(&mbuf, "-{s}", .{t}) catch "";
        const z = state.alloc.dupeZ(u8, m) catch return;
        c.gtk_label_set_text(lbl, z.ptr);
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

    was_playing = mode == .music or mode == .music_min;
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

    was_playing = mode == .music or mode == .music_min;
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
/// Append `s` to `buf` at `*pos`, wrapped in single quotes with POSIX
/// escaping (' -> '\'') so a quote anywhere in the value can't break or
/// inject into a sh -c command. Returns false when it doesn't fit.
fn appendShellQuoted(buf: []u8, pos: *usize, s: []const u8) bool {
    if (pos.* + 1 >= buf.len) return false;
    buf[pos.*] = '\'';
    pos.* += 1;
    for (s) |ch| {
        if (ch == '\'') {
            const esc = "'\\''";
            if (pos.* + esc.len >= buf.len) return false;
            @memcpy(buf[pos.* .. pos.* + esc.len], esc);
            pos.* += esc.len;
        } else {
            if (pos.* + 1 >= buf.len) return false;
            buf[pos.*] = ch;
            pos.* += 1;
        }
    }
    if (pos.* + 1 >= buf.len) return false;
    buf[pos.*] = '\'';
    pos.* += 1;
    return true;
}

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

    was_playing = mode == .music or mode == .music_min;
    setMode(.screenshot);
    cancelNotifTimer();
    notif_timer = c.g_timeout_add(6000, @ptrCast(&onNotifTimeout), null);
}

/// Update the idle battery label and warn once when crossing 20% while
/// discharging. `pct` in 0..100, `present` false hides the label entirely.
pub fn setBattery(pct: i32, charging: bool, present: bool) void {
    if (!state.cfg.island_enabled) return;

    const same = pct == last_battery_pct and charging == last_battery_charging;
    if (same and !charging) return; // unchanged
    last_battery_pct = pct;
    last_battery_charging = charging;

    if (!present) {
        battery_warned = false;
        return;
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
    cancelShrinkTimer();
}
