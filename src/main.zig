const std = @import("std");
const args_mod = @import("utils/args.zig");
const scanner = @import("scanner/parallel.zig");
const tree = @import("render/tree.zig");
const flat = @import("render/flat.zig");
const compare_render = @import("render/compare.zig");
const tui = @import("render/tui.zig");
const size_fmt = @import("size_fmt");
const types = @import("types");
const pattern_filter = @import("filter/pattern.zig");
const size_filter = @import("filter/size.zig");
const age_filter = @import("filter/age.zig");
const preset_mod = @import("filter/preset.zig");
const json_export = @import("json_export");
const csv_export = @import("csv_export");
const snapshot = @import("snapshot");

const version_str = "0.1.0";

const help_text =
    \\sz - directory size visualizer
    \\
    \\USAGE:
    \\  sz [OPTIONS] [PATH]
    \\
    \\ARGS:
    \\  PATH  Directory to scan (default: current directory)
    \\
    \\OPTIONS:
    \\  -d, --depth <N>        Max display depth (default: 3)
    \\  -t, --top <N>          Max entries per directory (default: 10)
    \\  -j, --jobs <N>         Parallel worker count (default: CPU cores)
    \\      --flat             Flat display sorted by size
    \\  -L, --follow-links     Follow symbolic links
    \\  -x, --cross-mount      Cross mount point boundaries
    \\  -m, --min <SIZE>       Show only entries >= SIZE (e.g. 100MB)
    \\  -M, --max <SIZE>       Show only entries <= SIZE
    \\      --exclude PATTERN  Exclude entries matching PATTERN (repeatable)
    \\      --only PATTERN     Show only entries matching PATTERN (repeatable, comma-separated)
    \\      --preset NAME      Apply preset filter (dev, media, logs)
    \\      --json             Output result as JSON
    \\      --csv              Output result as CSV
    \\      --save <PATH>      Save scan result as JSON snapshot
    \\      --apparent         Use apparent size (st_size) instead of disk usage
    \\      --older <Nd>       Show only entries older than N days (e.g. 30d)
    \\      --assert-max <SZ>  Exit 1 if total size exceeds SIZE (e.g. 500MB)
    \\      --compare <PATH>   Compare with saved JSON snapshot
    \\  -1, --one-level        Show only one level deep (equiv. to --depth 1)
    \\  -i, --interactive      Launch interactive TUI mode
    \\  -h, --help             Show this help message
    \\  -V, --version          Show version
    \\
;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parsed = args_mod.parse(allocator) catch |err| {
        switch (err) {
            error.InvalidArgument => std.process.exit(1),
            else => return err,
        }
    };

    if (parsed.help) {
        try std.fs.File.stdout().writeAll(help_text);
        return;
    }

    if (parsed.version) {
        try std.fs.File.stdout().writeAll("sz " ++ version_str ++ "\n");
        return;
    }

    // -1 / --one-level: depth を 1 に強制
    if (parsed.one_level) {
        parsed.depth = 1;
    }

    // --preset をパターンバッファに展開する
    if (parsed.preset) |p| {
        switch (p) {
            .dev => {
                for (preset_mod.dev_exclude) |pat| {
                    if (parsed.exclude_count < args_mod.MAX_PATTERNS) {
                        parsed.exclude_buf[parsed.exclude_count] = pat;
                        parsed.exclude_count += 1;
                    }
                }
            },
            .media => {
                for (preset_mod.media_only) |pat| {
                    if (parsed.only_count < args_mod.MAX_PATTERNS) {
                        parsed.only_buf[parsed.only_count] = pat;
                        parsed.only_count += 1;
                    }
                }
            },
            .logs => {
                for (preset_mod.logs_only) |pat| {
                    if (parsed.only_count < args_mod.MAX_PATTERNS) {
                        parsed.only_buf[parsed.only_count] = pat;
                        parsed.only_count += 1;
                    }
                }
            },
        }
    }

    // --min / --max をパース
    const min_size: ?u64 = if (parsed.min_size_str) |s| size_fmt.parse(s) catch blk: {
        std.debug.print("error: invalid size value '{s}'\n", .{s});
        std.process.exit(1);
        break :blk null;
    } else null;

    const max_size: ?u64 = if (parsed.max_size_str) |s| size_fmt.parse(s) catch blk: {
        std.debug.print("error: invalid size value '{s}'\n", .{s});
        std.process.exit(1);
        break :blk null;
    } else null;

    // --older の日数をパース
    const older_days: ?u32 = if (parsed.older_str) |s| age_filter.parseDays(s) catch blk: {
        std.debug.print("error: invalid older value '{s}' (expected e.g. 30d)\n", .{s});
        std.process.exit(1);
        break :blk null;
    } else null;

    const start_ms = std.time.milliTimestamp();
    const result = try scanner.scan(allocator, parsed.path, .{
        .follow_symlinks = parsed.follow_links,
        .cross_mount = parsed.cross_mount,
        .jobs = parsed.jobs,
        .apparent = parsed.apparent,
    });
    const elapsed_ms = std.time.milliTimestamp() - start_ms;

    // 現在時刻 (--older フィルタ用)
    const now_sec: i64 = @divTrunc(std.time.milliTimestamp(), 1000);

    // フィルタリングされた DirEntry ツリーを構築する
    const filtered_root = try filterTree(
        allocator,
        &result.root,
        parsed.excludePatterns(),
        parsed.onlyPatterns(),
        min_size,
        max_size,
        older_days,
        now_sec,
    );

    // --assert-max: 閾値を超えた場合は exit 1
    if (parsed.assert_max_str) |ams| {
        const assert_max = size_fmt.parse(ams) catch {
            std.debug.print("error: invalid size value '{s}'\n", .{ams});
            std.process.exit(1);
        };
        if (filtered_root.total_size > assert_max) {
            var actual_buf: [16]u8 = undefined;
            var limit_buf: [16]u8 = undefined;
            std.debug.print("error: size {s} exceeds limit {s}\n", .{
                size_fmt.fmt(&actual_buf, filtered_root.total_size),
                size_fmt.fmt(&limit_buf, assert_max),
            });
            std.process.exit(1);
        }
        return;
    }

    // --compare: スナップショットと比較表示
    if (parsed.compare_path) |cp| {
        const snap = snapshot.load(allocator, cp) catch |err| {
            std.debug.print("error: failed to load snapshot '{s}': {s}\n", .{ cp, @errorName(err) });
            std.process.exit(1);
        };
        var out: std.ArrayList(u8) = .{};
        defer out.deinit(allocator);
        try compare_render.render(out.writer(allocator), allocator, &filtered_root, &snap);
        try std.fs.File.stdout().writeAll(out.items);
        return;
    }

    // --save: JSON スナップショットをファイルに保存
    if (parsed.save_path) |sp| {
        try snapshot.save(allocator, &filtered_root, parsed.path, elapsed_ms, sp);
        return;
    }

    // --json: JSON 形式で stdout へ出力
    if (parsed.json) {
        var out: std.ArrayList(u8) = .{};
        defer out.deinit(allocator);
        try json_export.render(out.writer(allocator), allocator, &filtered_root, .{
            .root_path = parsed.path,
            .scan_time_ms = elapsed_ms,
        });
        try std.fs.File.stdout().writeAll(out.items);
        return;
    }

    // --csv: CSV 形式で stdout へ出力
    if (parsed.csv) {
        var out: std.ArrayList(u8) = .{};
        defer out.deinit(allocator);
        try csv_export.render(out.writer(allocator), &filtered_root, .{
            .root_path = parsed.path,
        });
        try std.fs.File.stdout().writeAll(out.items);
        return;
    }

    // -i / --interactive: TUIモード
    if (parsed.interactive) {
        try tui.run(allocator, &filtered_root);
        return;
    }

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);

    if (parsed.flat) {
        try flat.render(out.writer(allocator), allocator, &filtered_root, .{
            .top = parsed.top,
        }, elapsed_ms);
    } else {
        try tree.render(out.writer(allocator), &filtered_root, .{
            .depth = parsed.depth,
            .top = parsed.top,
            .color = true,
            .bar_width = 20,
        }, elapsed_ms);
    }

    try std.fs.File.stdout().writeAll(out.items);
}

/// DirEntry ツリーを再帰的にフィルタリングして新しいツリーを返す。
/// フィルタ条件にマッチしない子エントリを除外する。
fn filterTree(
    allocator: std.mem.Allocator,
    entry: *const types.DirEntry,
    exclude_patterns: []const []const u8,
    only_patterns: []const []const u8,
    min_size: ?u64,
    max_size: ?u64,
    older_days: ?u32,
    now_sec: i64,
) !types.DirEntry {
    var filtered: std.ArrayList(types.DirEntry) = .{};
    for (entry.children) |*child| {
        const name = child.nameSlice();

        // --exclude: マッチしたら除外
        if (exclude_patterns.len > 0 and pattern_filter.matchAny(exclude_patterns, name)) {
            continue;
        }
        // --only: マッチしなければ除外
        if (only_patterns.len > 0 and !pattern_filter.matchAny(only_patterns, name)) {
            // only フィルタは子ノードをスキップするが、孫以降は個別評価のため再帰は続ける
            const sub = try filterTree(allocator, child, exclude_patterns, only_patterns, min_size, max_size, older_days, now_sec);
            if (sub.children.len > 0) {
                try filtered.append(allocator, sub);
            }
            continue;
        }
        // --min / --max: サイズフィルタ
        if (!size_filter.matchSize(child.total_size, min_size, max_size)) {
            continue;
        }
        // --older: 日付フィルタ
        if (!age_filter.matchOlder(child.mtime, now_sec, older_days)) {
            continue;
        }

        const sub = try filterTree(allocator, child, exclude_patterns, only_patterns, min_size, max_size, older_days, now_sec);
        try filtered.append(allocator, sub);
    }

    return types.DirEntry{
        .name = entry.name,
        .name_len = entry.name_len,
        .total_size = entry.total_size,
        .file_count = entry.file_count,
        .dir_count = entry.dir_count,
        .children = try filtered.toOwnedSlice(allocator),
        .depth = entry.depth,
        .mtime = entry.mtime,
    };
}

test "main compiles" {
    // placeholder test to satisfy `zig build test`
}
