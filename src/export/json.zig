const std = @import("std");
const types = @import("types");

/// JSON 出力オプション
pub const JsonOptions = struct {
    /// スキャン対象ルートパス
    root_path: []const u8,
    /// スキャン所要時間 (ms)
    scan_time_ms: i64,
};

/// DirEntry ツリーを JSON 形式で writer に出力する。
pub fn render(
    writer: anytype,
    allocator: std.mem.Allocator,
    root: *const types.DirEntry,
    opts: JsonOptions,
) !void {
    _ = allocator;
    try writer.writeAll("{\n");
    try writer.print("  \"root\": \"{s}\",\n", .{opts.root_path});
    try writer.print("  \"total_size\": {d},\n", .{root.total_size});
    try writer.print("  \"total_files\": {d},\n", .{root.file_count});
    try writer.print("  \"total_dirs\": {d},\n", .{root.dir_count});
    try writer.print("  \"scan_time_ms\": {d},\n", .{opts.scan_time_ms});
    try writer.writeAll("  \"entries\": ");
    try renderEntries(writer, root, root.total_size, 1);
    try writer.writeAll("\n}\n");
}

fn renderEntries(
    writer: anytype,
    entry: *const types.DirEntry,
    total_size: u64,
    indent: u32,
) !void {
    try writer.writeAll("[\n");
    for (entry.children, 0..) |*child, i| {
        try writeIndent(writer, indent + 1);
        try writer.writeAll("{\n");

        const pct: f64 = if (total_size > 0)
            @as(f64, @floatFromInt(child.total_size)) / @as(f64, @floatFromInt(total_size)) * 100.0
        else
            0.0;

        try writeIndent(writer, indent + 2);
        try writer.print("\"path\": \"{s}\",\n", .{child.nameSlice()});
        try writeIndent(writer, indent + 2);
        try writer.print("\"size\": {d},\n", .{child.total_size});
        try writeIndent(writer, indent + 2);
        try writer.print("\"percentage\": {d:.1},\n", .{pct});
        try writeIndent(writer, indent + 2);
        try writer.print("\"files\": {d},\n", .{child.file_count});
        try writeIndent(writer, indent + 2);
        try writer.print("\"dirs\": {d},\n", .{child.dir_count});
        try writeIndent(writer, indent + 2);
        try writer.writeAll("\"children\": ");
        if (child.children.len > 0) {
            try renderEntries(writer, child, child.total_size, indent + 2);
        } else {
            try writer.writeAll("[]");
        }
        try writer.writeByte('\n');

        try writeIndent(writer, indent + 1);
        if (i + 1 < entry.children.len) {
            try writer.writeAll("},\n");
        } else {
            try writer.writeAll("}\n");
        }
    }
    try writeIndent(writer, indent);
    try writer.writeByte(']');
}

fn writeIndent(writer: anytype, level: u32) !void {
    var i: u32 = 0;
    while (i < level) : (i += 1) {
        try writer.writeAll("  ");
    }
}

// ─── tests ───────────────────────────────────────────────────────────────────

test "render: empty root produces valid JSON" {
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

    try render(buf.writer(std.testing.allocator), std.testing.allocator, &root, .{
        .root_path = "/tmp/test",
        .scan_time_ms = 5,
    });

    const json = buf.items;
    // 最低限の JSON フィールドが存在することを確認
    try std.testing.expect(std.mem.indexOf(u8, json, "\"root\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total_size\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total_files\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total_dirs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scan_time_ms\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"entries\"") != null);
}

test "render: child entry appears in JSON output" {
    const root_name = "root";
    const child_name = "node_modules";
    const child = types.DirEntry{
        .name = child_name.ptr,
        .name_len = @intCast(child_name.len),
        .total_size = 512 * 1024 * 1024,
        .file_count = 1000,
        .dir_count = 50,
        .children = &.{},
        .depth = 1,
    };
    var children = [_]types.DirEntry{child};
    const root = types.DirEntry{
        .name = root_name.ptr,
        .name_len = @intCast(root_name.len),
        .total_size = 1024 * 1024 * 1024,
        .file_count = 1200,
        .dir_count = 60,
        .children = &children,
        .depth = 0,
    };

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);

    try render(buf.writer(std.testing.allocator), std.testing.allocator, &root, .{
        .root_path = "/home/user",
        .scan_time_ms = 42,
    });

    const json = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"node_modules\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"files\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"dirs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"percentage\"") != null);
}
