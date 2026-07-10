#!/bin/bash
# backup — Git add/commit/push wrapper across tracked directories.
#
# Landed: Sub-plan 02 T-2 (2026-04-21). Extracted from SKILL.md
# -434 pseudocode. Manifest-wired in T-3 (2026-04-29):
# system defaults stripped of user-specific targets, extension list reads
# from `user-manifest.system.backup_targets[]` (schema 1.3.0).
#
# Usage:
#   backup.sh                    # commit + push across default targets
#   backup.sh --dry-run          # show what would be committed; no writes
#   backup.sh --scope <dir>      # restrict to one dir (repeatable via env)
#   backup.sh --message <msg>    # override auto-generated commit message
#
# Default tracked targets (skipped if not a git repo):
#   $VAULT_ROOT          — vault working tree (when present)
#   $CLAUDE_HOME         — config repo
#   $PLANS_DIR           — plans tree
#   plus any paths declared in user-manifest .system.backup_targets[]
#
# Graceful degradation:
#   - Non-repo target: WARNING + remediation, counted in NONREPO_SKIPS.
#   - Clean tree: skip with info line.
#   - Push failure: surface git's fatal:/error: line + remediation; continue.
#
# Env overrides:
#   BACKUP_TARGETS       — colon-separated paths; overrides system defaults.
#   USER_MANIFEST_PATH   — override $CLAUDE_HOME/user-manifest.json source.
#
# Bash 3.2 clean. Never force-pushes, never runs destructive git ops.

set -u
set -o pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"

if [[ -z "${VAULT_ROOT:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; }
fi

DRY_RUN=0
MESSAGE=""
SCOPE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --scope)   SCOPE_OVERRIDE="$2"; shift 2 ;;
    --message) MESSAGE="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "backup: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/user-manifest-read.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/user-manifest-read.sh"; } \
  || source "$_REPO_LIB/user-manifest-read.sh"

# Determine target list.
#
# Resolution order:
#   1. --scope CLI flag (single dir override).
#   2. BACKUP_TARGETS env (colon-separated; overrides defaults entirely).
#   3. System defaults + user-manifest .system.backup_targets[] extensions.
if [[ -n "$SCOPE_OVERRIDE" ]]; then
  TARGETS="$SCOPE_OVERRIDE"
elif [[ -n "${BACKUP_TARGETS:-}" ]]; then
  TARGETS="$BACKUP_TARGETS"
else
  TARGETS=""
  [[ -n "${VAULT_ROOT:-}" ]] && TARGETS="${TARGETS:+$TARGETS:}$VAULT_ROOT"
  TARGETS="${TARGETS:+$TARGETS:}${CLAUDE_HOME:-$HOME/.claude}"
  TARGETS="${TARGETS:+$TARGETS:}${PLANS_DIR:-$HOME/.claude-plans}"
  # the durable ~/work deliverables spoke was absent from
  # the default TARGETS, so it was entirely unbacked with no owning target. Add
  # WORK_HOME (guarded like VAULT_ROOT with a non-empty check so an empty/unset
  # WORK_HOME degrades cleanly under `set -u` — no empty target). A ~/work without
  # .git routes to the non-repo WARNING branch (133), not a hard FAILED.
  [[ -n "${WORK_HOME:-}" ]] && TARGETS="${TARGETS:+$TARGETS:}$WORK_HOME"
  # User-extension list from manifest (graceful-degrade if missing/jq-absent).
  while IFS= read -r extra_path; do
    [[ -n "$extra_path" ]] && TARGETS="$TARGETS:$extra_path"
  done < <(umr_get_array '.system.backup_targets')
fi

# --- Intentional-no-remote posture list (S5 T-8) --------------------
# A target declared local-only commits its changes but is NOT pushed — the push
# is skipped with an INFO line and does NOT set FAILED, so an intentionally-local
# target (e.g. a VAULT_ROOT with zero remotes + a dirty tree) never poisons the
# tri-state exit to 1. Resolution mirrors TARGETS: the env BACKUP_NO_REMOTE_TARGETS
# (colon-separated) is UNIONED with the manifest-declared
# .system.backup_no_remote_targets[] list. Genuine push failures on a target WITH
# a remote still set FAILED=1; a no-.git target still routes to the exit-3
# branch (133) — the posture only reshapes the "committed-but-no-remote" case.
NO_REMOTE_TARGETS="${BACKUP_NO_REMOTE_TARGETS:-}"
while IFS= read -r _nr_path; do
  [[ -n "$_nr_path" ]] && NO_REMOTE_TARGETS="${NO_REMOTE_TARGETS:+$NO_REMOTE_TARGETS:}$_nr_path"
done < <(umr_get_array '.system.backup_no_remote_targets')

# _backup_is_no_remote <dir> — return 0 iff <dir> is on the intentional-no-remote
# list (exact path match; bash-3.2-safe colon split, no $@ clobber).
_backup_is_no_remote() {
  local d="$1" _oifs="$IFS" p
  [[ -z "$NO_REMOTE_TARGETS" ]] && return 1
  IFS=":"
  for p in $NO_REMOTE_TARGETS; do
    if [[ "$p" == "$d" ]]; then IFS="$_oifs"; return 0; fi
  done
  IFS="$_oifs"
  return 1
}

# --- Secret token catalog -------------------------------------
# SINGLE SOURCE OF TRUTH for high-confidence provider-token shapes. The
# pre-stage secret-scan (below) greps the staged diff against these;
# (uninstall.sh redaction, T-4) consumes the SAME shapes — keep the
# two in lockstep (design/intra-dep). High-confidence prefixes only,
# to keep false-positives near-zero (block-and-log honors the registry's
# declared failure_mode: block-and-log).
#   sk-ant-                                   Anthropic API key
#   ghp_ / github_pat_                        GitHub PAT (classic / fine-grained)
#   AKIA[0-9A-Z]{16}                          AWS access key id
#   -----BEGIN [A-Z ]*PRIVATE KEY-----        PEM private-key header
#   xox[baprs]-                               Slack token
#   Authorization: (Token|Bearer) <value>     bearer/token auth header
SECRET_TOKEN_CATALOG='sk-ant-|ghp_|github_pat_|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[baprs]-|Authorization:[[:space:]]*(Token|Bearer)[[:space:]]+[^[:space:]]+'

# --- Non-repo skip counter -------------------------------
# Counts default/target dirs that exist but are NOT git repos, so the
# first-backup-is-a-no-op condition (every default target un-inited =>
# -backup-uninstall-1) is REPORTABLE. Consumed by (T-6) to drive the
# exit-3 partial-degraded code; here it is only incremented + surfaced as a
# warning with the exact remediation command.
NONREPO_SKIPS=0

# --- Hard-failure flag (exit-3) -------------
# Set to 1 ONLY on real-failure branches (a push that failed after a successful
# commit, or a commit that failed) — NOT on graceful skips (clean tree, no
# stageable changes, not-a-directory) and NOT on non-repo targets (those drive
# the partial-degraded exit 3 via NONREPO_SKIPS). Drives the tri-state exit
# below: FAILED=1 -> exit 1 (hard failure); else NONREPO_SKIPS>0 && !dry-run ->
# exit 3 (ran, but a default target is un-backed-up); else -> exit 0.
FAILED=0

printf "## Backup"
if [[ "$DRY_RUN" -eq 1 ]]; then
  printf " (dry-run)"
fi
printf "\n\n"

# Split TARGETS by colon (bash 3.2 safe).
OLD_IFS="$IFS"
IFS=":"
set -- $TARGETS
IFS="$OLD_IFS"

for dir in "$@"; do
  [[ -z "$dir" ]] && continue
  if [[ ! -d "$dir" ]]; then
    printf -- "- %s: not a directory, skipped\n" "$dir"
    continue
  fi
  if [[ ! -d "$dir/.git" ]]; then
    # --- non-repo WARNING ---------------------------------
    # Escalated from a benign "skipped" line to an actionable WARNING: a default
    # target that is not a repo is silently un-backed-up. Print the exact
    # init+remote+push remediation and increment NONREPO_SKIPS (/T-6 turns a
    # nonzero count into exit 3).
    NONREPO_SKIPS=$((NONREPO_SKIPS + 1))
    printf -- "- %s: WARNING — not a git repo, NOT backed up\n" "$dir"
    printf -- "    remediate: git init && git remote add origin <url> && git push -u origin <branch>\n"
    continue
  fi

  # Check working tree.
  status_output=$(cd "$dir" && git status --porcelain 2>/dev/null || echo "")
  if [[ -z "$status_output" ]]; then
    printf -- "- %s: no changes\n" "$dir"
    continue
  fi

  # Count changed files (excluding vault workspace.json noise).
  change_count=$(echo "$status_output" | wc -l | tr -d ' ')

  # --- Deletion-count visibility -----------------
  # Surface deletions so a backup-of-record audit can spot unexpected mass-
  # deletions. No confirmation gate (git is history-preserving — visibility gap
  # only). Dry-run never stages, so the would-be deletion count is read from the
  # porcelain status field (a 'D' in either status column = a deletion); the
  # live path recomputes from the staged index after `git add -A .` below.
  del_count=$(echo "$status_output" \
    | awk '{ st=substr($0,1,2); if (st ~ /D/) c++ } END { print c+0 }')

  # Compose commit message. The auto-generated message folds in the deletion
  # count when nonzero ('librarian: N files (M deletions)'); a --message override
  # is used verbatim. Zero deletions omit the suffix (no '(0 deletions)' noise).
  if [[ -n "$MESSAGE" ]]; then
    commit_msg="$MESSAGE"
  else
    commit_msg="librarian: ${change_count} files"
    if [[ "$del_count" -gt 0 ]]; then
      commit_msg="${commit_msg} (${del_count} deletions)"
    fi
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf -- "- %s: %s files would be committed (%s deletions): '%s'\n" \
      "$dir" "$change_count" "$del_count" "$commit_msg"
    # Show first few entries
    echo "$status_output" | head -5 | while IFS= read -r line; do
      printf "    %s\n" "$line"
    done
    if [[ "$change_count" -gt 5 ]]; then
      printf "    ... and %d more\n" $((change_count - 5))
    fi
    continue
  fi

  # Live mode: add + commit + push.
  cd "$dir" || { printf -- "- %s: cd failed\n" "$dir"; continue; }

  # Add all tracked-modified + new files (exclude workspace.json for vault).
  if [[ -n "${VAULT_ROOT:-}" && "$dir" == "$VAULT_ROOT" ]]; then
    # Add selectively — everything except .obsidian/workspace.json.
    git add -A . 2>/dev/null
    git reset -q .obsidian/workspace.json 2>/dev/null || true
  else
    git add -A . 2>/dev/null
  fi

  # --- Pre-stage secret gate ----------------------------------
  # Runs UNCONDITIONALLY for EVERY target (defaults, --scope, backup_targets[]),
  # closing4-credential-hygiene-1/2/3/4. Sits between the stage above and
  # the commit below; composes with the empty-guard at the next step (if the
  # resets empty the staged set, the "no stageable changes" branch is taken —
  # no dead commit).
  #
  # (1) Always-exclude the three secret surfaces even when $dir was a repo
  #     BEFORE's .gitignore landed (the ignore only affects NEW additions;
  #     an already-tracked settings.local.json still stages without this reset).
  git reset -q -- settings.local.json '.pre-uninstall-*' projects/ 2>/dev/null || true
  # the projects/ reset above excludes the WHOLE subtree,
  # which unbacked the per-project MEMORY tier (projects/<slug>/memory/** —
  # MEMORY.md + topic files + episodic-chronicle.md). The per-project RUNTIME
  # state under projects/<slug>/ STAYS excluded (still reset above); RE-STAGE only
  # the memory tier (-A so memory deletions are captured too). The unconditional
  # pre-stage secret gate below then scans the newly-staged memory files, so a
  # planted token in a memory file is still excluded (no token leak).
  git add -A -- ':(glob)projects/*/memory/**' 2>/dev/null || true

  # (2) Scan the staged diff for high-confidence provider tokens; on a hit,
  #     reset that path out of the index, emit a block-and-log line, and move
  #     on. Per-file so only the offending path is excluded (not the whole
  #     commit). git diff --cached -G greps added/changed staged content.
  while IFS= read -r _staged_path; do
    [[ -z "$_staged_path" ]] && continue
    if git diff --cached -- "$_staged_path" 2>/dev/null \
         | grep -aE "$SECRET_TOKEN_CATALOG" >/dev/null 2>&1; then
      git reset -q -- "$_staged_path" 2>/dev/null || true
      printf -- "  SECRET DETECTED in %s — excluded from backup\n" "$_staged_path"
    fi
  done < <(git diff --cached --name-only 2>/dev/null)

  # Recompute the authoritative deletion count from the STAGED index now that
  # the secret gate (and the vault workspace.json reset) have run — this is the
  # exact set going into the commit, so the subject's '(M deletions)' matches
  # what is committed. Refold into the auto-generated message;
  # a --message override stays verbatim.
  del_count=$(git diff --cached --name-only --diff-filter=D 2>/dev/null \
    | wc -l | tr -d ' ')
  if [[ -z "$MESSAGE" ]]; then
    commit_msg="librarian: ${change_count} files"
    if [[ "$del_count" -gt 0 ]]; then
      commit_msg="${commit_msg} (${del_count} deletions)"
    fi
  fi

  # Commit (staged may be empty if workspace.json was only change).
  if git diff --cached --quiet 2>/dev/null; then
    printf -- "- %s: no stageable changes after filter\n" "$dir"
    continue
  fi

  if git commit -m "$commit_msg" >/dev/null 2>&1; then
    # --- push diagnostics ---------------------------------
    # Capture push stderr instead of swallowing it (>/dev/null 2>&1). On a
    # failure, fold the first actionable `fatal:`/`error:` line into the report
    # and print the cross-cluster remediation. NOTE: the `gh auth setup-git`
    # remediation only becomes ACTIONABLE once the external gh-auth setup lands —
    # `gh auth setup-git` appears nowhere in the
    # repo today; the diagnostic itself is independently valuable. The two
    # clusters' release notes cross-reference this ordering.
    if _backup_is_no_remote "$dir"; then
      # T-8 (S5): a DECLARED intentional-no-remote target commits
      # locally but is NOT pushed — emit INFO and DO NOT set FAILED, so an
      # intentionally-local target does not poison the tri-state exit to 1.
      printf -- "- %s: %d files committed (%d deletions), intentional-no-remote — push skipped (INFO)\n" \
        "$dir" "$change_count" "$del_count"
    elif push_err="$( { git push >/dev/null; } 2>&1 )"; then
      printf -- "- %s: %d files committed (%d deletions), pushed\n" \
        "$dir" "$change_count" "$del_count"
    else
      # Real failure: the commit landed but the push did not. Mark the run
      # hard-failed -> tri-state exit 1 below.
      FAILED=1
      push_diag="$( printf '%s\n' "$push_err" | grep -aE '^(fatal|error):' | head -1 )"
      printf -- "- %s: %d files committed (%d deletions), PUSH FAILED" \
        "$dir" "$change_count" "$del_count"
      if [[ -n "$push_diag" ]]; then
        printf -- " — %s" "$push_diag"
      fi
      printf -- "\n"
      printf -- "    PUSH FAILED — run 'gh auth setup-git' then 'git -C %s push'\n" "$dir"
    fi
  else
    # Real failure: the commit itself failed -> tri-state exit 1.
    FAILED=1
    printf -- "- %s: commit failed\n" "$dir"
  fi
done

# --- Tri-state exit (exit-3 +-1) --------
# Honest POSIX/rsync-style exit semantics so callers (session-close) can
# branch on the real outcome instead of a forced-green:
#   1  hard failure  — a commit or post-commit push failed (FAILED=1).
#   3  partial/degraded — the run completed but >=1 default/scoped target was a
#      non-repo and was NOT backed up (NONREPO_SKIPS>0); this is the condition
#      that finally makes the first-backup-is-a-no-op case (-backup-uninstall-1)
#      REPORT instead of returning a false `ok`. Suppressed under --dry-run.
#   0  success or graceful skip — clean tree / no stageable changes /
#      not-a-directory all exit 0, and EVERY dry-run exits 0 regardless of skips.
# Hard failure outranks partial-degraded (an exit 1 must not be masked by a 3).
# backup is ADVISORY by ratified design: these codes are CONSUMED by, never
# block the session-close chain.
if [[ "$FAILED" -eq 1 ]]; then
  exit 1
fi
if [[ "$DRY_RUN" -eq 0 && "$NONREPO_SKIPS" -gt 0 ]]; then
  exit 3
fi
exit 0
