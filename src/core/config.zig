//! dockh configuration: a small TOML-lite loader (sections, key = value,
//! comments, strings, ints, floats, bools and string arrays) plus CLI
//! overrides. Kept dependency-free on purpose: Zig 0.16 has no runtime TOML
//! parser in std, and std.json is overkill for a human-edited file.
const std = @import("std");
const fs = @import("fs.zig");

/// The .dockh-mag-N ladder (theme.zig) extends this much ABOVE
/// animation.scale so the settle spring (widgets.zig) has headroom to
/// overshoot visibly — the resting magnify peak maps to exactly
/// animation.scale and the bounce lands in the zone above it. Single
/// source of truth: theme.zig and widgets.zig both import it, so the
/// ladder top and the target mapping can never drift apart.
pub const SPRING_HEADROOM: f64 = 0.15;

pub const Config = struct {
    // [dock]
    position: []const u8 = "bottom", // bottom | top | left | right
    alignment: []const u8 = "center", // start | center | end
    full: bool = false,
    layer: []const u8 = "bottom", // overlay | top | bottom (bottom = behind windows)
    exclusive: bool = false,
    autohide: bool = false,
    hide_on_activity: bool = false, // intellihide: hide when the active ws has windows
    resident: bool = false,
    icon_size: i32 = 32,
    num_workspaces: i32 = 10,
    target_output: []const u8 = "",

    // [margins]
    margin_top: i32 = 0,
    margin_bottom: i32 = 0,
    margin_left: i32 = 0,
    margin_right: i32 = 0,

    // [launcher]
    launcher_cmd: []const u8 = "nwg-drawer",
    launcher_icon: []const u8 = "",
    no_launcher: bool = true, // launcher hidden by default (set show = true to enable)
    launcher_pos: []const u8 = "end", // start | end

    // [hotspot]
    hotspot_delay_ms: i64 = 20,
    hotspot_layer: []const u8 = "overlay", // overlay | top
    hotspot_size: i32 = 0, // 0 = auto (1/3 of the monitor edge length)

    // [animation] — injected into the CSS at runtime (transform/transition)
    animation_scale: f64 = 1.5,
    animation_duration_ms: i64 = 200,
    animation_curve: []const u8 = "cubic-bezier(0.34, 1.56, 0.64, 1)",

    // [magnify] — macOS proximity magnification: icons scale by distance to
    // the cursor (closest scales most, far icons stay at 1.0). The scale is
    // eased per frame in code inside a frame-clock tick (exponential
    // smoothing, no CSS transition — transitions restart on every bucket
    // change and render as micro-cuts). `steps` = 256 makes each bucket
    // sub-pixel (~0.06 px on 32 px icons), so instant swaps look continuous.
    // `duration_ms` is the exponential ease constant (higher = smoother).
    magnify_enabled: bool = true,
    magnify_spread: i32 = 3, // effect radius in icon slots from the cursor
    magnify_steps: usize = 256, // bucket ladder size (sub-pixel steps = smooth)
    magnify_duration_ms: i64 = 40, // ease time constant in ms (higher = smoother follow)
    // macOS settle spring: when the pointer stops over the dock, the icons
    // complete their motion with one tiny damped bounce (a controlled
    // overshoot) before resting — all in code, no CSS transition.
    magnify_spring: bool = true,
    magnify_spring_strength: f64 = 0.06, // bounce amplitude, fraction of each icon's scale (0–0.25)

    // [glow] — in-dock blur/glow behind the active app's icon (self-contained,
    // no compositor blur: GskGLShaderNode on GTK < 4.16, GskBlurNode after).
    glow_enabled: bool = true,
    glow_radius: f32 = 8, // Gaussian radius in px (0 disables)

    // [progress] — macOS-style media progress bar under the icon (playerctl)
    progress_enabled: bool = true,

    // [badge] — notification counter on the app icon (makoctl). `threshold`
    // is the notification count at which the badge switches to the
    // `.dockh-badge.high` state (typically styled red); 0 disables the
    // high state entirely (the badge always keeps its base style).
    badge_enabled: bool = true,
    badge_threshold: usize = 5,

    // [apps]
    css_file: []const u8 = "style.css",
    pinned: []const []const u8 = &.{},
    ignore_classes: []const []const u8 = &.{},
    ignore_workspaces: []const []const u8 = &.{},

    pub fn defaults() Config {
        return .{};
    }
};

const Err = error{ ConfigFileNotFound, OutOfMemory };

/// Parse a dockh config file into `cfg`. Only keys found in the file are
/// overwritten; everything else keeps its default. All strings are copied
/// into `alloc`.
pub fn parseFile(alloc: std.mem.Allocator, path: []const u8, cfg: *Config) !void {
    const data = fs.readFileAlloc(alloc, path, 1 << 20) catch |e| switch (e) {
        error.FileNotFound => return Err.ConfigFileNotFound,
        else => return e,
    };
    defer alloc.free(data);

    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            section = std.mem.trim(u8, line[1..close], " \t");
            continue;
        }

        const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_pos], " \t");
        var value = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");
        if (key.len == 0) continue;

        // Strip inline comments (TOML: '#' starts a comment anywhere outside
        // a quoted string). If the value starts with a quote, keep up to the
        // closing quote; otherwise cut at the first '#'.
        if (value.len > 0 and value[0] == '"') {
            if (std.mem.indexOfScalarPos(u8, value, 1, '"')) |end| {
                value = value[0 .. end + 1];
            }
        } else if (std.mem.indexOfScalar(u8, value, '#')) |h| {
            value = std.mem.trim(u8, value[0..h], " \t");
        }

        applyKey(alloc, cfg, section, key, value) catch {};
    }
}

fn applyKey(alloc: std.mem.Allocator, cfg: *Config, section: []const u8, key: []const u8, value: []const u8) !void {
    const full = if (section.len > 0)
        try std.fmt.allocPrint(alloc, "{s}.{s}", .{ section, key })
    else
        try alloc.dupe(u8, key);
    defer alloc.free(full);

    if (eq(full, "dock.position")) return setStr(alloc, &cfg.position, value);
    if (eq(full, "dock.alignment")) return setStr(alloc, &cfg.alignment, value);
    if (eq(full, "dock.full")) return setBool(&cfg.full, value);
    if (eq(full, "dock.layer")) return setStr(alloc, &cfg.layer, value);
    if (eq(full, "dock.exclusive")) return setBool(&cfg.exclusive, value);
    if (eq(full, "dock.autohide")) return setBool(&cfg.autohide, value);
    if (eq(full, "dock.hide_on_activity")) return setBool(&cfg.hide_on_activity, value);
    if (eq(full, "dock.resident")) return setBool(&cfg.resident, value);
    if (eq(full, "dock.icon_size")) return setInt(&cfg.icon_size, value);
    if (eq(full, "dock.num_workspaces")) return setInt(&cfg.num_workspaces, value);
    if (eq(full, "dock.target_output")) return setStr(alloc, &cfg.target_output, value);

    if (eq(full, "margins.top")) return setInt(&cfg.margin_top, value);
    if (eq(full, "margins.bottom")) return setInt(&cfg.margin_bottom, value);
    if (eq(full, "margins.left")) return setInt(&cfg.margin_left, value);
    if (eq(full, "margins.right")) return setInt(&cfg.margin_right, value);

    if (eq(full, "launcher.command")) return setStr(alloc, &cfg.launcher_cmd, value);
    if (eq(full, "launcher.icon")) return setStr(alloc, &cfg.launcher_icon, value);
    if (eq(full, "launcher.show")) {
        var shown = true;
        setBool(&shown, value) catch {};
        cfg.no_launcher = !shown;
        return;
    }
    if (eq(full, "launcher.position")) return setStr(alloc, &cfg.launcher_pos, value);

    if (eq(full, "hotspot.delay_ms")) return setInt(&cfg.hotspot_delay_ms, value);
    if (eq(full, "hotspot.layer")) return setStr(alloc, &cfg.hotspot_layer, value);
    if (eq(full, "hotspot.size")) return setInt(&cfg.hotspot_size, value);

    if (eq(full, "animation.scale")) return setFloat(&cfg.animation_scale, value);
    if (eq(full, "animation.duration_ms")) return setInt(&cfg.animation_duration_ms, value);
    if (eq(full, "animation.curve")) return setStr(alloc, &cfg.animation_curve, value);

    if (eq(full, "magnify.enabled")) return setBool(&cfg.magnify_enabled, value);
    if (eq(full, "magnify.spread")) return setInt(&cfg.magnify_spread, value);
    if (eq(full, "magnify.steps")) {
        // Clamp the ladder size: theme.zig emits one CSS rule per bucket, so a
        // pathological value would balloon the generated stylesheet on every
        // startup and hot reload. 512 is far beyond sub-pixel anyway.
        var s: usize = cfg.magnify_steps;
        setInt(&s, value) catch {};
        if (s < 2) s = 2;
        if (s > 512) s = 512;
        cfg.magnify_steps = s;
        return;
    }
    if (eq(full, "magnify.duration_ms")) return setInt(&cfg.magnify_duration_ms, value);
    if (eq(full, "magnify.spring")) return setBool(&cfg.magnify_spring, value);
    if (eq(full, "magnify.spring_strength")) {
        var f: f64 = cfg.magnify_spring_strength;
        setFloat(&f, value) catch {};
        if (f < 0) f = 0;
        if (f > 0.25) f = 0.25;
        cfg.magnify_spring_strength = f;
        return;
    }

    if (eq(full, "glow.enabled")) return setBool(&cfg.glow_enabled, value);
    if (eq(full, "glow.radius")) {
        var f: f64 = cfg.glow_radius;
        setFloat(&f, value) catch {};
        cfg.glow_radius = @floatCast(f);
        return;
    }

    if (eq(full, "progress.enabled")) return setBool(&cfg.progress_enabled, value);
    if (eq(full, "badge.enabled")) return setBool(&cfg.badge_enabled, value);
    if (eq(full, "badge.threshold")) {
        var t: usize = cfg.badge_threshold;
        setInt(&t, value) catch {};
        cfg.badge_threshold = t;
        return;
    }

    if (eq(full, "apps.css_file")) return setStr(alloc, &cfg.css_file, value);
    if (eq(full, "apps.pinned")) return setStrList(alloc, &cfg.pinned, value);
    if (eq(full, "apps.ignore_classes")) return setStrList(alloc, &cfg.ignore_classes, value);
    if (eq(full, "apps.ignore_workspaces")) return setStrList(alloc, &cfg.ignore_workspaces, value);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn setStr(alloc: std.mem.Allocator, dst: *[]const u8, value: []const u8) !void {
    const v = std.mem.trim(u8, value, " \t");
    if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') {
        dst.* = try alloc.dupe(u8, v[1 .. v.len - 1]);
    } else {
        dst.* = try alloc.dupe(u8, v);
    }
}

fn setBool(dst: *bool, value: []const u8) !void {
    const v = std.mem.trim(u8, value, " \t\"");
    if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "yes") or std.mem.eql(u8, v, "on") or std.mem.eql(u8, v, "1")) {
        dst.* = true;
    } else if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "no") or std.mem.eql(u8, v, "off") or std.mem.eql(u8, v, "0")) {
        dst.* = false;
    }
}

fn setInt(dst: anytype, value: []const u8) !void {
    const v = std.mem.trim(u8, value, " \t\"");
    dst.* = std.fmt.parseInt(@TypeOf(dst.*), v, 10) catch dst.*;
}

fn setFloat(dst: *f64, value: []const u8) !void {
    const v = std.mem.trim(u8, value, " \t\"");
    dst.* = std.fmt.parseFloat(f64, v) catch dst.*;
}

/// Parses `["a", "b", "c"]` (or a bare comma-separated list) into a slice of
/// freshly allocated strings.
fn setStrList(alloc: std.mem.Allocator, dst: *[]const []const u8, value: []const u8) !void {
    var inner = std.mem.trim(u8, value, " \t");
    if (inner.len >= 2 and inner[0] == '[' and inner[inner.len - 1] == ']') {
        inner = inner[1 .. inner.len - 1];
    }
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t");
        if (item.len == 0) continue;
        var clean = item;
        if (clean.len >= 2 and clean[0] == '"' and clean[clean.len - 1] == '"') {
            clean = clean[1 .. clean.len - 1];
        }
        try out.append(alloc, try alloc.dupe(u8, clean));
    }
    dst.* = try out.toOwnedSlice(alloc);
}
