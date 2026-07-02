#!/usr/bin/env bash
# agmsg-autonomous/setup.sh
#
# Bootstrap a Claude Code <-> Codex CLI autonomous dev pair (agmsg-mediated)
# for ANY git repository, on any machine (Linux or macOS; sandboxed
# container or a normal laptop). Idempotent: safe to re-run.
#
# What it does, in order:
#   1. Detects OS, checks/reports on required binaries (git, bash, sqlite3,
#      tmux, claude, codex).
#   2. Installs/updates agmsg from the fujibee/agmsg GitHub `main` branch
#      (falls back to a file-by-file jsdelivr fetch if a direct git clone
#      is blocked, which happens in some sandboxed network policies).
#   3. Configures ~/.codex/config.toml for workspace-write sandboxing with
#      agmsg's db/teams/run dirs whitelisted (timestamped backup if the
#      file already exists and needs edits beyond what install.sh adds).
#   4. Creates a dedicated git worktree + branch for the target repo
#      (never touches the repo's existing branches/working tree).
#   5. Joins both agents to an agmsg team derived from the repo name.
#   6. Sets delivery mode: `both` for Claude Code, `monitor` (beta) for
#      Codex, via the explicit codex-monitor.sh launcher (no global
#      `codex` shell-function/PATH shim is installed).
#   7. Generates AGENTS.md / CLAUDE.md / .agent/{config.sh,bin/*} in the
#      new worktree from the templates embedded in this script.
#
# Usage:
#   setup.sh [/path/to/repo] [options]
#
# Options:
#   --team NAME              default: <sanitized-repo-name>-agents
#   --claude-agent NAME      default: claude-reviewer
#   --codex-agent NAME       default: codex-impl
#   --branch NAME            default: agent/autonomous
#   --worktree PATH          default: <parent-of-repo>/<repo-name>-agent
#   --tmux-session NAME      default: <sanitized-repo-name>-agents
#   --agmsg-cmd NAME         default: agmsg  (agmsg's own --cmd install name)
#   --skip-agmsg-install     assume agmsg is already installed/up to date
#   -h, --help
#
# Never pushes, merges, or touches the repo's existing branches. Never uses
# --dangerously-skip-permissions / bypassPermissions or Codex
# --danger-full-access / disabled sandbox.
set -euo pipefail

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
REPO_PATH=""
TEAM_OVERRIDE=""
CLAUDE_AGENT_OVERRIDE=""
CODEX_AGENT_OVERRIDE=""
BRANCH_OVERRIDE=""
WORKTREE_OVERRIDE=""
TMUX_SESSION_OVERRIDE=""
AGMSG_CMD="agmsg"
SKIP_AGMSG_INSTALL=false

usage() { sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --team) TEAM_OVERRIDE="$2"; shift 2 ;;
    --claude-agent) CLAUDE_AGENT_OVERRIDE="$2"; shift 2 ;;
    --codex-agent) CODEX_AGENT_OVERRIDE="$2"; shift 2 ;;
    --branch) BRANCH_OVERRIDE="$2"; shift 2 ;;
    --worktree) WORKTREE_OVERRIDE="$2"; shift 2 ;;
    --tmux-session) TMUX_SESSION_OVERRIDE="$2"; shift 2 ;;
    --agmsg-cmd) AGMSG_CMD="$2"; shift 2 ;;
    --skip-agmsg-install) SKIP_AGMSG_INSTALL=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 1 ;;
    *) REPO_PATH="$1"; shift ;;
  esac
done

log() { echo "[agmsg-autonomous] $*"; }
warn() { echo "[agmsg-autonomous] WARNING: $*" >&2; }
die() { echo "[agmsg-autonomous] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Resolve repo, derive defaults
# ---------------------------------------------------------------------------
REPO_PATH="${REPO_PATH:-$(pwd)}"
REPO_ROOT="$(cd "$REPO_PATH" && git rev-parse --show-toplevel 2>/dev/null)" \
  || die "'$REPO_PATH' is not inside a git repository"

RAW_REPO_NAME="$(basename "$REPO_ROOT")"
# Sanitize: lowercase, non [a-z0-9-] -> '-', collapse/trim '-'
SAFE_REPO_NAME="$(printf '%s' "$RAW_REPO_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-//; s/-$//')"
[ -n "$SAFE_REPO_NAME" ] || die "could not derive a safe name from repo dir '$RAW_REPO_NAME'"

TEAM="${TEAM_OVERRIDE:-${SAFE_REPO_NAME}-agents}"
CLAUDE_AGENT="${CLAUDE_AGENT_OVERRIDE:-claude-reviewer}"
CODEX_AGENT="${CODEX_AGENT_OVERRIDE:-codex-impl}"
BRANCH="${BRANCH_OVERRIDE:-agent/autonomous}"
WORKTREE="${WORKTREE_OVERRIDE:-$(dirname "$REPO_ROOT")/${SAFE_REPO_NAME}-agent}"
TMUX_SESSION="${TMUX_SESSION_OVERRIDE:-${SAFE_REPO_NAME}-agents}"
SKILL_DIR="$HOME/.agents/skills/$AGMSG_CMD"
SKILL_SCRIPTS="$SKILL_DIR/scripts"

OS="$(uname -s)"
log "repo: $REPO_ROOT (name: $RAW_REPO_NAME -> $SAFE_REPO_NAME)"
log "team=$TEAM claude-agent=$CLAUDE_AGENT codex-agent=$CODEX_AGENT"
log "branch=$BRANCH worktree=$WORKTREE tmux-session=$TMUX_SESSION"
log "OS=$OS agmsg-cmd=$AGMSG_CMD skill-dir=$SKILL_DIR"

# ---------------------------------------------------------------------------
# 2. Dependency checks
# ---------------------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1; }

need git   || die "git not found - install git first"
need bash  || die "bash not found"

if ! need sqlite3; then
  case "$OS" in
    Linux)
      if need apt-get && [ "$(id -u)" = 0 ]; then
        log "sqlite3 missing - installing via apt-get"
        apt-get update -qq && apt-get install -y -qq sqlite3
      else
        die "sqlite3 not found. Install it (e.g. 'sudo apt-get install sqlite3') and re-run."
      fi
      ;;
    Darwin)
      die "sqlite3 not found (unexpected on macOS - check your PATH / Xcode CLT install)"
      ;;
    *) die "sqlite3 not found - install it for your OS and re-run" ;;
  esac
fi

if ! need tmux; then
  case "$OS" in
    Darwin) warn "tmux not found. Install with: brew install tmux" ;;
    Linux)  warn "tmux not found. Install with your distro's package manager (e.g. apt-get install tmux)" ;;
    *)      warn "tmux not found - install it for your OS" ;;
  esac
  warn "continuing without tmux; the generated .agent/bin/team script will refuse to start until tmux is installed"
fi

if ! need claude; then
  warn "claude (Claude Code CLI) not found on PATH - install it before running .agent/bin/team start"
fi
if ! need codex; then
  warn "codex (Codex CLI) not found on PATH - install it (npm i -g @openai/codex) before running .agent/bin/team start"
fi

# ---------------------------------------------------------------------------
# 3. Install / update agmsg from fujibee/agmsg main
# ---------------------------------------------------------------------------
agmsg_installed_ok() {
  [ -f "$SKILL_DIR/.agmsg" ] && [ -x "$SKILL_SCRIPTS/join.sh" ]
}

if [ "$SKIP_AGMSG_INSTALL" = true ]; then
  agmsg_installed_ok || die "--skip-agmsg-install given but $SKILL_DIR is not a valid install"
  log "agmsg install: skipped (--skip-agmsg-install), using existing $SKILL_DIR"
elif agmsg_installed_ok; then
  log "agmsg already installed at $SKILL_DIR (version $(bash "$SKILL_SCRIPTS/version.sh" 2>/dev/null || echo unknown)) - leaving as-is"
  log "(to force a refresh from main, remove --skip-agmsg-install and delete $SKILL_DIR, or run its own './install.sh --update' from a fresh clone)"
else
  TMP_SRC="$(mktemp -d)"
  trap 'rm -rf "$TMP_SRC"' EXIT

  fetched=false
  log "fetching fujibee/agmsg (main) ..."
  if git clone --depth 1 https://github.com/fujibee/agmsg.git "$TMP_SRC/agmsg" >/dev/null 2>&1; then
    SRC_DIR="$TMP_SRC/agmsg"
    fetched=true
    log "  via git clone"
  else
    warn "git clone of github.com/fujibee/agmsg failed (network policy may block it) - falling back to jsdelivr file fetch"
    SRC_DIR="$TMP_SRC/agmsg"
    mkdir -p "$SRC_DIR"
    LIST_JSON="$TMP_SRC/list.json"
    if curl -fsSL "https://data.jsdelivr.com/v1/packages/gh/fujibee/agmsg@main?structure=flat" -o "$LIST_JSON"; then
      python3 - "$LIST_JSON" "$SRC_DIR" <<'PYEOF'
import json, os, sys, urllib.request
list_json, dest = sys.argv[1], sys.argv[2]
data = json.load(open(list_json))
skip_prefixes = ("/site/",)
skip_ext = (".png", ".gif", ".jpg", ".jpeg", ".svg", ".ico", ".webp")
for f in data["files"]:
    name = f["name"]
    if name.startswith(skip_prefixes) or name.endswith(skip_ext):
        continue
    url = "https://cdn.jsdelivr.net/gh/fujibee/agmsg@main" + name
    out = dest + name
    os.makedirs(os.path.dirname(out), exist_ok=True)
    try:
        urllib.request.urlretrieve(url, out)
    except Exception as e:
        print(f"warn: failed to fetch {name}: {e}", file=sys.stderr)
PYEOF
      [ -f "$SRC_DIR/install.sh" ] && fetched=true
    fi
  fi

  [ "$fetched" = true ] && [ -f "$SRC_DIR/install.sh" ] || die "could not fetch agmsg source via git clone or jsdelivr fallback. Install manually: see https://github.com/fujibee/agmsg#install"

  chmod +x "$SRC_DIR/install.sh"
  find "$SRC_DIR/scripts" -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true

  log "running agmsg install.sh --cmd $AGMSG_CMD"
  (cd "$SRC_DIR" && bash install.sh --cmd "$AGMSG_CMD")
fi

# ---------------------------------------------------------------------------
# 4. Codex sandbox config (~/.codex/config.toml)
# ---------------------------------------------------------------------------
CODEX_CONFIG="$HOME/.codex/config.toml"
mkdir -p "$HOME/.codex"
if [ ! -f "$CODEX_CONFIG" ]; then
  log "creating $CODEX_CONFIG (sandbox_mode = workspace-write)"
  printf 'sandbox_mode = "workspace-write"\n' > "$CODEX_CONFIG"
else
  log "$CODEX_CONFIG already exists - leaving sandbox_mode as-is"
fi
# agmsg's own install.sh (run above, or on a prior run) already adds the
# db/teams/run writable_roots to this file when it exists, with its own
# timestamped-free .bak. If you need a true point-in-time backup before
# further manual edits, do it yourself:
#   cp ~/.codex/config.toml ~/.codex/config.toml.$(date +%Y%m%dT%H%M%S).bak

# ---------------------------------------------------------------------------
# 5. Dedicated worktree + branch (never touches existing branches)
# ---------------------------------------------------------------------------
if git -C "$REPO_ROOT" worktree list | awk '{print $1}' | grep -qx "$WORKTREE"; then
  log "worktree $WORKTREE already registered - reusing"
elif [ -e "$WORKTREE" ]; then
  die "$WORKTREE exists but is not a registered git worktree of this repo - resolve manually before re-running"
else
  log "creating worktree $WORKTREE on branch $BRANCH"
  if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git -C "$REPO_ROOT" worktree add "$WORKTREE" "$BRANCH"
  else
    DEFAULT_REMOTE_BRANCH="$(git -C "$REPO_ROOT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"
    git -C "$REPO_ROOT" worktree add -b "$BRANCH" "$WORKTREE" "$DEFAULT_REMOTE_BRANCH" 2>/dev/null \
      || git -C "$REPO_ROOT" worktree add -b "$BRANCH" "$WORKTREE"
  fi
fi

# ---------------------------------------------------------------------------
# 6. Join team + set delivery modes (idempotent - agmsg scripts already are)
# ---------------------------------------------------------------------------
log "joining agmsg team '$TEAM'"
bash "$SKILL_SCRIPTS/join.sh" "$TEAM" "$CLAUDE_AGENT" claude-code "$WORKTREE" || true
bash "$SKILL_SCRIPTS/join.sh" "$TEAM" "$CODEX_AGENT" codex "$WORKTREE" || true
bash "$SKILL_SCRIPTS/team.sh" "$TEAM"

log "setting delivery modes (claude-code=both, codex=monitor)"
bash "$SKILL_SCRIPTS/delivery.sh" set both claude-code "$WORKTREE" >/dev/null
bash "$SKILL_SCRIPTS/delivery.sh" set monitor codex "$WORKTREE" >/dev/null

# ---------------------------------------------------------------------------
# 7. Generate AGENTS.md / CLAUDE.md / .agent/* in the worktree
# ---------------------------------------------------------------------------
mkdir -p "$WORKTREE/.agent/bin" "$WORKTREE/.agent/logs" "$WORKTREE/.agent/run" "$WORKTREE/.agent/reviews"
touch "$WORKTREE/.agent/reviews/.gitkeep"

if [ -f "$WORKTREE/AGENTS.md" ]; then
  log "AGENTS.md already exists in worktree - leaving it untouched (delete it and re-run to regenerate)"
else
  log "writing $WORKTREE/AGENTS.md"
  cat > "$WORKTREE/AGENTS.md" <<EOF
# AGENTS.md — ${CODEX_AGENT}

This worktree is a dedicated autonomous-development environment shared by
\`${CODEX_AGENT}\` (Codex CLI, agmsg team \`${TEAM}\`) and \`${CLAUDE_AGENT}\`
(Claude Code, same team). Read this file at the start of every session.

## Role

- **Codex (\`${CODEX_AGENT}\`) is the only implementation agent.** Only Codex
  edits files in this worktree: source code, tests, config, dependencies.
- Claude Code (\`${CLAUDE_AGENT}\`) never edits files here. Do not expect it
  to push commits or run build/test commands on your behalf.
- Enable agmsg automatic delivery (\`monitor\` mode) and stay listening for
  messages from \`${CLAUDE_AGENT}\` for the duration of the session.

## When to consult Claude before implementing

Before making a change that is **high-risk or ambiguous** — schema/migration
changes, public API changes, security-sensitive code, anything where the
correct approach is not obvious from the task description — send a message
to \`${CLAUDE_AGENT}\` over agmsg describing the situation and proposed
approach, and wait for a reply before proceeding. Routine, low-risk changes
do not need a pre-implementation consult.

## When to request review

After completing a change that is **more than trivial** (i.e. not a one-line
fix or typo), request a review from \`${CLAUDE_AGENT}\` over agmsg. The
review request message must include:

- A short description of the change and why
- The **test results** (command run + pass/fail summary)
- The **commit SHA** of the change under review

## Handling review feedback

Claude's review will separate feedback into **blocking** and **optional**
items.

- Fix **blocking** items automatically and re-request review.
- Do **not** implement **optional** items — they are suggestions, not
  requirements, unless the human explicitly asks for them later.

## Review round limit

A given change gets **at most 2 review rounds** with \`${CLAUDE_AGENT}\`. If
the review is not resolved (no more blocking items) after round 2, stop
making further changes to that item, send a message to the team summarizing
the unresolved blocking issue(s), and mark the item \`ESCALATED\`. Wait for a
human to intervene — do not keep looping.

## Exact script syntax

Do not improvise argument order. \`send.sh\` takes exactly:

\`\`\`
${SKILL_SCRIPTS}/send.sh ${TEAM} ${CODEX_AGENT} ${CLAUDE_AGENT} "<message>"
\`\`\`

That's \`send.sh <team> <from> <to> "<message>"\` — four positional args, in
that order.

## Hard limits

- Never \`git push\`.
- Never merge into \`main\` (or any branch other than this worktree's
  \`${BRANCH}\` branch).
- Never deploy or release anything.
- All of the above are exclusively human operations.
EOF
fi

if [ -f "$WORKTREE/CLAUDE.md" ]; then
  log "CLAUDE.md already exists in worktree - leaving it untouched (delete it and re-run to regenerate)"
else
  log "writing $WORKTREE/CLAUDE.md"
  cat > "$WORKTREE/CLAUDE.md" <<EOF
# CLAUDE.md — ${CLAUDE_AGENT}

This worktree is a dedicated autonomous-development environment shared by
\`${CLAUDE_AGENT}\` (Claude Code, agmsg team \`${TEAM}\`) and \`${CODEX_AGENT}\`
(Codex CLI, same team). Read this file at the start of every session.

## Role

- **Design consultation and independent review only.** You do not implement
  features or fixes here.
- \`${CODEX_AGENT}\` is the only agent that edits source code in this
  worktree.
- Enable agmsg automatic delivery (\`monitor\`/\`both\` mode) and stay
  listening for messages from \`${CODEX_AGENT}\` for the duration of the
  session.

## What you must never change

- Do not edit source code, tests, dependency manifests (\`package.json\`,
  lockfiles, etc.), or any tracked project file.
- Do not change git state: no commits, no staging, no branch changes, no
  \`git push\`, no \`git merge\`.
- The **only** files you may write are review artifacts under \`.agent/\`
  (e.g. \`.agent/reviews/\`) in this worktree.

## How to review

Base every review on the **diff** (\`git diff\` / \`git show <sha>\`) and the
**acceptance criteria** implied by the task or Codex's description — not on
personal style preference.

Separate findings into two categories:

- **Blocking** — must be fixed before this change is acceptable. For each
  blocking finding, include:
  - **File** and **line**
  - **Trigger condition** (concrete input/state that hits the problem)
  - **Impact** (what breaks, and how badly)
  - **Fix requirement** (what the fix must accomplish, not necessarily exact
    code)
  - **Verification** (how to confirm the fix actually resolves it)
- **Optional** — worth mentioning but not required. Keep this list short and
  clearly separated from blocking items.

Do not request refactors that are pure preference with no correctness,
security, or maintainability justification.

## Review round limit

A given change gets **at most 2 review rounds**. If blocking items remain
unresolved after round 2, reply \`ESCALATED\` with a summary of what's still
blocking, and stop reviewing that item — wait for a human to intervene.

## Communication

Send review results back to \`${CODEX_AGENT}\` over agmsg. Keep messages
actionable and scoped to this review; do not send unrelated design musings
unless asked.

Exact \`send.sh\` syntax (do not improvise the argument order):

\`\`\`
${SKILL_SCRIPTS}/send.sh ${TEAM} ${CLAUDE_AGENT} ${CODEX_AGENT} "<message>"
\`\`\`

That's \`send.sh <team> <from> <to> "<message>"\` — four positional args, in
that order. It is unrelated to the Monitor tool's \`watch.sh <session_id>
<project_path> <agent_type>\` invocation; don't carry watch.sh's argument
shape over to send.sh.
EOF
fi

log "writing $WORKTREE/.agent/config.sh"
cat > "$WORKTREE/.agent/config.sh" <<EOF
#!/usr/bin/env bash
# Shared config for .agent/bin/team. Sourced, not executed.
# Generated by tools/agmsg-autonomous/setup.sh - safe to hand-edit afterwards,
# re-running setup.sh will NOT overwrite this file once it exists.

AGENT_CONF_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="\$(cd "\$AGENT_CONF_DIR/.." && pwd)"

TEAM="${TEAM}"
CLAUDE_AGENT="${CLAUDE_AGENT}"
CODEX_AGENT="${CODEX_AGENT}"
AGMSG_CMD="\${AGMSG_CMD:-${AGMSG_CMD}}"
SKILL_DIR="\$HOME/.agents/skills/\$AGMSG_CMD"
SKILL_SCRIPTS="\$SKILL_DIR/scripts"
TMUX_SESSION="${TMUX_SESSION}"

LOG_DIR="\$WORKTREE_ROOT/.agent/logs"
RUN_DIR="\$WORKTREE_ROOT/.agent/run"
mkdir -p "\$LOG_DIR" "\$RUN_DIR"

CLAUDE_WINDOW="${CLAUDE_AGENT}"
CODEX_WINDOW="${CODEX_AGENT}"

CLAUDE_INITIAL_PROMPT="Read CLAUDE.md in this worktree and follow it exactly. You are \${CLAUDE_AGENT} on the agmsg team \${TEAM}. Do not edit any source code, tests, dependencies, or git state in this worktree - your only writable area is .agent/ review artifacts. Start agmsg automatic delivery now: run '\${SKILL_SCRIPTS}/whoami.sh \"\\\$(pwd)\" claude-code' to confirm identity, then invoke the Monitor tool as instructed by agmsg (mode is already set to 'both' for this project) so you receive messages from \${CODEX_AGENT} in real time. Then wait for messages."

CODEX_INITIAL_PROMPT="Read AGENTS.md in this worktree and follow it exactly. You are \${CODEX_AGENT} on the agmsg team \${TEAM}, the only agent allowed to edit files here. agmsg monitor delivery is already enabled for this project. Confirm your identity, then wait for messages from \${CLAUDE_AGENT} and for tasks from the human."

# Project-hash used by codex-monitor.sh / codex-bridge for run/ pidfiles.
agmsg_project_hash() {
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "\$WORKTREE_ROOT" | sha1sum | cut -d' ' -f1
  else
    printf '%s' "\$WORKTREE_ROOT" | shasum | cut -d' ' -f1
  fi
}
EOF

log "writing $WORKTREE/.agent/bin/launch-claude-reviewer.sh"
cat > "$WORKTREE/.agent/bin/launch-claude-reviewer.sh" <<'LAUNCHEOF'
#!/usr/bin/env bash
# Launch an independent, correctly-authenticated `claude` session.
#
# Some hosts (notably nested/managed Claude Code environments, e.g. "Claude
# Code on the web") export CLAUDE_CODE_SESSION_ID and ~25 other
# CLAUDE_CODE_*/CLAUDECODE_* vars into every child shell. A nested `claude`
# picking up the SAME session id as its parent collides with it, which
# surfaces as a persistent "Authentication error" on every turn even after a
# fresh, valid login. Stripping those vars before exec gives the nested
# process its own clean session identity. On a plain local machine these
# vars are simply unset already, so this is a no-op there.
set -euo pipefail

args=()
while IFS= read -r name; do
  [ -n "$name" ] && args+=(-u "$name")
done < <(env | awk -F= '/^(CLAUDE_CODE_|CLAUDECODE|CLAUDE_AUTO|CLAUDE_AFTER_LAST_COMPACT|CLAUDE_EFFORT|CLAUDE_ENABLE_STREAM_WATCHDOG|CLAUDE_SESSION_INGRESS_TOKEN_FILE|CLAUDE_AUTOCOMPACT_PCT_OVERRIDE)/{print $1}')

exec env "${args[@]}" claude "$@"
LAUNCHEOF

log "writing $WORKTREE/.agent/bin/team"
cat > "$WORKTREE/.agent/bin/team" <<'TEAMEOF'
#!/usr/bin/env bash
# .agent/bin/team - launch/stop/inspect the two-agent pair for this worktree
# over tmux, using agmsg's official scripts underneath.
#
# Usage: team {start|stop|status|logs|restart|doctor}
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config.sh
source "$HERE/../config.sh"

LOCK_FILE="$RUN_DIR/team.lock"

with_lock() {
  exec 9>"$LOCK_FILE"
  if flock -n 9; then
    return 0
  fi
  # flock is only ever held for the few seconds a start/stop takes, so a
  # lock still held after a short wait is almost certainly stale (e.g. a
  # previous invocation's shell was killed without releasing its fd
  # cleanly, or the lock file lives on a filesystem with flaky advisory
  # locking). Wait briefly, then retry once before giving up for real.
  sleep 2
  if flock -n 9; then
    return 0
  fi
  echo "team: another team command appears to be running (lock: $LOCK_FILE)." >&2
  echo "team: if no other 'team start/stop/restart' is actually in flight, remove the lock file and retry:" >&2
  echo "  rm -f '$LOCK_FILE'" >&2
  exit 1
}

tmux_available() { command -v tmux >/dev/null 2>&1; }

session_exists() {
  tmux has-session -t "$TMUX_SESSION" 2>/dev/null
}

window_exists() {
  local win="$1"
  tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$win"
}

pane_pid_alive() {
  local win="$1"
  local pid
  pid="$(tmux list-panes -t "$TMUX_SESSION:$win" -F '#{pane_pid}' 2>/dev/null | head -1)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# --- codex bridge process discovery (by project hash, see codex-monitor.sh) ---
codex_hash="$(agmsg_project_hash)"
codex_server_pidfile="$SKILL_DIR/run/codex-app-server.${codex_hash}.pid"
codex_server_logfile="$SKILL_DIR/run/codex-app-server.${codex_hash}.log"

codex_bridge_pids() {
  # codex-bridge.js (node) and codex-bridge-launcher.sh processes for THIS
  # project path, matched by cmdline substring (never a broad pattern kill).
  pgrep -f "codex-bridge(\\.js|-launcher\\.sh).*${WORKTREE_ROOT}" 2>/dev/null || true
}

codex_app_server_pid() {
  [ -f "$codex_server_pidfile" ] || return 0
  local pid
  pid="$(cat "$codex_server_pidfile" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

cmd_start() {
  with_lock
  if ! tmux_available; then
    echo "team: tmux not found. This script requires tmux on this OS; install tmux and re-run." >&2
    exit 1
  fi

  if session_exists; then
    echo "team: tmux session '$TMUX_SESSION' already running - not double-launching."
    cmd_status
    return 0
  fi

  echo "team: starting tmux session '$TMUX_SESSION' in $WORKTREE_ROOT"
  tmux new-session -d -s "$TMUX_SESSION" -n "$CLAUDE_WINDOW" -c "$WORKTREE_ROOT"
  tmux pipe-pane -t "$TMUX_SESSION:$CLAUDE_WINDOW" -o "cat >> '$LOG_DIR/${CLAUDE_WINDOW}.log'"
  tmux send-keys -t "$TMUX_SESSION:$CLAUDE_WINDOW" \
    "'$HERE/launch-claude-reviewer.sh' $(printf '%q' "$CLAUDE_INITIAL_PROMPT")" C-m

  tmux new-window -t "$TMUX_SESSION" -n "$CODEX_WINDOW" -c "$WORKTREE_ROOT"
  tmux pipe-pane -t "$TMUX_SESSION:$CODEX_WINDOW" -o "cat >> '$LOG_DIR/${CODEX_WINDOW}.log'"
  # Explicit official launcher (no global `codex` shell-function/PATH shim),
  # per docs/codex-monitor-beta.md "Optional PATH Shim" section - this keeps
  # a normal `codex` invocation elsewhere on the host completely unaffected.
  tmux send-keys -t "$TMUX_SESSION:$CODEX_WINDOW" \
    "'$SKILL_SCRIPTS/drivers/types/codex/codex-monitor.sh' --project '$WORKTREE_ROOT' --codex-command codex -- $(printf '%q' "$CODEX_INITIAL_PROMPT")" C-m

  echo "team: launched. Logs: $LOG_DIR/${CLAUDE_WINDOW}.log , $LOG_DIR/${CODEX_WINDOW}.log"
  echo "team: attach with: tmux attach -t $TMUX_SESSION"
}

cmd_stop() {
  with_lock
  local did_something=false

  if tmux_available && session_exists; then
    did_something=true
    echo "team: stopping tmux session '$TMUX_SESSION'"
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  else
    echo "team: no tmux session '$TMUX_SESSION' running"
  fi

  # Best-effort teardown of the Codex monitor bridge for this project, even
  # if the tmux session was already gone (orphaned bridge case).
  local pids
  pids="$(codex_bridge_pids)"
  if [ -n "$pids" ]; then
    did_something=true
    echo "team: stopping Codex monitor bridge processes: $pids"
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
  fi
  local server_pid
  server_pid="$(codex_app_server_pid)"
  if [ -n "$server_pid" ]; then
    did_something=true
    echo "team: stopping Codex app-server (pid $server_pid) for this project"
    kill "$server_pid" 2>/dev/null || true
    rm -f "$codex_server_pidfile" "$SKILL_DIR/run/codex-app-server.${codex_hash}.port" "$SKILL_DIR/run/codex-app-server.${codex_hash}.version"
  fi

  if [ "$did_something" = false ]; then
    echo "team: nothing was running"
  fi
}

cmd_status() {
  echo "== tmux =="
  if ! tmux_available; then
    echo "  tmux: not installed"
  elif session_exists; then
    echo "  session '$TMUX_SESSION': RUNNING"
    tmux list-windows -t "$TMUX_SESSION" -F '    window=#{window_name} pane_pid=#{pane_pid}'
    for w in "$CLAUDE_WINDOW" "$CODEX_WINDOW"; do
      if window_exists "$w"; then
        if pane_pid_alive "$w"; then
          echo "    $w: pane process alive"
        else
          echo "    $w: pane exists but process looks dead"
        fi
      else
        echo "    $w: window not present"
      fi
    done
  else
    echo "  session '$TMUX_SESSION': not running"
  fi

  echo "== agmsg delivery mode (this project) =="
  bash "$SKILL_SCRIPTS/delivery.sh" status claude-code "$WORKTREE_ROOT" 2>&1 | sed 's/^/  [claude-code] /'
  bash "$SKILL_SCRIPTS/delivery.sh" status codex "$WORKTREE_ROOT" 2>&1 | sed 's/^/  [codex]       /'

  echo "== codex bridge / app-server (this project) =="
  local pids server_pid
  pids="$(codex_bridge_pids)"
  server_pid="$(codex_app_server_pid)"
  echo "  bridge/launcher pids: ${pids:-none}"
  echo "  app-server pid: ${server_pid:-none (or not running)}"

  echo "== team roster =="
  bash "$SKILL_SCRIPTS/team.sh" "$TEAM" 2>&1 | sed 's/^/  /'

  echo "== logs =="
  echo "  $LOG_DIR/${CLAUDE_WINDOW}.log"
  echo "  $LOG_DIR/${CODEX_WINDOW}.log"
  echo "  $codex_server_logfile"
}

cmd_logs() {
  echo "Log locations:"
  echo "  Claude ($CLAUDE_WINDOW) tmux pane log: $LOG_DIR/${CLAUDE_WINDOW}.log"
  echo "  Codex  ($CODEX_WINDOW) tmux pane log:  $LOG_DIR/${CODEX_WINDOW}.log"
  echo "  Codex app-server log:                   $codex_server_logfile"
  echo ""
  for f in "$LOG_DIR/${CLAUDE_WINDOW}.log" "$LOG_DIR/${CODEX_WINDOW}.log" "$codex_server_logfile"; do
    if [ -f "$f" ]; then
      echo "----- tail -n 30 $f -----"
      tail -n 30 "$f"
      echo ""
    fi
  done
}

cmd_restart() {
  cmd_stop
  sleep 1
  cmd_start
}

cmd_doctor() {
  local problems=0

  echo "== binaries =="
  for bin in tmux sqlite3 git bash; do
    if command -v "$bin" >/dev/null 2>&1; then
      echo "  $bin: OK ($("$bin" --version 2>&1 | head -1))"
    else
      echo "  $bin: MISSING"
      problems=$((problems + 1))
    fi
  done
  if command -v claude >/dev/null 2>&1; then
    echo "  claude: OK ($(claude --version 2>&1))"
  else
    echo "  claude: MISSING"
    problems=$((problems + 1))
  fi
  if command -v codex >/dev/null 2>&1; then
    echo "  codex: OK ($(codex --version 2>&1))"
  else
    echo "  codex: MISSING"
    problems=$((problems + 1))
  fi

  echo "== agmsg install =="
  if [ -f "$SKILL_DIR/.agmsg" ]; then
    echo "  installed at $SKILL_DIR (version $(bash "$SKILL_SCRIPTS/version.sh" 2>&1))"
  else
    echo "  NOT installed at $SKILL_DIR"
    problems=$((problems + 1))
  fi

  echo "== double-launch check =="
  if tmux_available && session_exists; then
    for w in "$CLAUDE_WINDOW" "$CODEX_WINDOW"; do
      local n
      n="$(tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2>/dev/null | grep -cx "$w")"
      if [ "${n:-0}" -gt 1 ]; then
        echo "  WARNING: window '$w' appears $n times in session '$TMUX_SESSION' (possible double-launch)"
        problems=$((problems + 1))
      else
        echo "  $w: single instance OK"
      fi
    done
  else
    echo "  no session running (nothing to double-launch)"
  fi

  echo "== orphan Codex monitor bridge check =="
  local pids server_pid tui_alive
  pids="$(codex_bridge_pids)"
  server_pid="$(codex_app_server_pid)"
  tui_alive=false
  if tmux_available && session_exists && window_exists "$CODEX_WINDOW" && pane_pid_alive "$CODEX_WINDOW"; then
    tui_alive=true
  fi
  if { [ -n "$pids" ] || [ -n "$server_pid" ]; } && [ "$tui_alive" = false ]; then
    echo "  WARNING: Codex bridge/app-server process(es) found (pids: ${pids:-} ${server_pid:-}) but no live Codex TUI pane - likely orphaned (see agmsg issue #149)."
    echo "  Fix: run '$0 stop' to clean them up, or kill manually."
    problems=$((problems + 1))
  else
    echo "  no orphan bridge detected"
  fi
  if [ -f "$codex_server_pidfile" ] && [ -z "$server_pid" ]; then
    echo "  WARNING: stale pidfile $codex_server_pidfile (process not running) - safe to remove."
    problems=$((problems + 1))
  fi

  echo "== agmsg connectivity smoke test =="
  if bash "$SKILL_SCRIPTS/team.sh" "$TEAM" >/dev/null 2>&1; then
    echo "  team.sh: OK"
  else
    echo "  team.sh: FAILED"
    problems=$((problems + 1))
  fi
  if bash "$SKILL_SCRIPTS/whoami.sh" "$WORKTREE_ROOT" claude-code >/dev/null 2>&1; then
    echo "  whoami.sh (claude-code): OK"
  else
    echo "  whoami.sh (claude-code): FAILED"
    problems=$((problems + 1))
  fi
  if bash "$SKILL_SCRIPTS/whoami.sh" "$WORKTREE_ROOT" codex >/dev/null 2>&1; then
    echo "  whoami.sh (codex): OK"
  else
    echo "  whoami.sh (codex): FAILED"
    problems=$((problems + 1))
  fi

  echo ""
  if [ "$problems" -eq 0 ]; then
    echo "doctor: OK, no problems found"
  else
    echo "doctor: $problems problem(s) found"
  fi
  return "$problems"
}

case "${1:-}" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  status)  cmd_status ;;
  logs)    cmd_logs ;;
  restart) cmd_restart ;;
  doctor)  cmd_doctor ;;
  *)
    echo "Usage: $0 {start|stop|status|logs|restart|doctor}" >&2
    exit 1
    ;;
esac
TEAMEOF

log "writing $WORKTREE/.agent/bin/rollback.sh"
cat > "$WORKTREE/.agent/bin/rollback.sh" <<'ROLLBACKEOF'
#!/usr/bin/env bash
# .agent/bin/rollback.sh - undo the autonomous claude<->codex agmsg setup
# for this worktree. Safe by default: never deletes uncommitted work, and
# never touches ~/.codex/config.toml wholesale (it is a machine-wide file
# that other repos' worktrees may also depend on).
#
# Usage: rollback.sh [--yes] [--remove-worktree] [--restore-configs]
#   (no args)          dry-run: print what WOULD be done
#   --yes              actually perform the stop + team leave steps
#   --remove-worktree  also remove the dedicated git worktree (only if clean)
#   --restore-configs  also remove just this worktree's
#                       [projects."<path>"] trust entry from
#                       ~/.codex/config.toml (never the whole file - see below)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config.sh
source "$HERE/../config.sh"

DO_IT=false
REMOVE_WORKTREE=false
RESTORE_CONFIGS=false
for a in "$@"; do
  case "$a" in
    --yes) DO_IT=true ;;
    --remove-worktree) REMOVE_WORKTREE=true ;;
    --restore-configs) RESTORE_CONFIGS=true ;;
    *) echo "unknown flag: $a" >&2; exit 1 ;;
  esac
done

run() {
  if [ "$DO_IT" = true ]; then
    echo "+ $*"
    "$@"
  else
    echo "(dry-run) would run: $*"
  fi
}

echo "=== 1. Stop the autonomous session (tmux + Codex monitor bridge) ==="
run "$HERE/team" stop

echo ""
echo "=== 2. Disable agmsg automatic delivery for this project ==="
run bash "$SKILL_SCRIPTS/delivery.sh" set off claude-code "$WORKTREE_ROOT"
run bash "$SKILL_SCRIPTS/delivery.sh" set off codex "$WORKTREE_ROOT"

echo ""
echo "=== 3. Unregister project / leave team ==="
run bash "$SKILL_SCRIPTS/reset.sh" "$WORKTREE_ROOT" claude-code "$CLAUDE_AGENT"
run bash "$SKILL_SCRIPTS/reset.sh" "$WORKTREE_ROOT" codex "$CODEX_AGENT"
run bash "$SKILL_SCRIPTS/leave.sh" "$TEAM" "$CLAUDE_AGENT"
run bash "$SKILL_SCRIPTS/leave.sh" "$TEAM" "$CODEX_AGENT"
echo "(message history in $SKILL_DIR/db/messages.db is left intact - agmsg has no"
echo " destructive team-delete script; this only removes the two memberships.)"

echo ""
echo "=== 4. Remove the dedicated worktree ==="
if [ "$REMOVE_WORKTREE" != true ]; then
  echo "(skipped - pass --remove-worktree to remove $WORKTREE_ROOT)"
else
  cd "$(dirname "$WORKTREE_ROOT")" || exit 1
  if [ -n "$(git -C "$WORKTREE_ROOT" status --porcelain 2>/dev/null)" ]; then
    echo "REFUSING to remove worktree: uncommitted changes present in $WORKTREE_ROOT"
    echo "Inspect with: git -C '$WORKTREE_ROOT' status"
  else
    run git worktree remove "$WORKTREE_ROOT"
  fi
fi

echo ""
echo "=== 5. Remove this worktree's Codex trust entry ==="
CODEX_CONFIG="$HOME/.codex/config.toml"
if [ "$RESTORE_CONFIGS" != true ]; then
  echo "(skipped - pass --restore-configs to remove this worktree's"
  echo " [projects.\"$WORKTREE_ROOT\"] entry from $CODEX_CONFIG, if present)"
else
  echo "NOTE: $CODEX_CONFIG is a machine-wide file that other repos'"
  echo "      worktrees may also rely on (sandbox_mode, writable_roots for"
  echo "      the agmsg skill dir). This step ONLY removes the"
  echo "      [projects.\"$WORKTREE_ROOT\"] trust entry Codex itself may have"
  echo "      added for this exact worktree - it never deletes the file or"
  echo "      touches sandbox_mode / writable_roots."
  if [ -f "$CODEX_CONFIG" ] && grep -qF "[projects.\"$WORKTREE_ROOT\"]" "$CODEX_CONFIG" 2>/dev/null; then
    if [ "$DO_IT" = true ]; then
      TMP_CFG="$(mktemp)"
      awk -v hdr="[projects.\"$WORKTREE_ROOT\"]" '
        $0 == hdr { skip=1; next }
        skip && /^\[/ { skip=0 }
        !skip { print }
      ' "$CODEX_CONFIG" > "$TMP_CFG"
      cp "$CODEX_CONFIG" "$CODEX_CONFIG.$(date +%Y%m%dT%H%M%S).bak"
      mv "$TMP_CFG" "$CODEX_CONFIG"
      echo "+ removed [projects.\"$WORKTREE_ROOT\"] from $CODEX_CONFIG (backup: $CODEX_CONFIG.*.bak)"
    else
      echo "(dry-run) would remove [projects.\"$WORKTREE_ROOT\"] from $CODEX_CONFIG (with a timestamped backup first)"
    fi
  else
    echo "no [projects.\"$WORKTREE_ROOT\"] entry found in $CODEX_CONFIG - nothing to do"
  fi
  echo ""
  echo "If NO other repo's worktree uses agmsg/Codex on this machine and you want"
  echo "to remove $CODEX_CONFIG entirely, do that manually - this script will not:"
  echo "  rm -f '$CODEX_CONFIG'"
fi

echo ""
if [ "$DO_IT" != true ]; then
  echo "This was a DRY RUN. Re-run with --yes (and optionally --remove-worktree"
  echo "--restore-configs) to actually perform these steps."
fi
ROLLBACKEOF

chmod +x "$WORKTREE/.agent/bin/team" "$WORKTREE/.agent/bin/rollback.sh" "$WORKTREE/.agent/bin/launch-claude-reviewer.sh"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
log "done."
echo ""
echo "  Worktree:      $WORKTREE"
echo "  Branch:        $BRANCH"
echo "  Team:          $TEAM"
echo "  Claude agent:  $CLAUDE_AGENT (delivery: both)"
echo "  Codex agent:   $CODEX_AGENT (delivery: monitor beta)"
echo ""
echo "  Next steps:"
echo "    cd '$WORKTREE'"
echo "    .agent/bin/team start"
echo "    tmux attach -t $TMUX_SESSION"
echo "    # complete the one-time interactive login in each pane if needed,"
echo "    # then both agents self-configure via the SessionStart hooks already installed."
echo ""
echo "  Status / stop / rollback:"
echo "    .agent/bin/team status"
echo "    .agent/bin/team doctor"
echo "    .agent/bin/team stop"
echo "    .agent/bin/rollback.sh            # dry-run"
echo "    .agent/bin/rollback.sh --yes      # actually undo"
