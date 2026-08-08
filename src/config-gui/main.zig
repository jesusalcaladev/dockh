//! dockh-config — graphical editor for ~/.config/dockh/config.toml.
//!
//! A regular GTK4 window (NOT a layer shell) with a GtkNotebook of tabs:
//!   General · Behavior · Widgets · Apps
//! Every option is a form control (GtkSwitch / GtkSpinButton / GtkEntry /
//! GtkDropDown). Save writes the file TEXTUALLY through config.setValueInText
//! — comments, indentation and every untouched key survive — and the running
//! dock hot-reloads config.toml on its own (main.zig watches the file with a
//! GFileMonitor and re-executes itself), so editing here is applied live.
//!
//! Supports English / Spanish with a language toggle in the header bar.
const std = @import("std");
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
var loading_values = false;

// ---------------------------------------------------------------------------
// i18n — English / Spanish translations
// ---------------------------------------------------------------------------

const Lang = enum { en, es };
var current_lang: Lang = .en;

const TabKey = enum { general, behavior, widgets, apps };

const I18n = struct {
    // Tab names
    tab_general: []const u8,
    tab_behavior: []const u8,
    tab_widgets: []const u8,
    tab_apps: []const u8,
    // Section headers
    sec_dock: []const u8,
    sec_margins: []const u8,
    sec_launcher: []const u8,
    sec_hotspot: []const u8,
    sec_animation: []const u8,
    sec_magnify: []const u8,
    sec_island: []const u8,
    sec_progress: []const u8,
    sec_badge: []const u8,
    sec_system: []const u8,
    // Field labels
    lbl_position: []const u8,
    lbl_alignment: []const u8,
    lbl_full: []const u8,
    lbl_layer: []const u8,
    lbl_exclusive: []const u8,
    lbl_icon_size: []const u8,
    lbl_workspaces: []const u8,
    lbl_target_output: []const u8,
    lbl_margin_top: []const u8,
    lbl_margin_bottom: []const u8,
    lbl_margin_left: []const u8,
    lbl_margin_right: []const u8,
    lbl_show_launcher: []const u8,
    lbl_launcher_cmd: []const u8,
    lbl_launcher_icon: []const u8,
    lbl_launcher_pos: []const u8,
    lbl_autohide: []const u8,
    lbl_intelli_hide: []const u8,
    lbl_resident: []const u8,
    lbl_hotspot_delay: []const u8,
    lbl_hotspot_layer: []const u8,
    lbl_hotspot_size: []const u8,
    lbl_magnify_scale: []const u8,
    lbl_transition: []const u8,
    lbl_ease_curve: []const u8,
    lbl_magnify_enabled: []const u8,
    lbl_spread: []const u8,
    lbl_falloff: []const u8,
    lbl_steps: []const u8,
    lbl_ease_time: []const u8,
    lbl_spring: []const u8,
    lbl_spring_strength: []const u8,
    lbl_island: []const u8,
    lbl_progress: []const u8,
    lbl_badge: []const u8,
    lbl_badge_threshold: []const u8,
    lbl_sys_monitor: []const u8,
    lbl_sys_dock: []const u8,
    lbl_sys_interval: []const u8,
    lbl_sys_ram: []const u8,
    lbl_sys_cpu: []const u8,
    lbl_sys_temp: []const u8,
    lbl_css_file: []const u8,
    lbl_pinned: []const u8,
    lbl_ignore_classes: []const u8,
    lbl_ignore_ws: []const u8,
    // UI
    lbl_save: []const u8,
    lbl_saved: []const u8,
    lbl_icon_preview: []const u8,
    lbl_lang_toggle: []const u8,
};

const en = I18n{
    .tab_general = "General",
    .tab_behavior = "Behavior",
    .tab_widgets = "Widgets",
    .tab_apps = "Apps",
    .sec_dock = "Dock",
    .sec_margins = "Margins",
    .sec_launcher = "Launcher",
    .sec_hotspot = "Hotspot",
    .sec_animation = "Animation",
    .sec_magnify = "Magnify",
    .sec_island = "Dynamic Island",
    .sec_progress = "Progress",
    .sec_badge = "Badge",
    .sec_system = "System Monitor",
    .lbl_position = "Position",
    .lbl_alignment = "Alignment",
    .lbl_full = "Full width / height",
    .lbl_layer = "Layer",
    .lbl_exclusive = "Exclusive zone",
    .lbl_icon_size = "Icon size (px)",
    .lbl_workspaces = "Workspaces",
    .lbl_target_output = "Target output",
    .lbl_margin_top = "Margin top (px)",
    .lbl_margin_bottom = "Margin bottom (px)",
    .lbl_margin_left = "Margin left (px)",
    .lbl_margin_right = "Margin right (px)",
    .lbl_show_launcher = "Show launcher",
    .lbl_launcher_cmd = "Launcher command",
    .lbl_launcher_icon = "Launcher icon",
    .lbl_launcher_pos = "Launcher position",
    .lbl_autohide = "Auto-hide",
    .lbl_intelli_hide = "Intelli-hide",
    .lbl_resident = "Always visible",
    .lbl_hotspot_delay = "Hotspot delay (ms)",
    .lbl_hotspot_layer = "Hotspot layer",
    .lbl_hotspot_size = "Hotspot size (px)",
    .lbl_magnify_scale = "Magnify scale",
    .lbl_transition = "Transition (ms)",
    .lbl_ease_curve = "Ease curve",
    .lbl_magnify_enabled = "Magnify on hover",
    .lbl_spread = "Spread (slots)",
    .lbl_falloff = "Curve sharpness",
    .lbl_steps = "Bucket steps",
    .lbl_ease_time = "Ease time (ms)",
    .lbl_spring = "Settle spring",
    .lbl_spring_strength = "Spring strength",
    .lbl_island = "Dynamic Island",
    .lbl_progress = "Media progress bar",
    .lbl_badge = "Notification badge",
    .lbl_badge_threshold = "Badge high threshold",
    .lbl_sys_monitor = "System monitor (menu)",
    .lbl_sys_dock = "System pill in dock",
    .lbl_sys_interval = "Poll interval (ms)",
    .lbl_sys_ram = "Show RAM",
    .lbl_sys_cpu = "Show CPU",
    .lbl_sys_temp = "Show temperature",
    .lbl_css_file = "Stylesheet file",
    .lbl_pinned = "Pinned apps",
    .lbl_ignore_classes = "Ignored classes",
    .lbl_ignore_ws = "Ignored workspaces",
    .lbl_save = "Save",
    .lbl_saved = "Saved — dock applies it now",
    .lbl_icon_preview = "Icon preview",
    .lbl_lang_toggle = "ES",
};

const es = I18n{
    .tab_general = "General",
    .tab_behavior = "Comportamiento",
    .tab_widgets = "Widgets",
    .tab_apps = "Aplicaciones",
    .sec_dock = "Dock",
    .sec_margins = "Márgenes",
    .sec_launcher = "Lanzador",
    .sec_hotspot = "Hotspot",
    .sec_animation = "Animación",
    .sec_magnify = "Magnificación",
    .sec_island = "Isla Dinámica",
    .sec_progress = "Progreso",
    .sec_badge = "Insignia",
    .sec_system = "Monitor del Sistema",
    .lbl_position = "Posición",
    .lbl_alignment = "Alineación",
    .lbl_full = "Ancho / alto completo",
    .lbl_layer = "Capa",
    .lbl_exclusive = "Zona exclusiva",
    .lbl_icon_size = "Tamaño de icono (px)",
    .lbl_workspaces = "Espacios de trabajo",
    .lbl_target_output = "Salida destino",
    .lbl_margin_top = "Margen superior (px)",
    .lbl_margin_bottom = "Margen inferior (px)",
    .lbl_margin_left = "Margen izquierdo (px)",
    .lbl_margin_right = "Margen derecho (px)",
    .lbl_show_launcher = "Mostrar lanzador",
    .lbl_launcher_cmd = "Comando del lanzador",
    .lbl_launcher_icon = "Icono del lanzador",
    .lbl_launcher_pos = "Posición del lanzador",
    .lbl_autohide = "Auto-ocultar",
    .lbl_intelli_hide = "Inteli-ocultar",
    .lbl_resident = "Siempre visible",
    .lbl_hotspot_delay = "Retraso hotspot (ms)",
    .lbl_hotspot_layer = "Capa hotspot",
    .lbl_hotspot_size = "Tamaño hotspot (px)",
    .lbl_magnify_scale = "Escala de magnificación",
    .lbl_transition = "Transición (ms)",
    .lbl_ease_curve = "Curva de ease",
    .lbl_magnify_enabled = "Magnificar al pasar",
    .lbl_spread = "Extensión (slots)",
    .lbl_falloff = "Nitidez de curva",
    .lbl_steps = "Pasos de escalera",
    .lbl_ease_time = "Tiempo de ease (ms)",
    .lbl_spring = "Resorte de asentamiento",
    .lbl_spring_strength = "Fuerza del resorte",
    .lbl_island = "Isla Dinámica",
    .lbl_progress = "Barra de progreso",
    .lbl_badge = "Insignia de notificaciones",
    .lbl_badge_threshold = "Umbral de insignia",
    .lbl_sys_monitor = "Monitor del sistema (menú)",
    .lbl_sys_dock = "Píldora en el dock",
    .lbl_sys_interval = "Intervalo de sondeo (ms)",
    .lbl_sys_ram = "Mostrar RAM",
    .lbl_sys_cpu = "Mostrar CPU",
    .lbl_sys_temp = "Mostrar temperatura",
    .lbl_css_file = "Archivo de estilos",
    .lbl_pinned = "Apps fijadas",
    .lbl_ignore_classes = "Clases ignoradas",
    .lbl_ignore_ws = "Espacios ignorados",
    .lbl_save = "Guardar",
    .lbl_saved = "Guardado — el dock se aplica ahora",
    .lbl_icon_preview = "Vista previa del icono",
    .lbl_lang_toggle = "EN",
};

fn i18n() I18n {
    return if (current_lang == .es) es else en;
}

// ---------------------------------------------------------------------------
// Field table: every config option the editor knows, grouped by tab.
// ---------------------------------------------------------------------------

const Kind = enum { boolean, integer, float, string, en_opt, list };

const Field = struct {
    tab: TabKey,
    section: []const u8,
    key: []const u8,
    label_key: []const u8, // key into I18n for the label
    kind: Kind,
    options: []const []const u8 = &.{},
    min: f64 = 0,
    max: f64 = 100,
    step: f64 = 1,
    digits: c_uint = 0,
    help: []const u8 = "",
};

// Helper to look up the translated label from the i18n struct
fn getLabel(label_key: []const u8) []const u8 {
    const il = i18n();
    const map = .{
        .{ "position", il.lbl_position },
        .{ "alignment", il.lbl_alignment },
        .{ "full", il.lbl_full },
        .{ "layer", il.lbl_layer },
        .{ "exclusive", il.lbl_exclusive },
        .{ "icon_size", il.lbl_icon_size },
        .{ "workspaces", il.lbl_workspaces },
        .{ "target_output", il.lbl_target_output },
        .{ "margin_top", il.lbl_margin_top },
        .{ "margin_bottom", il.lbl_margin_bottom },
        .{ "margin_left", il.lbl_margin_left },
        .{ "margin_right", il.lbl_margin_right },
        .{ "show_launcher", il.lbl_show_launcher },
        .{ "launcher_cmd", il.lbl_launcher_cmd },
        .{ "launcher_icon", il.lbl_launcher_icon },
        .{ "launcher_pos", il.lbl_launcher_pos },
        .{ "autohide", il.lbl_autohide },
        .{ "intelli_hide", il.lbl_intelli_hide },
        .{ "resident", il.lbl_resident },
        .{ "hotspot_delay", il.lbl_hotspot_delay },
        .{ "hotspot_layer", il.lbl_hotspot_layer },
        .{ "hotspot_size", il.lbl_hotspot_size },
        .{ "magnify_scale", il.lbl_magnify_scale },
        .{ "transition", il.lbl_transition },
        .{ "ease_curve", il.lbl_ease_curve },
        .{ "magnify_enabled", il.lbl_magnify_enabled },
        .{ "spread", il.lbl_spread },
        .{ "falloff", il.lbl_falloff },
        .{ "steps", il.lbl_steps },
        .{ "ease_time", il.lbl_ease_time },
        .{ "spring", il.lbl_spring },
        .{ "spring_strength", il.lbl_spring_strength },
        .{ "progress", il.lbl_progress },
        .{ "badge", il.lbl_badge },
        .{ "badge_threshold", il.lbl_badge_threshold },
        .{ "sys_monitor", il.lbl_sys_monitor },
        .{ "sys_dock", il.lbl_sys_dock },
        .{ "sys_interval", il.lbl_sys_interval },
        .{ "sys_ram", il.lbl_sys_ram },
        .{ "sys_cpu", il.lbl_sys_cpu },
        .{ "sys_temp", il.lbl_sys_temp },
        .{ "css_file", il.lbl_css_file },
        .{ "pinned", il.lbl_pinned },
        .{ "ignore_classes", il.lbl_ignore_classes },
        .{ "ignore_ws", il.lbl_ignore_ws },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, label_key, entry[0])) return entry[1];
    }
    return label_key;
}    fn getSection(sec: []const u8) []const u8 {
    const il = i18n();
    const map = .{
        .{ "dock", il.sec_dock },
        .{ "margins", il.sec_margins },
        .{ "launcher", il.sec_launcher },
        .{ "hotspot", il.sec_hotspot },
        .{ "animation", il.sec_animation },
        .{ "magnify", il.sec_magnify },
        .{ "island", il.sec_island },
        .{ "progress", il.sec_progress },
        .{ "badge", il.sec_badge },
        .{ "system", il.sec_system },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, sec, entry[0])) return entry[1];
    }
    return sec;
}

const fields = [_]Field{
    // ---- General ----
    .{ .tab = .general, .section = "dock", .key = "position", .label_key = "position", .kind = .en_opt, .options = &.{ "bottom", "top", "left", "right" } },
    .{ .tab = .general, .section = "dock", .key = "alignment", .label_key = "alignment", .kind = .en_opt, .options = &.{ "center", "start", "end" } },
    .{ .tab = .general, .section = "dock", .key = "full", .label_key = "full", .kind = .boolean },
    .{ .tab = .general, .section = "dock", .key = "layer", .label_key = "layer", .kind = .en_opt, .options = &.{ "bottom", "top", "overlay" } },
    .{ .tab = .general, .section = "dock", .key = "exclusive", .label_key = "exclusive", .kind = .boolean },
    .{ .tab = .general, .section = "dock", .key = "icon_size", .label_key = "icon_size", .kind = .integer, .min = 16, .max = 128, .step = 2 },
    .{ .tab = .general, .section = "dock", .key = "num_workspaces", .label_key = "workspaces", .kind = .integer, .min = 1, .max = 20, .step = 1 },
    .{ .tab = .general, .section = "dock", .key = "target_output", .label_key = "target_output", .kind = .string },
    .{ .tab = .general, .section = "margins", .key = "top", .label_key = "margin_top", .kind = .integer, .min = 0, .max = 500, .step = 1 },
    .{ .tab = .general, .section = "margins", .key = "bottom", .label_key = "margin_bottom", .kind = .integer, .min = 0, .max = 500, .step = 1 },
    .{ .tab = .general, .section = "margins", .key = "left", .label_key = "margin_left", .kind = .integer, .min = 0, .max = 500, .step = 1 },
    .{ .tab = .general, .section = "margins", .key = "right", .label_key = "margin_right", .kind = .integer, .min = 0, .max = 500, .step = 1 },
    .{ .tab = .general, .section = "launcher", .key = "show", .label_key = "show_launcher", .kind = .boolean },
    .{ .tab = .general, .section = "launcher", .key = "command", .label_key = "launcher_cmd", .kind = .string },

    // ---- Behavior ----
    .{ .tab = .behavior, .section = "dock", .key = "autohide", .label_key = "autohide", .kind = .boolean },
    .{ .tab = .behavior, .section = "dock", .key = "hide_on_activity", .label_key = "intelli_hide", .kind = .boolean },
    .{ .tab = .behavior, .section = "dock", .key = "resident", .label_key = "resident", .kind = .boolean },
    .{ .tab = .behavior, .section = "hotspot", .key = "delay_ms", .label_key = "hotspot_delay", .kind = .integer, .min = 0, .max = 2000, .step = 5 },
    .{ .tab = .behavior, .section = "animation", .key = "scale", .label_key = "magnify_scale", .kind = .float, .min = 1.0, .max = 3.0, .step = 0.05, .digits = 2 },
    .{ .tab = .behavior, .section = "animation", .key = "duration_ms", .label_key = "transition", .kind = .integer, .min = 50, .max = 2000, .step = 10 },

    // ---- Widgets ----
    .{ .tab = .widgets, .section = "magnify", .key = "enabled", .label_key = "magnify_enabled", .kind = .boolean },
    .{ .tab = .widgets, .section = "magnify", .key = "spread", .label_key = "spread", .kind = .integer, .min = 1, .max = 12, .step = 1 },
    .{ .tab = .widgets, .section = "magnify", .key = "spring", .label_key = "spring", .kind = .boolean },
    .{ .tab = .widgets, .section = "island", .key = "enabled", .label_key = "island", .kind = .boolean },
    .{ .tab = .widgets, .section = "progress", .key = "enabled", .label_key = "progress", .kind = .boolean },
    .{ .tab = .widgets, .section = "badge", .key = "enabled", .label_key = "badge", .kind = .boolean },

    // ---- Apps ----
    .{ .tab = .apps, .section = "apps", .key = "css_file", .label_key = "css_file", .kind = .string },
    .{ .tab = .apps, .section = "apps", .key = "pinned", .label_key = "pinned", .kind = .list },
    .{ .tab = .apps, .section = "apps", .key = "ignore_classes", .label_key = "ignore_classes", .kind = .list },
    .{ .tab = .apps, .section = "apps", .key = "ignore_workspaces", .label_key = "ignore_ws", .kind = .list },
};

var field_widgets: [fields.len]?*anyopaque = .{null} ** fields.len;

// ---------------------------------------------------------------------------
// Icon size live preview
// ---------------------------------------------------------------------------

var icon_preview_area: ?*anyopaque = null;

fn iconPreviewDraw(_: ?*anyopaque, cr: c.Cairo, width: c_int, height: c_int, _: ?*anyopaque) callconv(.c) void {
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);

    // Dark background
    c.cairo_set_source_rgba(cr, 0.08, 0.09, 0.12, 1.0);
    c.cairo_paint(cr);

    // Get current icon_size from the spin button
    var icon_size: f64 = 48;
    for (fields, 0..) |f, i| {
        if (std.mem.eql(u8, f.key, "icon_size")) {
            if (field_widgets[i]) |wi| {
                icon_size = c.gtk_spin_button_get_value(wi);
            }
            break;
        }
    }

    // Draw a dock-like panel
    const panel_h = icon_size + 28;
    const panel_y = h - panel_h - 8;
    const panel_x: f64 = 12;
    const panel_w = w - 24;
    const radius = 14.0;

    // Panel background
    c.cairo_set_source_rgba(cr, 0.12, 0.13, 0.17, 0.90);
    cairoRoundedRect(cr, panel_x, panel_y, panel_w, panel_h, radius);
    c.cairo_fill(cr);

    // Panel border
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.10);
    c.cairo_set_line_width(cr, 1);
    cairoRoundedRect(cr, panel_x, panel_y, panel_w, panel_h, radius);
    c.cairo_stroke(cr);

    // Draw sample icons
    const colors = [_][3]f64{
        .{ 0.94, 0.40, 0.30 },
        .{ 0.30, 0.62, 0.95 },
        .{ 0.98, 0.76, 0.28 },
        .{ 0.36, 0.84, 0.50 },
        .{ 0.72, 0.42, 0.96 },
    };
    const n: f64 = @floatFromInt(colors.len);
    const slot = icon_size + 12;
    const total_w = slot * n;
    const start_x = panel_x + (panel_w - total_w) / 2.0;
    const icon_y = panel_y + (panel_h - icon_size) / 2.0;

    for (colors, 0..) |col, idx| {
        const x = start_x + @as(f64, @floatFromInt(idx)) * slot;
        const round = icon_size * 0.22;

        // Icon body
        c.cairo_set_source_rgba(cr, col[0], col[1], col[2], 0.95);
        cairoRoundedRect(cr, x, icon_y, icon_size, icon_size, round);
        c.cairo_fill(cr);

        // Top sheen
        const sheen = c.cairo_pattern_create_linear(0, icon_y, 0, icon_y + icon_size);
        c.cairo_pattern_add_color_stop_rgba(sheen, 0, 1, 1, 1, 0.30);
        c.cairo_pattern_add_color_stop_rgba(sheen, 0.4, 1, 1, 1, 0.05);
        c.cairo_pattern_add_color_stop_rgba(sheen, 1, 0, 0, 0, 0.15);
        c.cairo_set_source(cr, sheen);
        cairoRoundedRect(cr, x, icon_y, icon_size, icon_size, round);
        c.cairo_fill(cr);
        c.cairo_pattern_destroy(sheen);
    }
}

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

fn refreshIconPreview() void {
    if (icon_preview_area) |g| c.gtk_widget_queue_draw(g);
}

// ---------------------------------------------------------------------------
// Paths
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
// Config value access
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
        if (eq(k, "falloff")) return .{ .f = cfg.magnify_falloff };
        if (eq(k, "steps")) return .{ .i = @intCast(cfg.magnify_steps) };
        if (eq(k, "duration_ms")) return .{ .i = cfg.magnify_duration_ms };
        if (eq(k, "spring")) return .{ .b = cfg.magnify_spring };
        if (eq(k, "spring_strength")) return .{ .f = cfg.magnify_spring_strength };
    } else if (eq(s, "island")) {
        if (eq(k, "enabled")) return .{ .b = cfg.island_enabled };
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
    } else if (eq(s, "apps")) {
        if (eq(k, "css_file")) return .{ .s = cfg.css_file };
        if (eq(k, "pinned")) return .{ .list = cfg.pinned };
        if (eq(k, "ignore_classes")) return .{ .list = cfg.ignore_classes };
        if (eq(k, "ignore_workspaces")) return .{ .list = cfg.ignore_workspaces };
    }
    return .{ .b = false };
}

// ---------------------------------------------------------------------------
// Load / Save
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
        .en_opt => {
            var idx: c_uint = 0;
            for (f.options, 0..) |o, i| {
                if (eq(o, v.s)) { idx = @intCast(i); break; }
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
        if (eq(f.section, "apps") and eq(f.key, "pinned")) {
            if (readPinnedCache()) |list| v = .{ .list = list };
        }
        setWidgetFromVal(f, w, v);
    }
    refreshIconPreview();
}

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
        .en_opt => {
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
            setStatus("Error de memoria");
            return;
        };
        if (updated.ptr != text.ptr) {
            alloc.free(text);
            text = updated;
        }
        if (eq(f.section, "apps") and eq(f.key, "pinned")) {
            var items: std.ArrayList([]const u8) = .empty;
            widgetListItems(w, &items);
            pinned_items = items;
        }
    }

    fs.writeFile(config_path, text) catch {
        setStatus("Error al escribir config");
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

    setStatus(i18n().lbl_saved);
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
        .en_opt => {
            var list: std.ArrayList(?[*:0]const u8) = .empty;
            defer list.deinit(alloc);
            for (f.options) |o| {
                const z = alloc.dupeZ(u8, o) catch continue;
                list.append(alloc, z) catch continue;
            }
            list.append(alloc, null) catch {};
            const drop = c.gtk_drop_down_new_from_strings(@ptrCast(list.items.ptr));
            styleDropdown(drop);
            return drop;
        },
    }
}

fn styleDropdown(drop: ?*anyopaque) void {
    const popover_type = c.gtk_popover_get_type();
    var child = c.gtk_widget_get_first_child(drop);
    while (child != null) {
        const inst: *const c.GTypeInstance = @ptrCast(@alignCast(child.?));
        const obj_type = if (inst.g_class) |cls| cls.g_type else 0;
        if (c.g_type_is_a(obj_type, popover_type) != 0) {
            c.gtk_widget_add_css_class(child, "dockh-config-window");
            return;
        }
        child = c.gtk_widget_get_next_sibling(child);
    }
}

// ---------------------------------------------------------------------------
// Live update: when the icon_size spin changes, redraw the preview
// ---------------------------------------------------------------------------

fn onIconSizeChanged(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    refreshIconPreview();
}

fn onIconSizeSpinChanged(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    refreshIconPreview();
}

// ---------------------------------------------------------------------------
// Language toggle
// ---------------------------------------------------------------------------

var lang_toggle_btn: ?*anyopaque = null;
var tab_notebook: ?*anyopaque = null;
var rebuild_pending = false;

fn rebuildUI() void {
    if (tab_notebook == null or win == null) return;
    // Destroy old notebook child
    if (tab_notebook) |nb| {
        var old_child = c.gtk_widget_get_first_child(nb);
        while (old_child != null) {
            const next = c.gtk_widget_get_next_sibling(old_child);
            c.gtk_widget_unparent(old_child);
            old_child = next;
        }
    }
    // Reset field widgets
    for (&field_widgets) |*fw| fw.* = null;
    // Rebuild tabs
    buildTabs(tab_notebook);
    loadValues();
}

fn onLangToggle(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    current_lang = if (current_lang == .en) .es else .en;
    if (lang_toggle_btn) |b| {
        const z = alloc.dupeZ(u8, i18n().lbl_lang_toggle) catch return;
        c.gtk_button_set_label(b, z.ptr);
    }
    rebuildUI();
}

// ---------------------------------------------------------------------------
// Tab builder
// ---------------------------------------------------------------------------

fn buildTabs(notebook: ?*anyopaque) void {
    const tabs = [_]TabKey{ .general, .behavior, .widgets, .apps };
    const tab_labels = [_][]const u8{ i18n().tab_general, i18n().tab_behavior, i18n().tab_widgets, i18n().tab_apps };

    for (tabs, 0..) |tab_key, idx| {
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

        // Add icon preview on the General tab (after first section)
        if (tab_key == .general) {
            icon_preview_area = c.gtk_drawing_area_new();
            c.gtk_drawing_area_set_content_width(icon_preview_area, 460);
            c.gtk_drawing_area_set_content_height(icon_preview_area, 100);
            c.gtk_drawing_area_set_draw_func(icon_preview_area, @ptrCast(&iconPreviewDraw), null, null);
            c.gtk_widget_set_hexpand(icon_preview_area, 1);
            c.gtk_widget_set_vexpand(icon_preview_area, 0);
            const preview_lbl = c.gtk_label_new(alloc.dupeZ(u8, i18n().lbl_icon_preview) catch "Preview");
            c.gtk_widget_add_css_class(preview_lbl, "dockh-cfg-caption");
            c.gtk_widget_set_halign(preview_lbl, c.ALIGN_START);
            // Insert after the first section header
            // We'll add it at the top before the fields
            c.gtk_grid_attach(grid, preview_lbl, 0, 0, 2, 1);
            c.gtk_grid_attach(grid, icon_preview_area, 0, 1, 2, 1);
        }

        var row: c_int = if (tab_key == .general) @intCast(2) else 0;
        var last_section: []const u8 = "";

        for (fields, 0..) |f, i| {
            if (f.tab != tab_key) continue;
            if (!eq(f.section, last_section)) {
                const head = c.gtk_label_new(alloc.dupeZ(u8, getSection(f.section)) catch "");
                c.gtk_widget_add_css_class(head, "dockh-cfg-section");
                c.gtk_widget_set_halign(head, c.ALIGN_START);
                c.gtk_grid_attach(grid, head, 0, row, 2, 1);
                row += 1;
                last_section = f.section;
            }
            const lbl = c.gtk_label_new(alloc.dupeZ(u8, getLabel(f.label_key)) catch "");
            c.gtk_widget_set_halign(lbl, c.ALIGN_START);
            c.gtk_widget_set_hexpand(lbl, 1);
            const ctl = makeControl(f) orelse continue;
            field_widgets[i] = ctl;

            // Live update icon preview when icon_size changes
            if (eq(f.key, "icon_size")) {
                _ = c.g_signal_connect(ctl, "value-changed", @ptrCast(&onIconSizeChanged), null);
            }

            c.gtk_grid_attach(grid, lbl, 0, row, 1, 1);
            c.gtk_grid_attach(grid, ctl, 1, row, 1, 1);
            row += 1;
        }

        const label_z = alloc.dupeZ(u8, tab_labels[idx]) catch "";
        _ = c.gtk_notebook_append_page(notebook, scrolled, c.gtk_label_new(label_z));
    }
}

// ---------------------------------------------------------------------------
// Build the main window
// ---------------------------------------------------------------------------

fn onSaveClicked(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    saveConfig();
}

fn buildWindow() void {
    const w = c.gtk_window_new();
    win = w;
    c.gtk_widget_set_name(w, "dockh-config-window");
    c.gtk_widget_add_css_class(w, "dockh-config-window");
    c.gtk_window_set_title(w, "dockh — Configuración");
    c.gtk_window_set_default_size(w, 780, 620);
    c.gtk_window_set_resizable(w, 1);

    // Header bar with title + save + language toggle
    const header = c.gtk_header_bar_new();
    c.gtk_widget_add_css_class(header, "dockh-config-window");

    const title_box = c.gtk_box_new(c.ORIENTATION_VERTICAL, 0);
    const title_lbl = c.gtk_label_new("dockh");
    c.gtk_widget_add_css_class(title_lbl, "dockh-cfg-title");
    c.gtk_box_append(title_box, title_lbl);
    c.gtk_header_bar_set_title_widget(header, title_box);

    // Language toggle button
    lang_toggle_btn = c.gtk_button_new_with_label(alloc.dupeZ(u8, i18n().lbl_lang_toggle) catch "ES");
    _ = c.g_signal_connect(lang_toggle_btn, "clicked", @ptrCast(&onLangToggle), null);
    c.gtk_header_bar_pack_end(header, lang_toggle_btn);

    // Save button (suggested-action = accent)
    const save_btn = c.gtk_button_new_with_label(alloc.dupeZ(u8, i18n().lbl_save) catch "Save");
    c.gtk_widget_add_css_class(save_btn, "suggested-action");
    _ = c.g_signal_connect(save_btn, "clicked", @ptrCast(&onSaveClicked), null);
    c.gtk_header_bar_pack_start(header, save_btn);

    c.gtk_window_set_titlebar(w, header);

    // Notebook (tabs)
    tab_notebook = c.gtk_notebook_new();
    buildTabs(tab_notebook);

    // Status bar
    status_label = c.gtk_label_new("");
    c.gtk_widget_add_css_class(status_label, "dockh-cfg-status");
    c.gtk_widget_set_halign(status_label, c.ALIGN_START);
    c.gtk_widget_set_margin_start(status_label, 12);
    c.gtk_widget_set_margin_bottom(status_label, 6);

    const vbox = c.gtk_box_new(c.ORIENTATION_VERTICAL, 0);
    c.gtk_box_append(vbox, tab_notebook);
    c.gtk_box_append(vbox, status_label);

    c.gtk_window_set_child(w, vbox);

    _ = c.g_signal_connect(w, "destroy", @ptrCast(&onWindowDestroy), null);

    loadValues();
}

fn onWindowDestroy(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (main_loop) |ml| c.g_main_loop_quit(ml);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init.Minimal) void {
    perm_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    alloc = perm_arena.allocator();

    const args = init.args.toSlice(alloc) catch &.{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (eq(args[i], "-cfg")) {
            if (i + 1 < args.len) {
                cfg_override = alloc.dupe(u8, args[i + 1]) catch "";
            }
            i += 1;
        }
    }
    config_path = cfgPath();
    _ = fs.ensureDir(configDir());
    if (!fs.pathExists(config_path)) {
        fs.writeFile(config_path, default_toml) catch {};
    }

    // GTK init + CSS
    c.gtk_init();
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

    if (win) |w| c.gtk_widget_show(w);

    main_loop = c.g_main_loop_new(null, 0);
    if (main_loop) |ml| c.g_main_loop_run(ml);
    if (main_loop) |ml| c.g_main_loop_unref(ml);
}
