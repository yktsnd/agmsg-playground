# spawn.sh leaks the parent session's `detect=` identity vars into a same-type child, breaking auth/session state

## Summary

`spawn.sh` launches a new agent CLI in a fresh tmux pane/window (or OS
terminal) without stripping any environment variables. When the process
*doing the spawning* is itself a running session of the **same type** it is
spawning — e.g. a `claude-code` session using `agmsg spawn claude-code
<name>` to bring up a second `claude-code` peer — the child inherits the
parent's own session-identity environment variables verbatim. For
`claude-code` this reliably breaks authentication in the child session.

## Why this is a realistic trigger, not an edge case

`docs/actas.md` documents multi-role patterns (e.g. tech-lead +
biz-analyst) and nothing there requires the peers to be different CLI
types — two `claude-code` peers (e.g. an implementer + an independent
reviewer for a second opinion) is an explicitly supported, natural setup.
Any of the following ordinary flows hit this:

1. **Same-type actas pairs** — a `claude-code` session spawns another
   `claude-code` peer via `agmsg spawn claude-code reviewer` for
   independent review, exactly as `docs/actas.md` illustrates.
2. **A Claude Code session managing its own agmsg team from Bash** — this
   is the most direct trigger and needs no multi-layer setup at all. A
   single `claude-code` session's own Bash tool environment already
   exports the full identity var set (see below); if that session's Bash
   tool runs `agmsg spawn claude-code <name>` (a perfectly normal way for
   an agent to bootstrap a teammate), the freshly spawned pane inherits
   them immediately.
3. **CI/orchestration runners** — a runner that itself is/wraps a
   `claude-code` process and fans out several `claude-code` workers into
   tmux panes on the same host inherits the same collision per worker.

## Root cause detail

`type.conf`'s `detect=` field exists specifically to name the env var(s)
that identify a running session of that type (`detect=CLAUDE_CODE_SESSION_ID`
for claude-code; also declared for `codex`, `gemini`, `grok-build`). But
`spawn.sh`'s boot-script generation never reads `detect=` — it just execs
the CLI, so the child ends up "detecting" the *parent's* session, not
getting its own.

For `claude-code` specifically, the blast radius is larger than just the
session id. Inspecting a live Claude Code Bash tool environment shows
~27 exported `CLAUDE_CODE_*`/`CLAUDECODE` vars, including ones that carry
process-local handles, not just identifiers:

```
CLAUDECODE=1
CLAUDE_CODE_SESSION_ID=...
CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=4
CLAUDE_CODE_WEBSOCKET_AUTH_FILE_DESCRIPTOR=3
CLAUDE_CODE_CHILD_SESSION=1
... (~20 more)
```

`CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` / `CLAUDE_CODE_WEBSOCKET_AUTH_FILE_DESCRIPTOR`
name file-descriptor numbers that are only meaningful in the *original*
process — a spawned child inheriting the var but not the actual open fd is
a plausible mechanism for the symptom we observed empirically: a nested
`claude` session showing a persistent `Authentication error · This may be
a temporary network issue` on every turn, despite valid cached OAuth
credentials, that only went away once we stripped the full
`CLAUDE_CODE_*`/`CLAUDECODE` family before exec'ing the child.

I don't have a fully isolated proof of which specific var(s) cause the
auth error vs. just the session-id collision — but the practical fix we
verified (strip the family, not just one var) is stronger than relying on
`detect=` alone, and I want to flag that explicitly for whoever picks this
up: **the attached PR fixes the narrower, provable part (unset the
`detect=` var(s), which is what that manifest field already documents as
the session-identity signal) but may not be a complete fix for
`claude-code`'s auth-error symptom if it does turn out to be FD-related
rather than session-id-related.** Happy to test a broader
prefix-strip (e.g. everything matching `CLAUDE_CODE_*`/`CLAUDECODE*`) if
maintainers want that instead — it's a slightly bigger behavioral change
(stripping vars `detect=` doesn't name) so I didn't want to bake that
assumption into the PR without input.

## Reproduction

```bash
# tmux new-window/split-window (and the OS-terminal paths) copy the calling
# shell's exported env into the new pane/window verbatim:
export CLAUDE_CODE_SESSION_ID=outer-session-abc123
export CLAUDECODE=1
tmux new-session -d -s repro 'sleep 30'
tmux new-window -t repro -n child \
  'env | grep -E "^CLAUDE_CODE_SESSION_ID|^CLAUDECODE" > /tmp/child-env.txt'
cat /tmp/child-env.txt
# CLAUDE_CODE_SESSION_ID=outer-session-abc123
# CLAUDECODE=1
```

Confirmed the same for `spawn.sh`'s generated `.command` boot script: it
execs the CLI with no `unset`, so whatever `spawn.sh` itself inherited
(from the shell that ran it) reaches the child CLI unchanged.

## Proposed fix

Minimal, uses data `type.conf` already declares — no new manifest field:

- Read `DETECT_VARS="$(agmsg_type_get "$AGENT_TYPE" detect)"` in `spawn.sh`
  (treat the literal `explicit` as "none", matching its existing meaning
  elsewhere).
- Emit `unset $DETECT_VARS` as the first line of the generated boot
  script, before the CLI invocation.

Diff (also attached as `spawn-detect-vars-unset.patch`):

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

## Testing done

- Added two `tests/test_spawn.bats` cases:
  - boot script for `claude-code` contains `unset CLAUDE_CODE_SESSION_ID
    CLAUDECODE`
  - boot script for `copilot` (`detect=explicit`) contains no `unset` line
- Full `tests/test_spawn.bats` (44 existing + 2 new = 46 cases): all pass
  with the fix applied.
- Confirmed the new test fails without the fix (`git stash` the `spawn.sh`
  change only, rerun): `not ok ... boot script unsets the target type's
  detect= vars`.
- `bash -n scripts/spawn.sh`: clean.

## Environment

- agmsg `1.1.3` (main @ `f665c1c`)
- Reproduced on Linux with a locally-built tmux socket (`tmux -L`), and via
  the existing bats `AGMSG_TERMINAL` stub path used by `tests/test_spawn.bats`.
