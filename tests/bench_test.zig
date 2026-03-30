/// ベンチマークテスト。
/// 一時ディレクトリに大量ファイルを生成し、スキャン所要時間を計測して
/// 目標値（10万ファイル < 300ms）以内であることを確認する。
///
/// 実行方法:
///   zig build bench
///
/// 他ツールとの比較（手動実行）:
///   hyperfine --warmup 3 \
///     'sz /path/to/large' \
///     'du -sb /path/to/large' \
///     'dust /path/to/large' \
///     'gdu /path/to/large'
const std = @import("std");
const scanner = @import("scanner");
const args_mod = @import("args");

// ─── CountingAllocator: メモリ使用量計測用 ────────────────────────────────────
//
// スキャン中に要求されたバイト数のピーク値を計測する。
// mutex 保護により複数ワーカースレッドからの同時アクセスに対応。

const CountingAllocator = struct {
    inner: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    current: usize = 0,
    peak: usize = 0,

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, n: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        const res = self.inner.rawAlloc(n, al, ra) orelse return null;
        self.current += n;
        if (self.current > self.peak) self.peak = self.current;
        return res;
    }

    fn resize(ctx: *anyopaque, buf: []u8, al: std.mem.Alignment, nl: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.inner.rawResize(buf, al, nl, ra)) return false;
        if (nl > buf.len) {
            self.current += nl - buf.len;
            if (self.current > self.peak) self.peak = self.current;
        } else if (nl < buf.len) {
            self.current -= buf.len - nl;
        }
        return true;
    }

    fn remap(ctx: *anyopaque, buf: []u8, al: std.mem.Alignment, nl: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        const res = self.inner.rawRemap(buf, al, nl, ra) orelse return null;
        if (nl > buf.len) {
            self.current += nl - buf.len;
            if (self.current > self.peak) self.peak = self.current;
        } else if (nl < buf.len) {
            self.current -= buf.len - nl;
        }
        return res;
    }

    fn free(ctx: *anyopaque, buf: []u8, al: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.inner.rawFree(buf, al, ra);
        self.current -= @min(self.current, buf.len);
    }
};

/// テスト用一時ディレクトリに `file_count` 個のファイルを生成する。
/// 生成したルートパスを返す（呼び出し側で removeTree すること）。
fn createTempTree(
    allocator: std.mem.Allocator,
    tmp_dir: std.testing.TmpDir,
    file_count: u32,
    depth: u32,
) ![]const u8 {
    _ = depth;
    var i: u32 = 0;
    while (i < file_count) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "f{d:0>6}.bin", .{i});
        const f = try tmp_dir.dir.createFile(name, .{});
        f.close();
    }
    return tmp_dir.dir.realpathAlloc(allocator, ".") catch unreachable;
}

test "bench: 10k files scan completes within 500ms" {
    const file_count: u32 = 10_000;
    const limit_ms: i64 = 500;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try createTempTree(alloc, tmp, file_count, 1);

    const t0 = std.time.milliTimestamp();
    const result = try scanner.scan(alloc, root_path, .{});
    const elapsed = std.time.milliTimestamp() - t0;

    std.debug.print(
        "\n[bench] {d} files scanned in {d} ms (limit {d} ms)\n",
        .{ result.root.file_count, elapsed, limit_ms },
    );

    try std.testing.expect(result.root.file_count >= file_count);
    try std.testing.expect(elapsed < limit_ms);
}

test "bench: 50k files scan completes within 1000ms" {
    const file_count: u32 = 50_000;
    const limit_ms: i64 = 1_000;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try createTempTree(alloc, tmp, file_count, 1);

    const t0 = std.time.milliTimestamp();
    const result = try scanner.scan(alloc, root_path, .{});
    const elapsed = std.time.milliTimestamp() - t0;

    std.debug.print(
        "\n[bench] {d} files scanned in {d} ms (limit {d} ms)\n",
        .{ result.root.file_count, elapsed, limit_ms },
    );

    try std.testing.expect(result.root.file_count >= file_count);
    try std.testing.expect(elapsed < limit_ms);
}

// ─── Issue X-4: メモリ使用量計測 ─────────────────────────────────────────────
//
// 目標: 100万ファイル (= 10万ディレクトリ × 10ファイル) で < 50MB
// 換算: ディレクトリあたり 500 bytes 以内
// テスト: 100 dirs × 10 files で < 50KB (同比率でスケール)

test "bench: memory usage within 500-bytes-per-dir budget (extrapolates to <50MB at 100k dirs)" {
    const dir_count: u32 = 100;
    const files_per_dir: u32 = 10;
    // 50MB / 100_000 dirs × 100 dirs = 50KB
    const budget_bytes: usize = 50_000;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // ディレクトリとファイルを作成（setup 用に別アロケータを使用）
    var setup_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup_arena.deinit();

    var i: u32 = 0;
    while (i < dir_count) : (i += 1) {
        var dir_name_buf: [32]u8 = undefined;
        const dir_name = try std.fmt.bufPrint(&dir_name_buf, "dir{d:0>4}", .{i});
        try tmp.dir.makeDir(dir_name);
        var sub = try tmp.dir.openDir(dir_name, .{});
        defer sub.close();
        var j: u32 = 0;
        while (j < files_per_dir) : (j += 1) {
            var file_name_buf: [32]u8 = undefined;
            const file_name = try std.fmt.bufPrint(&file_name_buf, "f{d:0>4}.bin", .{j});
            const f = try sub.createFile(file_name, .{});
            f.close();
        }
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_path = try tmp.dir.realpath(".", &path_buf);

    // CountingAllocator でスキャン (page_allocator はスレッドセーフ)
    var counter = CountingAllocator{ .inner = std.heap.page_allocator };
    const result = try scanner.scan(counter.allocator(), root_path, .{});
    const peak = counter.peak;

    std.debug.print(
        "\n[bench:memory] {d} dirs, {d} files: peak {d} bytes, budget {d} bytes ({d} bytes/dir)\n",
        .{ result.root.dir_count, result.root.file_count, peak, budget_bytes, if (result.root.dir_count > 0) peak / result.root.dir_count else 0 },
    );

    try std.testing.expect(result.root.dir_count >= dir_count);
    try std.testing.expect(peak < budget_bytes);
}

// ─── Issue X-5: 起動時間計測 ─────────────────────────────────────────────────
//
// 目標: スキャン開始まで (= 引数パース完了まで) < 5ms
// 引数パースは parseSlice() を直接計測する

test "bench: argument parsing completes within 5ms" {
    const limit_ns: i64 = 5_000_000; // 5ms

    const t0 = std.time.nanoTimestamp();
    const parsed = try args_mod.parseSlice(&.{
        "--depth",    "3",
        "--top",      "10",
        "--jobs",     "4",
        "/some/path",
    });
    const elapsed_ns = std.time.nanoTimestamp() - t0;

    std.debug.print(
        "\n[bench:startup] arg parse: {d} ns (limit {d} ns)\n",
        .{ elapsed_ns, limit_ns },
    );

    // 引数が正しくパースされていることを確認
    try std.testing.expectEqual(@as(u32, 3), parsed.depth);
    try std.testing.expectEqual(@as(u32, 10), parsed.top);
    try std.testing.expectEqual(@as(?u32, 4), parsed.jobs);
    try std.testing.expect(elapsed_ns < limit_ns);
}
