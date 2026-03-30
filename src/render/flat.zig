/// flat.zig - フラット表示モード (Issue #24)
///
/// ツリー構造を無視して全ディレクトリをサイズ降順でフラット表示する。
const std = @import("std");
const types = @import("types");
const size_fmt = @import("size_fmt");

pub const FlatOptions = struct {
    /// 表示する最大エントリ数（デフォルト: 10）
    top: u32 = 10,
};

const FlatEntry = struct {
    path: []const u8,
    size: u64,
};

fn sizeDescending(_: void, a: FlatEntry, b: FlatEntry) bool {
    return a.size > b.size;
}

/// DirEntry ツリーを再帰的に走査して全ディレクトリを収集する。
fn collectAll(
    allocator: std.mem.Allocator,
    entry: *const types.DirEntry,
    parent_path: []const u8,
    list: *std.ArrayList(FlatEntry),
) !void {
    for (entry.children) |*child| {
        const name = child.nameSlice();
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent_path, name });
        try list.append(allocator, FlatEntry{ .path = path, .size = child.total_size });
        try collectAll(allocator, child, path, list);
    }
}

/// DirEntry ツリーをフラット表示する。
/// 全ディレクトリをサイズ降順で並べ、top 件を表示する。
pub fn render(
    writer: anytype,
    allocator: std.mem.Allocator,
    root: *const types.DirEntry,
    opts: FlatOptions,
    scan_time_ms: i64,
) !void {
    var list: std.ArrayList(FlatEntry) = .{};
    defer list.deinit(allocator);

    // ルートを起点に全サブディレクトリを収集（"." を起点とするパスで）
    try collectAll(allocator, root, ".", &list);

    const total = list.items.len;
    std.sort.block(FlatEntry, list.items, {}, sizeDescending);

    const show_count: usize = @min(total, @as(usize, opts.top));
    for (list.items[0..show_count]) |entry| {
        var size_buf: [16]u8 = undefined;
        const size_str = size_fmt.fmt(&size_buf, entry.size);
        try writer.print("  {s:>7}  {s}/\n", .{ size_str, entry.path });
    }

    try writer.print("\n  Showing top {d} of {d} dirs (--top N to change)\n", .{
        show_count,
        total,
    });
    try writer.print("  {d}ms\n", .{scan_time_ms});
}

// ─── tests ───────────────────────────────────────────────────────────────────

fn makeEntry(name: []const u8, total_size: u64, children: []types.DirEntry) types.DirEntry {
    return types.DirEntry{
        .name = name.ptr,
        .name_len = @intCast(name.len),
        .total_size = total_size,
        .file_count = 0,
        .dir_count = 0,
        .children = children,
        .depth = 0,
    };
}

test "flat render: no children produces empty list" {
    const root = makeEntry(".", 1024, &.{});
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try render(fbs.writer(), arena.allocator(), &root, .{ .top = 10 }, 0);
    const out = fbs.getWritten();
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "Showing top 0 of 0"));
}

test "flat render: children sorted by size descending" {
    var children = [_]types.DirEntry{
        makeEntry("small", 100, &.{}),
        makeEntry("large", 500, &.{}),
        makeEntry("medium", 300, &.{}),
    };
    const root = makeEntry(".", 900, &children);

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try render(fbs.writer(), arena.allocator(), &root, .{ .top = 10 }, 0);
    const out = fbs.getWritten();

    // "large" が "small" より前に出現する
    const large_pos = std.mem.indexOf(u8, out, "large").?;
    const small_pos = std.mem.indexOf(u8, out, "small").?;
    try std.testing.expect(large_pos < small_pos);
}

test "flat render: top limits output" {
    var children = [_]types.DirEntry{
        makeEntry("a", 300, &.{}),
        makeEntry("b", 200, &.{}),
        makeEntry("c", 100, &.{}),
    };
    const root = makeEntry(".", 600, &children);

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try render(fbs.writer(), arena.allocator(), &root, .{ .top = 2 }, 0);
    const out = fbs.getWritten();

    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "Showing top 2 of 3"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "a"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "b"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, out, 1, "./c"));
}

test "flat render: nested directories appear with path" {
    var grandchildren = [_]types.DirEntry{
        makeEntry("inner", 50, &.{}),
    };
    var children = [_]types.DirEntry{
        makeEntry("outer", 200, &grandchildren),
    };
    const root = makeEntry(".", 200, &children);

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try render(fbs.writer(), arena.allocator(), &root, .{ .top = 10 }, 5);
    const out = fbs.getWritten();

    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "./outer/"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "./outer/inner/"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "Showing top 2 of 2"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "5ms"));
}
