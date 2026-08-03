//! In-dock Gaussian blur rendered by the dock itself — no compositor needed.
//!
//! The effect is injected directly into the window's own scene graph by a tiny
//! custom widget, DockhGlow, whose snapshot vfunc pushes a blur region and
//! draws the icon inside it:
//!
//!   1. GskBlurNode (gtk_snapshot_push_blur) on GTK >= 4.16 — supported by
//!      every renderer (ngl / cairo / vulkan), GPU-accelerated in ngl. This
//!      is the path that runs on modern GTK (the user's 4.22).
//!   2. GskGLShaderNode (gtk_snapshot_push_gl_shader) on GTK < 4.16 — the
//!      classic GL renderer executes a Gaussian GLSL shader.
//!
//! No offscreen renderer is created, so the effect costs zero extra memory
//! (the previous gsk_renderer_render_texture approach measured +61 MB RSS).
//! If neither path is usable the dock simply skips the glow (no crash).
const std = @import("std");
const c = @import("../c.zig");
const state = @import("../core/state.zig");
const log = @import("../core/log.zig");

const Backend = enum { gl_shader, blur_node };

var backend: Backend = .blur_node;
var gl_shader: ?*anyopaque = null;
var glow_type: usize = 0; // registered GType of DockhGlow
var init_done = false;
var logged = false;

// ---------------------------------------------------------------------------
// GLSL for the classic GL renderer (GTK < 4.16). mainImage() is the entry
// point GTK injects; GskTexture() samples a bound texture; u_radius is the
// single custom uniform. The ngl renderer (4.14+) ignores GL shader nodes,
// which is exactly why GskBlurNode is the primary path.
// ---------------------------------------------------------------------------
const blur_glsl =
    \\uniform sampler2D u_texture1;
    \\uniform float u_radius;
    \\
    \\void mainImage(out vec4 fragColor, in vec2 fragCoord, in vec2 resolution, in vec2 uv) {
    \\    vec2 texel = u_radius / resolution;
    \\    vec4 sum = vec4(0.0);
    \\    vec4 c;
    \\    c = GskTexture(u_texture1, uv + vec2(-2.0,-2.0)*texel); sum += c*1.0;
    \\    c = GskTexture(u_texture1, uv + vec2(-1.0,-2.0)*texel); sum += c*4.0;
    \\    c = GskTexture(u_texture1, uv + vec2( 0.0,-2.0)*texel); sum += c*6.0;
    \\    c = GskTexture(u_texture1, uv + vec2( 1.0,-2.0)*texel); sum += c*4.0;
    \\    c = GskTexture(u_texture1, uv + vec2( 2.0,-2.0)*texel); sum += c*1.0;
    \\    c = GskTexture(u_texture1, uv + vec2(-2.0,-1.0)*texel); sum += c*4.0;
    \\    c = GskTexture(u_texture1, uv + vec2(-1.0,-1.0)*texel); sum += c*16.0;
    \\    c = GskTexture(u_texture1, uv + vec2( 0.0,-1.0)*texel); sum += c*24.0;
    \\    c = GskTexture(u_texture1, uv + vec2( 1.0,-1.0)*texel); sum += c*16.0;
    \\    c = GskTexture(u_texture1, uv + vec2( 2.0,-1.0)*texel); sum += c*4.0;
    \\    c = GskTexture(u_texture1, uv + vec2(-2.0, 0.0)*texel); sum += c*6.0;
    \\    c = GskTexture(u_texture1, uv + vec2(-1.0, 0.0)*texel); sum += c*24.0;
    \\    c = GskTexture(u_texture1, uv + vec2( 0.0, 0.0)*texel); sum += c*36.0;
    \\    c = GskTexture(u_texture1, uv + vec2( 1.0, 0.0)*texel); sum += c*24.0;
    \\    c = GskTexture(u_texture1, uv + vec2( 2.0, 0.0)*texel); sum += c*6.0;
    \\    c = GskTexture(u_texture1, uv + vec2(-2.0, 1.0)*texel); sum += c*4.0;
    \\    c = GskTexture(u_texture1, uv + vec2(-1.0, 1.0)*texel); sum += c*16.0;
    \\    c = GskTexture(u_texture1, uv + vec2( 0.0, 1.0)*texel); sum += c*24.0;
    \\    c = GskTexture(u_texture1, uv + vec2( 1.0, 1.0)*texel); sum += c*16.0;
    \\    c = GskTexture(u_texture1, uv + vec2( 2.0, 1.0)*texel); sum += c*4.0;
    \\    c = GskTexture(u_texture1, uv + vec2(-2.0, 2.0)*texel); sum += c*1.0;
    \\    c = GskTexture(u_texture1, uv + vec2(-1.0, 2.0)*texel); sum += c*4.0;
    \\    c = GskTexture(u_texture1, uv + vec2( 0.0, 2.0)*texel); sum += c*6.0;
    \\    c = GskTexture(u_texture1, uv + vec2( 1.0, 2.0)*texel); sum += c*4.0;
    \\    c = GskTexture(u_texture1, uv + vec2( 2.0, 2.0)*texel); sum += c*1.0;
    \\    fragColor = sum / 256.0;
    \\}
;

/// One-shot backend detection + DockhGlow type registration. Pure scene-graph:
/// no display, surface or offscreen renderer required, so it can run right
/// after gtk_init (before the window is mapped).
pub fn init() void {
    if (init_done) return;
    init_done = true;

    if (c.gtk_get_minor_version() < 16) {
        const src = c.g_bytes_new_static(blur_glsl.ptr, blur_glsl.len);
        const sh = c.gsk_gl_shader_new_from_bytes(src);
        c.g_bytes_unref(src);
        if (sh != null) {
            gl_shader = sh;
            backend = .gl_shader;
        } else {
            backend = .blur_node;
        }
    } else {
        backend = .blur_node;
    }

    registerGlowType();

    if (!logged) {
        log.info("blur backend: {s}", .{@tagName(backend)});
        logged = true;
    }
}

// ---------------------------------------------------------------------------
// DockhGlow: a minimal GtkWidget subclass whose snapshot vfunc blurs the
// stored paintable. Registered with g_type_register_static_simple (no
// @cImport); the vfuncs are written into GtkWidgetClass at their measured
// offsets (GTK 4.22 / x86_64: measure +232, snapshot +320).
// ---------------------------------------------------------------------------

fn registerGlowType() void {
    if (glow_type != 0) return;
    var q: c.GTypeQuery = .{};
    c.g_type_query(c.gtk_widget_get_type(), &q);
    // glib 2.88 flat signature: (parent, name, class_size, class_init,
    // instance_size, instance_init, flags) — no GTypeInfo struct.
    glow_type = c.g_type_register_static_simple(
        c.gtk_widget_get_type(),
        "DockhGlow",
        q.class_size,
        @ptrCast(&glowClassInit),
        q.instance_size,
        null,
        0,
    );
    // Sanity: the snapshot/measure vfunc offsets below are measured against
    // this exact GTK build (4.22/x86_64). If a future GTK changes the
    // GtkWidgetClass layout, this size will differ and the glow must be
    // re-verified before relying on the offsets.
    log.debug("glow type registered (parent class_size={d})", .{q.class_size});
}

fn glowClassInit(class_ptr: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const base: [*]u8 = @ptrCast(@alignCast(class_ptr.?));
    const measure_slot: *?*const anyopaque = @ptrCast(@alignCast(base + 232));
    measure_slot.* = @ptrCast(&glowMeasure);
    const snapshot_slot: *?*const anyopaque = @ptrCast(@alignCast(base + 320));
    snapshot_slot.* = @ptrCast(&glowSnapshot);
}

/// Sizing: the glow fills the icon box exactly.
fn glowMeasure(widget: ?*anyopaque, orientation: c_int, _: c_int, minimum: ?*c_int, natural: ?*c_int, _: ?*c_int, _: ?*c_int) callconv(.c) void {
    _ = widget;
    _ = orientation;
    const size: c_int = state.cfg.icon_size;
    if (minimum) |m| m.* = size;
    if (natural) |n| n.* = size;
}

/// Draw the icon blurred: push a blur region, snapshot the paintable into it,
/// pop. GtkOverlay stacks the crisp icon on top, so the glow sits behind it.
fn glowSnapshot(widget: ?*anyopaque, snap: ?*anyopaque) callconv(.c) void {
    const paintable = c.g_object_get_data(widget, "dockh-glow-paintable") orelse return;
    const w = c.gtk_widget_get_width(widget);
    const h = c.gtk_widget_get_height(widget);
    if (w <= 0 or h <= 0) return;

    var bounds = c.GrapheneRect{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(w),
        .height = @floatFromInt(h),
    };

    switch (backend) {
        .blur_node => {
            c.gtk_snapshot_push_blur(snap, @floatCast(state.cfg.glow_radius));
            c.gdk_paintable_snapshot(paintable, snap, @floatFromInt(w), @floatFromInt(h));
            c.gtk_snapshot_pop(snap);
        },
        .gl_shader => {
            // One uniform: u_radius (float). GTK packs uniforms in declaration
            // order into the node's args bytes; push_gl_shader takes ownership
            // of the GBytes.
            var args: [4]u8 = undefined;
            const rbits: u32 = @bitCast(@as(f32, @floatCast(state.cfg.glow_radius)));
            std.mem.writeInt(u32, args[0..4], rbits, .little);
            const args_bytes = c.g_bytes_new(&args, args.len);
            c.gtk_snapshot_push_gl_shader(snap, gl_shader.?, &bounds, args_bytes);
            c.gdk_paintable_snapshot(paintable, snap, @floatFromInt(w), @floatFromInt(h));
            c.gtk_snapshot_pop(snap);
        },
    }
}

/// Create the glow widget for an icon paintable. The paintable is ref'd and
/// released with the widget (g_object_set_data_full). Returns null when the
/// blur is unavailable or disabled — callers fall back to the plain icon.
pub fn makeGlowWidget(paintable: ?*anyopaque) ?*anyopaque {
    init();
    if (paintable == null or glow_type == 0) return null;
    if (state.cfg.glow_radius <= 0) return null;

    const widget = c.g_object_new(glow_type, null);
    if (widget == null) return null;

    _ = c.g_object_ref(paintable);
    c.g_object_set_data_full(widget, "dockh-glow-paintable", paintable, @ptrCast(&c.g_object_unref));
    c.gtk_widget_add_css_class(widget, "dockh-glow");
    return widget;
}
