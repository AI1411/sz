const std = @import("std");
const types = @import("types");
const json_export = @import("json_export");

/// スナップショットの1エントリ（パスとサイズのペア）。
pub const SnapshotEntry = struct {
    path: []const u8,
    size: u64,
    children: []SnapshotEntry,
};

/// 読み込んだスナップショットの全データ。
pub const Snapshot = struct {
    root_path: []const u8,
    total_size: u64,
    entries: []SnapshotEntry,
};

/// JSON スナップショットファイルをロードする。
/// allocator はアリーナを推奨（Snapshot の全フィールドはアリーナ管理）。
pub fn load(allocator: std.mem.Allocator, path: []const u8) !Snapshot {
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 512 * 1024 * 1024);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidSnapshot,
    };

    const root_val = obj.get("root") orelse return error.InvalidSnapshot;
    const root_path = try allocator.dupe(u8, switch (root_val) {
        .string => |s| s,
        else => return error.InvalidSnapshot,
    });

    const ts_val = obj.get("total_size") orelse return error.InvalidSnapshot;
    const total_size: u64 = switch (ts_val) {
        .integer => |n| if (n >= 0) @intCast(n) else return error.InvalidSnapshot,
        else => return error.InvalidSnapshot,
    };

    const entries_val = obj.get("entries") orelse return error.InvalidSnapshot;
    const entries_arr = switch (entries_val) {
        .array => |a| a,
        else => return error.InvalidSnapshot,
    };
    const entries = try parseSnapshotEntries(allocator, entries_arr.items);

    return Snapshot{
        .root_path = root_path,
        .total_size = total_size,
        .entries = entries,
    };
}

fn parseSnapshotEntries(allocator: std.mem.Allocator, items: []const std.json.Value) ![]SnapshotEntry {
    var list: std.ArrayList(SnapshotEntry) = .{};
    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const path_val = obj.get("path") orelse continue;
        const path = switch (path_val) {
            .string => |s| try allocator.dupe(u8, s),
            else => continue,
        };

        const size_val = obj.get("size") orelse continue;
        const size: u64 = switch (size_val) {
            .integer => |n| if (n >= 0) @intCast(n) else 0,
            else => 0,
        };

        var children: []SnapshotEntry = &.{};
        if (obj.get("children")) |c| {
            switch (c) {
                .array => |a| {
                    children = try parseSnapshotEntries(allocator, a.items);
                },
                else => {},
            }
        }

        try list.append(allocator, SnapshotEntry{
            .path = path,
            .size = size,
            .children = children,
        });
    }
    return list.toOwnedSlice(allocator);
}

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

test "load: reads snapshot saved by save()" {
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
    const full_path = try std.fmt.bufPrint(&full_buf, "{s}/snap.json", .{snap_path});

    try save(std.testing.allocator, &root, "/home/user/project", 42, full_path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const snap = try load(arena.allocator(), full_path);
    try std.testing.expectEqualStrings("/home/user/project", snap.root_path);
    try std.testing.expectEqual(@as(u64, 8192), snap.total_size);
    try std.testing.expectEqual(@as(usize, 1), snap.entries.len);
    try std.testing.expectEqualStrings("src", snap.entries[0].path);
    try std.testing.expectEqual(@as(u64, 4096), snap.entries[0].size);
}

test "load: invalid file returns error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const snap_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(snap_path);

    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_buf, "{s}/bad.json", .{snap_path});

    // not valid JSON snapshot
    const bad_file = try std.fs.cwd().createFile(full_path, .{});
    try bad_file.writeAll("{\"invalid\": true}");
    bad_file.close();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidSnapshot, load(arena.allocator(), full_path));
}
