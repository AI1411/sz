const std = @import("std");
const posix = std.posix;
const types = @import("types.zig");

pub const ScanOptions = struct {
    /// シンボリックリンクを追跡するか（デフォルト: 追跡しない）
    follow_symlinks: bool = false,
    /// マウントポイントを越えてスキャンするか（デフォルト: 越えない）
    cross_mount: bool = false,
};

fn getDeviceId(dir: std.fs.Dir) !posix.dev_t {
    const stat = try posix.fstat(dir.fd);
    return stat.dev;
}

fn scanDirRecursive(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    name: []const u8,
    depth: u8,
    root_dev: posix.dev_t,
    options: ScanOptions,
) !types.DirEntry {
    var total_size: u64 = 0;
    var file_count: u32 = 0;
    var dir_count: u32 = 0;
    var children: std.ArrayList(types.DirEntry) = .{};

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .sym_link => {
                // シンボリックリンクはデフォルトで追跡しない
                if (!options.follow_symlinks) continue;
            },
            .directory => {
                var child_dir = dir.openDir(entry.name, .{
                    .iterate = true,
                    .no_follow = true,
                }) catch |err| switch (err) {
                    error.AccessDenied => {
                        var warn_buf: [512]u8 = undefined;
                        const warn_msg = std.fmt.bufPrint(
                            &warn_buf,
                            "sz: warning: cannot access '{s}': permission denied\n",
                            .{entry.name},
                        ) catch "sz: warning: permission denied\n";
                        std.fs.File.stderr().writeAll(warn_msg) catch {};
                        continue;
                    },
                    else => continue,
                };
                defer child_dir.close();

                // マウントポイントの境界を越えない
                if (!options.cross_mount) {
                    const child_dev = getDeviceId(child_dir) catch continue;
                    if (child_dev != root_dev) continue;
                }

                dir_count += 1;

                const next_depth: u8 = if (depth < 255) depth + 1 else 255;
                const child = try scanDirRecursive(
                    allocator,
                    child_dir,
                    entry.name,
                    next_depth,
                    root_dev,
                    options,
                );
                total_size += child.total_size;
                file_count += child.file_count;
                dir_count += child.dir_count;
                try children.append(allocator, child);
            },
            .file => {
                const stat = dir.statFile(entry.name) catch continue;
                total_size += stat.size;
                file_count += 1;
            },
            else => {},
        }
    }

    const name_copy = try allocator.dupe(u8, name);

    return types.DirEntry{
        .name = name_copy.ptr,
        .name_len = @intCast(name_copy.len),
        .total_size = total_size,
        .file_count = file_count,
        .dir_count = dir_count,
        .children = try children.toOwnedSlice(allocator),
        .depth = depth,
    };
}

/// 指定パスのディレクトリを再帰的にスキャンする。
/// メモリは呼び出し側の allocator で管理する。
pub fn scan(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: ScanOptions,
) !types.ScanResult {
    var root_dir = if (std.fs.path.isAbsolute(path))
        try std.fs.openDirAbsolute(path, .{ .iterate = true, .no_follow = true })
    else
        try std.fs.cwd().openDir(path, .{ .iterate = true, .no_follow = true });
    defer root_dir.close();

    const root_dev = try getDeviceId(root_dir);
    const basename = std.fs.path.basename(path);
    const root_name = if (basename.len == 0) "." else basename;

    const root = try scanDirRecursive(
        allocator,
        root_dir,
        root_name,
        0,
        root_dev,
        options,
    );

    return types.ScanResult{ .root = root };
}

// ─── tests ───────────────────────────────────────────────────────────────────

test "scan: recursive scan and size aggregation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // file1.txt = 5 bytes
    {
        const f = try tmp.dir.createFile("file1.txt", .{});
        defer f.close();
        try f.writeAll("hello");
    }
    // file2.txt = 10 bytes
    {
        const f = try tmp.dir.createFile("file2.txt", .{});
        defer f.close();
        try f.writeAll("0123456789");
    }
    // subdir/file3.txt = 7 bytes
    try tmp.dir.makeDir("subdir");
    {
        var sub = try tmp.dir.openDir("subdir", .{});
        defer sub.close();
        const f = try sub.createFile("file3.txt", .{});
        defer f.close();
        try f.writeAll("abcdefg");
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath(".", &path_buf);

    const result = try scan(arena.allocator(), path, .{});
    try std.testing.expectEqual(@as(u64, 22), result.root.total_size);
    try std.testing.expectEqual(@as(u32, 3), result.root.file_count);
    try std.testing.expectEqual(@as(u32, 1), result.root.dir_count);
    try std.testing.expectEqual(@as(u8, 0), result.root.depth);
    try std.testing.expectEqual(@as(usize, 1), result.root.children.len);
    try std.testing.expectEqualStrings("subdir", result.root.children[0].nameSlice());
    try std.testing.expectEqual(@as(u8, 1), result.root.children[0].depth);
    try std.testing.expectEqual(@as(u64, 7), result.root.children[0].total_size);
}

test "scan: symlinks not followed by default" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("real.txt", .{});
        defer f.close();
        try f.writeAll("data");
    }
    // symlink pointing to real.txt
    try tmp.dir.symLink("real.txt", "link.txt", .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath(".", &path_buf);

    const result = try scan(arena.allocator(), path, .{});
    // symlink should not be counted
    try std.testing.expectEqual(@as(u32, 1), result.root.file_count);
    try std.testing.expectEqual(@as(u64, 4), result.root.total_size);
}

test "scan: permission denied directory is skipped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("visible.txt", .{});
        defer f.close();
        try f.writeAll("ok");
    }
    try tmp.dir.makeDir("noaccess");
    {
        var sub = try tmp.dir.openDir("noaccess", .{});
        defer sub.close();
        const f = try sub.createFile("hidden.txt", .{});
        defer f.close();
        try f.writeAll("secret");
    }

    // Remove read+execute permission from noaccess
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath("noaccess", &path_buf);
    try std.posix.fchmodat(std.posix.AT.FDCWD, dir_path, 0o000, 0);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root_path = try tmp.dir.realpath(".", &path_buf);
    const result = try scan(arena.allocator(), root_path, .{});

    // Restore permissions for cleanup
    try std.posix.fchmodat(std.posix.AT.FDCWD, dir_path, 0o755, 0);

    // noaccess dir is counted in dir_count, its contents are skipped
    try std.testing.expectEqual(@as(u32, 1), result.root.file_count);
    try std.testing.expectEqual(@as(u64, 2), result.root.total_size);
}
