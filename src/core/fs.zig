//! File I/O straight through libc.
const std = @import("std");
const c = @import("../c.zig");

pub const Error = error{ FileNotFound, Unreadable, FileTooBig, WriteFailed, OutOfMemory };

pub fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8, max_size: usize) Error![]u8 {
    const pz = alloc.dupeZ(u8, path) catch return error.Unreadable;
    defer alloc.free(pz);

    const f = c.fopen(pz.ptr, "r") orelse return error.FileNotFound;
    defer _ = c.fclose(f);

    if (c.fseek(f, 0, c.SEEK_END) != 0) return error.Unreadable;
    const size = c.ftell(f);
    if (size < 0) return error.Unreadable;
    if (c.fseek(f, 0, c.SEEK_SET) != 0) return error.Unreadable;

    const sz: usize = @intCast(size);
    if (sz > max_size) return error.FileTooBig;
    if (sz == 0) return alloc.alloc(u8, 0);

    const buf = try alloc.alloc(u8, sz);
    const got = c.fread(buf.ptr, 1, sz, f);
    return buf[0..got];
}

pub fn writeFile(path: []const u8, data: []const u8) Error!void {
    const alloc = std.heap.page_allocator;
    const pz = alloc.dupeZ(u8, path) catch return error.WriteFailed;
    defer alloc.free(pz);

    const f = c.fopen(pz.ptr, "w");
    if (f == null) return error.WriteFailed;
    defer _ = c.fclose(f);

    if (data.len > 0) {
        const wrote = c.fwrite(data.ptr, 1, data.len, f);
        if (wrote != data.len) return error.WriteFailed;
    }
}

pub fn pathExists(path: []const u8) bool {
    const alloc = std.heap.page_allocator;
    const pz = alloc.dupeZ(u8, path) catch return false;
    defer alloc.free(pz);
    return c.access(pz.ptr, c.F_OK) == 0;
}

/// mkdir -p
pub fn ensureDir(path: []const u8) bool {
    const alloc = std.heap.page_allocator;
    const pz = alloc.dupeZ(u8, path) catch return false;
    defer alloc.free(pz);

    var buf: [4096]u8 = undefined;
    var buf_len: usize = 0;
    if (path.len > 0 and path[0] == '/') {
        buf[0] = '/';
        buf_len = 1;
    }
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (buf_len > 0 and buf[buf_len - 1] != '/') {
            buf[buf_len] = '/';
            buf_len += 1;
        }
        @memcpy(buf[buf_len .. buf_len + part.len], part);
        buf_len += part.len;
        buf[buf_len] = 0;
        if (c.mkdir(@ptrCast(&buf), 0o755) != 0) {
            const err = c.errnoValue();
            if (err != c.EEXIST and err != c.ENOTDIR) return false;
        }
    }
    return true;
}

/// List regular files in a directory (names only). Returns null if the
/// directory cannot be opened. The returned slice and names are allocated
/// with `alloc`; caller frees via `alloc.free` on the slice.
pub fn listDirFiles(alloc: std.mem.Allocator, dir_path: []const u8) ?[]const []const u8 {
    const pz = alloc.dupeZ(u8, dir_path) catch return null;
    defer alloc.free(pz);

    const dir = c.opendir(pz.ptr) orelse return null;
    defer _ = c.closedir(dir);

    var out: std.ArrayList([]const u8) = .empty;
    while (true) {
        const entry = c.readdir(dir) orelse break;
        if (entry.*.name[0] == 0) continue;
        const name = std.mem.sliceTo(&entry.*.name, 0);
        const d_type = entry.*.dtype;
        if (d_type == c.DT_REG or d_type == c.DT_UNKNOWN) {
            out.append(alloc, alloc.dupe(u8, name) catch continue) catch continue;
        }
    }
    return out.toOwnedSlice(alloc) catch null;
}
