# playground

自律開発ペア(codex-impl / claude-reviewer)の作業題材を置くディレクトリです。

## wordstats

テキストの統計(行数・単語数・文字数・頻出単語)を出す小さな CLI。Python 標準ライブラリのみで動きます。

```bash
# ファイルから
python3 -m wordstats sample.txt

# 標準入力から
echo "the quick brown fox jumps over the lazy dog" | python3 -m wordstats

# 頻出単語の表示数を変える
python3 -m wordstats --top 3 sample.txt
```

テスト:

```bash
cd playground
python3 -m unittest discover -s tests -v
```

## タスクの流し方

未着手のタスクは [BACKLOG.md](BACKLOG.md) にあります。人間が agmsg 経由で
`codex-impl` にタスクを 1 件割り当てると、実装 → `claude-reviewer` のレビュー →
指摘修正のループが自動で回ります(最大 2 ラウンド、未解決なら `ESCALATED`)。

```bash
~/.agents/skills/agmsg/scripts/send.sh <team> human codex-impl \
  "BACKLOG.md の W-1 をお願いします"
```
