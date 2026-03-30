const std = @import("std");

/// スキャン結果を保持するノード型。1ノードあたり約64bytesを目標とする。
pub const DirEntry = struct {
    name: [*]const u8,
    name_len: u16,
    total_size: u64,
    file_count: u32,
    dir_count: u32,
    children: []DirEntry,
    /// ディレクトリツリーの深さ。最大255階層を上限とする（u8: 0-255）。
    /// CLIの --depth 引数（u32）からこのフィールドへ代入する際は clamp が必要。
    depth: u8,
    /// ディレクトリの最終更新時刻（Unix エポック秒）。--older フィルタで使用。
    /// デフォルトは 0 (不明/未設定)。
    mtime: i64 = 0,

    /// name フィールドから Zig スライスとして名前を取得する。
    pub fn nameSlice(self: *const DirEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// スキャン全体の結果を保持する型。
/// メモリ管理は呼び出し側の ArenaAllocator で行う（arena.deinit() で一括解放）。
pub const ScanResult = struct {
    root: DirEntry,
    /// 権限エラー（EACCES/EPERM）が発生したディレクトリの数。
    perm_errors: u32 = 0,
};

test "DirEntry nameSlice" {
    const name = "hello";
    const entry = DirEntry{
        .name = name.ptr,
        .name_len = @intCast(name.len),
        .total_size = 1024,
        .file_count = 3,
        .dir_count = 1,
        .children = &.{},
        .depth = 0,
    };
    try std.testing.expectEqualStrings("hello", entry.nameSlice());
}

test "DirEntry size" {
    // 1ノードあたり64bytes以内を目標とする (mtime追加後は64bytes)
    const size = @sizeOf(DirEntry);
    try std.testing.expect(size <= 64);
}

test "DirEntry mtime default" {
    const name = "dir";
    const entry = DirEntry{
        .name = name.ptr,
        .name_len = @intCast(name.len),
        .total_size = 0,
        .file_count = 0,
        .dir_count = 0,
        .children = &.{},
        .depth = 0,
    };
    try std.testing.expectEqual(@as(i64, 0), entry.mtime);
}
