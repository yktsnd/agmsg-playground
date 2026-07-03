# Same-type `agmsg spawn` (claude-code → claude-code) inherits the parent's session-identity env vars, breaks auth

We hit this building an autonomous dev pair: a Claude Code reviewer and a
Codex implementer, coordinated over agmsg. The setup itself runs as a
`claude-code` session, and it uses `spawn` to start both peers — including
a second, independent `claude-code` process for the reviewer. That
`claude-code`-spawning-`claude-code` step is what triggers the bug below.

This is a fairly specific use case, so if it's outside what `spawn` is
meant to support, feel free to close — just sharing the bug and fix in
case they're useful.

## Symptom

Spawning a peer of the **same CLI type** you're already running as (e.g.
`claude-code` doing `agmsg spawn claude-code <name>`) leaves the child
showing a persistent `Authentication error` on every turn, even with
valid credentials.

## Cause

`spawn.sh`'s generated boot script execs the CLI without touching the
environment. tmux `new-window`/`split-window` copy the parent shell's
exported env verbatim, so a same-type child inherits the parent's
session-identity vars (`CLAUDE_CODE_SESSION_ID`, `CLAUDECODE`) and
mistakes the parent's session for its own:

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

Related: #93 fixed a different flavor of the same "two processes, one
session_id" shape (resume, not spawn). #142 notes a process-tree fallback
in `whoami` that might mean env-var stripping alone isn't the full
picture.

## Fix

`type.conf`'s `detect=` already names the session-identity var(s) per
type — `spawn.sh` just never reads it. Unset them at the top of the
generated boot script:

```diff
--- a/scripts/spawn.sh
+++ b/scripts/spawn.sh
@@
 PROMPT_ARG="$(agmsg_type_get "$AGENT_TYPE" prompt_arg)"

+DETECT_VARS="$(agmsg_type_get "$AGENT_TYPE" detect)"
+[ "$DETECT_VARS" = "explicit" ] && DETECT_VARS=""
+
 # Extra CLI args for this type from the spawn options file (opt-in, see
@@
 {
   echo '#!/usr/bin/env bash'
   printf 'cd %q || exit 1\n' "$PROJECT"
+  if [ -n "$DETECT_VARS" ]; then
+    printf 'unset %s\n' "$DETECT_VARS"
+  fi
   if [ -n "$SPAWN_AGENT" ]; then
```

46/46 `tests/test_spawn.bats` pass with this applied (2 new cases);
confirmed they fail without it. Happy to PR if this fits, or adjust the
approach if you'd rather handle it differently.

agmsg `1.1.3` (main @ `f665c1c`), reproduced on Linux.
