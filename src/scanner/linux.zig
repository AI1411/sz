/// linux.zig - Linux最適化スキャナー (Issue #20)
///
/// Linux 環境では getdents64 syscall を直接呼び出してディレクトリを高速走査する。
/// 非 Linux 環境 (macOS 等) では POSIX readdir にフォールバックする。
///
/// getdents64 の利点:
/// - libc を経由せず直接 syscall を呼び出す
/// - 大きなバッファ (32768 bytes) で 1 回の syscall が数百エントリを返す
/// - I/O システムコール数を大幅に削減できる
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const types = @import("types.zig");

// posix.zig の ScanOptions と互換性を持たせる
pub const ScanOptions = struct {
    follow_symlinks: bool = false,
    cross_mount: bool = false,
};

const InodeKey = u128;
fn inodeKey(dev: posix.dev_t, ino: posix.ino_t) InodeKey {
    const dev64: u64 = @bitCast(@as(i64, dev));
    const ino64: u64 = @intCast(ino);
    return (@as(u128, dev64) << 64) | @as(u128, ino64);
}

fn getDeviceId(fd: std.posix.fd_t) !posix.dev_t {
    const stat = try posix.fstat(fd);
    return stat.dev;
}

// ─── Linux getdents64 実装 (Linux のみコンパイル) ────────────────────────────

/// Linux 専用の型と関数をまとめた名前空間。
/// 非 Linux 環境ではコンパイルされない空の構造体になる。
const linux_impl = if (builtin.os.tag == .linux) struct {
    /// io_uring バッチサイズ: 1 サブミットで処理する最大 SQE 数
    const IOURING_BATCH: u16 = 64;
    /// Linux dirent64 構造体 (getdents64 が返す形式)
    const LinuxDirent64 = extern struct {
        ino: u64,
        off: i64,
        reclen: u16,
        kind: u8,
        name: [0]u8, // 可変長: name は reclen - offsetOf(name) バイト続く
    };

    /// d_type の値 (Linux dirent64 の kind フィールド)
    const DT_UNKNOWN: u8 = 0;
    const DT_DIR: u8 = 4;
    const DT_REG: u8 = 8;
    const DT_LNK: u8 = 10;

    /// getdents64 syscall を直接呼び出す。
    /// 返値: 読み込んだバイト数 (0 = EOF)
    fn getdents64(fd: std.posix.fd_t, buf: []u8) !usize {
        const rc = std.os.linux.syscall3(
            .getdents64,
            @intCast(fd),
            @intFromPtr(buf.ptr),
            buf.len,
        );
        return switch (std.posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .INVAL => error.InvalidArgument,
            .NOTDIR => error.NotDir,
            .NOENT => error.FileNotFound,
            else => error.Unexpected,
        };
    }

    fn scanDir(
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

        var buf: [32768]u8 align(8) = undefined;

        while (true) {
            const n = getdents64(dir.fd, &buf) catch break;
            if (n == 0) break;

            var offset: usize = 0;
            while (offset < n) {
                const de: *LinuxDirent64 = @ptrCast(@alignCast(&buf[offset]));
                defer offset += de.reclen;

                // エントリ名を取得
                const name_ptr: [*:0]const u8 = @ptrCast(&buf[offset + @offsetOf(LinuxDirent64, "name")]);
                const entry_name = std.mem.span(name_ptr);

                // . と .. をスキップ
                if (std.mem.eql(u8, entry_name, ".") or std.mem.eql(u8, entry_name, "..")) continue;

                var kind = de.kind;

                // DT_UNKNOWN: fstatat でフォールバック
                if (kind == DT_UNKNOWN) {
                    const st = dir.statFile(entry_name) catch continue;
                    kind = switch (st.kind) {
                        .file => DT_REG,
                        .directory => DT_DIR,
                        .sym_link => DT_LNK,
                        else => DT_UNKNOWN,
                    };
                }

                switch (kind) {
                    DT_REG => {
                        const st = dir.statFile(entry_name) catch continue;
                        total_size += st.size;
                        file_count += 1;
                    },
                    DT_LNK => {
                        if (!options.follow_symlinks) continue;
                        const st = dir.statFile(entry_name) catch continue;
                        switch (st.kind) {
                            .file => {
                                total_size += st.size;
                                file_count += 1;
                            },
                            .directory => {
                                var child_dir = dir.openDir(entry_name, .{
                                    .iterate = true,
                                    .no_follow = false,
                                }) catch continue;
                                defer child_dir.close();

                                if (!options.cross_mount) {
                                    const child_dev = getDeviceId(child_dir.fd) catch continue;
                                    if (child_dev != root_dev) continue;
                                }

                                const child_stat = posix.fstat(child_dir.fd) catch continue;
                                const key = inodeKey(child_stat.dev, child_stat.ino);
                                if (visited.contains(key)) {
                                    std.fs.File.stderr().writeAll("sz: warning: symlink loop detected\n") catch {};
                                    continue;
                                }
                                try visited.put(key, {});

                                dir_count += 1;
                                const next_depth: u8 = if (depth < 255) depth + 1 else 255;
                                const child = try scanDir(allocator, child_dir, entry_name, next_depth, root_dev, options, visited);
                                total_size += child.total_size;
                                file_count += child.file_count;
                                dir_count += child.dir_count;
                                try children.append(allocator, child);
                            },
                            else => {},
                        }
                    },
                    DT_DIR => {
                        var child_dir = dir.openDir(entry_name, .{
                            .iterate = true,
                            .no_follow = true,
                        }) catch |err| switch (err) {
                            error.AccessDenied => {
                                var warn_buf: [512]u8 = undefined;
                                const warn_msg = std.fmt.bufPrint(
                                    &warn_buf,
                                    "sz: warning: cannot access '{s}': permission denied\n",
                                    .{entry_name},
                                ) catch "sz: warning: permission denied\n";
                                std.fs.File.stderr().writeAll(warn_msg) catch {};
                                continue;
                            },
                            else => continue,
                        };
                        defer child_dir.close();

                        if (!options.cross_mount) {
                            const child_dev = getDeviceId(child_dir.fd) catch continue;
                            if (child_dev != root_dev) continue;
                        }

                        dir_count += 1;
                        const next_depth: u8 = if (depth < 255) depth + 1 else 255;
                        const child = try scanDir(allocator, child_dir, entry_name, next_depth, root_dev, options, visited);
                        total_size += child.total_size;
                        file_count += child.file_count;
                        dir_count += child.dir_count;
                        try children.append(allocator, child);
                    },
                    else => {},
                }
            }
        }

        std.sort.block(types.DirEntry, children.items, {}, struct {
            fn desc(_: void, a: types.DirEntry, b: types.DirEntry) bool {
                return a.total_size > b.total_size;
            }
        }.desc);

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

    // ─── io_uring 最適化スキャン ──────────────────────────────────────────────

    /// io_uring を使ってファイルの statx をバッチ発行し、ファイルサイズを一括取得する。
    /// sizes[i] に names[i] のファイルサイズを書き込む。エラー時は sizes[i] = 0 のまま。
    fn batchStatxFiles(
        allocator: std.mem.Allocator,
        ring: *std.os.linux.IoUring,
        dir_fd: posix.fd_t,
        names: []const [:0]const u8,
        sizes: []u64,
    ) !void {
        if (names.len == 0) return;

        // statx 結果バッファを一括確保 (カーネルが直接書き込む)
        const statx_bufs = try allocator.alloc(std.os.linux.Statx, names.len);
        defer allocator.free(statx_bufs);
        @memset(sizes, 0);

        var offset: usize = 0;
        while (offset < names.len) {
            const end = @min(offset + IOURING_BATCH, names.len);
            const count = end - offset;

            // SQE をキューに追加
            for (offset..end) |i| {
                _ = try ring.statx(
                    @intCast(i), // user_data = グローバルインデックス
                    dir_fd,
                    names[i],
                    std.os.linux.AT.NO_AUTOMOUNT,
                    std.os.linux.STATX_SIZE,
                    &statx_bufs[i],
                );
            }

            // サブミットして完了を待つ
            _ = try ring.submit_and_wait(@intCast(count));

            // CQE を処理してサイズを収集
            var cqes: [IOURING_BATCH]std.os.linux.io_uring_cqe = undefined;
            const n_done = try ring.copy_cqes(cqes[0..count], 0);
            for (cqes[0..n_done]) |cqe| {
                if (cqe.err() == .SUCCESS) {
                    const i: usize = @intCast(cqe.user_data);
                    if (i < names.len) sizes[i] = statx_bufs[i].size;
                }
            }

            offset = end;
        }
    }

    /// io_uring を使ったディレクトリスキャン。
    /// 通常ファイルの stat を io_uring でバッチ発行して高速化する。
    fn scanDirIoUring(
        allocator: std.mem.Allocator,
        ring: *std.os.linux.IoUring,
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

        // 通常ファイル名を収集して io_uring でバッチ stat する
        var file_names: std.ArrayList([:0]const u8) = .{};
        defer {
            for (file_names.items) |n| allocator.free(n);
            file_names.deinit(allocator);
        }

        var buf: [32768]u8 align(8) = undefined;
        while (true) {
            const n = getdents64(dir.fd, &buf) catch break;
            if (n == 0) break;

            var off: usize = 0;
            while (off < n) {
                const de: *LinuxDirent64 = @ptrCast(@alignCast(&buf[off]));
                defer off += de.reclen;

                const name_ptr: [*:0]const u8 = @ptrCast(&buf[off + @offsetOf(LinuxDirent64, "name")]);
                const entry_name = std.mem.span(name_ptr);

                if (std.mem.eql(u8, entry_name, ".") or std.mem.eql(u8, entry_name, "..")) continue;

                var kind = de.kind;
                if (kind == DT_UNKNOWN) {
                    const st = dir.statFile(entry_name) catch continue;
                    kind = switch (st.kind) {
                        .file => DT_REG,
                        .directory => DT_DIR,
                        .sym_link => DT_LNK,
                        else => DT_UNKNOWN,
                    };
                }

                switch (kind) {
                    DT_REG => {
                        // ファイル名をコピーして後でバッチ stat
                        const name_copy = try allocator.dupeZ(u8, entry_name);
                        try file_names.append(allocator, name_copy);
                        file_count += 1;
                    },
                    DT_LNK => {
                        if (!options.follow_symlinks) continue;
                        const st = dir.statFile(entry_name) catch continue;
                        switch (st.kind) {
                            .file => {
                                total_size += st.size;
                                file_count += 1;
                            },
                            .directory => {
                                var child_dir = dir.openDir(entry_name, .{
                                    .iterate = true,
                                    .no_follow = false,
                                }) catch continue;
                                defer child_dir.close();

                                if (!options.cross_mount) {
                                    const child_dev = getDeviceId(child_dir.fd) catch continue;
                                    if (child_dev != root_dev) continue;
                                }

                                const child_stat = posix.fstat(child_dir.fd) catch continue;
                                const key = inodeKey(child_stat.dev, child_stat.ino);
                                if (visited.contains(key)) {
                                    std.fs.File.stderr().writeAll("sz: warning: symlink loop detected\n") catch {};
                                    continue;
                                }
                                try visited.put(key, {});

                                dir_count += 1;
                                const next_depth: u8 = if (depth < 255) depth + 1 else 255;
                                const child = try scanDirIoUring(allocator, ring, child_dir, entry_name, next_depth, root_dev, options, visited);
                                total_size += child.total_size;
                                file_count += child.file_count;
                                dir_count += child.dir_count;
                                try children.append(allocator, child);
                            },
                            else => {},
                        }
                    },
                    DT_DIR => {
                        var child_dir = dir.openDir(entry_name, .{
                            .iterate = true,
                            .no_follow = true,
                        }) catch |err| switch (err) {
                            error.AccessDenied => {
                                var warn_buf: [512]u8 = undefined;
                                const warn_msg = std.fmt.bufPrint(
                                    &warn_buf,
                                    "sz: warning: cannot access '{s}': permission denied\n",
                                    .{entry_name},
                                ) catch "sz: warning: permission denied\n";
                                std.fs.File.stderr().writeAll(warn_msg) catch {};
                                continue;
                            },
                            else => continue,
                        };
                        defer child_dir.close();

                        if (!options.cross_mount) {
                            const child_dev = getDeviceId(child_dir.fd) catch continue;
                            if (child_dev != root_dev) continue;
                        }

                        dir_count += 1;
                        const next_depth: u8 = if (depth < 255) depth + 1 else 255;
                        const child = try scanDirIoUring(allocator, ring, child_dir, entry_name, next_depth, root_dev, options, visited);
                        total_size += child.total_size;
                        file_count += child.file_count;
                        dir_count += child.dir_count;
                        try children.append(allocator, child);
                    },
                    else => {},
                }
            }
        }

        // 収集したファイル名を io_uring でバッチ stat
        if (file_names.items.len > 0) {
            const sizes = try allocator.alloc(u64, file_names.items.len);
            defer allocator.free(sizes);
            batchStatxFiles(allocator, ring, dir.fd, file_names.items, sizes) catch {
                // io_uring 失敗時は通常 stat にフォールバック
                for (file_names.items, sizes) |fname, *sz| {
                    const st = dir.statFile(fname) catch continue;
                    sz.* = st.size;
                }
            };
            for (sizes) |sz| total_size += sz;
        }

        std.sort.block(types.DirEntry, children.items, {}, struct {
            fn desc(_: void, a: types.DirEntry, b: types.DirEntry) bool {
                return a.total_size > b.total_size;
            }
        }.desc);

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

    /// Linux 用スキャンエントリポイント。
    /// io_uring が使用可能であれば scanDirIoUring を、そうでなければ scanDir を使う。
    fn scanLinux(
        allocator: std.mem.Allocator,
        dir: std.fs.Dir,
        name: []const u8,
        depth: u8,
        root_dev: posix.dev_t,
        options: ScanOptions,
        visited: *std.AutoHashMap(InodeKey, void),
    ) !types.DirEntry {
        // io_uring の初期化を試みる
        var ring = std.os.linux.IoUring.init(IOURING_BATCH, 0) catch {
            // カーネルが io_uring 非対応 → getdents64 にフォールバック
            return scanDir(allocator, dir, name, depth, root_dev, options, visited);
        };
        defer ring.deinit();

        // io_uring スキャン (失敗時は getdents64 にフォールバック)
        return scanDirIoUring(allocator, &ring, dir, name, depth, root_dev, options, visited) catch
            scanDir(allocator, dir, name, depth, root_dev, options, visited);
    }
} else struct {};

// ─── POSIX フォールバック (非 Linux 環境用) ──────────────────────────────────

fn scanDirPosix(
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
        if (kind == .unknown) {
            const st = dir.statFile(entry.name) catch continue;
            kind = st.kind;
        }

        switch (kind) {
            .sym_link => {
                if (!options.follow_symlinks) continue;
                const st = dir.statFile(entry.name) catch continue;
                switch (st.kind) {
                    .file => {
                        total_size += st.size;
                        file_count += 1;
                    },
                    .directory => {
                        var child_dir = dir.openDir(entry.name, .{
                            .iterate = true,
                            .no_follow = false,
                        }) catch continue;
                        defer child_dir.close();

                        if (!options.cross_mount) {
                            const child_dev = getDeviceId(child_dir.fd) catch continue;
                            if (child_dev != root_dev) continue;
                        }

                        const child_stat = posix.fstat(child_dir.fd) catch continue;
                        const key = inodeKey(child_stat.dev, child_stat.ino);
                        if (visited.contains(key)) {
                            std.fs.File.stderr().writeAll("sz: warning: symlink loop detected\n") catch {};
                            continue;
                        }
                        try visited.put(key, {});

                        dir_count += 1;
                        const next_depth: u8 = if (depth < 255) depth + 1 else 255;
                        const child = try scanDirPosix(allocator, child_dir, entry.name, next_depth, root_dev, options, visited);
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

                if (!options.cross_mount) {
                    const child_dev = getDeviceId(child_dir.fd) catch continue;
                    if (child_dev != root_dev) continue;
                }

                dir_count += 1;
                const next_depth: u8 = if (depth < 255) depth + 1 else 255;
                const child = try scanDirPosix(allocator, child_dir, entry.name, next_depth, root_dev, options, visited);
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

    std.sort.block(types.DirEntry, children.items, {}, struct {
        fn desc(_: void, a: types.DirEntry, b: types.DirEntry) bool {
            return a.total_size > b.total_size;
        }
    }.desc);

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

// ─── パブリック API ──────────────────────────────────────────────────────────

/// ディレクトリを再帰的にスキャンする。
/// Linux では getdents64 syscall を使用し、それ以外は POSIX readdir にフォールバックする。
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
    const root_dev = root_stat.dev;
    const basename = std.fs.path.basename(real_path);
    const root_name = if (basename.len == 0) "." else basename;

    var visited = std.AutoHashMap(InodeKey, void).init(allocator);
    defer visited.deinit();
    try visited.put(inodeKey(root_stat.dev, root_stat.ino), {});

    const root = if (builtin.os.tag == .linux)
        try linux_impl.scanLinux(allocator, root_dir, root_name, 0, root_dev, options, &visited)
    else
        try scanDirPosix(allocator, root_dir, root_name, 0, root_dev, options, &visited);

    return types.ScanResult{ .root = root };
}

// ─── tests ───────────────────────────────────────────────────────────────────

test "linux scanner: basic scan (POSIX fallback on non-Linux)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("file.txt", .{});
        defer f.close();
        try f.writeAll("hello world"); // 11 bytes
    }
    try tmp.dir.makeDir("subdir");
    {
        var sub = try tmp.dir.openDir("subdir", .{});
        defer sub.close();
        const f = try sub.createFile("nested.txt", .{});
        defer f.close();
        try f.writeAll("nested"); // 6 bytes
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath(".", &path_buf);

    const result = try scan(arena.allocator(), path, .{});
    try std.testing.expectEqual(@as(u64, 17), result.root.total_size);
    try std.testing.expectEqual(@as(u32, 2), result.root.file_count);
    try std.testing.expectEqual(@as(u32, 1), result.root.dir_count);
}

test "linux scanner: permission denied is skipped" {
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

test "linux scanner: children sorted by size descending" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("big");
    {
        var sub = try tmp.dir.openDir("big", .{});
        defer sub.close();
        const f = try sub.createFile("f.txt", .{});
        defer f.close();
        try f.writeAll("x" ** 200);
    }
    try tmp.dir.makeDir("small");
    {
        var sub = try tmp.dir.openDir("small", .{});
        defer sub.close();
        const f = try sub.createFile("f.txt", .{});
        defer f.close();
        try f.writeAll("x" ** 10);
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath(".", &path_buf);

    const result = try scan(arena.allocator(), path, .{});
    try std.testing.expectEqual(@as(usize, 2), result.root.children.len);
    try std.testing.expect(result.root.children[0].total_size >= result.root.children[1].total_size);
}
