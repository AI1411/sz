const std = @import("std");
const types = @import("types");

/// CSV 出力オプション
pub const CsvOptions = struct {
    /// 親パスプレフィックス（先頭スラッシュ除去のため）
    root_path: []const u8 = ".",
};

/// DirEntry ツリーを CSV 形式で writer に出力する。
/// フォーマット: path,size_bytes,files,dirs,percentage
pub fn render(
    writer: anytype,
    root: *const types.DirEntry,
    opts: CsvOptions,
) !void {
    // ヘッダー行
    try writer.writeAll("path,size_bytes,files,dirs,percentage\n");
    // ルート直下の子から再帰的に出力
    try renderChildren(writer, root, opts.root_path, root.total_size);
}

fn renderChildren(
    writer: anytype,
    entry: *const types.DirEntry,
    parent_path: []const u8,
    total_size: u64,
) !void {
    for (entry.children) |*child| {
        const pct: f64 = if (total_size > 0)
            @as(f64, @floatFromInt(child.total_size)) / @as(f64, @floatFromInt(total_size)) * 100.0
        else
            0.0;

        // パスを "parent_path/name" 形式で組み立てる
        // スタック上のバッファで結合（最大 4096 バイト）
        var path_buf: [4096]u8 = undefined;
        const path = blk: {
            if (std.mem.eql(u8, parent_path, ".") or parent_path.len == 0) {
                break :blk try std.fmt.bufPrint(&path_buf, "./{s}", .{child.nameSlice()});
            } else {
                break :blk try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ parent_path, child.nameSlice() });
            }
        };

        try writer.print("{s},{d},{d},{d},{d:.1}\n", .{
            path,
            child.total_size,
            child.file_count,
            child.dir_count,
            pct,
        });

        if (child.children.len > 0) {
            try renderChildren(writer, child, path, total_size);
        }
    }
}

// ─── tests ───────────────────────────────────────────────────────────────────

test "render: header row present" {
    const root_name = "root";
    const root = types.DirEntry{
        .name = root_name.ptr,
        .name_len = @intCast(root_name.len),
        .total_size = 0,
        .file_count = 0,
        .dir_count = 0,
        .children = &.{},
        .depth = 0,
    };

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);

    try render(buf.writer(std.testing.allocator), &root, .{});

    const csv = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, csv, "path,size_bytes,files,dirs,percentage") != null);
}

test "render: child entry row is correct" {
    const root_name = "root";
    const child_name = "node_modules";
    const child = types.DirEntry{
        .name = child_name.ptr,
        .name_len = @intCast(child_name.len),
        .total_size = 510_656_512,
        .file_count = 8234,
        .dir_count = 1102,
        .children = &.{},
        .depth = 1,
    };
    var children = [_]types.DirEntry{child};
    const root = types.DirEntry{
        .name = root_name.ptr,
        .name_len = @intCast(root_name.len),
        .total_size = 1_270_000_000,
        .file_count = 10000,
        .dir_count = 1200,
        .children = &children,
        .depth = 0,
    };

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);

    try render(buf.writer(std.testing.allocator), &root, .{});

    const csv = buf.items;
    // ヘッダーが先頭行
    try std.testing.expect(std.mem.startsWith(u8, csv, "path,size_bytes,files,dirs,percentage\n"));
    // node_modules の行が存在する
    try std.testing.expect(std.mem.indexOf(u8, csv, "node_modules") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "510656512") != null);
}

test "render: percentage is computed" {
    const root_name = "root";
    const child_name = "big";
    const child = types.DirEntry{
        .name = child_name.ptr,
        .name_len = @intCast(child_name.len),
        .total_size = 500,
        .file_count = 5,
        .dir_count = 0,
        .children = &.{},
        .depth = 1,
    };
    var children = [_]types.DirEntry{child};
    const root = types.DirEntry{
        .name = root_name.ptr,
        .name_len = @intCast(root_name.len),
        .total_size = 1000,
        .file_count = 10,
        .dir_count = 1,
        .children = &children,
        .depth = 0,
    };

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);

    try render(buf.writer(std.testing.allocator), &root, .{});

    const csv = buf.items;
    // 50.0% が含まれる
    try std.testing.expect(std.mem.indexOf(u8, csv, "50.0") != null);
}
