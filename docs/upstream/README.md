# upstream への提案(fujibee/agmsg)

agmsg 本体の `spawn.sh` に、このリポジトリで踏んだのと同種の**同型ネストセッション問題**があることを fork 上で再現・修正・検証済みです。ここにはその成果物を保存しています。

| ファイル | 内容 |
|---|---|
| `ISSUE.md` | Issue 本文の下書き(英語)。同じ症状(claude-code 同型ネストでの Authentication error)に遭遇した人が検索で辿り着けるよう症状ベースで書き出し、押し付けがましくならないよう「これが正解の直し方」ではなく「うちで検証した内容の共有」というトーンに統一。現実的な発生ケース・根本原因・再現手順・fd 系変数に関する未解明部分の明示を含む |
| `PR_BODY.md` | PR 本文の下書き。`<issue-number>` を実際の Issue 番号に置換して使う |
| `spawn-detect-vars-unset.patch` | 検証済みパッチ。`scripts/spawn.sh`(+17行)と `tests/test_spawn.bats`(+27行、回帰テスト2件) |

## 検証状況(2026-07-02, agmsg 1.1.3 / main @ f665c1c 時点)

- tmux の子ペインが親の `CLAUDE_CODE_SESSION_ID` を継承することを実測で確認
- 修正適用で bats 46/46 パス(既存 44 + 新規 2)、修正を外すと新規テストが red になることを確認
- `bash -n` クリーン

## 提出手順

1. GitHub で fujibee/agmsg を fork し、ブランチを切る
2. `git apply spawn-detect-vars-unset.patch`
3. `ISSUE.md` の内容で Issue を作成
4. fork に push し、`PR_BODY.md`(Issue 番号を埋める)で PR を作成

提出前に upstream の main が進んでいないか確認し、コンフリクトすればパッチを当て直すこと。upstream に取り込まれたら、このディレクトリは「取り込み済み(バージョン X.Y.Z)」と追記して閉じる。
