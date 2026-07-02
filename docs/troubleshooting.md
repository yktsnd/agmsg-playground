# トラブルシューティング

このペア環境を実際に構築したときに踏んだ問題と対処の記録です。同じ症状に当たったらまずここを見てください。

## 1. ネストした Claude セッションで「Authentication error」

**症状**: tmux ペイン内の Claude Code が、正しい OAuth 認証情報があるのに毎ターン
`Authentication error · This may be a temporary network issue` を出す。

**原因**: 外側の環境(別の Claude Code セッションや管理ツール)から
`CLAUDE_CODE_SESSION_ID` などの環境変数を継承し、セッション ID が衝突していた。
認証情報の問題ではない。

**対処**: `claude` を起動する前に `CLAUDE_CODE_*` / `CLAUDECODE` 系の環境変数を
すべて剥がす。setup.sh が生成する `.agent/bin/launch-claude-reviewer.sh` が
これを行うので、tmux から直接 `claude` を叩かずに必ずラッパー経由で起動すること。
非管理環境ではこれらの変数は元々存在しないため、ラッパーは無害。

codex 側にも同型の危険(`CODEX_THREAD_ID` / `CODEX_SANDBOX` の継承)があり、
`team start` が `env -u` で剥がして起動する。外側セッションの検出状況は
`team doctor` の「outer agent session check」で確認できる。この問題が
どういう構成で起きるかの全体像は [agent-driven-setup.md](agent-driven-setup.md)、
agmsg 本体の `spawn.sh` にある同種の問題(修正提案済み)は
[upstream/](upstream/) を参照。

## 2. send.sh の引数順ミスでメッセージが届かない

**症状**: `send.sh` は正常終了し DB にも行が入るのに、相手エージェントに届かない。

**原因**: Monitor ツールの `watch.sh <session_id> <project_path> <agent_type>` の
引数形を `send.sh` に持ち込み、`<team> <from> <to> "<message>"` の順序を崩していた。
間違った値が team / 宛先として解釈され、存在しない宛先に「配達」される。

**対処**: 正しい形は常に:

```bash
~/.agents/skills/agmsg/scripts/send.sh <team> <from> <to> "<message>"
```

再発防止として、生成される `AGENTS.md` / `CLAUDE.md` の両方に正確なシグネチャを
明記してある。

## 3. rollback が `~/.codex/config.toml` を丸ごと消していた(修正済み)

**症状**(旧版): あるリポジトリで `--restore-configs` を実行すると、他リポジトリの
ペアも依存しているマシン共通の `~/.codex/config.toml`(`sandbox_mode`、
`writable_roots`)ごと消えた。

**対処**: 現行版は該当 worktree の `[projects."<path>"]` エントリ**だけ**を削除し、
削除前にタイムスタンプ付きバックアップを作る。ファイル全体の削除はスクリプトでは
行わない設計に変更した。誤って消してしまった場合は `~/.codex/config.toml.*.bak`
から復元するか、任意のリポジトリで setup.sh を再実行すれば共通設定が再生成される。

## 4. ヘッドレス環境での初回ログイン

**症状**: コンテナ・リモート環境ではブラウザが開けず、Claude の OAuth も Codex の
ChatGPT サインイン(localhost コールバック)も完了できない。

**対処**:
- **Claude**: 手元のブラウザで OAuth を完了し、表示されたコードを tmux ペインの
  プロンプトに貼り付ける。
- **Codex**: ブラウザサインインが使えない場合はデバイスコードフロー
  (<https://auth.openai.com/codex/device>)を使う。
- どちらも一度成功すれば認証情報がキャッシュされ(`~/.claude/.credentials.json`、
  `~/.codex/`)、以降のセッションでは再ログイン不要。

## 5. サンドボックス化されたネットワークで agmsg が取得できない

**症状**: ネットワークポリシーによっては GitHub への `git clone` が塞がれていて
agmsg のインストールが失敗する。

**対処**: setup.sh は clone 失敗時に jsdelivr CDN からファイル単位で取得する
フォールバックを持つ。それでも失敗する場合は、別マシンで取得した
`~/.agents/skills/agmsg/` を持ち込み `--skip-agmsg-install` を付けて実行する。

## 6. API 利用枠の消費が速い

**症状**: ペアを常駐させてテストしていると、Claude / Codex 双方の利用枠警告が
早期に出る。

**対処**: PING/PONG のような疎通確認は最小限にする。アイドル時の不要なターンを
発生させない(agmsg はデーモンレスなので、メッセージがなければ消費は発生しない)。
作業がないときは `team stop` で落としておくのが安全。

## 診断の入口

原因がわからないときはまず:

```bash
.agent/bin/team doctor   # 依存・設定・チーム登録・配信モードを一括診断
.agent/bin/team status   # tmux / ブリッジの生存確認
.agent/bin/team logs     # 直近のログ
```
