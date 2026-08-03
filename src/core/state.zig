//! Shared process-wide state. GTK callbacks are plain C functions, so the
//! app state lives in globals instead of being threaded through closures.
const std = @import("std");
const config_mod = @import("config.zig");
const hypr = @import("../hypr/ipc.zig");

// Long-lived allocations (config, pinned, strings captured by popovers).
pub var alloc: std.mem.Allocator = undefined;
// Scratch arena reset on every client refresh.
pub var scratch: std.mem.Allocator = undefined;

pub var cfg: config_mod.Config = config_mod.Config.defaults();
pub var ctx: hypr.Context = .{};

// GTK widget tree (opaque C handles)
pub var win: ?*anyopaque = null;
pub var outer_box: ?*anyopaque = null;
pub var alignment_box: ?*anyopaque = null;
pub var main_box: ?*anyopaque = null;

// App state
pub var clients: []hypr.Client = &.{};
pub var monitors: []hypr.Monitor = &.{};
pub var pinned: std.ArrayList([]const u8) = .empty;
pub var active_class: []const u8 = "";
pub var last_win_addr: []const u8 = "";
pub var active_ws_id: i32 = 0;
pub var workspace_has_windows: bool = false; // active ws occupancy (hide_on_activity)

pub var vertical: bool = false; // dock on left/right edge
pub var hide_timer: c_uint = 0;
pub var mouse_in_dock = false;
pub var mouse_in_hotspot = false;
pub var detector_entered_ms: i64 = 0;
