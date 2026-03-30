# sz

高速なディレクトリサイズビジュアライザー。`du` より速く、インタラクティブな TUI モードも備えています。

## 特徴

- **高速スキャン**: 並列ワーカーとプラットフォーム最適化 (Linux: `getdents64` / `io_uring`、macOS: POSIX readdir)
- **ツリー表示 / フラット表示**: ディレクトリ構造を見やすく可視化
- **インタラクティブ TUI**: キーボード操作でディレクトリを探索・削除
- **フィルタリング**: サイズ・名前・更新日時・プリセットで絞り込み
- **エクスポート**: JSON / CSV 形式で出力、スナップショット比較
- **Zig 製**: 単一バイナリで依存なし

## インストール

### 必要環境

- [Zig](https://ziglang.org/) 0.15 以上

### ビルド

```sh
git clone https://github.com/AI1411/sz.git
cd sz
zig build -Doptimize=ReleaseFast
```

ビルドされたバイナリは `zig-out/bin/sz` に生成されます。

```sh
# PATH に追加 (任意)
cp zig-out/bin/sz ~/.local/bin/
```

## 使い方

```sh
sz [OPTIONS] [PATH]
```

`PATH` を省略するとカレントディレクトリをスキャンします。

### 基本例

```sh
# カレントディレクトリをスキャン
sz

# 指定ディレクトリをスキャン
sz /home/user

# 深さ2まで表示、上位5件に絞る
sz -d 2 -t 5 /var/log

# フラット表示 (サイズ降順)
sz --flat /usr/local

# インタラクティブ TUI モード
sz -i /home/user
```

## オプション一覧

| オプション | 説明 |
|-----------|------|
| `-d, --depth <N>` | 表示する最大深さ (デフォルト: 3) |
| `-t, --top <N>` | ディレクトリあたりの最大表示件数 (デフォルト: 10) |
| `-j, --jobs <N>` | 並列ワーカー数 (デフォルト: CPU コア数) |
| `--flat` | フラット表示 (サイズ降順) |
| `-L, --follow-links` | シンボリックリンクを追跡 |
| `-x, --cross-mount` | マウントポイントを跨いでスキャン |
| `-m, --min <SIZE>` | SIZE 以上のエントリのみ表示 (例: `100MB`) |
| `-M, --max <SIZE>` | SIZE 以下のエントリのみ表示 |
| `--exclude PATTERN` | PATTERN に一致するエントリを除外 (繰り返し指定可) |
| `--only PATTERN` | PATTERN に一致するエントリのみ表示 (カンマ区切り可) |
| `--preset NAME` | プリセットフィルタを適用 (`dev`, `media`, `logs`) |
| `--json` | JSON 形式で stdout に出力 |
| `--csv` | CSV 形式で stdout に出力 |
| `--save <PATH>` | スキャン結果を JSON スナップショットとして保存 |
| `--apparent` | ディスク使用量ではなく見かけ上のサイズ (`st_size`) を使用 |
| `--older <Nd>` | N 日より古いエントリのみ表示 (例: `30d`) |
| `--assert-max <SZ>` | 合計サイズが SIZE を超えたら exit 1 (例: `500MB`) |
| `--compare <PATH>` | 保存済み JSON スナップショットと比較 |
| `-1, --one-level` | 1 階層のみ表示 (`--depth 1` と同等) |
| `-i, --interactive` | インタラクティブ TUI モードを起動 |
| `-h, --help` | ヘルプを表示 |
| `-V, --version` | バージョンを表示 |

## TUI モード

`sz -i` で起動するインタラクティブモードのキー操作:

| キー | 動作 |
|------|------|
| `↑` / `↓` | カーソル移動 |
| `Enter` | ディレクトリを展開 / 折りたたむ |
| `→` | 選択ディレクトリにドリルダウン |
| `←` | 上位ディレクトリに戻る |
| `s` | ソート順を切り替え (size → name → files → size) |
| `d` | 選択アイテムを削除 (確認ダイアログあり) |
| `q` | 終了 |

ターミナルをリサイズすると自動的に再描画されます (SIGWINCH 対応)。

## フィルタ例

```sh
# 100MB 以上のディレクトリのみ表示
sz -m 100MB /var

# node_modules を除外
sz --exclude node_modules ~/projects

# 30 日以上更新がないファイルを表示
sz --older 30d ~/Downloads

# CI でサイズ上限チェック (超えたら exit 1)
sz --assert-max 500MB ./dist
```

## エクスポートと比較

```sh
# スナップショットを保存
sz --save baseline.json /home/user

# 変更を比較
sz --compare baseline.json /home/user

# JSON で出力
sz --json /var/log | jq '.children[].name'
```

## スクリーンショット

### ツリー表示

```
$ sz -d 2 -t 5 ~/projects/myapp

  831.2 MB  myapp
  ├── 829.0 MB  .zig-cache  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  99.7%
  │   ├── 818.8 MB  o  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  98.8%
  │   ├──  9.5 MB  h  ░░░░░░░░░░░░░░░░░░░░  1.1%
  │   └── 784.0 KB  z  ░░░░░░░░░░░░░░░░░░░░  0.1%
  ├──  1.3 MB  .git  ░░░░░░░░░░░░░░░░░░░░  0.2%
  │   ├──  1.1 MB  objects  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░  85.8%
  │   └── 44.0 KB  logs  ▓░░░░░░░░░░░░░░░░░░░  3.4%
  ├── 252.0 KB  src  ░░░░░░░░░░░░░░░░░░░░  0.0%
  └── 188.0 KB  (2 others)  ░░░░░░░░░░░░░░░░░░░░  0.0%

  2356 files, 378 dirs, 34ms
```

### フラット表示

```
$ sz --flat -t 5 ~/projects/myapp/src

  88.0 KB  ./scanner/
  68.0 KB  ./render/
  36.0 KB  ./utils/
  28.0 KB  ./export/
  20.0 KB  ./filter/

  Showing top 5 of 5 dirs (--top N to change)
  1ms
```

## ベンチマーク

### 計測環境

| 項目 | 値 |
|------|-----|
| CPU | Apple M4 Max (16コア) |
| RAM | 128 GB |
| OS | macOS 15 (Sequoia) |
| ビルド | `zig build -Doptimize=ReleaseFast` |
| 計測ツール | [hyperfine](https://github.com/sharkdp/hyperfine) (warmup 2回, 5回計測) |

> **Note**: macOS は POSIX readdir を使用。Linux では `getdents64` / `io_uring` による追加最適化が有効になります。

### 10 万ファイル (100,000 files)

| ツール | 平均時間 | sz との比 |
|--------|---------|----------|
| **sz** | **82.6 ms** | **1.00x** |
| du | 111.6 ms | 1.35x 遅い |
| gdu | 111.8 ms | 1.35x 遅い |
| dust | 115.4 ms | 1.40x 遅い |
| ncdu | 187.3 ms | 2.27x 遅い |

## 他ツールとの比較

| 機能 | sz | du | ncdu | dust | gdu |
|------|:--:|:--:|:----:|:----:|:---:|
| 並列スキャン | ✅ | ❌ | ✅ | ✅ | ✅ |
| TUI モード | ✅ | ❌ | ✅ | ❌ | ✅ |
| JSON 出力 | ✅ | ❌ | ✅ | ❌ | ❌ |
| CSV 出力 | ✅ | ❌ | ❌ | ❌ | ❌ |
| スナップショット比較 | ✅ | ❌ | ❌ | ❌ | ❌ |
| io_uring 最適化 (Linux) | ✅ | ❌ | ❌ | ❌ | ❌ |
| フィルタリング | ✅ | 限定的 | ❌ | 限定的 | ❌ |
| 単一バイナリ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 依存なし | ✅ | ✅ | ❌ | ❌ | ❌ |
| バイナリサイズ | **320 KB** | OS標準 | 432 KB | ~3 MB | ~10 MB |

## プラットフォームサポート

| プラットフォーム | サポート | ビルド確認 |
|-----------------|---------|-----------|
| macOS Apple Silicon (arm64) | ✅ P1 | ✅ 動作確認済み |
| macOS Intel (x86_64) | ✅ P2 | ✅ クロスコンパイル確認済み |
| Linux x86_64 | ✅ P1 | ✅ クロスコンパイル確認済み |
| Linux aarch64 (ARM/Raspberry Pi) | ✅ P1 | ✅ クロスコンパイル確認済み |

### バイナリサイズ

| ビルドモード | サイズ (macOS arm64) | サイズ (Linux aarch64) |
|------------|-------------------|----------------------|
| `ReleaseFast` | 320 KB | - |
| `ReleaseSmall` | 217 KB | 153 KB |
| `ReleaseSmall` + strip | 180 KB | - |

すべてのビルドで静的リンク・外部依存ゼロ・500 KB 以下を達成。

## ライセンス

MIT
