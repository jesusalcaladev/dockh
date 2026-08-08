//! Dock widgets. Every clickable item is a box with:
//!   [icon button] + [CSS indicator bar]
//! styled entirely through CSS classes — the liquid-glass look is pure CSS +
//! Hyprland layerrule blur, and the container keeps fixed dimensions while
//! buttons get `transform: scale()` transitions (no layout jitter).
const std = @import("std");
const c = @import("c"); // named module (build.zig)
const config_mod = @import("../core/config.zig");
const state = @import("../core/state.zig");
const hypr = @import("../hypr/ipc.zig");
const desktop = @import("../hypr/desktop.zig");
const blur = @import("blur.zig");

const main_mod = @import("../main.zig");
const log = @import("../core/log.zig");

const BtnData = struct {
    class: []const u8 = "",
    address: []const u8 = "",
    multiple: bool = false,
    pinned: bool = false,
    launcher: bool = false,
    anchor: ?*anyopaque = null,
};

/// GTK4 popovers are parented widgets that do NOT destroy themselves on close,
/// so repeated clicks would leak entire popover trees. Track them and destroy
/// when replacing. `nested_popover` is the "move to workspace" menu that lives
/// inside the context menu (it must not dismiss its parent).
///
/// CRITICAL: GTK destroys popovers on its own — autohide when the user clicks
/// outside, Escape, or the anchor being torn down during a dock rebuild. Every
/// popover gets a `destroy` handler (trackPopover) that nulls whichever global
/// points at it, so the next dismissPopover can never unref freed memory (the
/// `g_object_unref: G_IS_OBJECT` assertion the dock used to crash with).
var current_popover: ?*anyopaque = null;
var nested_popover: ?*anyopaque = null;

// ---------------------------------------------------------------------------
// Status widgets registry (progress bar + notification badge per app)
// ---------------------------------------------------------------------------
// The dock is rebuilt on every Hyprland event, but progress (playerctl) and
// notification counts (makoctl) arrive on timers. Keep the per-class status
// widgets here so polls can update them without rebuilding the whole dock.

const ItemStatus = struct {
    class: []const u8 = "",
    progress: ?*anyopaque = null,
    badge: ?*anyopaque = null,
};

var item_status: std.ArrayList(ItemStatus) = .empty;

/// The optional system monitor (RAM / CPU / temp) has TWO possible homes:
///
///  * `sys_label` — the always-visible pill at the end of the dock, but ONLY
///    when `[system] dock = true` (opt-in: constant stats in a dock are
///    noise — the context menu is the good UX). Recreated on every rebuild,
///    wiped in clearBox.
///  * `sys_menu_label` — the live "System" section at the bottom of the
///    right-click context menu, updated by the same pollSystem timer while
///    the popover is open. Created per popover, cleared when dismissed.
///
/// setSystemText/setSystemVisible write to whichever is currently alive.
var sys_label: ?*anyopaque = null;
var sys_menu_label: ?*anyopaque = null;
/// The popover that owns sys_menu_label — when THAT popover is destroyed (by
/// us or by GTK), the label dies with its tree, so both pointers must clear
/// together. Other popovers (e.g. the nested "move to workspace" menu) have
/// no system section and must not clobber it.
var sys_menu_pop: ?*anyopaque = null;

/// Set the media-progress fraction (0 hides the bar) for one app class.
/// An empty `class` (no player) hides every progress bar.
pub fn setProgress(class: []const u8, fraction: f64) void {
    for (item_status.items) |it| {
        const match = class.len == 0 or std.ascii.eqlIgnoreCase(it.class, class);
        if (!match) continue;
        if (it.progress) |p| {
            // Only show with REAL progress (>= 0.5%): a fraction of ~0 with a
            // visible trough reads as an empty white line "doing nothing".
            if (fraction >= 0.005 and fraction <= 1) {
                c.gtk_progress_bar_set_fraction(p, fraction);
                c.gtk_widget_show(p);
            } else {
                c.gtk_widget_hide(p);
            }
        }
    }
}

/// Set the notification badge (0 hides it) for one app class. The label
/// text lives in a stack buffer — gtk_label_set_text copies it, so there's
/// no per-poll allocation churn.
pub fn setBadge(class: []const u8, count: usize) void {
    if (class.len == 0) return;
    if (log.debug_enabled) {
        log.debug("badge {s} -> {d}", .{ class, count });
    }
    var buf: [8]u8 = undefined;
    const txt = if (count > 99) "99+" else std.fmt.bufPrint(&buf, "{d}", .{count}) catch "0";
    // [9:0]: 8 chars max + explicit NUL; gtk_label_set_text copies the text.
    var zbuf: [9:0]u8 = undefined;
    @memset(zbuf[0..9], 0);
    const n = @min(txt.len, @as(usize, 8));
    @memcpy(zbuf[0..n], txt[0..n]);
    // Configurable "high" state: at `badge.threshold` notifications the badge
    // gains the .dockh-badge.high class (styled red by default). Threshold 0
    // disables the switch — the badge always keeps its base style.
    const high = state.cfg.badge_threshold > 0 and count >= state.cfg.badge_threshold;
    const high_z: [5:0]u8 = .{ 'h', 'i', 'g', 'h', 0 };
    for (item_status.items) |it| {
        if (!std.ascii.eqlIgnoreCase(it.class, class)) continue;
        if (it.badge) |b| {
            if (high) {
                c.gtk_widget_add_css_class(b, &high_z);
            } else {
                c.gtk_widget_remove_css_class(b, &high_z);
            }
            if (count > 0) {
                c.gtk_label_set_text(b, &zbuf);
                c.gtk_widget_show(b);
            } else {
                c.gtk_widget_hide(b);
            }
        }
    }
}

/// Fresh slice (in `alloc`) of every class that has status widgets — used by
/// the badge poll to reset counts that dropped to zero.
pub fn statusClasses(alloc: std.mem.Allocator) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (item_status.items) |it| {
        out.append(alloc, it.class) catch {};
    }
    return out.toOwnedSlice(alloc) catch &.{};
}

// ---------------------------------------------------------------------------
// macOS proximity magnification
// ---------------------------------------------------------------------------
// The dock box carries a GtkEventControllerMotion (main.zig). On every motion
// it calls applyMagnify(px, py) with the pointer position in main_box
// coordinates; each item gets a `.dockh-mag-N` CSS bucket (N interpolating
// 1.0 → animation.scale, generated in theme.zig) from its distance to the
// cursor — gaussian falloff like the macOS dock.
//
// Why easing in code and NOT a CSS transition? GTK4 has no working per-widget
// transform for children of a layout (gtk_widget_allocate's transform is only
// valid on top-levels — verified empirically: 177 pushes, zero visible
// change), so the scale has to go through CSS buckets. But a
// `transition: transform` restarts on EVERY bucket class swap, and while the
// cursor moves the bucket changes every frame — GTK renders that constant
// transition-restart as micro-cuts (the "choppy" the user kept seeing). The
// macOS way: ease a continuous scale value per frame inside the frame-clock
// tick (exponential smoothing with the real dt), and apply the rounded bucket
// instantly. With 256 buckets each step is ~0.06 px — sub-pixel, invisible —
// so instant swaps look perfectly continuous with ZERO transition restarts.
// The leave-shrink is eased the same way (the tick stays alive until settled).

const MagEntry = struct {
    widget: ?*anyopaque = null,
    /// Optional second widget mirroring the same CSS bucket: the workspace
    /// dot row under the icon. Sharing one entry (instead of a second
    /// distance computation) keeps the dots spreading in EXACT sync with the
    /// button — the row's scaleX follows the icon's scale curve precisely.
    linked: ?*anyopaque = null,
    bucket: usize = 0, // last applied CSS bucket
    scale: f64 = 0, // continuous eased position in [0, steps-1]
};

var mag_items: std.ArrayList(MagEntry) = .empty;
var mag_pointer: struct { x: f64, y: f64 } = .{ .x = 0, .y = 0 };
var mag_inside = false; // pointer currently over the dock box
var mag_tick: c_uint = 0;
var last_tick_us: i64 = 0; // previous frame-clock time (µs) for the dt

// macOS settle spring: when the pointer stops moving over the dock (idle >
// SPRING_IDLE_MS), the icons don't just freeze mid-motion — they complete
// their magnification with one tiny damped bounce (a controlled overshoot)
// before resting, exactly like the real dock "catching" the cursor. The
// spring perturbs each icon's scale TARGET proportionally to that icon's own
// magnification (so the peak icon bounces most and far icons stay put) and
// is integrated in the same per-frame tick, in code — no CSS transition.
const SPRING_IDLE_MS: i64 = 120; // pointer must be still this long to settle
const SPRING_ZETA: f64 = 0.6; // damping ratio (< 1 = underdamped = overshoot)
const SPRING_OMEGA: f64 = 30.0; // natural frequency rad/s (~5 Hz bounce)
const SPRING_MAX_S: f64 = 0.55; // the bounce is done after ~550 ms

// SPRING_HEADROOM lives in config.zig (single source of truth shared with
// theme.zig's ladder) — see config_mod.SPRING_HEADROOM below.
const SPRING_HEADROOM = config_mod.SPRING_HEADROOM;

// macOS click spring: pressing an icon squashes it down briefly (a quick
// dip), and releasing springs it back with a PRONOUNCED overshoot — like the
// real dock when you click an app. Both phases are integrated in the same
// per-frame tick as the settle spring, applied only to the CLICKED icon
// (matched by widget pointer, so far icons stay put). The press dip uses a
// stiffer, faster spring; the release bounce uses the same ζ/ω shape as the
// settle spring but with a much larger amplitude.
const PRESS_ZETA: f64 = 0.7; // quick dip: less overshoot, snappier
const PRESS_OMEGA: f64 = 40.0; // faster oscillation (~6.4 Hz)
const PRESS_MAX_S: f64 = 0.28; // dip is done after ~280 ms
const RELEASE_ZETA: f64 = 0.6; // same damping as the settle spring
const RELEASE_OMEGA: f64 = 30.0; // same frequency as the settle spring
const RELEASE_MAX_S: f64 = 0.55; // bounce is done after ~550 ms

var spring_active = false; // pointer idle -> a settle bounce is running
var spring_t: f64 = 0; // seconds since the bounce started
var spring_fired = false; // one bounce per idle period (no re-trigger loop)
var mag_last_move_us: i64 = 0; // monotonic µs of the last pointer move

// click spring state: the widget that was pressed/released and its phase
var press_widget: ?*anyopaque = null;
var press_active = false;
var press_t: f64 = 0;
var release_widget: ?*anyopaque = null;
var release_active = false;
var release_t: f64 = 0;

// macOS ghost launch: clicking a pinned app that ISN'T running bounces the
// icon and fades it out toward the app that opens — the "ghost" flying into
// the launch, like the real dock. The clicked icon scales up to
// ghost_scale and its opacity drops to 0 over ghost_ms, driven in the same
// frame-clock tick; when the app's openwindow event lands, the rebuild
// replaces the ghost with the live running icon.
var ghost_widget: ?*anyopaque = null;
var ghost_active = false;
var ghost_t: f64 = 0;
var ghost_dur: f64 = 0.6; // seconds, from config at trigger time

/// Monotonic microseconds (CLOCK_MONOTONIC) — used to detect that the
/// pointer stopped moving over the dock (idle), which triggers the spring.
fn monoUs() i64 {
    var ts: c.Timespec = .{};
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return ts.sec * 1_000_000 + @divTrunc(ts.nsec, 1_000);
}

fn registerMagItem(w: ?*anyopaque) void {
    if (!state.cfg.magnify_enabled) return;
    mag_items.append(state.ui_alloc, .{ .widget = w }) catch {};
}

/// Register a magnify entry whose `linked` widget (the workspace dot row)
/// mirrors the icon's bucket, so the dots spread in sync with the icon.
fn registerMagItemLinked(w: ?*anyopaque, linked: ?*anyopaque) void {
    if (!state.cfg.magnify_enabled) return;
    mag_items.append(state.ui_alloc, .{ .widget = w, .linked = linked }) catch {};
}

/// Cursor distance (in icon slots) -> continuous scale position [0..steps-1].
/// A Cauchy (Lorentzian) "lens" curve — the shape of the real macOS dock. The
/// old gaussian used σ = 0.4·spread, which left the neighbor at 1 slot at
/// 0.707 of the peak — nearly the same size as the hovered icon, so the
/// whole row looked flat and left/right were indistinguishable. Cauchy has a
/// much sharper peak: with the default falloff (0.24, σ = 0.72 slots) the
/// immediate neighbors drop to ~0.34 of the peak and a second neighbor to
/// ~0.12 — clearly smaller, macOS-like — while the steep slope near the
/// peak also makes the LEFT/RIGHT asymmetry real: a cursor at 1/4 of the
/// hovered icon gives the near neighbor ~0.48 and the far one ~0.25. The
/// effect reaches out to the `spread` limit, where it is hard-cut to 0 so
/// icons beyond the radius stay perfectly still (matches the `spread`
/// "effect radius" semantic in the config).
fn magScale(dist_slots: f64, maxb: f64) f64 {
    const spread: f64 = @floatFromInt(state.cfg.magnify_spread);
    if (spread <= 0) return 0;
    if (dist_slots >= spread) return 0; // hard cutoff: nothing moves past `spread`
    const sigma = spread * state.cfg.magnify_falloff;
    if (sigma <= 0) return 0;
    const t = dist_slots / sigma;
    const falloff = 1.0 / (1.0 + t * t);
    return falloff * maxb;
}

/// Swap the `dockh-mag-N` CSS class on one widget (N = the bucket). The class
/// names live in stack buffers — gtk_widget_add/remove_css_class copy them.
fn applyBucket(w: ?*anyopaque, old_bucket: usize, new_bucket: usize) void {
    if (w == null) return;
    var old_buf: [32]u8 = undefined;
    const old_name = std.fmt.bufPrint(&old_buf, "dockh-mag-{d}", .{old_bucket}) catch return;
    var old_z: [33]u8 = undefined;
    const on = @min(old_name.len, 32);
    @memcpy(old_z[0..on], old_name[0..on]);
    old_z[on] = 0;
    c.gtk_widget_remove_css_class(w, old_z[0..on :0]);

    var new_buf: [32]u8 = undefined;
    const new_name = std.fmt.bufPrint(&new_buf, "dockh-mag-{d}", .{new_bucket}) catch return;
    var new_z: [33]u8 = undefined;
    const nn = @min(new_name.len, 32);
    @memcpy(new_z[0..nn], new_name[0..nn]);
    new_z[nn] = 0;
    c.gtk_widget_add_css_class(w, new_z[0..nn :0]);
}

fn setMagBucket(item: *MagEntry, bucket: usize) void {
    if (item.bucket == bucket) return;
    // The icon button and its workspace-dot row share the same bucket, so
    // the dots spread apart in exact sync with the icon's own scale.
    applyBucket(item.widget, item.bucket, bucket);
    applyBucket(item.linked, item.bucket, bucket);
    item.bucket = bucket;
}

/// One frame: ease every item's continuous scale toward its target (computed
/// from the last pointer position) with exponential smoothing, then apply the
/// rounded bucket instantly. Returns true while anything is still moving
/// (keep the tick alive) — including the leave-shrink, which is eased the
/// same way instead of snapping.
fn magFrame(dt: f64) bool {
    const box = state.main_box orelse return false;
    const steps: usize = if (state.cfg.magnify_steps > 1) state.cfg.magnify_steps else 8;
    const maxb: f64 = @floatFromInt(steps - 1);
    // Map the resting magnify peak to EXACTLY animation.scale, leaving the
    // ladder buckets above it (theme.zig extends 15% higher) as headroom that
    // the settle spring can bounce into — otherwise the peak icon clamps at
    // the ladder top and the macOS overshoot is invisible.
    const anim_scale: f64 = @max(state.cfg.animation_scale, 1.0);
    const top_scale = anim_scale * (1.0 + SPRING_HEADROOM);
    const anim_bucket_peak = maxb * (anim_scale - 1.0) / (top_scale - 1.0);
    // exponential smoothing factor: alpha = 1 - exp(-dt / tau),
    // tau = magnify_duration_ms (the "feel" constant, like macOS).
    const tau_ms: f64 = @floatFromInt(@max(state.cfg.magnify_duration_ms, 8));
    const alpha = 1.0 - @exp(-(dt * 1000.0) / tau_ms);
    // The tick must stay alive while the pointer is inside OR a click spring
    // phase is still running — hoisted OUT of the loop so a
    // translate_coordinates failure (widgets not yet realized right after a
    // rebuild) can never kill it and freeze the animation until the next
    // motion event re-arms it.
    var moving = mag_inside or press_active or release_active or ghost_active;

    // macOS settle spring: while the pointer is inside and stops moving
    // (idle > SPRING_IDLE_MS), each icon completes its motion with one tiny
    // damped bounce — the "controlled overshoot" — before resting. The
    // bounce perturbs the icon's scale target (proportional to its own
    // magnification: the peak icon bounces most, distant icons stay put) and
    // decays exponentially; the per-frame easing then chases the perturbed
    // target, so there is no CSS transition and no discontinuity.
    const now_us = monoUs();
    const idle = mag_inside and state.cfg.magnify_spring and
        state.cfg.magnify_spring_strength > 0 and // strength 0 = no bounce at all
        (now_us - mag_last_move_us) >= SPRING_IDLE_MS * 1_000;
    if (!idle) {
        // pointer moving again (or left): reset the one-shot guard
        spring_active = false;
        spring_t = 0;
        spring_fired = false;
    } else if (!spring_active and !spring_fired) {
        spring_active = true; // trigger: sin(0) = 0, so it starts continuously
        spring_t = 0;
        spring_fired = true; // only once per idle period, or it loops forever
        if (log.debug_enabled) log.debug("magnify settle spring: bounce", .{});
    }
    var spring_k: f64 = 1.0; // target multiplier while the bounce runs
    if (spring_active) {
        spring_t += dt;
        if (spring_t >= SPRING_MAX_S) {
            spring_active = false;
        } else {
            // exp(-ζωt)·sin(ω_d·t), normalized so the first swing peaks at
            // ~spring_strength (the "controlled overshoot" fraction). The
            // peak factor is derived ANALYTICALLY from ζ/ω (first maximum of
            // e^(-at)·sin(bt): t_peak = atan(b/a)/b), so tuning the spring
            // constants never silently changes what `spring_strength` means.
            const wd = SPRING_OMEGA * @sqrt(1.0 - SPRING_ZETA * SPRING_ZETA);
            const a = SPRING_ZETA * SPRING_OMEGA;
            const t_peak = std.math.atan(wd / a) / wd;
            const peak = @exp(-a * t_peak) * @sin(wd * t_peak);
            const env = @exp(-a * spring_t) * @sin(wd * spring_t);
            spring_k = 1.0 + (state.cfg.magnify_spring_strength / peak) * env;
        }
    }
    // click spring: advance both phases once per frame
    if (press_active) {
        press_t += dt;
        if (press_t >= PRESS_MAX_S) press_active = false;
    }
    if (release_active) {
        release_t += dt;
        if (release_t >= RELEASE_MAX_S) release_active = false;
    }
    // macOS ghost launch: advance the phase; when it ends restore the icon
    // (the openwindow event usually rebuilds and replaces it before then, but
    // a slow launch leaves the ghost faded — bring it back so it's not stuck).
    if (ghost_active) {
        ghost_t += dt;
        if (ghost_t >= ghost_dur) {
            ghost_active = false;
            if (ghost_widget) |gw| c.gtk_widget_set_opacity(gw, 1.0);
            ghost_widget = null;
        }
    }

    for (mag_items.items) |*item| {
        const w = item.widget orelse continue;
        var target: f64 = 0;
        if (mag_inside) {
            var ix: f64 = 0;
            var iy: f64 = 0;
            // FALSE if the widgets aren't realized yet — the center would be
            // bogus (0,0), so keep the current scale until it's mapped.
            if (c.gtk_widget_translate_coordinates(w, box, 0, 0, &ix, &iy) == 0) continue;
            const iw: f64 = @floatFromInt(c.gtk_widget_get_width(w));
            const ih: f64 = @floatFromInt(c.gtk_widget_get_height(w));
            const cx = ix + iw / 2;
            const cy = iy + ih / 2;
            // distance along the dock axis (x for horizontal dock, y for vertical)
            var d: f64 = 0;
            if (state.vertical) {
                d = @abs(mag_pointer.y - cy);
            } else {
                d = @abs(mag_pointer.x - cx);
            }
            const slot: f64 = if (iw > 0) iw else 48;
            target = magScale(d / slot, anim_bucket_peak);
        }
        // Apply the spring in SCALE space to the magnify delta only: distant
        // icons (rest scale ~ 1.0) stay put, and the peak icon overshoots by
        // `spring_strength` of its own magnification into the ladder's
        // headroom (theme.zig extends 30% above animation.scale) — so the
        // bounce is visible on the icon under the cursor, exactly like macOS.
        if (spring_active) {
            const rest_scale = 1.0 + (target / maxb) * (top_scale - 1.0);
            const scale_spring = 1.0 + (rest_scale - 1.0) * spring_k;
            target = (scale_spring - 1.0) / (top_scale - 1.0) * maxb;
        }
        // Click spring: applied to the CLICKED icon only, in full scale space
        // (rest 1.0 included), so even an unmagnified icon squashes and
        // bounces. Press dips below 1.0 (squash); release overshoots above
        // (macOS launch bounce).
        if (press_active and item.widget == press_widget) {
            const rest_scale = 1.0 + (target / maxb) * (top_scale - 1.0);
            const press_k = 1.0 - state.cfg.magnify_press_strength *
                @sin(std.math.pi * @min(press_t / PRESS_MAX_S, 1.0));
            target = (rest_scale * press_k - 1.0) / (top_scale - 1.0) * maxb;
        }
        if (release_active and item.widget == release_widget) {
            const rest_scale = 1.0 + (target / maxb) * (top_scale - 1.0);
            const wd = RELEASE_OMEGA * @sqrt(1.0 - RELEASE_ZETA * RELEASE_ZETA);
            const a = RELEASE_ZETA * RELEASE_OMEGA;
            const t_peak = std.math.atan(wd / a) / wd;
            const peak = @exp(-a * t_peak) * @sin(wd * t_peak);
            const env = @exp(-a * release_t) * @sin(wd * release_t);
            const release_k = 1.0 + (state.cfg.magnify_release_strength / peak) * env;
            target = (rest_scale * release_k - 1.0) / (top_scale - 1.0) * maxb;
        }
        // macOS ghost launch: the clicked ghost pin scales up to ghost_scale
        // (a smooth rise-and-fall envelope, clipped to the ladder) while its
        // opacity drops to 0 — the icon "flies" into the app that's opening.
        // The envelope is an ease-in-out pulse so the growth feels springy,
        // not linear; opacity fades in the second half for the ghost effect.
        if (ghost_active and item.widget == ghost_widget) {
            const p = @min(ghost_t / ghost_dur, 1.0);
            const pulse = 0.5 - 0.5 * @cos(std.math.pi * p); // 0 -> 1 -> eased
            const ghost_target_scale = 1.0 + (state.cfg.magnify_ghost_scale - 1.0) * pulse;
            const rest_scale = 1.0 + (target / maxb) * (top_scale - 1.0);
            const combined = @min(rest_scale * ghost_target_scale, top_scale);
            target = (combined - 1.0) / (top_scale - 1.0) * maxb;
            const opacity = 1.0 - pulse * pulse;
            c.gtk_widget_set_opacity(w, opacity);
        }
        item.scale += (target - item.scale) * alpha;
        var b: usize = @intFromFloat(@round(item.scale));
        if (b >= steps) b = steps - 1;
        if (b != item.bucket) {
            setMagBucket(item, b);
        }
        // keep ticking while the scale is still converging to 1.0 after a
        // leave; > 0.5 is the exact cutoff where round(scale) returns bucket 0
        if (item.scale > 0.5) moving = true;
    }
    return moving;
}

/// Frame-clock tick: ease every icon's scale at most once per compositor
/// frame, driven by the real frame delta (rate-independent on any display).
/// Keeps running while the pointer is inside OR while the leave-shrink is
/// still easing down.
///
/// Returning 0 (G_SOURCE_REMOVE) makes GTK destroy the source — so we MUST
/// zero `mag_tick` right here, otherwise the stale id makes armMagTick()
/// think the tick is still alive and never re-register it on the next enter
/// (the "works once, dies after leaving" bug).
fn onMagTick(_: ?*anyopaque, frame_clock: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    const now_us = c.gdk_frame_clock_get_frame_time(frame_clock.?);
    const dt: f64 = if (last_tick_us > 0)
        @max(@as(f64, @floatFromInt(now_us - last_tick_us)) / 1_000_000.0, 0.001)
    else
        1.0 / 60.0; // first frame: assume 60 Hz
    last_tick_us = now_us;
    const keep = magFrame(dt);
    if (!keep) {
        mag_tick = 0; // this source is being destroyed by GTK right now
        last_tick_us = 0;
        return 0; // G_SOURCE_REMOVE
    }
    return 1; // G_SOURCE_CONTINUE
}

fn armMagTick() void {
    if (mag_tick != 0) return;
    const box = state.main_box orelse return;
    mag_tick = c.gtk_widget_add_tick_callback(box, @ptrCast(&onMagTick), null, null);
}

/// Unregister the tick and zero the id — the single place that manages the
/// `mag_tick` lifecycle. Every path that stops the magnify (leave, rebuild)
/// goes through here so a stale id can never make armMagTick() skip re-arming.
fn stopMagTick() void {
    if (mag_tick != 0) {
        if (state.main_box) |box| c.gtk_widget_remove_tick_callback(box, mag_tick);
        mag_tick = 0;
    }
}

/// Store the pointer and arm the frame-clock tick; the actual easing runs one
/// pass per compositor frame (smooth, rate-independent, no CSS transition).
pub fn applyMagnify(px: f64, py: f64) void {
    if (!state.cfg.magnify_enabled) return;
    mag_inside = true;
    mag_pointer = .{ .x = px, .y = py };
    mag_last_move_us = monoUs(); // moving again -> idle clock restarts
    armMagTick();
    // Wake the frame clock: a registered tick callback only fires on frames
    // that were already scheduled, and a stationary cursor over one button
    // changes no :hover state — without this the icons would stop following
    // the mouse until some unrelated invalidation. Same pattern as GTK4's
    // widget_transform demo.
    if (state.main_box) |box| c.gtk_widget_queue_draw(box);
}

/// Pointer left the dock: target becomes 0 for every icon, but the tick keeps
/// running and eases them back to 1.0 smoothly (no CSS transition, no snap).
/// When everything settles, onMagTick returns 0, GTK destroys the source and
/// we zero `mag_tick` — so the next enter re-arms cleanly.
pub fn resetMagnify() void {
    if (!state.cfg.magnify_enabled) return;
    mag_inside = false;
    spring_active = false; // a settle bounce must never run during the shrink
    spring_t = 0;
    spring_fired = false;
    armMagTick(); // ensure the tick is alive to drive the shrink
    if (state.main_box) |box| c.gtk_widget_queue_draw(box);
}

/// The dock was rebuilt (clearBox ran): cancel the tick and drop stale
/// buckets/scale so the new buttons start at 1.0.
pub fn resetMagnifyState() void {
    mag_inside = false;
    spring_active = false;
    spring_t = 0;
    spring_fired = false;
    press_widget = null;
    press_active = false;
    press_t = 0;
    release_widget = null;
    release_active = false;
    release_t = 0;
    mag_last_move_us = 0;
    // ghost launch: cancel any in-flight fade and restore the icon — the old
    // widget tree is being torn down, but the ghost pin may survive a rebuild
    // (e.g. the app is still opening), so it must not stay invisible.
    ghost_active = false;
    ghost_t = 0;
    if (ghost_widget) |gw| c.gtk_widget_set_opacity(gw, 1.0);
    ghost_widget = null;
    stopMagTick();
    last_tick_us = 0;
    for (mag_items.items) |*item| {
        item.bucket = 0;
        item.scale = 0;
    }
}
// ---------------------------------------------------------------------------
// Icon loading
// ---------------------------------------------------------------------------

fn makeImage(alloc: std.mem.Allocator, id: []const u8, size: i32) ?*anyopaque {
    if (id.len == 0) return null;

    if (id[0] == '/') {
        const z = alloc.dupeZ(u8, id) catch return null;
        defer alloc.free(z);
        const img = c.gtk_image_new_from_file(z.ptr);
        if (img == null) return null;
        c.gtk_image_set_pixel_size(img, size);
        return img;
    }

    const display = c.gdk_display_get_default() orelse return null;
    const theme = c.gtk_icon_theme_get_for_display(display);
    const z = alloc.dupeZ(u8, id) catch return null;
    defer alloc.free(z);
    // Request the icon from the theme at a HIGHER resolution than it is
    // displayed (icon_size x magnify peak). GtkImage then downscales the
    // bigger source to pixel_size — a smooth, crisp 32px render at rest — and
    // when the CSS magnify transform scales the button up, GSK interpolates
    // from that high-quality render instead of a barely-32px texture (the
    // "pixelated" look).
    const anim_scale: f64 = @max(state.cfg.animation_scale, 1.0);
    const lookup_size: i32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(size)) * anim_scale));
    const paintable = c.gtk_icon_theme_lookup_icon(theme, z.ptr, null, lookup_size, 1, 0, c.ICON_LOOKUP_NONE);
    if (paintable == null) return null;
    const img = c.gtk_image_new_from_paintable(paintable);
    c.gtk_image_set_pixel_size(img, size);
    // lookup_icon returns a full reference; GtkImage refs it again. Release
    // ours or we leak one paintable per icon per dock rebuild.
    c.g_object_unref(paintable);
    return img;
}

fn fallbackImage(alloc: std.mem.Allocator, size: i32) ?*anyopaque {
    if (makeImage(alloc, "image-missing", size)) |img| return img;
    return c.gtk_image_new();
}

fn cString(s: []const u8) [:0]const u8 {
    // Transient label/tooltip strings live in the per-rebuild arena.
    return state.ui_alloc.dupeZ(u8, s) catch "";
}

/// `Alacritty` + `dockh-app-` -> `dockh-app-alacritty` — a stable, CSS-safe
/// per-app class so users can style a single app without touching the TOML
/// (see style.css). Shared by the item, the progress bar (dockh-progress-*)
/// and the badge (dockh-badge-*). The prefix is a string literal (always
/// sentinel-terminated), so every returned value is `[:0]const u8` and can be
/// passed straight to gtk_widget_add_css_class.
fn cssClassWithPrefix(alloc: std.mem.Allocator, prefix: [:0]const u8, class: []const u8) [:0]const u8 {
    // Empty class -> bare prefix WITHOUT the trailing hyphen: the old
    // appCssClass returned "dockh-app" (not "dockh-app-"), and a class with
    // a dangling '-' matches nothing in CSS. Keep that contract.
    if (class.len == 0) return prefix[0 .. prefix.len - 1 :0];
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    buf.appendSlice(alloc, prefix) catch return prefix;
    for (class) |ch| {
        const lc = std.ascii.toLower(ch);
        const ok = std.ascii.isAlphanumeric(lc) or lc == '-' or lc == '_';
        buf.append(alloc, if (ok) lc else '-') catch return prefix;
    }
    return buf.toOwnedSliceSentinel(alloc, 0) catch prefix;
}

fn appCssClass(alloc: std.mem.Allocator, class: []const u8) [:0]const u8 {
    return cssClassWithPrefix(alloc, "dockh-app-", class);
}

/// `firefox` + `dockh-progress-` -> `dockh-progress-firefox`.
fn progressCssClass(alloc: std.mem.Allocator, class: []const u8) [:0]const u8 {
    return cssClassWithPrefix(alloc, "dockh-progress-", class);
}

/// `firefox` + `dockh-badge-` -> `dockh-badge-firefox`.
fn badgeCssClass(alloc: std.mem.Allocator, class: []const u8) [:0]const u8 {
    return cssClassWithPrefix(alloc, "dockh-badge-", class);
}

/// True if the workspace is listed in `ignore_workspaces` (by id, name, or
/// `special:` prefix — so `"special"` also matches `special:scratchpad`).
pub fn wsIgnored(ws: hypr.Workspace) bool {
    for (state.cfg.ignore_workspaces) |ig| {
        if (ig.len == 0) continue;
        if (std.mem.eql(u8, ig, ws.name)) return true;
        if (std.mem.startsWith(u8, ws.name, ig) and
            ws.name.len > ig.len and ws.name[ig.len] == ':')
        {
            return true;
        }
        if (std.fmt.parseInt(i32, ig, 10)) |n| {
            if (n == ws.id) return true;
        } else |_| {}
    }
    return false;
}

// ---------------------------------------------------------------------------
// Indicators
// ---------------------------------------------------------------------------

/// Unique, ascending workspace ids where `class` has a window — the macOS
/// per-workspace indicator dots. Allocated in the scratch arena (refreshed
/// on every rebuild).
fn classWorkspaces(class: []const u8) []const i32 {
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(state.scratch);
    for (state.clients) |cl| {
        if (!std.ascii.eqlIgnoreCase(cl.class, class)) continue;
        if (cl.workspace.id <= 0) continue;
        var dup = false;
        for (list.items) |w| if (w == cl.workspace.id) {
            dup = true;
            break;
        };
        if (!dup) list.append(state.scratch, cl.workspace.id) catch {};
    }
    std.mem.sort(i32, list.items, {}, struct {
        fn lt(_: void, a: i32, b: i32) bool {
            return a < b;
        }
    }.lt);
    return list.toOwnedSlice(state.scratch) catch &.{};
}

/// macOS-style workspace indicator: a row of small dots under the icon, one
/// per workspace where the app has a window. The dot for the current
/// workspace gets `active` (accent + glow), the others `inactive`. The row
/// is registered with the magnify engine so the dots spread apart in sync
/// with the icon as the cursor approaches (see theme.zig's indicator rules).
fn makeIndicator(ws_ids: []const i32) ?*anyopaque {
    const vertical = state.vertical;
    const box = c.gtk_box_new(if (vertical) c.ORIENTATION_VERTICAL else c.ORIENTATION_HORIZONTAL, 1);
    c.gtk_widget_add_css_class(box, "dockh-indicator");
    // hug content and center under the icon instead of stretching across
    // the whole item width.
    c.gtk_widget_set_halign(box, c.ALIGN_CENTER);
    c.gtk_widget_set_valign(box, c.ALIGN_CENTER);
    if (ws_ids.len == 0) {
        c.gtk_widget_add_css_class(box, "empty");
    } else {
        for (ws_ids) |wid| {
            const dot = c.gtk_box_new(if (vertical) c.ORIENTATION_VERTICAL else c.ORIENTATION_HORIZONTAL, 0);
            c.gtk_widget_add_css_class(dot, "dockh-wsdot");
            if (wid == state.active_ws_id) {
                c.gtk_widget_add_css_class(dot, "active");
            } else {
                c.gtk_widget_add_css_class(dot, "inactive");
            }
            c.gtk_box_append(box, dot);
        }
    }
    return box;
}

// ---------------------------------------------------------------------------
// Popovers (GTK4: GtkPopover replaces GtkMenu)
// ---------------------------------------------------------------------------

fn popoverPosition() c.GtkPositionType {
    if (std.mem.eql(u8, state.cfg.position, "bottom")) return c.POSITION_TOP;
    if (std.mem.eql(u8, state.cfg.position, "top")) return c.POSITION_BOTTOM;
    if (std.mem.eql(u8, state.cfg.position, "left")) return c.POSITION_RIGHT;
    return c.POSITION_LEFT;
}

/// Pop down, unparent and release our reference. We always hold the ref from
/// gtk_popover_new, so the pointer stays valid until we unref it — as long as
/// the `destroy` tracking (trackPopover) kept the globals in sync, so we never
/// dismiss an object GTK already freed.
fn dismissPopover(pop: ?*anyopaque) void {
    if (pop) |p| {
        c.gtk_popover_popdown(p);
        c.gtk_widget_unparent(p); // releases the anchor's ref
        c.g_object_unref(p); // releases our ref from gtk_popover_new
    }
}

/// GTK called destroy on a popover WE created — either our own dismiss or GTK
/// freeing it behind our back (autohide / anchor teardown). Null every global
/// that pointed at it so nothing ever dismisses freed memory twice.
fn onPopoverDestroyed(widget: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const p = widget orelse return;
    if (current_popover == p) current_popover = null;
    if (nested_popover == p) nested_popover = null;
    if (sys_menu_pop == p) {
        sys_menu_pop = null;
        sys_menu_label = null; // the label was a child of this popover's tree
    }
}

/// Connect the destroy tracking to a freshly created popover.
fn trackPopover(pop: ?*anyopaque) void {
    if (pop) |p| {
        _ = c.g_signal_connect(p, "destroy", @ptrCast(&onPopoverDestroyed), null);
    }
}

/// Dismiss both open popovers, null-first: the globals are cleared BEFORE the
/// destroy calls so a re-entrant destroy callback can never double-dismiss.
///
/// NOTE: sys_menu_label/sys_menu_pop are NOT nulled here — appendSystemMenuSection
/// runs before popupAt() (which calls this), so clearing them here would clobber
/// the freshly-registered label of the popover being OPENED and the live System
/// section would never update. Cleanup belongs to onPopoverDestroyed, which
/// nulls them only when the dying popover is the one that owns the label.
fn dismissCurrentPopover() void {
    const n = nested_popover;
    nested_popover = null;
    const c_cur = current_popover;
    current_popover = null;
    dismissPopover(n);
    dismissPopover(c_cur);
}

fn popupAt(popover: ?*anyopaque, anchor: ?*anyopaque) void {
    dismissCurrentPopover();
    c.gtk_widget_set_parent(popover, anchor);
    c.gtk_popover_set_position(popover, popoverPosition());
    c.gtk_popover_popup(popover);
    current_popover = popover;
}

fn menuRowButton(label: []const u8, on_click: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void, ud: ?*anyopaque) ?*anyopaque {
    const btn = c.gtk_button_new_with_label(cString(label));
    c.gtk_widget_add_css_class(btn, "dockh-menu-row");
    _ = c.g_signal_connect(btn, "clicked", @ptrCast(on_click), ud);
    return btn;
}

// -- instance switcher (multiple windows of one class) -----------------------

const SwitchData = struct { address: []const u8 = "" };

fn onSwitchFocus(_: ?*anyopaque, ud: ?*anyopaque) callconv(.c) void {
    const d: *SwitchData = @ptrCast(@alignCast(ud.?));
    hypr.focusWindow(&state.ctx, state.ui_alloc, d.address);
}

fn instancePopover(anchor: ?*anyopaque, class: []const u8, instances: []const hypr.Client) ?*anyopaque {
    const pop = c.gtk_popover_new();
    trackPopover(pop);
    const vbox = c.gtk_box_new(c.ORIENTATION_VERTICAL, 2);
    c.gtk_widget_add_css_class(vbox, "dockh-menu");

    const header = c.gtk_label_new(cString(desktop.getAppName(state.ui_alloc, class)));
    c.gtk_widget_add_css_class(header, "dockh-menu-title");
    c.gtk_box_append(vbox, header);

    for (instances) |inst| {
        const title_perm = state.ui_alloc.dupe(u8, if (inst.title.len > 30) inst.title[0..30] else inst.title) catch continue;
        const ws_perm = state.ui_alloc.dupe(u8, inst.workspace.name) catch continue;
        const label = std.fmt.allocPrint(state.ui_alloc, "{s}  ({s})", .{ title_perm, ws_perm }) catch title_perm;
        const d: *SwitchData = state.ui_alloc.create(SwitchData) catch continue;
        d.* = .{ .address = state.ui_alloc.dupe(u8, inst.address) catch continue };
        const btn = menuRowButton(label, onSwitchFocus, d);
        c.gtk_box_append(vbox, btn);
    }

    c.gtk_popover_set_child(pop, vbox);
    popupAt(pop, anchor);
    return pop;
}

// -- context menu (right click) ----------------------------------------------

const CtxData = struct { class: []const u8 = "", address: []const u8 = "" };
const MoveAnchor = struct { address: []const u8 = "", button: ?*anyopaque = null };
const MoveData = struct { address: []const u8 = "", ws: i32 = 1 };

fn onCtxFocus(_: ?*anyopaque, ud: ?*anyopaque) callconv(.c) void {
    const d: *CtxData = @ptrCast(@alignCast(ud.?));
    hypr.focusWindow(&state.ctx, state.ui_alloc, d.address);
}

fn onCtxClose(_: ?*anyopaque, ud: ?*anyopaque) callconv(.c) void {
    const d: *CtxData = @ptrCast(@alignCast(ud.?));
    hypr.closeWindow(&state.ctx, state.ui_alloc, d.address);
    hideIfAutohide();
}

fn onCtxFloat(_: ?*anyopaque, ud: ?*anyopaque) callconv(.c) void {
    const d: *CtxData = @ptrCast(@alignCast(ud.?));
    hypr.toggleFloating(&state.ctx, state.ui_alloc, d.address);
    hypr.focusWindow(&state.ctx, state.ui_alloc, d.address);
}

fn onCtxFullscreen(_: ?*anyopaque, ud: ?*anyopaque) callconv(.c) void {
    const d: *CtxData = @ptrCast(@alignCast(ud.?));
    hypr.toggleFullscreen(&state.ctx, state.ui_alloc, d.address);
    hypr.focusWindow(&state.ctx, state.ui_alloc, d.address);
}

fn onCtxMove(_: ?*anyopaque, ud: ?*anyopaque) callconv(.c) void {
    const d: *MoveData = @ptrCast(@alignCast(ud.?));
    hypr.moveToWorkspace(&state.ctx, state.ui_alloc, d.address, d.ws);
}

fn onMovePopover(_: ?*anyopaque, ud: ?*anyopaque) callconv(.c) void {
    const ma: *MoveAnchor = @ptrCast(@alignCast(ud.?));
    const pop = c.gtk_popover_new();
    trackPopover(pop);
    const vbox = c.gtk_box_new(c.ORIENTATION_VERTICAL, 2);
    c.gtk_widget_add_css_class(vbox, "dockh-menu");
    var ws: i32 = 1;
    while (ws <= state.cfg.num_workspaces) : (ws += 1) {
        const md: *MoveData = state.ui_alloc.create(MoveData) catch return;
        md.* = .{ .address = ma.address, .ws = ws };
        const label = std.fmt.allocPrint(state.ui_alloc, "Workspace {d}", .{ws}) catch continue;
        const btn = menuRowButton(label, onCtxMove, md);
        c.gtk_box_append(vbox, btn);
    }
    c.gtk_popover_set_child(pop, vbox);
    const anchor = ma.button orelse return;
    // Nested menu: don't dismiss the context popover that contains `anchor`.
    // Null-first so a re-entrant destroy callback can't double-dismiss.
    const old_nested = nested_popover;
    nested_popover = null;
    dismissPopover(old_nested);
    c.gtk_widget_set_parent(pop, anchor);
    c.gtk_popover_set_position(pop, popoverPosition());
    c.gtk_popover_popup(pop);
    nested_popover = pop;
}

fn onCtxLaunch(_: ?*anyopaque, ud: ?*anyopaque) callconv(.c) void {
    const d: *CtxData = @ptrCast(@alignCast(ud.?));
    _ = desktop.launch(state.ui_alloc, d.class);
    hideIfAutohide();
}

fn onCtxPin(_: ?*anyopaque, ud: ?*anyopaque) callconv(.c) void {
    const d: *CtxData = @ptrCast(@alignCast(ud.?));
    pinUnpin(d.class);
}

/// Launch the graphical config editor (dockh-config). Prefer the sibling
/// binary sitting next to dockh's own executable (readlink /proc/self/exe),
/// so the menu item works even when PATH doesn't include ~/.local/bin;
/// fall back to a plain PATH search otherwise.
fn launchConfigGUI() void {
    var buf: [4096]u8 = undefined;
    const n = c.readlink("/proc/self/exe", &buf, buf.len);
    if (n > 0 and n < @as(isize, @intCast(buf.len))) {
        const self_path = buf[0..@intCast(n)];
        if (std.mem.lastIndexOfScalar(u8, self_path, '/')) |i| {
            const sibling = std.fmt.allocPrint(state.ui_alloc, "{s}/dockh-config", .{self_path[0..i]}) catch null;
            if (sibling) |cmd| {
                if (desktop.spawnCommand(state.ui_alloc, cmd)) return;
            }
        }
    }
    _ = desktop.spawnCommand(state.ui_alloc, "dockh-config");
}

fn onCtxConfig(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    // Close the menu so the editor window gets focus cleanly.
    dismissCurrentPopover();
    launchConfigGUI();
}

fn pinUnpin(class: []const u8) void {
    if (isPinned(class)) {
        removePinned(class);
    } else {
        addPinned(class);
    }
    savePinned();
    main_mod.requestRebuild();
}

fn hideIfAutohide() void {
    if (state.cfg.autohide) {
        if (state.win) |w| c.gtk_widget_hide(w);
    }
}

/// Defer the autohide until the ghost-launch fade finishes, so the animation
/// is visible (with autohide on, the dock would otherwise vanish the instant
/// the app launches and swallow the ghost entirely). One-shot GLib timer;
/// the ghost duration comes from config (clamped, so the callback is always
/// well-formed).
fn hideAfterGhostCallback(_: ?*anyopaque) callconv(.c) c_int {
    hideIfAutohide();
    return 0; // G_SOURCE_REMOVE — one shot
}

fn hideAfterGhostLaunch() void {
    const ms: c_uint = @intCast(@max(state.cfg.magnify_ghost_ms, 150));
    _ = c.g_timeout_add(ms, @ptrCast(&hideAfterGhostCallback), null);
}

fn contextPopover(anchor: ?*anyopaque, class: []const u8, instances: []const hypr.Client) ?*anyopaque {
    const pop = c.gtk_popover_new();
    trackPopover(pop);
    const vbox = c.gtk_box_new(c.ORIENTATION_VERTICAL, 2);
    c.gtk_widget_add_css_class(vbox, "dockh-menu");

    const header = c.gtk_label_new(cString(desktop.getAppName(state.ui_alloc, class)));
    c.gtk_widget_add_css_class(header, "dockh-menu-title");
    c.gtk_box_append(vbox, header);

    for (instances) |inst| {
        const title_perm = state.ui_alloc.dupe(u8, if (inst.title.len > 30) inst.title[0..30] else inst.title) catch continue;
        const ws_perm = state.ui_alloc.dupe(u8, inst.workspace.name) catch continue;
        const label = std.fmt.allocPrint(state.ui_alloc, "{s}  ({s})", .{ title_perm, ws_perm }) catch title_perm;

        const d: *CtxData = state.ui_alloc.create(CtxData) catch continue;
        d.* = .{
            .class = state.ui_alloc.dupe(u8, class) catch continue,
            .address = state.ui_alloc.dupe(u8, inst.address) catch continue,
        };

        const row = c.gtk_box_new(c.ORIENTATION_HORIZONTAL, 4);
        c.gtk_widget_add_css_class(row, "dockh-menu-row");
        const lbl = c.gtk_label_new(cString(label));
        c.gtk_widget_add_css_class(lbl, "dockh-menu-title");
        c.gtk_box_append(row, lbl);

        const focus_b = c.gtk_button_new_with_label("focus");
        _ = c.g_signal_connect(focus_b, "clicked", @ptrCast(&onCtxFocus), d);
        c.gtk_box_append(row, focus_b);

        const close_b = c.gtk_button_new_with_label("close");
        _ = c.g_signal_connect(close_b, "clicked", @ptrCast(&onCtxClose), d);
        c.gtk_box_append(row, close_b);

        const float_b = c.gtk_button_new_with_label("float");
        _ = c.g_signal_connect(float_b, "clicked", @ptrCast(&onCtxFloat), d);
        c.gtk_box_append(row, float_b);

        const fs_b = c.gtk_button_new_with_label("fullscreen");
        _ = c.g_signal_connect(fs_b, "clicked", @ptrCast(&onCtxFullscreen), d);
        c.gtk_box_append(row, fs_b);

        const move_b = c.gtk_button_new_with_label("move →");
        const ma: *MoveAnchor = state.ui_alloc.create(MoveAnchor) catch continue;
        ma.* = .{ .address = d.address, .button = move_b };
        _ = c.g_signal_connect(move_b, "clicked", @ptrCast(&onMovePopover), ma);
        c.gtk_box_append(row, move_b);

        c.gtk_box_append(vbox, row);
    }

    const sep = c.gtk_separator_new(c.ORIENTATION_HORIZONTAL);
    c.gtk_box_append(vbox, sep);

    const d: *CtxData = state.ui_alloc.create(CtxData) catch return pop;
    d.* = .{ .class = state.ui_alloc.dupe(u8, class) catch "", .address = "" };

    const pin_label = if (isPinned(class)) "Unpin" else "Pin";
    const pin_b = menuRowButton(pin_label, onCtxPin, d);
    c.gtk_box_append(vbox, pin_b);

    const new_b = menuRowButton("New window", onCtxLaunch, d);
    c.gtk_box_append(vbox, new_b);

    const sep2 = c.gtk_separator_new(c.ORIENTATION_HORIZONTAL);
    c.gtk_box_append(vbox, sep2);

    const cfg_b = menuRowButton("Configuration…", onCtxConfig, null);
    c.gtk_box_append(vbox, cfg_b);

    // Live system stats at the bottom of every right-click menu.
    appendSystemMenuSection(pop, vbox);

    c.gtk_popover_set_child(pop, vbox);
    popupAt(pop, anchor);
    return pop;
}

// -- pinned button context (unpin) -------------------------------------------

fn onUnpin(_: ?*anyopaque, ud: ?*anyopaque) callconv(.c) void {
    const d: *CtxData = @ptrCast(@alignCast(ud.?));
    removePinned(d.class);
    savePinned();
    main_mod.requestRebuild();
}

fn pinnedPopover(anchor: ?*anyopaque, class: []const u8) ?*anyopaque {
    const pop = c.gtk_popover_new();
    trackPopover(pop);
    const vbox = c.gtk_box_new(c.ORIENTATION_VERTICAL, 2);
    c.gtk_widget_add_css_class(vbox, "dockh-menu");
    const d: *CtxData = state.ui_alloc.create(CtxData) catch return pop;
    d.* = .{ .class = state.ui_alloc.dupe(u8, class) catch "", .address = "" };
    const btn = menuRowButton("Unpin", onUnpin, d);
    c.gtk_box_append(vbox, btn);

    // Only two rows here — no separator needed (the context menu's item is
    // visually grouped with a divider; this small menu stays tight).
    const cfg_b = menuRowButton("Configuration…", onCtxConfig, null);
    c.gtk_box_append(vbox, cfg_b);

    // Live system stats on the pinned-app menu too.
    appendSystemMenuSection(pop, vbox);

    c.gtk_popover_set_child(pop, vbox);
    popupAt(pop, anchor);
    return pop;
}

// ---------------------------------------------------------------------------
// Buttons
// ---------------------------------------------------------------------------

/// macOS click spring — press phase: squash the clicked icon down briefly.
/// Called from the button's "pressed" handler; the release handler fires
/// the bounce-back. Matched by widget pointer so only the clicked icon
/// moves (far icons stay put), and it works even when the icon isn't
/// magnified (rest scale 1.0 still dips).
fn triggerPressSpring(w: ?*anyopaque) void {
    if (!state.cfg.magnify_enabled or !state.cfg.magnify_click_spring) return;
    if (state.cfg.magnify_press_strength <= 0) return;
    // The pointer is (almost) idle while clicking, so the settle spring may
    // be mid-decay — compounding it with the click spring makes the bounce
    // mushy. Kill the settle phase here and mark it fired so it stays off
    // until the pointer moves again.
    spring_active = false;
    spring_t = 0;
    spring_fired = true;
    press_widget = w;
    press_active = true;
    press_t = 0;
    mag_inside = true; // keep the tick alive while the dip runs
    armMagTick();
    if (state.main_box) |box| c.gtk_widget_queue_draw(box);
}

/// macOS click spring — release phase: spring the clicked icon back with a
/// pronounced overshoot (the "launch bounce" of the real dock). Same settle
/// suppression as the press, so the bounce is the click's own, not a mix.
fn triggerReleaseSpring(w: ?*anyopaque) void {
    if (!state.cfg.magnify_enabled or !state.cfg.magnify_click_spring) return;
    if (state.cfg.magnify_release_strength <= 0) return;
    spring_active = false;
    spring_t = 0;
    spring_fired = true;
    release_widget = w;
    release_active = true;
    release_t = 0;
    mag_inside = true;
    armMagTick();
    if (state.main_box) |box| c.gtk_widget_queue_draw(box);
}

/// macOS ghost launch — clicking a pinned app that ISN'T running (a "ghost
/// pin") makes the icon bounce up and fade out toward the app that's
/// opening, exactly like the real dock. The clicked icon scales to
/// `magnify_ghost_scale` and fades to transparent over `magnify_ghost_ms`,
/// driven by the same frame-clock tick as the springs; when the app's
/// openwindow event lands, the dock rebuilds and the ghost is replaced by
/// the live running icon. Runs even when the click spring is off (it's its
/// own animation, not a spring phase).
fn triggerGhostLaunch(w: ?*anyopaque) void {
    if (!state.cfg.magnify_enabled or !state.cfg.magnify_ghost_launch) return;
    if (state.cfg.magnify_ghost_ms <= 0) return;
    // Interrupting a previous ghost (clicking pin A then pin B within the
    // fade window) must not leave A stuck at partial opacity — restore it
    // before switching to the new widget.
    if (ghost_active) {
        if (ghost_widget) |old| {
            if (old != w) c.gtk_widget_set_opacity(old, 1.0);
        }
    }
    // A ghost pin click also fires the normal press spring — the two compose
    // nicely (press squashes, then the ghost pulse takes over on release),
    // so don't touch press/release state here.
    ghost_widget = w;
    ghost_active = true;
    ghost_t = 0;
    ghost_dur = @as(f64, @floatFromInt(state.cfg.magnify_ghost_ms)) / 1000.0;
    mag_inside = true; // keep the tick alive while the ghost flies
    armMagTick();
    if (state.main_box) |box| c.gtk_widget_queue_draw(box);
    if (log.debug_enabled) log.debug("ghost launch on", .{});
}

fn onTaskPress(gesture_arg: ?*anyopaque, _: c_int, _: f64, _: f64, ud: ?*anyopaque) callconv(.c) void {
    const d: *BtnData = @ptrCast(@alignCast(ud.?));
    const button = c.gtk_gesture_single_get_current_button(gesture_arg.?);
    if (button == 1) triggerPressSpring(d.anchor);

    const anchor = d.anchor;
    if (button == 1) {
        if (d.launcher) {
            _ = desktop.launch(state.ui_alloc, d.class);
            hideIfAutohide();
        } else if (d.pinned) {
            // Pinned app: if an instance is already running, FOCUS it (and
            // switch to its workspace) instead of launching a duplicate —
            // launching a second instance is what made clicks on open apps
            // feel ~2s slow. Only launch when nothing is running (ghost pin).
            if (d.address.len > 0) {
                if (d.multiple) {
                    const instances = taskInstances(d.class);
                    _ = instancePopover(anchor, d.class, instances);
                } else {
                    hypr.focusWindow(&state.ctx, state.ui_alloc, d.address);
                }
            } else {
                // Ghost pin: launch the app and fly the icon into it — the
                // openwindow event rebuilds the dock with the running icon.
                _ = desktop.launch(state.ui_alloc, d.class);
                triggerGhostLaunch(d.anchor);
                // Defer autohide until the ghost fade finishes, so the
                // animation is actually visible (autohide=false users never
                // hit this path).
                if (state.cfg.autohide) {
                    hideAfterGhostLaunch();
                } else {
                    hideIfAutohide();
                }
            }
        } else if (!d.multiple) {
            hypr.focusWindow(&state.ctx, state.ui_alloc, d.address);
        } else {
            const instances = taskInstances(d.class);
            _ = instancePopover(anchor, d.class, instances);
        }
    } else if (button == 2) {
        _ = desktop.launch(state.ui_alloc, d.class);
        hideIfAutohide();
    } else if (button == 3) {
        if (d.pinned) {
            _ = pinnedPopover(anchor, d.class);
        } else {
            const instances = taskInstances(d.class);
            _ = contextPopover(anchor, d.class, instances);
        }
    }
}

/// "released" — the bounce-back phase of the click spring. Only the LEFT
/// button bounces (same gate as the press): a right-click opening the context
/// menu or a middle-click launching an instance must not animate the icon.
fn onTaskReleased(gesture_arg: ?*anyopaque, _: c_int, _: f64, _: f64, ud: ?*anyopaque) callconv(.c) void {
    const d: *BtnData = @ptrCast(@alignCast(ud.?));
    if (c.gtk_gesture_single_get_current_button(gesture_arg.?) == 1) {
        triggerReleaseSpring(d.anchor);
    }
}

fn onLauncherPress(gesture_arg: ?*anyopaque, _: c_int, _: f64, _: f64, ud: ?*anyopaque) callconv(.c) void {
    const d: *BtnData = @ptrCast(@alignCast(ud.?));
    const button = c.gtk_gesture_single_get_current_button(gesture_arg.?);
    if (button == 1) triggerPressSpring(d.anchor);
    if (button == 1 or button == 2) {
        _ = desktop.spawnCommand(state.ui_alloc, d.class);
        hideIfAutohide();
    }
}

fn onLauncherReleased(gesture_arg: ?*anyopaque, _: c_int, _: f64, _: f64, ud: ?*anyopaque) callconv(.c) void {
    const d: *BtnData = @ptrCast(@alignCast(ud.?));
    if (c.gtk_gesture_single_get_current_button(gesture_arg.?) == 1) {
        triggerReleaseSpring(d.anchor);
    }
}

/// Active-app halo: a blurred copy of the icon, rendered by the dock itself
/// (GskBlurNode on GTK >= 4.16, GskGLShaderNode before), injected directly
/// into the scene graph (zero extra memory). Null when blur is unavailable.
fn makeGlow(_: std.mem.Allocator, _: []const u8, img: ?*anyopaque) ?*anyopaque {
    const paintable = c.gtk_image_get_paintable(img) orelse return null;
    const glow = blur.makeGlowWidget(paintable) orelse return null;
    const overlay = c.gtk_overlay_new();
    c.gtk_overlay_set_child(overlay, glow);
    c.gtk_widget_set_halign(img, c.ALIGN_CENTER);
    c.gtk_widget_set_valign(img, c.ALIGN_CENTER);
    c.gtk_overlay_add_overlay(overlay, img);
    return overlay;
}

fn makeButtonItem(alloc: std.mem.Allocator, id: []const u8, class: []const u8, address: []const u8, multiple: bool, pinned: bool, launcher: bool, active: bool, instances: usize) ?*anyopaque {
    const vertical = state.vertical;
    const outer = c.gtk_box_new(if (vertical) c.ORIENTATION_HORIZONTAL else c.ORIENTATION_VERTICAL, 2);
    c.gtk_widget_add_css_class(outer, "dockh-item");
    c.gtk_widget_add_css_class(outer, if (launcher) "dockh-launcher" else if (pinned) "dockh-pinned" else "dockh-task");
    // state + per-app classes for the CSS engine
    c.gtk_widget_add_css_class(outer, if (active) "active" else "inactive");
    c.gtk_widget_add_css_class(outer, if (launcher or instances == 0) "idle" else "running");
    c.gtk_widget_add_css_class(outer, appCssClass(alloc, class));

    const btn = c.gtk_button_new();
    c.gtk_widget_add_css_class(btn, "dockh-btn");
    c.gtk_widget_add_css_class(btn, appCssClass(alloc, class));
    const img = makeImage(alloc, id, state.cfg.icon_size) orelse fallbackImage(alloc, state.cfg.icon_size);
    var btn_child: ?*anyopaque = img;
    // Active app: blurred halo behind the crisp icon (in-dock blur, no
    // compositor). Falls back to the plain icon when blur is unavailable.
    if (active and state.cfg.glow_enabled and state.cfg.glow_radius > 0) {
        if (makeGlow(alloc, id, img)) |overlay| {
            btn_child = overlay;
        }
    }

    // Status overlay: macOS-style progress bar at the bottom edge + the
    // notification counter badge at the top-right corner of the icon. Both
    // start hidden; the status polls (playerctl / makoctl) drive them.
    const status_overlay = c.gtk_overlay_new();
    c.gtk_overlay_set_child(status_overlay, btn_child);

    // macOS-style media progress bar under the icon — OFF by default
    // ([progress] enabled = false): don't even build the widget, so nothing
    // can ever show. When enabled it starts hidden and the playerctl poll
    // (status.zig) drives it only with real progress.
    const pbar = if (state.cfg.progress_enabled) blk: {
        const pb = c.gtk_progress_bar_new();
        c.gtk_widget_add_css_class(pb, "dockh-progress");
        c.gtk_widget_add_css_class(pb, progressCssClass(alloc, class));
        c.gtk_progress_bar_set_show_text(pb, 0);
        c.gtk_progress_bar_set_fraction(pb, 0);
        c.gtk_widget_set_halign(pb, c.ALIGN_FILL);
        c.gtk_widget_set_valign(pb, c.ALIGN_END);
        c.gtk_overlay_add_overlay(status_overlay, pb);
        c.gtk_widget_hide(pb);
        break :blk pb;
    } else null;

    const badge = c.gtk_label_new("0");
    c.gtk_widget_add_css_class(badge, "dockh-badge");
    // per-app badge class: .dockh-badge-<app> (e.g. .dockh-badge-firefox)
    c.gtk_widget_add_css_class(badge, badgeCssClass(alloc, class));
    c.gtk_widget_set_halign(badge, c.ALIGN_END);
    c.gtk_widget_set_valign(badge, c.ALIGN_START);
    c.gtk_overlay_add_overlay(status_overlay, badge);
    c.gtk_widget_hide(badge);

    item_status.append(state.ui_alloc, .{
        .class = state.ui_alloc.dupe(u8, class) catch "",
        .progress = pbar,
        .badge = badge,
    }) catch {};

    c.gtk_button_set_child(btn, status_overlay);
    const tooltip = if (pinned and instances == 0)
        std.fmt.allocPrint(state.ui_alloc, "Launch {s}", .{desktop.getAppName(alloc, class)}) catch desktop.getAppName(alloc, class)
    else
        desktop.getAppName(alloc, class);
    c.gtk_widget_set_tooltip_text(btn, cString(tooltip));

    const gesture = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(gesture, 0);
    c.gtk_gesture_single_set_exclusive(gesture, 1);
    const d: *BtnData = alloc.create(BtnData) catch return outer;
    d.* = .{
        .class = alloc.dupe(u8, class) catch "",
        .address = alloc.dupe(u8, address) catch "",
        .multiple = multiple,
        .pinned = pinned,
        .launcher = launcher,
        .anchor = btn,
    };
    if (launcher) {
        _ = c.g_signal_connect(gesture, "pressed", @ptrCast(&onLauncherPress), d);
        _ = c.g_signal_connect(gesture, "released", @ptrCast(&onLauncherReleased), d);
    } else {
        _ = c.g_signal_connect(gesture, "pressed", @ptrCast(&onTaskPress), d);
        _ = c.g_signal_connect(gesture, "released", @ptrCast(&onTaskReleased), d);
    }
    c.gtk_widget_add_controller(btn, gesture);

    // pinned/launcher show their real state: empty when not running. The
    // indicator is a row of workspace dots (one per workspace with windows),
    // or empty for the launcher / ghost pins.
    const ind = if (launcher) makeIndicator(&.{}) else makeIndicator(classWorkspaces(class));

    // indicator faces the screen edge
    const bottom = std.mem.eql(u8, state.cfg.position, "bottom");
    const right = std.mem.eql(u8, state.cfg.position, "right");
    const top = std.mem.eql(u8, state.cfg.position, "top");
    if (bottom or right) {
        c.gtk_box_append(outer, btn);
        c.gtk_box_append(outer, ind);
    } else if (top or std.mem.eql(u8, state.cfg.position, "left")) {
        c.gtk_box_append(outer, ind);
        c.gtk_box_append(outer, btn);
    } else {
        c.gtk_box_append(outer, btn);
        c.gtk_box_append(outer, ind);
    }
    // macOS proximity magnification tracks the icon button and links the
    // workspace dot row to the same bucket: the button grows from its base
    // edge while the dots below spread apart in exact sync (theme.zig
    // generates scaleX/scaleY rules for the indicator, counter-scaled per
    // dot to keep them round). The launcher has no dots, so it stays a
    // plain magnify item.
    if (launcher) {
        registerMagItem(btn);
    } else {
        registerMagItemLinked(btn, ind);
    }
    return outer;
}

// ---------------------------------------------------------------------------
// Main box assembly
// ---------------------------------------------------------------------------

/// Does a running client class match a pin/task id? Mirrors
/// status.appMatchesClass: case-insensitive exact, prefix form (pin "brave" ↔
/// class "brave-browser"), and dotted-suffix on EITHER side (pin
/// "org.mozilla.firefox" ↔ class "firefox"; class "com.obsidian.Obsidian" ↔
/// pin "obsidian"). Min 3 chars so short ids can't over-match. Without this,
/// a dotted desktop-id pin would never match its running windows and the
/// click fix below would still launch a duplicate.
fn taskClassMatches(a: []const u8, b: []const u8) bool {
    if (a.len < 3 or b.len < 3) return false;
    if (std.ascii.eqlIgnoreCase(a, b)) return true;
    if (std.ascii.startsWithIgnoreCase(b, a)) return true;
    if (std.ascii.startsWithIgnoreCase(a, b)) return true;
    if (std.mem.lastIndexOfScalar(u8, a, '.')) |i| {
        if (std.ascii.eqlIgnoreCase(a[i + 1 ..], b)) return true;
    }
    if (std.mem.lastIndexOfScalar(u8, b, '.')) |i| {
        if (std.ascii.eqlIgnoreCase(b[i + 1 ..], a)) return true;
    }
    return false;
}

fn taskInstances(class: []const u8) []const hypr.Client {
    var result: std.ArrayList(hypr.Client) = .empty;
    for (state.clients) |cl| {
        if (taskClassMatches(cl.class, class)) {
            result.append(state.scratch, cl) catch {};
        }
    }
    return result.toOwnedSlice(state.scratch) catch &.{};
}

pub fn isPinned(id: []const u8) bool {
    for (state.pinned.items) |p| {
        if (std.mem.eql(u8, p, id)) return true;
    }
    return false;
}

pub fn addPinned(id: []const u8) void {
    for (state.pinned.items) |p| {
        if (std.mem.eql(u8, p, id)) return;
    }
    const copy = state.alloc.dupe(u8, id) catch return;
    state.pinned.append(state.alloc, copy) catch return;
    log.info("pinned {s}", .{id});
}

pub fn removePinned(id: []const u8) void {
    for (state.pinned.items, 0..) |p, i| {
        if (std.mem.eql(u8, p, id)) {
            _ = state.pinned.orderedRemove(i);
            log.info("unpinned {s}", .{id});
            return;
        }
    }
}

pub fn savePinned() void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(state.alloc);
    for (state.pinned.items) |p| {
        buf.appendSlice(state.alloc, p) catch {};
        buf.append(state.alloc, '\n') catch {};
    }
    const path = main_mod.pinnedFilePath();
    @import("fs").writeFile(path, buf.items) catch {};
}

fn clientLessThan(a: hypr.Client, b: hypr.Client) bool {
    if (a.workspace.id != b.workspace.id) return a.workspace.id < b.workspace.id;
    return std.mem.lessThan(u8, a.class, b.class);
}

fn clearBox(box: ?*anyopaque) void {
    // The dock is being rebuilt — any open menu would dangle its anchor.
    dismissCurrentPopover();
    resetMagnifyState(); // cancel the tick; stale transforms must go
    sys_label = null; // the label widget is being destroyed with the tree
    // Drop the per-rebuild registries. Their backing buffers live in
    // ui_arena, which rebuildMainBox resets right after clearBox destroys
    // the old widgets — reassigning .empty (instead of clearRetainingCapacity)
    // discards the stale buffer pointer so the next append reallocates from
    // the fresh arena.
    item_status = .empty;
    mag_items = .empty;
    var child = c.gtk_widget_get_first_child(box);
    while (child != null) {
        const next = c.gtk_widget_get_next_sibling(child);
        c.gtk_box_remove(box, child);
        child = next;
    }
}

fn launcherButton(alloc: std.mem.Allocator) ?*anyopaque {
    if (state.cfg.no_launcher or state.cfg.launcher_cmd.len == 0) return null;
    const icon = if (state.cfg.launcher_icon.len > 0) state.cfg.launcher_icon else "view-app-grid-symbolic";
    return makeButtonItem(alloc, icon, state.cfg.launcher_cmd, "", false, false, true, false, 1);
}

// ---------------------------------------------------------------------------
// Optional system monitor (RAM / CPU / temperature)
// ---------------------------------------------------------------------------
// A single label at the end of the dock, updated every system.interval_ms by
// status.zig's pollSystem (same status-poll timers as progress/badges — no
// extra subprocesses, /proc + sysfs reads only). The text is set in place
// (gtk_label_set_text copies), so the timer never rebuilds the dock.

/// True when the system monitor is enabled at all — the right-click menu
/// section (and the optional dock pill) only exist when there is something
/// to show.
pub fn systemEnabled() bool {
    return state.cfg.system_enabled and
        (state.cfg.system_ram or state.cfg.system_cpu or state.cfg.system_temp);
}

/// Build the dock pill (or null). OFF by default: `[system] dock = true`
/// opts into the always-visible pill at the end of the dock — constant
/// stats in a dock are noise, the context menu is the good UX. Registers it
/// as the global sys_label so pollSystem can update it without a rebuild.
fn makeSystemItem() ?*anyopaque {
    if (!systemEnabled() or !state.cfg.system_dock) return null;
    const lbl = c.gtk_label_new("");
    c.gtk_widget_add_css_class(lbl, "dockh-sys");
    c.gtk_widget_set_halign(lbl, c.ALIGN_CENTER);
    c.gtk_widget_set_valign(lbl, c.ALIGN_CENTER);
    sys_label = lbl;
    return lbl;
}

/// Append the live "System" section to a right-click context menu — the
/// home of the monitor (see the sys_label header comment): a separator, a
/// small title and the RAM/CPU/temp label. The label is registered as
/// sys_menu_label, so the same pollSystem timer updates it in place while
/// the popover is open; dismissCurrentPopover clears the pointer when the
/// menu closes.
fn appendSystemMenuSection(pop: ?*anyopaque, vbox: ?*anyopaque) void {
    if (!systemEnabled()) return;
    const sep = c.gtk_separator_new(c.ORIENTATION_HORIZONTAL);
    c.gtk_box_append(vbox, sep);
    const title = c.gtk_label_new("System");
    c.gtk_widget_add_css_class(title, "dockh-menu-title");
    c.gtk_box_append(vbox, title);
    const lbl = c.gtk_label_new("");
    c.gtk_widget_add_css_class(lbl, "dockh-sys");
    c.gtk_widget_set_halign(lbl, c.ALIGN_START);
    c.gtk_box_append(vbox, lbl);
    sys_menu_label = lbl;
    sys_menu_pop = pop;
}

/// Update the system labels in place (called from the poll timer): the dock
/// pill (if any) and the open context menu's System section (if any).
/// gtk_label_set_text copies, so the caller's buffer can be a stack array.
pub fn setSystemText(text: [:0]const u8) void {
    if (sys_label) |lbl| c.gtk_label_set_text(lbl, text.ptr);
    if (sys_menu_label) |lbl| c.gtk_label_set_text(lbl, text.ptr);
}

/// Show/hide the system labels — hidden when every segment failed to produce
/// data (no RAM/CPU/temp readable), so no empty pill with padding sits in
/// the dock.
pub fn setSystemVisible(visible: bool) void {
    if (sys_label) |lbl| {
        if (visible) {
            c.gtk_widget_show(lbl);
        } else {
            c.gtk_widget_hide(lbl);
        }
    }
    if (sys_menu_label) |lbl| {
        if (visible) {
            c.gtk_widget_show(lbl);
        } else {
            c.gtk_widget_hide(lbl);
        }
    }
}

/// Rebuild the whole dock content. Called on every Hyprland event that
/// matters. Every allocation the new widgets make (CSS class names, tooltips,
/// BtnData, popover data, .desktop lookups) goes into the per-rebuild
/// `ui_arena`, which is wiped on the next rebuild — so the permanent arena
/// never grows with events and RSS stays flat instead of creeping toward
/// 200 MB.
pub fn rebuildMainBox() void {
    const mb = state.main_box orelse return;
    clearBox(mb); // destroy the old widget tree first (frees ui_arena refs)
    state.resetUi(); // wipe the previous generation's allocations
    const alloc = state.ui_alloc;

    if (std.mem.eql(u8, state.cfg.launcher_pos, "start")) {
        if (launcherButton(alloc)) |lb| c.gtk_box_append(mb, lb);
    }

    var added: std.ArrayList([]const u8) = .empty;
    defer added.deinit(alloc);

    // pinned apps
    for (state.pinned.items) |pin| {
        if (pin.len == 0) continue;
        const running = taskInstances(pin);
        const active = std.ascii.eqlIgnoreCase(pin, state.active_class);
        const w = makeButtonItem(alloc, desktop.getIconName(alloc, pin), pin, if (running.len > 0) running[0].address else "", running.len > 1, true, false, active, running.len);
        c.gtk_box_append(mb, w);
        added.append(alloc, alloc.dupe(u8, pin) catch continue) catch continue;
    }

    // running tasks, dedup by class, sorted by workspace then class
    var sorted: std.ArrayList(hypr.Client) = .empty;
    defer sorted.deinit(state.scratch);
    for (state.clients) |cl| {
        if (cl.class.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(cl.class, state.cfg.launcher_cmd)) continue;
        if (wsIgnored(cl.workspace)) continue;
        sorted.append(state.scratch, cl) catch {};
    }
    std.mem.sort(hypr.Client, sorted.items, {}, struct {
        fn lt(_: void, a: hypr.Client, b: hypr.Client) bool {
            return clientLessThan(a, b);
        }
    }.lt);

    var sep_added = false;
    for (sorted.items) |cl| {
        if (isPinned(cl.class)) continue;
        var skip = false;
        for (state.cfg.ignore_classes) |ig| {
            if (std.ascii.eqlIgnoreCase(ig, cl.class)) {
                skip = true;
                break;
            }
        }
        if (skip) continue;
        // thin divider between the pinned section and the running tasks
        if (!sep_added and added.items.len > 0) {
            const sep = c.gtk_separator_new(if (state.vertical) c.ORIENTATION_HORIZONTAL else c.ORIENTATION_VERTICAL);
            c.gtk_widget_add_css_class(sep, "dockh-separator");
            c.gtk_box_append(mb, sep);
            sep_added = true;
        }
        var already = false;
        for (added.items) |a| {
            if (std.ascii.eqlIgnoreCase(a, cl.class)) {
                already = true;
                break;
            }
        }
        if (already) continue;

        const instances = taskInstances(cl.class);
        const active = std.ascii.eqlIgnoreCase(cl.class, state.active_class);
        const w = makeButtonItem(alloc, desktop.getIconName(alloc, cl.class), cl.class, if (instances.len > 0) instances[0].address else "", instances.len > 1, false, false, active, instances.len);
        c.gtk_box_append(mb, w);
        added.append(alloc, alloc.dupe(u8, cl.class) catch continue) catch continue;
    }

    if (std.mem.eql(u8, state.cfg.launcher_pos, "end")) {
        if (launcherButton(alloc)) |lb| c.gtk_box_append(mb, lb);
    }

    // Optional system monitor at the very end of the dock (RAM/CPU/temp).
    if (makeSystemItem()) |si| c.gtk_box_append(mb, si);

    c.gtk_widget_show(mb);
}
