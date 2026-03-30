const std = @import("std");

/// スキャン結果を保持するノード型。1ノードあたり約64bytesを目標とする。
pub const DirEntry = struct {
    name: [*]const u8,
    name_len: u16,
    total_size: u64,
    file_count: u32,
    dir_count: u32,
    children: []DirEntry,
    depth: u8,

    /// name フィールドから Zig スライスとして名前を取得する。
    pub fn nameSlice(self: DirEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// スキャン全体の結果を保持する型。
pub const ScanResult = struct {
    root: DirEntry,
    allocator: std.mem.Allocator,
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
    // 1ノードあたり約64bytesを目標とする
    const size = @sizeOf(DirEntry);
    try std.testing.expect(size <= 64);
}
