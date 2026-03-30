const std = @import("std");

/// glob パターンマッチング。
/// `*` は任意の文字列（空含む）にマッチする。
/// `**` も同様（パス区切りを含む場合も一致）。
/// `?` は任意の1文字にマッチする。
pub fn matchGlob(pattern: []const u8, name: []const u8) bool {
    var pi: usize = 0;
    var ni: usize = 0;
    // 最後に見た `*` の位置
    var star_pi: usize = std.math.maxInt(usize);
    var star_ni: usize = 0;

    while (ni < name.len) {
        if (pi < pattern.len and pattern[pi] == '*') {
            // 連続する `*` をまとめてスキップ
            while (pi < pattern.len and pattern[pi] == '*') pi += 1;
            star_pi = pi;
            star_ni = ni;
        } else if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == name[ni])) {
            pi += 1;
            ni += 1;
        } else if (star_pi != std.math.maxInt(usize)) {
            // `*` にもう1文字追加して再試行
            star_ni += 1;
            ni = star_ni;
            pi = star_pi;
        } else {
            return false;
        }
    }

    // パターン末尾の余分な `*` をスキップ
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi >= pattern.len;
}

/// patterns リストの中で name にマッチするものがあれば true を返す。
pub fn matchAny(patterns: []const []const u8, name: []const u8) bool {
    for (patterns) |p| {
        if (matchGlob(p, name)) return true;
    }
    return false;
}

// ─── tests ───────────────────────────────────────────────────────────────────

test "matchGlob: exact match" {
    try std.testing.expect(matchGlob("node_modules", "node_modules"));
    try std.testing.expect(!matchGlob("node_modules", "node_modules2"));
    try std.testing.expect(!matchGlob("node_modules", "xnode_modules"));
}

test "matchGlob: star extension" {
    try std.testing.expect(matchGlob("*.log", "foo.log"));
    try std.testing.expect(matchGlob("*.log", ".log"));
    try std.testing.expect(!matchGlob("*.log", "foo.txt"));
}

test "matchGlob: star matches empty string" {
    try std.testing.expect(matchGlob("*", "anything"));
    try std.testing.expect(matchGlob("*", ""));
    try std.testing.expect(matchGlob("prefix*", "prefix"));
    try std.testing.expect(matchGlob("prefix*", "prefixSuffix"));
}

test "matchGlob: question mark" {
    try std.testing.expect(matchGlob("?.txt", "a.txt"));
    try std.testing.expect(!matchGlob("?.txt", "ab.txt"));
    try std.testing.expect(!matchGlob("?.txt", ".txt"));
}

test "matchGlob: double star" {
    try std.testing.expect(matchGlob("**.log", "foo.log"));
    try std.testing.expect(matchGlob("**.log", "dir/foo.log"));
    try std.testing.expect(!matchGlob("**.log", "foo.txt"));
}

test "matchGlob: star in middle" {
    try std.testing.expect(matchGlob("*.log.*", "foo.log.1"));
    try std.testing.expect(!matchGlob("*.log.*", "foo.log"));
}

test "matchAny: matches any pattern in list" {
    const pats = [_][]const u8{ "*.jpg", "*.png", "*.gif" };
    try std.testing.expect(matchAny(&pats, "photo.jpg"));
    try std.testing.expect(matchAny(&pats, "image.png"));
    try std.testing.expect(matchAny(&pats, "anim.gif"));
    try std.testing.expect(!matchAny(&pats, "file.txt"));
}

test "matchAny: empty pattern list returns false" {
    try std.testing.expect(!matchAny(&.{}, "anything"));
}
