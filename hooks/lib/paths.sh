# hooks/lib/paths.sh — single canonical source of truth for filesystem paths
# used by hooks, orchestrator scripts, and cron wrappers. Source this file —
# do not execute it.
#   source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
# brain-stem. This is the SOLE canonical paths.sh body — there is no
# top-level lib/paths.sh 1-line sourcing shim. All hook bodies source THIS
# path directly. (paths.sh dedup PRIMARY OWNER.)
# Resolution order for each path:
#   1. Caller-set environment variable wins (test/CI overrides).
#   2. Field in user-manifest.json (when file exists, jq present, key non-empty).
#   3. Install-convention default ($HOME-relative).
# VAULT_ROOT and BACKUPS_DIR have no install-convention default — they stay
# empty when neither env nor manifest provides them. Consumers must check
# before use; missing-vault is graceful-degrade (every hook exits 0 on
# missing manifest).
# Bash 3.2 clean (R-23): no associative arrays, no bash-4 file-into-array
# builtins, no parameter-expansion case-conversion, and no regex capture
# groups in production paths.

# --- install-convention base (never empty) ---
export CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
export HOOKS_DIR="${HOOKS_DIR:-$CLAUDE_HOME/hooks}"
export SCHEMAS_DIR="${SCHEMAS_DIR:-$CLAUDE_HOME/schemas}"

# --- manifest reader (graceful-degrade) ---
# Returns the value at the given dotted-path inside user-manifest.json, or
# empty string if the file is missing, jq is absent, or the key is null/empty.
# Never errors — every consumer must tolerate empty output.
_USER_MANIFEST="${USER_MANIFEST_PATH:-$CLAUDE_HOME/user-manifest.json}"
_manifest_get() {
  if [ -r "$_USER_MANIFEST" ] && command -v jq >/dev/null 2>&1; then
    jq -r --arg p "$1" '
      . as $m
      | ($p | split(".") | map(select(length > 0)))
      | reduce .[] as $k ($m; if . == null then null else .[$k]? end)
      | if . == null or . == "" then "" else . end
    ' "$_USER_MANIFEST" 2>/dev/null
  fi
}

# --- two-root state tier ---
# CLAUDE_STATE_ROOT is the machine-local EPHEMERAL state root
# (XDG_STATE_HOME tier; ~/.local/state/brain-stem). All <state-root>
# resolution flows through here so C2 hooks resolve renamed roots unchanged.
# HOOKS_STATE is the hooks-runtime state dir (below); CLAUDE_STATE_ROOT is the
# broader ephemeral root that holds the coordination directory + locks.
if [ -z "${CLAUDE_STATE_ROOT:-}" ]; then
  _v="$(_manifest_get .paths.state_root)"
  if [ -n "$_v" ]; then
    CLAUDE_STATE_ROOT="$_v"
  else
    CLAUDE_STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem"
  fi
  unset _v
fi
export CLAUDE_STATE_ROOT

# Coordination directory (machine-local ephemeral): the session
# registry + the four lockf locks live here. registry.sh consumes COORD_DIR
# from this file. Resolved to machine-local ephemeral state rather than an
# in-vault $VAULT_LOGS/.coordination location.
export COORD_DIR="${COORD_DIR:-$CLAUDE_STATE_ROOT/.coordination}"

# Workshop home (R-ARCH-1a): the three-surface ephemeral staging root. Resolves
# off CLAUDE_STATE_ROOT (the XDG ephemeral tier) so it is wipe-safe and never a
# hardcoded literal. Every consumer (the install-time scaffold + future workshop
# writers) reads CLAUDE_WORKSHOP_DIR from here so the home is single-sourced.
export CLAUDE_WORKSHOP_DIR="${CLAUDE_WORKSHOP_DIR:-$CLAUDE_STATE_ROOT/workshop}"

# --- hooks runtime state (XDG state tier) ---
# G5: the hooks runtime state dir is machine exhaust, so the default roots under
# the XDG ephemeral state tier ($CLAUDE_STATE_ROOT/hooks-state), NOT $CLAUDE_HOME.
# Note: there is NO HOOKS_STATE_OVERRIDE branch here (only SESSION_STATE_ROOT below
# has one) — test isolation of HOOKS_STATE writes requires an explicit HOOKS_STATE=
# export plus a scratch CLAUDE_STATE_ROOT, not HOOKS_STATE_OVERRIDE.
if [ -z "${HOOKS_STATE:-}" ]; then
  _v="$(_manifest_get .paths.hooks_state)"
  if [ -n "$_v" ]; then HOOKS_STATE="$_v"; else HOOKS_STATE="$CLAUDE_STATE_ROOT/hooks-state"; fi
  unset _v
fi
export HOOKS_STATE

# --- per-session checkpoint/pressure state root ---
# checkpoint.md + context-pressure.json are EPHEMERAL per-session state, so they
# root under $CLAUDE_STATE_ROOT (the XDG ephemeral tier) — NOT $HOOKS_STATE. This
# is the binding C2/S2 contract: "S2 owns the root; C2 owns the sessions/<sid>/
# substructure." The session-checkpoint skill (writer) and the four C2 hooks
# (prompt-context, stop-checkpoint-check, pre-compact-checkpoint, session-register)
# all resolve sessions/<sid>/ through this single SoT so they never re-drift — the
# to $HOOKS_STATE while the skill + the binding spec stayed on $CLAUDE_STATE_ROOT.
# HOOKS_STATE_OVERRIDE wins for test isolation (feedback_test_isolation_for_hooks_state).
export SESSION_STATE_ROOT="${HOOKS_STATE_OVERRIDE:-$CLAUDE_STATE_ROOT}"

# --- plans tree ---
if [ -z "${PLANS_DIR:-}" ]; then
  _v="$(_manifest_get .paths.plans_root)"
  if [ -n "$_v" ]; then PLANS_DIR="$_v"; else PLANS_DIR="$HOME/.claude-plans"; fi
  unset _v
fi
export PLANS_DIR

# Tripwire path. Held as null-stub by default. Honors env override for
# test/CI scenarios. Consumers MUST gate on non-empty before using.
export PLANS_DIR_DEAD="${PLANS_DIR_DEAD:-}"

# --- work tree (deliverable layer) ---
# 3-tier resolver mirroring the plans arm above: env BRAIN_STEM_WORK_HOME >
# manifest .paths.work_root > default $HOME/work. The durable + human/agent-authored
# deliverables home (the 4th context surface), surfaced into the vault as Work/ by
# build-brain-vault.sh. A pre-set WORK_HOME wins (test isolation), matching the
# [ -z ] guard on PLANS_DIR. Per-spoke memory needs NOTHING here —
# resolve_memory_dir() is already cwd/git-root-keyed, so a ~/work/<spoke>/ launch
# gets its own memory slug for free.
if [ -z "${WORK_HOME:-}" ]; then
  if [ -n "${BRAIN_STEM_WORK_HOME:-}" ]; then
    WORK_HOME="$BRAIN_STEM_WORK_HOME"
  else
    _v="$(_manifest_get .paths.work_root)"
    if [ -n "$_v" ]; then WORK_HOME="$_v"; else WORK_HOME="$HOME/work"; fi
    unset _v
  fi
fi
export WORK_HOME

# --- vault (no install-convention default) ---
if [ -z "${VAULT_ROOT:-}" ]; then
  _v="$(_manifest_get .paths.vault_root)"
  if [ -z "$_v" ]; then _v="$(_manifest_get .vault.root)"; fi
  VAULT_ROOT="$_v"
  unset _v
fi
export VAULT_ROOT

# missing-vault contract (paths.sh:17-19) ONCE at the SoT producer so every
# vault-scoped consumer (frontmatter-enforce.sh, pre-write-guard.sh) READS it
# rather than re-deriving `[ -n … ] && [ -d … ]` inline. This prevents the next
# consumer from re-introducing the empty-VAULT_ROOT `/*`-collapse class
# (feedback_structural_over_bandaid: guard declared once at the producer beats
# N consumer guards). Additive — existing VAULT_ROOT semantics unchanged.
if [ -n "${VAULT_ROOT:-}" ] && [ -d "$VAULT_ROOT" ]; then VAULT_CONFIGURED=1; else VAULT_CONFIGURED=0; fi
export VAULT_CONFIGURED

# work-surface-configured contract ONCE at the SoT producer (same pattern as
# VAULT_CONFIGURED above) so every Work/-aware consumer (pre-write-guard.sh
# spoke-scoped remap, post-write-verify.sh Tier-1 bootstrap) READS it rather
# than re-deriving the triple `[ -d … ] && [ -n … ] && [ -d … ]` inline. The
# Work surface is configured IFF: the vault is configured AND a $VAULT_ROOT/Work
# vault-view exists AND WORK_HOME is non-empty AND the WORK_HOME dir exists. Any
# negative leg → 0 (graceful degrade: a remap/bootstrap consumer no-ops). VAULT_
# CONFIGURED semantics are unchanged. Bash 3.2 clean.
if [ "$VAULT_CONFIGURED" = "1" ] && [ -d "$VAULT_ROOT/Work" ] && [ -n "${WORK_HOME:-}" ] && [ -d "$WORK_HOME" ]; then
  WORK_CONFIGURED=1
else
  WORK_CONFIGURED=0
fi
export WORK_CONFIGURED

if [ -z "${VAULT_LOGS:-}" ]; then
  if [ -n "$VAULT_ROOT" ]; then VAULT_LOGS="$VAULT_ROOT/Logs"; else VAULT_LOGS=""; fi
fi
export VAULT_LOGS

# --- cron wrappers (install-convention) ---
export CRON_WRAPPERS="${CRON_WRAPPERS:-$CLAUDE_HOME/installer/cron-wrappers}"

# --- log dir (XDG state tier) ---
# Resolution: env CLAUDE_LOG_DIR > .paths.log_dir (manifest) > install default.
# Cron + orchestrator run-logs are machine exhaust, so the default roots under the
# XDG ephemeral state tier ($CLAUDE_STATE_ROOT/logs) — NOT the config-home. The
# .paths.log_dir manifest seam mirrors HOOKS_STATE above. CLAUDE_STATE_ROOT is
# resolved earlier in this file, so the default is always well-formed here.
if [ -z "${CLAUDE_LOG_DIR:-}" ]; then
  _v="$(_manifest_get .paths.log_dir)"
  if [ -n "$_v" ]; then CLAUDE_LOG_DIR="$_v"; else CLAUDE_LOG_DIR="$CLAUDE_STATE_ROOT/logs"; fi
  unset _v
fi
export CLAUDE_LOG_DIR

# --- orchestration manifest (install-convention) ---
export ORCHESTRATION_JSON="${ORCHESTRATION_JSON:-$CLAUDE_HOME/orchestration.json}"

# --- git infrastructure ---
export CLAUDE_GIT_REPO="${CLAUDE_GIT_REPO:-$CLAUDE_HOME}"
export PLANS_GIT_REPO="${PLANS_GIT_REPO:-$PLANS_DIR}"

if [ -z "${BACKUPS_DIR:-}" ]; then
  _v="$(_manifest_get .paths.backups_dir)"
  if [ -n "$_v" ]; then BACKUPS_DIR="$_v"; else BACKUPS_DIR="$HOME/Backups"; fi
  unset _v
fi
export BACKUPS_DIR

# resolve_memory_dir — absolute auto-memory dir for the current session,
# mirroring Claude Code's own resolver. Resolution order:
#   1. MEMORY_DIR env (test/CI) wins.
#   2. Flat override — CLAUDE_COWORK_MEMORY_PATH_OVERRIDE env, else
#      autoMemoryDirectory from policy then user settings — returned AS-IS.
#   3. Default — <base>/projects/<slug>/memory, where
#        slug = git-repo-root (else physical cwd), every non-[a-zA-Z0-9] -> '-'
#        base = CLAUDE_CODE_REMOTE_MEMORY_DIR env, else $CLAUDE_HOME
# Bash 3.2 clean. Never errors; prints the path on stdout.
resolve_memory_dir() {
  if [ -n "${MEMORY_DIR:-}" ]; then
    echo "$MEMORY_DIR"
    return
  fi

  # --- flat override: env, then autoMemoryDirectory (policy > user) ---
  local flat=""
  if [ -n "${CLAUDE_COWORK_MEMORY_PATH_OVERRIDE:-}" ]; then
    flat="$CLAUDE_COWORK_MEMORY_PATH_OVERRIDE"
  elif command -v jq >/dev/null 2>&1; then
    local f
    for f in "/Library/Application Support/ClaudeCode/managed-settings.json" "$CLAUDE_HOME/settings.json"; do
      if [ -r "$f" ]; then
        flat="$(jq -r '.autoMemoryDirectory // empty' "$f" 2>/dev/null)"
        [ -n "$flat" ] && break
      fi
    done
  fi
  if [ -n "$flat" ]; then
    case "$flat" in "~/"*) flat="$HOME/${flat#\~/}" ;; esac
    echo "$flat"
    return
  fi

  # --- default: <base>/projects/<git-root-or-physical-cwd slug>/memory ---
  local phys root slug base
  phys="$(pwd -P 2>/dev/null)" || phys="$(pwd)"
  root="$(git -C "$phys" rev-parse --show-toplevel 2>/dev/null)" || root=""
  [ -n "$root" ] || root="$phys"
  slug="$(printf '%s' "$root" | sed 's/[^a-zA-Z0-9]/-/g')"
  base="${CLAUDE_CODE_REMOTE_MEMORY_DIR:-$CLAUDE_HOME}"
  echo "${base}/projects/${slug}/memory"
}
