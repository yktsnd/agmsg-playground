# agmsg-playground

[agmsg](https://github.com/fujibee/agmsg) を使って **Claude Code と Codex CLI の自律開発ペア**を動かすための実験場です。

- **Codex (`codex-impl`)** … 唯一の実装エージェント。コード・テスト・設定を編集する
- **Claude Code (`claude-reviewer`)** … 設計相談とレビュー専任。ファイルは一切編集しない

2 つのエージェントは agmsg(SQLite ベースのエージェント間メッセージング。デーモン不要)でメッセージをやり取りし、専用の git worktree 上で「実装 → レビュー依頼 → 指摘修正 → 再レビュー」のループを人間の介入なしに回します。レビューは 1 変更につき最大 2 ラウンドで、解決しなければ `ESCALATED` として人間に引き継ぎます。

## クイックスタート

任意の git リポジトリに対して 1 コマンドでペアを構築できます:

```bash
bash tools/agmsg-autonomous/setup.sh /path/to/your-repo
```

セットアップ後、生成された worktree(既定: `<repo>-agent/`)から起動します:

```bash
cd /path/to/your-repo-agent
.agent/bin/team start    # tmux 上で両エージェントを起動
.agent/bin/team status   # 稼働状況の確認
.agent/bin/team doctor   # 環境診断
.agent/bin/team stop     # 停止
```

元に戻したいときは:

```bash
.agent/bin/rollback.sh          # dry-run(何が行われるか表示のみ)
.agent/bin/rollback.sh --yes    # 実際に停止・チーム離脱
```

詳細は [tools/agmsg-autonomous/README.md](tools/agmsg-autonomous/README.md) を参照してください。

## リポジトリ構成

| パス | 内容 |
|---|---|
| `tools/agmsg-autonomous/` | 自律ペアを任意のリポジトリに構築するセットアップスクリプト一式 |
| `docs/architecture.md` | 仕組みの解説(コンポーネント構成・メッセージフロー) |
| `docs/troubleshooting.md` | 構築時に実際に踏んだ罠と対処の記録 |
| `playground/` | 自律ペアの作業題材となるサンプルプロジェクト(`wordstats`)とタスクバックログ |

## 安全設計

セットアップとエージェント運用は以下を厳守します:

- `--dangerously-skip-permissions` / `bypassPermissions` / Codex の `--danger-full-access` は使わない(Codex は workspace-write サンドボックスで実行)
- force-push・`main` へのマージ・デプロイはエージェント禁止(人間専用の操作)
- 既存ブランチ・作業ツリーには触らず、専用 worktree + 専用ブランチ(既定: `agent/autonomous`)のみ使用
- 設定ファイル(`~/.codex/config.toml` など)を書き換える前にタイムスタンプ付きバックアップを作成
- ロールバックは未コミットの作業がある worktree の削除を拒否する

## License

[MIT](LICENSE)
