const std = @import("std");

/// 日付フィルタ。
/// mtime はファイルの最終更新時刻（Unix エポック秒）。
/// newer_than が非 null の場合は mtime > newer_than でなければ false。
/// older_than が非 null の場合は mtime < older_than でなければ false。
pub fn matchDate(mtime: i64, newer_than: ?i64, older_than: ?i64) bool {
    if (newer_than) |ts| {
        if (mtime <= ts) return false;
    }
    if (older_than) |ts| {
        if (mtime >= ts) return false;
    }
    return true;
}

// ─── tests ───────────────────────────────────────────────────────────────────

test "matchDate: no filter always passes" {
    try std.testing.expect(matchDate(0, null, null));
    try std.testing.expect(matchDate(1_700_000_000, null, null));
    try std.testing.expect(matchDate(-1, null, null));
}

test "matchDate: newer_than filter" {
    const base: i64 = 1_700_000_000;
    try std.testing.expect(matchDate(base + 1, base, null));
    try std.testing.expect(!matchDate(base, base, null));
    try std.testing.expect(!matchDate(base - 1, base, null));
}

test "matchDate: older_than filter" {
    const base: i64 = 1_700_000_000;
    try std.testing.expect(matchDate(base - 1, null, base));
    try std.testing.expect(!matchDate(base, null, base));
    try std.testing.expect(!matchDate(base + 1, null, base));
}

test "matchDate: newer_than and older_than range" {
    const lo: i64 = 1_000_000;
    const hi: i64 = 2_000_000;
    try std.testing.expect(matchDate(1_500_000, lo, hi));
    try std.testing.expect(!matchDate(lo, lo, hi));
    try std.testing.expect(!matchDate(hi, lo, hi));
    try std.testing.expect(!matchDate(lo - 1, lo, hi));
    try std.testing.expect(!matchDate(hi + 1, lo, hi));
}
