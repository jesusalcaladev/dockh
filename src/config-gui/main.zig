//! dockh-config — graphical editor for ~/.config/dockh/config.toml.
//!
//! A regular GTK4 window (NOT a layer shell) with a GtkNotebook of tabs:
//!   Apariencia · Comportamiento · Widgets · Glass · Apps · Memoria
//! Every option is a form control (GtkSwitch / GtkSpinButton / GtkEntry /
//! GtkDropDown). Save writes the file TEXTUALLY through config.setValueInText
//! — comments, indentation and every untouched key survive — and the running
//! dock hot-reloads config.toml on its own (main.zig watches the file with a
//! GFileMonitor and re-execs itself), so editing here is applied live.
//!
//! The [apps] pinned list is special: the dock's runtime truth lives in
//! ~/.cache/dockh/pinned (one class per line), which wins over the TOML
//! seed. This editor reads it from the cache file and writes both.
const std = @import("std");
// Named imports wired up in build.zig (the module is rooted in src/config-gui/
// so ../ relative imports would leave its path):
const c = @import("c");
const config_mod = @import("cfg");
const fs = @import("fs");
const default_toml = @import("defaults").content;

var perm_arena: std.heap.ArenaAllocator = undefined;
var alloc: std.mem.Allocator = undefined;

var win: ?*anyopaque = null;
var status_label: ?*anyopaque = null;
var config_path: []const u8 = "";
var cfg_override: []const u8 = "";
var main_loop: ?*anyopaque = null;

// Glass tab: live preview widget + preset dropdown + load guard (the
// dropdown's notify::selected also fires when loadValues() resets it, and
// must not re-apply a preset over freshly loaded values).
var glass_preview: ?*anyopaque = null;
var glass_preset_drop: ?*anyopaque = null;
var loading_values = false;

// Glass presets — one click sets all nine tunable shader knobs. The names
// follow the optical feel: Light (barely there), Frost (heavy blur),
// Spray (chromatic rainbow edges), Liquid (strong refraction + splay),
// Deep (dark tinted panel).
const GlassPreset = struct {
    name: []const u8,
    radius: f64,
    margin: f64,
    refraction: f64,
    dispersion: f64,
    splay: f64,
    frost: f64,
    depth: f64,
    light_angle: f64,
    alpha: f64,
};

const glass_presets = [_]GlassPreset{
    .{ .name = "Light", .radius = 24, .margin = 10, .refraction = 0.30, .dispersion = 0.08, .splay = 0.35, .frost = 0.10, .depth = 0.08, .light_angle = -45, .alpha = 0.92 },
    .{ .name = "Frost", .radius = 26, .margin = 12, .refraction = 0.35, .dispersion = 0.12, .splay = 0.45, .frost = 0.65, .depth = 0.12, .light_angle = -45, .alpha = 0.88 },
    .{ .name = "Spray", .radius = 22, .margin = 8, .refraction = 0.55, .dispersion = 0.55, .splay = 0.75, .frost = 0.25, .depth = 0.20, .light_angle = -60, .alpha = 0.85 },
    .{ .name = "Liquid", .radius = 20, .margin = 6, .refraction = 0.80, .dispersion = 0.30, .splay = 0.90, .frost = 0.15, .depth = 0.28, .light_angle = -30, .alpha = 0.82 },
    .{ .name = "Deep", .radius = 16, .margin = 4, .refraction = 0.95, .dispersion = 0.45, .splay = 0.85, .frost = 0.10, .depth = 0.60, .light_angle = -15, .alpha = 0.72 },
};

// ---------------------------------------------------------------------------
// Field table: every config option the editor knows, grouped by tab.
// ---------------------------------------------------------------------------

const Kind = enum { boolean, integer, float, string, en, list };

const Field = struct {
    tab: u8, // 0 Apariencia, 1 Comportamiento, 2 Widgets, 3 Glass, 4 Apps, 5 Memoria
    section: []const u8,
    key: []const u8,
    label: []const u8,
    kind: Kind,
    options: []const []const u8 = &.{},
    min: f64 = 0,
    max: f64 = 100,
    step: f64 = 1,
    digits: c_uint = 0,
    help: []const u8 = "",
};

const tab_names = [_][]const u8{ "Apariencia", "Comportamiento", "Widgets", "Glass", "Apps", "Memoria" };

const fields = [_]Field{
    // ---- 0 · Apariencia: dock ----
    .{ .tab = 0, .section = "dock", .key = "position", .label = "Position", .kind = .en, .options = &.{ "bottom", "top", "left", "right" }, .help = "Screen edge the dock sits on" },
    .{ .tab = 0, .section = "dock", .key = "alignment", .label = "Alignment", .kind = .en, .options = &.{ "center", "start", "end" }, .help = "Alignment along the monitor edge (full = off)" },
    .{ .tab = 0, .section = "dock", .key = "full", .label = "Full width / height", .kind = .boolean, .help = "Take the whole monitor edge" },
    .{ .tab = 0, .section = "dock", .key = "layer", .label = "Layer", .kind = .en, .options = &.{ "bottom", "top", "overlay" }, .help = "bottom = behind windows, overlay = above everything" },
    .{ .tab = 0, .section = "dock", .key = "exclusive", .label = "Exclusive zone", .kind = .boolean, .help = "Reserve screen space for the dock (forces top layer)" },
    .{ .tab = 0, .section = "dock", .key = "icon_size", .label = "Icon size (px)", .kind = .integer, .min = 16, .max = 256, .step = 2, .help = "Base icon size before magnify" },
    .{ .tab = 0, .section = "dock", .key = "num_workspaces", .label = "Workspaces", .kind = .integer, .min = 1, .max = 20, .step = 1, .help = "Number of workspaces shown in menus" },
    .{ .tab = 0, .section = "dock", .key = "target_output", .label = "Target output", .kind = .string, .help = "e.g. DP-1 — empty = focused monitor" },
    // margins
    .{ .tab = 0, .section = "margins", .key = "top", .label = "Margin top (px)", .kind = .integer, .min = 0, .max = 500, .step = 1 },
    .{ .tab = 0, .section = "margins", .key = "bottom", .label = "Margin bottom (px)", .kind = .integer, .min = 0, .max = 500, .step = 1 },
    .{ .tab = 0, .section = "margins", .key = "left", .label = "Margin left (px)", .kind = .integer, .min = 0, .max = 500, .step = 1 },
    .{ .tab = 0, .section = "margins", .key = "right", .label = "Margin right (px)", .kind = .integer, .min = 0, .max = 500, .step = 1 },
    // launcher
    .{ .tab = 0, .section = "launcher", .key = "show", .label = "Show launcher button", .kind = .boolean, .help = "App launcher icon at the dock end" },
    .{ .tab = 0, .section = "launcher", .key = "command", .label = "Launcher command", .kind = .string, .help = "e.g. nwg-drawer" },
    .{ .tab = 0, .section = "launcher", .key = "icon", .label = "Launcher icon", .kind = .string, .help = "Icon theme name or absolute path" },
    .{ .tab = 0, .section = "launcher", .key = "position", .label = "Launcher position", .kind = .en, .options = &.{ "end", "start" } },
    // appearance — injected CSS, hot-reloads live
    .{ .tab = 0, .section = "appearance", .key = "icon_shadow", .label = "Icon shadow", .kind = .boolean, .help = "Soft drop shadow behind each dock icon (injected into CSS — no style.css editing)" },
    .{ .tab = 0, .section = "appearance", .key = "icon_shadow_radius", .label = "Shadow blur (px)", .kind = .float, .min = 0, .max = 64, .step = 1, .digits = 0, .help = "Blur radius in whole px (GTK rejects decimals); 0 = sharp edge — only when icon_shadow is on" },

    // ---- 1 · Comportamiento ----
    .{ .tab = 1, .section = "dock", .key = "autohide", .label = "Auto-hide", .kind = .boolean, .help = "Show on hotspot hover, hide on leave" },
    .{ .tab = 1, .section = "dock", .key = "hide_on_activity", .label = "Intelli-hide", .kind = .boolean, .help = "Hide while the active workspace has windows" },
    .{ .tab = 1, .section = "dock", .key = "resident", .label = "Resident (always visible)", .kind = .boolean, .help = "Never auto-hide" },
    .{ .tab = 1, .section = "hotspot", .key = "delay_ms", .label = "Hotspot delay (ms)", .kind = .integer, .min = 0, .max = 2000, .step = 5, .help = "Flick-to-edge window; 0 = always show" },
    .{ .tab = 1, .section = "hotspot", .key = "layer", .label = "Hotspot layer", .kind = .en, .options = &.{ "overlay", "top" } },
    .{ .tab = 1, .section = "hotspot", .key = "size", .label = "Hotspot size (px)", .kind = .integer, .min = 0, .max = 600, .step = 4, .help = "Detector depth; 0 = auto (1/3 of the edge)" },
    .{ .tab = 1, .section = "animation", .key = "scale", .label = "Magnify scale", .kind = .float, .min = 1.0, .max = 3.0, .step = 0.05, .digits = 2, .help = "Peak hover/magnify scale (macOS drama)" },
    .{ .tab = 1, .section = "animation", .key = "duration_ms", .label = "Transition (ms)", .kind = .integer, .min = 50, .max = 2000, .step = 10 },
    .{ .tab = 1, .section = "animation", .key = "curve", .label = "Ease curve", .kind = .string, .help = "cubic-bezier(...) CSS curve" },

    // ---- 2 · Widgets: magnify ----
    .{ .tab = 2, .section = "magnify", .key = "enabled", .label = "Magnify on hover", .kind = .boolean, .help = "macOS proximity magnification" },
    .{ .tab = 2, .section = "magnify", .key = "spread", .label = "Spread (slots)", .kind = .integer, .min = 1, .max = 12, .step = 1, .help = "Effect radius in icon slots from the cursor" },
    .{ .tab = 2, .section = "magnify", .key = "steps", .label = "Bucket steps", .kind = .integer, .min = 8, .max = 512, .step = 8, .help = "Ladder size: 256 = sub-pixel, smooth" },
    .{ .tab = 2, .section = "magnify", .key = "duration_ms", .label = "Ease time (ms)", .kind = .integer, .min = 10, .max = 200, .step = 5, .help = "Higher = smoother follow" },
    .{ .tab = 2, .section = "magnify", .key = "spring", .label = "Settle spring", .kind = .boolean, .help = "macOS settle bounce when the pointer stops" },
    .{ .tab = 2, .section = "magnify", .key = "spring_strength", .label = "Spring strength", .kind = .float, .min = 0, .max = 0.25, .step = 0.01, .digits = 2 },
    .{ .tab = 2, .section = "magnify", .key = "click_spring", .label = "Click spring", .kind = .boolean, .help = "Press squash + release bounce on click" },
    .{ .tab = 2, .section = "magnify", .key = "press_strength", .label = "Press strength", .kind = .float, .min = 0, .max = 0.30, .step = 0.01, .digits = 2 },
    .{ .tab = 2, .section = "magnify", .key = "release_strength", .label = "Release strength", .kind = .float, .min = 0, .max = 0.50, .step = 0.01, .digits = 2 },
    .{ .tab = 2, .section = "magnify", .key = "ghost_launch", .label = "Ghost launch", .kind = .boolean, .help = "Bounce + fade when opening a pinned app" },
    .{ .tab = 2, .section = "magnify", .key = "ghost_ms", .label = "Ghost fade (ms)", .kind = .integer, .min = 150, .max = 2000, .step = 25 },
    .{ .tab = 2, .section = "magnify", .key = "ghost_scale", .label = "Ghost scale", .kind = .float, .min = 1.0, .max = 2.5, .step = 0.05, .digits = 2 },
    // progress / badge
    .{ .tab = 2, .section = "progress", .key = "enabled", .label = "Media progress bar", .kind = .boolean, .help = "macOS-style bar under the playing app (playerctl)" },
    .{ .tab = 2, .section = "badge", .key = "enabled", .label = "Notification badge", .kind = .boolean, .help = "Notification counter on the app icon (mako)" },
    .{ .tab = 2, .section = "badge", .key = "threshold", .label = "Badge high threshold", .kind = .integer, .min = 0, .max = 99, .step = 1, .help = "Count at which the badge turns red; 0 = never" },
    // system monitor
    .{ .tab = 2, .section = "system", .key = "enabled", .label = "System monitor (menu)", .kind = .boolean, .help = "RAM/CPU/temp in the right-click menu" },
    .{ .tab = 2, .section = "system", .key = "dock", .label = "System pill in dock", .kind = .boolean, .help = "Always-visible stats at the dock end (opt-in)" },
    .{ .tab = 2, .section = "system", .key = "interval_ms", .label = "Poll interval (ms)", .kind = .integer, .min = 500, .max = 60000, .step = 250 },
    .{ .tab = 2, .section = "system", .key = "ram", .label = "Show RAM", .kind = .boolean },
    .{ .tab = 2, .section = "system", .key = "cpu", .label = "Show CPU", .kind = .boolean },
    .{ .tab = 2, .section = "system", .key = "temp", .label = "Show temperature", .kind = .boolean },
    // glow
    .{ .tab = 2, .section = "glow", .key = "enabled", .label = "Active-app glow", .kind = .boolean, .help = "In-dock blur halo behind the active icon" },
    .{ .tab = 2, .section = "glow", .key = "radius", .label = "Glow radius (px)", .kind = .float, .min = 0, .max = 64, .step = 1, .digits = 0 },

    // ---- 3 · Glass ----
    .{ .tab = 3, .section = "glass", .key = "enabled", .label = "Liquid glass", .kind = .boolean, .help = "Real GLSL panel (adds ~70 MB RSS); off = CSS glass" },
    .{ .tab = 3, .section = "glass", .key = "radius", .label = "Corner radius (px)", .kind = .float, .min = 0, .max = 64, .step = 1, .digits = 0 },
    .{ .tab = 3, .section = "glass", .key = "margin", .label = "Inset (px)", .kind = .float, .min = 0, .max = 64, .step = 1, .digits = 0, .help = "Must match the #dockh-box CSS margin" },
    .{ .tab = 3, .section = "glass", .key = "refraction", .label = "Refraction", .kind = .float, .min = 0, .max = 1, .step = 0.05, .digits = 2, .help = "Bend strength at the panel edges" },
    .{ .tab = 3, .section = "glass", .key = "dispersion", .label = "Chromatic dispersion", .kind = .float, .min = 0, .max = 1, .step = 0.05, .digits = 2 },
    .{ .tab = 3, .section = "glass", .key = "splay", .label = "Edge curvature", .kind = .float, .min = 0, .max = 1, .step = 0.05, .digits = 2 },
    .{ .tab = 3, .section = "glass", .key = "frost", .label = "Frost blur", .kind = .float, .min = 0, .max = 1, .step = 0.05, .digits = 2 },
    .{ .tab = 3, .section = "glass", .key = "depth", .label = "Depth tint", .kind = .float, .min = 0, .max = 1, .step = 0.05, .digits = 2 },
    .{ .tab = 3, .section = "glass", .key = "light_angle", .label = "Light angle (°)", .kind = .float, .min = -180, .max = 180, .step = 5, .digits = 0 },
    .{ .tab = 3, .section = "glass", .key = "alpha", .label = "Panel opacity", .kind = .float, .min = 0, .max = 1, .step = 0.05, .digits = 2 },

    // ---- 4 · Apps ----
    .{ .tab = 4, .section = "apps", .key = "css_file", .label = "Stylesheet file", .kind = .string, .help = "File name inside the config dir" },
    .{ .tab = 4, .section = "apps", .key = "pinned", .label = "Pinned apps", .kind = .list, .help = "Comma-separated classes / .desktop ids" },
    .{ .tab = 4, .section = "apps", .key = "ignore_classes", .label = "Ignored classes", .kind = .list, .help = "Comma-separated window classes to skip" },
    .{ .tab = 4, .section = "apps", .key = "ignore_workspaces", .label = "Ignored workspaces", .kind = .list, .help = "Comma-separated, e.g. special,10" },

    // ---- 5 · Memoria ----
    .{ .tab = 5, .section = "memory", .key = "watch_sec", .label = "Watch interval (s)", .kind = .integer, .min = 0, .max = 300, .step = 1, .help = "RSS sampling; 0 = off" },
    .{ .tab = 5, .section = "memory", .key = "trim_above_mb", .label = "Trim heap above (MB)", .kind = .integer, .min = 0, .max = 2048, .step = 8, .help = "Force malloc_trim above this RSS; 0 = off" },
    .{ .tab = 5, .section = "memory", .key = "glass_off_mb", .label = "Drop glass above (MB)", .kind = .integer, .min = 0, .max = 2048, .step = 8, .help = "Hard ceiling: disables the GLSL shader; 0 = off" },
};

var field_widgets: [fields.len]?*anyopaque = .{null} ** fields.len;

// ---------------------------------------------------------------------------
// Paths (same resolution as the dock: $XDG_CONFIG_HOME/dockh, ~/.config/dockh)
// ---------------------------------------------------------------------------

fn envSpan(name: [*:0]const u8) ?[]const u8 {
    const v = c.getenv(name) orelse return null;
    return std.mem.span(v);
}

fn homeDir() []const u8 {
    return envSpan("HOME") orelse "/";
}

fn configDir() []const u8 {
    if (envSpan("XDG_CONFIG_HOME")) |d| {
        return std.fmt.allocPrint(alloc, "{s}/dockh", .{d}) catch "/tmp/dockh-config";
    }
    return std.fmt.allocPrint(alloc, "{s}/.config/dockh", .{homeDir()}) catch "/tmp/dockh-config";
}

fn cacheDir() []const u8 {
    if (envSpan("XDG_CACHE_HOME")) |d| {
        return std.fmt.allocPrint(alloc, "{s}/dockh", .{d}) catch "/tmp/dockh-cache";
    }
    return std.fmt.allocPrint(alloc, "{s}/.cache/dockh", .{homeDir()}) catch "/tmp/dockh-cache";
}

fn cfgPath() []const u8 {
    if (cfg_override.len > 0) return cfg_override;
    return std.fmt.allocPrint(alloc, "{s}/config.toml", .{configDir()}) catch "";
}

fn pinnedCachePath() []const u8 {
    return std.fmt.allocPrint(alloc, "{s}/pinned", .{cacheDir()}) catch "";
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ---------------------------------------------------------------------------
// Config value access: one big switch from (section, key) -> typed value
// ---------------------------------------------------------------------------

const Val = union(enum) { b: bool, i: i64, f: f64, s: []const u8, list: []const []const u8 };

fn fieldVal(cfg: *const config_mod.Config, f: Field) Val {
    const s = f.section;
    const k = f.key;
    if (eq(s, "dock")) {
        if (eq(k, "position")) return .{ .s = cfg.position };
        if (eq(k, "alignment")) return .{ .s = cfg.alignment };
        if (eq(k, "full")) return .{ .b = cfg.full };
        if (eq(k, "layer")) return .{ .s = cfg.layer };
        if (eq(k, "exclusive")) return .{ .b = cfg.exclusive };
        if (eq(k, "autohide")) return .{ .b = cfg.autohide };
        if (eq(k, "hide_on_activity")) return .{ .b = cfg.hide_on_activity };
        if (eq(k, "resident")) return .{ .b = cfg.resident };
        if (eq(k, "icon_size")) return .{ .i = cfg.icon_size };
        if (eq(k, "num_workspaces")) return .{ .i = cfg.num_workspaces };
        if (eq(k, "target_output")) return .{ .s = cfg.target_output };
    } else if (eq(s, "margins")) {
        if (eq(k, "top")) return .{ .i = cfg.margin_top };
        if (eq(k, "bottom")) return .{ .i = cfg.margin_bottom };
        if (eq(k, "left")) return .{ .i = cfg.margin_left };
        if (eq(k, "right")) return .{ .i = cfg.margin_right };
    } else if (eq(s, "launcher")) {
        if (eq(k, "show")) return .{ .b = !cfg.no_launcher };
        if (eq(k, "command")) return .{ .s = cfg.launcher_cmd };
        if (eq(k, "icon")) return .{ .s = cfg.launcher_icon };
        if (eq(k, "position")) return .{ .s = cfg.launcher_pos };
    } else if (eq(s, "hotspot")) {
        if (eq(k, "delay_ms")) return .{ .i = cfg.hotspot_delay_ms };
        if (eq(k, "layer")) return .{ .s = cfg.hotspot_layer };
        if (eq(k, "size")) return .{ .i = cfg.hotspot_size };
    } else if (eq(s, "animation")) {
        if (eq(k, "scale")) return .{ .f = cfg.animation_scale };
        if (eq(k, "duration_ms")) return .{ .i = cfg.animation_duration_ms };
        if (eq(k, "curve")) return .{ .s = cfg.animation_curve };
    } else if (eq(s, "magnify")) {
        if (eq(k, "enabled")) return .{ .b = cfg.magnify_enabled };
        if (eq(k, "spread")) return .{ .i = cfg.magnify_spread };
        if (eq(k, "steps")) return .{ .i = @intCast(cfg.magnify_steps) };
        if (eq(k, "duration_ms")) return .{ .i = cfg.magnify_duration_ms };
        if (eq(k, "spring")) return .{ .b = cfg.magnify_spring };
        if (eq(k, "spring_strength")) return .{ .f = cfg.magnify_spring_strength };
        if (eq(k, "click_spring")) return .{ .b = cfg.magnify_click_spring };
        if (eq(k, "press_strength")) return .{ .f = cfg.magnify_press_strength };
        if (eq(k, "release_strength")) return .{ .f = cfg.magnify_release_strength };
        if (eq(k, "ghost_launch")) return .{ .b = cfg.magnify_ghost_launch };
        if (eq(k, "ghost_ms")) return .{ .i = cfg.magnify_ghost_ms };
        if (eq(k, "ghost_scale")) return .{ .f = cfg.magnify_ghost_scale };
    } else if (eq(s, "progress")) {
        if (eq(k, "enabled")) return .{ .b = cfg.progress_enabled };
    } else if (eq(s, "badge")) {
        if (eq(k, "enabled")) return .{ .b = cfg.badge_enabled };
        if (eq(k, "threshold")) return .{ .i = @intCast(cfg.badge_threshold) };
    } else if (eq(s, "system")) {
        if (eq(k, "enabled")) return .{ .b = cfg.system_enabled };
        if (eq(k, "dock")) return .{ .b = cfg.system_dock };
        if (eq(k, "interval_ms")) return .{ .i = cfg.system_interval_ms };
        if (eq(k, "ram")) return .{ .b = cfg.system_ram };
        if (eq(k, "cpu")) return .{ .b = cfg.system_cpu };
        if (eq(k, "temp")) return .{ .b = cfg.system_temp };
    } else if (eq(s, "glow")) {
        if (eq(k, "enabled")) return .{ .b = cfg.glow_enabled };
        if (eq(k, "radius")) return .{ .f = cfg.glow_radius };
    } else if (eq(s, "appearance")) {
        if (eq(k, "icon_shadow")) return .{ .b = cfg.icon_shadow };
        if (eq(k, "icon_shadow_radius")) return .{ .f = cfg.icon_shadow_radius };
    } else if (eq(s, "glass")) {
        if (eq(k, "enabled")) return .{ .b = cfg.glass_enabled };
        if (eq(k, "radius")) return .{ .f = cfg.glass_radius };
        if (eq(k, "margin")) return .{ .f = cfg.glass_margin };
        if (eq(k, "refraction")) return .{ .f = cfg.glass_refraction };
        if (eq(k, "dispersion")) return .{ .f = cfg.glass_dispersion };
        if (eq(k, "splay")) return .{ .f = cfg.glass_splay };
        if (eq(k, "frost")) return .{ .f = cfg.glass_frost };
        if (eq(k, "depth")) return .{ .f = cfg.glass_depth };
        if (eq(k, "light_angle")) return .{ .f = cfg.glass_light_angle };
        if (eq(k, "alpha")) return .{ .f = cfg.glass_alpha };
    } else if (eq(s, "memory")) {
        if (eq(k, "watch_sec")) return .{ .i = cfg.memory_watch_sec };
        if (eq(k, "trim_above_mb")) return .{ .i = cfg.memory_trim_above_mb };
        if (eq(k, "glass_off_mb")) return .{ .i = cfg.memory_glass_off_mb };
    } else if (eq(s, "apps")) {
        if (eq(k, "css_file")) return .{ .s = cfg.css_file };
        if (eq(k, "pinned")) return .{ .list = cfg.pinned };
        if (eq(k, "ignore_classes")) return .{ .list = cfg.ignore_classes };
        if (eq(k, "ignore_workspaces")) return .{ .list = cfg.ignore_workspaces };
    }
    return .{ .b = false };
}

// ---------------------------------------------------------------------------
// Load: parse the file into a Config and populate every widget
// ---------------------------------------------------------------------------

fn joinList(items: []const []const u8, out: *std.ArrayList(u8)) void {
    for (items, 0..) |it, i| {
        if (i > 0) out.appendSlice(alloc, ", ") catch {};
        out.appendSlice(alloc, it) catch {};
    }
}

fn setWidgetFromVal(f: Field, w: ?*anyopaque, v: Val) void {
    switch (f.kind) {
        .boolean => c.gtk_switch_set_active(w, if (v.b) 1 else 0),
        .integer => c.gtk_spin_button_set_value(w, @floatFromInt(v.i)),
        .float => c.gtk_spin_button_set_value(w, v.f),
        .string => {
            const z = alloc.dupeZ(u8, v.s) catch return;
            c.gtk_editable_set_text(w, z.ptr);
        },
        .en => {
            var idx: c_uint = 0;
            for (f.options, 0..) |o, i| {
                if (eq(o, v.s)) {
                    idx = @intCast(i);
                    break;
                }
            }
            c.gtk_drop_down_set_selected(w, idx);
        },
        .list => {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(alloc);
            joinList(v.list, &buf);
            const z = alloc.dupeZ(u8, buf.items) catch return;
            c.gtk_editable_set_text(w, z.ptr);
        },
    }
}

/// Read the pinned cache file (the dock's runtime truth) into a list.
fn readPinnedCache() ?[]const []const u8 {
    const path = pinnedCachePath();
    if (!fs.pathExists(path)) return null;
    const data = fs.readFileAlloc(alloc, path, 1 << 20) catch return null;
    defer alloc.free(data);
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t\r");
        if (p.len == 0) continue;
        out.append(alloc, alloc.dupe(u8, p) catch continue) catch continue;
    }
    return out.toOwnedSlice(alloc) catch null;
}

fn loadValues() void {
    loading_values = true;
    defer loading_values = false;
    var cfg: config_mod.Config = config_mod.Config.defaults();
    if (fs.pathExists(config_path)) {
        config_mod.parseFile(alloc, config_path, &cfg) catch {};
    }
    for (fields, 0..) |f, i| {
        const w = field_widgets[i] orelse continue;
        var v = fieldVal(&cfg, f);
        // Pinned apps come from the cache file when it exists (it wins).
        if (eq(f.section, "apps") and eq(f.key, "pinned")) {
            if (readPinnedCache()) |list| v = .{ .list = list };
        }
        setWidgetFromVal(f, w, v);
    }
    // Reset the preset dropdown to an unset state (the notify::selected that
    // fires while loading_values is true is a no-op in the handler).
    if (glass_preset_drop) |d| {
        // GTK_INVALID_LIST_POSITION == G_MAXUINT — GTK4's "no selection".
        c.gtk_drop_down_set_selected(d, std.math.maxInt(c_uint));
    }
    // First paint of the preview with the freshly loaded values.
    refreshGlassPreview();
}

// ---------------------------------------------------------------------------
// Save: read every widget, rewrite the file textually, poke the pinned cache
// ---------------------------------------------------------------------------

fn widgetNewValue(f: Field, w: ?*anyopaque) ?[]const u8 {
    switch (f.kind) {
        .boolean => return if (c.gtk_switch_get_active(w) != 0) "true" else "false",
        .integer => {
            const v = c.gtk_spin_button_get_value(w);
            const n: i64 = @intFromFloat(@round(v));
            return std.fmt.allocPrint(alloc, "{d}", .{n}) catch null;
        },
        .float => {
            const v = c.gtk_spin_button_get_value(w);
            var buf: [64]u8 = undefined;
            const s = config_mod.fmtFloat(v, &buf);
            return alloc.dupe(u8, s) catch null;
        },
        .string => {
            const t = c.gtk_editable_get_text(w) orelse return config_mod.quoteStr(alloc, "") catch null;
            return config_mod.quoteStr(alloc, std.mem.span(t)) catch null;
        },
        .en => {
            const idx = c.gtk_drop_down_get_selected(w);
            const opt = f.options[@min(idx, f.options.len - 1)];
            return config_mod.quoteStr(alloc, opt) catch null;
        },
        .list => {
            const t = c.gtk_editable_get_text(w) orelse return null;
            var items: std.ArrayList([]const u8) = .empty;
            defer items.deinit(alloc);
            var it = std.mem.tokenizeAny(u8, std.mem.span(t), " \t,\n\r");
            while (it.next()) |tok| {
                const clean = std.mem.trim(u8, tok, " \t\"'");
                if (clean.len == 0) continue;
                items.append(alloc, alloc.dupe(u8, clean) catch continue) catch continue;
            }
            return config_mod.quoteList(alloc, items.items) catch null;
        },
    }
}

/// Parse a comma/space list back into items (for the pinned cache file).
fn widgetListItems(w: ?*anyopaque, out: *std.ArrayList([]const u8)) void {
    const t = c.gtk_editable_get_text(w) orelse return;
    var it = std.mem.tokenizeAny(u8, std.mem.span(t), " \t,\n\r");
    while (it.next()) |tok| {
        const clean = std.mem.trim(u8, tok, " \t\"'");
        if (clean.len == 0) continue;
        out.append(alloc, alloc.dupe(u8, clean) catch continue) catch continue;
    }
}

fn saveConfig() void {
    var text: []const u8 = undefined;
    if (fs.pathExists(config_path)) {
        text = fs.readFileAlloc(alloc, config_path, 1 << 20) catch default_toml;
    } else {
        text = default_toml;
    }
    var pinned_items: ?std.ArrayList([]const u8) = null;

    for (fields, 0..) |f, i| {
        const w = field_widgets[i] orelse continue;
        const new_value = widgetNewValue(f, w) orelse continue;
        const updated = config_mod.setValueInText(alloc, text, f.section, f.key, new_value) catch {
            setStatus("Save failed (out of memory)");
            return;
        };
        if (updated.ptr != text.ptr) {
            alloc.free(text);
            text = updated;
        }
        // Keep the pinned cache file in sync (the dock's runtime truth).
        if (eq(f.section, "apps") and eq(f.key, "pinned")) {
            var items: std.ArrayList([]const u8) = .empty;
            widgetListItems(w, &items);
            pinned_items = items;
        }
    }

    fs.writeFile(config_path, text) catch {
        setStatus("Save failed — cannot write the config file");
        return;
    };

    if (pinned_items) |*items| {
        defer items.deinit(alloc);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        for (items.items) |p| {
            buf.appendSlice(alloc, p) catch {};
            buf.append(alloc, '\n') catch {};
        }
        _ = fs.ensureDir(cacheDir());
        fs.writeFile(pinnedCachePath(), buf.items) catch {};
    }

    setStatus("Saved — the dock applies it now (config hot reload)");
}

// ---------------------------------------------------------------------------
// UI construction
// ---------------------------------------------------------------------------

fn setStatus(msg: []const u8) void {
    if (status_label) |l| {
        const z = alloc.dupeZ(u8, msg) catch return;
        c.gtk_label_set_text(l, z.ptr);
    }
}

fn makeControl(f: Field) ?*anyopaque {
    switch (f.kind) {
        .boolean => return c.gtk_switch_new(),
        .integer, .float => {
            const spin = c.gtk_spin_button_new_with_range(f.min, f.max, f.step);
            if (spin == null) return null;
            c.gtk_spin_button_set_digits(spin, f.digits);
            c.gtk_spin_button_set_increments(spin, f.step, f.step * 10);
            c.gtk_spin_button_set_numeric(spin, 1);
            return spin;
        },
        .string, .list => return c.gtk_entry_new(),
        .en => {
            var list: std.ArrayList(?[*:0]const u8) = .empty;
            defer list.deinit(alloc);
            for (f.options) |o| {
                const z = alloc.dupeZ(u8, o) catch continue;
                list.append(alloc, z) catch continue;
            }
            list.append(alloc, null) catch {};
            const drop = c.gtk_drop_down_new_from_strings(@ptrCast(list.items.ptr));
            return drop;
        },
    }
}

// ---------------------------------------------------------------------------
// Glass tab: presets + live preview (approximates the GLSL shader with Cairo)
// ---------------------------------------------------------------------------

/// Widget for a glass key (spin / switch) — or null if the tab isn't built.
fn glassWidgetFor(key: []const u8) ?*anyopaque {
    for (fields, 0..) |f, i| {
        if (f.tab == 3 and eq(f.section, "glass") and eq(f.key, key)) {
            return field_widgets[i];
        }
    }
    return null;
}

fn readGlassEnabled() bool {
    const w = glassWidgetFor("enabled") orelse return false;
    return c.gtk_switch_get_active(w) != 0;
}

fn readGlassFloat(key: []const u8) f64 {
    const w = glassWidgetFor(key) orelse return 0;
    return c.gtk_spin_button_get_value(w);
}

/// Rounded-rect path (cairo has no rounded_rectangle in this version).
fn cairoRoundedRect(cr: c.Cairo, x: f64, y: f64, w: f64, h: f64, r: f64) void {
    const rr = @min(r, @min(w, h) / 2.0);
    c.cairo_new_path(cr);
    c.cairo_move_to(cr, x + rr, y);
    c.cairo_line_to(cr, x + w - rr, y);
    c.cairo_arc(cr, x + w - rr, y + rr, rr, -std.math.pi / 2.0, 0);
    c.cairo_line_to(cr, x + w, y + h - rr);
    c.cairo_arc(cr, x + w - rr, y + h - rr, rr, 0, std.math.pi / 2.0);
    c.cairo_line_to(cr, x + rr, y + h);
    c.cairo_arc(cr, x + rr, y + h - rr, rr, std.math.pi / 2.0, std.math.pi);
    c.cairo_line_to(cr, x, y + rr);
    c.cairo_arc(cr, x + rr, y + rr, rr, std.math.pi, std.math.pi * 1.5);
    c.cairo_close_path(cr);
}

/// Fake desktop behind the panel so refraction/frost have something to show:
/// a dusk gradient with a radial sun glow, mountain silhouettes and two
/// "app windows" — vivid shapes that visibly bend when refraction zooms.
fn drawPreviewBackdrop(cr: c.Cairo, w: f64, h: f64) void {
    // Dusk sky gradient.
    const pat = c.cairo_pattern_create_linear(0, 0, 0, h);
    c.cairo_pattern_add_color_stop_rgba(pat, 0, 0.24, 0.30, 0.52, 1);
    c.cairo_pattern_add_color_stop_rgba(pat, 0.55, 0.10, 0.13, 0.26, 1);
    c.cairo_pattern_add_color_stop_rgba(pat, 1, 0.04, 0.05, 0.10, 1);
    c.cairo_set_source(cr, pat);
    c.cairo_paint(cr);
    c.cairo_pattern_destroy(pat);

    // Sun glow (radial) behind the mountains.
    const gx = w * 0.30;
    const gy = h * 0.42;
    const glow = c.cairo_pattern_create_radial(gx, gy, 2, gx, gy, w * 0.30);
    c.cairo_pattern_add_color_stop_rgba(glow, 0, 1.0, 0.75, 0.35, 0.9);
    c.cairo_pattern_add_color_stop_rgba(glow, 0.4, 0.95, 0.55, 0.22, 0.35);
    c.cairo_pattern_add_color_stop_rgba(glow, 1, 0.4, 0.2, 0.05, 0);
    c.cairo_set_source(cr, glow);
    c.cairo_paint(cr);
    c.cairo_pattern_destroy(glow);

    // Mountain silhouettes.
    c.cairo_set_source_rgba(cr, 0.03, 0.04, 0.08, 0.95);
    c.cairo_new_path(cr);
    c.cairo_move_to(cr, 0, h);
    c.cairo_line_to(cr, w * 0.12, h * 0.62);
    c.cairo_line_to(cr, w * 0.28, h * 0.80);
    c.cairo_line_to(cr, w * 0.45, h * 0.58);
    c.cairo_line_to(cr, w * 0.62, h * 0.76);
    c.cairo_line_to(cr, w * 0.82, h * 0.60);
    c.cairo_line_to(cr, w, h * 0.72);
    c.cairo_line_to(cr, w, h);
    c.cairo_close_path(cr);
    c.cairo_fill(cr);

    // Two colored "app windows" floating above the mountains.
    c.cairo_set_source_rgba(cr, 0.95, 0.60, 0.30, 0.95);
    cairoRoundedRect(cr, w * 0.10, h * 0.20, w * 0.15, h * 0.28, 4);
    c.cairo_fill(cr);
    c.cairo_set_source_rgba(cr, 0.34, 0.66, 0.90, 0.95);
    cairoRoundedRect(cr, w * 0.52, h * 0.16, w * 0.21, h * 0.34, 4);
    c.cairo_fill(cr);
    c.cairo_set_source_rgba(cr, 0.42, 0.85, 0.55, 0.90);
    c.cairo_arc(cr, w * 0.80, h * 0.58, h * 0.16, 0, 2 * std.math.pi);
    c.cairo_fill(cr);
}

/// A row of rounded "app icons" sitting on the panel bottom — so the preview
/// reads as a real dock at a glance. Five macOS-ish colors.
fn drawDockIcons(cr: c.Cairo, px: f64, py: f64, pw: f64, ph: f64) void {
    const colors = [_][3]f64{
        .{ 0.94, 0.40, 0.30 }, // red-orange
        .{ 0.30, 0.62, 0.95 }, // blue
        .{ 0.98, 0.76, 0.28 }, // yellow
        .{ 0.36, 0.84, 0.50 }, // green
        .{ 0.72, 0.42, 0.96 }, // purple
    };
    const n: f64 = @floatFromInt(colors.len);
    const slot = pw / (n + 2.0); // icon spacing (1 free slot each side)
    const isz = @min(slot * 0.62, ph * 0.30);
    const y = py + ph - isz - 6.0;
    var x = px + slot;
    for (colors) |col| {
        // Icon body with a subtle top sheen (glass look).
        c.cairo_set_source_rgba(cr, col[0], col[1], col[2], 0.95);
        cairoRoundedRect(cr, x, y, isz, isz, isz * 0.24);
        c.cairo_fill(cr);
        const sheen = c.cairo_pattern_create_linear(0, y, 0, y + isz);
        c.cairo_pattern_add_color_stop_rgba(sheen, 0, 1, 1, 1, 0.35);
        c.cairo_pattern_add_color_stop_rgba(sheen, 0.45, 1, 1, 1, 0.06);
        c.cairo_pattern_add_color_stop_rgba(sheen, 1, 0, 0, 0, 0.18);
        c.cairo_set_source(cr, sheen);
        cairoRoundedRect(cr, x, y, isz, isz, isz * 0.24);
        c.cairo_fill(cr);
        c.cairo_pattern_destroy(sheen);
        x += slot;
    }
}

/// The dock glass panel the shader draws, approximated for the preview.
/// Every knob maps to a visible effect: refraction zooms the backdrop,
/// dispersion fringes the edges RGB, splay rounds/brightens the bevel,
/// frost washes it white, depth darkens the bottom, light_angle orients the
/// specular highlight, alpha sets the panel fill, radius/margin shape it.
fn glassPreviewDraw(_: ?*anyopaque, cr: c.Cairo, width: c_int, height: c_int, _: ?*anyopaque) callconv(.c) void {
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);
    drawPreviewBackdrop(cr, w, h);

    const enabled = readGlassEnabled();
    const radius = readGlassFloat("radius");
    const margin = @max(readGlassFloat("margin"), 2);
    const refraction = readGlassFloat("refraction");
    const dispersion = readGlassFloat("dispersion");
    const splay = readGlassFloat("splay");
    const frost = readGlassFloat("frost");
    const depth = readGlassFloat("depth");
    const angle_deg = readGlassFloat("light_angle");
    const alpha = readGlassFloat("alpha");

    // Panel rect (scaled up so margin reads visibly in a small preview).
    const px = margin * 1.6;
    const py = margin * 1.6;
    const pw = w - 2 * px;
    const ph = h - 2 * py;
    if (pw <= 4 or ph <= 4) return;

    // Soft drop shadow under the floating panel (two blurs for depth).
    c.cairo_save(cr);
    cairoRoundedRect(cr, px + 3, py + 5, pw, ph, radius);
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0.30);
    c.cairo_fill(cr);
    cairoRoundedRect(cr, px + 1, py + 2, pw, ph, radius);
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0.18);
    c.cairo_fill(cr);
    c.cairo_restore(cr);

    if (!enabled) {
        // CSS-glass fallback: flat dark translucent panel + icons.
        cairoRoundedRect(cr, px, py, pw, ph, radius);
        c.cairo_set_source_rgba(cr, 0.07, 0.08, 0.12, 0.78);
        c.cairo_fill(cr);
        drawDockIcons(cr, px, py, pw, ph);
        cairoRoundedRect(cr, px, py, pw, ph, radius);
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.10);
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);
        return;
    }

    // 1) Refraction: re-draw the backdrop zoomed inside the panel clip.
    c.cairo_save(cr);
    cairoRoundedRect(cr, px, py, pw, ph, radius);
    c.cairo_clip(cr);
    const zoom = 1.0 + refraction * 0.25;
    const cx = w / 2;
    const cy = h / 2;
    c.cairo_translate(cr, cx, cy);
    c.cairo_scale(cr, zoom, zoom);
    c.cairo_translate(cr, -cx, -cy);
    drawPreviewBackdrop(cr, w, h);

    // 2) Frost: white wash (the shader's gaussian blur feels like this).
    if (frost > 0) {
        c.cairo_set_source_rgba(cr, 1, 1, 1, frost * 0.45);
        c.cairo_paint(cr);
    }

    // 3) Depth: darkening toward the bottom edge.
    if (depth > 0) {
        const dpat = c.cairo_pattern_create_linear(0, py, 0, py + ph);
        c.cairo_pattern_add_color_stop_rgba(dpat, 0, 0, 0, 0, 0);
        c.cairo_pattern_add_color_stop_rgba(dpat, 1, 0, 0, 0, depth * 0.65);
        c.cairo_set_source(cr, dpat);
        c.cairo_paint(cr);
        c.cairo_pattern_destroy(dpat);
    }

    // 4) Panel tint: the glass body with the user's alpha.
    c.cairo_set_source_rgba(cr, 0.09, 0.12, 0.19, alpha);
    c.cairo_paint(cr);
    c.cairo_restore(cr);

    // 5) Specular bevel lit from light_angle (a soft band near that edge).
    if (splay > 0.01) {
        const rad = angle_deg * std.math.pi / 180.0;
        const dx = @cos(rad);
        const dy = @sin(rad);
        c.cairo_save(cr);
        cairoRoundedRect(cr, px, py, pw, ph, radius);
        c.cairo_clip(cr);
        const sx = cx + dx * pw * 0.5;
        const sy = cy + dy * ph * 0.5;
        const ex = cx - dx * pw * 0.5;
        const ey = cy - dy * ph * 0.5;
        const spat = c.cairo_pattern_create_linear(sx, sy, ex, ey);
        c.cairo_pattern_add_color_stop_rgba(spat, 0, 1, 1, 1, splay * 0.50);
        c.cairo_pattern_add_color_stop_rgba(spat, 0.55, 1, 1, 1, splay * 0.08);
        c.cairo_pattern_add_color_stop_rgba(spat, 1, 1, 1, 1, 0);
        c.cairo_set_source(cr, spat);
        c.cairo_paint(cr);
        c.cairo_pattern_destroy(spat);
        // Rim light: a bright hairline along the light-facing edge.
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.35 + splay * 0.25);
        c.cairo_set_line_width(cr, 1.2);
        c.cairo_move_to(cr, px + radius, py + 1);
        c.cairo_line_to(cr, px + pw - radius, py + 1);
        c.cairo_stroke(cr);
        c.cairo_restore(cr);
    }

    // 6) Chromatic dispersion: thin R/C fringes on the top/bottom edges.
    if (dispersion > 0.01) {
        c.cairo_save(cr);
        cairoRoundedRect(cr, px, py, pw, ph, radius);
        c.cairo_set_line_width(cr, 2.5);
        c.cairo_set_source_rgba(cr, 1, 0.25, 0.25, dispersion * 0.7);
        c.cairo_stroke_preserve(cr);
        c.cairo_set_source_rgba(cr, 0.25, 0.6, 1, dispersion * 0.7);
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);
        c.cairo_restore(cr);
    }

    // 7) Dock icons on the glass.
    drawDockIcons(cr, px, py, pw, ph);

    // 8) Crisp edge.
    cairoRoundedRect(cr, px, py, pw, ph, radius);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.16 + splay * 0.10);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);
}

fn refreshGlassPreview() void {
    if (glass_preview) |g| c.gtk_widget_queue_draw(g);
}

fn applyGlassPreset(idx: usize) void {
    if (idx >= glass_presets.len) return;
    const p = glass_presets[idx];
    setSpin("radius", p.radius);
    setSpin("margin", p.margin);
    setSpin("refraction", p.refraction);
    setSpin("dispersion", p.dispersion);
    setSpin("splay", p.splay);
    setSpin("frost", p.frost);
    setSpin("depth", p.depth);
    setSpin("light_angle", p.light_angle);
    setSpin("alpha", p.alpha);
    refreshGlassPreview();
    setStatus("Preset applied — click Save to write it");
}

fn setSpin(key: []const u8, v: f64) void {
    if (glassWidgetFor(key)) |w| c.gtk_spin_button_set_value(w, v);
}

fn onGlassControlChanged(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    refreshGlassPreview();
}

fn onGlassSwitchChanged(_: ?*anyopaque, _: c_int, _: ?*anyopaque) callconv(.c) c_int {
    refreshGlassPreview();
    return 0; // FALSE — let GTK apply the new state itself
}

fn onGlassPresetSelected(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (loading_values) return; // loadValues() reset the dropdown
    const idx = c.gtk_drop_down_get_selected(glass_preset_drop);
    applyGlassPreset(idx);
}

fn buildTab(notebook: ?*anyopaque, tab_idx: u8) void {
    const scrolled = c.gtk_scrolled_window_new();
    c.gtk_scrolled_window_set_policy(scrolled, c.POLICY_AUTOMATIC, c.POLICY_AUTOMATIC);
    const grid = c.gtk_grid_new();
    c.gtk_grid_set_row_spacing(grid, 8);
    c.gtk_grid_set_column_spacing(grid, 14);
    c.gtk_widget_set_margin_start(grid, 20);
    c.gtk_widget_set_margin_end(grid, 20);
    c.gtk_widget_set_margin_top(grid, 14);
    c.gtk_widget_set_margin_bottom(grid, 14);
    c.gtk_scrolled_window_set_child(scrolled, grid);

    var row: c_int = 0;
    var last_section: []const u8 = "";

    // Glass tab: live preview + preset dropdown sit above the knobs.
    if (tab_idx == 3) {
        // --- Preset row ---
        const preset_lbl = c.gtk_label_new("Preset");
        c.gtk_widget_set_halign(preset_lbl, c.ALIGN_START);
        c.gtk_widget_set_tooltip_text(preset_lbl, "One click: Light / Frost / Spray / Liquid / Deep");
        var popts: std.ArrayList(?[*:0]const u8) = .empty;
        defer popts.deinit(alloc);
        for (glass_presets) |p| {
            const z = alloc.dupeZ(u8, p.name) catch continue;
            popts.append(alloc, z) catch continue;
        }
        popts.append(alloc, null) catch {};
        glass_preset_drop = c.gtk_drop_down_new_from_strings(@ptrCast(popts.items.ptr));
        _ = c.g_signal_connect(glass_preset_drop, "notify::selected", @ptrCast(&onGlassPresetSelected), null);
        c.gtk_widget_set_hexpand(glass_preset_drop, 1);
        c.gtk_grid_attach(grid, preset_lbl, 0, row, 1, 1);
        c.gtk_grid_attach(grid, glass_preset_drop, 1, row, 1, 1);
        row += 1;

        // --- Live preview ---
        glass_preview = c.gtk_drawing_area_new();
        c.gtk_drawing_area_set_content_width(glass_preview, 540);
        c.gtk_drawing_area_set_content_height(glass_preview, 150);
        c.gtk_drawing_area_set_draw_func(glass_preview, @ptrCast(&glassPreviewDraw), null, null);
        c.gtk_widget_set_hexpand(glass_preview, 1);
        c.gtk_widget_set_vexpand(glass_preview, 1);
        c.gtk_widget_set_halign(glass_preview, c.ALIGN_FILL);
        c.gtk_widget_set_valign(glass_preview, c.ALIGN_FILL);
        const cap = c.gtk_label_new("Live preview — drag any knob below to see the glass change");
        c.gtk_widget_add_css_class(cap, "dockh-cfg-caption");
        c.gtk_widget_set_halign(cap, c.ALIGN_START);
        c.gtk_grid_attach(grid, cap, 0, row, 2, 1);
        row += 1;
        c.gtk_grid_attach(grid, glass_preview, 0, row, 2, 1);
        row += 1;
    }

    for (fields, 0..) |f, i| {
        if (f.tab != tab_idx) continue;
        if (!eq(f.section, last_section)) {
            // Section header spanning both columns.
            const head = c.gtk_label_new(alloc.dupeZ(u8, f.section) catch "");
            c.gtk_widget_add_css_class(head, "dockh-cfg-section");
            c.gtk_widget_set_halign(head, c.ALIGN_START);
            c.gtk_grid_attach(grid, head, 0, row, 2, 1);
            row += 1;
            last_section = f.section;
        }
        const lbl = c.gtk_label_new(alloc.dupeZ(u8, f.label) catch "");
        c.gtk_widget_set_halign(lbl, c.ALIGN_START);
        c.gtk_widget_set_hexpand(lbl, 1);
        if (f.help.len > 0) {
            c.gtk_widget_set_tooltip_text(lbl, alloc.dupeZ(u8, f.help) catch "");
        }
        const ctl = makeControl(f) orelse continue;
        if (f.help.len > 0) {
            c.gtk_widget_set_tooltip_text(ctl, alloc.dupeZ(u8, f.help) catch "");
        }
        field_widgets[i] = ctl;
        // Glass knobs redraw the preview live.
        if (tab_idx == 3) {
            if (f.kind == .boolean) {
                _ = c.g_signal_connect(ctl, "state-set", @ptrCast(&onGlassSwitchChanged), null);
            } else if (f.kind == .integer or f.kind == .float) {
                _ = c.g_signal_connect(ctl, "value-changed", @ptrCast(&onGlassControlChanged), null);
            }
        }
        c.gtk_widget_set_hexpand(ctl, 1);
        c.gtk_grid_attach(grid, lbl, 0, row, 1, 1);
        c.gtk_grid_attach(grid, ctl, 1, row, 1, 1);
        row += 1;
    }

    const tab_label = c.gtk_label_new(alloc.dupeZ(u8, tab_names[tab_idx]) catch "");
    _ = c.gtk_notebook_append_page(notebook, scrolled, tab_label);
}

fn onSave(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    saveConfig();
}

fn onReload(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    loadValues();
    setStatus("Reloaded from disk (unsaved changes discarded)");
}

fn onDestroy(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (main_loop) |ml| c.g_main_loop_quit(ml);
}

fn buildWindow() void {
    const w = c.gtk_window_new();
    win = w;
    c.gtk_widget_set_name(w, "dockh-config-window");
    c.gtk_window_set_title(w, "dockh — Configuration");
    c.gtk_window_set_default_size(w, 820, 660);
    c.gtk_window_set_resizable(w, 1);

    // Header bar with Save / Reload. GTK4 has no header-bar title/subtitle
    // properties — the title area is a widget, so stack title + path in a box.
    const bar = c.gtk_header_bar_new();
    const title_box = c.gtk_box_new(c.ORIENTATION_VERTICAL, 0);
    const title_lbl = c.gtk_label_new("dockh — Configuration");
    c.gtk_widget_add_css_class(title_lbl, "dockh-cfg-title");
    const path_lbl = c.gtk_label_new(alloc.dupeZ(u8, config_path) catch "");
    c.gtk_widget_add_css_class(path_lbl, "dockh-cfg-path");
    c.gtk_box_append(title_box, title_lbl);
    c.gtk_box_append(title_box, path_lbl);
    c.gtk_header_bar_set_title_widget(bar, title_box);
    const save_b = c.gtk_button_new_with_label("Save");
    c.gtk_widget_add_css_class(save_b, "suggested-action");
    _ = c.g_signal_connect(save_b, "clicked", @ptrCast(&onSave), null);
    c.gtk_header_bar_pack_end(bar, save_b);
    const reload_b = c.gtk_button_new_with_label("Reload");
    _ = c.g_signal_connect(reload_b, "clicked", @ptrCast(&onReload), null);
    c.gtk_header_bar_pack_end(bar, reload_b);
    c.gtk_window_set_titlebar(w, bar);

    const notebook = c.gtk_notebook_new();
    c.gtk_notebook_set_tab_pos(notebook, c.POSITION_TOP);
    c.gtk_notebook_set_scrollable(notebook, 1);

    var t: u8 = 0;
    while (t < tab_names.len) : (t += 1) {
        buildTab(notebook, t);
    }

    const vbox = c.gtk_box_new(c.ORIENTATION_VERTICAL, 0);
    c.gtk_box_append(vbox, notebook);
    status_label = c.gtk_label_new("");
    c.gtk_widget_add_css_class(status_label, "dockh-cfg-status");
    c.gtk_widget_set_halign(status_label, c.ALIGN_START);
    c.gtk_widget_set_margin_start(status_label, 20);
    c.gtk_widget_set_margin_end(status_label, 20);
    c.gtk_widget_set_margin_top(status_label, 8);
    c.gtk_widget_set_margin_bottom(status_label, 10);
    c.gtk_box_append(vbox, status_label);
    c.gtk_window_set_child(w, vbox);

    _ = c.g_signal_connect(w, "destroy", @ptrCast(&onDestroy), null);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

fn printUsage() void {
    std.debug.print(
        \\dockh-config — graphical editor for dockh's config.toml
        \\
        \\Usage: dockh-config [options]
        \\  -cfg <path>   config file to edit (default $XDG_CONFIG_HOME/dockh/config.toml)
        \\  -h            this help
        \\
    , .{});
}

pub fn main(init: std.process.Init.Minimal) void {
    perm_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer perm_arena.deinit();
    alloc = perm_arena.allocator();

    const args = init.args.toSlice(alloc) catch &.{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (eq(args[i], "-cfg")) {
            if (i + 1 < args.len) {
                cfg_override = alloc.dupe(u8, args[i + 1]) catch "";
            }
            i += 1;
        } else if (eq(args[i], "-h") or eq(args[i], "--help")) {
            printUsage();
            std.process.exit(0);
        }
    }

    config_path = cfgPath();
    _ = fs.ensureDir(configDir());
    if (!fs.pathExists(config_path)) {
        fs.writeFile(config_path, default_toml) catch {};
    }

    c.gtk_init();

    // A touch of styling so the form reads nicely (scoped to this window).
    const css = @embedFile("style.css");
    const provider = c.gtk_css_provider_new();
    const css_z = alloc.dupeZ(u8, css) catch "";
    if (css_z.len > 0) c.gtk_css_provider_load_from_string(provider, css_z.ptr);
    const display = c.gdk_display_get_default();
    if (display != null and css_z.len > 0) {
        c.gtk_style_context_add_provider_for_display(display, provider, c.PROVIDER_PRIORITY_APPLICATION);
    }

    buildWindow();
    loadValues();
    setStatus("Ready — Save writes the config and the dock reloads it live");

    if (win) |w| c.gtk_widget_show(w);

    main_loop = c.g_main_loop_new(null, 0);
    if (main_loop) |ml| c.g_main_loop_run(ml);
    if (main_loop) |ml| c.g_main_loop_unref(ml);
}
