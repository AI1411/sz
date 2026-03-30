const std = @import("std");

const Unit = struct {
    threshold: u64,
    divisor: f64,
    suffix: []const u8,
};

const units = [_]Unit{
    .{ .threshold = 1024 * 1024 * 1024 * 1024, .divisor = 1024.0 * 1024.0 * 1024.0 * 1024.0, .suffix = "TB" },
    .{ .threshold = 1024 * 1024 * 1024, .divisor = 1024.0 * 1024.0 * 1024.0, .suffix = "GB" },
    .{ .threshold = 1024 * 1024, .divisor = 1024.0 * 1024.0, .suffix = "MB" },
    .{ .threshold = 1024, .divisor = 1024.0, .suffix = "KB" },
};

/// バイト数を人間可読な文字列に変換する。
/// buf は結果を格納するバッファ（最低 16 バイト推奨）。
/// 戻り値は buf のスライス。
pub fn fmt(buf: []u8, bytes: u64) []const u8 {
    if (bytes == 0) {
        return std.fmt.bufPrint(buf, "0 B", .{}) catch "0 B";
    }

    inline for (units) |u| {
        if (bytes >= u.threshold) {
            const val = @as(f64, @floatFromInt(bytes)) / u.divisor;
            return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ val, u.suffix }) catch u.suffix;
        }
    }

    // bytes < 1024: 整数表示
    return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "B";
}

/// 人間可読なサイズ文字列をバイト数に変換する。
/// 例: "100MB" → 104_857_600, "1KB" → 1024, "512" → 512
/// サポート単位: B, KB, MB, GB, TB (大文字小文字区別なし)
/// 不正な入力は error.InvalidFormat を返す。
pub fn parse(s: []const u8) !u64 {
    if (s.len == 0) return error.InvalidFormat;

    // 数値部分と単位部分を分割
    var i: usize = 0;
    while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '.')) : (i += 1) {}

    if (i == 0) return error.InvalidFormat;

    const num_str = s[0..i];
    const unit_str = std.mem.trimLeft(u8, s[i..], " \t");

    // 数値をパース（整数のみ対応）
    const num = std.fmt.parseUnsigned(u64, num_str, 10) catch return error.InvalidFormat;

    if (unit_str.len == 0) {
        // 単位なし → バイトとして扱う
        return num;
    }

    // 単位を大文字に正規化して比較
    var unit_upper: [4]u8 = undefined;
    if (unit_str.len > unit_upper.len) return error.InvalidFormat;
    for (unit_str, 0..) |c, j| {
        unit_upper[j] = std.ascii.toUpper(c);
    }
    const unit_norm = unit_upper[0..unit_str.len];

    if (std.mem.eql(u8, unit_norm, "B")) {
        return num;
    } else if (std.mem.eql(u8, unit_norm, "KB")) {
        return num * 1024;
    } else if (std.mem.eql(u8, unit_norm, "MB")) {
        return num * 1024 * 1024;
    } else if (std.mem.eql(u8, unit_norm, "GB")) {
        return num * 1024 * 1024 * 1024;
    } else if (std.mem.eql(u8, unit_norm, "TB")) {
        return num * 1024 * 1024 * 1024 * 1024;
    } else {
        return error.InvalidFormat;
    }
}

// ─── tests ───────────────────────────────────────────────────────────────────

test "fmt: 0 bytes" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", fmt(&buf, 0));
}

test "fmt: bytes range" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1 B", fmt(&buf, 1));
    try std.testing.expectEqualStrings("123 B", fmt(&buf, 123));
    try std.testing.expectEqualStrings("1023 B", fmt(&buf, 1023));
}

test "fmt: kilobytes" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1.0 KB", fmt(&buf, 1024));
    try std.testing.expectEqualStrings("1.2 KB", fmt(&buf, 1234));
    try std.testing.expectEqualStrings("10.0 KB", fmt(&buf, 10240));
}

test "fmt: megabytes" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1.2 MB", fmt(&buf, 1_234_567));
    try std.testing.expectEqualStrings("1.0 MB", fmt(&buf, 1024 * 1024));
}

test "fmt: gigabytes" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1.0 GB", fmt(&buf, 1024 * 1024 * 1024));
}

test "fmt: terabytes" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1.0 TB", fmt(&buf, 1024 * 1024 * 1024 * 1024));
}

test "parse: bytes only (no unit)" {
    try std.testing.expectEqual(@as(u64, 0), try parse("0"));
    try std.testing.expectEqual(@as(u64, 512), try parse("512"));
    try std.testing.expectEqual(@as(u64, 1024), try parse("1024"));
}

test "parse: B unit" {
    try std.testing.expectEqual(@as(u64, 100), try parse("100B"));
    try std.testing.expectEqual(@as(u64, 100), try parse("100b"));
}

test "parse: KB unit" {
    try std.testing.expectEqual(@as(u64, 1024), try parse("1KB"));
    try std.testing.expectEqual(@as(u64, 1024), try parse("1kb"));
    try std.testing.expectEqual(@as(u64, 10 * 1024), try parse("10KB"));
}

test "parse: MB unit" {
    try std.testing.expectEqual(@as(u64, 104_857_600), try parse("100MB"));
    try std.testing.expectEqual(@as(u64, 104_857_600), try parse("100mb"));
    try std.testing.expectEqual(@as(u64, 1024 * 1024), try parse("1MB"));
}

test "parse: GB unit" {
    try std.testing.expectEqual(@as(u64, 1024 * 1024 * 1024), try parse("1GB"));
    try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024 * 1024), try parse("2gb"));
}

test "parse: TB unit" {
    try std.testing.expectEqual(@as(u64, 1024 * 1024 * 1024 * 1024), try parse("1TB"));
    try std.testing.expectEqual(@as(u64, 1024 * 1024 * 1024 * 1024), try parse("1tb"));
}

test "parse: invalid format" {
    try std.testing.expectError(error.InvalidFormat, parse(""));
    try std.testing.expectError(error.InvalidFormat, parse("abc"));
    try std.testing.expectError(error.InvalidFormat, parse("100XB"));
    try std.testing.expectError(error.InvalidFormat, parse("100ZZ"));
}
