const std = @import("std");

pub const Preset = enum { dev, media, logs };

/// --exclude / --only に指定できる最大パターン数
pub const MAX_PATTERNS: usize = 32;

pub const Args = struct {
    path: []const u8,
    depth: u32,
    top: u32,
    /// 並列ワーカー数。null = CPU コア数（自動）
    jobs: ?u32,
    help: bool,
    version: bool,
    /// --flat: フラット表示モード
    flat: bool,
    /// --follow-links: シンボリックリンクを追跡
    follow_links: bool,
    /// --cross-mount: マウントポイントを越える
    cross_mount: bool,
    /// --min: 最小サイズ文字列（例: "100MB"）。null = フィルタなし
    min_size_str: ?[]const u8,
    /// --max: 最大サイズ文字列
    max_size_str: ?[]const u8,
    /// --preset
    preset: ?Preset,
    /// --json: JSON 形式で stdout へ出力
    json: bool,
    /// --csv: CSV 形式で stdout へ出力
    csv: bool,
    /// --save <path>: スキャン結果を JSON スナップショットとして保存
    save_path: ?[]const u8,
    /// --apparent: 見かけのサイズ (st_size) を使用する（デフォルト: ディスク使用量）
    apparent: bool,
    /// --older <Nd>: N日以上前のエントリのみ表示（例: "30d"）
    older_str: ?[]const u8,
    /// --assert-max <SIZE>: 指定サイズを超えた場合は exit 1 を返す
    assert_max_str: ?[]const u8,
    /// --compare <path>: 保存済みスナップショットと比較表示
    compare_path: ?[]const u8,
    /// --exclude パターンバッファ
    exclude_buf: [MAX_PATTERNS][]const u8,
    exclude_count: u8,
    /// --only パターンバッファ
    only_buf: [MAX_PATTERNS][]const u8,
    only_count: u8,

    pub fn excludePatterns(self: *const Args) []const []const u8 {
        return self.exclude_buf[0..self.exclude_count];
    }

    pub fn onlyPatterns(self: *const Args) []const []const u8 {
        return self.only_buf[0..self.only_count];
    }
};

const default_path = ".";
const default_depth: u32 = 3;
const default_top: u32 = 10;

/// カンマ区切りパターン文字列をバッファに追加する。
/// バッファが満杯の場合は余分なパターンを無視する。
fn addPatterns(buf: [][]const u8, count: *u8, pattern: []const u8) void {
    var start: usize = 0;
    var i: usize = 0;
    while (i <= pattern.len) : (i += 1) {
        if (i == pattern.len or pattern[i] == ',') {
            const seg = pattern[start..i];
            if (seg.len > 0 and count.* < @as(u8, @intCast(buf.len))) {
                buf[count.*] = seg;
                count.* += 1;
            }
            start = i + 1;
        }
    }
}

fn parseCore(argv: []const []const u8) !Args {
    var path: []const u8 = default_path;
    var path_set = false;
    var depth: u32 = default_depth;
    var top: u32 = default_top;
    var jobs: ?u32 = null;
    var help: bool = false;
    var version: bool = false;
    var flat: bool = false;
    var follow_links: bool = false;
    var cross_mount: bool = false;
    var min_size_str: ?[]const u8 = null;
    var max_size_str: ?[]const u8 = null;
    var preset: ?Preset = null;
    var json: bool = false;
    var csv: bool = false;
    var save_path: ?[]const u8 = null;
    var apparent: bool = false;
    var older_str: ?[]const u8 = null;
    var assert_max_str: ?[]const u8 = null;
    var compare_path: ?[]const u8 = null;
    var exclude_buf: [MAX_PATTERNS][]const u8 = undefined;
    var exclude_count: u8 = 0;
    var only_buf: [MAX_PATTERNS][]const u8 = undefined;
    var only_count: u8 = 0;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--depth")) {
            i += 1;
            if (i >= argv.len) {
                std.debug.print("error: {s} requires a numeric argument\n", .{arg});
                return error.InvalidArgument;
            }
            depth = std.fmt.parseInt(u32, argv[i], 10) catch {
                std.debug.print("error: invalid depth value '{s}'\n", .{argv[i]});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--top")) {
            i += 1;
            if (i >= argv.len) {
                std.debug.print("error: {s} requires a numeric argument\n", .{arg});
                return error.InvalidArgument;
            }
            top = std.fmt.parseInt(u32, argv[i], 10) catch {
                std.debug.print("error: invalid top value '{s}'\n", .{argv[i]});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--jobs")) {
            i += 1;
            if (i >= argv.len) {
                std.debug.print("error: {s} requires a numeric argument\n", .{arg});
                return error.InvalidArgument;
            }
            jobs = std.fmt.parseInt(u32, argv[i], 10) catch {
                std.debug.print("error: invalid jobs value '{s}'\n", .{argv[i]});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--exclude")) {
            i += 1;
            if (i >= argv.len) {
                std.debug.print("error: {s} requires a pattern argument\n", .{arg});
                return error.InvalidArgument;
            }
            addPatterns(&exclude_buf, &exclude_count, argv[i]);
        } else if (std.mem.eql(u8, arg, "--only")) {
            i += 1;
            if (i >= argv.len) {
                std.debug.print("error: {s} requires a pattern argument\n", .{arg});
                return error.InvalidArgument;
            }
            addPatterns(&only_buf, &only_count, argv[i]);
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--min")) {
            i += 1;
            if (i >= argv.len) {
                std.debug.print("error: {s} requires a size argument\n", .{arg});
                return error.InvalidArgument;
            }
            min_size_str = argv[i];
        } else if (std.mem.eql(u8, arg, "-M") or std.mem.eql(u8, arg, "--max")) {
            i += 1;
            if (i >= argv.len) {
                std.debug.print("error: {s} requires a size argument\n", .{arg});
                return error.InvalidArgument;
            }
            max_size_str = argv[i];
        } else if (std.mem.eql(u8, arg, "--preset")) {
            i += 1;
            if (i >= argv.len) {
                std.debug.print("error: {s} requires a preset name (dev, media, logs)\n", .{arg});
                return error.InvalidArgument;
            }
            const p_name = argv[i];
            if (std.mem.eql(u8, p_name, "dev")) {
                preset = .dev;
            } else if (std.mem.eql(u8, p_name, "media")) {
                preset = .media;
            } else if (std.mem.eql(u8, p_name, "logs")) {
                preset = .logs;
            } else {
                std.debug.print("error: unknown preset '{s}' (available: dev, media, logs)\n", .{p_name});
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--csv")) {
            csv = true;
        } else if (std.mem.eql(u8, arg, "--save")) {
            i += 1;
            if (i >= argv.len) {
                std.debug.print("error: {s} requires a file path argument\n", .{arg});
                return error.InvalidArgument;
            }
            save_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--apparent")) {
            apparent = true;
        } else if (std.mem.eql(u8, arg, "--older")) {
            i += 1;
            if (i >= argv.len) {
                std.debug.print("error: {s} requires a day argument (e.g. 30d)\n", .{arg});
                return error.InvalidArgument;
            }
            older_str = argv[i];
        } else if (std.mem.eql(u8, arg, "--assert-max")) {
            i += 1;
            if (i >= argv.len) {
                std.debug.print("error: {s} requires a size argument\n", .{arg});
                return error.InvalidArgument;
            }
            assert_max_str = argv[i];
        } else if (std.mem.eql(u8, arg, "--compare")) {
            i += 1;
            if (i >= argv.len) {
                std.debug.print("error: {s} requires a file path argument\n", .{arg});
                return error.InvalidArgument;
            }
            compare_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--flat")) {
            flat = true;
        } else if (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "--follow-links")) {
            follow_links = true;
        } else if (std.mem.eql(u8, arg, "-x") or std.mem.eql(u8, arg, "--cross-mount")) {
            cross_mount = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            help = true;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            version = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("error: unknown option '{s}'\n", .{arg});
            return error.InvalidArgument;
        } else {
            if (path_set) {
                std.debug.print("error: too many path arguments\n", .{});
                return error.InvalidArgument;
            }
            path = arg;
            path_set = true;
        }
    }

    return Args{
        .path = path,
        .depth = depth,
        .top = top,
        .jobs = jobs,
        .help = help,
        .version = version,
        .flat = flat,
        .follow_links = follow_links,
        .cross_mount = cross_mount,
        .min_size_str = min_size_str,
        .max_size_str = max_size_str,
        .preset = preset,
        .json = json,
        .csv = csv,
        .save_path = save_path,
        .apparent = apparent,
        .older_str = older_str,
        .assert_max_str = assert_max_str,
        .compare_path = compare_path,
        .exclude_buf = exclude_buf,
        .exclude_count = exclude_count,
        .only_buf = only_buf,
        .only_count = only_count,
    };
}

pub fn parse(allocator: std.mem.Allocator) !Args {
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const rest: []const []const u8 = blk: {
        const n = if (argv.len > 1) argv.len - 1 else 0;
        const buf = try allocator.alloc([]const u8, n);
        for (0..n) |k| buf[k] = argv[k + 1];
        break :blk buf;
    };
    defer allocator.free(rest);

    var result = try parseCore(rest);

    // argv は defer で解放されるので、借用スライスをすべて複製する
    result.path = try allocator.dupe(u8, result.path);
    for (0..result.exclude_count) |k| {
        result.exclude_buf[k] = try allocator.dupe(u8, result.exclude_buf[k]);
    }
    for (0..result.only_count) |k| {
        result.only_buf[k] = try allocator.dupe(u8, result.only_buf[k]);
    }
    if (result.min_size_str) |s| {
        result.min_size_str = try allocator.dupe(u8, s);
    }
    if (result.max_size_str) |s| {
        result.max_size_str = try allocator.dupe(u8, s);
    }
    if (result.save_path) |s| {
        result.save_path = try allocator.dupe(u8, s);
    }
    if (result.older_str) |s| {
        result.older_str = try allocator.dupe(u8, s);
    }
    if (result.assert_max_str) |s| {
        result.assert_max_str = try allocator.dupe(u8, s);
    }
    if (result.compare_path) |s| {
        result.compare_path = try allocator.dupe(u8, s);
    }
    return result;
}

/// テスト用: argv スライスを直接渡してパースする（アロケーションなし）。
pub fn parseSlice(argv: []const []const u8) !Args {
    return parseCore(argv);
}

// ─── tests ───────────────────────────────────────────────────────────────────

test "default args" {
    const parsed = try parseSlice(&.{});
    try std.testing.expectEqualStrings(".", parsed.path);
    try std.testing.expectEqual(@as(u32, 3), parsed.depth);
    try std.testing.expectEqual(@as(u32, 10), parsed.top);
    try std.testing.expect(parsed.jobs == null);
    try std.testing.expect(!parsed.flat);
    try std.testing.expect(!parsed.follow_links);
    try std.testing.expect(!parsed.cross_mount);
    try std.testing.expect(parsed.min_size_str == null);
    try std.testing.expect(parsed.max_size_str == null);
    try std.testing.expect(parsed.preset == null);
    try std.testing.expect(!parsed.json);
    try std.testing.expect(!parsed.csv);
    try std.testing.expect(parsed.save_path == null);
    try std.testing.expect(!parsed.apparent);
    try std.testing.expect(parsed.older_str == null);
    try std.testing.expect(parsed.assert_max_str == null);
    try std.testing.expect(parsed.compare_path == null);
    try std.testing.expectEqual(@as(u8, 0), parsed.exclude_count);
    try std.testing.expectEqual(@as(u8, 0), parsed.only_count);
}

test "parse path" {
    const parsed = try parseSlice(&.{"/tmp"});
    try std.testing.expectEqualStrings("/tmp", parsed.path);
}

test "parse depth long flag" {
    const parsed = try parseSlice(&.{ "/tmp", "--depth", "5" });
    try std.testing.expectEqual(@as(u32, 5), parsed.depth);
}

test "parse top long flag" {
    const parsed = try parseSlice(&.{ "--top", "20" });
    try std.testing.expectEqual(@as(u32, 20), parsed.top);
}

test "parse short flags" {
    const parsed = try parseSlice(&.{ "-d", "2", "-t", "5" });
    try std.testing.expectEqual(@as(u32, 2), parsed.depth);
    try std.testing.expectEqual(@as(u32, 5), parsed.top);
}

test "parse --jobs" {
    const parsed = try parseSlice(&.{ "--jobs", "4" });
    try std.testing.expectEqual(@as(u32, 4), parsed.jobs.?);
}

test "parse -j" {
    const parsed = try parseSlice(&.{ "-j", "1" });
    try std.testing.expectEqual(@as(u32, 1), parsed.jobs.?);
}

test "parse --flat" {
    const parsed = try parseSlice(&.{"--flat"});
    try std.testing.expect(parsed.flat);
}

test "parse --follow-links" {
    const parsed = try parseSlice(&.{"--follow-links"});
    try std.testing.expect(parsed.follow_links);
}

test "parse -L" {
    const parsed = try parseSlice(&.{"-L"});
    try std.testing.expect(parsed.follow_links);
}

test "parse --cross-mount" {
    const parsed = try parseSlice(&.{"--cross-mount"});
    try std.testing.expect(parsed.cross_mount);
}

test "parse -x" {
    const parsed = try parseSlice(&.{"-x"});
    try std.testing.expect(parsed.cross_mount);
}

test "parse --min and --max" {
    const parsed = try parseSlice(&.{ "--min", "100MB", "--max", "1GB" });
    try std.testing.expectEqualStrings("100MB", parsed.min_size_str.?);
    try std.testing.expectEqualStrings("1GB", parsed.max_size_str.?);
}

test "parse --exclude single pattern" {
    const parsed = try parseSlice(&.{ "--exclude", "node_modules" });
    try std.testing.expectEqual(@as(u8, 1), parsed.exclude_count);
    try std.testing.expectEqualStrings("node_modules", parsed.excludePatterns()[0]);
}

test "parse --exclude multiple" {
    const parsed = try parseSlice(&.{ "--exclude", "node_modules", "--exclude", ".git" });
    try std.testing.expectEqual(@as(u8, 2), parsed.exclude_count);
}

test "parse --only with comma-separated patterns" {
    const parsed = try parseSlice(&.{ "--only", "*.jpg,*.png,*.gif" });
    try std.testing.expectEqual(@as(u8, 3), parsed.only_count);
    try std.testing.expectEqualStrings("*.jpg", parsed.onlyPatterns()[0]);
    try std.testing.expectEqualStrings("*.png", parsed.onlyPatterns()[1]);
    try std.testing.expectEqualStrings("*.gif", parsed.onlyPatterns()[2]);
}

test "parse --preset dev" {
    const parsed = try parseSlice(&.{ "--preset", "dev" });
    try std.testing.expectEqual(Preset.dev, parsed.preset.?);
}

test "parse --preset media" {
    const parsed = try parseSlice(&.{ "--preset", "media" });
    try std.testing.expectEqual(Preset.media, parsed.preset.?);
}

test "parse --preset logs" {
    const parsed = try parseSlice(&.{ "--preset", "logs" });
    try std.testing.expectEqual(Preset.logs, parsed.preset.?);
}

test "parse --preset unknown returns error" {
    try std.testing.expectError(error.InvalidArgument, parseSlice(&.{ "--preset", "unknown" }));
}

test "unknown option returns error" {
    try std.testing.expectError(error.InvalidArgument, parseSlice(&.{"--unknown"}));
}

test "missing depth value returns error" {
    try std.testing.expectError(error.InvalidArgument, parseSlice(&.{"--depth"}));
}

test "non-numeric depth returns error" {
    try std.testing.expectError(error.InvalidArgument, parseSlice(&.{ "--depth", "abc" }));
}

test "missing top value returns error" {
    try std.testing.expectError(error.InvalidArgument, parseSlice(&.{"--top"}));
}

test "non-numeric top returns error" {
    try std.testing.expectError(error.InvalidArgument, parseSlice(&.{ "--top", "xyz" }));
}

test "too many path arguments returns error" {
    try std.testing.expectError(error.InvalidArgument, parseSlice(&.{ "/tmp", "/var" }));
}

test "parse --help sets help flag" {
    const parsed = try parseSlice(&.{"--help"});
    try std.testing.expect(parsed.help);
}

test "parse -h sets help flag" {
    const parsed = try parseSlice(&.{"-h"});
    try std.testing.expect(parsed.help);
}

test "parse --version sets version flag" {
    const parsed = try parseSlice(&.{"--version"});
    try std.testing.expect(parsed.version);
}

test "parse -V sets version flag" {
    const parsed = try parseSlice(&.{"-V"});
    try std.testing.expect(parsed.version);
}

test "default args: help and version are false" {
    const parsed = try parseSlice(&.{});
    try std.testing.expect(!parsed.help);
    try std.testing.expect(!parsed.version);
}

test "parse --json sets json flag" {
    const parsed = try parseSlice(&.{"--json"});
    try std.testing.expect(parsed.json);
    try std.testing.expect(!parsed.csv);
}

test "parse --csv sets csv flag" {
    const parsed = try parseSlice(&.{"--csv"});
    try std.testing.expect(parsed.csv);
    try std.testing.expect(!parsed.json);
}

test "parse --save sets save_path" {
    const parsed = try parseSlice(&.{ "--save", "snapshot.json" });
    try std.testing.expectEqualStrings("snapshot.json", parsed.save_path.?);
}

test "parse --save missing path returns error" {
    try std.testing.expectError(error.InvalidArgument, parseSlice(&.{"--save"}));
}

test "parse --apparent sets apparent flag" {
    const parsed = try parseSlice(&.{"--apparent"});
    try std.testing.expect(parsed.apparent);
}

test "parse --older sets older_str" {
    const parsed = try parseSlice(&.{ "--older", "30d" });
    try std.testing.expectEqualStrings("30d", parsed.older_str.?);
}

test "parse --older missing value returns error" {
    try std.testing.expectError(error.InvalidArgument, parseSlice(&.{"--older"}));
}

test "parse --assert-max sets assert_max_str" {
    const parsed = try parseSlice(&.{ "--assert-max", "500MB" });
    try std.testing.expectEqualStrings("500MB", parsed.assert_max_str.?);
}

test "parse --assert-max missing value returns error" {
    try std.testing.expectError(error.InvalidArgument, parseSlice(&.{"--assert-max"}));
}

test "parse --compare sets compare_path" {
    const parsed = try parseSlice(&.{ "--compare", "snap.json" });
    try std.testing.expectEqualStrings("snap.json", parsed.compare_path.?);
}

test "parse --compare missing path returns error" {
    try std.testing.expectError(error.InvalidArgument, parseSlice(&.{"--compare"}));
}
