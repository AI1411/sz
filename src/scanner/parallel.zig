/// parallel.zig - 並列スキャンエンジン (Issue #18-19)
///
/// CPUコア数に応じたスレッドプールでディレクトリを並列スキャンする。
/// サイズ集計は atomic 操作を使用してスレッドセーフに行う。
/// スキャン完了後にサイズを伝播し、DirEntry ツリーを構築する。
const std = @import("std");
const posix = std.posix;
const types = @import("types");
const queue_mod = @import("queue.zig");
const worker_mod = @import("worker.zig");

pub const ScanOptions = struct {
    /// シンボリックリンクを追跡するか（デフォルト: 追跡しない）
    follow_symlinks: bool = false,
    /// マウントポイントを越えてスキャンするか（デフォルト: 越えない）
    cross_mount: bool = false,
    /// 並列ワーカー数。null = CPU コア数（自動）
    jobs: ?u32 = null,
    /// true = ファイルサイズ(st_size)を使用、false = ディスク使用量(st_blocks × 512)
    apparent: bool = false,
};

fn sizeDescending(_: void, a: types.DirEntry, b: types.DirEntry) bool {
    return a.total_size > b.total_size;
}

/// ScanNode ツリーをサイズ降順ソート済みの DirEntry ツリーに変換する。
/// sizes は各ノードの直接ファイルサイズのみを持つため、まず伝播が必要。
fn buildDirEntry(
    allocator: std.mem.Allocator,
    node: *worker_mod.ScanNode,
) std.mem.Allocator.Error!types.DirEntry {
    // 子ノードを再帰的に変換
    var children_list: std.ArrayList(types.DirEntry) = .{};
    {
        node.children_mutex.lock();
        const child_nodes = node.children.items;
        node.children_mutex.unlock();
        for (child_nodes) |child| {
            const child_entry = try buildDirEntry(allocator, child);
            try children_list.append(allocator, child_entry);
        }
    }

    // 子の合計サイズをこのノードに加算
    var subtotal: u64 = node.total_size.load(.monotonic);
    for (children_list.items) |child| {
        subtotal += child.total_size;
    }

    // 子を total_size 降順でソート
    std.sort.block(types.DirEntry, children_list.items, {}, sizeDescending);

    // dir_count: 直接子ディレクトリ数 + 子孫の dir_count
    var total_dir_count: u32 = node.dir_count.load(.monotonic);
    var total_file_count: u32 = node.file_count.load(.monotonic);
    for (children_list.items) |child| {
        total_dir_count += child.dir_count;
        total_file_count += child.file_count;
    }

    const name_copy = try allocator.dupe(u8, node.name);
    const depth_u8: u8 = blk: {
        // depth を計算するため親チェーンを辿る
        var d: u32 = 0;
        var p: ?*worker_mod.ScanNode = node.parent;
        while (p != null) : (p = p.?.parent) {
            d += 1;
            if (d >= 255) break;
        }
        break :blk @intCast(@min(d, 255));
    };

    return types.DirEntry{
        .name = name_copy.ptr,
        .name_len = @intCast(name_copy.len),
        .total_size = subtotal,
        .file_count = total_file_count,
        .dir_count = total_dir_count,
        .children = try children_list.toOwnedSlice(allocator),
        .depth = depth_u8,
        .mtime = node.mtime,
    };
}

/// ScanNode ツリーを再帰的に解放する。
fn freeScanNodes(allocator: std.mem.Allocator, node: *worker_mod.ScanNode) void {
    node.children_mutex.lock();
    const children = node.children.items;
    node.children_mutex.unlock();
    for (children) |child| {
        freeScanNodes(allocator, child);
        allocator.free(child.path);
        allocator.free(child.name);
        allocator.destroy(child);
    }
    node.children.deinit(allocator);
}

/// 指定パスのディレクトリを並列スキャンする。
/// CPUコア数分のワーカースレッドを起動し、結果を DirEntry ツリーとして返す。
pub fn scan(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: ScanOptions,
) !types.ScanResult {
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try std.fs.cwd().realpath(path, &real_buf);

    var root_dir = try std.fs.openDirAbsolute(real_path, .{ .iterate = true, .no_follow = true });
    defer root_dir.close();

    const root_stat = try posix.fstat(root_dir.fd);
    const basename = std.fs.path.basename(real_path);
    const root_name = if (basename.len == 0) "." else basename;

    // ルートScanNodeを確保 (パスと名前はallocatorで複製)
    const root_path = try allocator.dupe(u8, real_path);
    const root_name_copy = try allocator.dupe(u8, root_name);
    const root_node = try allocator.create(worker_mod.ScanNode);
    root_node.* = .{ .name = root_name_copy, .path = root_path };

    // WorkQueue を初期化してルートをエンキュー
    var q = queue_mod.WorkQueue.init(allocator);
    defer q.deinit();
    try q.enqueue(.{ .path = root_path, .context = root_node });

    // ワーカーコンテキスト
    var ctx = worker_mod.WorkerContext{
        .queue = &q,
        .allocator = allocator,
        .root_dev = root_stat.dev,
        .follow_symlinks = options.follow_symlinks,
        .cross_mount = options.cross_mount,
        .apparent = options.apparent,
    };

    // ワーカー数を決定: --jobs 指定があればその値、なければ CPU コア数（最低1スレッド）
    const thread_count: usize = if (options.jobs) |j|
        @max(1, @as(usize, j))
    else
        @max(1, std.Thread.getCpuCount() catch 1);

    // ワーカースレッドを起動
    const threads = try allocator.alloc(std.Thread, thread_count);
    defer allocator.free(threads);
    for (threads) |*t| {
        t.* = try std.Thread.spawn(.{}, worker_mod.workerFn, .{&ctx});
    }

    // 全作業完了を待機してキューをクローズ（ワーカーが終了できるようにする）
    q.waitUntilDone();

    // 全ワーカースレッドの終了を待機
    for (threads) |t| {
        t.join();
    }

    // DirEntry ツリーを構築
    const root_entry = try buildDirEntry(allocator, root_node);
    const perm_errors = ctx.perm_errors.load(.monotonic);

    // ScanNode ツリーを解放
    freeScanNodes(allocator, root_node);
    allocator.free(root_node.path);
    allocator.free(root_node.name);
    allocator.destroy(root_node);

    return types.ScanResult{ .root = root_entry, .perm_errors = perm_errors };
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

    const result = try scan(arena.allocator(), path, .{ .apparent = true });
    try std.testing.expectEqual(@as(u64, 22), result.root.total_size);
    try std.testing.expectEqual(@as(u32, 3), result.root.file_count);
    try std.testing.expectEqual(@as(u32, 1), result.root.dir_count);
    try std.testing.expectEqual(@as(u8, 0), result.root.depth);
    try std.testing.expectEqual(@as(usize, 1), result.root.children.len);
    try std.testing.expectEqualStrings("subdir", result.root.children[0].nameSlice());
    try std.testing.expectEqual(@as(u8, 1), result.root.children[0].depth);
    try std.testing.expectEqual(@as(u64, 7), result.root.children[0].total_size);
}

test "scan: children are sorted by total_size descending" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("small");
    {
        var sub = try tmp.dir.openDir("small", .{});
        defer sub.close();
        const f = try sub.createFile("a.txt", .{});
        defer f.close();
        try f.writeAll("0123456789");
    }
    try tmp.dir.makeDir("large");
    {
        var sub = try tmp.dir.openDir("large", .{});
        defer sub.close();
        const f = try sub.createFile("b.txt", .{});
        defer f.close();
        try f.writeAll("a" ** 100);
    }
    try tmp.dir.makeDir("medium");
    {
        var sub = try tmp.dir.openDir("medium", .{});
        defer sub.close();
        const f = try sub.createFile("c.txt", .{});
        defer f.close();
        try f.writeAll("b" ** 50);
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath(".", &path_buf);

    const result = try scan(arena.allocator(), path, .{ .apparent = true });
    try std.testing.expectEqual(@as(usize, 3), result.root.children.len);
    try std.testing.expect(result.root.children[0].total_size >= result.root.children[1].total_size);
    try std.testing.expect(result.root.children[1].total_size >= result.root.children[2].total_size);
    try std.testing.expectEqual(@as(u64, 100), result.root.children[0].total_size);
    try std.testing.expectEqual(@as(u64, 50), result.root.children[1].total_size);
    try std.testing.expectEqual(@as(u64, 10), result.root.children[2].total_size);
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

    const result = try scan(arena.allocator(), path, .{ .apparent = true });
    try std.testing.expectEqual(@as(u32, 1), result.root.file_count);
    try std.testing.expectEqual(@as(u64, 4), result.root.total_size);
}

test "scan: follow_symlinks=true counts symlinked file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("real.txt", .{});
        defer f.close();
        try f.writeAll("12345");
    }
    try tmp.dir.symLink("real.txt", "link.txt", .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath(".", &path_buf);

    const result_no = try scan(arena.allocator(), path, .{ .follow_symlinks = false, .apparent = true });
    try std.testing.expectEqual(@as(u32, 1), result_no.root.file_count);
    try std.testing.expectEqual(@as(u64, 5), result_no.root.total_size);

    const result_yes = try scan(arena.allocator(), path, .{ .follow_symlinks = true, .apparent = true });
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
    const result = try scan(arena.allocator(), root_path, .{ .apparent = true });

    try std.posix.fchmodat(std.posix.AT.FDCWD, dir_path, 0o755, 0);

    try std.testing.expectEqual(@as(u32, 1), result.root.file_count);
    try std.testing.expectEqual(@as(u64, 2), result.root.total_size);
}

test "scan: perm_errors incremented for permission denied directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("visible.txt", .{});
        defer f.close();
        try f.writeAll("ok");
    }
    try tmp.dir.makeDir("noaccess");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath("noaccess", &path_buf);
    try std.posix.fchmodat(std.posix.AT.FDCWD, dir_path, 0o000, 0);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root_path = try tmp.dir.realpath(".", &path_buf);
    const result = try scan(arena.allocator(), root_path, .{ .apparent = true });

    try std.posix.fchmodat(std.posix.AT.FDCWD, dir_path, 0o755, 0);

    try std.testing.expectEqual(@as(u32, 1), result.perm_errors);
}
