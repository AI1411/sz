/// compare.zig - スナップショット比較レンダラー (Issue #37)
///
/// 現在のスキャン結果と保存済みスナップショットを比較し、
/// 増減・NEW・DELETED を表示する。
const std = @import("std");
const types = @import("types");
const size_fmt = @import("size_fmt");
const snapshot_mod = @import("snapshot");

/// 変化の種類
const ChangeKind = enum {
    increased,
    decreased,
    unchanged,
    new,
    deleted,
};

/// 比較結果の1行分
const CompareRow = struct {
    name: []const u8,
    current_size: u64,
    prev_size: u64,
    kind: ChangeKind,
};

/// 差分サイズを "+1.2 MB" / "-500 KB" 形式の文字列として buf に書き込む。
/// 戻り値は buf のスライス。
fn fmtDiff(buf: []u8, diff: i64) []const u8 {
    const abs: u64 = if (diff >= 0) @intCast(diff) else @intCast(-diff);
    var abs_buf: [16]u8 = undefined;
    const abs_str = size_fmt.fmt(&abs_buf, abs);
    const sign: u8 = if (diff >= 0) '+' else '-';
    return std.fmt.bufPrint(buf, "{c}{s}", .{ sign, abs_str }) catch buf[0..0];
}

/// 変化率を "+34.2%" / "-15.0%" 形式の文字列として buf に書き込む。
fn fmtPct(buf: []u8, diff: i64, prev: u64) []const u8 {
    if (prev == 0) return std.fmt.bufPrint(buf, "N/A", .{}) catch "N/A";
    const pct = @as(f64, @floatFromInt(@as(i64, @intCast(if (diff >= 0) diff else -diff)))) /
        @as(f64, @floatFromInt(prev)) * 100.0;
    const sign: u8 = if (diff >= 0) '+' else '-';
    return std.fmt.bufPrint(buf, "{c}{d:.1}%", .{ sign, pct }) catch buf[0..0];
}

/// 現在のスキャン結果とスナップショットを比較して差分テーブルを出力する。
pub fn render(
    writer: anytype,
    allocator: std.mem.Allocator,
    current: *const types.DirEntry,
    snap: *const snapshot_mod.Snapshot,
) !void {
    // スナップショットのエントリを path → size のマップに変換
    var snap_map = std.StringHashMap(u64).init(allocator);
    defer snap_map.deinit();
    for (snap.entries) |e| {
        try snap_map.put(e.path, e.size);
    }

    // 現在のエントリを name → size のマップに変換
    var cur_map = std.StringHashMap(u64).init(allocator);
    defer cur_map.deinit();
    for (current.children) |*child| {
        try cur_map.put(child.nameSlice(), child.total_size);
    }

    // ヘッダー: ルートパス、合計サイズ、差分
    var root_size_buf: [16]u8 = undefined;
    const root_size_str = size_fmt.fmt(&root_size_buf, current.total_size);

    const total_diff: i64 = @as(i64, @intCast(current.total_size)) -
        @as(i64, @intCast(snap.total_size));
    var diff_buf: [32]u8 = undefined;
    const diff_str = fmtDiff(&diff_buf, total_diff);

    try writer.print("  {s}  ·  {s} ({s} since snapshot)\n\n", .{
        current.nameSlice(),
        root_size_str,
        diff_str,
    });

    // テーブルヘッダー
    try writer.writeAll("  CHANGE      SIZE        DIFF        NAME\n");
    try writer.writeAll("  ─────────────────────────────────────────────────────\n");

    // 現在のエントリを出力（NEW + 変化）
    for (current.children) |*child| {
        const name = child.nameSlice();
        var size_buf: [16]u8 = undefined;
        const size_str = size_fmt.fmt(&size_buf, child.total_size);

        if (snap_map.get(name)) |prev_size| {
            const diff: i64 = @as(i64, @intCast(child.total_size)) - @as(i64, @intCast(prev_size));
            var diff_row_buf: [32]u8 = undefined;
            const diff_row_str = fmtDiff(&diff_row_buf, diff);

            if (diff == 0) {
                try writer.print("  {s:<10}  {s:>9}  {s:>10}  {s}\n", .{
                    "unchanged", size_str, diff_row_str, name,
                });
            } else {
                var pct_buf: [16]u8 = undefined;
                const pct_str = fmtPct(&pct_buf, diff, prev_size);
                try writer.print("  {s:<10}  {s:>9}  {s:>10}  {s}\n", .{
                    pct_str, size_str, diff_row_str, name,
                });
            }
        } else {
            // スナップショットに存在しない → NEW
            var new_diff_buf: [32]u8 = undefined;
            const new_diff_str = fmtDiff(&new_diff_buf, @intCast(child.total_size));
            try writer.print("  {s:<10}  {s:>9}  {s:>10}  {s}\n", .{
                "NEW", size_str, new_diff_str, name,
            });
        }
    }

    // DELETED: スナップショットにあるが現在のスキャンにないエントリ
    var snap_iter = snap_map.iterator();
    while (snap_iter.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!cur_map.contains(name)) {
            const prev_size = entry.value_ptr.*;
            const del_diff: i64 = -@as(i64, @intCast(prev_size));
            var del_diff_buf: [32]u8 = undefined;
            const del_diff_str = fmtDiff(&del_diff_buf, del_diff);
            try writer.print("  {s:<10}  {s:>9}  {s:>10}  {s}\n", .{
                "DELETED", "---", del_diff_str, name,
            });
        }
    }
}

// ─── tests ───────────────────────────────────────────────────────────────────

test "render: compare shows NEW and unchanged entries" {
    const root_name = "project";
    const child1_name = "node_modules";
    const child2_name = "src";
    const child1 = types.DirEntry{
        .name = child1_name.ptr,
        .name_len = @intCast(child1_name.len),
        .total_size = 512 * 1024 * 1024,
        .file_count = 1000,
        .dir_count = 50,
        .children = &.{},
        .depth = 1,
    };
    const child2 = types.DirEntry{
        .name = child2_name.ptr,
        .name_len = @intCast(child2_name.len),
        .total_size = 10 * 1024 * 1024,
        .file_count = 100,
        .dir_count = 10,
        .children = &.{},
        .depth = 1,
    };
    var children = [_]types.DirEntry{ child1, child2 };
    const root = types.DirEntry{
        .name = root_name.ptr,
        .name_len = @intCast(root_name.len),
        .total_size = 522 * 1024 * 1024,
        .file_count = 1100,
        .dir_count = 60,
        .children = &children,
        .depth = 0,
    };

    // スナップショット: node_modules のみ存在
    const snap_entries = [_]snapshot_mod.SnapshotEntry{
        .{ .path = "node_modules", .size = 512 * 1024 * 1024, .children = &.{} },
    };
    const snap = snapshot_mod.Snapshot{
        .root_path = "/home/user/project",
        .total_size = 512 * 1024 * 1024,
        .entries = @constCast(&snap_entries),
    };

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);

    try render(buf.writer(std.testing.allocator), std.testing.allocator, &root, &snap);

    const output = buf.items;
    // node_modules は unchanged (同サイズ)
    try std.testing.expect(std.mem.indexOf(u8, output, "unchanged") != null);
    // src は NEW
    try std.testing.expect(std.mem.indexOf(u8, output, "NEW") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "src") != null);
}

test "render: compare shows DELETED entries" {
    const root_name = "project";
    const root = types.DirEntry{
        .name = root_name.ptr,
        .name_len = @intCast(root_name.len),
        .total_size = 0,
        .file_count = 0,
        .dir_count = 0,
        .children = &.{},
        .depth = 0,
    };

    // スナップショット: tmp が存在
    const snap_entries = [_]snapshot_mod.SnapshotEntry{
        .{ .path = "tmp", .size = 1024 * 1024, .children = &.{} },
    };
    const snap = snapshot_mod.Snapshot{
        .root_path = "/home/user/project",
        .total_size = 1024 * 1024,
        .entries = @constCast(&snap_entries),
    };

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);

    try render(buf.writer(std.testing.allocator), std.testing.allocator, &root, &snap);

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "DELETED") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "tmp") != null);
}
