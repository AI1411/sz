const std = @import("std");

/// サイズフィルタ。
/// min_size が非 null の場合は size >= min_size でなければ false。
/// max_size が非 null の場合は size <= max_size でなければ false。
pub fn matchSize(size: u64, min_size: ?u64, max_size: ?u64) bool {
    if (min_size) |min| {
        if (size < min) return false;
    }
    if (max_size) |max| {
        if (size > max) return false;
    }
    return true;
}

// ─── tests ───────────────────────────────────────────────────────────────────

test "matchSize: no filter always passes" {
    try std.testing.expect(matchSize(0, null, null));
    try std.testing.expect(matchSize(1024 * 1024, null, null));
    try std.testing.expect(matchSize(std.math.maxInt(u64), null, null));
}

test "matchSize: min filter" {
    try std.testing.expect(matchSize(50, 50, null));
    try std.testing.expect(matchSize(100, 50, null));
    try std.testing.expect(!matchSize(49, 50, null));
    try std.testing.expect(!matchSize(0, 50, null));
}

test "matchSize: max filter" {
    try std.testing.expect(matchSize(200, null, 200));
    try std.testing.expect(matchSize(0, null, 200));
    try std.testing.expect(!matchSize(201, null, 200));
}

test "matchSize: min and max" {
    try std.testing.expect(matchSize(100, 50, 200));
    try std.testing.expect(matchSize(50, 50, 200));
    try std.testing.expect(matchSize(200, 50, 200));
    try std.testing.expect(!matchSize(49, 50, 200));
    try std.testing.expect(!matchSize(201, 50, 200));
}
