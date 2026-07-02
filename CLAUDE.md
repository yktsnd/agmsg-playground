# CLAUDE.md — agmsg-playground

このリポジトリは、agmsg を使った Claude Code ↔ Codex 自律開発ペアの実験場です。
**セットアップや運用をエージェント(あなた)が実行することを前提に設計されています。**

## セットアップを頼まれたら

[docs/agent-driven-setup.md](docs/agent-driven-setup.md) のランブックに従ってください。要点:

- 入口は常に `bash tools/agmsg-autonomous/setup.sh /path/to/repo`(冪等・再実行安全)
- 起動・停止・診断は生成された `<repo>-agent/.agent/bin/team {start|stop|status|doctor}` 経由のみ
- **claude / codex を素のコマンドで直接起動しない。** あなた自身がエージェントセッション内で動いている場合、同型ネストによるセッション衝突(認証エラー)を引き起こします。team スクリプトの起動経路にこの対策が組み込まれています
- 認証ログインが必要になったら人間に依頼して待つ。認証情報ファイルを直接触らない

## 全エージェント共通の禁止事項

- `git push` / `main` へのマージ / デプロイ(人間専用)
- `--dangerously-skip-permissions` / `--danger-full-access` などの権限バイパス
- `~/.codex/config.toml` 等のマシン共通設定をバックアップなしで変更・削除すること

## リポジトリ地図

- `tools/agmsg-autonomous/setup.sh` — 任意リポジトリへのペア構築スクリプト(テンプレート埋め込み・自己完結)
- `docs/architecture.md` — 仕組み(配信モード・レビューループ・命名規則)
- `docs/agent-driven-setup.md` — エージェントがセットアップを実行するときのランブック
- `docs/troubleshooting.md` — 実際に踏んだ問題と対処
- `docs/upstream/` — agmsg 本体へ提案予定の修正(検証済みパッチ+issue 下書き)
- `playground/` — ペアの作業題材(`wordstats` CLI)とタスクバックログ

テストは `cd playground && python3 -m unittest discover -s tests` で全部回ります(標準ライブラリのみ、依存インストール不要)。
