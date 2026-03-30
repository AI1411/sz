# sz — 要件定義書

## 1. プロジェクト概要

### 1.1 プロダクト名

**sz** (size) — ファイル/ディレクトリサイズの高速可視化ツール

### 1.2 概要

Zig製の超高速ディスク使用量アナライザ。ディレクトリ内の何がどれだけディスクを消費しているかを、ツリーマップ風の可視化で瞬時に把握できるCLIツール。
`du` の代替として、並列ファイルシステム走査による圧倒的な速度と、直感的な表示を両立する。

### 1.3 開発動機

- `du -sh *` は遅い（シングルスレッド）、出力がソートされない、視覚性が低い
- `ncdu` はインタラクティブだが初回スキャンが遅い、TUI操作が前提
- 開発者は `node_modules`、`.git`、`target/`、`__pycache__` 等の肥大化を頻繁に確認する必要がある
- dk（Dockerクリーンアップ）と組み合わせて、ディスク逼迫時のワークフローを完結させたい

### 1.4 ポジショニング

| ツール    | 言語      | 速度     | 可視化           | インタラクティブ      | サイズ        |
|--------|---------|--------|---------------|---------------|------------|
| du     | C       | 遅い     | なし            | ×             | OS標準       |
| ncdu   | C       | 中程度    | バー            | ○ (TUI必須)     | 小          |
| dust   | Rust    | 速い     | バー+ツリー        | ×             | 3MB        |
| gdu    | Go      | 速い     | バー            | ○             | 10MB       |
| dua    | Rust    | 速い     | バー            | ○             | 3MB        |
| **sz** | **Zig** | **最速** | **バー+比率+色分け** | **○ (オプション)** | **<500KB** |

sz の差別化: 最小バイナリサイズ、最速スキャン（io_uring対応）、ワンショットでもTUIでも使える柔軟性、他ツール（dk, vt）との統合。

---

## 2. ユーザーストーリー

### 2.1 主要ユースケース

**US-1: ディスク逼迫の原因特定**
「ディスクが90%使用中と vt に表示された。sz でルートディレクトリを調べて、何がディスクを食っているか3秒で特定したい」

**US-2: プロジェクトの肥大化チェック**
「開発プロジェクトのディレクトリが大きくなりすぎた。node_modules、.git、ビルド成果物のどれが主因か一目で確認したい」

**US-3: クリーンアップ対象の判断**
「不要なディレクトリを削除してディスクを解放したい。どれを消せばどれだけ空くか、サイズ降順で確認したい」

**US-4: CI/CDでのサイズ監視**
「ビルド成果物のサイズが閾値を超えたらCIを失敗させたい。sz の終了コードとJSON出力で自動チェックしたい」

**US-5: 複数ディレクトリの比較**
「本番サーバーの /var/log と /tmp のどちらがディスクを圧迫しているか、並べて比較したい」

### 2.2 ペルソナ

- **バックエンドエンジニア**: Go/Rust/Node.js プロジェクトの依存・ビルドキャッシュの肥大化を頻繁に確認
- **インフラ/SRE**: 本番サーバーのディスク逼迫時に即座に原因を特定したい
- **1人LLC/フリーランス**: 限られたVPSのディスクを効率的に管理

---

## 3. 機能要件

### 3.1 コア機能

#### F-1: 高速ディレクトリスキャン

- 指定ディレクトリ以下の全ファイル/ディレクトリのサイズを再帰的に集計する
- 並列走査（ワーカースレッドプール）で最大スループットを出す
- Linux では io_uring、非対応環境では getdents64 syscall で高速化
- シンボリックリンクはデフォルトで追跡しない（`--follow-links` で追跡可）
- マウントポイントの境界はデフォルトで越えない（`--cross-mount` で越えられる）

#### F-2: ツリー表示（デフォルト）

- サイズ降順でディレクトリ/ファイルをインデントツリー表示
- 各エントリにサイズバーと割合を表示
- デフォルト深さ: 3階層（`--depth N` で変更可）
- デフォルト表示数: 上位10件（`--top N` で変更可）
- 閾値以下のエントリは「その他 (N items)」にまとめる

```
$ sz

  1.2 GB  ./
  ├── 487 MB  node_modules/        ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░  40.2%
  │   ├── 89 MB   @next/             ▓▓▓▓░░░░░░░░░░░░░░░░  18.3%
  │   ├── 67 MB   typescript/        ▓▓▓░░░░░░░░░░░░░░░░░░  13.8%
  │   ├── 45 MB   @babel/            ▓▓░░░░░░░░░░░░░░░░░░░   9.2%
  │   └── 286 MB  (1,247 others)     ▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░  58.7%
  ├── 312 MB  .git/                ▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░  25.8%
  │   ├── 298 MB  objects/           ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░  95.5%
  │   └── 14 MB   (others)           ▓░░░░░░░░░░░░░░░░░░░░   4.5%
  ├── 198 MB  .next/               ▓▓▓▓▓▓░░░░░░░░░░░░░░░  16.4%
  ├── 112 MB  public/              ▓▓▓░░░░░░░░░░░░░░░░░░░   9.3%
  ├── 56 MB   src/                 ▓▓░░░░░░░░░░░░░░░░░░░░   4.6%
  └── 44 MB   (23 others)          ▓░░░░░░░░░░░░░░░░░░░░░   3.7%

  Files: 12,847    Dirs: 1,923    Scanned in 0.12s
```

#### F-3: フラット表示

- ツリー構造を無視して、全ディレクトリをサイズ降順でフラット表示
- 「どのディレクトリが一番大きいか」を最短で把握できる

```
$ sz --flat

  487 MB  ./node_modules/
  312 MB  ./.git/
  298 MB  ./.git/objects/
  198 MB  ./.next/
  112 MB  ./public/
   89 MB  ./node_modules/@next/
   67 MB  ./node_modules/typescript/
   56 MB  ./src/
   45 MB  ./node_modules/@babel/
   44 MB  ./.next/cache/

  Showing top 10 of 1,923 dirs (--top N to change)
```

#### F-4: インタラクティブTUIモード

- `sz -i` でncdu風のインタラクティブモードを起動
- ディレクトリの展開/折りたたみ、ドリルダウン、ソート切替が可能
- TUI内から直接削除操作（確認付き）

```
┌─ sz interactive ─────────────────────────────────────────────┐
│  /home/akira/project  ·  1.2 GB  ·  12,847 files            │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  SIZE     %     NAME                                         │
│  ──────────────────────────────────────────────────────────  │
│  487 MB   40.2  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  node_modules/            │
│  312 MB   25.8  ▓▓▓▓▓▓▓▓▓▓▓       .git/                     │
│  198 MB   16.4  ▓▓▓▓▓▓▓           .next/                    │
│  112 MB    9.3  ▓▓▓▓              public/                    │
│   56 MB    4.6  ▓▓                src/                       │
│   22 MB    1.8  ▓                 dist/                      │
│   12 MB    1.0  ▓                 .yarn/                     │
│    4 MB    0.3                    scripts/                   │
│    2 MB    0.2                    docs/                      │
│    1 MB    0.1                    tests/                     │
│  ──────────────────────────────────────────────────────────  │
│  497 KB    0.0                    (13 others)                │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│ [Enter] 展開  [←] 戻る  [d] 削除  [s] ソート  [q] 終了     │
└──────────────────────────────────────────────────────────────┘
```

#### F-5: フィルタ/除外

- パターンでファイル/ディレクトリを除外または限定できる

```bash
# 特定ディレクトリを除外
sz --exclude node_modules --exclude .git

# 特定パターンのみ表示
sz --only "*.log"
sz --only "*.jpg,*.png,*.gif"

# 巨大ファイルだけ表示
sz --min 100MB

# 古いファイルだけ表示
sz --older 30d

# プリセット: 開発プロジェクト用 (node_modules, .git, target, __pycache__ 等を除外)
sz --preset dev
```

#### F-6: 出力フォーマット

```bash
# JSON出力（CI/CD連携）
sz --json

# CSV出力（表計算ソフト連携）
sz --csv

# 比較モード: 2時点のスナップショットを比較
sz --save snapshot-v1.json
# ... 時間経過 ...
sz --compare snapshot-v1.json
```

#### F-7: CI/CD向け機能

```bash
# 閾値チェック: 指定サイズを超えたら exit 1
sz --assert-max 500MB ./dist
# → dist/ が 500MB を超えたら exit 1、CI失敗

# 特定ディレクトリの存在＋サイズチェック
sz --assert-max 100MB ./node_modules/@next
```

---

## 4. 非機能要件

### 4.1 パフォーマンス

| 指標     | 目標値             | 計測条件          |
|--------|-----------------|---------------|
| スキャン速度 | 100万ファイルを < 2秒  | NVMe SSD、8コア  |
| スキャン速度 | 10万ファイルを < 0.3秒 | NVMe SSD、8コア  |
| 起動時間   | < 5ms           | スキャン開始まで      |
| メモリ使用量 | < 50MB          | 100万ファイルスキャン時 |
| CPU使用率 | 全コア活用           | スキャン中         |

### 4.2 サイズ・依存

| 指標      | 目標値                     |
|---------|-------------------------|
| バイナリサイズ | < 500KB (static linked) |
| 外部依存    | ゼロ                      |
| libc依存  | なし (Linux: 直接syscall)   |

### 4.3 対応環境

| 環境                    | 優先度 | 備考            |
|-----------------------|-----|---------------|
| Linux x86_64          | P0  | 主要ターゲット       |
| Linux aarch64         | P1  | ARM サーバー/ラズパイ |
| macOS (Apple Silicon) | P2  | 開発機           |
| macOS (Intel)         | P3  | レガシー開発機       |

### 4.4 セキュリティ

- 権限のないファイル/ディレクトリはスキップし、stderr に警告を出す
- シンボリックリンクのループを検出し、無限再帰を防ぐ
- 削除操作（TUIモード）は常に確認ダイアログを表示

---

## 5. CLI インターフェース仕様

### 5.1 基本構文

```
sz [PATH...] [OPTIONS]
```

PATH を省略した場合はカレントディレクトリを対象とする。

### 5.2 オプション一覧

```
表示オプション:
  -d, --depth <N>         表示深さ (デフォルト: 3)
  -t, --top <N>           表示件数 (デフォルト: 10)
  -f, --flat              フラット表示 (ツリーなし)
  -i, --interactive       インタラクティブTUIモード
  -1, --one-level         1階層のみ表示 (du -sh * 相当)

フィルタ:
  -e, --exclude <PATTERN> パターン除外 (複数指定可)
  -o, --only <PATTERN>    パターン限定
  -m, --min <SIZE>        最小サイズフィルタ (例: 10MB)
  -M, --max <SIZE>        最大サイズフィルタ
      --older <DURATION>  N日以上古いファイル (例: 30d)
      --preset <NAME>     プリセットフィルタ (dev, media, logs)

出力:
      --json              JSON出力
      --csv               CSV出力
      --save <FILE>       スナップショット保存 (JSON)
      --compare <FILE>    スナップショットと比較

スキャン:
  -L, --follow-links      シンボリックリンクを追跡
  -x, --cross-mount       マウントポイントを越える
  -j, --jobs <N>          並列ワーカー数 (デフォルト: CPUコア数)
      --apparent           見かけのサイズ (ディスク使用量ではなくファイルサイズ)

CI/CD:
      --assert-max <SIZE> 超過時に exit 1

その他:
  -h, --help              ヘルプ表示
  -V, --version           バージョン表示
```

### 5.3 プリセット定義

```
dev:    node_modules, .git, target, __pycache__, .next, dist,
        .gradle, build, .cargo, zig-cache, zig-out を除外

media:  *.jpg, *.png, *.gif, *.mp4, *.mov, *.avi のみ表示

logs:   *.log, *.log.*, /var/log/** のみ表示
```

### 5.4 サイズ表記

```
入力 (--min, --max, --assert-max):
  100       → 100 bytes
  10KB      → 10,240 bytes
  100MB     → 104,857,600 bytes
  1GB       → 1,073,741,824 bytes

出力:
  自動スケーリング (最適な単位を選択)
  1,234 bytes → "1.2 KB"
  1,234,567   → "1.2 MB"
  小数点1桁、1024ベース
```

---

## 6. 出力仕様

### 6.1 JSON 出力

```json
{
  "root": "/home/akira/project",
  "total_size": 1288490188,
  "total_files": 12847,
  "total_dirs": 1923,
  "scan_time_ms": 120,
  "entries": [
    {
      "path": "node_modules",
      "size": 510656512,
      "percentage": 40.2,
      "files": 8234,
      "dirs": 1102,
      "children": [
        {
          "path": "node_modules/@next",
          "size": 93323264,
          "percentage": 18.3,
          "files": 412,
          "dirs": 56
        }
      ]
    }
  ]
}
```

### 6.2 CSV 出力

```csv
path,size_bytes,files,dirs,percentage
./node_modules,510656512,8234,1102,40.2
./.git,327155712,423,34,25.8
./.next,207618048,1893,287,16.4
./public,117440512,156,12,9.3
```

### 6.3 比較出力

```
$ sz --compare snapshot-v1.json

  /home/akira/project  ·  1.2 GB (+180 MB since v1)

  CHANGE     SIZE       DIFF        NAME
  ──────────────────────────────────────────────
  +34.2%     487 MB     +124 MB     node_modules/
  unchanged  312 MB     +0 B        .git/
  NEW        198 MB     +198 MB     .next/
  -15.0%     112 MB     -20 MB      public/
  DELETED    ---        -122 MB     tmp/
```

---

## 7. アーキテクチャ

### 7.1 全体構成

```
┌──────────────────────────────────────────────────────────┐
│                      CLI Entry                           │
│  sz [PATH] [OPTIONS]                                     │
└───────────────┬──────────────────────────────────────────┘
                │
                ▼
┌──────────────────────────────────────────────────────────┐
│               Parallel Scanner                           │
│                                                          │
│  ┌──────────┐                                            │
│  │  Work    │ → Thread Pool (N workers)                  │
│  │  Queue   │                                            │
│  │ (dirs)   │ → Worker: opendir → readdir → stat         │
│  └──────────┘   → サブディレクトリを queue に追加         │
│                 → ファイルサイズを atomic に集計          │
│                                                          │
│  Linux最適化:                                            │
│  - io_uring で readdir + stat をバッチ発行               │
│  - getdents64 syscall で readdir を高速化                │
└───────────────┬──────────────────────────────────────────┘
                │
                ▼
┌──────────────────────────────────────────────────────────┐
│              Size Tree (結果構造体)                       │
│                                                          │
│  root: DirEntry {                                        │
│    name, total_size, file_count, dir_count,              │
│    children: []DirEntry (sorted by size desc)            │
│  }                                                       │
└───────────────┬──────────────────────────────────────────┘
                │
        ┌───────┼───────┬──────────┐
        ▼       ▼       ▼          ▼
┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐
│ Tree   │ │ Flat   │ │ TUI    │ │ Export │
│ View   │ │ View   │ │ Mode   │ │ JSON/  │
│(stdout)│ │(stdout)│ │        │ │ CSV    │
└────────┘ └────────┘ └────────┘ └────────┘
```

### 7.2 並列スキャンの設計

```
メインスレッド:
  1. ルートディレクトリを work queue に投入
  2. ワーカースレッドを起動 (CPUコア数)
  3. 全ワーカーの完了を待つ
  4. 結果ツリーを構築

ワーカースレッド:
  loop:
    1. work queue からディレクトリパスを取得 (なければ待機)
    2. opendir → readdir で全エントリを列挙
    3. ファイル: サイズを親ノードに atomic add
    4. ディレクトリ: work queue に追加 (再帰ではなくキュー)
    5. 全エントリ処理完了 → 親ノードの remaining_children を atomic dec
    6. remaining_children == 0 → 親のサイズ確定、さらに上位へ伝播

終了条件:
  - work queue が空 AND 全ワーカーがアイドル → 完了
```

### 7.3 メモリ管理

```
Arena Allocator:
  - スキャン結果の全ノードを1つのArenaで管理
  - ノード間のポインタはArena内相対アドレス
  - 表示完了後にArena全体を一括解放
  - GCなし、断片化なし

DirEntry 構造体: (1ノードあたり約 64 bytes)
  struct DirEntry {
      name: [*]const u8,       // Arenaからのスライス
      name_len: u16,
      total_size: u64,         // 累積サイズ (atomic更新)
      file_count: u32,
      dir_count: u32,
      children: []DirEntry,    // Arenaからのスライス
      depth: u8,
  }

100万ファイル/10万ディレクトリ時のメモリ見積もり:
  - DirEntry: 100,000 × 64 bytes = 6.4 MB
  - ファイル名文字列: ~20 MB (平均200 bytes/name)
  - ワークキュー: ~1 MB
  - 合計: ~30 MB
```

---

## 8. プロジェクト構成

```
sz/
├── build.zig
├── build.zig.zon
├── README.md
│
├── src/
│   ├── main.zig               # CLI エントリ、引数パース
│   │
│   ├── scanner/
│   │   ├── parallel.zig       # 並列スキャンエンジン
│   │   ├── worker.zig         # ワーカースレッド
│   │   ├── queue.zig          # ロックフリーワークキュー
│   │   ├── linux.zig          # Linux最適化 (getdents64, io_uring)
│   │   ├── posix.zig          # POSIX フォールバック
│   │   └── types.zig          # DirEntry, ScanResult
│   │
│   ├── filter/
│   │   ├── pattern.zig        # glob パターンマッチ
│   │   ├── size.zig           # サイズフィルタ (--min, --max)
│   │   ├── age.zig            # 日付フィルタ (--older)
│   │   └── preset.zig         # プリセット定義 (dev, media, logs)
│   │
│   ├── render/
│   │   ├── tree.zig           # ツリー表示
│   │   ├── flat.zig           # フラット表示
│   │   ├── bar.zig            # サイズバー描画
│   │   ├── tui.zig            # インタラクティブTUIモード
│   │   └── compare.zig        # 比較表示
│   │
│   ├── export/
│   │   ├── json.zig           # JSON出力
│   │   ├── csv.zig            # CSV出力
│   │   └── snapshot.zig       # スナップショット保存/読込
│   │
│   └── utils/
│       ├── size_fmt.zig       # バイト数→人間可読変換 (共通ライブラリ)
│       ├── ansi.zig           # ANSIカラー (共通ライブラリ)
│       └── args.zig           # 引数パーサー
│
└── tests/
    ├── scanner_test.zig       # スキャナーユニットテスト
    ├── filter_test.zig        # フィルタテスト
    └── fixtures/
        └── test_tree/         # テスト用ディレクトリ構造
```

---

## 9. 実装フェーズ

### Phase 1: コアスキャナー + ツリー表示 (Week 1)

```
目標: sz で カレントディレクトリのツリーが表示される

タスク:
  [1] CLI引数パーサー (PATH, --depth, --top)
  [2] シングルスレッド再帰スキャナー (まず動くものを)
  [3] DirEntry ツリー構築
  [4] サイズ降順ソート
  [5] ツリー表示 (インデント + サイズバー + 割合)
  [6] サイズの人間可読フォーマット
  [7] カラー出力 (ディレクトリ/ファイル色分け)
  [8] 「その他 (N items)」の集約表示

テスト:
  - 空ディレクトリ、単一ファイル、深いネスト
  - シンボリックリンクのループ検出
  - 権限なしディレクトリのスキップ
```

### Phase 2: 並列化 + フィルタ (Week 2)

```
目標: 100万ファイルを2秒以内でスキャン、フィルタが動く

タスク:
  [1] 並列スキャンエンジン (ワーカースレッドプール)
  [2] ロックフリーワークキュー (MPMC)
  [3] アトミックなサイズ集計
  [4] Linux最適化: getdents64 syscall
  [5] --exclude, --only パターンフィルタ
  [6] --min, --max サイズフィルタ
  [7] --preset (dev, media, logs)
  [8] フラット表示モード (--flat)

ベンチマーク:
  - du, ncdu, dust, gdu との速度比較
  - 10万ファイル / 100万ファイルでの計測
```

### Phase 3: 出力フォーマット + 比較 (Week 3)

```
目標: --json, --csv, --compare が動く、CI連携可能

タスク:
  [1] JSON出力
  [2] CSV出力
  [3] スナップショット保存 (--save)
  [4] スナップショット比較 (--compare)
  [5] 比較表示 (増減, NEW, DELETED)
  [6] --assert-max (閾値チェック、exit code制御)
  [7] --older 日付フィルタ
  [8] --apparent (見かけサイズ vs ディスク使用量)
```

### Phase 4: TUI + 仕上げ (Week 4)

```
目標: sz -i でインタラクティブモード、README完成

タスク:
  [1] TUIモード基盤 (raw terminal, キー入力)
  [2] ディレクトリ展開/折りたたみ
  [3] ドリルダウン/戻る操作
  [4] ソート切替 (サイズ/名前/ファイル数)
  [5] 削除操作 (確認ダイアログ付き)
  [6] ターミナルリサイズ対応
  [7] io_uring 最適化 (Linux、Phase 2の拡張)
  [8] README / スクリーンショット / デモGIF / ベンチマーク
```

---

## 10. Zigの特性が活きるポイント

### 10.1 getdents64 による高速ディレクトリ走査

```zig
// libc の readdir() を経由せず、syscall を直接呼ぶ
// バッファサイズを大きく取ることで syscall 回数を最小化
const buf: [32768]u8 = undefined;
const n = std.os.linux.getdents64(fd, &buf, buf.len);
// 1回の syscall で数百エントリを取得
```

### 10.2 comptime でサイズ単位テーブルを構築

```zig
const SizeUnit = struct { threshold: u64, unit: []const u8, divisor: f64 };
const units = comptime [_]SizeUnit{
    .{ .threshold = 1 << 30, .unit = "GB", .divisor = 1 << 30 },
    .{ .threshold = 1 << 20, .unit = "MB", .divisor = 1 << 20 },
    .{ .threshold = 1 << 10, .unit = "KB", .divisor = 1 << 10 },
    .{ .threshold = 0,       .unit = "B",  .divisor = 1       },
};

fn formatSize(bytes: u64) struct { val: f64, unit: []const u8 } {
    inline for (units) |u| {
        if (bytes >= u.threshold)
            return .{ .val = @as(f64, @floatFromInt(bytes)) / u.divisor, .unit = u.unit };
    }
    unreachable;
}
```

### 10.3 Arena Allocator でスキャン結果を一括管理

```zig
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit(); // 表示完了後に全メモリ一括解放

const root = try scanner.scan(path, arena.allocator());
try renderer.printTree(root, stdout);
// arena.deinit() で全ノード・全文字列を一括解放
```

### 10.4 atomic 操作でロックフリー集計

```zig
// ワーカースレッドからのサイズ集計をロックなしで実行
const AtomicU64 = std.atomic.Value(u64);

const DirEntry = struct {
    total_size: AtomicU64,
    file_count: AtomicU64,

    fn addSize(self: *@This(), size: u64) void {
        _ = self.total_size.fetchAdd(size, .monotonic);
        _ = self.file_count.fetchAdd(1, .monotonic);
    }
};
```

---

## 11. 受け入れ基準

### 11.1 機能テスト

| #    | テスト項目                                           | 期待結果                 |
|------|-------------------------------------------------|----------------------|
| T-1  | `sz` (引数なし)                                     | カレントディレクトリのツリーが表示される |
| T-2  | `sz /tmp --depth 1`                             | /tmp 直下のみ表示          |
| T-3  | `sz --flat --top 5`                             | 上位5件がフラット表示          |
| T-4  | `sz --exclude node_modules`                     | node_modules が除外される  |
| T-5  | `sz --min 100MB`                                | 100MB以上のエントリのみ表示     |
| T-6  | `sz --json`                                     | 有効なJSONが stdout に出力  |
| T-7  | `sz --csv`                                      | 有効なCSVが stdout に出力   |
| T-8  | `sz --save snap.json && sz --compare snap.json` | 差分が表示される             |
| T-9  | `sz --assert-max 1KB ./large_dir`               | exit code 1          |
| T-10 | `sz --assert-max 1TB ./small_dir`               | exit code 0          |
| T-11 | `sz -i`                                         | TUI が起動し、操作可能        |
| T-12 | シンボリックリンクループのあるディレクトリ                           | 無限ループせず完了            |
| T-13 | 権限のないディレクトリ                                     | スキップ + stderr警告      |

### 11.2 パフォーマンステスト

| #   | テスト項目             | 期待結果       |
|-----|-------------------|------------|
| P-1 | 10万ファイルのスキャン      | < 0.3秒     |
| P-2 | 100万ファイルのスキャン     | < 2秒       |
| P-3 | メモリ使用量 (100万ファイル) | < 50MB RSS |
| P-4 | dust との速度比較       | 同等以上       |
| P-5 | バイナリサイズ           | < 500KB    |

---

## 12. 共通ライブラリとの統合

sz は pp, dk, vt, zb と以下のモジュールを共有する。

| 共通モジュール                 | sz での用途         | 他ツールでの用途                     |
|-------------------------|-----------------|------------------------------|
| `libs/fmt/size.zig`     | バイト→人間可読変換      | dk (イメージサイズ), vt (メモリ/ディスク)  |
| `libs/tui/terminal.zig` | TUIモードのraw mode | vt (ダッシュボード), dk (TUI)       |
| `libs/tui/bar.zig`      | サイズバー描画         | vt (CPU/MEM バー), zb (ヒストグラム) |
| `libs/tui/table.zig`    | カラム整列           | pp (ポートテーブル), dk (コンテナ一覧)    |
| `libs/tui/ansi.zig`     | カラー出力           | 全ツール共通                       |
| `libs/io/args.zig`      | CLI引数パース        | 全ツール共通                       |
| `libs/data/json.zig`    | JSON出力          | pp (--json), zb (レポート)       |

---

## 13. リスク・課題

| リスク                    | 影響                    | 対策                                |
|------------------------|-----------------------|-----------------------------------|
| io_uring 非対応環境         | スキャン速度低下              | getdents64 → readdir のフォールバックチェーン |
| 巨大ディレクトリ (1000万ファイル+)  | メモリ不足                 | ストリーミングモード検討、depth制限              |
| macOS 対応               | /proc なし、syscall が異なる | POSIX レイヤーで抽象化                    |
| dust/gdu との速度差が出ない     | 差別化困難                 | バイナリサイズ、CI統合、比較機能で差別化             |
| ファイルシステム種別 (NFS, FUSE) | stat が遅い              | --jobs 1 へのフォールバック、タイムアウト         |