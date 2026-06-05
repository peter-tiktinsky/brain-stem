#!/bin/bash
# session-close — Deterministic orchestrator that chains extracted librarian
# capabilities to perform end-of-session reconciliation.
#
# Deterministic shell chain that invokes existing capability shells. Does NOT
# reimplement capabilities — only glue. Respects R-42 peer-session scope contract.
#
# Scope modes:
#   --scope solo        default (no peers) — standard touched-file scope
#   --scope scoped      peers still active — own touched files only, defer
#                       reconciliation to a later reconciler pass
#   --scope reconciler  last active peer — merge all peers' touched files,
#                       run full manifest regen, clear pending flags
#   (default: auto-detect via session registry + UserPromptSubmit signals)
#
# Capability chain (per SKILL.md session-close):
#   Step 2  : scoped integrity (frontmatter-enforce, xref-check,
#             placement-validate, stale-detect, handoff-disposition-check,
#             plan-index, plan-parent-resolve) + the auto-fire adds:
#             writers-index-refresh + writers-overlap-refresh (vault-health),
#             drift-sweep --plans --fix (the master<->sub reconciler), and
#             governance-parity-audit (R-37's enforcement vehicle —
#             BUILD-DOGFOOD ONLY, excluded from the adopter chain). Cut caps
#             (cron-log-architecture, sync-check, architect-triage) are absent.
#   Step 2b : rename cascade. Runs
#             rename-detect.sh over last-24h git log across VAULT + PLANS,
#             appends to doc-dependencies.json rename_history, then
#             dry-run-cascades inbound wikilinks. No --apply from session
#             close — human-initiated.
#   Step 2c : pending-reconciliation sweep (invokes
#             ~/.claude/hooks/reconcile-sessions.sh). Fires in every mode;
#             the sweep script is idempotent + lock-guarded.
#   Step 4b : Backlog update advisory (RETIRED; backlog lifecycle is now
#             librarian-owned at
#             ~/.claude-plans/_backlog.md per governance/plans-rules.json
#             :: root_files; librarian:backlog-index capability emits row
#             findings via its `backlog-row-missing-disposition` category).
#   Step 5  : backup (git add/commit/push on tracked dirs).
#   Step 6  : write aggregated session-close log.
#
# Design constraints:
#   - Bash 3.2 clean per R-23. No declare -A, readarray, step brace expansion,
#     ${var,,}, &>>. No bashisms introduced here.
#   - Advisory-only failure semantics: individual capability failures are logged
#     and flow continues. Exit 0 always. NOTE: "advisory" means failures do not
#     halt the chain — it does NOT mean read-only. Step-2 auto-fires reconcilers
#     (writers-index-refresh, writers-overlap-refresh, drift-sweep --plans --fix)
#     that MAY WRITE to the vault / plan-tree when drift is detected. The writers
#     refreshers are drift-gated (no write when rendered content already matches
#     on disk), so a virgin-vault close is a write-no-op once the shipped seeds
#     render identically to the refreshers' output (guaranteed by the corrected
#     Vault Writers/_index.md seed). drift-sweep --plans --fix finds no master
#     plans on a virgin vault, so it writes nothing there either.
#   - Single aggregated write per run at Logs/session-close-YYYYMMDD-HHMMSS.md.
#     Individual capabilities may write their own sub-logs per their contracts.
#
# CLI:
#   session-close.sh
#   session-close.sh --scope solo|scoped|reconciler
#   session-close.sh --dry-run       # skip actual execution; report plan
#   session-close.sh --touched-files <comma-sep-paths>
#   session-close.sh --test-mode     # test harness override; stubs out
#                                    # capability invocations, writes to
#                                    # $SESSION_CLOSE_LOG_DIR (if set)
#
# Exits:
#   0 — always. Session-close is advisory.

set -uo pipefail

# ---- paths ------------------------------------------------------------------

if [[ -z "${VAULT_LOGS:-}" || -z "${COORD_DIR:-}" ]]; then
  # Source paths.sh when EITHER var is unset: a caller that pre-exports VAULT_LOGS
  # alone (without COORD_DIR) would otherwise reach the SESSION_REGISTRY="$COORD_DIR/…"
  # line below with COORD_DIR unbound and abort under `set -u`. paths.sh preserves
  # an already-set VAULT_LOGS, so this only fills in the missing COORD_DIR.
  # shellcheck source=/dev/null
  source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
fi

CAPS_DIR="${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/capabilities"
RECONCILE_SESSIONS_SH="${CLAUDE_HOME:-$HOME/.claude}/hooks/reconcile-sessions.sh"
SESSION_REGISTRY="$COORD_DIR/session-registry.json"

LOG_DIR="${SESSION_CLOSE_LOG_DIR:-$VAULT_LOGS}"

# ---- args -------------------------------------------------------------------

SCOPE=""
DRY_RUN="false"
TEST_MODE="false"
TOUCHED_FILES_CSV=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)
      SCOPE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --test-mode)
      TEST_MODE="true"
      shift
      ;;
    --touched-files)
      TOUCHED_FILES_CSV="$2"
      shift 2
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

# ---- scope auto-detect ------------------------------------------------------

auto_detect_scope() {
  # Default solo if registry absent.
  if [[ ! -f "$SESSION_REGISTRY" ]]; then
    echo "solo"
    return 0
  fi
  # Count active peers. If registry lacks python3, default solo.
  if ! command -v python3 >/dev/null 2>&1; then
    echo "solo"
    return 0
  fi
  # Resolve own session-id. Claude Code
  # does NOT export CLAUDE_SESSION_ID into Bash tool subshells, so the env
  # var is empty and the self-exclusion filter below would no-op, causing
  # the running session to count itself as a peer (pre-fix: scoped wins
  # forever, reconciler-mode unreachable). Fallback path: walk the parent
  # process chain from $$ until an ancestor pid matches an entry in the
  # session registry — that's our claude daemon, and the matched session-id
  # is "us." Verified live: typical chain is bash-tool-subshell -> shell ->
  # claude daemon, depth 2.
  local me="${CLAUDE_SESSION_ID:-}"
  if [[ -z "$me" ]] && command -v jq >/dev/null 2>&1; then
    local _pid=$$ _depth=0 _match
    while [[ -n "$_pid" && "$_pid" != "1" && "$_pid" != "0" && "$_depth" -lt 10 ]]; do
      _match=$(jq -r --argjson p "$_pid" \
        '.sessions | to_entries[] | select(.value.pid == $p) | .key' \
        "$SESSION_REGISTRY" 2>/dev/null | head -1)
      if [[ -n "$_match" ]]; then me="$_match"; break; fi
      _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
      _depth=$((_depth + 1))
    done
  fi
  local active_peers pending_peers
  active_peers=$(python3 -c '
import json, os, sys
p = sys.argv[1]
me = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("CLAUDE_SESSION_ID", "")
try:
    d = json.load(open(p))
except Exception:
    print(0); sys.exit(0)
sessions = d.get("sessions", {}) if isinstance(d, dict) else {}
n = 0
for sid, entry in sessions.items():
    if sid == me:
        continue
    status = entry.get("status", "") if isinstance(entry, dict) else ""
    if status == "active":
        n += 1
print(n)
' "$SESSION_REGISTRY" "$me" 2>/dev/null || echo 0)
  pending_peers=$(python3 -c '
import json, os, sys
p = sys.argv[1]
me = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("CLAUDE_SESSION_ID", "")
try:
    d = json.load(open(p))
except Exception:
    print(0); sys.exit(0)
sessions = d.get("sessions", {}) if isinstance(d, dict) else {}
n = 0
for sid, entry in sessions.items():
    if sid == me:
        continue
    status = entry.get("status", "") if isinstance(entry, dict) else ""
    if status == "closed-pending-reconciliation":
        n += 1
print(n)
' "$SESSION_REGISTRY" "$me" 2>/dev/null || echo 0)
  if [[ "$active_peers" -gt 0 ]]; then
    echo "scoped"
  elif [[ "$pending_peers" -gt 0 ]]; then
    echo "reconciler"
  else
    echo "solo"
  fi
}

if [[ -z "$SCOPE" ]]; then
  SCOPE=$(auto_detect_scope)
fi

case "$SCOPE" in
  solo|scoped|reconciler) : ;;
  *)
    echo "invalid --scope: $SCOPE (expected solo|scoped|reconciler)" >&2
    exit 2
    ;;
esac

# ---- orchestration state ----------------------------------------------------

TS=$(date +%Y%m%d-%H%M%S)
LOG_PATH="$LOG_DIR/session-close-$TS.md"
ISO_NOW=$(date +%Y-%m-%dT%H:%M:%S)
TODAY=$(date +%Y-%m-%d)

FINDINGS_COUNT=0
ERRORS_COUNT=0
CAPABILITY_LOG=""

# Per-run findings sink.
# Every chained capability honors the FINDINGS_OUTPUT env contract
# (hooks/lib/findings.sh: append one NDJSON finding line per finding, falling
# back to stdout when unset). Before this fix the orchestrator never set
# FINDINGS_OUTPUT and discarded capability stdout to /dev/null, so every finding
# was thrown away and FINDINGS_COUNT stayed hardwired at its 0 init — the
# findings-total emit (write_log) always reported 0. We route every capability's
# findings to this single NDJSON sink (FINDINGS_OUTPUT for honoring caps + a
# stdout copy for stdout-fallback caps like plan-parent-resolve) and, after the
# chain, count it (wc -l) so findings-total reflects the REAL finding count:
# clean is 0, dirty is non-zero.
RUN_FINDINGS_NDJSON="${TMPDIR:-/tmp}/session-close-findings-$$.ndjson"
: > "$RUN_FINDINGS_NDJSON"

record_capability() {
  local name="$1" status="$2" detail="$3"
  CAPABILITY_LOG="$CAPABILITY_LOG
- $name: $status$([ -n "$detail" ] && echo " — $detail")"
  if [[ "$status" == "error" ]]; then
    ERRORS_COUNT=$((ERRORS_COUNT + 1))
  fi
}

# Stub-aware runner. In test mode, emit a deterministic token and skip the
# real invocation. In normal mode, invoke the capability and record status.
#
# Output handling: the capability's combined output is captured
# to a temp file instead of /dev/null so a non-zero exit can fold a one-line
# digest of the real fail/skip lines into record_capability's detail (instead of
# the content-free "exit N"). On SUCCESS the behavior is IDENTICAL for every
# capability — the output is discarded and `ok` recorded (low blast radius).
#
# backup is special-cased on its tri-state exit codes: exit 3
# (partial-degraded — a default target is a non-repo and was NOT backed up) maps
# to `warn` with the remediation digest, and warn must NOT inflate
# ERRORS_COUNT; exit 1 (hard failure — a commit or post-commit push failed) maps
# to `error` carrying the real git fatal:/PUSH FAILED digest. This makes the
# false-green and the swallowed push fatal: / non-repo skip
# finally surface at the session-close layer instead of reading `ok`.
run_capability() {
  local name="$1"
  shift
  local cap_path="$CAPS_DIR/$name.sh"
  if [[ "$TEST_MODE" == "true" ]]; then
    record_capability "$name" "stub" "test-mode"
    return 0
  fi
  if [[ ! -x "$cap_path" ]]; then
    record_capability "$name" "skip" "not-installed"
    return 0
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    record_capability "$name" "dry-run" "would invoke: $cap_path $*"
    return 0
  fi
  local out_file cap_stdout rc
  out_file="${TMPDIR:-/tmp}/session-close-cap-$name-$$.out"
  cap_stdout="${TMPDIR:-/tmp}/session-close-cap-$name-$$.stdout"
 # wire the per-run findings sink. Export FINDINGS_OUTPUT so
  # caps that honor it append findings NDJSON directly to the shared sink; for
  # the stdout-fallback class (a findings cap that prints findings to stdout when
  # FINDINGS_OUTPUT is unset), this cap's stdout is also appended to the SAME
  # sink so a single sink covers both classes. stderr is captured to out_file
  # for the error-detail digest, so record_capability error-detection
  # (ERRORS_COUNT) is unchanged. out_file carries THIS cap's combined
 # stdout+stderr (not the accumulated sink) so the fail/skip digest
  # still resolves to this capability's own lines on a non-zero exit.
 #
  # The stdout copy is FILTERED to NDJSON finding lines (those beginning with
  # `{` — the emit_finding/emit_event shape from hooks/lib/findings.sh). Findings
  # caps that honor FINDINGS_OUTPUT write findings to the sink directly and print
  # only summary/info noise to stdout (e.g. placement-validate:251
  # `placement-validate: scanned=N findings=N`); backup prints a `## Backup`
  # human report. Copying that non-finding noise verbatim would inflate
  # findings-total on a clean run (breaking the clean-vault==0 contract), so only
  # `{`-prefixed JSON-finding lines from stdout are folded into the sink — this
  # captures the stdout-fallback findings class while excluding summary/report
 # noise. out_file still gets the FULL stdout (+ stderr) for the digest.
  FINDINGS_OUTPUT="$RUN_FINDINGS_NDJSON" "$cap_path" "$@" \
    >"$cap_stdout" 2>"$out_file"
  rc=$?
  grep -a '^{' "$cap_stdout" >>"$RUN_FINDINGS_NDJSON" 2>/dev/null
  cat "$cap_stdout" >>"$out_file"
  rm -f "$cap_stdout"
  if [[ "$rc" -eq 0 ]]; then
    record_capability "$name" "ok" ""
    rm -f "$out_file"
    return 0
  fi
  # Non-zero: fold a one-line digest of the fail/skip lines into the detail.
  local digest
  if [[ "$name" == "backup" && "$rc" -eq 3 ]]; then
    # backup partial-degraded (non-repo): a default target was NOT backed up.
    # warn (NOT error — must not inflate ERRORS_COUNT). Surface the remediation.
    digest=$(grep -aE 'WARNING — not a git repo|^[[:space:]]*remediate:' "$out_file" \
      | head -1 | sed 's/^[[:space:]]*//')
    [[ -z "$digest" ]] && digest="exit 3 — a default backup target is a non-repo and was NOT backed up"
    record_capability "$name" "warn" "$digest"
  elif [[ "$name" == "backup" && "$rc" -eq 1 ]]; then
    # backup hard failure (push fatal: / commit fail). error with the digest.
    digest=$(grep -aE 'PUSH FAILED|^(fatal|error):|commit failed' "$out_file" \
      | head -1 | sed 's/^[[:space:]]*//')
    [[ -z "$digest" ]] && digest="exit 1"
    record_capability "$name" "error" "$digest"
  else
    digest=$(grep -aE '^(fatal|error):|FAILED|WARNING|ERROR' "$out_file" \
      | head -1 | sed 's/^[[:space:]]*//')
    if [[ -n "$digest" ]]; then
      record_capability "$name" "error" "exit $rc — $digest"
    else
      record_capability "$name" "error" "exit $rc"
    fi
  fi
  rm -f "$out_file"
}

# ---- Step 2c gate: reconciliation sweep ------------------------------------
# R-42 contract: scoped runs DEFER the sweep to a later reconciler pass.
run_reconcile_sweep() {
  if [[ "$SCOPE" == "scoped" ]]; then
    record_capability "reconcile-sessions" "skip" "scoped — deferred to reconciler"
    return 0
  fi
  if [[ "$TEST_MODE" == "true" ]]; then
    record_capability "reconcile-sessions" "stub" "test-mode"
    return 0
  fi
  if [[ ! -x "$RECONCILE_SESSIONS_SH" ]]; then
    record_capability "reconcile-sessions" "skip" "not-installed"
    return 0
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    record_capability "reconcile-sessions" "dry-run" "would invoke: $RECONCILE_SESSIONS_SH"
    return 0
  fi
 # set FINDINGS_OUTPUT in the capability environment and route
  # any findings stdout to the shared per-run sink (uniform with run_capability)
  # instead of discarding it to /dev/null; stderr still discarded (sweep emits
  # its own sub-logs, not findings NDJSON).
  if FINDINGS_OUTPUT="$RUN_FINDINGS_NDJSON" "$RECONCILE_SESSIONS_SH" \
      >>"$RUN_FINDINGS_NDJSON" 2>/dev/null; then
    record_capability "reconcile-sessions" "ok" ""
  else
    record_capability "reconcile-sessions" "error" "exit $?"
  fi
}

# ---- build-dogfood detection ----------------------------------------------
# governance-parity-audit is R-37's enforcement vehicle but its
# repo-only pillar inputs + unshipped narrative spokes are unsatisfiable on an
# adopter (pre-launch INTERNAL only). So it is chained ONLY on the foundation
# source repo's own dogfood session-close, EXCLUDED from
# the shipped adopter chain. Signal = the foundation source repo present at
# $FOUNDATION_REPO (default ~/Code/brain-stem) with a governance/ pillar tree —
# the build box, never an adopter install.
is_build_dogfood() {
  local repo="${FOUNDATION_REPO:-$HOME/Code/brain-stem}"
  [[ -d "$repo/governance" ]]
}

# ---- Step 2: scoped integrity ----------------------------------------------
# Scope argument is a no-op for stubs; real capabilities already read their
# own scope via CLI flags per their SKILL.md contracts.

step2_integrity() {
  run_capability frontmatter-enforce --check
  run_capability xref-check
  run_capability placement-validate
  run_capability stale-detect
  run_capability handoff-disposition-check
  run_capability plan-index
  run_capability plan-parent-resolve
  # Chain the vault-health writers-* refreshers (R-44 _index regen).
  # writers-index-refresh -> Vault Writers/_index.md catalog;
  # writers-overlap-refresh -> _overlap-matrix.md. writers-health-audit is NOT
  # chained here — it is a findings-JSONL no-vault-write sweep (cron_block:daily,
  # registry-declared); its daily home is a documented carry-over (a librarian-full
  # launchd is deferred to v1.1). The cron_block:daily declaration is intact in
  # capability-registry.json.
  run_capability writers-index-refresh
  run_capability writers-overlap-refresh
  # Auto-fire the master<->sub reconciler (pull-based
  # derived aggregation; R-61/R-62). drift-sweep --plans --fix runs
  # ONLY the master<->sub aggregation axis and repairs each master's sub_plans[]
  # read-replica via subplan-aggregate (single-writer invariant). Without this the
  # master sub_plans[] never auto-reconciles.
  run_capability drift-sweep --plans --fix
  # R-37's enforcement vehicle, build-dogfood only.
  if is_build_dogfood; then
    run_capability governance-parity-audit
  fi
}

# ---- Step 2b: rename cascade -----------------------------------------------
# Detect renames in the last 24h across VAULT + PLANS repos; append audit
# rows to doc-dependencies.json; cascade inbound wikilinks (dry-run only —
# user runs --apply separately). Idempotent: re-running
# without new commits produces zero new findings.
step2b_rename_cascade() {
  if [[ "$TEST_MODE" == "true" ]]; then
    record_capability "rename-detect" "stub" "test-mode"
    record_capability "rename-history-sync" "stub" "test-mode"
    record_capability "rename-cascade" "stub" "test-mode"
    return 0
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    record_capability "rename-cascade-pipeline" "dry-run" "would invoke rename-detect | tee (rename-history-sync append) | rename-cascade"
    return 0
  fi
  local rd="$CAPS_DIR/rename-detect.sh"
  local rhs="$CAPS_DIR/rename-history-sync.sh"
  local rc="$CAPS_DIR/rename-cascade.sh"
  if [[ ! -x "$rd" || ! -x "$rc" || ! -x "$rhs" ]]; then
    record_capability "rename-cascade-pipeline" "skip" "not-installed"
    return 0
  fi
  # Capture NDJSON once, feed both downstream consumers.
 # set FINDINGS_OUTPUT in the capability environment so any
  # findings these caps emit land in the shared per-run sink. rename-detect's
  # STDOUT is its rename-record data pipeline (captured to $tmp_nd, fed to the
  # downstream consumers) — NOT findings — so it must stay on stdout; setting
  # FINDINGS_OUTPUT routes its findings (if any) to the sink and keeps the data
  # channel clean. rename-history-sync / rename-cascade have no data stdout, so
  # their findings go to the sink while their info stdout stays discarded.
  local tmp_nd="${TMPDIR:-/tmp}/session-close-rename-$$.ndjson"
  if FINDINGS_OUTPUT="$RUN_FINDINGS_NDJSON" "$rd" --since "24 hours ago" > "$tmp_nd" 2>/dev/null; then
    record_capability "rename-detect" "ok" "$(wc -l < "$tmp_nd" | tr -d ' ') record(s)"
  else
    record_capability "rename-detect" "error" "exit $?"
    rm -f "$tmp_nd"
    return 0
  fi
  if [[ -s "$tmp_nd" ]]; then
    if FINDINGS_OUTPUT="$RUN_FINDINGS_NDJSON" "$rhs" append < "$tmp_nd" >/dev/null 2>&1; then
      record_capability "rename-history-sync" "ok" ""
    else
      record_capability "rename-history-sync" "error" "exit $?"
    fi
    if FINDINGS_OUTPUT="$RUN_FINDINGS_NDJSON" "$rc" < "$tmp_nd" >/dev/null 2>&1; then
      record_capability "rename-cascade" "ok" "dry-run"
    else
      record_capability "rename-cascade" "error" "exit $?"
    fi
  else
    record_capability "rename-cascade-pipeline" "ok" "no renames in 24h window"
  fi
  rm -f "$tmp_nd"
}

# ---- Step 2d: trinity-drift-detect ------------------------------------------
# After 2c pending-reconciliation, walk all plan
# dirs for spec/manifest/tasks-ledger drift. Advisory. Uses shared find-emission
# contract (FINDINGS_OUTPUT honored). Scoped runs still invoke — detection is
# cheap + read-only.
step2d_trinity_drift() {
  run_capability trinity-drift-detect
}

# ---- (former Step 3: sync-check / Step 4c: architect-triage) ---------------
# sync-check and architect-triage are cut capabilities (bodies absent +
# unregistered). Their run_capability calls, step functions, and
# orchestration-tail invocations are all absent, so the chain no longer
# carries dead "skip: not-installed" references. The registry session-close
# dependencies[] omits the same caps (regenerated, never hand-edited).

# ---- Step 5: backup ---------------------------------------------------------

step5_backup() {
  # Only full reconciler or solo runs commit. Scoped runs defer backup
  # to avoid partial-state commits during overlapping sessions.
  if [[ "$SCOPE" == "scoped" ]]; then
    record_capability "backup" "skip" "scoped — deferred"
    return 0
  fi
  run_capability backup
}

# ---- Step 6: write aggregated log ------------------------------------------

# Idempotency: if a session-close log was written within the last 60s AND
# the orchestrator is being re-invoked without --dry-run, skip the write.
idempotent_guard() {
  local recent
  recent=$(ls -1t "$LOG_DIR"/session-close-*.md 2>/dev/null | head -1)
  [[ -z "$recent" ]] && return 1
  local age
  age=$(( $(date +%s) - $(stat -f %m "$recent" 2>/dev/null || echo 0) ))
  if [[ "$age" -lt 60 ]]; then
    return 0
  fi
  return 1
}

write_log() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] would write: $LOG_PATH"
    return 0
  fi
  if idempotent_guard; then
    echo "[idempotent] recent session-close log found (<60s) — skipping write"
    return 0
  fi
  mkdir -p "$LOG_DIR"
  {
    echo "---"
    echo "type: log"
    echo "log-type: session-close"
    echo "mode: shell-orchestrator"
    echo "scope: $SCOPE"
    echo "date: $TODAY"
    echo "timestamp: $ISO_NOW"
    echo "created: $TODAY"
    echo "updated: $TODAY"
    echo "findings-total: $FINDINGS_COUNT"
    echo "errors-total: $ERRORS_COUNT"
    echo "tags: [\"#log/session-close\"]"
    echo "---"
    echo ""
    echo "# Session Close — $ISO_NOW"
    echo ""
    echo "**Scope:** $SCOPE"
    echo "**Orchestrator:** capabilities/session-close.sh"
    echo ""
    echo "## Capability Chain"
    echo "$CAPABILITY_LOG"
    echo ""
    echo "## Summary"
    echo ""
    echo "- Capabilities invoked: see chain above"
    echo "- Errors: $ERRORS_COUNT"
    echo "- Scope: $SCOPE"
    echo ""
    if [[ "$ERRORS_COUNT" -gt 0 ]]; then
      echo "## Error Findings"
      echo ""
      echo "One or more capabilities exited non-zero. Session-close is advisory"
      echo "and did not halt. Review the capability chain section for details."
    fi
  } > "$LOG_PATH"
  echo "session-close log: $LOG_PATH"
}

# ---- orchestration ----------------------------------------------------------

step2_integrity
step2b_rename_cascade
run_reconcile_sweep
step2d_trinity_drift
step5_backup

# Count the per-run findings
# sink AFTER the capability chain and BEFORE write_log emits `findings-total:`.
# FINDINGS_COUNT is no longer left at its 0 init — it reflects the real count of
# findings every chained capability routed to RUN_FINDINGS_NDJSON. Clean vault
# is 0 (empty sink); a vault with drift is the non-zero line count.
if [[ -f "$RUN_FINDINGS_NDJSON" ]]; then
  FINDINGS_COUNT=$(wc -l < "$RUN_FINDINGS_NDJSON" | tr -d ' ')
fi

write_log

rm -f "$RUN_FINDINGS_NDJSON"
exit 0
