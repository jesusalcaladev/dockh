//! Hyprland IPC, the direct way:
//!  - `.socket.sock`  : hyprctl request/reply socket (blocking, local, µs)
//!  - `.socket2.sock` : event socket, consumed event-driven through the
//!                      GLib main loop via g_unix_fd_add — no polling.
const std = @import("std");
const c = @import("../c.zig");

pub const Workspace = struct {
    id: i32 = 0,
    name: []const u8 = "",
    monitor: []const u8 = "",
    windows: i32 = 0,
};

pub const Client = struct {
    address: []const u8 = "",
    mapped: bool = true,
    hidden: bool = false,
    workspace: Workspace = .{},
    floating: bool = false,
    class: []const u8 = "",
    title: []const u8 = "",
    initial_class: []const u8 = "",
    pid: i32 = 0,
    pinned: bool = false,
};

pub const Monitor = struct {
    id: i32 = 0,
    name: []const u8 = "",
    model: []const u8 = "",
    width: i32 = 0,
    height: i32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    scale: f64 = 1,
    focused: bool = false,
};

pub const Context = struct {
    hypr_dir: []const u8 = "", // $XDG_RUNTIME_DIR/hypr or /tmp/hypr
    his: []const u8 = "", // $HYPRLAND_INSTANCE_SIGNATURE
};

fn socketPath(ctx: *const Context, socket_name: []const u8, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ ctx.hypr_dir, ctx.his, socket_name });
}

fn unixConnect(ctx: *const Context, socket_name: []const u8) !c_int {
    var path_buf: [128]u8 = undefined;
    const path = try socketPath(ctx, socket_name, &path_buf);

    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    if (fd < 0) return error.SocketCreateFailed;

    var addr: c.SockaddrUn = .{};
    addr.family = @intCast(c.AF_UNIX);
    if (path.len >= addr.path.len) {
        _ = c.close(fd);
        return error.PathTooLong;
    }
    @memcpy(addr.path[0..path.len], path);

    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.SockaddrUn)) != 0) {
        const err = c.errnoValue();
        _ = c.close(fd);
        return switch (err) {
            c.ENOENT => error.HyprlandSocketMissing,
            c.ECONNREFUSED => error.HyprlandSocketRefused,
            else => error.ConnectFailed,
        };
    }
    return fd;
}

/// Send a hyprctl command and return the full reply. The caller owns the
/// returned slice (allocated with `alloc`).
pub fn hyprctl(alloc: std.mem.Allocator, ctx: *const Context, cmd: []const u8) ![]u8 {
    const fd = try unixConnect(ctx, ".socket.sock");
    defer _ = c.close(fd);

    // Don't hang forever if Hyprland misbehaves.
    var tv: c.Timeval = .{ .sec = 3, .usec = 0 };
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_RCVTIMEO, @ptrCast(&tv), @sizeOf(c.Timeval));

    var sent: usize = 0;
    while (sent < cmd.len) {
        const n = c.send(fd, cmd.ptr + sent, cmd.len - sent, c.MSG_NOSIGNAL);
        if (n < 0) {
            if (c.errnoValue() == c.EINTR) continue;
            return error.SendFailed;
        }
        sent += @intCast(n);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.recv(fd, &buf, buf.len, 0);
        if (n < 0) {
            const err = c.errnoValue();
            if (err == c.EINTR) continue;
            if (err == c.EAGAIN) break; // timeout: got what we got
            break;
        }
        if (n == 0) break; // server closed: reply complete
        out.appendSlice(alloc, buf[0..@intCast(n)]) catch break;
    }
    return out.toOwnedSlice(alloc) catch &.{};
}

pub fn listClients(alloc: std.mem.Allocator, ctx: *const Context) ![]Client {
    const reply = try hyprctl(alloc, ctx, "j/clients");
    defer alloc.free(reply);
    // Leaky parse: strings live in `alloc` (the caller's scratch arena, reset
    // per refresh) — no deinit, so the returned slices stay valid.
    // `.allocate = .alloc_always` is REQUIRED: with the default alloc_if_needed
    // the strings reference `reply`, which is freed right after — dangling.
    return std.json.parseFromSliceLeaky([]Client, alloc, reply, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

pub fn listMonitors(alloc: std.mem.Allocator, ctx: *const Context) ![]Monitor {
    const reply = try hyprctl(alloc, ctx, "j/monitors");
    defer alloc.free(reply);
    return std.json.parseFromSliceLeaky([]Monitor, alloc, reply, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

pub fn activeWindow(alloc: std.mem.Allocator, ctx: *const Context) !Client {
    const reply = try hyprctl(alloc, ctx, "j/activewindow");
    defer alloc.free(reply);
    const trimmed = std.mem.trim(u8, reply, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "null")) return .{};
    return std.json.parseFromSliceLeaky(Client, alloc, reply, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

/// Try the modern Lua dispatcher first, fall back to the legacy syntax.
pub fn dispatch(ctx: *const Context, alloc: std.mem.Allocator, lua_cmd: []const u8, legacy_cmd: []const u8) void {
    const reply = hyprctl(alloc, ctx, lua_cmd) catch return;
    defer alloc.free(reply);
    if (std.mem.indexOf(u8, reply, "Invalid dispatcher") != null) {
        const r2 = hyprctl(alloc, ctx, legacy_cmd) catch return;
        alloc.free(r2);
    }
}

pub fn focusWindow(ctx: *const Context, alloc: std.mem.Allocator, address: []const u8) void {
    const lua = std.fmt.allocPrint(alloc, "dispatch hl.dsp.focus({{ window = 'address:{s}' }})", .{address}) catch return;
    defer alloc.free(lua);
    const legacy = std.fmt.allocPrint(alloc, "dispatch focuswindow address:{s}", .{address}) catch return;
    defer alloc.free(legacy);
    dispatch(ctx, alloc, lua, legacy);
}

pub fn closeWindow(ctx: *const Context, alloc: std.mem.Allocator, address: []const u8) void {
    const lua = std.fmt.allocPrint(alloc, "dispatch hl.dsp.window.close({{ window = 'address:{s}' }})", .{address}) catch return;
    defer alloc.free(lua);
    const legacy = std.fmt.allocPrint(alloc, "dispatch closewindow address:{s}", .{address}) catch return;
    defer alloc.free(legacy);
    dispatch(ctx, alloc, lua, legacy);
}

pub fn toggleFloating(ctx: *const Context, alloc: std.mem.Allocator, address: []const u8) void {
    const lua = std.fmt.allocPrint(alloc, "dispatch hl.dsp.window.float({{ window = 'address:{s}', action = 'toggle' }})", .{address}) catch return;
    defer alloc.free(lua);
    const legacy = std.fmt.allocPrint(alloc, "dispatch togglefloating address:{s}", .{address}) catch return;
    defer alloc.free(legacy);
    dispatch(ctx, alloc, lua, legacy);
}

pub fn toggleFullscreen(ctx: *const Context, alloc: std.mem.Allocator, address: []const u8) void {
    const lua = std.fmt.allocPrint(alloc, "dispatch hl.dsp.window.fullscreen({{ window = 'address:{s}', action = 'toggle' }})", .{address}) catch return;
    defer alloc.free(lua);
    const legacy = std.fmt.allocPrint(alloc, "dispatch fullscreen address:{s}", .{address}) catch return;
    defer alloc.free(legacy);
    dispatch(ctx, alloc, lua, legacy);
}

pub fn moveToWorkspace(ctx: *const Context, alloc: std.mem.Allocator, address: []const u8, workspace: i32) void {
    const lua = std.fmt.allocPrint(alloc, "dispatch hl.dsp.window.move({{ workspace = '{d}', window = 'address:{s}' }})", .{ workspace, address }) catch return;
    defer alloc.free(lua);
    const legacy = std.fmt.allocPrint(alloc, "dispatch movetoworkspace {d},address:{s}", .{ workspace, address }) catch return;
    defer alloc.free(legacy);
    dispatch(ctx, alloc, lua, legacy);
}

/// Open the event socket and return its fd, or an error. The fd must be made
/// non-blocking before handing it to GLib.
pub fn connectEventSocket(ctx: *const Context) !c_int {
    const fd = try unixConnect(ctx, ".socket2.sock");
    const flags = c.fcntl(fd, c.F_GETFL);
    if (flags >= 0) {
        _ = c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK);
    }
    return fd;
}
