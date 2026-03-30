const std = @import("std");

const filled_char = "▓";
const empty_char = "░";

pub fn draw(writer: anytype, ratio: f64, bar_width: usize) !void {
    const clamped = std.math.clamp(ratio, 0.0, 1.0);
    const filled_count: usize = @intFromFloat(@round(clamped * @as(f64, @floatFromInt(bar_width))));
    const empty_count = bar_width - filled_count;

    for (0..filled_count) |_| {
        try writer.writeAll(filled_char);
    }
    for (0..empty_count) |_| {
        try writer.writeAll(empty_char);
    }

    try writer.print("  {d:.1}%", .{clamped * 100.0});
}

test "draw ratio=0.0 all empty" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try draw(fbs.writer(), 0.0, 8);
    const result = fbs.getWritten();
    // 8 empty chars + "  0.0%"
    const expected = "░░░░░░░░  0.0%";
    try std.testing.expectEqualStrings(expected, result);
}

test "draw ratio=1.0 all filled" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try draw(fbs.writer(), 1.0, 8);
    const result = fbs.getWritten();
    const expected = "▓▓▓▓▓▓▓▓  100.0%";
    try std.testing.expectEqualStrings(expected, result);
}

test "draw ratio=0.5 bar_width=10" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try draw(fbs.writer(), 0.5, 10);
    const result = fbs.getWritten();
    const expected = "▓▓▓▓▓░░░░░  50.0%";
    try std.testing.expectEqualStrings(expected, result);
}

test "draw ratio clamped below 0.0" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try draw(fbs.writer(), -0.5, 4);
    const result = fbs.getWritten();
    const expected = "░░░░  0.0%";
    try std.testing.expectEqualStrings(expected, result);
}

test "draw ratio clamped above 1.0" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try draw(fbs.writer(), 1.5, 4);
    const result = fbs.getWritten();
    const expected = "▓▓▓▓  100.0%";
    try std.testing.expectEqualStrings(expected, result);
}
