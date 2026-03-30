# sz — タスク一覧

要件定義書 (`requirements.md`) から洗い出したタスクです。
フェーズごとに整理し、依存関係を考慮した順序で記載しています。

---

## Phase 1: コアスキャナー + ツリー表示

**目標**: `sz` でカレントディレクトリのツリーが表示される

| # | タスク | ファイル | 状態 |
|---|--------|---------|------|
| 1.1 | プロジェクトセットアップ (`build.zig`, `build.zig.zon`) | `build.zig` | [ ] |
| 1.2 | CLI引数パーサー (`PATH`, `--depth`, `--top`) | `src/utils/args.zig` | [ ] |
| 1.3 | `DirEntry` 型定義 | `src/scanner/types.zig` | [ ] |
| 1.4 | シングルスレッド再帰スキャナー | `src/scanner/posix.zig` | [ ] |
| 1.5 | DirEntry ツリー構築 + サイズ降順ソート | `src/scanner/parallel.zig` | [ ] |
| 1.6 | サイズの人間可読フォーマット (1024ベース、小数1桁) | `src/utils/size_fmt.zig` | [ ] |
| 1.7 | ANSIカラー出力ユーティリティ | `src/utils/ansi.zig` | [ ] |
| 1.8 | サイズバー描画 (`▓░` 形式) | `src/render/bar.zig` | [ ] |
| 1.9 | ツリー表示 (インデント + サイズバー + 割合) | `src/render/tree.zig` | [ ] |
| 1.10 | 「その他 (N items)」の集約表示 | `src/render/tree.zig` | [ ] |
| 1.11 | エントリポイント実装 | `src/main.zig` | [ ] |
| 1.12 | スキャナーユニットテスト (空ディレクトリ・単一ファイル・深いネスト) | `tests/scanner_test.zig` | [ ] |
| 1.13 | シンボリックリンクのループ検出テスト | `tests/scanner_test.zig` | [ ] |
| 1.14 | 権限なしディレクトリのスキップテスト | `tests/scanner_test.zig` | [ ] |
| 1.15 | テスト用フィクスチャ ディレクトリ構造作成 | `tests/fixtures/test_tree/` | [ ] |

---

## Phase 2: 並列化 + フィルタ

**目標**: 100万ファイルを2秒以内でスキャン、フィルタが動く

| # | タスク | ファイル | 状態 |
|---|--------|---------|------|
| 2.1 | ロックフリーワークキュー (MPMC) | `src/scanner/queue.zig` | [ ] |
| 2.2 | ワーカースレッド実装 | `src/scanner/worker.zig` | [ ] |
| 2.3 | 並列スキャンエンジン (スレッドプール) | `src/scanner/parallel.zig` | [ ] |
| 2.4 | アトミックなサイズ集計 | `src/scanner/parallel.zig` | [ ] |
| 2.5 | Linux最適化: `getdents64` syscall | `src/scanner/linux.zig` | [ ] |
| 2.6 | `--exclude` / `--only` glob パターンフィルタ | `src/filter/pattern.zig` | [ ] |
| 2.7 | `--min` / `--max` サイズフィルタ | `src/filter/size.zig` | [ ] |
| 2.8 | `--preset` 定義 (`dev`, `media`, `logs`) | `src/filter/preset.zig` | [ ] |
| 2.9 | `--flat` フラット表示モード | `src/render/flat.zig` | [ ] |
| 2.10 | `-j, --jobs` オプション (並列ワーカー数指定) | `src/utils/args.zig` | [ ] |
| 2.11 | `--follow-links` シンボリックリンク追跡オプション | `src/scanner/posix.zig` | [ ] |
| 2.12 | `--cross-mount` マウントポイント越えオプション | `src/scanner/posix.zig` | [ ] |
| 2.13 | フィルタユニットテスト | `tests/filter_test.zig` | [ ] |
| 2.14 | ベンチマーク: `du`, `ncdu`, `dust`, `gdu` との速度比較 | — | [ ] |

---

## Phase 3: 出力フォーマット + 比較

**目標**: `--json`, `--csv`, `--compare` が動く、CI連携可能

| # | タスク | ファイル | 状態 |
|---|--------|---------|------|
| 3.1 | JSON出力 | `src/export/json.zig` | [ ] |
| 3.2 | CSV出力 | `src/export/csv.zig` | [ ] |
| 3.3 | スナップショット保存 (`--save`) | `src/export/snapshot.zig` | [ ] |
| 3.4 | スナップショット読み込み | `src/export/snapshot.zig` | [ ] |
| 3.5 | 比較表示 (増減、NEW、DELETED) (`--compare`) | `src/render/compare.zig` | [ ] |
| 3.6 | `--assert-max` 閾値チェック (exit code 制御) | `src/main.zig` | [ ] |
| 3.7 | `--older` 日付フィルタ | `src/filter/age.zig` | [ ] |
| 3.8 | `--apparent` 見かけサイズ vs ディスク使用量オプション | `src/scanner/types.zig` | [ ] |
| 3.9 | サイズ入力パース (`100MB` → bytes 変換) | `src/utils/size_fmt.zig` | [ ] |
| 3.10 | `-1, --one-level` オプション (`du -sh *` 相当) | `src/render/tree.zig` | [ ] |

---

## Phase 4: TUI + 仕上げ

**目標**: `sz -i` でインタラクティブモード、README完成

| # | タスク | ファイル | 状態 |
|---|--------|---------|------|
| 4.1 | TUIモード基盤 (raw terminal、キー入力ハンドラ) | `src/render/tui.zig` | [ ] |
| 4.2 | ディレクトリ展開/折りたたみ操作 | `src/render/tui.zig` | [ ] |
| 4.3 | ドリルダウン/戻る操作 (`Enter` / `←`) | `src/render/tui.zig` | [ ] |
| 4.4 | ソート切替 (サイズ/名前/ファイル数) (`s` キー) | `src/render/tui.zig` | [ ] |
| 4.5 | 削除操作 (確認ダイアログ付き) (`d` キー) | `src/render/tui.zig` | [ ] |
| 4.6 | ターミナルリサイズ対応 (`SIGWINCH`) | `src/render/tui.zig` | [ ] |
| 4.7 | `io_uring` 最適化 (Linux、Phase 2 拡張) | `src/scanner/linux.zig` | [ ] |
| 4.8 | README 作成 (使い方、インストール方法) | `README.md` | [ ] |
| 4.9 | スクリーンショット / デモGIF 作成 | — | [ ] |
| 4.10 | ベンチマーク結果をREADMEに記載 | `README.md` | [ ] |

---

## 横断タスク

フェーズに依存せず随時対応するタスクです。

| # | タスク | 状態 |
|---|--------|------|
| X.1 | macOS (Apple Silicon / Intel) 対応確認 | [ ] |
| X.2 | Linux aarch64 対応確認 | [ ] |
| X.3 | バイナリサイズ計測・最適化 (目標 < 500KB) | [ ] |
| X.4 | メモリ使用量計測 (目標 < 50MB @ 100万ファイル) | [ ] |
| X.5 | 起動時間計測 (目標 < 5ms) | [ ] |
| X.6 | stderr への権限警告出力の実装 | [ ] |
