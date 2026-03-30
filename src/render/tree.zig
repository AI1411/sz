const std = @import("std");
const types = @import("types");
const size_fmt = @import("size_fmt");
const bar = @import("bar");

pub const RenderOptions = struct {
    /// 表示する最大深さ（デフォルト: 3）
    depth: u32 = 3,
    /// 各ディレクトリで表示する最大エントリ数（デフォルト: 10）
    top: u32 = 10,
    /// カラー出力を使うか（デフォルト: true）
    color: bool = true,
    /// バーの文字数（デフォルト: 20）
    bar_width: usize = 20,
};

// ツリー描画用のプレフィックス文字列
// NOTE: "│   " は U+2502(3バイト) + スペース3文字 = 6バイト
//       "├── " は U+251C(3) + U+2500(3) + U+2500(3) + スペース(1) = 10バイト
//       "└── " は U+2514(3) + U+2500(3) + U+2500(3) + スペース(1) = 10バイト
const PREFIX_VERT = "│   ";
const PREFIX_NONE = "    ";
const CONNECTOR_MID = "├── ";
const CONNECTOR_LAST = "└── ";

/// DirEntry ツリーをライターにレンダリングする。
/// scan_time_ms: スキャンにかかった時間(ms)。フッターに表示される。
pub fn render(
    writer: anytype,
    root: *const types.DirEntry,
    opts: RenderOptions,
    scan_time_ms: i64,
) !void {
    // ルートエントリを表示（コネクタなし）
    var size_buf: [16]u8 = undefined;
    const size_str = size_fmt.fmt(&size_buf, root.total_size);
    try writer.print("  {s:>7}  {s}\n", .{ size_str, root.nameSlice() });

    // 子エントリを再帰的に表示
    // prefix_buf: 各深さのインデントを蓄積するバッファ（最大深さ255 × 最大6バイト = 1530バイト）
    var prefix_buf: [2048]u8 = undefined;
    try renderChildren(writer, root, &prefix_buf, 0, 0, opts);

    // フッター: ファイル数・ディレクトリ数・スキャン時間
    try writer.print("\n  {d} files, {d} dirs, {d}ms\n", .{
        root.file_count,
        root.dir_count,
        scan_time_ms,
    });
}

fn renderEntry(
    writer: anytype,
    entry: *const types.DirEntry,
    parent_size: u64,
    prefix: []const u8,
    is_last: bool,
    opts: RenderOptions,
) !void {
    const connector = if (is_last) CONNECTOR_LAST else CONNECTOR_MID;
    var size_buf: [16]u8 = undefined;
    const size_str = size_fmt.fmt(&size_buf, entry.total_size);
    const ratio = if (parent_size > 0)
        @as(f64, @floatFromInt(entry.total_size)) / @as(f64, @floatFromInt(parent_size))
    else
        0.0;

    try writer.print("  {s}{s}{s:>7}  {s}  ", .{
        prefix,
        connector,
        size_str,
        entry.nameSlice(),
    });
    try bar.draw(writer, ratio, opts.bar_width);
    try writer.writeByte('\n');
}

fn renderChildren(
    writer: anytype,
    parent: *const types.DirEntry,
    prefix_buf: *[2048]u8,
    prefix_len: usize,
    depth: u32,
    opts: RenderOptions,
) !void {
    if (depth >= opts.depth) return;

    const children = parent.children;
    if (children.len == 0) return;

    const show_count: usize = @min(children.len, @as(usize, opts.top));
    const has_others = children.len > show_count;

    for (0..show_count) |i| {
        const child = &children[i];
        const is_last = (i == show_count - 1) and !has_others;

        try renderEntry(writer, child, parent.total_size, prefix_buf[0..prefix_len], is_last, opts);

        // 子エントリが存在し、深さ制限に達していなければ再帰
        if (depth + 1 < opts.depth) {
            const cont = if (is_last) PREFIX_NONE else PREFIX_VERT;
            const new_len = prefix_len + cont.len;
            if (new_len <= prefix_buf.len) {
                std.mem.copyForwards(u8, prefix_buf[prefix_len..][0..cont.len], cont);
                try renderChildren(writer, child, prefix_buf, new_len, depth + 1, opts);
            }
        }
    }

    // --top を超えたエントリを「(N others)」として集約表示（Issue #10）
    if (has_others) {
        const others_count = children.len - show_count;
        var others_size: u64 = 0;
        for (children[show_count..]) |child| {
            others_size += child.total_size;
        }

        var size_buf: [16]u8 = undefined;
        const size_str = size_fmt.fmt(&size_buf, others_size);
        const ratio = if (parent.total_size > 0)
            @as(f64, @floatFromInt(others_size)) / @as(f64, @floatFromInt(parent.total_size))
        else
            0.0;

        var name_buf: [64]u8 = undefined;
        const name_str = std.fmt.bufPrint(&name_buf, "({d} others)", .{others_count}) catch "(others)";

        try writer.print("  {s}{s}{s:>7}  {s}  ", .{
            prefix_buf[0..prefix_len],
            CONNECTOR_LAST,
            size_str,
            name_str,
        });
        try bar.draw(writer, ratio, opts.bar_width);
        try writer.writeByte('\n');
    }
}

// ─── tests ───────────────────────────────────────────────────────────────────

fn makeEntry(name: []const u8, total_size: u64, children: []types.DirEntry) types.DirEntry {
    return types.DirEntry{
        .name = name.ptr,
        .name_len = @intCast(name.len),
        .total_size = total_size,
        .file_count = 0,
        .dir_count = 0,
        .children = children,
        .depth = 0,
    };
}

test "render: root only (no children)" {
    const root = makeEntry(".", 1024, &.{});

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try render(fbs.writer(), &root, .{ .depth = 3, .top = 10, .color = false, .bar_width = 4 }, 0);

    const out = fbs.getWritten();
    // ルート行の存在確認
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "1.0 KB"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "."));
    // フッターの存在確認
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "0 files"));
}

test "render: children are shown with connectors" {
    var children = [_]types.DirEntry{
        makeEntry("alpha", 512, &.{}),
        makeEntry("beta", 256, &.{}),
    };
    const root = makeEntry(".", 768, &children);

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try render(fbs.writer(), &root, .{ .depth = 3, .top = 10, .color = false, .bar_width = 4 }, 10);

    const out = fbs.getWritten();
    // ├── が alpha に使われ、└── が beta（最後）に使われる
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "├──"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "└──"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "alpha"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "beta"));
}

test "render: depth=1 does not recurse" {
    var grandchildren = [_]types.DirEntry{
        makeEntry("grandchild", 128, &.{}),
    };
    var children = [_]types.DirEntry{
        makeEntry("child", 256, &grandchildren),
    };
    const root = makeEntry(".", 384, &children);

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try render(fbs.writer(), &root, .{ .depth = 1, .top = 10, .color = false, .bar_width = 4 }, 0);

    const out = fbs.getWritten();
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "child"));
    // grandchild は depth=1 なので表示されない
    try std.testing.expect(!std.mem.containsAtLeast(u8, out, 1, "grandchild"));
}

test "render: top=1 shows others aggregate" {
    var children = [_]types.DirEntry{
        makeEntry("big", 600, &.{}),
        makeEntry("med", 300, &.{}),
        makeEntry("small", 100, &.{}),
    };
    const root = makeEntry(".", 1000, &children);

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try render(fbs.writer(), &root, .{ .depth = 3, .top = 1, .color = false, .bar_width = 4 }, 0);

    const out = fbs.getWritten();
    // top=1 なので "big" だけ個別表示、残りは "(2 others)" に集約
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "big"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "(2 others)"));
    // med と small は個別には表示されない
    try std.testing.expect(!std.mem.containsAtLeast(u8, out, 1, "med"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, out, 1, "small"));
}

test "render: others aggregate size is correct" {
    var children = [_]types.DirEntry{
        makeEntry("a", 500, &.{}),
        makeEntry("b", 300, &.{}),
        makeEntry("c", 200, &.{}),
    };
    const root = makeEntry(".", 1000, &children);

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try render(fbs.writer(), &root, .{ .depth = 3, .top = 1, .color = false, .bar_width = 4 }, 0);

    const out = fbs.getWritten();
    // others = 300 + 200 = 500 bytes
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "500 B"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "(2 others)"));
}

test "render: footer contains file/dir counts and scan time" {
    const root = makeEntry(".", 0, &.{});

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try render(fbs.writer(), &root, .{}, 42);

    const out = fbs.getWritten();
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "0 files"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "0 dirs"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "42ms"));
}
