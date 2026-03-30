const std = @import("std");

pub const Preset = enum { dev, media, logs };

/// dev プリセット: 開発成果物ディレクトリを除外するパターン一覧
pub const dev_exclude = [_][]const u8{
    "node_modules",
    ".git",
    "target",
    "__pycache__",
    ".next",
    "dist",
    ".gradle",
    "build",
    ".cargo",
    "zig-cache",
    "zig-out",
};

/// media プリセット: メディアファイルのみ表示するパターン一覧
pub const media_only = [_][]const u8{
    "*.jpg",
    "*.png",
    "*.gif",
    "*.mp4",
    "*.mov",
    "*.avi",
};

/// logs プリセット: ログファイルのみ表示するパターン一覧
pub const logs_only = [_][]const u8{
    "*.log",
    "*.log.*",
};

/// プリセット名文字列を Preset 型に変換する。
/// 未知の名前は null を返す。
pub fn parse(name: []const u8) ?Preset {
    if (std.mem.eql(u8, name, "dev")) return .dev;
    if (std.mem.eql(u8, name, "media")) return .media;
    if (std.mem.eql(u8, name, "logs")) return .logs;
    return null;
}

// ─── tests ───────────────────────────────────────────────────────────────────

test "parse: known presets" {
    try std.testing.expectEqual(Preset.dev, parse("dev").?);
    try std.testing.expectEqual(Preset.media, parse("media").?);
    try std.testing.expectEqual(Preset.logs, parse("logs").?);
}

test "parse: unknown preset returns null" {
    try std.testing.expect(parse("unknown") == null);
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("Dev") == null);
}

test "dev_exclude contains node_modules and .git" {
    var found_nm = false;
    var found_git = false;
    for (dev_exclude) |p| {
        if (std.mem.eql(u8, p, "node_modules")) found_nm = true;
        if (std.mem.eql(u8, p, ".git")) found_git = true;
    }
    try std.testing.expect(found_nm);
    try std.testing.expect(found_git);
}
