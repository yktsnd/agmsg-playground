# Same-type `agmsg spawn` (claude-code → claude-code) inherits the parent's session-identity env vars, breaks auth in the child

## Symptom

Spawn a peer of the **same CLI type** you're already running as (e.g. a
`claude-code` session doing `agmsg spawn claude-code <name>` to bring up a
second `claude-code` peer for review), and the new pane immediately shows
a persistent `Authentication error · This may be a temporary network
issue` on every turn — even with valid credentials.

## Cause

`spawn.sh` launches the new CLI in a tmux pane/window without touching the
environment. tmux `new-window`/`split-window` (and the OS-terminal paths)
copy the calling shell's exported env into the new pane verbatim, so a
same-type child inherits the parent's own session-identity vars
(`CLAUDE_CODE_SESSION_ID`, `CLAUDECODE`, ...) instead of getting its own:

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

Not an exotic trigger — it's the normal shape of an actas-style same-type
peer (`docs/actas.md`'s tech-lead/biz-analyst pattern), or a `claude-code`
session's own Bash tool running `agmsg spawn claude-code <name>` to
bootstrap a teammate.

Related prior art: #93 fixed a different flavor of session_id collision
(parallel `claude --continue`/`--resume` sharing a session_id, breaking
the actas lock). Same underlying shape ("two processes, one
`CLAUDE_CODE_SESSION_ID`"), different trigger and symptom here.

Open question, not fully verified: #142 notes `whoami`'s
`detect_cli_type` falls back to a process-tree (`ps`) walk when env vars
are absent. If that fallback is reachable from the same identity path,
unsetting env vars alone might not fully prevent same-type
misidentification — worth checking.

Also, for `claude-code` specifically, two of the ~27 exported
`CLAUDE_CODE_*`/`CLAUDECODE` vars name file descriptors
(`CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR`,
`CLAUDE_CODE_WEBSOCKET_AUTH_FILE_DESCRIPTOR`) meaningful only in the
original process. Couldn't isolate whether the auth error comes from the
session-id collision, the stale fd refs, or both — noting in case the fix
below turns out to be necessary but not sufficient.

## Fix

`type.conf`'s `detect=` field already names the session-identity var(s)
per type (`CLAUDE_CODE_SESSION_ID` for claude-code; also declared for
`codex`, `gemini`, `grok-build`), but `spawn.sh` never reads it. Read
`detect=` and `unset` those vars as the first line of the generated boot
script, before the CLI runs:

```diff
--- a/scripts/spawn.sh
+++ b/scripts/spawn.sh
@@
 PROMPT_ARG="$(agmsg_type_get "$AGENT_TYPE" prompt_arg)"

+# A spawned child inherits the parent shell's exported environment (tmux
+# new-window/split-window and every OS-terminal path copy it verbatim into
+# the new pane/window). If we are ourselves running inside a session of the
+# SAME type we are spawning (e.g. actas-ing a second claude-code peer from
+# inside a claude-code session), the child would inherit the parent's own
+# `detect=` session-identity vars — e.g. CLAUDE_CODE_SESSION_ID — and the
+# child CLI can mistake the parent's session for its own, breaking auth/session
+# state. `detect=` in type.conf already names exactly the vars that identify a
+# running session of this type (space-separated; "explicit" means none), so
+# unset them in the boot script before the CLI line runs. Harmless when none
+# of these vars are actually set.
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

## Testing

Added two `tests/test_spawn.bats` cases (claude-code boot script contains
`unset CLAUDE_CODE_SESSION_ID CLAUDECODE`; `detect=explicit` types get no
`unset` line). Full suite: 46/46 pass (44 existing + 2 new). Confirmed the
new tests fail without the `spawn.sh` change. `bash -n scripts/spawn.sh`
clean.

Happy to open a PR with this if the direction looks right, or adjust if
you'd prefer a broader strip (e.g. full `CLAUDE_CODE_*`/`CLAUDECODE*`,
given the fd-var caveat above).

## Environment

agmsg `1.1.3` (main @ `f665c1c`), reproduced on Linux.
