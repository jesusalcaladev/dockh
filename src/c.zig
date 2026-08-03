//! Hand-written C-ABI declarations for exactly the GTK4 / gtk4-layer-shell /
//! GLib / libc surface dockh uses. No @cImport, no generated bindings — the
//! shortest path from Zig to the C ABI. All GTK objects are opaque handles
//! (?*anyopaque); plain ints carry enums and flags (stable Linux ABI values).

// ---------------------------------------------------------------------------
// GLib / GTK4
// ---------------------------------------------------------------------------

pub const GtkWidget = ?*anyopaque;
pub const GdkMonitor = ?*anyopaque;

pub const GtkOrientation = c_int; // HORIZONTAL=0 VERTICAL=1
pub const ORIENTATION_HORIZONTAL: c_int = 0;
pub const ORIENTATION_VERTICAL: c_int = 1;

pub const GtkPositionType = c_int; // LEFT=0 RIGHT=1 TOP=2 BOTTOM=3
pub const POSITION_LEFT: c_int = 0;
pub const POSITION_RIGHT: c_int = 1;
pub const POSITION_TOP: c_int = 2;
pub const POSITION_BOTTOM: c_int = 3;

pub const GtkAlign = c_int; // FILL=0 START=1 END=2 CENTER=3 (GTK4 order!)
pub const ALIGN_FILL: c_int = 0;
pub const ALIGN_START: c_int = 1;
pub const ALIGN_END: c_int = 2;
pub const ALIGN_CENTER: c_int = 3;

// GtkIconLookupFlags (GTK 4.18+: NONE=0 FORCE_REGULAR=1 FORCE_SYMBOLIC=2 PRELOAD=4)
pub const ICON_LOOKUP_NONE: c_uint = 0;

// GtkStyleProviderPriority (GTK_STYLE_PROVIDER_PRIORITY_APPLICATION = 600)
pub const PROVIDER_PRIORITY_APPLICATION: c_uint = 600;

// gdk_monitor_get_geometry
pub const GdkRect = extern struct {
    x: c_int = 0,
    y: c_int = 0,
    width: c_int = 0,
    height: c_int = 0,
};

pub extern fn gtk_init() void;

// GLib main loop (GTK4 removed gtk_main/gtk_main_quit — we drive the
// default main context with GMainLoop, the standard pattern for
// layer-shell panels without a GtkApplication).
pub extern fn g_main_loop_new(context: ?*anyopaque, is_running: c_int) ?*anyopaque;
pub extern fn g_main_loop_run(loop: ?*anyopaque) void;
pub extern fn g_main_loop_quit(loop: ?*anyopaque) void;
pub extern fn g_main_loop_unref(loop: ?*anyopaque) void;

pub extern fn gtk_window_new() GtkWidget;
pub extern fn gtk_window_set_child(window: GtkWidget, child: GtkWidget) void;
pub extern fn gtk_window_set_title(window: GtkWidget, title: [*:0]const u8) void;
// -1 = "no default size": let the layer-shell window shrink to its content
// instead of keeping GTK's 200x200 minimum (which left dead space in the box).
pub extern fn gtk_window_set_default_size(window: GtkWidget, width: c_int, height: c_int) void;

pub extern fn gtk_widget_set_name(widget: GtkWidget, name: [*:0]const u8) void;
pub extern fn gtk_widget_add_css_class(widget: GtkWidget, name: [*:0]const u8) void;
pub extern fn gtk_widget_remove_css_class(widget: GtkWidget, name: [*:0]const u8) void;
pub extern fn gtk_widget_show(widget: GtkWidget) void;
pub extern fn gtk_widget_hide(widget: GtkWidget) void;
pub extern fn gtk_widget_is_visible(widget: GtkWidget) c_int;
pub extern fn gtk_widget_get_realized(widget: GtkWidget) c_int;
pub extern fn gtk_widget_set_tooltip_text(widget: GtkWidget, text: [*:0]const u8) void;
pub extern fn gtk_widget_set_size_request(widget: GtkWidget, width: c_int, height: c_int) void;
pub extern fn gtk_widget_add_controller(widget: GtkWidget, controller: ?*anyopaque) void;
pub extern fn gtk_widget_get_first_child(widget: GtkWidget) GtkWidget;
pub extern fn gtk_widget_get_next_sibling(widget: GtkWidget) GtkWidget;
pub extern fn gtk_widget_set_hexpand(widget: GtkWidget, expand: c_int) void;
pub extern fn gtk_widget_set_vexpand(widget: GtkWidget, expand: c_int) void;
pub extern fn gtk_widget_set_halign(widget: GtkWidget, alignment: GtkAlign) void;
pub extern fn gtk_widget_set_valign(widget: GtkWidget, alignment: GtkAlign) void;

// Measure a widget's natural size before it is realized (used to compute the
// desktop region behind the dock for the liquid-glass background capture).
pub extern fn gtk_widget_measure(widget: GtkWidget, orientation: GtkOrientation, for_size: c_int, minimum: ?*c_int, natural: ?*c_int, minimum_baseline: ?*c_int, natural_baseline: ?*c_int) void;

// ---------------------------------------------------------------------------
// GtkGLArea: a real GL context inside the dock — the modern replacement for
// GskGLShaderNode, which the ngl (Vulkan) renderer ignores (deprecated in
// GTK 4.16+; blur.zig only uses it on < 4.16). Runs the liquid-glass GLSL.
// ---------------------------------------------------------------------------

pub extern fn gtk_gl_area_new() GtkWidget;
pub extern fn gtk_gl_area_set_auto_render(area: GtkWidget, auto_render: c_int) void;
pub extern fn gtk_gl_area_queue_render(area: GtkWidget) void;
pub extern fn gtk_gl_area_get_error(area: GtkWidget) ?*anyopaque;
pub extern fn gtk_gl_area_make_current(area: GtkWidget) void;
pub extern fn gtk_widget_get_scale_factor(widget: GtkWidget) c_int;

// Request an OpenGL 3.3 core context — the liquid-glass shader is written in
// GLSL 330. GtkGLArea's default is a much older context; without this the
// shader would fail to compile and the dock would silently fall back to CSS.
pub extern fn gtk_gl_area_set_required_version(area: GtkWidget, major: c_int, minor: c_int) void;
pub extern fn gtk_gl_area_set_use_es(area: GtkWidget, use_es: c_int) void;

// glDeleteShader / glDeleteProgram: teardown after a compile/link failure.
pub extern fn glDeleteShader(shader: c_uint) void;
pub extern fn glDeleteProgram(program: c_uint) void;

// glGetString: report the actual GL version on startup (troubleshooting).
pub const GL_VERSION: c_uint = 0x1F02;
pub extern fn glGetString(name: c_uint) ?[*:0]const u8;

// glTexImage2D row pitch: GdkPixbuf rows are 4-byte aligned and may be wider
// than width*channels — tell GL so the glass texture isn't skewed on HiDPI.
// (declared once with the GdkPixbuf bindings below)

// OpenGL (resolved through libepoxy — declared in the exact form epoxy
// exports them, so the build just links -lepoxy).
pub extern fn glCreateShader(kind: c_uint) c_uint;
pub extern fn glShaderSource(shader: c_uint, count: c_int, string: [*]const [*:0]const u8, length: ?[*]const c_int) void;
pub extern fn glCompileShader(shader: c_uint) void;
pub extern fn glGetShaderiv(shader: c_uint, pname: c_int, params: *c_int) void;
pub extern fn glGetShaderInfoLog(shader: c_uint, max_length: c_int, length: ?*c_int, info_log: [*]u8) void;
pub extern fn glCreateProgram() c_uint;
pub extern fn glAttachShader(program: c_uint, shader: c_uint) void;
pub extern fn glLinkProgram(program: c_uint) void;
pub extern fn glGetProgramiv(program: c_uint, pname: c_int, params: *c_int) void;
pub extern fn glGetProgramInfoLog(program: c_uint, max_length: c_int, length: ?*c_int, info_log: [*]u8) void;
pub extern fn glUseProgram(program: c_uint) void;
pub extern fn glGenVertexArrays(count: c_int, arrays: *c_uint) void;
pub extern fn glBindVertexArray(array: c_uint) void;
pub extern fn glGenBuffers(count: c_int, buffers: *c_uint) void;
pub extern fn glBindBuffer(target: c_uint, buffer: c_uint) void;
pub extern fn glBufferData(target: c_uint, size: isize, data: ?*const anyopaque, usage: c_uint) void;
pub extern fn glVertexAttribPointer(index: c_uint, size: c_int, type_: c_uint, normalized: u8, stride: c_int, pointer: ?*const anyopaque) void;
pub extern fn glEnableVertexAttribArray(index: c_uint) void;
pub extern fn glDrawArrays(mode: c_uint, first: c_int, count: c_int) void;
pub extern fn glGetUniformLocation(program: c_uint, name: [*:0]const u8) c_int;
pub extern fn glUniform1f(location: c_int, v0: f32) void;
pub extern fn glUniform2f(location: c_int, v0: f32, v1: f32) void;
pub extern fn glUniform1i(location: c_int, v0: c_int) void;
pub extern fn glActiveTexture(texture: c_uint) void;
pub extern fn glBindTexture(target: c_uint, texture: c_uint) void;
pub extern fn glGenTextures(count: c_int, textures: *c_uint) void;
pub extern fn glTexImage2D(target: c_uint, level: c_int, internal_format: c_int, width: c_int, height: c_int, border: c_int, format: c_uint, type_: c_uint, pixels: ?*const anyopaque) void;
pub extern fn glTexParameteri(target: c_uint, pname: c_int, param: c_int) void;
pub extern fn glPixelStorei(pname: c_int, param: c_int) void;
pub extern fn glViewport(x: c_int, y: c_int, width: c_int, height: c_int) void;
pub extern fn glEnable(cap: c_uint) void;
pub extern fn glDisable(cap: c_uint) void;
pub extern fn glBlendFunc(sfactor: c_uint, dfactor: c_uint) void;
pub extern fn glClearColor(r: f32, g: f32, b: f32, a: f32) void;
pub extern fn glClear(mask: c_uint) void;

// OpenGL constants (stable ABI values).
pub const GL_VERTEX_SHADER: c_uint = 0x8B31;
pub const GL_FRAGMENT_SHADER: c_uint = 0x8B30;
pub const GL_COMPILE_STATUS: c_int = 0x8B81;
pub const GL_LINK_STATUS: c_int = 0x8B82;
pub const GL_INFO_LOG_LENGTH: c_int = 0x8B84;
pub const GL_ARRAY_BUFFER: c_uint = 0x8892;
pub const GL_STATIC_DRAW: c_uint = 0x88E4;
pub const GL_TRIANGLES: c_uint = 0x0004;
pub const GL_TEXTURE0: c_uint = 0x84C0;
pub const GL_TEXTURE_2D: c_uint = 0x0DE1;
pub const GL_RGBA: c_uint = 0x1908;
pub const GL_RGB: c_uint = 0x1907;
pub const GL_RGBA8: c_int = 0x8058;
pub const GL_UNSIGNED_BYTE: c_uint = 0x1401;
pub const GL_TEXTURE_MIN_FILTER: c_int = 0x2801;
pub const GL_TEXTURE_MAG_FILTER: c_int = 0x2800;
pub const GL_LINEAR: c_int = 0x2601;
pub const GL_TEXTURE_WRAP_S: c_int = 0x2802;
pub const GL_TEXTURE_WRAP_T: c_int = 0x2803;
pub const GL_CLAMP_TO_EDGE: c_int = 0x812F;
pub const GL_UNPACK_ROW_LENGTH: c_int = 0x0CF2;
pub const GL_UNPACK_ALIGNMENT: c_int = 0x0CF5;
pub const GL_FLOAT: c_uint = 0x1406;
pub const GL_BLEND: c_uint = 0x0BE2;
pub const GL_SRC_ALPHA: c_uint = 0x0302;
pub const GL_ONE_MINUS_SRC_ALPHA: c_uint = 0x0303;
pub const GL_COLOR_BUFFER_BIT: c_uint = 0x00004000;

// GdkPixbuf: load the captured desktop region into a GL texture.
// gdk-pixbuf 2.40+ exports the UTF-8 variant as the plain name (no _utf8
// suffix — that was the old GLib filename encoding).
pub extern fn gdk_pixbuf_new_from_file(filename: [*:0]const u8, err_out: ?*?*anyopaque) ?*anyopaque;
pub extern fn gdk_pixbuf_get_width(pixbuf: ?*anyopaque) c_int;
pub extern fn gdk_pixbuf_get_height(pixbuf: ?*anyopaque) c_int;
pub extern fn gdk_pixbuf_get_n_channels(pixbuf: ?*anyopaque) c_int;
pub extern fn gdk_pixbuf_get_rowstride(pixbuf: ?*anyopaque) c_int;
pub extern fn gdk_pixbuf_get_pixels(pixbuf: ?*anyopaque) [*]u8;

pub extern fn unlink(pathname: [*:0]const u8) c_int;

// Force a redraw: wakes the frame clock from the magnify motion handler so
// the GtkTickCallback fires even when no CSS transition/hover invalidation
// is running (the widget_transform demo's pattern).
pub extern fn gtk_widget_queue_draw(widget: GtkWidget) void;

pub extern fn gtk_box_new(orientation: GtkOrientation, spacing: c_int) GtkWidget;
pub extern fn gtk_box_append(box: GtkWidget, child: GtkWidget) void;
pub extern fn gtk_box_remove(box: GtkWidget, child: GtkWidget) void;
pub extern fn gtk_box_set_spacing(box: GtkWidget, spacing: c_int) void;

pub extern fn gtk_button_new() GtkWidget;
pub extern fn gtk_button_new_with_label(label: [*:0]const u8) GtkWidget;
pub extern fn gtk_button_set_child(button: GtkWidget, child: GtkWidget) void;

pub extern fn gtk_label_new(str: [*:0]const u8) GtkWidget;
pub extern fn gtk_separator_new(orientation: GtkOrientation) GtkWidget;

pub extern fn gtk_image_new() GtkWidget;
pub extern fn gtk_image_new_from_file(filename: [*:0]const u8) GtkWidget;
pub extern fn gtk_image_new_from_paintable(paintable: ?*anyopaque) GtkWidget;
pub extern fn gtk_image_set_pixel_size(image: GtkWidget, size: c_int) void;

pub extern fn gtk_icon_theme_get_for_display(display: ?*anyopaque) ?*anyopaque;
// GTK 4.22 signature: (theme, icon_name, fallbacks[], size, scale,
// direction, flags) — fallbacks and direction are required args.
pub extern fn gtk_icon_theme_lookup_icon(theme: ?*anyopaque, icon_name: [*:0]const u8, fallbacks: ?[*]const ?[*:0]const u8, size: c_int, scale: c_int, direction: c_int, flags: c_uint) ?*anyopaque;

pub extern fn gtk_event_controller_motion_new() ?*anyopaque;
pub extern fn gtk_gesture_click_new() ?*anyopaque;
pub extern fn gtk_gesture_single_set_button(gesture: ?*anyopaque, button: c_uint) void;
pub extern fn gtk_gesture_single_set_exclusive(gesture: ?*anyopaque, exclusive: c_int) void;
pub extern fn gtk_gesture_single_get_current_button(gesture: ?*anyopaque) c_uint;

pub extern fn gtk_popover_new() GtkWidget;
pub extern fn gtk_popover_set_child(popover: GtkWidget, child: GtkWidget) void;
pub extern fn gtk_popover_set_position(popover: GtkWidget, position: GtkPositionType) void;
pub extern fn gtk_popover_popup(popover: GtkWidget) void;
pub extern fn gtk_popover_popdown(popover: GtkWidget) void;

// ---------------------------------------------------------------------------
// dockh-config GUI: GtkNotebook (tabs), form controls (switch / spin button /
// entry / drop-down), header bar, scrolled window, grid — a regular window,
// not a layer shell (it edits config.toml and the dock hot-reloads it).
// ---------------------------------------------------------------------------

pub extern fn gtk_notebook_new() GtkWidget;
pub extern fn gtk_notebook_append_page(notebook: GtkWidget, child: GtkWidget, tab_label: GtkWidget) c_int;
pub extern fn gtk_notebook_set_tab_pos(notebook: GtkWidget, position: GtkPositionType) void;
pub extern fn gtk_notebook_set_scrollable(notebook: GtkWidget, scrollable: c_int) void;

pub extern fn gtk_switch_new() GtkWidget;
pub extern fn gtk_switch_set_active(sw: GtkWidget, active: c_int) void;
pub extern fn gtk_switch_get_active(sw: GtkWidget) c_int;

pub extern fn gtk_spin_button_new_with_range(min: f64, max: f64, step: f64) GtkWidget;
pub extern fn gtk_spin_button_set_value(spin: GtkWidget, value: f64) void;
pub extern fn gtk_spin_button_get_value(spin: GtkWidget) f64;
pub extern fn gtk_spin_button_set_digits(spin: GtkWidget, digits: c_uint) void;
pub extern fn gtk_spin_button_set_increments(spin: GtkWidget, step: f64, page: f64) void;
pub extern fn gtk_spin_button_set_numeric(spin: GtkWidget, numeric: c_int) void;

pub extern fn gtk_entry_new() GtkWidget;
pub extern fn gtk_editable_set_text(editable: ?*anyopaque, text: [*:0]const u8) void;
pub extern fn gtk_editable_get_text(editable: ?*anyopaque) ?[*:0]const u8;

// GtkDropDown + GtkStringList: the GTK4 replacement for GtkComboBoxText.
pub extern fn gtk_drop_down_new_from_strings(strings: [*:null]const ?[*:0]const u8) GtkWidget;
pub extern fn gtk_drop_down_set_selected(drop: GtkWidget, position: c_uint) void;
pub extern fn gtk_drop_down_get_selected(drop: GtkWidget) c_uint;

pub extern fn gtk_header_bar_new() GtkWidget;
pub extern fn gtk_header_bar_pack_end(bar: GtkWidget, child: GtkWidget) void;
// GTK4 header bars have no set_title/set_subtitle — the title area is a
// plain widget (dockh-config stacks a title + path label in a GtkBox).
pub extern fn gtk_header_bar_set_title_widget(bar: GtkWidget, child: GtkWidget) void;
pub extern fn gtk_window_set_titlebar(window: GtkWidget, titlebar: GtkWidget) void;
pub extern fn gtk_window_set_resizable(window: GtkWidget, resizable: c_int) void;

// GtkPolicyType (gtkenums.h): AUTOMATIC=0 ALWAYS=1 NEVER=2
pub const POLICY_AUTOMATIC: c_int = 0;
pub const POLICY_ALWAYS: c_int = 1;
pub const POLICY_NEVER: c_int = 2;
pub extern fn gtk_scrolled_window_new() GtkWidget;
pub extern fn gtk_scrolled_window_set_child(scrolled: GtkWidget, child: GtkWidget) void;
pub extern fn gtk_scrolled_window_set_policy(scrolled: GtkWidget, hscrollbar: c_int, vscrollbar: c_int) void;

pub extern fn gtk_grid_new() GtkWidget;
pub extern fn gtk_grid_attach(grid: GtkWidget, child: GtkWidget, column: c_int, row: c_int, width: c_int, height: c_int) void;
pub extern fn gtk_grid_set_row_spacing(grid: GtkWidget, spacing: c_int) void;
pub extern fn gtk_grid_set_column_spacing(grid: GtkWidget, spacing: c_int) void;

pub extern fn gtk_widget_set_margin_start(widget: GtkWidget, margin: c_int) void;
pub extern fn gtk_widget_set_margin_end(widget: GtkWidget, margin: c_int) void;
pub extern fn gtk_widget_set_margin_top(widget: GtkWidget, margin: c_int) void;
pub extern fn gtk_widget_set_margin_bottom(widget: GtkWidget, margin: c_int) void;

pub extern fn gtk_label_set_xalign(label: GtkWidget, xalign: f32) void;

// libc: execv — the dock hot-reloads config.toml by re-executing itself with
// the same argv (position/layer/margins/glass need a fresh window, so a full
// in-place restart is the reliable way to apply them).
pub extern fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

/// GTK4 replaced gtk_popover_set_parent() with gtk_widget_set_parent().
pub extern fn gtk_widget_set_parent(widget: GtkWidget, parent: GtkWidget) void;
pub extern fn gtk_widget_unparent(widget: GtkWidget) void;

pub extern fn gtk_css_provider_new() ?*anyopaque;
// GTK 4.22: load_from_path no longer takes a GError** (2 args, void). Parse
// problems are reported via the GtkCssProvider::parsing-error signal instead.
pub extern fn gtk_css_provider_load_from_path(provider: ?*anyopaque, path: [*:0]const u8) void;
// GTK 4.12+ replaced load_from_data with load_from_string (no GError).
pub extern fn gtk_css_provider_load_from_string(provider: ?*anyopaque, string: [*:0]const u8) void;

// GError — read the message of a parsing-error signal.
pub const GError = extern struct {
    domain: u32 = 0, // GQuark
    code: c_int = 0, // gint
    message: [*:0]const u8 = undefined,
};
pub extern fn gtk_style_context_add_provider_for_display(display: ?*anyopaque, provider: ?*anyopaque, priority: c_uint) void;
pub extern fn gtk_style_context_remove_provider_for_display(display: ?*anyopaque, provider: ?*anyopaque, priority: c_uint) void;

// ---------------------------------------------------------------------------
// GSK scene graph: in-dock blur injected into the window's own render tree
// (GskGLShaderNode via gtk_snapshot_push_gl_shader on GTK < 4.16, GskBlurNode
// via gtk_snapshot_push_blur on 4.16+). No offscreen renderer is created, so
// the effect costs zero extra memory (offscreen render_texture measured at
// +61 MB RSS).
// ---------------------------------------------------------------------------

// graphene_rect_t — plain 4-float layout (x, y, width, height).
pub const GrapheneRect = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
};

// GskGLShader: GLSL fragment shader executed by the classic GL renderer.
// Deprecated since 4.16: the ngl renderer ignores GL shader nodes, so dockh
// only uses this path on GTK < 4.16 and falls back to GskBlurNode otherwise.
pub extern fn gsk_gl_shader_new_from_bytes(source: ?*anyopaque) ?*anyopaque;

// Snapshot helpers used by the DockhGlow widget snapshot vfunc.
pub extern fn gtk_snapshot_push_blur(snapshot: ?*anyopaque, radius: f64) void;
pub extern fn gtk_snapshot_push_gl_shader(snapshot: ?*anyopaque, shader: ?*anyopaque, bounds: *const GrapheneRect, take_args: ?*anyopaque) void;
pub extern fn gtk_snapshot_pop(snapshot: ?*anyopaque) void;

// Draw a paintable into a snapshot at a given size (used to draw the icon
// inside the pushed blur region).
pub extern fn gdk_paintable_snapshot(paintable: ?*anyopaque, snapshot: ?*anyopaque, width: f64, height: f64) void;

// GBytes: GLSL shader source + uniform args (transferred to push_gl_shader).
pub extern fn g_bytes_new(data: *const anyopaque, size: usize) ?*anyopaque;
pub extern fn g_bytes_new_static(data: *const anyopaque, size: usize) ?*anyopaque;
pub extern fn g_bytes_unref(bytes: ?*anyopaque) void;

// GtkOverlay: stack the blurred glow behind the crisp icon.
pub extern fn gtk_overlay_new() GtkWidget;
pub extern fn gtk_overlay_set_child(overlay: GtkWidget, child: GtkWidget) void;
pub extern fn gtk_overlay_add_overlay(overlay: GtkWidget, widget: GtkWidget) void;
pub extern fn gtk_overlay_remove_overlay(overlay: GtkWidget, widget: GtkWidget) void;

pub extern fn gtk_widget_get_parent(widget: GtkWidget) GtkWidget;

pub extern fn gtk_image_get_paintable(image: GtkWidget) ?*anyopaque;
pub extern fn gtk_get_minor_version() c_uint;

// Sizing inside the glow snapshot vfunc.
pub extern fn gtk_widget_get_width(widget: GtkWidget) c_int;
pub extern fn gtk_widget_get_height(widget: GtkWidget) c_int;

// GtkDrawingArea + Cairo: the live glass preview inside dockh-config. The
// preview approximates the GLSL shader's optical model with plain Cairo so
// every knob (refraction, dispersion, splay, frost, depth, light angle,
// alpha, radius, margin) is visible in real time without a GL context.
pub extern fn gtk_drawing_area_new() GtkWidget;
pub extern fn gtk_drawing_area_set_draw_func(area: GtkWidget, draw_func: ?*const anyopaque, user_data: ?*anyopaque, destroy: ?*const anyopaque) void;
pub extern fn gtk_drawing_area_set_content_width(area: GtkWidget, width: c_int) void;
pub extern fn gtk_drawing_area_set_content_height(area: GtkWidget, height: c_int) void;

pub const Cairo = ?*anyopaque;
pub extern fn cairo_save(cr: Cairo) void;
pub extern fn cairo_restore(cr: Cairo) void;
pub extern fn cairo_new_path(cr: Cairo) void;
pub extern fn cairo_move_to(cr: Cairo, x: f64, y: f64) void;
pub extern fn cairo_line_to(cr: Cairo, x: f64, y: f64) void;
pub extern fn cairo_close_path(cr: Cairo) void;
pub extern fn cairo_arc(cr: Cairo, xc: f64, yc: f64, radius: f64, angle1: f64, angle2: f64) void;
pub extern fn cairo_rectangle(cr: Cairo, x: f64, y: f64, w: f64, h: f64) void;
pub extern fn cairo_fill(cr: Cairo) void;
pub extern fn cairo_fill_preserve(cr: Cairo) void;
pub extern fn cairo_stroke(cr: Cairo) void;
pub extern fn cairo_stroke_preserve(cr: Cairo) void;
pub extern fn cairo_paint(cr: Cairo) void;
pub extern fn cairo_clip(cr: Cairo) void;
pub extern fn cairo_set_source_rgba(cr: Cairo, r: f64, g: f64, b: f64, a: f64) void;
pub extern fn cairo_set_source(cr: Cairo, pattern: ?*anyopaque) void;
pub extern fn cairo_set_line_width(cr: Cairo, width: f64) void;
pub extern fn cairo_scale(cr: Cairo, sx: f64, sy: f64) void;
pub extern fn cairo_translate(cr: Cairo, tx: f64, ty: f64) void;
pub extern fn cairo_pattern_create_linear(x0: f64, y0: f64, x1: f64, y1: f64) ?*anyopaque;
pub extern fn cairo_pattern_create_radial(cx0: f64, cy0: f64, r0: f64, cx1: f64, cy1: f64, r1: f64) ?*anyopaque;
pub extern fn cairo_pattern_add_color_stop_rgba(pattern: ?*anyopaque, offset: f64, r: f64, g: f64, b: f64, a: f64) void;
pub extern fn cairo_pattern_destroy(pattern: ?*anyopaque) void;

// Geometry: convert a point from one widget's coordinate space to another's
// (both must share a toplevel). Used by the macOS magnify effect to place
// each dock item in the pointer's (window) coordinate space.
pub extern fn gtk_widget_translate_coordinates(widget: GtkWidget, dest_widget: GtkWidget, src_x: f64, src_y: f64, dest_x: *f64, dest_y: *f64) c_int;

// ---------------------------------------------------------------------------
// Frame clock: coalescing the macOS magnify bucket updates to ONE pass per
// compositor frame. widgets.zig swaps `.dockh-mag-N` CSS classes (whose scale
// rules theme.zig injects); the short CSS transition interpolates between
// buckets, and updating only once per frame (instead of on every raw motion
// event) is what keeps the animation fluid — no transition restarts.
//
// Note: GTK4 has NO gtk_widget_set_transform, and gtk_widget_allocate's
// transform is only honored on top-level widgets (children of a GtkBox wipe
// it on relayout — verified empirically: 177 pushes, zero visible change),
// so CSS buckets are the only approach that actually renders for dock items.
// ---------------------------------------------------------------------------

// GtkTickCallback: gboolean (*)(GtkWidget*, GdkFrameClock*, gpointer); return
// G_SOURCE_CONTINUE to keep animating, G_SOURCE_REMOVE to stop. Returns a
// source id (guint).
pub extern fn gtk_widget_add_tick_callback(widget: GtkWidget, callback: ?*const anyopaque, user_data: ?*anyopaque, notify: ?*const anyopaque) c_uint;

// Remove a tick callback previously added with gtk_widget_add_tick_callback.
pub extern fn gtk_widget_remove_tick_callback(widget: GtkWidget, id: c_uint) void;

// Frame clock time in microseconds (gint64) — gives a real dt for the per-
// frame magnify easing (rate-independent at any refresh rate).
pub extern fn gdk_frame_clock_get_frame_time(frame_clock: ?*anyopaque) i64;

// ---------------------------------------------------------------------------
// GtkProgressBar (macOS-style progress under the icon) + GtkLabel text.
// ---------------------------------------------------------------------------

pub extern fn gtk_progress_bar_new() GtkWidget;
pub extern fn gtk_progress_bar_set_fraction(pbar: GtkWidget, fraction: f64) void;
pub extern fn gtk_progress_bar_set_show_text(pbar: GtkWidget, show_text: c_int) void;

pub extern fn gtk_label_set_text(label: GtkWidget, str: [*:0]const u8) void;

// ---------------------------------------------------------------------------
// GSubprocess: safe polling of playerctl / makoctl from the GLib main loop.
// GLib spawns with posix_spawn (no fork() in a multithreaded GTK process).
// ---------------------------------------------------------------------------

// G_SPAWN_SEARCH_PATH = 1 << 2 (glib gspawn.h)
pub const G_SPAWN_SEARCH_PATH: c_int = 4;

pub extern fn g_subprocess_launcher_new(flags: c_int) ?*anyopaque;
// glib 2.88 made g_subprocess_launcher_spawn variadic (self, error, argv0, ...);
// the array form spawnv is the stable ABI we bind instead.
pub extern fn g_subprocess_launcher_spawnv(launcher: ?*anyopaque, argv: [*]const ?[*:0]const u8, err_out: ?*?*anyopaque) ?*anyopaque;
// glib 2.88 ALSO replaced the `int *exit_status` out-param of
// g_subprocess_communicate_utf8 with `GError **error` (breaking change — the
// exit status now comes from g_subprocess_get_exit_status after the call).
// Passing `&exit_status` (int*) here would make glib write an 8-byte GError*
// into 4 bytes of stack — heap corruption that surfaced as
// `g_object_unref: assertion 'G_IS_OBJECT (object)' failed` during the
// 2-second makoctl/playerctl polls. Bind the real glib 2.88 signature.
pub extern fn g_subprocess_communicate_utf8(subprocess: ?*anyopaque, stdin_buf: ?[*:0]const u8, cancellable: ?*anyopaque, stdout_out: ?*?[*:0]const u8, stderr_out: ?*?[*:0]const u8, err_out: ?*?*anyopaque) c_int;
pub extern fn g_free(ptr: ?*anyopaque) void;

// ---------------------------------------------------------------------------
// GObject / GType: registering the custom DockhGlow widget class
// ---------------------------------------------------------------------------

pub const GTypeQuery = extern struct {
    type: usize = 0,
    type_name: ?[*:0]const u8 = null,
    class_size: u32 = 0,
    instance_size: u32 = 0,
};

// struct _GTypeInfo (gtype.h) — guint16 class/instance sizes + callbacks.
pub const GTypeInfo = extern struct {
    class_size: u16 = 0,
    base_init: ?*const anyopaque = null,
    base_finalize: ?*const anyopaque = null,
    class_init: ?*const anyopaque = null,
    class_finalize: ?*const anyopaque = null,
    class_data: ?*const anyopaque = null,
    instance_size: u16 = 0,
    n_preallocs: u16 = 0,
    instance_init: ?*const anyopaque = null,
    value_table: ?*const anyopaque = null,
};

pub extern fn g_type_query(type_: usize, query: *GTypeQuery) void;
// glib 2.88 changed g_type_register_static_simple to a flat signature
// (parent, name, class_size, class_init, instance_size, instance_init, flags)
// — no GTypeInfo* struct. Verified against the installed header.
pub extern fn g_type_register_static_simple(parent_type: usize, type_name: [*:0]const u8, class_size: u32, class_init: ?*const anyopaque, instance_size: u32, instance_init: ?*const anyopaque, flags: c_uint) usize;

// g_object_new is variadic; we only ever call it with a NULL property list.
pub extern fn g_object_new(object_type: usize, first_property_name: ?[*:0]const u8) ?*anyopaque;
pub extern fn g_object_set_data_full(object: ?*anyopaque, key: [*:0]const u8, data: ?*anyopaque, destroy: ?*const anyopaque) void;
pub extern fn g_object_get_data(object: ?*anyopaque, key: [*:0]const u8) ?*anyopaque;

pub extern fn gtk_widget_get_type() usize;

// GIO: file monitoring for CSS hot reload (GFileMonitor follows the path, so
// editors that save via rename still trigger events).
pub const G_FILE_MONITOR_WATCH_MOVES: c_int = 1;

// GFileMonitorEvent (gioenums.h)
pub const G_FILE_MONITOR_EVENT_CHANGED: c_int = 0;
pub const G_FILE_MONITOR_EVENT_CHANGES_DONE_HINT: c_int = 1;
pub const G_FILE_MONITOR_EVENT_DELETED: c_int = 2;
pub const G_FILE_MONITOR_EVENT_CREATED: c_int = 3;
pub const G_FILE_MONITOR_EVENT_ATTRIBUTE_CHANGED: c_int = 4;
pub const G_FILE_MONITOR_EVENT_MOVED: c_int = 7;
pub const G_FILE_MONITOR_EVENT_RENAMED: c_int = 8;
pub const G_FILE_MONITOR_EVENT_MOVED_IN: c_int = 9;
pub const G_FILE_MONITOR_EVENT_MOVED_OUT: c_int = 10;

pub extern fn g_file_new_for_path(path: [*:0]const u8) ?*anyopaque;
pub extern fn g_file_monitor_file(file: ?*anyopaque, flags: c_int, cancellable: ?*anyopaque, err_out: ?*?*anyopaque) ?*anyopaque;
pub extern fn g_file_monitor_cancel(monitor: ?*anyopaque) c_int;

pub extern fn gdk_display_get_default() ?*anyopaque;
pub extern fn gdk_display_get_monitors(display: ?*anyopaque) ?*anyopaque;
pub extern fn gdk_monitor_get_connector(monitor: GdkMonitor) ?[*:0]const u8;
pub extern fn gdk_monitor_get_geometry(monitor: GdkMonitor, geometry: *GdkRect) void;

pub extern fn g_list_model_get_n_items(model: ?*anyopaque) c_uint;
pub extern fn g_list_model_get_item(model: ?*anyopaque, position: c_uint) ?*anyopaque;

// g_signal_connect is a macro in the C headers; the exported symbol is
// g_signal_connect_data. Keep the friendly name as a Zig wrapper so all
// call sites stay unchanged.
pub extern fn g_signal_connect_data(instance: ?*anyopaque, detailed_signal: [*:0]const u8, c_handler: ?*const anyopaque, data: ?*anyopaque, destroy_data: ?*const anyopaque, connect_flags: c_int) c_ulong;
pub fn g_signal_connect(instance: ?*anyopaque, detailed_signal: [*:0]const u8, c_handler: ?*const anyopaque, data: ?*anyopaque) c_ulong {
    return g_signal_connect_data(instance, detailed_signal, c_handler, data, null, 0);
}
pub extern fn g_object_ref(object: ?*anyopaque) ?*anyopaque;
pub extern fn g_object_unref(object: ?*anyopaque) void;
pub extern fn g_error_free(err_obj: ?*anyopaque) void;
pub extern fn gtk_widget_set_opacity(widget: ?*anyopaque, opacity: f64) void;
pub extern fn g_timeout_add(interval: c_uint, function: ?*const anyopaque, data: ?*anyopaque) c_uint;
pub extern fn g_source_remove(source_id: c_uint) c_int;
pub extern fn g_unix_fd_add(fd: c_int, condition: c_int, function: ?*const anyopaque, user_data: ?*anyopaque) c_uint;

// ---------------------------------------------------------------------------
// gtk4-layer-shell (wmww)
// ---------------------------------------------------------------------------

pub const GtkLayerShellLayer = c_int; // BACKGROUND=0 BOTTOM=1 TOP=2 OVERLAY=3
pub const LAYER_OVERLAY: c_int = 3;
pub const LAYER_TOP: c_int = 2;
pub const LAYER_BOTTOM: c_int = 1;

pub const GtkLayerShellEdge = c_int; // LEFT=0 RIGHT=1 TOP=2 BOTTOM=3
pub const EDGE_LEFT: c_int = 0;
pub const EDGE_RIGHT: c_int = 1;
pub const EDGE_TOP: c_int = 2;
pub const EDGE_BOTTOM: c_int = 3;

pub extern fn gtk_layer_init_for_window(window: GtkWidget) void;
pub extern fn gtk_layer_set_namespace(window: GtkWidget, name_space: [*:0]const u8) void;
pub extern fn gtk_layer_set_monitor(window: GtkWidget, monitor: GdkMonitor) void;
pub extern fn gtk_layer_set_anchor(window: GtkWidget, edge: GtkLayerShellEdge, anchor_to_edge: c_int) void;
pub extern fn gtk_layer_set_layer(window: GtkWidget, layer: GtkLayerShellLayer) void;
pub extern fn gtk_layer_set_margin(window: GtkWidget, edge: GtkLayerShellEdge, margin_size: c_int) void;
pub extern fn gtk_layer_set_exclusive_zone(window: GtkWidget, exclusive_zone: c_int) void;
pub extern fn gtk_layer_auto_exclusive_zone_enable(window: GtkWidget) void;

// ---------------------------------------------------------------------------
// libc: sockets, signals, files, process
// ---------------------------------------------------------------------------

pub const SockaddrUn = extern struct {
    family: u16 = 0,
    path: [108]u8 = [_]u8{0} ** 108,
};

pub const Timespec = extern struct {
    sec: i64 = 0,
    nsec: i64 = 0,
};

pub const Timeval = extern struct {
    sec: i64 = 0,
    usec: i64 = 0,
};

/// glibc x86_64 layout: handler (union) + sigset_t (128B) + flags + restorer.
pub const Sigaction = extern struct {
    handler: ?*const fn (c_int) callconv(.c) void,
    mask: [128]u8 = [_]u8{0} ** 128,
    flags: c_int = 0,
    restorer: ?*const fn () callconv(.c) void = null,
};

/// glibc x86_64 struct dirent64.
pub const Dirent = extern struct {
    ino: u64 = 0,
    off: i64 = 0,
    reclen: u16 = 0,
    dtype: u8 = 0,
    name: [256]u8 = [_]u8{0} ** 256,
};

/// glibc x86_64 struct stat (bits/stat.h) — enough fields for st_mtim, which
/// the .desktop cache uses to detect hot-installed/upgraded apps (pacman -S
/// writes a fresh mtime; dockh re-resolves the entry when it changes).
pub const Stat = extern struct {
    st_dev: u64 = 0,
    st_ino: u64 = 0,
    st_nlink: u64 = 0,
    st_mode: u32 = 0,
    st_uid: u32 = 0,
    st_gid: u32 = 0,
    __pad0: u32 = 0,
    st_rdev: u64 = 0,
    st_size: i64 = 0,
    st_blksize: i64 = 0,
    st_blocks: i64 = 0,
    st_atim: Timespec = .{},
    st_mtim: Timespec = .{},
    st_ctim: Timespec = .{},
    __glibc_reserved: [3]i64 = .{ 0, 0, 0 },
};

pub extern fn stat(pathname: [*:0]const u8, statbuf: *Stat) c_int;

pub const AF_UNIX: c_int = 1;
pub const SOCK_STREAM: c_int = 1;
pub const SOCK_CLOEXEC: c_int = 0o2000000;
pub const MSG_NOSIGNAL: c_int = 0x4000;
pub const SOL_SOCKET: c_int = 1;
pub const SO_RCVTIMEO: c_int = 20;
pub const F_GETFL: c_int = 3;
pub const F_SETFL: c_int = 4;
pub const O_NONBLOCK: c_int = 0x800;
pub const O_RDONLY: c_int = 0;
pub const O_CREAT: c_int = 0x40;
pub const O_RDWR: c_int = 2;
pub const O_CLOEXEC: c_int = 0x80000;
pub const LOCK_EX: c_int = 2;
pub const LOCK_NB: c_int = 4;
pub const SEEK_SET: c_int = 0;
pub const SEEK_END: c_int = 2;
pub const F_OK: c_int = 0;
pub const CLOCK_MONOTONIC: c_int = 1;
pub const SIGTERM: c_int = 15;
pub const EEXIST: c_int = 17;
pub const ENOTDIR: c_int = 20;
pub const EAGAIN: c_int = 11;
pub const EINTR: c_int = 4;
pub const ENOENT: c_int = 2;
pub const ECONNREFUSED: c_int = 111;
pub const DT_REG: u8 = 8;
pub const DT_UNKNOWN: u8 = 0;

// GIOCondition (glib) — low bits of the condition enum
pub const G_IO_IN: c_int = 1;
pub const G_IO_OUT: c_int = 4;
pub const G_IO_PRI: c_int = 2;
pub const G_IO_ERR: c_int = 8;
pub const G_IO_HUP: c_int = 16;
pub const G_IO_NVAL: c_int = 32;

pub extern fn socket(domain: c_int, type_: c_int, protocol: c_int) c_int;
pub extern fn connect(fd: c_int, addr: ?*const anyopaque, len: c_uint) c_int;
pub extern fn send(fd: c_int, buf: [*]const u8, len: usize, flags: c_int) isize;
pub extern fn recv(fd: c_int, buf: [*]u8, len: usize, flags: c_int) isize;
pub extern fn close(fd: c_int) c_int;
pub extern fn setsockopt(fd: c_int, level: c_int, optname: c_int, opt: ?*const anyopaque, optlen: c_uint) c_int;
pub extern fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
pub extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
pub extern fn flock(fd: c_int, operation: c_int) c_int;
pub extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
pub extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
pub extern fn lseek(fd: c_int, offset: i64, whence: c_int) i64;
pub extern fn ftruncate(fd: c_int, length: i64) c_int;
pub extern fn pipe(fds: [*]c_int) c_int;
pub extern fn readlink(path: [*:0]const u8, buf: [*]u8, bufsiz: usize) isize;
pub extern fn sigaction(sig: c_int, act: ?*const Sigaction, oact: ?*Sigaction) c_int;
pub extern fn sigemptyset(set: *[128]u8) c_int;
pub extern fn kill(pid: c_int, sig: c_int) c_int;
pub extern fn getpid() c_int;
pub extern fn getuid() c_uint;
pub extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
pub extern fn clock_gettime(clock_id: c_int, tp: *Timespec) c_int;
pub extern fn time(tloc: ?*i64) i64;
pub extern fn posix_spawnp(pid: *c_int, file: [*:0]const u8, file_actions: ?*const anyopaque, attrp: ?*const anyopaque, argv: [*]const ?[*:0]u8, envp: [*]const ?[*:0]u8) c_int;
pub extern fn strerror(errnum: c_int) [*:0]const u8;
pub extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
pub extern fn fclose(stream: ?*anyopaque) c_int;
pub extern fn fseek(stream: ?*anyopaque, offset: c_long, whence: c_int) c_int;
pub extern fn ftell(stream: ?*anyopaque) c_long;
pub extern fn fread(ptr: [*]u8, size: usize, count: usize, stream: ?*anyopaque) usize;
pub extern fn fwrite(ptr: [*]const u8, size: usize, count: usize, stream: ?*anyopaque) usize;
pub extern fn access(path: [*:0]const u8, mode: c_int) c_int;
pub extern fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
pub extern fn opendir(path: [*:0]const u8) ?*anyopaque;
pub extern fn closedir(dirp: ?*anyopaque) c_int;
pub extern fn readdir(dirp: ?*anyopaque) ?*Dirent;
pub extern fn __libc_current_sigrtmin() c_int;
pub extern fn __errno_location() *c_int;

// glibc: release freed heap pages back to the OS (GTK4 frees a lot of
// transient memory; without this the RSS stays high after rebuilds).
pub extern fn malloc_trim(pad: usize) c_int;

pub extern "c" var environ: [*:null]?[*:0]u8;

pub fn errnoValue() c_int {
    return __errno_location().*;
}
