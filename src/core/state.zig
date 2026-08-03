//! Shared process-wide state. GTK callbacks are plain C functions, so the
//! app state lives in globals instead of being threaded through closures.
const std = @import("std");
const config_mod = @import("config.zig");
const hypr = @import("../hypr/ipc.zig");

// Long-lived allocations (config, pinned, strings captured by popovers).
pub var alloc: std.mem.Allocator = undefined;
// Scratch arena reset on every client refresh.
pub var scratch: std.mem.Allocator = undefined;
// Per-rebuild arena: every allocation a dock rebuild makes (CSS class
// names, tooltips, BtnData, .desktop lookups) goes here and is wiped on the
// next rebuild — so the permanent `alloc` arena never grows with Hyprland
// events and RSS stays flat instead of creeping toward 200 MB.
pub var ui_arena: std.heap.ArenaAllocator = undefined;
pub var ui_alloc: std.mem.Allocator = undefined;

/// Reset the per-rebuild arena. Call AFTER the old widget tree has been
/// destroyed (clearBox) — every live widget that referenced ui_alloc memory
/// is gone by then, so no dangling pointers survive.
/// INVARIANT: must run to completion inside the same main-loop dispatch as
/// clearBox (rebuildMainBox does both synchronously) — GLib timers (status
/// polls) can never interleave with the reset, so nothing reads item_status /
/// mag_items / BtnData mid-wipe.
pub fn resetUi() void {
    _ = ui_arena.reset(.retain_capacity);
    ui_alloc = ui_arena.allocator();
}

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
// Last activewindowv2 address — a fixed buffer instead of a heap dupe so the
// per-focus-change event never allocates into the permanent arena.
pub var last_win_addr_buf: [128]u8 = undefined;
pub var last_win_addr_len: usize = 0;
pub var active_ws_id: i32 = 0;
pub var workspace_has_windows: bool = false; // active ws occupancy (hide_on_activity)

pub var vertical: bool = false; // dock on left/right edge
pub var hide_timer: c_uint = 0;
pub var mouse_in_dock = false;
pub var mouse_in_hotspot = false;
pub var detector_entered_ms: i64 = 0;
