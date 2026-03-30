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

/// (dev, inode) を 128 ビットキーに変換してループ検出に使用する。
const InodeKey = u128;
fn inodeKey(dev: posix.dev_t, ino: posix.ino_t) InodeKey {
    // dev_t は macOS で i32, Linux で u64 など環境依存のため符号拡張してから u64 に変換する
    const dev64: u64 = @bitCast(@as(i64, dev));
    const ino64: u64 = @intCast(ino);
    return (@as(u128, dev64) << 64) | @as(u128, ino64);
}

fn scanDirRecursive(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    name: []const u8,
    depth: u8,
    root_dev: posix.dev_t,
    options: ScanOptions,
    visited: *std.AutoHashMap(InodeKey, void),
) !types.DirEntry {
    var total_size: u64 = 0;
    var file_count: u32 = 0;
    var dir_count: u32 = 0;
    var children: std.ArrayList(types.DirEntry) = .{};

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        var kind = entry.kind;

        // .unknown: d_type が返されないファイルシステム（NFS/FUSE など）のフォールバック。
        // Dir.statFile はシンボリックリンクを追跡するため、リンク先の種別が返る。
        if (kind == .unknown) {
            const st = dir.statFile(entry.name) catch continue;
            kind = st.kind;
        }

        switch (kind) {
            .sym_link => {
                // デフォルトではシンボリックリンクを追跡しない
                if (!options.follow_symlinks) continue;
                // statFile はリンクを追跡して実体の情報を返す
                const st = dir.statFile(entry.name) catch continue;
                switch (st.kind) {
                    .file => {
                        total_size += st.size;
                        file_count += 1;
                    },
                    .directory => {
                        // シンボリックリンクを辿ってディレクトリを開く
                        var child_dir = dir.openDir(entry.name, .{
                            .iterate = true,
                            .no_follow = false,
                        }) catch continue;
                        defer child_dir.close();

                        if (!options.cross_mount) {
                            const child_dev = getDeviceId(child_dir) catch continue;
                            if (child_dev != root_dev) continue;
                        }

                        // ループ検出: 既に訪問済みの inode はスキップ
                        const child_stat = posix.fstat(child_dir.fd) catch continue;
                        const key = inodeKey(child_stat.dev, child_stat.ino);
                        if (visited.contains(key)) {
                            var warn_buf: [512]u8 = undefined;
                            const warn_msg = std.fmt.bufPrint(
                                &warn_buf,
                                "sz: warning: symbolic link loop detected at '{s}'\n",
                                .{entry.name},
                            ) catch "sz: warning: symlink loop detected\n";
                            std.fs.File.stderr().writeAll(warn_msg) catch {};
                            continue;
                        }
                        try visited.put(key, {});

                        dir_count += 1;
                        const next_depth: u8 = if (depth < 255) depth + 1 else 255;
                        const child = try scanDirRecursive(allocator, child_dir, entry.name, next_depth, root_dev, options, visited);
                        total_size += child.total_size;
                        file_count += child.file_count;
                        dir_count += child.dir_count;
                        try children.append(allocator, child);
                    },
                    else => {},
                }
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
                const child = try scanDirRecursive(allocator, child_dir, entry.name, next_depth, root_dev, options, visited);
                total_size += child.total_size;
                file_count += child.file_count;
                dir_count += child.dir_count;
                try children.append(allocator, child);
            },
            .file => {
                const st = dir.statFile(entry.name) catch continue;
                total_size += st.size;
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
    // 相対パスは realpath で絶対化してから開く。
    // cwd().openDir(".", .{ .no_follow = true }) は macOS で FileNotFound になるため。
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try std.fs.cwd().realpath(path, &real_buf);

    var root_dir = try std.fs.openDirAbsolute(real_path, .{ .iterate = true, .no_follow = true });
    defer root_dir.close();

    const root_stat = try posix.fstat(root_dir.fd);
    const root_dev = root_stat.dev;
    const basename = std.fs.path.basename(real_path);
    const root_name = if (basename.len == 0) "." else basename;

    // visited inode セット: ループ検出用。Arena allocator を共有する。
    var visited = std.AutoHashMap(InodeKey, void).init(allocator);
    defer visited.deinit();
    try visited.put(inodeKey(root_stat.dev, root_stat.ino), {});

    const root = try scanDirRecursive(
        allocator,
        root_dir,
        root_name,
        0,
        root_dev,
        options,
        &visited,
    );

    return types.ScanResult{ .root = root };
}

// ─── tests ───────────────────────────────────────────────────────────────────

test "scan: recursive scan and size aggregation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("file1.txt", .{});
        defer f.close();
        try f.writeAll("hello");
    }
    {
        const f = try tmp.dir.createFile("file2.txt", .{});
        defer f.close();
        try f.writeAll("0123456789");
    }
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
    try tmp.dir.symLink("real.txt", "link.txt", .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath(".", &path_buf);

    const result = try scan(arena.allocator(), path, .{});
    try std.testing.expectEqual(@as(u32, 1), result.root.file_count);
    try std.testing.expectEqual(@as(u64, 4), result.root.total_size);
}

test "scan: follow_symlinks=true counts symlinked file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("real.txt", .{});
        defer f.close();
        try f.writeAll("12345"); // 5 bytes
    }
    try tmp.dir.symLink("real.txt", "link.txt", .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath(".", &path_buf);

    // follow_symlinks=false: only real.txt counted
    const result_no = try scan(arena.allocator(), path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 1), result_no.root.file_count);
    try std.testing.expectEqual(@as(u64, 5), result_no.root.total_size);

    // follow_symlinks=true: real.txt + link.txt (both point to same 5-byte content)
    const result_yes = try scan(arena.allocator(), path, .{ .follow_symlinks = true });
    try std.testing.expectEqual(@as(u32, 2), result_yes.root.file_count);
    try std.testing.expectEqual(@as(u64, 10), result_yes.root.total_size);
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

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath("noaccess", &path_buf);
    try std.posix.fchmodat(std.posix.AT.FDCWD, dir_path, 0o000, 0);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root_path = try tmp.dir.realpath(".", &path_buf);
    const result = try scan(arena.allocator(), root_path, .{});

    try std.posix.fchmodat(std.posix.AT.FDCWD, dir_path, 0o755, 0);

    try std.testing.expectEqual(@as(u32, 1), result.root.file_count);
    try std.testing.expectEqual(@as(u64, 2), result.root.total_size);
}
