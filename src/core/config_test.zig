const std = @import("std");
const config_mod = @import("config");

test "toml serializer preserves comments and edits in place" {
    const a = std.testing.allocator;

    const src =
        \\# DockH configuration
        \\[general]
        \\position = "top" # edge of screen
        \\icon_size = 48
        \\
        \\[behavior]
        \\autohide = false
        \\# nested comment
        \\
    ;

    var out: []const u8 = src;

    // Replace an existing value, preserving its inline comment.
    const s1 = try config_mod.setValueInText(a, out, "general", "position", "\"bottom\"");
    defer a.free(s1);
    out = s1;

    // Replace a plain value.
    const s2 = try config_mod.setValueInText(a, out, "general", "icon_size", "42");
    defer a.free(s2);
    out = s2;

    // Insert a brand-new key into an existing section.
    const s3 = try config_mod.setValueInText(a, out, "general", "hotkey", "\"SUPER + D\"");
    out = s3;
    defer a.free(out);

    // Edited values in place, with spacing preserved before the inline comment.
    try std.testing.expect(std.mem.indexOf(u8, out, "position = \"bottom\" # edge of screen") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "icon_size = 42") != null);
    // Comments preserved.
    try std.testing.expect(std.mem.indexOf(u8, out, "# DockH configuration") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# nested comment") != null);
    // New key inserted inside the right section, and the old value is gone.
    try std.testing.expect(std.mem.indexOf(u8, out, "hotkey = \"SUPER + D\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "position = \"top\"") == null);
    // No glued comment ("value# ..." without a space).
    try std.testing.expect(std.mem.indexOf(u8, out, "bottom\"#") == null);
    // The other section is untouched.
    try std.testing.expect(std.mem.indexOf(u8, out, "autohide = false") != null);
}

test "toml serializer keeps '#' inside quoted values" {
    const a = std.testing.allocator;
    const src = "[general]\napp_launcher = \"kitty --title '#dev'\" # launcher\n";
    const out = try config_mod.setValueInText(a, src, "general", "app_launcher", "\"firefox\"");
    defer a.free(out);
    // The '#' inside the OLD quoted value must not be treated as a comment
    // start: the replacement keeps only the real trailing comment, spaced.
    try std.testing.expect(std.mem.indexOf(u8, out, "app_launcher = \"firefox\" # launcher") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "firefox\"#") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "#dev") == null);
}
