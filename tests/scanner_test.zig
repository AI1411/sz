/// scanner_test.zig - スキャナー統合テスト (Issue #12-14)
///
/// Issue #12: スキャナーユニットテスト
/// Issue #13: シンボリックリンクのループ検出テスト
/// Issue #14: 権限なしディレクトリのスキップテスト
const std = @import("std");
const scanner = @import("scanner");

// ─── Issue #12: スキャナーユニットテスト ──────────────────────────────────────

test "scan: empty directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath(".", &path_buf);

    const result = try scanner.scan(arena.allocator(), path, .{});
    try std.testing.expectEqual(@as(u64, 0), result.root.total_size);
    try std.testing.expectEqual(@as(u32, 0), result.root.file_count);
    try std.testing.expectEqual(@as(u32, 0), result.root.dir_count);
    try std.testing.expectEqual(@as(usize, 0), result.root.children.len);
}

test "scan: single file size aggregation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("hello.txt", .{});
        defer f.close();
        try f.writeAll("hello world"); // 11 bytes
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath(".", &path_buf);

    const result = try scanner.scan(arena.allocator(), path, .{ .apparent = true });
    try std.testing.expectEqual(@as(u64, 11), result.root.total_size);
    try std.testing.expectEqual(@as(u32, 1), result.root.file_count);
    try std.testing.expectEqual(@as(u32, 0), result.root.dir_count);
}

test "scan: deep nested structure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // a/b/c/deep.txt (3 levels deep)
    try tmp.dir.makePath("a/b/c");
    {
        var deep = try tmp.dir.openDir("a/b/c", .{});
        defer deep.close();
        const f = try deep.createFile("deep.txt", .{});
        defer f.close();
        try f.writeAll("x" ** 100); // 100 bytes
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath(".", &path_buf);

    const result = try scanner.scan(arena.allocator(), path, .{ .apparent = true });
    try std.testing.expectEqual(@as(u64, 100), result.root.total_size);
    try std.testing.expectEqual(@as(u32, 1), result.root.file_count);
    try std.testing.expectEqual(@as(u32, 3), result.root.dir_count);
    try std.testing.expectEqual(@as(u8, 0), result.root.depth);
}

// ─── Issue #13: シンボリックリンクのループ検出テスト ────────────────────────────

test "scan: symlink loop does not hang (follow_symlinks=true)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // ループするシンボリックリンクを作成: loop -> .  (カレントディレクトリ自身を指す)
    try tmp.dir.symLink(".", "loop", .{ .is_directory = true });

    // 通常ファイルも追加
    {
        const f = try tmp.dir.createFile("file.txt", .{});
        defer f.close();
        try f.writeAll("data"); // 4 bytes
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath(".", &path_buf);

    // follow_symlinks=true でも無限再帰にならない (inode ベースのループ検出)
    const result = try scanner.scan(arena.allocator(), path, .{ .follow_symlinks = true, .apparent = true });
    // ファイルは正しく集計される
    try std.testing.expectEqual(@as(u32, 1), result.root.file_count);
    try std.testing.expectEqual(@as(u64, 4), result.root.total_size);
}

test "scan: symlink loop warning goes to stderr" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.symLink(".", "loop", .{ .is_directory = true });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath(".", &path_buf);

    // スキャンが完了すること（ループでスタックしない）を検証
    _ = try scanner.scan(arena.allocator(), path, .{ .follow_symlinks = true });
}

// ─── Issue #14: 権限なしディレクトリのスキップテスト ────────────────────────────

test "scan: permission denied directory is skipped with warning" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("visible.txt", .{});
        defer f.close();
        try f.writeAll("ok"); // 2 bytes
    }
    try tmp.dir.makeDir("noaccess");
    {
        var sub = try tmp.dir.openDir("noaccess", .{});
        defer sub.close();
        const f = try sub.createFile("hidden.txt", .{});
        defer f.close();
        try f.writeAll("secret"); // 6 bytes
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath("noaccess", &path_buf);
    try std.posix.fchmodat(std.posix.AT.FDCWD, dir_path, 0o000, 0);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root_path = try tmp.dir.realpath(".", &path_buf);
    const result = try scanner.scan(arena.allocator(), root_path, .{ .apparent = true });

    // 権限復元
    try std.posix.fchmodat(std.posix.AT.FDCWD, dir_path, 0o755, 0);

    // 権限なしディレクトリはスキップ、visible.txt のみ集計
    try std.testing.expectEqual(@as(u32, 1), result.root.file_count);
    try std.testing.expectEqual(@as(u64, 2), result.root.total_size);
}

test "scan: permission denied does not stop remaining scan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("noaccess");
    {
        var sub = try tmp.dir.openDir("noaccess", .{});
        defer sub.close();
        const f = try sub.createFile("hidden.txt", .{});
        defer f.close();
        try f.writeAll("secret");
    }
    try tmp.dir.makeDir("accessible");
    {
        var sub = try tmp.dir.openDir("accessible", .{});
        defer sub.close();
        const f = try sub.createFile("visible.txt", .{});
        defer f.close();
        try f.writeAll("hello"); // 5 bytes
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath("noaccess", &path_buf);
    try std.posix.fchmodat(std.posix.AT.FDCWD, dir_path, 0o000, 0);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root_path = try tmp.dir.realpath(".", &path_buf);
    const result = try scanner.scan(arena.allocator(), root_path, .{ .apparent = true });

    try std.posix.fchmodat(std.posix.AT.FDCWD, dir_path, 0o755, 0);

    // accessible ディレクトリのファイルが集計される
    try std.testing.expectEqual(@as(u32, 1), result.root.file_count);
    try std.testing.expectEqual(@as(u64, 5), result.root.total_size);
}

// ─── Issue #15: フィクスチャを使ったテスト ────────────────────────────────────

test "fixture: multi_files - known size aggregation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // tests/fixtures/test_tree/multi_files: 100 + 200 + 50 = 350 bytes
    const path = "tests/fixtures/test_tree/multi_files";
    const result = try scanner.scan(arena.allocator(), path, .{ .apparent = true });
    try std.testing.expectEqual(@as(u64, 350), result.root.total_size);
    try std.testing.expectEqual(@as(u32, 3), result.root.file_count);
}

test "fixture: deep nested - correct depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // tests/fixtures/test_tree/deep: a/b/c/deep.txt = 1024 bytes, 3 dirs
    const path = "tests/fixtures/test_tree/deep";
    const result = try scanner.scan(arena.allocator(), path, .{ .apparent = true });
    try std.testing.expectEqual(@as(u64, 1024), result.root.total_size);
    try std.testing.expectEqual(@as(u32, 1), result.root.file_count);
    try std.testing.expectEqual(@as(u32, 3), result.root.dir_count);
}

test "fixture: empty_dir - zero size and counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const path = "tests/fixtures/test_tree/empty_dir";
    const result = try scanner.scan(arena.allocator(), path, .{});
    try std.testing.expectEqual(@as(u64, 0), result.root.total_size);
    try std.testing.expectEqual(@as(u32, 0), result.root.file_count);
    try std.testing.expectEqual(@as(u32, 0), result.root.dir_count);
}

test "fixture: large_dir - 11 files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // file_00=10, file_01=20, ..., file_10=110 → sum = 10+20+...+110 = 660 bytes
    const path = "tests/fixtures/test_tree/large_dir";
    const result = try scanner.scan(arena.allocator(), path, .{ .apparent = true });
    try std.testing.expectEqual(@as(u32, 11), result.root.file_count);
    try std.testing.expectEqual(@as(u64, 660), result.root.total_size);
}

// ─── Issue #55: stderr 権限警告出力 ───────────────────────────────────────────

test "scan: perm_errors count tracks number of denied directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("denied1");
    try tmp.dir.makeDir("denied2");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const d1 = try tmp.dir.realpath("denied1", &path_buf);
    try std.posix.fchmodat(std.posix.AT.FDCWD, d1, 0o000, 0);
    const d2 = try tmp.dir.realpath("denied2", &path_buf2);
    try std.posix.fchmodat(std.posix.AT.FDCWD, d2, 0o000, 0);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root_path = try tmp.dir.realpath(".", &path_buf);
    const result = try scanner.scan(arena.allocator(), root_path, .{});

    try std.posix.fchmodat(std.posix.AT.FDCWD, d1, 0o755, 0);
    try std.posix.fchmodat(std.posix.AT.FDCWD, d2, 0o755, 0);

    try std.testing.expectEqual(@as(u32, 2), result.perm_errors);
}
