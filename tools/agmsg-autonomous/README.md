# agmsg-autonomous setup

任意の git リポジトリに Claude Code ↔ Codex CLI の自律開発ペアを構築する、自己完結型のセットアップスクリプトです。Linux / macOS 対応、再実行しても安全(冪等)です。

## 前提

| 必要なもの | 備考 |
|---|---|
| git, bash | 必須 |
| sqlite3 | agmsg のバックエンド。Linux(root)なら apt-get で自動インストール |
| tmux | エージェント常駐用。同上 |
| `claude` CLI | 事前に一度ログイン済みであること(`claude` を起動して認証) |
| `codex` CLI | 同上(`codex login` またはデバイスコードフロー) |

認証だけは対話が必要なので、初回のみ手動でログインしてください。以降はキャッシュされた認証情報が使われます。

## 使い方

```bash
bash setup.sh /path/to/repo
```

引数を省略するとカレントディレクトリのリポジトリが対象になります。

### オプション

| オプション | 既定値 |
|---|---|
| `--team NAME` | `<repo名をサニタイズ>-agents` |
| `--claude-agent NAME` | `claude-reviewer` |
| `--codex-agent NAME` | `codex-impl` |
| `--branch NAME` | `agent/autonomous` |
| `--worktree PATH` | `<リポジトリの親ディレクトリ>/<repo名>-agent` |
| `--tmux-session NAME` | `<repo名をサニタイズ>-agents` |
| `--agmsg-cmd NAME` | `agmsg` |
| `--skip-agmsg-install` | agmsg のインストール/更新をスキップ |

repo 名のサニタイズは「小文字化 → 英数字とハイフン以外をハイフンに置換」です。

## setup.sh がやること

1. OS 判定と依存バイナリのチェック(Linux では sqlite3 / tmux を自動インストール)
2. agmsg を GitHub `main` からインストール/更新(git clone が塞がれたネットワークでは jsdelivr CDN からファイル単位で取得するフォールバックあり)
3. `~/.codex/config.toml` に workspace-write サンドボックス設定と agmsg の db/teams/run ディレクトリの書き込み許可を追加(既存ファイルを編集する場合はタイムスタンプ付きバックアップを作成)
4. 対象リポジトリに専用 worktree + ブランチを作成(既存ブランチ・作業ツリーには一切触れない)
5. 両エージェントを agmsg チームに join
6. 配信モードを設定 — Claude Code は `both`(Monitor ツールによるリアルタイム受信+ターン間フォールバック)、Codex は `monitor`(ベータの app-server ブリッジ経由)
7. worktree 内に以下を生成:
   - `AGENTS.md` — Codex(実装担当)のロール定義
   - `CLAUDE.md` — Claude(レビュー担当)のロール定義
   - `.agent/config.sh` — 全スクリプトが source する共有設定
   - `.agent/bin/team` — 起動・停止・状態確認のマネージャ
   - `.agent/bin/launch-claude-reviewer.sh` — ネストセッション衝突を避ける環境変数ストリッパ
   - `.agent/bin/rollback.sh` — 撤去スクリプト

## 運用コマンド(生成された worktree 内)

```bash
.agent/bin/team start     # tmux セッション上で両エージェント起動(flock で二重起動防止)
.agent/bin/team status    # tmux / ブリッジ / 配信モードの状態表示
.agent/bin/team logs      # ログ確認
.agent/bin/team doctor    # 依存・設定・チーム登録の診断
.agent/bin/team restart   # 再起動
.agent/bin/team stop      # 停止(Codex の app-server / ブリッジも終了)
```

## ロールバック

```bash
.agent/bin/rollback.sh                                        # dry-run
.agent/bin/rollback.sh --yes                                  # 停止 + 配信モード解除 + チーム離脱
.agent/bin/rollback.sh --yes --remove-worktree                # worktree も削除(未コミット変更があれば拒否)
.agent/bin/rollback.sh --yes --restore-configs                # ~/.codex/config.toml からこの worktree の trust エントリのみ削除
```

`--restore-configs` は **`[projects."<worktree>"]` エントリだけ**を削除します。`~/.codex/config.toml` はマシン共通のファイルで、他リポジトリのペアも `sandbox_mode` / `writable_roots` に依存しているため、ファイル自体の削除や共通設定の変更は行いません(削除前にタイムスタンプ付きバックアップを作成)。

## 安全上の設計判断

- 権限バイパス(`--dangerously-skip-permissions`、`--danger-full-access`)は一切使わない
- エージェントは push / merge / デプロイ禁止(ロールファイルで明示。人間専用の操作)
- レビューは 1 変更あたり最大 2 ラウンド。未解決なら `ESCALATED` を宣言してループを止め、人間を待つ
- 常駐デーモンなし。agmsg は SQLite(WAL モード)のみに依存

ハマりどころは [docs/troubleshooting.md](../../docs/troubleshooting.md) にまとめてあります。
