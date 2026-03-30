/// フィルタ機能の統合テスト。
/// pattern / size / preset / date の各フィルタをまとめてテストする。
const std = @import("std");
const pattern_filter = @import("filter_pattern");
const size_filter = @import("filter_size");
const preset_mod = @import("filter_preset");
const date_filter = @import("filter_date");

// ─── glob パターンマッチング ────────────────────────────────────────────────

test "integration: glob pattern excludes node_modules" {
    const excludes = [_][]const u8{"node_modules"};
    try std.testing.expect(pattern_filter.matchAny(&excludes, "node_modules"));
    try std.testing.expect(!pattern_filter.matchAny(&excludes, "src"));
}

test "integration: glob wildcard matches extensions" {
    const only = [_][]const u8{ "*.jpg", "*.png" };
    try std.testing.expect(pattern_filter.matchAny(&only, "photo.jpg"));
    try std.testing.expect(pattern_filter.matchAny(&only, "image.png"));
    try std.testing.expect(!pattern_filter.matchAny(&only, "document.pdf"));
}

test "integration: double-star matches path with separator" {
    const pats = [_][]const u8{"**.log"};
    try std.testing.expect(pattern_filter.matchAny(&pats, "server.log"));
    try std.testing.expect(pattern_filter.matchAny(&pats, "logs/server.log"));
    try std.testing.expect(!pattern_filter.matchAny(&pats, "server.txt"));
}

test "integration: question mark matches single char" {
    const pats = [_][]const u8{"file?.txt"};
    try std.testing.expect(pattern_filter.matchAny(&pats, "file1.txt"));
    try std.testing.expect(pattern_filter.matchAny(&pats, "filea.txt"));
    try std.testing.expect(!pattern_filter.matchAny(&pats, "file10.txt"));
    try std.testing.expect(!pattern_filter.matchAny(&pats, "file.txt"));
}

// ─── サイズフィルタ ──────────────────────────────────────────────────────────

test "integration: size filter min boundary" {
    const min: u64 = 1024 * 1024; // 1 MiB
    try std.testing.expect(size_filter.matchSize(min, min, null));
    try std.testing.expect(size_filter.matchSize(min + 1, min, null));
    try std.testing.expect(!size_filter.matchSize(min - 1, min, null));
}

test "integration: size filter max boundary" {
    const max: u64 = 100 * 1024 * 1024; // 100 MiB
    try std.testing.expect(size_filter.matchSize(max, null, max));
    try std.testing.expect(size_filter.matchSize(0, null, max));
    try std.testing.expect(!size_filter.matchSize(max + 1, null, max));
}

test "integration: size filter range" {
    const min: u64 = 1024;
    const max: u64 = 1024 * 1024;
    try std.testing.expect(size_filter.matchSize(512 * 1024, min, max)); // 512 KiB
    try std.testing.expect(!size_filter.matchSize(512, min, max)); // 512 B
    try std.testing.expect(!size_filter.matchSize(2 * 1024 * 1024, min, max)); // 2 MiB
}

// ─── プリセットフィルタ ──────────────────────────────────────────────────────

test "integration: dev preset excludes common build artifacts" {
    const p = preset_mod.parse("dev").?;
    try std.testing.expectEqual(preset_mod.Preset.dev, p);

    // dev_exclude には node_modules, .git, target, zig-cache, zig-out が含まれる
    const must_exclude = [_][]const u8{
        "node_modules", ".git", "target", "zig-cache", "zig-out",
    };
    for (must_exclude) |name| {
        try std.testing.expect(pattern_filter.matchAny(&preset_mod.dev_exclude, name));
    }
    // src/ は除外されない
    try std.testing.expect(!pattern_filter.matchAny(&preset_mod.dev_exclude, "src"));
}

test "integration: media preset matches image and video extensions" {
    try std.testing.expect(pattern_filter.matchAny(&preset_mod.media_only, "photo.jpg"));
    try std.testing.expect(pattern_filter.matchAny(&preset_mod.media_only, "movie.mp4"));
    try std.testing.expect(!pattern_filter.matchAny(&preset_mod.media_only, "readme.md"));
}

test "integration: logs preset matches log files" {
    try std.testing.expect(pattern_filter.matchAny(&preset_mod.logs_only, "app.log"));
    try std.testing.expect(pattern_filter.matchAny(&preset_mod.logs_only, "app.log.1"));
    try std.testing.expect(!pattern_filter.matchAny(&preset_mod.logs_only, "config.json"));
}

test "integration: unknown preset returns null" {
    try std.testing.expect(preset_mod.parse("unknown") == null);
}

// ─── 日付フィルタ ────────────────────────────────────────────────────────────

test "integration: date filter newer_than" {
    const now: i64 = 1_700_000_000;
    const yesterday = now - 86400;
    const tomorrow = now + 86400;
    try std.testing.expect(date_filter.matchDate(tomorrow, now, null));
    try std.testing.expect(!date_filter.matchDate(yesterday, now, null));
    try std.testing.expect(!date_filter.matchDate(now, now, null)); // 等値は含まない
}

test "integration: date filter older_than" {
    const now: i64 = 1_700_000_000;
    const yesterday = now - 86400;
    try std.testing.expect(date_filter.matchDate(yesterday, null, now));
    try std.testing.expect(!date_filter.matchDate(now, null, now)); // 等値は含まない
    try std.testing.expect(!date_filter.matchDate(now + 1, null, now));
}

test "integration: date filter range (last 7 days)" {
    const now: i64 = 1_700_000_000;
    const week_ago = now - 7 * 86400;
    const two_weeks_ago = now - 14 * 86400;
    // week_ago < mtime < now の範囲
    try std.testing.expect(date_filter.matchDate(now - 3 * 86400, week_ago, now));
    try std.testing.expect(!date_filter.matchDate(two_weeks_ago, week_ago, now));
    try std.testing.expect(!date_filter.matchDate(now + 1, week_ago, now));
}

test "integration: date filter no constraints" {
    try std.testing.expect(date_filter.matchDate(0, null, null));
    try std.testing.expect(date_filter.matchDate(std.math.maxInt(i64), null, null));
}
