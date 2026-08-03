//! GTK4 theming: load the user's style.css into a GtkCssProvider bound to the
//! global display, then inject a generated rule that wires the config's
//! animation values (scale / duration / cubic-bezier curve) into CSS
//! `transition: transform` — the dock container keeps its fixed layout while
//! buttons scale/translate/rotate on hover.
//!
//! style.css is hot-reloaded: a GFileMonitor watches the file and, on change,
//! the providers are swapped out (remove old + add new) after a short debounce
//! so partial writes / atomic renames never flash a broken theme.
const std = @import("std");
const c = @import("../c.zig");
const config = @import("../core/config.zig");
const fs = @import("../core/fs.zig");
const log = @import("../core/log.zig");

var file_provider: ?*anyopaque = null;
var anim_provider: ?*anyopaque = null;
// Config pointer for reload(): re-applying the animation provider after the
// file provider keeps the startup precedence (anim added last wins).
var cfg_ref: ?*const config.Config = null;

var monitor: ?*anyopaque = null;
var debounce_timer: c_uint = 0;
var watched_path: [:0]const u8 = "";

// Single source of truth for the settle-spring headroom (see config.zig).

pub fn addProvider(provider: ?*anyopaque) void {
    const display = c.gdk_display_get_default() orelse return;
    c.gtk_style_context_add_provider_for_display(display, provider, c.PROVIDER_PRIORITY_APPLICATION);
}

fn removeProvider(provider: ?*anyopaque) void {
    if (provider) |p| {
        const display = c.gdk_display_get_default() orelse return;
        c.gtk_style_context_remove_provider_for_display(display, p, c.PROVIDER_PRIORITY_APPLICATION);
        c.g_object_unref(p);
    }
}

/// GtkCssProvider::parsing-error — GTK 4.22 reports CSS problems through this
/// signal (load_from_path no longer takes a GError**). Log every error/warning
/// so a bad edit is visible in the dockh log instead of silently failing.
fn onParsingError(_: ?*anyopaque, _: ?*anyopaque, err: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (err) |e| {
        const ge: *c.GError = @ptrCast(@alignCast(e));
        log.warn("CSS parse: {s}", .{std.mem.span(ge.message)});
    }
}

/// Load a CSS file into a fresh provider (already bound to the display).
/// Keeps a reference so it can be swapped out on hot reload.
pub fn loadFile(path_z: [:0]const u8) ?*anyopaque {
    const provider = c.gtk_css_provider_new();
    _ = c.g_signal_connect(provider, "parsing-error", @ptrCast(&onParsingError), null);
    c.gtk_css_provider_load_from_path(provider, path_z.ptr);
    addProvider(provider);
    removeProvider(file_provider); // drop the previous one, if any
    file_provider = provider;
    return provider;
}

/// Build and load the animation override provider from the config.
///
/// With `[magnify]` enabled we generate a ladder of `.dockh-mag-N` CSS
/// buckets (N = 0..steps-1, interpolating scale 1.0 → animation.scale).
/// There is deliberately NO `transition: transform` on the buttons: every
/// bucket change would restart a CSS transition (dozens of times per second
/// while the cursor moves), which GTK renders as constant micro-cuts. Instead
/// widgets.zig eases each icon's scale in code from the frame clock
/// (GtkTickCallback, coalesced once per frame) and applies the rounded bucket
/// instantly — 256 sub-pixel steps make each swap invisible, so the motion
/// is continuous with zero transition restarts.
pub fn loadAnimation(cfg: *const config.Config) void {
    cfg_ref = cfg; // remembered for hot reload
    const alloc = std.heap.page_allocator;
    var css: std.ArrayList(u8) = .empty;
    defer css.deinit(alloc);

    const trans = std.fmt.allocPrint(alloc,
        "#dockh-window .dockh-task,\n" ++
        "#dockh-window .dockh-pinned,\n" ++
        "#dockh-window .dockh-launcher {{\n" ++
        "  transition: transform {d}ms {s},\n" ++
        "              background-color 250ms ease,\n" ++
        "              box-shadow 250ms ease,\n" ++
        "              border-color 250ms ease;\n" ++
        "}}\n",
        .{ cfg.animation_duration_ms, cfg.animation_curve }) catch return;
    defer alloc.free(trans);
    css.appendSlice(alloc, trans) catch return;

    if (cfg.magnify_enabled and cfg.animation_scale > 1.0) {
        // Magnify ladder: one shared rule anchors the scale to the dock's
        // screen edge (icons grow outward from their base, macOS style) and
        // gives every button the short bucket-transition; then one rule per
        // bucket sets the scale. Ordering matters: `:active` (pressed) is
        // emitted AFTER the ladder below, so it wins on equal specificity.
        const origin: []const u8 = if (std.mem.eql(u8, cfg.position, "top"))
            "top center"
        else if (std.mem.eql(u8, cfg.position, "left"))
            "left center"
        else if (std.mem.eql(u8, cfg.position, "right"))
            "right center"
        else
            "bottom center";
        // NO `transition: transform` here — a CSS transition would restart on
        // every bucket class swap (dozens per second while the cursor moves)
        // and GTK would render that as constant micro-cuts. The scale easing
        // is done per-frame in code (widgets.zig magFrame); 256 sub-pixel
        // buckets make the instant class swaps invisible. transform-origin
        // still anchors growth to the dock edge. The fade transitions are
        // kept for hover background/glow (not transform).
        const btn_base = std.fmt.allocPrint(alloc,
            "#dockh-window .dockh-item .dockh-btn {{\n" ++
            "  transform-origin: {s};\n" ++
            "  transition: background-color 250ms ease,\n" ++
            "              box-shadow 250ms ease,\n" ++
            "              border-color 250ms ease;\n" ++
            "}}\n",
            .{origin}) catch return;
        defer alloc.free(btn_base);
        css.appendSlice(alloc, btn_base) catch return;

        const steps: usize = if (cfg.magnify_steps > 1) cfg.magnify_steps else 8;
        // The ladder extends ~15% ABOVE animation.scale so the macOS settle
        // spring (widgets.zig) has headroom: at rest the peak icon sits
        // exactly at animation.scale, and the spring's controlled overshoot
        // pushes it up into this extra zone (buckets that normal magnify
        // never reaches). Must match SPRING_HEADROOM in widgets.zig.
        const top_scale = cfg.animation_scale * (1.0 + config.SPRING_HEADROOM);
        const vertical_dock = std.mem.eql(u8, cfg.position, "left") or std.mem.eql(u8, cfg.position, "right");
        var i: usize = 0;
        while (i < steps) : (i += 1) {
            const t: f64 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps - 1));
            const sc = 1.0 + t * (top_scale - 1.0);
            const rule = std.fmt.allocPrint(alloc,
                "#dockh-window .dockh-item .dockh-btn.dockh-mag-{d} {{ transform: scale({d:.3}); }}\n",
                .{ i, sc }) catch return;
            defer alloc.free(rule);
            css.appendSlice(alloc, rule) catch return;

            // Workspace dots (macOS touch): as the icon magnifies, the
            // indicator row spreads the dots apart along the dock axis
            // (scaleX on bottom/top docks, scaleY on left/right), around its
            // center, while EACH dot counter-scales to keep its circular
            // shape — a pure transform, no layout shift.
            const sep = 1.0 + t * 0.6; // dots spread up to 1.6x at full magnify
            const axis: []const u8 = if (vertical_dock) "Y" else "X";
            const ind_trans = std.fmt.allocPrint(alloc, "scale{s}({d:.3})", .{ axis, sep }) catch return;
            defer alloc.free(ind_trans);
            const ind_rule = std.fmt.allocPrint(alloc,
                "#dockh-window .dockh-item .dockh-indicator.dockh-mag-{d} {{ transform: {s}; }}\n",
                .{ i, ind_trans }) catch return;
            defer alloc.free(ind_rule);
            css.appendSlice(alloc, ind_rule) catch return;

            const dot_trans = std.fmt.allocPrint(alloc, "scale{s}({d:.3})", .{ axis, 1.0 / sep }) catch return;
            defer alloc.free(dot_trans);
            const dot_rule = std.fmt.allocPrint(alloc,
                "#dockh-window .dockh-item .dockh-indicator.dockh-mag-{d} .dockh-wsdot {{ transform: {s}; }}\n",
                .{ i, dot_trans }) catch return;
            defer alloc.free(dot_rule);
            css.appendSlice(alloc, dot_rule) catch return;
        }
    } else {
        // Classic hover scale (magnify disabled). With magnify enabled the
        // frame-clock tick owns the scale; a CSS hover rule would fight it.
        const hover = std.fmt.allocPrint(alloc,
            "#dockh-window .dockh-task:hover,\n" ++
            "#dockh-window .dockh-pinned:hover,\n" ++
            "#dockh-window .dockh-launcher:hover {{\n" ++
            "  transform: scale({d});\n" ++
            "}}\n",
            .{cfg.animation_scale}) catch return;
        defer alloc.free(hover);
        css.appendSlice(alloc, hover) catch return;
    }

    // Press feedback — after the mag ladder so it wins on equal specificity.
    const active = "#dockh-window .dockh-item:active .dockh-btn { transform: scale(0.92); }\n";
    css.appendSlice(alloc, active) catch return;

    const provider = c.gtk_css_provider_new();
    const css_z = alloc.dupeZ(u8, css.items) catch {
        c.g_object_unref(provider);
        return;
    };
    defer alloc.free(css_z);
    c.gtk_css_provider_load_from_string(provider, css_z.ptr);
    addProvider(provider);
    removeProvider(anim_provider);
    anim_provider = provider;
}

// ---------------------------------------------------------------------------
// Hot reload
// ---------------------------------------------------------------------------

/// Start watching `path_z` (must outlive the app — callers pass arena memory).
/// Every change schedules a debounced reload that swaps the providers.
pub fn setupWatch(path_z: [:0]const u8) void {
    watched_path = path_z;
    if (path_z.len == 0) return;

    const file = c.g_file_new_for_path(path_z.ptr);
    if (file == null) return;
    defer c.g_object_unref(file);

    var err: ?*anyopaque = null;
    // WATCH_MOVES: editors that save via rename emit MOVED events; with NONE
    // the same rename only surfaces as DELETED+CREATED (both work, but the
    // moves flag is more accurate).
    const mon = c.g_file_monitor_file(file, c.G_FILE_MONITOR_WATCH_MOVES, null, &err);
    if (mon == null) {
        if (err != null) {
            log.warn("couldn't watch {s}: {any}", .{ path_z, err });
            c.g_error_free(err);
        }
        return;
    }
    if (monitor) |old| {
        _ = c.g_file_monitor_cancel(old);
        c.g_object_unref(old);
    }
    monitor = mon;
    _ = c.g_signal_connect(mon, "changed", @ptrCast(&onFileChanged), null);
    log.info("watching {s} for changes", .{path_z});
}

/// True for the events that actually mean "the file content may have changed"
/// (excludes metadata-only noise like ATTRIBUTE_CHANGED from chmod/touch).
fn contentEvent(ev: c_int) bool {
    return switch (ev) {
        c.G_FILE_MONITOR_EVENT_CHANGED,
        c.G_FILE_MONITOR_EVENT_CHANGES_DONE_HINT,
        c.G_FILE_MONITOR_EVENT_DELETED,
        c.G_FILE_MONITOR_EVENT_CREATED,
        c.G_FILE_MONITOR_EVENT_MOVED,
        c.G_FILE_MONITOR_EVENT_RENAMED,
        c.G_FILE_MONITOR_EVENT_MOVED_IN,
        c.G_FILE_MONITOR_EVENT_MOVED_OUT,
        => true,
        else => false,
    };
}

/// GFileMonitor "changed" — debounce: editors may emit several events in a
/// row (write, atomic rename, metadata). Wait until things settle, then reload.
fn onFileChanged(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, event_type: c_int, _: ?*anyopaque) callconv(.c) void {
    if (!contentEvent(event_type)) return; // chmod/touch noise
    if (debounce_timer != 0) {
        _ = c.g_source_remove(debounce_timer);
        debounce_timer = 0;
    }
    debounce_timer = c.g_timeout_add(150, @ptrCast(&onDebounceTimeout), null);
}

fn onDebounceTimeout(_: ?*anyopaque) callconv(.c) c_int {
    debounce_timer = 0;
    reload();
    return 0; // G_SOURCE_REMOVE
}

/// Re-read style.css and swap the providers. GTK's parser is lenient and
/// resumes after errors, so the new theme always applies; any problem is
/// surfaced through the parsing-error signal (see onParsingError).
pub fn reload() void {
    if (watched_path.len == 0) return;
    // Guard against a mid-write read (slow save / truncation): if the file
    // vanished for a moment, reschedule instead of blanking the theme.
    if (!fs.pathExists(watched_path)) {
        if (debounce_timer != 0) {
            _ = c.g_source_remove(debounce_timer);
            debounce_timer = 0;
        }
        debounce_timer = c.g_timeout_add(150, @ptrCast(&onDebounceTimeout), null);
        return;
    }
    const provider = c.gtk_css_provider_new();
    _ = c.g_signal_connect(provider, "parsing-error", @ptrCast(&onParsingError), null);
    c.gtk_css_provider_load_from_path(provider, watched_path.ptr);
    addProvider(provider);
    if (file_provider) |old| {
        const display = c.gdk_display_get_default() orelse return;
        c.gtk_style_context_remove_provider_for_display(display, old, c.PROVIDER_PRIORITY_APPLICATION);
        c.g_object_unref(old);
    }
    file_provider = provider;
    // Re-apply the animation provider last so the config's transition/scale
    // keeps winning over the file, exactly like at startup.
    if (cfg_ref) |cfg| loadAnimation(cfg);
    log.info("theme reloaded from {s}", .{watched_path});
}
