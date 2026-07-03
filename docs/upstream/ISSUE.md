# Memo: same-type `agmsg spawn` can break auth in the child (claude-code → claude-code)

This is a write-up for anyone building an agent-driven multi-agent setup on
top of agmsg, in case you hit the same wall we did. It can also serve as
the basis for an issue/PR against fujibee/agmsg — see `PR_BODY.md` and
`spawn-detect-vars-unset.patch` in this folder.

## What we were doing

Building an autonomous Claude↔Codex dev pair on agmsg (this repo). The
setup itself was run by a `claude-code` session, which needed to launch an
independent `claude-code` "reviewer" peer alongside a `codex` peer inside
the same tmux session.

## The problem we hit

The `claude-code` reviewer pane broke immediately: every turn showed a
persistent `Authentication error · This may be a temporary network issue`,
even though the login/credentials were valid. The `codex` pane was fine.

**Cause**: `agmsg spawn.sh` launches a new CLI in a tmux pane/window
without touching the environment. tmux `new-window`/`split-window` copy
the calling shell's exported env into the new pane verbatim — so when you
spawn a peer of the **same CLI type** you're already running as, the child
inherits the parent's own session-identity env vars (`CLAUDE_CODE_SESSION_ID`,
`CLAUDECODE`, ...) and ends up "detecting" the parent's session instead of
getting its own. Confirmed directly:

```bash
export CLAUDE_CODE_SESSION_ID=outer-session-abc123
export CLAUDECODE=1
tmux new-session -d -s repro 'sleep 30'
tmux new-window -t repro -n child \
  'env | grep -E "^CLAUDE_CODE_SESSION_ID|^CLAUDECODE" > /tmp/child-env.txt'
cat /tmp/child-env.txt
# CLAUDE_CODE_SESSION_ID=outer-session-abc123
# CLAUDECODE=1
```

This isn't exotic — it's the normal shape of an actas-style same-type peer
(`docs/actas.md`'s tech-lead/biz-analyst pattern), or simply a `claude-code`
session using its own Bash tool to `agmsg spawn claude-code <name>` to
bootstrap a teammate.

Caveat: `claude-code`'s environment carries ~27 `CLAUDE_CODE_*`/`CLAUDECODE`
vars, including two (`CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR`,
`CLAUDE_CODE_WEBSOCKET_AUTH_FILE_DESCRIPTOR`) that name file-descriptor
numbers only meaningful in the original process. We couldn't isolate
whether the auth error comes from the session-id collision, the stale fd
refs, or both — worth knowing if the narrower fix below doesn't fully
resolve it for you.

## How we solved it

`type.conf`'s `detect=` field already names the session-identity var(s)
for each agent type (`CLAUDE_CODE_SESSION_ID` for claude-code; also
declared for `codex`, `gemini`, `grok-build`), but `spawn.sh` never reads
it. Fix: read `detect=` and `unset` those vars as the first line of the
generated boot script, before the CLI runs — `spawn-detect-vars-unset.patch`
in this folder (+17 lines in `scripts/spawn.sh`, +2 regression tests in
`tests/test_spawn.bats`, 46/46 passing).

Until this lands upstream, our own `.agent/bin/team` script works around
it directly: the claude pane launches through
`launch-claude-reviewer.sh` (strips the full `CLAUDE_CODE_*`/`CLAUDECODE`
family — broader than just `detect=`, to also cover the fd-var caveat
above), and the codex pane launches under
`env -u CODEX_SANDBOX -u CODEX_THREAD_ID`. See
[docs/agent-driven-setup.md](../agent-driven-setup.md) for the full
picture and [docs/troubleshooting.md](../troubleshooting.md) for other
issues we hit along the way.

## Environment

agmsg `1.1.3` (main @ `f665c1c`), reproduced on Linux.
