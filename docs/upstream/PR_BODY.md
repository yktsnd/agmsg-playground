## Summary

Opening this alongside #<issue-number> in case the approach discussed
there looks reasonable — happy to adjust if a different direction is
preferred.

- `spawn.sh` never stripped a type's `detect=` session-identity env
  var(s) before exec'ing the CLI in the generated boot script, so a
  same-type spawn (e.g. a `claude-code` session spawning another
  `claude-code` peer via `agmsg spawn claude-code <name>`, the same
  pattern `docs/actas.md` describes) hands the child the parent's own
  session id. For `claude-code` this reliably breaks auth in the child.
- `type.conf`'s `detect=` field already names exactly the var(s) that
  identify a running session of that type, so this reads it via the
  existing `agmsg_type_get` accessor and emits `unset $DETECT_VARS` as the
  first line of the boot script, before the CLI is invoked. `detect=explicit`
  (antigravity, copilot, hermes) is treated as "no vars to unset", matching
  its meaning everywhere else `detect=` is read.
- As noted in the issue, this covers the `detect=` var(s) specifically —
  for claude-code there's some uncertainty about whether a broader
  `CLAUDE_CODE_*`/`CLAUDECODE*` strip is needed for the full symptom.
  Went with the narrower, provable change here; glad to expand it if
  that's the preferred direction.

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
