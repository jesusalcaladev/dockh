//! Minimal leveled logging to stderr, with epoch timestamps. No stdlib time
//! API needed — std.time lost its timestamp helpers in Zig 0.16.
const std = @import("std");
const c = @import("../c.zig");

pub var debug_enabled: bool = false;

const Level = enum { debug, info, warn, err };

fn write(level: Level, comptime fmt: []const u8, args: anytype) void {
    const level_tag: []const u8 = switch (level) {
        .debug => "DEBUG",
        .info => "INFO",
        .warn => "WARN",
        .err => "ERROR",
    };
    if (level == .debug and !debug_enabled) return;

    var stamp: [32]u8 = undefined;
    const secs = c.time(null);
    const stamp_slice = std.fmt.bufPrint(&stamp, "{d}", .{secs}) catch "?";

    std.debug.print("[{s} {s}] ", .{ stamp_slice, level_tag });
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    write(.debug, fmt, args);
}
pub fn info(comptime fmt: []const u8, args: anytype) void {
    write(.info, fmt, args);
}
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    write(.warn, fmt, args);
}
pub fn err(comptime fmt: []const u8, args: anytype) void {
    write(.err, fmt, args);
}
