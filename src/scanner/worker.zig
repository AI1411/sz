/// worker.zig - 並列スキャン用ワーカースレッド (Issue #17)
///
/// WorkerContext を共有しながら複数スレッドが同時にディレクトリをスキャンする。
/// ファイルサイズは atomic 操作で集計し、サブディレクトリはキューに追加する。
const std = @import("std");
const posix = std.posix;
const queue_mod = @import("queue.zig");

/// 並列スキャン中に各ディレクトリの結果を蓄積するノード。
/// 複数ワーカーからアトミックに更新される。
pub const ScanNode = struct {
    name: []const u8,
    path: []const u8,
    /// ファイル合計サイズ (atomic: 複数スレッドから加算)
    total_size: std.atomic.Value(u64) = .{ .raw = 0 },
    /// ファイル数 (atomic)
    file_count: std.atomic.Value(u32) = .{ .raw = 0 },
    /// ディレクトリ数 (atomic)
    dir_count: std.atomic.Value(u32) = .{ .raw = 0 },
    /// 子ノードの一覧 (mutex で保護)
    children: std.ArrayList(*ScanNode) = .{},
    children_mutex: std.Thread.Mutex = .{},
    /// 親ノードへサイズを伝播するための残り子数カウンター
    remaining_children: std.atomic.Value(u32) = .{ .raw = 0 },
    /// 親ノードへの参照 (null = ルート)
    parent: ?*ScanNode = null,
    /// ディレクトリの最終更新時刻 (Unix エポック秒)
    mtime: i64 = 0,

    pub fn addSize(self: *ScanNode, size: u64) void {
        _ = self.total_size.fetchAdd(size, .monotonic);
    }

    pub fn addFile(self: *ScanNode) void {
        _ = self.file_count.fetchAdd(1, .monotonic);
    }

    pub fn addDir(self: *ScanNode) void {
        _ = self.dir_count.fetchAdd(1, .monotonic);
    }

    pub fn addChild(self: *ScanNode, allocator: std.mem.Allocator, child: *ScanNode) !void {
        self.children_mutex.lock();
        defer self.children_mutex.unlock();
        try self.children.append(allocator, child);
    }
};

/// 全ワーカースレッドが共有するコンテキスト。
pub const WorkerContext = struct {
    queue: *queue_mod.WorkQueue,
    allocator: std.mem.Allocator,
    root_dev: posix.dev_t,
    follow_symlinks: bool,
    cross_mount: bool,
    /// true = ファイルサイズ(st_size)を使用、false = ディスク使用量(st_blocks × 512)
    apparent: bool = false,
};

fn getDeviceId(dir: std.fs.Dir) !posix.dev_t {
    const stat = try posix.fstat(dir.fd);
    return stat.dev;
}

/// プラットフォーム非依存で posix.Stat から mtime (秒) を取得する。
fn getStatMtime(stat: posix.Stat) i64 {
    // Linux: stat.mtim (timespec フィールド名は x86_64=tv_sec / aarch64=sec)
    // macOS: stat.mtimespec.sec
    if (comptime @hasField(posix.Stat, "mtim")) {
        const mtim = stat.mtim;
        const T = @TypeOf(mtim);
        if (comptime @hasField(T, "tv_sec")) {
            return @intCast(mtim.tv_sec);
        } else if (comptime @hasField(T, "sec")) {
            return @intCast(mtim.sec);
        }
    } else if (comptime @hasField(posix.Stat, "mtimespec")) {
        return @intCast(stat.mtimespec.sec);
    }
    return 0;
}

/// posix.fstatat でファイルのディスク使用量 (st_blocks × 512) を取得する。
fn getDiskSize(dir: std.fs.Dir, name: []const u8) !u64 {
    const os_stat = try posix.fstatat(dir.fd, name, posix.AT.SYMLINK_NOFOLLOW);
    return if (os_stat.blocks > 0) @as(u64, @intCast(os_stat.blocks)) * 512 else 0;
}

/// ワーカースレッドのエントリポイント。
/// キューからディレクトリを取り出し、ファイルサイズを集計してサブディレクトリをキューに追加する。
pub fn workerFn(ctx: *WorkerContext) void {
    while (ctx.queue.dequeue()) |item| {
        defer ctx.queue.finishWorker();
        processDir(ctx, item) catch {};
    }
}

fn processDir(ctx: *WorkerContext, item: queue_mod.WorkItem) !void {
    const node: *ScanNode = @ptrCast(@alignCast(item.context orelse return));

    var dir = std.fs.openDirAbsolute(item.path, .{
        .iterate = true,
        .no_follow = true,
    }) catch return;
    defer dir.close();

    const dir_dev = getDeviceId(dir) catch return;
    if (!ctx.cross_mount and dir_dev != ctx.root_dev) return;

    // ディレクトリ自身の mtime を取得する
    const dir_raw_stat = posix.fstat(dir.fd) catch null;
    if (dir_raw_stat) |s| {
        node.mtime = getStatMtime(s);
    }

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        var kind = entry.kind;
        if (kind == .unknown) {
            const st = dir.statFile(entry.name) catch continue;
            kind = st.kind;
        }

        switch (kind) {
            .file => {
                if (ctx.apparent) {
                    const st = dir.statFile(entry.name) catch continue;
                    node.addSize(st.size);
                } else {
                    const sz = getDiskSize(dir, entry.name) catch 0;
                    node.addSize(sz);
                }
                node.addFile();
            },
            .sym_link => {
                if (!ctx.follow_symlinks) continue;
                const st = dir.statFile(entry.name) catch continue;
                switch (st.kind) {
                    .file => {
                        if (ctx.apparent) {
                            node.addSize(st.size);
                        } else {
                            const sz = getDiskSize(dir, entry.name) catch 0;
                            node.addSize(sz);
                        }
                        node.addFile();
                    },
                    .directory => {
                        // シンボリックリンクのディレクトリ追跡 (ループ検出は parallel.zig 側で)
                        const child_name = try ctx.allocator.dupe(u8, entry.name);
                        const child_path = try std.fs.path.join(ctx.allocator, &.{ item.path, entry.name });
                        const child_node = try ctx.allocator.create(ScanNode);
                        child_node.* = .{
                            .name = child_name,
                            .path = child_path,
                            .parent = node,
                        };
                        try node.addChild(ctx.allocator, child_node);
                        node.addDir();
                        _ = node.remaining_children.fetchAdd(1, .monotonic);
                        try ctx.queue.enqueue(.{ .path = child_path, .context = child_node });
                    },
                    else => {},
                }
            },
            .directory => {
                const child_name = try ctx.allocator.dupe(u8, entry.name);
                const child_path = try std.fs.path.join(ctx.allocator, &.{ item.path, entry.name });
                const child_node = try ctx.allocator.create(ScanNode);
                child_node.* = .{
                    .name = child_name,
                    .path = child_path,
                    .parent = node,
                };
                try node.addChild(ctx.allocator, child_node);
                node.addDir();
                _ = node.remaining_children.fetchAdd(1, .monotonic);
                try ctx.queue.enqueue(.{ .path = child_path, .context = child_node });
            },
            else => {},
        }
    }
}

// ─── tests ───────────────────────────────────────────────────────────────────

test "worker: file sizes are accumulated atomically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 3 ファイル作成
    {
        const f = try tmp.dir.createFile("a.txt", .{});
        defer f.close();
        try f.writeAll("hello"); // 5 bytes
    }
    {
        const f = try tmp.dir.createFile("b.txt", .{});
        defer f.close();
        try f.writeAll("world!"); // 6 bytes
    }

    const allocator = std.testing.allocator;
    var q = queue_mod.WorkQueue.init(allocator);
    defer q.deinit();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);
    const dir_path_copy = try allocator.dupe(u8, dir_path);
    defer allocator.free(dir_path_copy);

    var root_node = ScanNode{ .name = ".", .path = dir_path_copy };

    const root_stat = try posix.fstat(tmp.dir.fd);
    var ctx = WorkerContext{
        .queue = &q,
        .allocator = allocator,
        .root_dev = root_stat.dev,
        .follow_symlinks = false,
        .cross_mount = false,
        .apparent = true, // 正確なバイト数をテストするため apparent size を使用
    };

    try q.enqueue(.{ .path = dir_path_copy, .context = &root_node });
    q.close();

    // ワーカーを同期実行
    workerFn(&ctx);

    try std.testing.expectEqual(@as(u64, 11), root_node.total_size.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 2), root_node.file_count.load(.monotonic));
}

test "worker: subdirs are enqueued" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("sub1");
    try tmp.dir.makeDir("sub2");

    const allocator = std.testing.allocator;
    var q = queue_mod.WorkQueue.init(allocator);
    defer q.deinit();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);
    const dir_path_copy = try allocator.dupe(u8, dir_path);
    defer allocator.free(dir_path_copy);

    var root_node = ScanNode{ .name = ".", .path = dir_path_copy };

    const root_stat = try posix.fstat(tmp.dir.fd);
    var ctx = WorkerContext{
        .queue = &q,
        .allocator = allocator,
        .root_dev = root_stat.dev,
        .follow_symlinks = false,
        .cross_mount = false,
    };

    try q.enqueue(.{ .path = dir_path_copy, .context = &root_node });
    q.close();

    workerFn(&ctx);

    try std.testing.expectEqual(@as(u32, 2), root_node.dir_count.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 2), root_node.children.items.len);

    // 子ノードのメモリを解放 (dir_path_copy は defer で解放)
    for (root_node.children.items) |child| {
        allocator.free(child.path);
        allocator.free(child.name);
        allocator.destroy(child);
    }
    root_node.children.deinit(allocator);
}

test "getStatMtime: returns positive mtime from real directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const stat = try posix.fstat(tmp.dir.fd);
    const mtime = getStatMtime(stat);
    try std.testing.expect(mtime > 0);
}
