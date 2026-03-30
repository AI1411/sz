const std = @import("std");

/// "30d" 形式の文字列を日数(u32)に変換する。
/// 対応フォーマット: "Nd" (N は正の整数、d は日を意味するサフィックス)
/// 例: "30d" → 30, "7d" → 7, "1d" → 1
/// 不正な入力は error.InvalidFormat を返す。
pub fn parseDays(s: []const u8) !u32 {
    if (s.len < 2) return error.InvalidFormat;
    if (s[s.len - 1] != 'd') return error.InvalidFormat;
    const num_str = s[0 .. s.len - 1];
    if (num_str.len == 0) return error.InvalidFormat;
    return std.fmt.parseInt(u32, num_str, 10) catch error.InvalidFormat;
}

/// mtime が now_sec から older_days 日以上前であれば true を返す。
/// older_days が null の場合は常に true を返す（フィルタなし）。
/// mtime: Unix エポック秒
/// now_sec: 現在時刻の Unix エポック秒
pub fn matchOlder(mtime: i64, now_sec: i64, older_days: ?u32) bool {
    const days = older_days orelse return true;
    const cutoff = now_sec - @as(i64, days) * 86400;
    return mtime < cutoff;
}

// ─── tests ───────────────────────────────────────────────────────────────────

test "parseDays: valid formats" {
    try std.testing.expectEqual(@as(u32, 30), try parseDays("30d"));
    try std.testing.expectEqual(@as(u32, 1), try parseDays("1d"));
    try std.testing.expectEqual(@as(u32, 365), try parseDays("365d"));
    try std.testing.expectEqual(@as(u32, 0), try parseDays("0d"));
}

test "parseDays: invalid formats" {
    try std.testing.expectError(error.InvalidFormat, parseDays(""));
    try std.testing.expectError(error.InvalidFormat, parseDays("d"));
    try std.testing.expectError(error.InvalidFormat, parseDays("30"));
    try std.testing.expectError(error.InvalidFormat, parseDays("30h"));
    try std.testing.expectError(error.InvalidFormat, parseDays("abcd"));
    try std.testing.expectError(error.InvalidFormat, parseDays("-1d"));
}

test "matchOlder: no filter always passes" {
    try std.testing.expect(matchOlder(0, 1_700_000_000, null));
    try std.testing.expect(matchOlder(1_700_000_000, 1_700_000_000, null));
}

test "matchOlder: 30d filter" {
    const now: i64 = 1_700_000_000;
    const cutoff = now - 30 * 86400;

    // mtime が cutoff より前 → 古い → true
    try std.testing.expect(matchOlder(cutoff - 1, now, 30));
    try std.testing.expect(matchOlder(0, now, 30));

    // mtime が cutoff 以降 → 新しい → false
    try std.testing.expect(!matchOlder(cutoff, now, 30));
    try std.testing.expect(!matchOlder(now, now, 30));
    try std.testing.expect(!matchOlder(cutoff + 1, now, 30));
}

test "matchOlder: 0d filter" {
    const now: i64 = 1_700_000_000;
    // cutoff = now - 0 = now → mtime < now でなければ false
    try std.testing.expect(matchOlder(now - 1, now, 0));
    try std.testing.expect(!matchOlder(now, now, 0));
    try std.testing.expect(!matchOlder(now + 1, now, 0));
}
