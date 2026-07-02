# Same-type `spawn` (e.g. claude-code → claude-code) can inherit the parent's session-identity env vars and break auth in the child

## If you're seeing this

You spawned a peer of the **same CLI type** you're already running in (e.g.
a `claude-code` session doing `agmsg spawn claude-code <name>` to bring up
a second `claude-code` peer for review/second-opinion), and the new pane
immediately shows a persistent `Authentication error · This may be a
temporary network issue` on every turn — even though your login/credentials
are fine. This might be why.

## What seems to be happening

`spawn.sh` launches the new CLI in a fresh tmux pane/window (or OS
terminal) without touching the environment at all. That's fine when the
spawned type differs from the parent's — but if you spawn the *same* type
you're already running as, the child inherits the parent's own
session-identity env vars verbatim, because tmux `new-window`/`split-window`
(and the OS-terminal paths) copy the calling shell's exported environment
into the new pane as-is:

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

`spawn.sh`'s generated `.command` boot script behaves the same way — it
execs the CLI with no `unset`, so anything `spawn.sh` itself inherited
reaches the child unchanged.

A few ordinary ways this comes up (none of them exotic):

- Spawning a second peer of the same type for an independent second
  opinion, along the lines of the tech-lead/biz-analyst pattern in
  `docs/actas.md` — nothing there requires the two roles to be different
  CLI types.
- A `claude-code` session's own Bash tool running `agmsg spawn claude-code
  <name>` to bootstrap a teammate — the spawning shell already has the
  full identity var set exported, no extra layering needed.
- A CI/orchestration runner that is itself (or wraps) a `claude-code`
  process and fans out several same-type workers into tmux panes on one
  host.

I hit this building a small Claude↔Codex pairing setup on top of agmsg
(a side project, not trying to plug it here — just explaining how this
surfaced) — the outer session doing the setup was itself `claude-code`,
and it needed to launch an independent `claude-code` reviewer alongside a
`codex` peer. The `codex` pane was unaffected; the `claude-code` pane
broke immediately.

## Root cause, as far as I can tell

`type.conf`'s `detect=` field already names the env var(s) that identify a
running session of a given type (`detect=CLAUDE_CODE_SESSION_ID` for
claude-code; also declared for `codex`, `gemini`, `grok-build`), but
`spawn.sh` never reads it — so nothing stops a same-type child from
"detecting" its parent's session instead of getting its own.

For claude-code, the blast radius looks bigger than just the session id.
A live Claude Code Bash-tool environment exports roughly 27
`CLAUDE_CODE_*`/`CLAUDECODE` vars, and some of them are more than plain
identifiers:

```
CLAUDECODE=1
CLAUDE_CODE_SESSION_ID=...
CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=4
CLAUDE_CODE_WEBSOCKET_AUTH_FILE_DESCRIPTOR=3
CLAUDE_CODE_CHILD_SESSION=1
... (~20 more)
```

The two `*_FILE_DESCRIPTOR` vars name fd numbers that are only meaningful
in the *original* process. A child that inherits the var but not the
actual open fd seems like a plausible mechanism for the auth-error
symptom, on top of (or instead of) plain session-id collision. I don't
have a clean isolated proof of which var(s) are actually responsible —
just noting it in case it saves someone time, since a fix scoped only to
`detect=CLAUDE_CODE_SESSION_ID` might turn out to be necessary but not
sufficient for claude-code specifically.

## What worked for us

Not asserting this is *the* fix — just sharing what we verified, in case
it's a reasonable starting point. Reads `detect=` (already-existing
manifest data, no new field needed) and unsets it before the CLI line in
the generated boot script:

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

(full diff also attached as `spawn-detect-vars-unset.patch`, includes two
new `tests/test_spawn.bats` cases)

With this applied: `tests/test_spawn.bats` — 44 existing + 2 new = 46
cases, all pass; the new cases fail without the `spawn.sh` change
(confirmed by stashing just that file and rerunning), so they do exercise
the fix; `bash -n scripts/spawn.sh` is clean.

If a broader strip (everything matching `CLAUDE_CODE_*`/`CLAUDECODE*`,
not just `detect=`) turns out to be the right call for claude-code given
the fd-var uncertainty above, happy to test that version instead — didn't
want to bake in a bigger behavioral change without checking first.

## Environment

- agmsg `1.1.3` (main @ `f665c1c`)
- Reproduced on Linux with a locally-built tmux socket (`tmux -L`) and via
  the existing bats `AGMSG_TERMINAL` stub path used by `tests/test_spawn.bats`.

Happy to open a PR with the patch above if that direction looks right —
or if you already have a preferred approach, just let me know and I'm glad
to adjust.
