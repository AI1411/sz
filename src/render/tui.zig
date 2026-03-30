const std = @import("std");
const types = @import("types");
const size_fmt = @import("size_fmt");
const posix = std.posix;

// ─── ターミナル制御 ────────────────────────────────────────────────────────────

/// 保存しておいたオリジナルの termios 設定
var original_termios: posix.termios = undefined;

/// stdin のファイルディスクリプタ
const STDIN_FD: posix.fd_t = 0;
/// stdout のファイルディスクリプタ
const STDOUT_FD: posix.fd_t = 1;

/// ターミナルを raw モードに切り替える
fn enterRawMode() !void {
    original_termios = try posix.tcgetattr(STDIN_FD);
    var raw = original_termios;

    // 入力フラグ: Ctrl-S/Q フロー制御・改行変換・パリティ・BREAK を無効化
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;
    // 出力フラグ: 後処理を無効化
    raw.oflag.OPOST = false;
    // 文字サイズを 8bit に設定
    raw.cflag.CSIZE = .CS8;
    // ローカルフラグ: エコー・カノニカル・シグナル・拡張を無効化
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;
    // 読み取り: 最低1文字・タイムアウトなし
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;

    try posix.tcsetattr(STDIN_FD, .FLUSH, raw);
}

/// ターミナルを元の設定に戻す
fn exitRawMode() void {
    posix.tcsetattr(STDIN_FD, .FLUSH, original_termios) catch {};
}

/// ANSI エスケープシーケンスをまとめた定数
const esc = struct {
    const clear_screen = "\x1b[2J";
    const cursor_home = "\x1b[H";
    const cursor_hide = "\x1b[?25l";
    const cursor_show = "\x1b[?25h";
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const fg_cyan = "\x1b[36m";
    const fg_red = "\x1b[31m";
    const bg_blue = "\x1b[44m";
    const fg_white = "\x1b[37m";
};

// ─── SIGWINCH: ターミナルリサイズシグナル ────────────────────────────────────

/// SIGWINCH を受信したかどうかのフラグ (シグナルハンドラから書き込む)
var sigwinch_received = std.atomic.Value(bool).init(false);

/// SIGWINCH シグナルハンドラ
fn handleSigWinch(_: i32) callconv(.c) void {
    sigwinch_received.store(true, .monotonic);
}

/// SIGWINCH ハンドラを登録する
fn setupSigWinch() void {
    const act = posix.Sigaction{
        .handler = .{ .handler = handleSigWinch },
        .mask = posix.sigemptyset(),
        .flags = 0, // SA_RESTART を付けないことで read() が EINTR で中断される
    };
    posix.sigaction(posix.SIG.WINCH, &act, null);
}

// ─── ソートモード ─────────────────────────────────────────────────────────────

/// ソート順の種類
const SortMode = enum {
    size,
    name,
    file_count,

    /// 次のソートモードにサイクルする
    fn next(self: SortMode) SortMode {
        return switch (self) {
            .size => .name,
            .name => .file_count,
            .file_count => .size,
        };
    }

    /// 表示ラベルを返す
    fn label(self: SortMode) []const u8 {
        return switch (self) {
            .size => "size",
            .name => "name",
            .file_count => "files",
        };
    }
};

// ─── キー入力 ─────────────────────────────────────────────────────────────────

const Key = enum {
    up,
    down,
    left,
    right,
    enter,
    sort, // s: ソート切替
    delete, // d: 削除操作
    confirm_yes, // y: 削除確認ダイアログで「はい」
    confirm_no, // n: 削除確認ダイアログで「いいえ」
    escape, // ESC: キャンセル
    quit,
    unknown,
};

/// stdin から1キーを読み取り Key に変換する
fn readKey() !Key {
    var buf: [4]u8 = undefined;
    const n = posix.read(STDIN_FD, &buf) catch |err| {
        // SIGWINCH 等によるシステムコール割り込みは無視して再描画させる
        if (err == error.Interrupted) return .unknown;
        return err;
    };
    if (n == 0) return .unknown;

    if (buf[0] == 'q' or buf[0] == 'Q') return .quit;
    if (buf[0] == '\r' or buf[0] == '\n') return .enter;
    if (buf[0] == 's' or buf[0] == 'S') return .sort;
    if (buf[0] == 'd' or buf[0] == 'D') return .delete;
    if (buf[0] == 'y' or buf[0] == 'Y') return .confirm_yes;
    if (buf[0] == 'n' or buf[0] == 'N') return .confirm_no;

    // ESC シーケンス (例: \x1b[A = 上矢印)
    if (buf[0] == 0x1b) {
        if (n == 1) return .escape; // 単独 ESC
        if (n >= 3 and buf[1] == '[') {
            return switch (buf[2]) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                else => .unknown,
            };
        }
        return .escape;
    }

    return .unknown;
}

// ─── 表示アイテムリスト ────────────────────────────────────────────────────────

/// 画面上の1行に対応するアイテム
const Item = struct {
    entry: *const types.DirEntry,
    depth: u32,
    is_last: bool,
    /// 展開済みかどうか
    expanded: bool,
};

/// children をソートモードに従ってインデックスのスライスとして返す。
/// 呼び出し元が allocator.free する責任を持つ。
fn sortedChildIndices(
    allocator: std.mem.Allocator,
    children: []const types.DirEntry,
    sort_mode: SortMode,
) ![]usize {
    const indices = try allocator.alloc(usize, children.len);
    for (indices, 0..) |*idx, i| idx.* = i;

    const SortCtx = struct {
        children: []const types.DirEntry,
        mode: SortMode,

        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            const ca = ctx.children[a];
            const cb = ctx.children[b];
            return switch (ctx.mode) {
                .size => ca.total_size > cb.total_size,
                .name => std.mem.lessThan(u8, ca.nameSlice(), cb.nameSlice()),
                .file_count => ca.file_count > cb.file_count,
            };
        }
    };

    std.sort.block(usize, indices, SortCtx{ .children = children, .mode = sort_mode }, SortCtx.lessThan);
    return indices;
}

/// DirEntry ツリーを深さ優先でフラットなリストに展開する。
/// expanded_set に含まれるエントリの子も再帰的に追加する。
/// deleted_set に含まれるエントリはスキップする。
fn buildItemList(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Item),
    entry: *const types.DirEntry,
    depth: u32,
    is_last: bool,
    expanded_set: *const std.AutoHashMap(usize, void),
    deleted_set: *const std.AutoHashMap(usize, void),
    sort_mode: SortMode,
) !void {
    const ptr_key = @intFromPtr(entry);
    const expanded = expanded_set.contains(ptr_key);
    try list.append(allocator, .{
        .entry = entry,
        .depth = depth,
        .is_last = is_last,
        .expanded = expanded,
    });
    if (expanded and entry.children.len > 0) {
        const indices = try sortedChildIndices(allocator, entry.children, sort_mode);
        defer allocator.free(indices);

        // 削除済みを除いた表示件数を先にカウント
        var visible: usize = 0;
        for (indices) |idx| {
            if (!deleted_set.contains(@intFromPtr(&entry.children[idx]))) visible += 1;
        }

        var vi: usize = 0;
        for (indices) |idx| {
            const child = &entry.children[idx];
            if (deleted_set.contains(@intFromPtr(child))) continue;
            vi += 1;
            try buildItemList(allocator, list, child, depth + 1, vi == visible, expanded_set, deleted_set, sort_mode);
        }
    }
}

// ─── 状態 ─────────────────────────────────────────────────────────────────────

const State = struct {
    allocator: std.mem.Allocator,
    /// ルートスタック (ドリルダウン用)。最初の要素が元ルート。
    root_stack: std.ArrayList(*const types.DirEntry),
    /// 展開済みエントリの集合 (ポインタ整数値をキーとする)
    expanded: std.AutoHashMap(usize, void),
    /// 削除済みエントリの集合 (ポインタ整数値をキーとする)
    deleted: std.AutoHashMap(usize, void),
    /// カーソル位置 (現在表示中のフラットリストのインデックス)
    cursor: usize,
    /// 現在のソートモード
    sort_mode: SortMode,
    /// 削除確認ダイアログ表示中かどうか
    confirm_delete: bool,
    /// スキャンのベースパス (絶対パス)
    scan_base_path: []const u8,

    fn init(allocator: std.mem.Allocator, root: *const types.DirEntry, scan_base_path: []const u8) !State {
        var stack: std.ArrayList(*const types.DirEntry) = .{};
        try stack.append(allocator, root);
        return State{
            .allocator = allocator,
            .root_stack = stack,
            .expanded = std.AutoHashMap(usize, void).init(allocator),
            .deleted = std.AutoHashMap(usize, void).init(allocator),
            .cursor = 0,
            .sort_mode = .size,
            .confirm_delete = false,
            .scan_base_path = scan_base_path,
        };
    }

    fn deinit(self: *State) void {
        self.root_stack.deinit(self.allocator);
        self.expanded.deinit();
        self.deleted.deinit();
    }

    fn currentRoot(self: *const State) *const types.DirEntry {
        return self.root_stack.items[self.root_stack.items.len - 1];
    }

    /// フラットリストを構築して返す (呼び出し元が deinit する責任を持つ)
    fn buildList(self: *const State) !std.ArrayList(Item) {
        var list: std.ArrayList(Item) = .{};
        const root = self.currentRoot();

        const indices = try sortedChildIndices(self.allocator, root.children, self.sort_mode);
        defer self.allocator.free(indices);

        var visible: usize = 0;
        for (indices) |idx| {
            if (!self.deleted.contains(@intFromPtr(&root.children[idx]))) visible += 1;
        }

        var vi: usize = 0;
        for (indices) |idx| {
            const child = &root.children[idx];
            if (self.deleted.contains(@intFromPtr(child))) continue;
            vi += 1;
            try buildItemList(self.allocator, &list, child, 0, vi == visible, &self.expanded, &self.deleted, self.sort_mode);
        }
        return list;
    }

    /// 現在ディレクトリの絶対パスをバッファに書き込み、スライスを返す。
    /// root_stack[0] = scan_base_path のルート
    /// root_stack[1..] = ドリルダウンした子ディレクトリ名
    fn buildCurrentPath(self: *const State, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.writeAll(self.scan_base_path);
        for (self.root_stack.items[1..]) |entry| {
            try w.writeByte('/');
            try w.writeAll(entry.nameSlice());
        }
        return fbs.getWritten();
    }
};

// ─── レンダリング ─────────────────────────────────────────────────────────────

const PREFIX_VERT = "│   ";
const PREFIX_NONE = "    ";
const CONNECTOR_MID = "├── ";
const CONNECTOR_LAST = "└── ";

/// 現在の状態を画面に描画する
fn render(writer: anytype, state: *const State, list: []const Item, term_rows: usize) !void {
    try writer.writeAll(esc.clear_screen ++ esc.cursor_home);

    // ヘッダー: キーバインド表示 (ソートモードを含む)
    try writer.writeAll(esc.bold ++ esc.fg_cyan);
    try writer.writeAll(" sz - interactive mode");
    try writer.writeAll(esc.reset);
    try writer.print(
        "  [↑↓] nav  [Enter] expand  [←→] drill  [s] sort:{s}  [d] del  [q] quit\n",
        .{state.sort_mode.label()},
    );

    // パス表示
    try writer.writeAll(esc.dim);
    try writer.writeAll(" Path: ");
    const root = state.currentRoot();
    try writer.writeAll(root.nameSlice());
    try writer.writeAll(esc.reset);
    try writer.writeByte('\n');

    // ルートサイズ
    var root_size_buf: [16]u8 = undefined;
    const root_size_str = size_fmt.fmt(&root_size_buf, root.total_size);
    try writer.print("  {s:>7}  {s}\n", .{ root_size_str, root.nameSlice() });
    try writer.writeByte('\n');

    // ヘッダー行を除いたコンテンツ行数
    const header_lines: usize = 4;
    const content_rows = if (term_rows > header_lines) term_rows - header_lines else 10;

    // スクロールオフセット (カーソルが見える範囲に収まるよう調整)
    const offset: usize = blk: {
        if (state.cursor < content_rows) break :blk 0;
        break :blk state.cursor - content_rows + 1;
    };

    var prefix_buf: [2048]u8 = undefined;
    var row: usize = 0;
    for (list, 0..) |item, idx| {
        if (idx < offset) continue;
        if (row >= content_rows) break;

        const is_cursor = (idx == state.cursor);

        // インデント用プレフィックスを構築
        var prefix_len: usize = 0;
        var d: u32 = 0;
        while (d < item.depth) : (d += 1) {
            const cont = PREFIX_NONE;
            if (prefix_len + cont.len <= prefix_buf.len) {
                std.mem.copyForwards(u8, prefix_buf[prefix_len..][0..cont.len], cont);
                prefix_len += cont.len;
            }
        }
        const prefix = prefix_buf[0..prefix_len];
        const connector = if (item.is_last) CONNECTOR_LAST else CONNECTOR_MID;

        var size_buf: [16]u8 = undefined;
        const size_str = size_fmt.fmt(&size_buf, item.entry.total_size);

        // 展開インジケーター
        const has_children = item.entry.children.len > 0;
        const indicator: []const u8 = if (has_children)
            if (item.expanded) "▼ " else "▶ "
        else
            "  ";

        if (is_cursor) {
            try writer.writeAll(esc.bg_blue ++ esc.fg_white ++ esc.bold);
        }

        try writer.print("  {s}{s}{s}{s:>7}  {s}", .{
            prefix,
            connector,
            indicator,
            size_str,
            item.entry.nameSlice(),
        });

        if (is_cursor) {
            try writer.writeAll(esc.reset);
        }
        try writer.writeByte('\n');

        row += 1;
    }

    // フッター
    try writer.writeAll(esc.dim);
    try writer.print("\n  {d} items", .{list.len});
    if (state.root_stack.items.len > 1) {
        try writer.print("  (depth {d})", .{state.root_stack.items.len - 1});
    }
    try writer.writeAll(esc.reset);
    try writer.writeByte('\n');

    // 削除確認ダイアログ (オーバーレイ表示)
    if (state.confirm_delete and list.len > 0) {
        const item = list[state.cursor];
        try writer.writeAll(esc.bold ++ esc.fg_red);
        try writer.print("\n  Delete '{s}'? [y/N] ", .{item.entry.nameSlice()});
        try writer.writeAll(esc.reset);
    }
}

// ─── ターミナルサイズ取得 ──────────────────────────────────────────────────────

fn getTerminalRows() usize {
    // TIOCGWINSZ で取得を試みる。失敗時はデフォルト 24 行
    const winsize_t = extern struct {
        ws_row: u16,
        ws_col: u16,
        ws_xpixel: u16,
        ws_ypixel: u16,
    };
    var ws: winsize_t = undefined;
    const builtin = @import("builtin");
    if (comptime builtin.os.tag == .linux) {
        // Linux: TIOCGWINSZ = 0x5413、直接 syscall を使用 (libc 不要)
        const ret = std.os.linux.ioctl(STDOUT_FD, 0x5413, @intFromPtr(&ws));
        if (ret == 0 and ws.ws_row > 0) return ws.ws_row;
    } else {
        // macOS/Darwin: TIOCGWINSZ = 0x40087468
        const ret = std.c.ioctl(STDOUT_FD, @as(u32, 0x40087468), &ws);
        if (ret == 0 and ws.ws_row > 0) return ws.ws_row;
    }
    return 24;
}

// ─── メインループ ─────────────────────────────────────────────────────────────

/// TUIモードを起動してユーザー操作を処理する。
/// `root` はスキャン済みの DirEntry ルート。
/// `scan_path` はスキャン対象パス (絶対・相対どちらでも可)。
pub fn run(allocator: std.mem.Allocator, root: *const types.DirEntry, scan_path: []const u8) !void {
    // スキャンパスを絶対パスに解決 (失敗時はそのまま使う)
    var base_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_path = std.fs.cwd().realpath(scan_path, &base_path_buf) catch scan_path;

    // SIGWINCH ハンドラを設定 (ターミナルリサイズ対応)
    setupSigWinch();

    try enterRawMode();
    defer exitRawMode();

    // カーソルを隠す
    try std.fs.File.stdout().writeAll(esc.cursor_hide);
    defer std.fs.File.stdout().writeAll(esc.cursor_show) catch {};

    var state = try State.init(allocator, root, base_path);
    defer state.deinit();

    // フレームバッファ: 1フレーム分の出力を溜めてから一括出力することでちらつきを防ぐ
    var frame_buf: std.ArrayList(u8) = .{};
    defer frame_buf.deinit(allocator);

    while (true) {
        var list = try state.buildList();
        defer list.deinit(allocator);

        const term_rows = getTerminalRows();
        frame_buf.clearRetainingCapacity();
        try render(frame_buf.writer(allocator), &state, list.items, term_rows);
        try std.fs.File.stdout().writeAll(frame_buf.items);

        const key = try readKey();

        // ─── 削除確認モード中のキー処理 ─────────────────────────────────────
        if (state.confirm_delete) {
            switch (key) {
                .confirm_yes => {
                    state.confirm_delete = false;
                    if (list.items.len > 0) {
                        const item = list.items[state.cursor];
                        // 削除対象の絶対パスを構築
                        var current_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const current_dir = try state.buildCurrentPath(&current_path_buf);
                        var full_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const full_path = try std.fmt.bufPrint(
                            &full_path_buf,
                            "{s}/{s}",
                            .{ current_dir, item.entry.nameSlice() },
                        );
                        // ファイルまたはディレクトリを削除
                        std.fs.deleteFileAbsolute(full_path) catch |e| {
                            if (e == error.IsDir) {
                                std.fs.deleteTreeAbsolute(full_path) catch {};
                            }
                        };
                        // 削除済みセットに追加してリストから除外
                        try state.deleted.put(@intFromPtr(item.entry), {});
                        // カーソル位置を調整
                        var new_list = try state.buildList();
                        defer new_list.deinit(allocator);
                        if (new_list.items.len > 0 and state.cursor >= new_list.items.len) {
                            state.cursor = new_list.items.len - 1;
                        } else if (new_list.items.len == 0) {
                            state.cursor = 0;
                        }
                    }
                },
                // y 以外はすべてキャンセル
                else => {
                    state.confirm_delete = false;
                },
            }
            continue;
        }

        // ─── 通常モードのキー処理 ────────────────────────────────────────────
        switch (key) {
            .quit => break,

            .up => {
                if (state.cursor > 0) {
                    state.cursor -= 1;
                }
            },

            .down => {
                if (list.items.len > 0 and state.cursor < list.items.len - 1) {
                    state.cursor += 1;
                }
            },

            .enter => {
                if (list.items.len == 0) continue;
                const item = list.items[state.cursor];
                if (item.entry.children.len == 0) continue;

                const key_val = @intFromPtr(item.entry);
                if (state.expanded.contains(key_val)) {
                    // 展開済み → 折りたたむ
                    _ = state.expanded.remove(key_val);
                } else {
                    // 未展開 → 展開する
                    try state.expanded.put(key_val, {});
                }
                // カーソル位置をリストのサイズに収める
                var new_list = try state.buildList();
                defer new_list.deinit(allocator);
                if (state.cursor >= new_list.items.len and new_list.items.len > 0) {
                    state.cursor = new_list.items.len - 1;
                }
            },

            .right => {
                // ドリルダウン: 選択中のエントリをルートに変更
                if (list.items.len == 0) continue;
                const item = list.items[state.cursor];
                if (item.entry.children.len == 0) continue;
                try state.root_stack.append(allocator, item.entry);
                state.cursor = 0;
                state.expanded.clearRetainingCapacity();
            },

            .left => {
                // 上位ディレクトリに戻る
                if (state.root_stack.items.len > 1) {
                    _ = state.root_stack.pop();
                    state.cursor = 0;
                    state.expanded.clearRetainingCapacity();
                }
            },

            .sort => {
                // ソートモードをサイクル: size → name → files → size
                state.sort_mode = state.sort_mode.next();
                state.cursor = 0;
            },

            .delete => {
                // 削除確認ダイアログを表示
                if (list.items.len > 0) {
                    state.confirm_delete = true;
                }
            },

            .confirm_yes, .confirm_no, .escape, .unknown => {},
        }
    }

    // 終了時に画面をクリア
    frame_buf.clearRetainingCapacity();
    try frame_buf.writer(allocator).writeAll(esc.clear_screen ++ esc.cursor_home);
    try std.fs.File.stdout().writeAll(frame_buf.items);
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

test "buildItemList: flat entries (no expansion)" {
    const allocator = std.testing.allocator;
    var children = [_]types.DirEntry{
        makeEntry("a", 100, &.{}),
        makeEntry("b", 200, &.{}),
    };
    const root = makeEntry(".", 300, &children);
    var expanded = std.AutoHashMap(usize, void).init(allocator);
    defer expanded.deinit();
    var deleted = std.AutoHashMap(usize, void).init(allocator);
    defer deleted.deinit();

    var list: std.ArrayList(Item) = .{};
    defer list.deinit(allocator);

    for (root.children, 0..) |*child, i| {
        try buildItemList(allocator, &list, child, 0, i == root.children.len - 1, &expanded, &deleted, .size);
    }

    // 展開なしなので a, b の2項目のみ
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    // サイズ降順ソートなので b(200) が先 (ただしここでは親ループで追加しているため順序は元のまま)
    try std.testing.expectEqualStrings("a", list.items[0].entry.nameSlice());
    try std.testing.expectEqualStrings("b", list.items[1].entry.nameSlice());
}

test "buildItemList: expanded entry shows children" {
    const allocator = std.testing.allocator;
    var grandchildren = [_]types.DirEntry{
        makeEntry("child1", 50, &.{}),
    };
    var children = [_]types.DirEntry{
        makeEntry("parent", 150, &grandchildren),
    };
    const root = makeEntry(".", 150, &children);
    var expanded = std.AutoHashMap(usize, void).init(allocator);
    defer expanded.deinit();
    var deleted = std.AutoHashMap(usize, void).init(allocator);
    defer deleted.deinit();

    // parent を展開済みとしてマーク
    try expanded.put(@intFromPtr(&children[0]), {});

    var list: std.ArrayList(Item) = .{};
    defer list.deinit(allocator);

    for (root.children, 0..) |*child, i| {
        try buildItemList(allocator, &list, child, 0, i == root.children.len - 1, &expanded, &deleted, .size);
    }

    // parent + child1 の2項目
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("parent", list.items[0].entry.nameSlice());
    try std.testing.expect(list.items[0].expanded);
    try std.testing.expectEqualStrings("child1", list.items[1].entry.nameSlice());
}

test "buildItemList: deleted entry is skipped" {
    const allocator = std.testing.allocator;
    var children = [_]types.DirEntry{
        makeEntry("a", 100, &.{}),
        makeEntry("b", 200, &.{}),
    };
    const root = makeEntry(".", 300, &children);
    var expanded = std.AutoHashMap(usize, void).init(allocator);
    defer expanded.deinit();
    var deleted = std.AutoHashMap(usize, void).init(allocator);
    defer deleted.deinit();

    // b を削除済みとしてマーク
    try deleted.put(@intFromPtr(&children[1]), {});

    var list: std.ArrayList(Item) = .{};
    defer list.deinit(allocator);

    for (root.children, 0..) |*child, i| {
        if (deleted.contains(@intFromPtr(child))) continue;
        try buildItemList(allocator, &list, child, 0, i == root.children.len - 1, &expanded, &deleted, .size);
    }

    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("a", list.items[0].entry.nameSlice());
}

test "sortedChildIndices: size descending" {
    const allocator = std.testing.allocator;
    const children = [_]types.DirEntry{
        makeEntry("small", 10, &.{}),
        makeEntry("large", 100, &.{}),
        makeEntry("mid", 50, &.{}),
    };
    const indices = try sortedChildIndices(allocator, &children, .size);
    defer allocator.free(indices);

    try std.testing.expectEqual(@as(usize, 1), indices[0]); // large
    try std.testing.expectEqual(@as(usize, 2), indices[1]); // mid
    try std.testing.expectEqual(@as(usize, 0), indices[2]); // small
}

test "sortedChildIndices: name ascending" {
    const allocator = std.testing.allocator;
    const children = [_]types.DirEntry{
        makeEntry("c", 30, &.{}),
        makeEntry("a", 10, &.{}),
        makeEntry("b", 20, &.{}),
    };
    const indices = try sortedChildIndices(allocator, &children, .name);
    defer allocator.free(indices);

    try std.testing.expectEqualStrings("a", children[indices[0]].nameSlice());
    try std.testing.expectEqualStrings("b", children[indices[1]].nameSlice());
    try std.testing.expectEqualStrings("c", children[indices[2]].nameSlice());
}

test "SortMode: next cycles correctly" {
    try std.testing.expectEqual(SortMode.name, SortMode.size.next());
    try std.testing.expectEqual(SortMode.file_count, SortMode.name.next());
    try std.testing.expectEqual(SortMode.size, SortMode.file_count.next());
}

test "State: init and currentRoot" {
    const allocator = std.testing.allocator;
    const root = makeEntry(".", 0, &.{});
    var state = try State.init(allocator, &root, ".");
    defer state.deinit();

    try std.testing.expectEqualStrings(".", state.currentRoot().nameSlice());
    try std.testing.expectEqual(@as(usize, 0), state.cursor);
    try std.testing.expectEqual(SortMode.size, state.sort_mode);
    try std.testing.expect(!state.confirm_delete);
}

test "State: drill-down and back" {
    const allocator = std.testing.allocator;
    var children = [_]types.DirEntry{
        makeEntry("sub", 100, &.{}),
    };
    const root = makeEntry(".", 100, &children);
    var state = try State.init(allocator, &root, ".");
    defer state.deinit();

    // ドリルダウン
    try state.root_stack.append(allocator, &children[0]);
    try std.testing.expectEqualStrings("sub", state.currentRoot().nameSlice());
    try std.testing.expectEqual(@as(usize, 2), state.root_stack.items.len);

    // 戻る
    _ = state.root_stack.pop();
    try std.testing.expectEqualStrings(".", state.currentRoot().nameSlice());
    try std.testing.expectEqual(@as(usize, 1), state.root_stack.items.len);
}

test "getTerminalRows: returns positive row count" {
    const rows = getTerminalRows();
    try std.testing.expect(rows > 0);
}

test "State: buildCurrentPath with drill-down" {
    const allocator = std.testing.allocator;
    var children = [_]types.DirEntry{
        makeEntry("subdir", 100, &.{}),
    };
    const root = makeEntry("myroot", 100, &children);
    var state = try State.init(allocator, &root, "/base/path");
    defer state.deinit();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path0 = try state.buildCurrentPath(&buf);
    try std.testing.expectEqualStrings("/base/path", path0);

    // ドリルダウン後
    try state.root_stack.append(allocator, &children[0]);
    const path1 = try state.buildCurrentPath(&buf);
    try std.testing.expectEqualStrings("/base/path/subdir", path1);
}
