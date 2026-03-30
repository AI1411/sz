const std = @import("std");

pub const reset = "\x1b[0m";
pub const bold = "\x1b[1m";
pub const dir = "\x1b[1;34m";
pub const file_default = "";
pub const bar_filled = "\x1b[32m";
pub const bar_empty = "\x1b[90m";
pub const size_color = "\x1b[33m";
pub const percent_color = "\x1b[36m";

pub fn isTty(fd: std.posix.fd_t) bool {
    return std.posix.isatty(fd);
}

pub fn colorizeDir(buf: []u8, name: []const u8, use_color: bool) []const u8 {
    if (!use_color) return name;
    const result = std.fmt.bufPrint(buf, "{s}{s}{s}", .{ dir, name, reset }) catch return name;
    return result;
}

pub fn colorizeFile(buf: []u8, name: []const u8, use_color: bool) []const u8 {
    if (!use_color) return name;
    _ = buf;
    return name;
}

test "isTty returns bool" {
    const stdout_fd: std.posix.fd_t = 1;
    const result = isTty(stdout_fd);
    try std.testing.expect(result == true or result == false);
}

test "colorizeDir without color returns name unchanged" {
    var buf: [256]u8 = undefined;
    const name = "mydir";
    const result = colorizeDir(&buf, name, false);
    try std.testing.expectEqualStrings(name, result);
}

test "colorizeDir with color wraps name in ANSI codes" {
    var buf: [256]u8 = undefined;
    const name = "mydir";
    const result = colorizeDir(&buf, name, true);
    try std.testing.expectEqualStrings("\x1b[1;34mmydir\x1b[0m", result);
}

test "colorizeFile without color returns name unchanged" {
    var buf: [256]u8 = undefined;
    const name = "myfile.txt";
    const result = colorizeFile(&buf, name, false);
    try std.testing.expectEqualStrings(name, result);
}

test "colorizeFile with color returns name unchanged (file_default is empty)" {
    var buf: [256]u8 = undefined;
    const name = "myfile.txt";
    const result = colorizeFile(&buf, name, true);
    try std.testing.expectEqualStrings(name, result);
}
