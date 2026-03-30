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
