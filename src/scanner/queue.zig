/// queue.zig - スレッドセーフ MPMC ワークキュー (Issue #16)
///
/// 複数スレッドから安全にディレクトリパスを enqueue/dequeue できる。
/// Mutex + CondVar による実装。全ワーカーがアイドルかつキューが空の場合に完了を検出する。
const std = @import("std");

/// ディレクトリパスを格納するワークアイテム。
pub const WorkItem = struct {
    /// スキャン対象ディレクトリのフルパス (arena allocator 上の文字列)
    path: []const u8,
    /// ユーザー定義コンテキスト (worker.zig では *ScanNode にキャストする)
    context: ?*anyopaque = null,
};

/// スレッドセーフ MPMC ワークキュー。
///
/// 使用パターン:
///   1. queue.enqueue(item) でディレクトリをキューに積む
///   2. 各ワーカーは queue.dequeue() でアイテムを取り出し処理する
///   3. 処理完了時は queue.finishWorker() を呼び、アイドル状態を通知する
///   4. queue.waitUntilDone() で全ワーカー完了を待機する
pub const WorkQueue = struct {
    mutex: std.Thread.Mutex = .{},
    /// キューが空でなくなるか done になるまで待つ条件変数
    not_empty: std.Thread.Condition = .{},
    /// 全ワーカーがアイドルかつキューが空になるまで待つ条件変数
    all_done: std.Thread.Condition = .{},
    items: std.ArrayList(WorkItem) = .{},
    allocator: std.mem.Allocator,
    /// 現在アクティブに処理中のワーカー数
    active_workers: u32 = 0,
    /// キューに対してこれ以上 enqueue しないことを示すフラグ
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator) WorkQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *WorkQueue) void {
        self.items.deinit(self.allocator);
    }

    /// ワークアイテムをキューに追加する。
    pub fn enqueue(self: *WorkQueue, item: WorkItem) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(self.allocator, item);
        self.not_empty.signal();
    }

    /// キューからアイテムを取り出す。
    /// キューが空かつ closed の場合は null を返す。
    /// キューが空かつ closed でない場合は not_empty を待機する。
    pub fn dequeue(self: *WorkQueue) ?WorkItem {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.items.items.len == 0) {
            if (self.closed) return null;
            self.not_empty.wait(&self.mutex);
        }

        const item = self.items.orderedRemove(0);
        self.active_workers += 1;
        return item;
    }

    /// ワーカーがアイテムの処理を完了したことを通知する。
    /// active_workers が 0 かつキューが空の場合に all_done を送信する。
    pub fn finishWorker(self: *WorkQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.active_workers -= 1;
        if (self.active_workers == 0 and self.items.items.len == 0) {
            self.all_done.broadcast();
        }
    }

    /// これ以上 enqueue しないことを通知する。待機中ワーカーを起こす。
    pub fn close(self: *WorkQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.not_empty.broadcast();
    }

    /// 全ワーカーがアイドル（active_workers == 0）かつキューが空になるまで待機する。
    /// 完了後にキューをクローズして待機中ワーカーを起こす。
    pub fn waitUntilDone(self: *WorkQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.active_workers > 0 or self.items.items.len > 0) {
            self.all_done.wait(&self.mutex);
        }
        // 全作業完了 → キューをクローズして待機中ワーカーを起こす
        self.closed = true;
        self.not_empty.broadcast();
    }
};

// ─── tests ───────────────────────────────────────────────────────────────────

test "enqueue and dequeue single item" {
    var q = WorkQueue.init(std.testing.allocator);
    defer q.deinit();

    try q.enqueue(.{ .path = "/tmp" });
    q.close();
    const item = q.dequeue();
    try std.testing.expect(item != null);
    try std.testing.expectEqualStrings("/tmp", item.?.path);
    q.finishWorker();

    // キューが空で closed なので null が返る
    const none = q.dequeue();
    try std.testing.expect(none == null);
}

test "enqueue multiple items and dequeue in order" {
    var q = WorkQueue.init(std.testing.allocator);
    defer q.deinit();

    const paths = [_][]const u8{ "/a", "/b", "/c" };
    for (paths) |p| try q.enqueue(.{ .path = p });
    q.close();

    var count: usize = 0;
    while (q.dequeue()) |item| {
        try std.testing.expectEqualStrings(paths[count], item.path);
        count += 1;
        q.finishWorker();
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "waitUntilDone: no items, no workers" {
    var q = WorkQueue.init(std.testing.allocator);
    defer q.deinit();
    q.close();
    // active_workers=0 かつ items 空なので即座に返る
    q.waitUntilDone();
}

test "concurrent enqueue and dequeue" {
    const allocator = std.testing.allocator;
    var q = WorkQueue.init(allocator);
    defer q.deinit();

    const n = 100;

    // プロデューサースレッド
    const Producer = struct {
        fn run(queue: *WorkQueue, count: u32) void {
            for (0..count) |i| {
                var buf: [32]u8 = undefined;
                const path = std.fmt.bufPrint(&buf, "/dir/{d}", .{i}) catch unreachable;
                // パスをヒープにコピー (スタック変数のため)
                queue.enqueue(.{ .path = path }) catch {};
            }
            queue.close();
        }
    };

    var consumed: std.atomic.Value(u32) = .{ .raw = 0 };

    // コンシューマースレッド
    const Consumer = struct {
        fn run(queue: *WorkQueue, counter: *std.atomic.Value(u32)) void {
            while (queue.dequeue()) |_| {
                _ = counter.fetchAdd(1, .monotonic);
                queue.finishWorker();
            }
        }
    };

    const producer = try std.Thread.spawn(.{}, Producer.run, .{ &q, n });
    const consumer1 = try std.Thread.spawn(.{}, Consumer.run, .{ &q, &consumed });
    const consumer2 = try std.Thread.spawn(.{}, Consumer.run, .{ &q, &consumed });

    producer.join();
    consumer1.join();
    consumer2.join();

    try std.testing.expectEqual(@as(u32, n), consumed.load(.monotonic));
}
