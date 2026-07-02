## Summary

- Fixes #<issue-number>: `spawn.sh` never stripped a type's `detect=`
  session-identity env var(s) before exec'ing the CLI in the generated boot
  script, so a same-type spawn (e.g. a `claude-code` session spawning
  another `claude-code` peer via `agmsg spawn claude-code <name>`, exactly
  the pattern `docs/actas.md` documents) hands the child the parent's own
  session id. For `claude-code` this reliably breaks auth in the child.
- `type.conf`'s `detect=` field already names exactly the var(s) that
  identify a running session of that type, so the fix reads it via the
  existing `agmsg_type_get` accessor and emits `unset $DETECT_VARS` as the
  first line of the boot script, before the CLI is invoked. `detect=explicit`
  (antigravity, copilot, hermes) is treated as "no vars to unset", matching
  its meaning everywhere else `detect=` is read.

## Test plan

- [x] Added two cases to `tests/test_spawn.bats`:
  - claude-code boot script contains `unset CLAUDE_CODE_SESSION_ID CLAUDECODE`
  - copilot (`detect=explicit`) boot script contains no `unset` line
- [x] Full suite: `bats tests/test_spawn.bats` — 46/46 pass (44 pre-existing
      + 2 new), no regressions
- [x] Verified the new test fails without the `scripts/spawn.sh` change
      (`git stash push -- scripts/spawn.sh` then rerun): confirms the test
      actually exercises the fix
- [x] `bash -n scripts/spawn.sh` — clean
- [x] Reproduced the underlying tmux env-inheritance mechanism directly
      (`tmux new-window` copies the caller's exported `CLAUDE_CODE_SESSION_ID`
      into the child pane verbatim) — details in the linked issue
