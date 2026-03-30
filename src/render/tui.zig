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
    const fg_yellow = "\x1b[33m";
    const fg_green = "\x1b[32m";
    const bg_blue = "\x1b[44m";
    const fg_white = "\x1b[37m";
};

// ─── キー入力 ─────────────────────────────────────────────────────────────────

const Key = enum {
    up,
    down,
    left,
    right,
    enter,
    quit,
    unknown,
};

/// stdin から1キーを読み取り Key に変換する
fn readKey() !Key {
    var buf: [4]u8 = undefined;
    const n = try posix.read(STDIN_FD, &buf);
    if (n == 0) return .unknown;

    if (buf[0] == 'q' or buf[0] == 'Q') return .quit;
    if (buf[0] == '\r' or buf[0] == '\n') return .enter;

    // ESC シーケンス (例: \x1b[A = 上矢印)
    if (n >= 3 and buf[0] == 0x1b and buf[1] == '[') {
        return switch (buf[2]) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            else => .unknown,
        };
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

/// DirEntry ツリーを深さ優先でフラットなリストに展開する。
/// `expanded_set` に含まれるエントリの子も再帰的に追加する。
fn buildItemList(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Item),
    entry: *const types.DirEntry,
    depth: u32,
    is_last: bool,
    expanded_set: *const std.AutoHashMap(usize, void),
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
        for (entry.children, 0..) |*child, i| {
            const child_is_last = (i == entry.children.len - 1);
            try buildItemList(allocator, list, child, depth + 1, child_is_last, expanded_set);
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
    /// カーソル位置 (現在表示中のフラットリストのインデックス)
    cursor: usize,

    fn init(allocator: std.mem.Allocator, root: *const types.DirEntry) !State {
        var stack: std.ArrayList(*const types.DirEntry) = .{};
        try stack.append(allocator, root);
        return State{
            .allocator = allocator,
            .root_stack = stack,
            .expanded = std.AutoHashMap(usize, void).init(allocator),
            .cursor = 0,
        };
    }

    fn deinit(self: *State) void {
        self.root_stack.deinit(self.allocator);
        self.expanded.deinit();
    }

    fn currentRoot(self: *const State) *const types.DirEntry {
        return self.root_stack.items[self.root_stack.items.len - 1];
    }

    /// フラットリストを構築して返す (呼び出し元が deinit する責任を持つ)
    fn buildList(self: *const State) !std.ArrayList(Item) {
        var list: std.ArrayList(Item) = .{};
        const root = self.currentRoot();
        for (root.children, 0..) |*child, i| {
            const is_last = (i == root.children.len - 1);
            try buildItemList(self.allocator, &list, child, 0, is_last, &self.expanded);
        }
        return list;
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

    // ヘッダー: 現在のパス
    try writer.writeAll(esc.bold ++ esc.fg_cyan);
    try writer.writeAll(" sz - interactive mode");
    try writer.writeAll(esc.reset);
    try writer.writeAll("  [↑↓] navigate  [Enter] expand/collapse  [←] up  [q] quit\n");

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

        try writer.print("  {s}{s}{s}{s:>7}  {s}{s}", .{
            prefix,
            connector,
            indicator,
            size_str,
            item.entry.nameSlice(),
            if (is_cursor) "" else "",
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
    const TIOCGWINSZ: u32 = 0x40087468; // macOS/Darwin
    const ret = std.c.ioctl(STDOUT_FD, TIOCGWINSZ, &ws);
    if (ret == 0 and ws.ws_row > 0) {
        return ws.ws_row;
    }
    return 24;
}

// ─── メインループ ─────────────────────────────────────────────────────────────

/// TUIモードを起動してユーザー操作を処理する。
/// `root` はスキャン済みの DirEntry ルート。
pub fn run(allocator: std.mem.Allocator, root: *const types.DirEntry) !void {
    try enterRawMode();
    defer exitRawMode();

    // カーソルを隠す
    try std.fs.File.stdout().writeAll(esc.cursor_hide);
    defer std.fs.File.stdout().writeAll(esc.cursor_show) catch {};

    var state = try State.init(allocator, root);
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

            .unknown => {},
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

    var list: std.ArrayList(Item) = .{};
    defer list.deinit(allocator);

    for (root.children, 0..) |*child, i| {
        try buildItemList(allocator, &list, child, 0, i == root.children.len - 1, &expanded);
    }

    // 展開なしなので a, b の2項目のみ
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
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

    // parent を展開済みとしてマーク
    try expanded.put(@intFromPtr(&children[0]), {});

    var list: std.ArrayList(Item) = .{};
    defer list.deinit(allocator);

    for (root.children, 0..) |*child, i| {
        try buildItemList(allocator, &list, child, 0, i == root.children.len - 1, &expanded);
    }

    // parent + child1 の2項目
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("parent", list.items[0].entry.nameSlice());
    try std.testing.expect(list.items[0].expanded);
    try std.testing.expectEqualStrings("child1", list.items[1].entry.nameSlice());
}

test "State: init and currentRoot" {
    const allocator = std.testing.allocator;
    const root = makeEntry(".", 0, &.{});
    var state = try State.init(allocator, &root);
    defer state.deinit();

    try std.testing.expectEqualStrings(".", state.currentRoot().nameSlice());
    try std.testing.expectEqual(@as(usize, 0), state.cursor);
}

test "State: drill-down and back" {
    const allocator = std.testing.allocator;
    var children = [_]types.DirEntry{
        makeEntry("sub", 100, &.{}),
    };
    const root = makeEntry(".", 100, &children);
    var state = try State.init(allocator, &root);
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
