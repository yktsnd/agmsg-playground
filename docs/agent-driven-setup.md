# エージェント主導セットアップ

このリポジトリのセットアップは「人間がターミナルで叩く」だけでなく、**エージェント(Claude Code / Codex のセッション)自身が実行する**ことを一級のユースケースとして設計しています。実際、この環境一式は Claude Code のセッションが自律的に構築したものであり、そこで踏んだ問題はすべてスクリプト側で対策済みです。

## なぜエージェント主導が現実的なのか

「マルチエージェント環境を作る」作業自体が、依存インストール・設定ファイル編集・worktree 作成・チーム join という定型作業の連続で、まさにエージェントに任せたい種類の仕事です。典型的な流れ:

1. 人間が Claude Code に「このリポジトリに自律ペアを組んで」と頼む
2. Claude Code が `setup.sh` を実行し、`team doctor` で検証し、`team start` でペアを起動する
3. 人間は認証ログインと最終的な push/merge だけ行う

このとき step 2 の Claude Code は「外側のエージェント」となり、内側に別の claude / codex セッションを産むことになります。これが**同型ネストセッション問題**の発生条件です。

## 同型ネストの罠(対策済み)

エージェントのセッションは自分の身元を環境変数で持っています(claude-code: `CLAUDE_CODE_SESSION_ID` ほか約27変数、codex: `CODEX_THREAD_ID` / `CODEX_SANDBOX`)。tmux のペインは起動元の環境変数をそのまま継承するため、**外側と同じ型のエージェントを内側に起動すると、子が親のセッションを自分のものと誤認**します。claude-code では毎ターン `Authentication error` になる形で実測されました(認証情報は正しいのに、です)。

対策は「同型のセッション識別変数を起動直前に剥がす」ことで、両起動経路に組み込み済みです:

| 起動経路 | 対策 |
|---|---|
| claude ペイン | `launch-claude-reviewer.sh` が `CLAUDE_CODE_*` / `CLAUDECODE` 系を strip してから exec |
| codex ペイン | `team start` が `env -u CODEX_SANDBOX -u CODEX_THREAD_ID` を前置して起動 |

素のターミナルから実行した場合はこれらの変数が元々存在しないので、どちらも no-op です。**エージェントが独自の方法で claude / codex を直接起動してはいけません** — 必ず team スクリプト経由で起動してください。

`team doctor` に「outer agent session check」があり、外側セッションの変数を検出すると報告します:

```
== outer agent session check ==
  outer claude-code session detected (CLAUDE_CODE_SESSION_ID/CLAUDECODE set)
  -> handled: claude pane starts via launch-claude-reviewer.sh, which strips these vars
```

## 人間とエージェントの分業

| 作業 | 担当 | 理由 |
|---|---|---|
| 依存インストール、agmsg 導入、worktree 作成、チーム join、設定生成 | エージェント | `setup.sh` 一発。冪等なので失敗しても再実行できる |
| `team start/stop/status/doctor` の運用 | エージェント | 全部スクリプト化済み |
| claude / codex の初回ログイン | **人間** | OAuth / デバイスコードはブラウザでの対話が必要。一度通れば認証情報がキャッシュされ、以降エージェントだけで回る |
| `git push` / `main` へのマージ / デプロイ | **人間** | 安全設計上、エージェントには恒久的に禁止 |
| ESCALATED の裁定 | **人間** | レビュー 2 ラウンドで解決しなかった問題の最終判断 |

## エージェント向けランブック

セットアップを任されたエージェントは、次の手順をそのまま実行してください:

```bash
# 1. セットアップ(冪等。再実行安全)
bash tools/agmsg-autonomous/setup.sh /path/to/target-repo

# 2. 検証(問題数が exit code になる)
cd /path/to/target-repo-agent
.agent/bin/team doctor

# 3. 認証確認 - 未ログインならここで人間に依頼して待つ。
#    勝手に認証フローを進めたり、認証情報ファイルを直接触ったりしない。

# 4. 起動と確認
.agent/bin/team start
.agent/bin/team status

# 5. 疎通確認(送信は send.sh の 4 位置引数を厳守)
~/.agents/skills/agmsg/scripts/send.sh <team> <your-agent-name> codex-impl "ping"
```

守るべき制約(生成される AGENTS.md / CLAUDE.md にも明記):

- `--dangerously-skip-permissions` / `--danger-full-access` を使わない
- 設定ファイルを編集する前にバックアップ(setup.sh は自動でやる)
- push / merge / デプロイをしない
- claude / codex を team スクリプトを経由せず素起動しない(上記のネスト対策を迂回してしまうため)

## 未対策の既知事項

- agmsg 本体の `spawn.sh` にも同じネスト問題があります(こちらで再現・修正・テスト済み、upstream 提案待ち)。詳細は [docs/upstream/](upstream/) を参照。upstream に取り込まれるまで、この環境では `spawn.sh` ではなく `team start` を使ってください。
- リモート実行環境(Claude Code on the web 等)では `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` のような fd 参照変数も確認されており、セッション ID 衝突とは別の壊れ方をする可能性があります。strip 対象は広め(`CLAUDE_CODE_*` 全体)に取ってあるのはこのためです。
