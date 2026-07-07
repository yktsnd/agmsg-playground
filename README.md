# agmsg-playground

**このリポジトリを、あなたのコーディングエージェントに渡してください。** 中身を読んだエージェントが、[agmsg](https://github.com/fujibee/agmsg) を使って Claude Code と Codex CLI の自律開発ペアを、対象リポジトリ上に自分で組み立てます。人間がやるのはログインと最終承認だけです。

```
あなた:  「このリポジトリのやり方で、~/work/my-app に自律ペアを組んで」
エージェント: setup.sh を実行 → team doctor で検証 → team start で起動
          → 「claude / codex ともに認証が必要です。ログインしてください」
あなた:  ブラウザで OAuth / デバイスコード認証を1回だけ完了
エージェント: 疎通確認 → 準備完了を報告
```

以降、Codex(実装)と Claude Code(レビュー)が agmsg 経由でメッセージをやり取りし、「実装 → レビュー依頼 → 指摘修正 → 再レビュー」のループを人間の介入なしに回します。レビューは 1 変更につき最大 2 ラウンド、解決しなければ `ESCALATED` として人間に差し戻します。push・`main` へのマージ・デプロイは常に人間の仕事です。

## なぜ「エージェント主導」が起点なのか

マルチエージェント環境の構築(依存インストール、設定編集、worktree 作成、チーム join、ペインの起動)は定型作業の連続で、そもそもエージェントに任せるのが自然な仕事です。実際、このリポジトリ一式は Claude Code のセッションが自分自身で構築しました。

その過程で、**エージェントがエージェントを起動する**という構図特有の罠を実地で踏み、対策済みです: 外側のセッション(このセットアップを実行しているエージェント自身)が内側に同型のエージェント(claude→claude、codex→codex)を起動すると、外側のセッション識別変数(`CLAUDE_CODE_SESSION_ID`、`CODEX_THREAD_ID` など)が tmux 経由で子にそのまま継承され、認証エラーを引き起こします。この環境は起動経路の両方(claude ペイン・codex ペイン)でこれを検知・剥離し、`team doctor` で診断できるようにしてあります。詳細は [docs/agent-driven-setup.md](docs/agent-driven-setup.md)。

## クイックスタート

エージェントに指示する場合もあなた自身が叩く場合も、コマンドは同じです。

```bash
# 1. 対象リポジトリに自律ペアを構築(冪等・再実行安全)
bash tools/agmsg-autonomous/setup.sh /path/to/your-repo

# 2. 生成された worktree に移動して検証・起動
cd /path/to/your-repo-agent
.agent/bin/team doctor    # 環境診断(問題があれば exit code で分かる)
.agent/bin/team start     # tmux 上で両エージェントを起動
.agent/bin/team status    # 稼働状況の確認
.agent/bin/team stop      # 停止
```

元に戻したいときは:

```bash
.agent/bin/rollback.sh          # dry-run(何が行われるか表示のみ)
.agent/bin/rollback.sh --yes    # 実際に停止・チーム離脱
```

初回だけ、claude / codex それぞれの CLI ログイン(OAuth / デバイスコード)が人間の対話操作として必要です。それ以降は認証情報がキャッシュされ、エージェントだけでセットアップから起動まで完結します。詳しくは [tools/agmsg-autonomous/README.md](tools/agmsg-autonomous/README.md) と [docs/agent-driven-setup.md](docs/agent-driven-setup.md) を参照してください。

## 人間とエージェントの分業

| 作業 | 担当 |
|---|---|
| 依存インストール・agmsg 導入・worktree 作成・チーム join・設定生成 | エージェント(`setup.sh` 一発、冪等) |
| `team start/stop/status/doctor` の運用 | エージェント |
| claude / codex の初回ログイン | **人間**(ブラウザでの対話が必須) |
| `git push` / `main` へのマージ / デプロイ | **人間**(エージェントには恒久的に禁止) |
| ESCALATED(レビュー2ラウンドで未解決)の裁定 | **人間** |

## 安全設計

- `--dangerously-skip-permissions` / `bypassPermissions` / Codex の `--danger-full-access` は使わない(Codex は workspace-write サンドボックスで実行)
- force-push・`main` へのマージ・デプロイはエージェント禁止
- 既存ブランチ・作業ツリーには触れず、専用 worktree + 専用ブランチ(既定: `agent/autonomous`)のみ使用
- 設定ファイル(`~/.codex/config.toml` など)を書き換える前にタイムスタンプ付きバックアップを作成
- ロールバックは未コミットの作業がある worktree の削除を拒否する
- エージェントは claude / codex を素のコマンドで直接起動しない — 必ず team スクリプト経由(同型ネストセッション対策を経由するため)

## リポジトリ構成

| パス | 内容 |
|---|---|
| `CLAUDE.md` | この repo を開いたエージェントへの案内(セットアップを任されたときの入口) |
| `tools/agmsg-autonomous/` | 自律ペアを任意のリポジトリに構築するセットアップスクリプト一式 |
| `docs/agent-driven-setup.md` | エージェント主導セットアップのランブックと人間/エージェントの分業の詳細 |
| `docs/architecture.md` | 仕組みの解説(コンポーネント構成・配信モード・レビューループ) |
| `docs/troubleshooting.md` | 構築・運用で実際に踏んだ罠と対処の記録 |
| `docs/upstream/` | agmsg 本体に見つかった同種の問題への検証済み修正(提案準備中) |
| `playground/` | 自律ペアの作業題材となるサンプルプロジェクト(`wordstats`)とタスクバックログ |
| `projects/sekimori/` | AI プロトタイプ公開用ミニゲートウェイ(manabi-repeat 収束後の新プロジェクト。独立した README・`docs/` を持つ) |

## License

[MIT](LICENSE)
