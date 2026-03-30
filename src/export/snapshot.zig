const std = @import("std");
const types = @import("types");
const json_export = @import("json.zig");

/// スキャン結果を JSON スナップショットファイルとして保存する。
/// `path` が "-" の場合は stdout へ出力する。
pub fn save(
    allocator: std.mem.Allocator,
    root: *const types.DirEntry,
    root_path: []const u8,
    scan_time_ms: i64,
    save_path: []const u8,
) !void {
    const opts = json_export.JsonOptions{
        .root_path = root_path,
        .scan_time_ms = scan_time_ms,
    };

    if (std.mem.eql(u8, save_path, "-")) {
        var out: std.ArrayList(u8) = .{};
        defer out.deinit(allocator);
        try json_export.render(out.writer(allocator), allocator, root, opts);
        try std.fs.File.stdout().writeAll(out.items);
        return;
    }

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    try json_export.render(out.writer(allocator), allocator, root, opts);

    const file = try std.fs.cwd().createFile(save_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(out.items);
}

// ─── tests ───────────────────────────────────────────────────────────────────

test "save: writes valid JSON snapshot to file" {
    const root_name = "project";
    const child_name = "src";
    const child = types.DirEntry{
        .name = child_name.ptr,
        .name_len = @intCast(child_name.len),
        .total_size = 4096,
        .file_count = 10,
        .dir_count = 2,
        .children = &.{},
        .depth = 1,
    };
    var children = [_]types.DirEntry{child};
    const root = types.DirEntry{
        .name = root_name.ptr,
        .name_len = @intCast(root_name.len),
        .total_size = 8192,
        .file_count = 15,
        .dir_count = 3,
        .children = &children,
        .depth = 0,
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const snap_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(snap_path);

    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_buf, "{s}/snapshot.json", .{snap_path});

    try save(std.testing.allocator, &root, "/home/user/project", 30, full_path);

    // ファイルが存在し、JSON が有効であることを確認
    const content = try std.fs.cwd().readFileAlloc(std.testing.allocator, full_path, 1024 * 1024);
    defer std.testing.allocator.free(content);

    try std.testing.expect(content.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"root\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"entries\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"src\"") != null);
}
