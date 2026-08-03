//! Real GLSL "liquid glass" panel rendered by a GtkGLArea behind the icons.
//!
//! GskGLShaderNode is deprecated in GTK >= 4.16 — the ngl (Vulkan) renderer
//! ignores it — so the shader runs in a real GL context (GtkGLArea + libGL,
//! GLSL 330 core). The desktop region behind the dock is captured with grim
//! into a texture and the fragment shader implements the full optical model:
//!   * SDF rounded rect (alpha cutout outside the glass)
//!   * Splay — edge normals tilt like a lens (refraction)
//!   * Chromatic dispersion (per-channel sampling offset, prism effect)
//!   * Specular bevel lit by `light_angle`
//!   * Frost — circular multi-tap blur of the background
//!   * Depth — volumetric tint toward the center
//!
//! The background texture is captured with grim from the strip just OUTSIDE
//! the dock (above a bottom dock, below a top one): the dock sits at layer
//! bottom, so when it is visible only the wallpaper is behind it, and the
//! strip never contains the dock itself or the window that covers it — no
//! ghost apps, no hide/show flicker. It re-captures on workspace changes and
//! window open/close/fullscreen events, debounced. Everything is
//! demand-driven: GtkGLArea only renders when queued, so there is no
//! per-frame cost — 60 fps with zero extra load. The panel always renders
//! (even before/without the texture — the shader falls back to a flat tint
//! and the compositor's live blur provides the frost), so the glass never
//! disappears.
//!
//! Fallback: if GL or grim is unavailable, `createOverlay` returns null and
//! the window keeps the pure-CSS glass from style.css (unchanged behavior).
const std = @import("std");
const c = @import("c"); // named module (build.zig)
const state = @import("../core/state.zig");
const log = @import("../core/log.zig");

const CAPTURE_PATH = "/tmp/dockh-glass.png";

const vert_src: [*:0]const u8 =
    \\#version 330 core
    \\layout(location = 0) in vec2 a_pos;
    \\out vec2 v_uv;
    \\void main() {
    \\    // flip V so the grim capture (top-down PNG) maps 1:1 onto the widget
    \\    v_uv = vec2(a_pos.x * 0.5 + 0.5, 0.5 - a_pos.y * 0.5);
    \\    gl_Position = vec4(a_pos, 0.0, 1.0);
    \\}
;

const frag_src: [*:0]const u8 =
    \\#version 330 core
    \\in vec2 v_uv;
    \\out vec4 fragColor;
    \\uniform vec2 u_resolution;   // widget size in device px
    \\uniform sampler2D u_tex;     // grim capture of the desktop behind
    \\uniform float u_radius;      // corner radius (px)
    \\uniform float u_margin;      // panel inset (px)
    \\uniform float u_refraction;  // 0..1
    \\uniform float u_dispersion;  // 0..1
    \\uniform float u_splay;       // 0..1
    \\uniform float u_frost;       // 0..1
    \\uniform float u_depth;       // 0..1
    \\uniform float u_light_angle; // degrees
    \\uniform float u_alpha;       // 0..1
    \\uniform int u_has_tex;       // 1 = refraction samples the capture
    \\
    \\// SDF rounded rect (Inigo Quilez)
    \\float sdRoundRect(vec2 p, vec2 b, float r) {
    \\    vec2 q = abs(p) - b + r;
    \\    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
    \\}
    \\
    \\vec3 sampleBG(vec2 uv) {
    \\    // Without a capture the panel still renders: sample a flat dark
    \\    // tint so refraction/frost stay inert and the bevel/tint/depth
    \\    // carry the look (the compositor blurs the live background).
    \\    if (u_has_tex == 0) return vec3(0.08, 0.08, 0.11);
    \\    return texture(u_tex, clamp(uv, 0.0, 1.0)).rgb;
    \\}
    \\
    \\void main() {
    \\    vec2 px = v_uv * u_resolution;
    \\    vec2 half_b = u_resolution * 0.5 - u_margin;
    \\    vec2 p = px - u_resolution * 0.5;
    \\
    \\    float d = sdRoundRect(p, half_b, u_radius);
    \\    // alpha cutout with a 1.5px anti-aliased edge
    \\    float alpha = 1.0 - smoothstep(0.0, 1.5, d);
    \\    if (alpha <= 0.0) discard;
    \\
    \\    // Splay: near the border the normal tilts like a lens.
    \\    // edge() ramps from 0 (flat center) to 1 at the border.
    \\    float edge = smoothstep(-u_splay * 8.0, 0.0, d);
    \\    vec2 pn = p / half_b; // normalized position
    \\    vec2 n = normalize(pn + vec2(1e-5)) * edge * (u_refraction * 0.12);
    \\
    \\    // Refraction: sample the background offset by the edge normal.
    \\    vec2 n_uv = n * 0.5; // half-size spans 0.5 uv
    \\    vec2 uv_ref = v_uv - n_uv;
    \\
    \\    // Chromatic dispersion (prism): per-channel offsets.
    \\    float disp = u_dispersion * 0.02;
    \\    float rr = sampleBG(uv_ref + n_uv * disp).r;
    \\    float gg = sampleBG(uv_ref).g;
    \\    float bb = sampleBG(uv_ref - n_uv * disp).b;
    \\    vec3 col = vec3(rr, gg, bb);
    \\
    \\    // Frost: circular multi-tap blur of the refracted background.
    \\    if (u_frost > 0.001) {
    \\        vec3 acc = col;
    \\        float rad = u_frost * 0.004;
    \\        const int N = 8;
    \\        for (int i = 0; i < N; i++) {
    \\            float ang = float(i) * 6.28318530718 / float(N);
    \\            vec2 off = vec2(cos(ang), sin(ang)) * rad;
    \\            acc += sampleBG(uv_ref + off);
    \\        }
    \\        col = mix(col, acc / float(N + 1), u_frost * 0.7);
    \\    }
    \\
    \\    // Specular bevel lit from u_light_angle — kept subtle so the panel
    \\    // reads as continuous glass, not a rimmed container.
    \\    float ang = radians(u_light_angle);
    \\    vec2 L = vec2(cos(ang), sin(ang));
    \\    float spec = max(0.0, -dot(n, L));
    \\    float bevel = smoothstep(-3.0, 0.0, d) * smoothstep(0.0, -3.0, d);
    \\    col += vec3(1.0) * bevel * (spec * 1.0 + 0.06);
    \\
    \\    // Depth: volumetric tint (thicker glass toward the center).
    \\    col += vec3(0.05, 0.05, 0.1) * u_depth;
    \\
    \\    fragColor = vec4(col, alpha * u_alpha);
    \\}
;

var gl_area: ?*anyopaque = null;
var program: c_uint = 0;
var vao: c_uint = 0;
var vbo: c_uint = 0;
var texture: c_uint = 0;
var tex_w: c_int = 0;
var tex_h: c_int = 0;
var gl_ok = false;
var tex_ok = false;
var active = false; // .glass-on applied to the window
var grim_missing = false; // don't retry spawning grim every workspace switch
var recap_timer: c_uint = 0;
var poll_timer: c_uint = 0;
var poll_tries: u32 = 0;

// uniform locations
var loc_res: c_int = -1;
var loc_tex: c_int = -1;
var loc_radius: c_int = -1;
var loc_margin: c_int = -1;
var loc_refr: c_int = -1;
var loc_disp: c_int = -1;
var loc_splay: c_int = -1;
var loc_frost: c_int = -1;
var loc_depth: c_int = -1;
var loc_angle: c_int = -1;
var loc_alpha: c_int = -1;
var loc_has_tex: c_int = -1;

// ---------------------------------------------------------------------------
// GLSL compile/link helpers
// ---------------------------------------------------------------------------

fn compileShader(kind: c_uint, src: [*:0]const u8) c_uint {
    const sh = c.glCreateShader(kind);
    if (sh == 0) return 0;
    var srcs = [_][*:0]const u8{src};
    c.glShaderSource(sh, 1, &srcs, null);
    c.glCompileShader(sh);
    var ok: c_int = 0;
    c.glGetShaderiv(sh, c.GL_COMPILE_STATUS, &ok);
    if (ok == 0) {
        var len: c_int = 0;
        c.glGetShaderiv(sh, c.GL_INFO_LOG_LENGTH, &len);
        var buf: [512]u8 = undefined;
        if (len > 0 and len < buf.len) {
            c.glGetShaderInfoLog(sh, len, null, &buf);
            log.warn("glass shader: {s}", .{std.mem.span(@as([*:0]u8, @ptrCast(&buf)))});
        }
        c.glDeleteShader(sh);
        return 0;
    }
    return sh;
}

fn linkProgram(vs: c_uint, fs: c_uint) c_uint {
    const prog = c.glCreateProgram();
    if (prog == 0) return 0;
    c.glAttachShader(prog, vs);
    c.glAttachShader(prog, fs);
    c.glLinkProgram(prog);
    var ok: c_int = 0;
    c.glGetProgramiv(prog, c.GL_LINK_STATUS, &ok);
    if (ok == 0) {
        var len: c_int = 0;
        c.glGetProgramiv(prog, c.GL_INFO_LOG_LENGTH, &len);
        var buf: [512]u8 = undefined;
        if (len > 0 and len < buf.len) {
            c.glGetProgramInfoLog(prog, len, null, &buf);
            log.warn("glass link: {s}", .{std.mem.span(@as([*:0]u8, @ptrCast(&buf)))});
        }
        c.glDeleteProgram(prog);
        return 0;
    }
    c.glDeleteShader(vs);
    c.glDeleteShader(fs);
    return prog;
}

fn setupGeometry() bool {
    c.glGenVertexArrays(1, &vao);
    c.glGenBuffers(1, &vbo);
    c.glBindVertexArray(vao);
    c.glBindBuffer(c.GL_ARRAY_BUFFER, vbo);
    // one big triangle covering the whole widget
    const verts = [_]f32{ -1.0, -1.0, 3.0, -1.0, -1.0, 3.0 };
    c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(f32) * verts.len, &verts, c.GL_STATIC_DRAW);
    c.glVertexAttribPointer(0, 2, c.GL_FLOAT, 0, 0, null);
    c.glEnableVertexAttribArray(0);
    return true;
}

// ---------------------------------------------------------------------------
// grim capture
// ---------------------------------------------------------------------------

const CaptureRect = struct { x: c_int, y: c_int, w: c_int, h: c_int, valid: bool };

fn monitorForDock() ?*anyopaque {
    const display = c.gdk_display_get_default() orelse return null;
    const list = c.gdk_display_get_monitors(display);
    if (list == null) return null;
    const n = c.g_list_model_get_n_items(list);
    var i: c_uint = 0;
    while (i < n) : (i += 1) {
        const item = c.g_list_model_get_item(list, i);
        if (item == null) continue;
        if (state.cfg.target_output.len == 0) return item;
        const conn = c.gdk_monitor_get_connector(item);
        if (conn != null and std.mem.eql(u8, std.mem.span(conn.?), state.cfg.target_output)) {
            return item;
        }
        c.g_object_unref(item);
    }
    return null;
}

/// The region grim captures (logical px, output layout coords) so the texture
/// maps 1:1 onto the panel: the parallel strip just outside the dock (pure
/// wallpaper — no self-capture, no ghost apps, no hide/show flicker).
fn captureRect() CaptureRect {
    const mon = monitorForDock() orelse return .{ .x = 0, .y = 0, .w = 0, .h = 0, .valid = false };
    defer c.g_object_unref(mon);
    var g: c.GdkRect = .{};
    c.gdk_monitor_get_geometry(mon, &g);
    const box = state.outer_box orelse return .{ .x = 0, .y = 0, .w = 0, .h = 0, .valid = false };

    var min_w: c_int = 0;
    var nat_w: c_int = 0;
    c.gtk_widget_measure(box, c.ORIENTATION_HORIZONTAL, -1, &min_w, &nat_w, null, null);
    var min_h: c_int = 0;
    var nat_h: c_int = 0;
    c.gtk_widget_measure(box, c.ORIENTATION_VERTICAL, -1, &min_h, &nat_h, null, null);
    if (nat_w <= 0 or nat_h <= 0) return .{ .x = 0, .y = 0, .w = 0, .h = 0, .valid = false };

    const vertical = std.mem.eql(u8, state.cfg.position, "left") or std.mem.eql(u8, state.cfg.position, "right");
    var w = nat_w;
    var h = nat_h;
    if (state.cfg.full) {
        if (vertical) h = g.height else w = g.width;
    }

    var x: c_int = 0;
    var y: c_int = 0;
    if (!vertical) {
        // horizontal dock (bottom/top)
        if (std.mem.eql(u8, state.cfg.position, "top")) {
            y = g.y + state.cfg.margin_top;
        } else {
            y = g.y + g.height - h - state.cfg.margin_bottom;
        }
        if (std.mem.eql(u8, state.cfg.alignment, "start")) {
            x = g.x + state.cfg.margin_left;
        } else if (std.mem.eql(u8, state.cfg.alignment, "end")) {
            x = g.x + g.width - w - state.cfg.margin_right;
        } else {
            x = g.x + @divTrunc(g.width - w, 2);
        }
    } else {
        // vertical dock (left/right)
        if (std.mem.eql(u8, state.cfg.position, "left")) {
            x = g.x + state.cfg.margin_left;
        } else {
            x = g.x + g.width - w - state.cfg.margin_right;
        }
        if (std.mem.eql(u8, state.cfg.alignment, "start")) {
            y = g.y + state.cfg.margin_top;
        } else if (std.mem.eql(u8, state.cfg.alignment, "end")) {
            y = g.y + g.height - h - state.cfg.margin_bottom;
        } else {
            y = g.y + @divTrunc(g.height - h, 2);
        }
    }
    // Capture the parallel strip just OUTSIDE the dock instead of the dock
    // itself: the strip is pure wallpaper (never the dock or the window that
    // covers it — the dock sits at layer bottom), so the glass background is
    // always clean, and no hide/show flicker is needed for the capture.
    // Wallpaper is continuous, so the strip content matches the panel area.
    var sx = x;
    var sy = y;
    if (!vertical) {
        if (std.mem.eql(u8, state.cfg.position, "bottom")) {
            sy = y - h; // strip just above the dock
            if (sy < g.y) sy = y + h; // near the top edge → flip below
        } else {
            sy = y + h; // strip just below the dock
            if (sy + h > g.y + g.height) sy = y - h;
        }
        if (sy < g.y) sy = g.y;
        if (sy + h > g.y + g.height) h = g.y + g.height - sy;
    } else {
        if (std.mem.eql(u8, state.cfg.position, "left")) {
            sx = x + w;
            if (sx + w > g.x + g.width) sx = x - w;
        } else {
            sx = x - w;
            if (sx < g.x) sx = x + w;
        }
        if (sx < g.x) sx = g.x;
        if (sx + w > g.x + g.width) w = g.x + g.width - sx;
    }
    // pathological layout (tiny monitor, huge margins): never hand grim a
    // zero/negative region — the flat-tint fallback takes over instead
    if (w <= 0 or h <= 0) return .{ .x = 0, .y = 0, .w = 0, .h = 0, .valid = false };
    return .{ .x = sx, .y = sy, .w = w, .h = h, .valid = true };
}

fn spawnGrim(rect: CaptureRect) bool {
    if (grim_missing) return false;
    var gbuf: [64:0]u8 = undefined;
    const gz = std.fmt.bufPrintZ(&gbuf, "{d},{d} {d}x{d}", .{ rect.x, rect.y, rect.w, rect.h }) catch return false;
    const argv = [_]?[*:0]u8{
        @constCast("grim"),
        @constCast("-g"),
        @constCast(gz.ptr),
        @constCast("-t"),
        @constCast("png"),
        @constCast(CAPTURE_PATH),
        null,
    };
    var pid: c_int = 0;
    const envp: [*]const ?[*:0]u8 = @ptrCast(c.environ);
    const rc = c.posix_spawnp(&pid, @constCast("grim"), null, null, &argv, envp);
    if (rc != 0) {
        if (!grim_missing) {
            log.warn("glass: grim unavailable ({s}); using CSS glass", .{std.mem.span(c.strerror(rc))});
            grim_missing = true;
        }
        return false;
    }
    return true;
}

/// Upload the capture PNG (if ready) into the GL texture. Returns true when
/// loaded. Must be called with the GL context current (render/realize, or
/// after gtk_gl_area_make_current).
fn loadTextureIfReady() bool {
    if (c.access(CAPTURE_PATH, c.F_OK) != 0) return false;
    var err: ?*anyopaque = null;
    const pb = c.gdk_pixbuf_new_from_file(CAPTURE_PATH, &err);
    if (pb == null) {
        if (err) |e| c.g_error_free(e);
        return false; // grim still writing — retry
    }
    defer c.g_object_unref(pb);

    const w = c.gdk_pixbuf_get_width(pb);
    const h = c.gdk_pixbuf_get_height(pb);
    const nch = c.gdk_pixbuf_get_n_channels(pb);
    const stride = c.gdk_pixbuf_get_rowstride(pb);
    const px = c.gdk_pixbuf_get_pixels(pb);
    if (w <= 0 or h <= 0) return false;

    if (texture == 0) c.glGenTextures(1, &texture);
    c.glBindTexture(c.GL_TEXTURE_2D, texture);
    // grim writes RGB PNGs (3 channels, no alpha) — upload as GL_RGB. The old
    // code always passed GL_RGBA, so GL read every row from the wrong byte
    // offset (rows are 3 bytes/texel, not 4) and the panel came out with
    // vertical stripes. GL_UNPACK_ALIGNMENT=1 makes any row stride safe.
    const gl_fmt: c_uint = if (nch == 3) c.GL_RGB else c.GL_RGBA;
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
    if (stride != w * nch) c.glPixelStorei(c.GL_UNPACK_ROW_LENGTH, @divTrunc(stride, nch));
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, w, h, 0, gl_fmt, c.GL_UNSIGNED_BYTE, px);
    c.glPixelStorei(c.GL_UNPACK_ROW_LENGTH, 0);
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 4);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    tex_w = w;
    tex_h = h;
    tex_ok = true;
    log.debug("glass: background texture {d}x{d}", .{ w, h });
    return true;
}

fn activate() void {
    if (active) return;
    active = true;
    if (state.win) |w| c.gtk_widget_add_css_class(w, "glass-on");
    if (gl_area) |a| c.gtk_gl_area_queue_render(a);
}

/// Check whether grim finished writing the capture file. Pure gdk-pixbuf (no
/// GL) — safe to call while the window is hidden and the GtkGLArea unrealized.
fn captureFileReady() bool {
    if (c.access(CAPTURE_PATH, c.F_OK) != 0) return false;
    var err: ?*anyopaque = null;
    const pb = c.gdk_pixbuf_new_from_file(CAPTURE_PATH, &err);
    if (pb == null) {
        if (err) |e| c.g_error_free(e);
        return false; // grim still writing — retry
    }
    c.g_object_unref(pb);
    return true;
}

/// Poll for the capture file. NEVER touches GL while the window is hidden:
/// a recapture hides the dock, which unrealizes the GtkGLArea and destroys
/// its GL context — calling gtk_gl_area_make_current there made Mesa SIGSEGV
/// (libgallium crash from a GLib timeout, confirmed in the coredump). This
/// only waits for grim's PNG, then re-shows the window so onRealize uploads
/// the texture into a fresh context. The upload also runs here directly when
/// the window was never hidden (autohide ghost mode).
fn pollForTexture(_: ?*anyopaque) callconv(.c) c_int {
    poll_tries += 1;
    if (!gl_ok) {
        // Not realized yet (startup): onRealize loads once the window shows.
        if (poll_tries > 120) {
            poll_timer = 0;
            return 0;
        }
        return 1;
    }
    if (captureFileReady()) {
        poll_timer = 0;
        const a = gl_area orelse return 0;
        // If the window was hidden (autohide), the GL area is unrealized —
        // calling make_current there would crash Mesa. In that case onRealize
        // loads the texture when the dock shows again.
        if (c.gtk_widget_get_realized(a) != 0) {
            c.gtk_gl_area_make_current(a);
            if (loadTextureIfReady()) {
                activate();
                if (gl_area) |g| c.gtk_gl_area_queue_render(g);
            }
        }
        return 0;
    }
    if (poll_tries > 60) {
        poll_timer = 0;
        return 0;
    }
    return 1; // keep polling (grim may still be writing)
}

fn armPoll() void {
    if (poll_timer != 0) _ = c.g_source_remove(poll_timer);
    poll_tries = 0;
    poll_timer = c.g_timeout_add(100, @ptrCast(&pollForTexture), null);
}

fn onRecaptureTimeout(_: ?*anyopaque) callconv(.c) c_int {
    recap_timer = 0;
    if (!gl_ok) return 0;
    // a capture is already in flight — don't stack another grim process
    if (poll_timer != 0) return 0;
    const rect = captureRect();
    if (!rect.valid) return 0;
    // No hide/show: the capture region is the strip outside the dock, so the
    // dock never lands in its own background and the panel never flickers.
    if (!spawnGrim(rect)) return 0;
    armPoll();
    return 0;
}

// ---------------------------------------------------------------------------
// GtkGLArea signals
// ---------------------------------------------------------------------------

fn onRealize(widget: ?*anyopaque) callconv(.c) void {
    gl_area = widget;
    c.gtk_gl_area_make_current(widget);
    if (c.gtk_gl_area_get_error(widget) != null) {
        log.warn("glass: no GL context; using CSS glass", .{});
        return;
    }
    const vs = compileShader(c.GL_VERTEX_SHADER, vert_src);
    if (vs == 0) return;
    const fs = compileShader(c.GL_FRAGMENT_SHADER, frag_src);
    if (fs == 0) {
        c.glDeleteShader(vs);
        return;
    }
    program = linkProgram(vs, fs);
    if (program == 0) return;
    if (!setupGeometry()) return;

    loc_res = c.glGetUniformLocation(program, "u_resolution");
    loc_tex = c.glGetUniformLocation(program, "u_tex");
    loc_radius = c.glGetUniformLocation(program, "u_radius");
    loc_margin = c.glGetUniformLocation(program, "u_margin");
    loc_refr = c.glGetUniformLocation(program, "u_refraction");
    loc_disp = c.glGetUniformLocation(program, "u_dispersion");
    loc_splay = c.glGetUniformLocation(program, "u_splay");
    loc_frost = c.glGetUniformLocation(program, "u_frost");
    loc_depth = c.glGetUniformLocation(program, "u_depth");
    loc_angle = c.glGetUniformLocation(program, "u_light_angle");
    loc_alpha = c.glGetUniformLocation(program, "u_alpha");
    loc_has_tex = c.glGetUniformLocation(program, "u_has_tex");
    gl_ok = true;

    // A hide/show cycle (autohide) unrealizes the GtkGLArea, destroying its
    // GL context — every GL object id is stale in the fresh context, so drop
    // the old texture handle and re-create it from the current capture file.
    texture = 0;
    tex_ok = false;

    // The panel renders NOW (no-texture fallback), so the glass is visible
    // immediately; the texture loads async and enables refraction.
    activate();
    if (loadTextureIfReady()) {
        if (gl_area) |a| c.gtk_gl_area_queue_render(a);
    } else {
        armPoll();
    }
}

fn onRender(widget: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    if (!gl_ok) return 0;
    const scale: f32 = @floatFromInt(c.gtk_widget_get_scale_factor(widget));
    const w_px: f32 = @floatFromInt(c.gtk_widget_get_width(widget));
    const h_px: f32 = @floatFromInt(c.gtk_widget_get_height(widget));
    const w = w_px * scale;
    const h = h_px * scale;

    c.glViewport(0, 0, @intFromFloat(w), @intFromFloat(h));
    c.glClearColor(0, 0, 0, 0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);

    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glUseProgram(program);
    c.glUniform2f(loc_res, w, h);
    c.glUniform1f(loc_radius, state.cfg.glass_radius * scale);
    c.glUniform1f(loc_margin, state.cfg.glass_margin * scale);
    c.glUniform1f(loc_refr, state.cfg.glass_refraction);
    c.glUniform1f(loc_disp, state.cfg.glass_dispersion);
    c.glUniform1f(loc_splay, state.cfg.glass_splay);
    c.glUniform1f(loc_frost, state.cfg.glass_frost);
    c.glUniform1f(loc_depth, state.cfg.glass_depth);
    c.glUniform1f(loc_angle, state.cfg.glass_light_angle);
    c.glUniform1f(loc_alpha, state.cfg.glass_alpha);
    c.glUniform1i(loc_has_tex, if (tex_ok) 1 else 0);
    if (tex_ok) {
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, texture);
        c.glUniform1i(loc_tex, 0);
    }
    c.glBindVertexArray(vao);
    c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
    return 0;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// The GL widget was resized (box content changed → syncSize): re-render with
/// the new resolution uniforms. Required with auto_render off.
fn onGLResize(widget: ?*anyopaque, _: c_int, _: c_int, _: ?*anyopaque) callconv(.c) void {
    if (gl_ok) c.gtk_gl_area_queue_render(widget);
}

/// Keep the GL area exactly the size of the dock box. The overlay's main
/// child (the GL area) drives the window size — a GtkGLArea has no natural
/// size, so without this the window clamps to GTK's 200x200 default minimum
/// and the 333x84 capture gets stretched over it (the elongated, smeared
/// panel). It also keeps the capture (measured from the same box) mapping 1:1
/// onto the widget.
pub fn syncSize() void {
    if (!state.cfg.glass_enabled) return;
    const a = gl_area orelse return;
    const box = state.outer_box orelse return;
    var min_w: c_int = 0;
    var nat_w: c_int = 0;
    c.gtk_widget_measure(box, c.ORIENTATION_HORIZONTAL, -1, &min_w, &nat_w, null, null);
    var min_h: c_int = 0;
    var nat_h: c_int = 0;
    c.gtk_widget_measure(box, c.ORIENTATION_VERTICAL, -1, &min_h, &nat_h, null, null);
    if (nat_w <= 0 or nat_h <= 0) return;
    c.gtk_widget_set_size_request(a, nat_w, nat_h);
}

/// Live config hot reload: the shader uniforms are re-read from state.cfg on
/// every render, so after the config changed we only need to queue one more
/// pass (and re-sync the GL area size in case the box changed). No teardown,
/// no restart — the same GL context keeps running.
pub fn refresh() void {
    if (!state.cfg.glass_enabled) return;
    const a = gl_area orelse return;
    syncSize();
    if (gl_ok) c.gtk_gl_area_queue_render(a);
}

/// Build the window child: a GtkOverlay with the GL glass behind and the dock
/// box on top. Returns null (fallback to CSS glass) when glass is disabled or
/// the environment can't support it (grim missing).
pub fn createOverlay(outer_box: ?*anyopaque) ?*anyopaque {
    if (!state.cfg.glass_enabled) return null;

    const a = c.gtk_gl_area_new();
    if (a == null) return null;
    gl_area = a;
    // The shader needs GLSL 330 core.
    c.gtk_gl_area_set_required_version(a, 3, 3);
    c.gtk_gl_area_set_use_es(a, 0);
    c.gtk_widget_set_name(a, "dockh-glass");
    // Render ONLY when queued (texture load, resize, activate): with the
    // default auto_render the shader re-ran on every window redraw, so the
    // hover magnify (a 60 fps CSS animation) cost a full GL pass per frame —
    // the FPS drop. The last frame stays cached and is composited cheaply.
    c.gtk_gl_area_set_auto_render(a, 0);
    _ = c.g_signal_connect(a, "realize", @ptrCast(&onRealize), null);
    _ = c.g_signal_connect(a, "render", @ptrCast(&onRender), null);
    _ = c.g_signal_connect(a, "resize", @ptrCast(&onGLResize), null);

    const overlay = c.gtk_overlay_new();
    if (overlay == null) return null;
    c.gtk_overlay_set_child(overlay, a);
    c.gtk_overlay_add_overlay(overlay, outer_box);
    syncSize(); // window must hug the box, not GTK's 200x200 default min
    return overlay;
}

/// Spawn the initial grim capture. Must run BEFORE the window is shown (so
/// the dock itself is not in its own background), after the box is measured.
pub fn captureStartup() void {
    if (!state.cfg.glass_enabled or grim_missing) return;
    if (gl_area == null) return; // overlay creation failed — nothing to feed
    const rect = captureRect();
    if (!rect.valid) return;
    _ = spawnGrim(rect);
    // texture load happens in onRealize (or the poll fallback)
}

/// The background may have changed (workspace switch, window open/close/
/// fullscreen) → re-capture the strip outside the dock (debounced). Runs even
/// without a texture yet, so a failed first capture is retried.
pub fn onBackgroundChanged() void {
    if (!state.cfg.glass_enabled or !gl_ok) return;
    // The texture is now stale: it captured the PREVIOUS workspace's strip,
    // which may have contained an app's pixels. Keeping it bound would flash
    // that app's background inside the glass for the ~1s grim takes to
    // re-capture — the "ghost app" the user sees when switching to an empty
    // workspace. Drop it immediately: the shader falls back to the flat tint
    // + the compositor's live blur until the fresh capture lands.
    tex_ok = false;
    if (gl_area) |a| c.gtk_gl_area_queue_render(a);
    // Also kill any poll that is still waiting on the PREVIOUS capture: if it
    // finished after us it would load the stale file back into the texture
    // (re-showing the ghost), and onRecaptureTimeout bails while a poll is
    // running — so no fresh capture would ever replace it. Deleting the file
    // makes any straggler captureFileReady() return false until grim writes
    // the new one.
    if (poll_timer != 0) {
        _ = c.g_source_remove(poll_timer);
        poll_timer = 0;
    }
    _ = c.unlink(CAPTURE_PATH);
    if (recap_timer != 0) _ = c.g_source_remove(recap_timer);
    // Shorter debounce: with the flat-tint fallback the panel never shows a
    // stale frame, so a snappier re-capture only makes the wallpaper return
    // sooner.
    recap_timer = c.g_timeout_add(150, @ptrCast(&onRecaptureTimeout), null);
}

/// Hard-memory-pressure escape hatch (the memory watchdog in main.zig): drop
/// the GL liquid-glass panel and go back to the pure-CSS glass. The box
/// becomes the overlay's main child (the window keeps hugging it) and the
/// GtkGLArea is explicitly unparented + destroyed — tearing down its GL
/// context (the ~70 MB of Mesa). Returns true when it actually disabled
/// (the watchdog uses that to log the transition only once, not per tick).
pub fn emergencyDisable() bool {
    if (!gl_ok and !active and gl_area == null) return false;
    if (state.win) |w| c.gtk_widget_remove_css_class(w, "glass-on");
    if (gl_area) |a| {
        const overlay = c.gtk_widget_get_parent(a);
        if (overlay != null) {
            if (state.outer_box) |box| c.gtk_overlay_remove_overlay(overlay, box);
            // Replacing the overlay's main child (the GtkGLArea was set via
            // gtk_overlay_set_child in createOverlay) unparents and destroys
            // the old child — tearing down its GL context. We deliberately do
            // NOT call gtk_widget_unparent() here: GTK4 documents it as a
            // widget-implementation API, and calling it from app code fired a
            // GTK_IS_WIDGET assertion.
            c.gtk_overlay_set_child(overlay, state.outer_box);
        }
    }
    if (poll_timer != 0) {
        _ = c.g_source_remove(poll_timer);
        poll_timer = 0;
    }
    if (recap_timer != 0) {
        _ = c.g_source_remove(recap_timer);
        recap_timer = 0;
    }
    gl_ok = false;
    tex_ok = false;
    active = false;
    gl_area = null;
    return true;
}

