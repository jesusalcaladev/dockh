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
pub extern fn gtk_widget_set_tooltip_text(widget: GtkWidget, text: [*:0]const u8) void;
pub extern fn gtk_widget_set_size_request(widget: GtkWidget, width: c_int, height: c_int) void;
pub extern fn gtk_widget_add_controller(widget: GtkWidget, controller: ?*anyopaque) void;
pub extern fn gtk_widget_get_first_child(widget: GtkWidget) GtkWidget;
pub extern fn gtk_widget_get_next_sibling(widget: GtkWidget) GtkWidget;
pub extern fn gtk_widget_set_hexpand(widget: GtkWidget, expand: c_int) void;
pub extern fn gtk_widget_set_vexpand(widget: GtkWidget, expand: c_int) void;
pub extern fn gtk_widget_set_halign(widget: GtkWidget, alignment: GtkAlign) void;
pub extern fn gtk_widget_set_valign(widget: GtkWidget, alignment: GtkAlign) void;

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

pub extern fn gtk_image_get_paintable(image: GtkWidget) ?*anyopaque;
pub extern fn gtk_get_minor_version() c_uint;

// Sizing inside the glow snapshot vfunc.
pub extern fn gtk_widget_get_width(widget: GtkWidget) c_int;
pub extern fn gtk_widget_get_height(widget: GtkWidget) c_int;

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
pub extern fn g_subprocess_communicate_utf8(subprocess: ?*anyopaque, stdin_buf: ?[*:0]const u8, cancellable: ?*anyopaque, stdout_out: ?*?[*:0]const u8, stderr_out: ?*?[*:0]const u8, exit_status: ?*c_int) c_int;
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

pub const AF_UNIX: c_int = 1;
pub const SOCK_STREAM: c_int = 1;
pub const SOCK_CLOEXEC: c_int = 0o2000000;
pub const MSG_NOSIGNAL: c_int = 0x4000;
pub const SOL_SOCKET: c_int = 1;
pub const SO_RCVTIMEO: c_int = 20;
pub const F_GETFL: c_int = 3;
pub const F_SETFL: c_int = 4;
pub const O_NONBLOCK: c_int = 0x800;
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
