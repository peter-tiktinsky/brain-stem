#!/bin/bash
# session-close — Deterministic orchestrator that chains extracted librarian
# capabilities to perform end-of-session reconciliation.
#
# Landed: T-1 (2026-04-21). Replaces the model-interpreted
# pseudocode in SKILL.md §Invocation Mode: session-close with a shell chain
# that invokes existing capability shells. Does NOT reimplement capabilities —
# only glue. Respects R-42 peer-session scope contract.
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
#             governance-parity-audit (R-37's enforcement vehicle — BUILD-DOGFOOD
#             ONLY, excluded from the adopter chain per LOCKED G2). The 3 cut caps
#             (cron-log-architecture, sync-check, architect-triage) were struck.
#   Step 2b : rename cascade. Runs
#             rename-detect.sh over last-24h git log across VAULT + PLANS,
#             then dry-run-cascades inbound wikilinks. No --apply from session
#             close — human-initiated.
#   Step 2c : pending-reconciliation sweep (invokes
#             ~/.claude/hooks/reconcile-sessions.sh). Fires in every mode;
#             the sweep script is idempotent + lock-guarded.
#   Step 4b : Backlog update advisory (RETIRED 2026-05-22;
#             backlog lifecycle now librarian-owned at
#             ~/.claude-plans/_backlog.md per governance/plans-rules.json
#             :: root_files; librarian:backlog-index capability emits row
#             findings via its `backlog-row-missing-disposition` category).
#   Step 5  : (removed) backup — T-1 made the close structurally
#             commit-free; /librarian backup stays the standalone by-hand cap
#             (SECURITY.md:11). The MANUAL close offers it; auto never does.
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
#   - Single aggregated write per run at <state>/logs/session-close-YYYYMMDD-HHMMSS.md.
#     Individual capabilities may write their own sub-logs per their contracts.
#
# CLI:
#   session-close.sh
#   session-close.sh --scope solo|scoped|reconciler
#   session-close.sh --dry-run       # skip actual execution; report plan
#   session-close.sh --touched-files <comma-sep-paths>
#   session-close.sh --cwd <dir>     # the CLOSING session's own cwd (the SessionEnd
#                                    # payload .cwd). Preferred over ambient $PWD for
#                                    # active-spoke resolution; $PWD is the fallback.
#   session-close.sh --test-mode     # test harness override; stubs out
#                                    # capability invocations, writes to
#                                    # $SESSION_CLOSE_LOG_DIR (if set)
#
# Exits:
#   0 — always. Session-close is advisory.

set -uo pipefail

# Capture whether the CALLER explicitly chose a plans root, BEFORE paths.sh resolves a
# fallback below. Consumed by the corpus-walk dead-switch: a fallback-resolved PLANS_DIR
# must not be mistaken for a deliberate caller choice.
_SC_PLANS_CALLER_SET=0
if [[ -n "${PLANS_ROOT:-}" || -n "${PLANS_DIR:-}" ]]; then
  _SC_PLANS_CALLER_SET=1
fi

# ---- paths ------------------------------------------------------------------

if [[ -z "${VAULT_LOGS:-}" || -z "${COORD_DIR:-}" || -z "${CLAUDE_STATE_ROOT:-}" ]]; then
  # Source paths.sh when ANY needed var is unset: a caller that pre-exports VAULT_LOGS
  # alone (without COORD_DIR) would otherwise reach the SESSION_REGISTRY="$COORD_DIR/…"
  # line below with COORD_DIR unbound and abort under `set -u`. CLAUDE_STATE_ROOT is
  # likewise required now that the session-close receipt lands under it (G1 relocation,
  # state/logs/). paths.sh preserves an already-set VAULT_LOGS, so this fills the gaps.
  # shellcheck source=/dev/null
  source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
fi

# --- test-harness plans-corpus isolation (class-level dead-switch) -----------
# session-close runs several plans-CORPUS-walking steps (the completed_at stamp; the
# auto-fired drift-sweep --plans --fix -> subplan-aggregate; plan-index; ...). Each
# resolves the plans root from paths.sh's fallback ($HOME/.claude-plans / user-manifest)
# when the caller does not override it. Under a TEST/CI harness that reaches session-close
# — including the SessionEnd DETACHED auto-close spawn (hooks/session-deregister.sh), which
# runs the real session-close inheriting the caller's env with no PLANS_DIR of its own —
# that fallback silently resolves to the operator's LIVE corpus. PLANS_DIR_DEAD marks a
# test/CI context; when it is armed AND the caller chose NO plans root, re-point the plans
# root to an isolated empty throwaway so EVERY corpus-walking step operates on an empty
# tree, never the live corpus. Production (dead-switch empty) and tests that own their
# plans root (PLANS_ROOT/PLANS_DIR set) are unaffected.
if [[ -n "${PLANS_DIR_DEAD:-}" && "$_SC_PLANS_CALLER_SET" == "0" ]]; then
  _SC_DEAD_PLANS="${CLAUDE_STATE_ROOT:-${TMPDIR:-/tmp}}/.session-close-dead-plans.$$"
  mkdir -p "$_SC_DEAD_PLANS" 2>/dev/null || true
  PLANS_DIR="$_SC_DEAD_PLANS"
  PLANS_ROOT="$_SC_DEAD_PLANS"
  export PLANS_DIR PLANS_ROOT
fi

CAPS_DIR="${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/capabilities"
RECONCILE_SESSIONS_SH="${CLAUDE_HOME:-$HOME/.claude}/hooks/reconcile-sessions.sh"
SESSION_REGISTRY="$COORD_DIR/session-registry.json"

# Cadence gate for the schedulable roster. sweep_due() decides — from a durable last-run
# ledger and a rolling window — whether a capability that declares a cron_block cadence is
# due to fire again at this detached close (the deterministic trigger that replaces the
# absent background scheduler). Sourced here so the cadence-roster step below can consult
# it; guarded so an install lacking the lib degrades to no cadence firing (never a crash).
_SC_CADENCE_LIB="${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/cadence.sh"
CADENCE_AVAILABLE=0
if [[ -r "$_SC_CADENCE_LIB" ]]; then
  # shellcheck source=/dev/null
  if source "$_SC_CADENCE_LIB" 2>/dev/null && command -v sweep_due >/dev/null 2>&1; then
    CADENCE_AVAILABLE=1
  fi
fi

LOG_DIR="${SESSION_CLOSE_LOG_DIR:-$CLAUDE_STATE_ROOT/logs}"

# ---- args -------------------------------------------------------------------

SCOPE=""
DRY_RUN="false"
TEST_MODE="false"
TOUCHED_FILES_CSV=""
# T-4: the session's OWN id, threaded EXPLICITLY (arg/env). The SessionEnd
# spawn (session-deregister.sh) and the manual /librarian close pass --session-id so
# self-ID never guesses. Env fallback CLAUDE_SESSION_ID (rarely exported into Bash
# subshells). Empty here -> auto_detect_scope's demoted last-resort ancestor-walk.
SELF_SESSION_ID="${CLAUDE_SESSION_ID:-}"
# The closing session's OWN cwd, threaded EXPLICITLY (--cwd). The SessionEnd spawn
# (session-deregister.sh) reads it from the harness payload `.cwd` — the session's LAUNCH
# directory — and the SessionStart integrity backstop threads the crashed row's stored cwd
# (or $HOME) at its recovery spawn. Empty here -> the ambient-$PWD fallback in
# step2_integrity, which is the working directory the DETACHED chain woke up in and is NOT
# the launch dir in general.
SELF_CWD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)
      SCOPE="$2"
      shift 2
      ;;
    --session-id)
      SELF_SESSION_ID="$2"
      shift 2
      ;;
    --cwd)
      SELF_CWD="$2"
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
  # Resolve own session-id. T-4 (identity, not liveness): self-ID is now
  # threaded EXPLICITLY via --session-id (session-deregister.sh's SessionEnd spawn +
  # the manual /librarian close), so `me` is KNOWN and never guessed. Fallback order:
  #   1. --session-id / SELF_SESSION_ID (the threaded id — the correct source)
  #   2. CLAUDE_SESSION_ID env (rarely exported into Bash tool subshells)
  #   3. the pid ancestor-walk — DEMOTED to a LAST-RESORT fallback (documented caveat).
  # WHY DEMOTED: the walk matches a stored .value.pid against an ancestor pid, but under
  # a SHARED ancestor pid (Task/Agent subagents; multiple session-ids in one long-lived
  # process) it matches the WRONG row — an identity bug no liveness-verdict change fixes.
  # It survives ONLY to degrade gracefully for a caller that threads neither an arg nor
  # the env; a threaded --session-id always wins. auto_detect_scope is READ-ONLY (it
  # computes scope, never mutates a row), so a wrong/empty fallback never corrupts a row.
  local me="${SELF_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
  if [[ -z "$me" ]] && command -v jq >/dev/null 2>&1; then
    # LAST-RESORT (T-4 caveat): under a shared ancestor pid this can match a
    # sibling's row. Kept only for a caller that threads no --session-id / env id.
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
import json, os, sys, time
from datetime import datetime, timezone
p = sys.argv[1]
me = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("CLAUDE_SESSION_ID", "")
try:
    threshold = int(sys.argv[3]) if len(sys.argv) > 3 else 1800
except (TypeError, ValueError):
    threshold = 1800
now = time.time()
def _epoch(iso):
    # Portable ISO8601 ...Z -> UTC epoch (0 if absent/unparseable). Mirrors
    # registry.sh::iso8601_to_epoch; python datetime is inherently BSD/GNU-portable
    # (no `date -jf`), so this alive() mirror carries no BSD-only degrade.
    if not iso or iso == "null":
        return 0
    try:
        return datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except Exception:
        return 0
def alive(pid):
    # PID-liveness shim: ProcessLookupError -> dead; PermissionError ->
    # alive (a real process we cannot signal); other/non-int -> dead.
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True
def live(entry):
    # T-5: heartbeat-authoritative mirror of registry.sh::session_liveness_verdict.
    # fresh hb -> live; stale hb -> dead (incl. the live-pid+stale-hb phantom quadrant);
    # absent/unparseable hb floors off started; the pid shim is consulted ONLY when hb AND
    # started are both absent (backward-compat). pid is never a keep-signal otherwise.
    e = _epoch(entry.get("last_heartbeat"))
    if e > 0:
        return (now - e) <= threshold
    e = _epoch(entry.get("started"))
    if e > 0:
        return (now - e) <= threshold
    return alive(entry.get("pid"))
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
    if status == "active" and live(entry):
        n += 1
print(n)
' "$SESSION_REGISTRY" "$me" "${STALE_THRESHOLD_SECS:-1800}" 2>/dev/null || echo 0)
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

# Idempotency, evaluated at chain START (and again at write time — see Step 6):
# the chain's own runtime exceeds the 60s window, so an at-write-only check could
# never dedupe a back-to-back re-invocation — it would re-run the whole chain and
# then write a second receipt anyway. A re-invocation arriving within 60s of the
# last receipt exits 0 here, before any capability work. Dry runs never short-
# circuit: they write nothing, so they always report the full would-do walk.
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
if [[ "$DRY_RUN" != "true" ]] && idempotent_guard; then
  echo "[idempotent] recent session-close log found (<60s) — skipping session-close (receipt already written)"
  exit 0
fi

# ---- orchestration state ----------------------------------------------------

TS=$(date +%Y%m%d-%H%M%S)
LOG_PATH="$LOG_DIR/session-close-$TS.md"
ISO_NOW=$(date +%Y-%m-%dT%H:%M:%S)
TODAY=$(date +%Y-%m-%d)

FINDINGS_COUNT=0
ERRORS_COUNT=0
# T-4 (B-1 #3; closes the run_capability silent-skip class): count
# capabilities whose BODY IS PRESENT ON DISK but is NON-EXEC (the dead-R-40
# placement-validate class — public v1.1.1 shipped placement-validate.sh at
# git-index 100644, so a real adopter session-close recorded `placement-validate:
# skip — not-installed` rc=0 and R-40 governance placement validation was DEAD
# while the orchestrator stayed GREEN). A present-but-non-exec cap is NOT
# "not-installed" — it is an installation-mode defect that MUST surface, so the
# orchestrator exits NON-ZERO when this count is > 0 (the advisory `exit 0 always`
# contract is carved out ONLY for this class — a body-present-but-non-exec
# required cap, which is a delivery defect the gate must observe, not a runtime
# capability error). `not-installed` is reserved for a GENUINELY MISSING file.
NONEXEC_REQUIRED_COUNT=0
CAPABILITY_LOG=""

# Per-run findings sink.
# Every chained capability honors the FINDINGS_OUTPUT env contract
# (hooks/lib/findings.sh: append one NDJSON finding line per finding, falling
# back to stdout when unset). Before T-1 the orchestrator never set
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
run_capability() {
  local name="$1"
  shift
  local cap_path="$CAPS_DIR/$name.sh"
  if [[ "$TEST_MODE" == "true" ]]; then
    record_capability "$name" "stub" "test-mode"
    return 0
  fi
  # T-4 (B-1 #3): distinguish body-present-but-non-exec from genuinely
  # absent. A present-but-non-exec cap is a delivery-mode defect (the dead-R-40
  # placement-validate class) — record `error` (which bumps ERRORS_COUNT) AND
  # flag it so the orchestrator exits non-zero, instead of silently skipping it
  # as `not-installed` rc=0. `not-installed` (return 0) is RESERVED for a file
  # that does not exist on disk at all (a genuinely unshipped/optional cap).
  if [[ ! -x "$cap_path" ]]; then
    if [[ -e "$cap_path" ]]; then
      NONEXEC_REQUIRED_COUNT=$((NONEXEC_REQUIRED_COUNT + 1))
      record_capability "$name" "error" "present-but-non-exec — capability body shipped NON-EXEC ($cap_path); cannot run (the dead-R-40/100644-delivery class)"
      return 0
    fi
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
  # T-1: wire the per-run findings sink. Export FINDINGS_OUTPUT so
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
  # `placement-validate: scanned=N findings=N`). Copying that non-finding noise verbatim would inflate
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
  digest=$(grep -aE '^(fatal|error):|FAILED|WARNING|ERROR' "$out_file" \
    | head -1 | sed 's/^[[:space:]]*//')
  if [[ -n "$digest" ]]; then
    record_capability "$name" "error" "exit $rc — $digest"
  else
    record_capability "$name" "error" "exit $rc"
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
  # T-1: set FINDINGS_OUTPUT in the capability environment and route
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

# ---- build-dogfood detection -----------------------------------------------
# governance-parity-audit is R-37's enforcement vehicle, but its repo-only
# pillar inputs are unsatisfiable on an adopter install, so it chains ONLY on
# the build's own dogfood session-close and is EXCLUDED from the shipped
# adopter chain. Signal = the foundation source repo present at
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
  # = ACTIVE-SPOKE-ONLY: resolve the active spoke
  # ONCE for the binder-maintenance block below. The binder generators (the 3
  # plan-* re-derivers + the situating card + the handoff-chronicle append) are
  # scoped to the ACTIVE SPOKE ONLY — whole-tree re-derive is reserved for the
  # `librarian-full` invocation, never the per-session close. The spoke is resolved through
  # the shared spoke_resolve_from_cwd resolver (skills/new-plan/lib/spoke-resolve.sh)
  # against the anchored-spoke registry, from ONE of two sources, in this order:
  #
  #   1. $SELF_CWD — the cwd threaded EXPLICITLY via --cwd. Its source is the SessionEnd
  #      harness payload's `.cwd`, which hooks/session-deregister.sh reads and passes to
  #      this detached spawn (the SessionStart integrity backstop threads its recovery
  #      spawn the same way). That payload field is the session's LAUNCH directory, and it
  #      is the same field hooks/session-start-project-context.sh reads to key the
  #      situating card — so the close and the card resolve from the same input.
  #
  #   2. ambient $PWD — FALLBACK ONLY, for a caller that threads no --cwd. It is the
  #      working directory this DETACHED chain happens to wake up in, which is NOT the
  #      session's launch dir in general: a headless lane whose working directory is $HOME
  #      resolves `home` and rewrites the HOME binder for a session that belonged to
  #      another spoke. (The pre-threading comment here asserted that $PWD was "the same
  #      anchor the SessionStart card hook keys on" — it was not. That hook keys on the
  #      payload `.cwd`; the two are different values and were observed resolving to
  #      different spokes within one second.)
  #
  # FALLBACK (documented, deliberate): if the resolver errors (registry unreadable,
  # python3 absent, collision) OR yields an empty key, default active_spoke="home"
  # — the registry catch-all. We MUST NOT silently fall back to a whole-tree
  # re-derive (passing no --spoke), which would violate ACTIVE-SPOKE-ONLY. The
  # `home` catch-all is the same key spoke_resolve_from_cwd returns for an
  # unanchored cwd, so the fallback is consistent with the resolver's own default.
  local active_spoke=""
  local _spoke_resolver="${CLAUDE_HOME:-$HOME/.claude}/skills/new-plan/lib/spoke-resolve.sh"
  if [[ ! -r "$_spoke_resolver" ]]; then
    # dev/source-tree resolution: CAPS_DIR is .../skills/librarian/capabilities
    _spoke_resolver="$(cd "$CAPS_DIR/../../new-plan/lib" 2>/dev/null && pwd)/spoke-resolve.sh"
  fi
  if [[ -r "$_spoke_resolver" ]]; then
    # shellcheck source=/dev/null
    source "$_spoke_resolver"
    active_spoke="$(spoke_resolve_from_cwd "${SELF_CWD:-$PWD}" 2>/dev/null)"
  fi
  if [[ -z "$active_spoke" ]]; then
    active_spoke="home"
  fi

  # Invoke the SCOPED Work-deliverable lane so the ~390 Work
  # bodies behind the Work/ symlink are validated at close. Pre-130 this ran a bare
  # `--check` (the recent/full whole-vault lane, symlink-inert per FIX #7), so the
  # scoped lane FIX #7 built had no caller and Work bodies were never validated. `--scope`
  # and the `--check`/`--fix` MODE are ORTHOGONAL flags (frontmatter-enforce's arg parse — no
  # `--enforce` flag exists): --scope sets WALK=scope (build_scope sources the shared walker,
  # symlink-following), --check keeps validation read-only. VAULT_ROOT-empty degrades
  # cleanly (frontmatter-enforce's own VAULT_CONFIGURED guard exits 0). This is the R2
  # serialization-cluster edit; it does NOT touch the SELF_SESSION_ID/--session-id
  # flow this lane resolves separately.
  run_capability frontmatter-enforce --scope "${VAULT_ROOT:-}/Work" --check
  # Plans-lane frontmatter contract check. The Work lane above validates the Work
  # deliverable surface behind the Work/ symlink; the plans tree carries its own
  # frontmatter contract that no close lane reached. A scoped lane over the vault's Plans/
  # symlink surface (the scoped walker descends it, the same mechanism as the Work lane)
  # surfaces contract-violating frontmatter in the plans tree too. Its findings flow into
  # the per-run sink and are bounded by the triage digest (a high-volume first pass does not
  # flood the log). Projects/Skills/Wiki stay out of the close lane until their contract
  # policy settles.
  if [[ -n "${VAULT_ROOT:-}" ]]; then
    run_capability frontmatter-enforce --scope "${VAULT_ROOT}/Plans" --check
  fi
  run_capability xref-check
  run_capability placement-validate
  # Feed the starved plans-root placement reader. The default call above reaches only
  # vault-proper (the external symlink surfaces are pruned at top level), so the
  # plans-root-namespace arm — which writes .drift_findings.placement.plans_root, the
  # leaf the SessionStart placement reader consumes — has no other scheduled caller. A
  # second call scoped to the plans root runs that rule so the leaf is populated at close
  # (a sibling leaf; the vault scope is never clobbered).
  if [[ -n "${PLANS_DIR:-}" ]]; then
    run_capability placement-validate --scope "$PLANS_DIR"
  fi
  run_capability stale-detect
  # T-7: pointer-currency scan — advisory, propose-only,
  # CHANGE-GATED. Verifies every plain-text absolute-path pointer in MEMORY.md +
  # memory topic-files + rules/*.md still resolves on disk (INVERTS memory-
  # staleness). --session-close fires the change-gate: it SILENT no-ops unless a
  # tracked file changed since the last scan (content-hash state under HOOKS_STATE)
  # — defeats alert-fatigue. Positioned between stale-detect and the close-out
  # write so its findings flow into the per-run sink with the rest of step 2.
  run_capability pointer-currency-scan --session-close
  # Forward the session's touched files to the R-25 handoff-disposition close-time
  # scan. When a caller supplied --touched-files, split that CSV (bash-3.2-safe IFS
  # split; no clobber of $@) into repeated --files args. When the CSV is empty — the
  # detached SessionEnd spawn passes none — fall back to the session registry: read
  # .sessions[$SELF_SESSION_ID].touched_files and feed the *handoff.md entries, so the
  # scan sees the session's real handoff instead of empty stdin (R-25 close-time
  # enforcement was a silent 0-handoff.md no-op on the detached path). Only handoff.md
  # entries are passed. handoff-disposition-check.sh accepts repeated --files or
  # newline stdin.
  _hd_files=()
  if [[ -n "$TOUCHED_FILES_CSV" ]]; then
    _hd_oifs="$IFS"; IFS=','
    for _hd_f in $TOUCHED_FILES_CSV; do
      [[ -z "$_hd_f" ]] && continue
      _hd_files+=(--files "$_hd_f")
    done
    IFS="$_hd_oifs"
  elif [[ -n "$SELF_SESSION_ID" && -f "$SESSION_REGISTRY" ]] && command -v jq >/dev/null 2>&1; then
    while IFS= read -r _hd_f; do
      [[ -z "$_hd_f" ]] && continue
      case "$_hd_f" in
        *handoff.md) _hd_files+=(--files "$_hd_f") ;;
      esac
    done < <(jq -r --arg s "$SELF_SESSION_ID" \
      '.sessions[$s].touched_files // [] | .[]' "$SESSION_REGISTRY" 2>/dev/null)
  fi
  if [[ ${#_hd_files[@]} -gt 0 ]]; then
    run_capability handoff-disposition-check "${_hd_files[@]}"
  else
    run_capability handoff-disposition-check
  fi
  # T-4: maintain the episodic chronicle. Chained AFTER
  # handoff-disposition-check so the handoff/close-out block is already written —
  # the one-line-summary backfill harvests it. Read-mostly: pointer-metadata
  # refresh + 50KB rotation + placeholder backfill (advisory; no 5s hook
  # timeout, so the close-out-harvest work that the SessionEnd hook cannot do
  # runs here).
  run_capability chronicle-index
  # Append-before-re-derive ordering: append the just-finalized handoff's
  # newest block to the active spoke's handoff-chronicle.md FIRST — the thin
  # adaptor (binder-handoff-append-wrapper) drives the orphaned positional-arg
  # hooks/handoff-chronicle-append.sh under the run_capability wrapper. It fires
  # BEFORE plan-handoff-index's full re-derive (below), which de-dupes the appended
  # block idempotently (the re-derive owns the whole file; the append is absorbed).
  run_capability binder-handoff-append-wrapper --spoke "$active_spoke"
  # completed_at stamp + no-verdict soft-surface. The archival display view-filter
  # needs a per-plan completion date the manifest does not otherwise carry. Stamp
  # `completed_at` (date-only) ONLY on the plan(s) the closing session was anchored to
  # (the arm-pointer chain: $PLANS_DIR/.active-plan -> <plan>/.active-sp) when
  # that target has transitioned to `completed` without the field — TRANSITION-SCOPED,
  # never a whole-tree walk. A legacy `completed` manifest that is NOT the armed target
  # keeps falling back to `updated` (schema-documented). The SAME transition-scoped
  # block also marks `research_closed: true` on the armed target when it reaches a
  # TERMINAL status {completed, superseded} without the flag (the plan-research-declare
  # reader consumes it to stop ratifying undeclared research artifacts). Also
  # advisory-surface a just-completed plan carrying no harness_validated[] verdict-pass
  # (the receipt lives in that field, not a status). Block-and-log, atomic os.replace,
  # findings to the per-run sink; session-close stays advisory.
  #
  # THE CLOSE-TIME ORDERING GATE rides the SAME block, ahead of both stamps:
  # a terminal `manifest.status` over a task ledger that still carries NON-ADVANCED rows is
  # REFUSED — loudly (stderr + a `refused` line in the capability chain + a finding in the
  # per-run sink) — and the stamp does NOT proceed. The gate is minted here because the close
  # path is where a plan's terminal status is first OBSERVED against its own ledger, and
  # because this block is already the single writer of that manifest at close: the drift class
  # is a plan stamped `completed` whose tasks[] still says `pending`, after which every derived
  # surface (tasks.md re-render below, _backlog.md, the master sub_plans[] read-replica) faithfully
  # renders the contradiction. The candidate owner was checked, not assumed:
  # `184/14-session-close-orchestration-capstone` is `completed` with 17 tasks and none of them is
  # this gate (its T-1 REORDERS the close chain; it never refuses a terminal stamp), so the gate
  # was unowned rather than already-shipped. It is deliberately NOT a blocking exit — session-close
  # is advisory-exit-0 by contract (the ONLY carve-out is a present-but-non-exec required cap), so
  # loud-and-recorded plus a withheld write is the strongest refusal this chain's contract supports;
  # the operator advances (or cuts) the open rows and re-closes.
  if [[ "$TEST_MODE" == "true" ]]; then
    record_capability "completed-at-stamp" "stub" "test-mode"
  elif [[ "$DRY_RUN" == "true" ]]; then
    record_capability "completed-at-stamp" "dry-run" "would stamp completed_at on the armed plan if it reached completed"
  else
    _ca_plans_root="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
    # Refusal channel for the ordering gate. The block's stdout is the stamped-count capture
    # and its stderr is suppressed (python tracebacks stay out of the close), so each refusal
    # is written here as exactly ONE line and replayed below to stderr + the capability chain.
    _ca_refusals="${TMPDIR:-/tmp}/session-close-terminal-gate-$$.refusals"
    : > "$_ca_refusals"
    _ca_stamped="$(FINDINGS_OUTPUT="$RUN_FINDINGS_NDJSON" python3 - "$_ca_plans_root" "$_ca_refusals" 2>/dev/null <<'PY'
import json, os, sys, tempfile
from datetime import date

plans_root = sys.argv[1]
refusal_path = sys.argv[2] if len(sys.argv) > 2 else ""
today = os.environ.get("SESSION_CLOSE_TODAY") or date.today().isoformat()
sink = os.environ.get("FINDINGS_OUTPUT", "")

def emit(d):
    if not sink:
        return
    with open(sink, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(d, ensure_ascii=False) + "\n")

def refuse(line):
    """One refusal, one line (the capability-chain + stderr shapes are line-based)."""
    if not refusal_path:
        return
    with open(refusal_path, "a", encoding="utf-8") as fh:
        fh.write(" ".join(str(line).split()) + "\n")

# The terminal set is governance/plans-rules.json :: lifecycle.terminal_status
# {completed, superseded} — the same pair the research_closed stamp below already keys on.
TERMINAL_STATUS = ("completed", "superseded")

# The NON-ADVANCED task-status set. Derived from the ACTUAL task-status vocabulary of the corpus
# (2,560 rows over the live plan manifests), NOT invented: the open-state tokens are
# not-started / planned / pending / in-progress / proposed / blocked / needs-revision, plus an
# ABSENT-or-empty status (the single largest class — a row that never claimed a state).
# It is a CLOSED open-state list, and everything else is read as advanced, deliberately:
# the corpus also carries settled-but-free-form dispositions (done, cut, verified, complete,
# deferred, retired-supersession, absorbed-*, satisfied-by-construction, "completed (with a
# free-form note)"), and an ADVANCED-side allowlist would refuse every one of them. Free-form suffixes are
# normalized off the front token ("in-progress (T-7a slice closed)" -> in-progress), so a
# narrated open row is still caught while a narrated settled row is not.
NON_ADVANCED = frozenset((
    "", "null", "none",
    "not-started", "planned", "pending", "in-progress", "proposed",
    "blocked", "needs-revision",
))

def task_state(t):
    v = t.get("status")
    if v is None:
        return ""
    if not isinstance(v, str):
        v = str(v)
    return v.split("(")[0].strip().lower().replace("_", "-")

def open_rows(m):
    rows = []
    for t in (m.get("tasks") or []):
        if not isinstance(t, dict):
            continue
        st = task_state(t)
        if st in NON_ADVANCED:
            rows.append((str(t.get("id") or "?"), st or "null"))
    return rows

def read_pointer(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""

# Session-anchored (armed) plan target from the arm-pointer chain:
# $PLANS_DIR/.active-plan names the armed plan; <plan>/.active-sp names the armed sub
# (a dot value or an absent .active-sp means the plan root manifest itself). The stamp
# is scoped to that target ONLY -- the plan this session worked, and thus the one that
# could have transitioned to completed. No whole-tree walk over legacy completed
# manifests.
targets = []
plan = read_pointer(os.path.join(plans_root, ".active-plan"))
if plan and os.path.isdir(os.path.join(plans_root, plan)):
    plan_dir = os.path.join(plans_root, plan)
    targets.append(os.path.join(plan_dir, "manifest.json"))
    sp = read_pointer(os.path.join(plan_dir, ".active-sp"))
    if sp and sp != "." and os.path.isdir(os.path.join(plan_dir, sp)):
        targets.append(os.path.join(plan_dir, sp, "manifest.json"))

stamped = 0
for mpath in targets:
    if not os.path.isfile(mpath):
        continue
    try:
        with open(mpath, encoding="utf-8") as fh:
            m = json.load(fh)
    except Exception:
        continue
    if not isinstance(m, dict):
        continue
    status = m.get("status")
    slug = os.path.basename(os.path.dirname(mpath))
    # ---- the close-time ordering gate: no terminal stamp over an open ledger -------
    # Fires on OBSERVATION, ahead of either stamp: a terminal status over a ledger still
    # carrying open rows is refused whether or not this close is the one that would write
    # the fields, because the contradiction is the finding. `continue` is the refusal — the
    # manifest is not opened for write on this path at all (refuse-and-freeze, never
    # stamp-and-hope), matching the discipline tasks-render already applies below.
    if status in TERMINAL_STATUS:
        rows = open_rows(m)
        if rows:
            shown = ", ".join("%s:%s" % (i, s) for i, s in rows[:5])
            if len(rows) > 5:
                shown += ", +%d more" % (len(rows) - 5)
            refuse(
                "%s — manifest.status=%s over %d non-advanced task row(s) [%s]; "
                "REFUSING the completed_at/research_closed stamp (advance or cut the rows, then re-close)"
                % (slug, status, len(rows), shown)
            )
            emit({"finding": "terminal-stamp-over-open-ledger", "file": mpath, "plan_slug": slug,
                  "status": status, "open_task_count": len(rows),
                  "open_tasks": [{"id": i, "status": s} for i, s in rows],
                  "note": "terminal plan status over a non-advanced task ledger — close-time stamp REFUSED",
                  "detected_at": today})
            continue
    did_completed_at = False
    did_research_closed = False
    # completed_at: date-only, only on a `completed` armed target lacking the field.
    if status == "completed" and not m.get("completed_at"):
        m["completed_at"] = today
        did_completed_at = True
    # research_closed: mark the armed target as research-closed when it reaches a
    # TERMINAL status {completed, superseded} without the flag. Transition-scoped to the
    # armed target ONLY (never a whole-tree walk); the plan-research-declare reader
    # consumes the flag to stop ratifying undeclared research artifacts.
    if status in ("completed", "superseded") and not m.get("research_closed"):
        m["research_closed"] = True
        did_research_closed = True
    if not (did_completed_at or did_research_closed):
        continue
    d = os.path.dirname(mpath) or "."
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".manifest.", suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(m, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        os.replace(tmp, mpath)
    except Exception:
        if tmp and os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except Exception:
                pass
        continue
    # `slug` is already resolved above (the gate emits with it); no second derivation.
    if did_completed_at:
        stamped += 1
        emit({"finding": "completed-at-stamped", "file": mpath, "plan_slug": slug,
              "completed_at": today, "detected_at": today})
        hv = m.get("harness_validated") or []
        has_pass = any(isinstance(e, dict) and e.get("verdict") == "pass" for e in hv)
        if not has_pass:
            emit({"finding": "completed-no-harness-verdict", "file": mpath, "plan_slug": slug,
                  "note": "completed plan carries no harness_validated[] verdict-pass (advisory)",
                  "detected_at": today})
    if did_research_closed:
        emit({"finding": "research-closed-stamped", "file": mpath, "plan_slug": slug,
              "status": status, "detected_at": today})
print(stamped)
PY
)"
    # Replay the ordering gate's refusals LOUDLY: one stderr line + one `refused` line in the
    # capability chain per refused target. `refused` is a NON-error status by design — the
    # withheld stamp is a CORRECT outcome (the same disposition tasks-render's loud-skip gets
    # below), so it must not bump ERRORS_COUNT and must not turn the advisory close into a
    # failure. The finding already rode into the per-run sink, so it also lands in
    # findings-total and the close log's findings digest. The `ok` line still records the
    # stamped count afterwards, so a run that refused one target and stamped another reports both.
    if [[ -s "$_ca_refusals" ]]; then
      while IFS= read -r _ca_refusal; do
        [[ -n "$_ca_refusal" ]] || continue
        echo "session-close: REFUSED terminal stamp — $_ca_refusal" >&2
        record_capability "completed-at-stamp" "refused" "$_ca_refusal"
      done < "$_ca_refusals"
    fi
    rm -f "$_ca_refusals"
    record_capability "completed-at-stamp" "ok" "${_ca_stamped:-0} plan(s) stamped completed_at (armed target)"
  fi
  # Re-derive the tasks.md read-replica on the SAME armed target chain the stamps above
  # resolve. tasks.md is a manifest-derived replica whose sole sanctioned writer is
  # tasks-render (/R-37), and its only direct callers were the two SCAFFOLDERS
  # (new-plan.sh, promote-from-inbox.sh) — so between scaffold and close the manifest is
  # mutated many times and nothing re-derives the replica, and a plan could close with its
  # human-facing file still saying `planned` while manifest.tasks[] (the task-state SoT)
  # said `done`. This is the missing CLOSE-TIME transition and nothing more.
  #
  # SCOPE — TRANSITION-SCOPED to the armed target ONLY ($PLANS_DIR/.active-plan ->
  # <plan>/.active-sp, the identical chain read above), never a whole-tree walk and never a
  # `--check` sweep. Both rejected explicitly: a read-only --check over 320 plan dirs
  # reports 115 completed plans drift=true, 51 of them whitespace-only and the substantive
  # remainder dominated by RENDERER-FORMAT EVOLUTION (on a sampled completed plan
  # the diff is the renderer ADDING strikethrough and the entire per-task detail section the
  # on-disk file predates). Sweeping-and-re-rendering would rewrite 115 closed plans for
  # reasons unrelated to this defect, and a close-time --check sweep would emit ~104
  # format-evolution findings out of 115 — a finding stream that trains the reader to ignore
  # it. The residual-`planned` backfill is a SEPARATE live-corpus pass over 11 measured
  # plans (post-sentinel scaffold residue), owned elsewhere; this block never backfills.
  #
  # NO SECOND TRIGGER. The PostToolUse render trigger on a plan manifest.json write ALREADY
  # EXISTS (hooks/post-manifest-binder-refresh.sh), as does the task-done-marker lane
  # (hooks/tasks-md-autosync.sh); BOTH scope to dirname(the manifest just written). This
  # adds no trigger surface — it is the close-time transition those two lanes cannot cover,
  # and it inherits tasks-render's single-writer + atomic temp+rename discipline unchanged.
  #
  # REFUSAL TOLERANCE. tasks-render's emptiness guard and schema gate are LOUD-SKIPS
  # ("tasks-render: skipped <plan> — …", stderr, exit 1) that deliberately FREEZE the
  # replica rather than write-and-hope. That is a correct outcome, not a close failure, so
  # it is recorded as `skip` with the diagnostic folded in — never `error`. A genuine
  # failure still records `error` (advisory; the close's exit contract is unchanged).
  #
  # FINDINGS ROUTING. tasks-render emits `tasks-md-regenerated` on EVERY successful write,
  # including a byte-identical one. Folding that into $RUN_FINDINGS_NDJSON would put a
  # permanent >=1 floor under the findings-total 0-baseline this orchestrator maintains
  # (see the FINDINGS_DIGEST block below), so this call's findings go to a throwaway sink —
  # the same disposition the automatic hook lane already gives them.
  if [[ "$TEST_MODE" == "true" ]]; then
    record_capability "tasks-render" "stub" "test-mode"
  elif [[ "$DRY_RUN" == "true" ]]; then
    record_capability "tasks-render" "dry-run" "would re-render tasks.md on the armed plan target chain"
  else
    _tr_cap="$CAPS_DIR/tasks-render.sh"
    _tr_plans_root="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
    _tr_armed=""
    if [[ -r "$_tr_plans_root/.active-plan" ]]; then
      _tr_armed="$(tr -d '[:space:]' < "$_tr_plans_root/.active-plan" 2>/dev/null)"
    fi
    _tr_targets=""
    if [[ -n "$_tr_armed" && -d "$_tr_plans_root/$_tr_armed" ]]; then
      _tr_targets="$_tr_plans_root/$_tr_armed"
      _tr_sp=""
      if [[ -r "$_tr_plans_root/$_tr_armed/.active-sp" ]]; then
        _tr_sp="$(tr -d '[:space:]' < "$_tr_plans_root/$_tr_armed/.active-sp" 2>/dev/null)"
      fi
      if [[ -n "$_tr_sp" && "$_tr_sp" != "." && -d "$_tr_plans_root/$_tr_armed/$_tr_sp" ]]; then
        _tr_targets="$_tr_targets
$_tr_plans_root/$_tr_armed/$_tr_sp"
      fi
    fi
    if [[ ! -x "$_tr_cap" ]]; then
      # Same delivery-mode discipline run_capability applies: present-but-non-exec is a
      # shipped-wrong defect the gate must observe; genuinely absent is a plain skip.
      if [[ -e "$_tr_cap" ]]; then
        NONEXEC_REQUIRED_COUNT=$((NONEXEC_REQUIRED_COUNT + 1))
        record_capability "tasks-render" "error" "present-but-non-exec — capability body shipped NON-EXEC ($_tr_cap); cannot run (the dead-R-40/100644-delivery class)"
      else
        record_capability "tasks-render" "skip" "not-installed"
      fi
    elif [[ -z "$_tr_targets" ]]; then
      record_capability "tasks-render" "skip" "no armed plan target (.active-plan absent or unresolvable) — transition-scoped, nothing to re-derive"
    else
      _tr_sink="${TMPDIR:-/tmp}/session-close-tasks-render-$$.ndjson"
      _tr_err="${TMPDIR:-/tmp}/session-close-tasks-render-$$.err"
      while IFS= read -r _tr_dir; do
        [[ -n "$_tr_dir" ]] || continue
        _tr_slug="$(basename "$_tr_dir")"
        # Mirror the automatic lane's precondition: re-derive an EXISTING replica; never
        # mint a tasks.md for a plan that has none (that is the scaffolder's job).
        if [[ ! -f "$_tr_dir/tasks.md" ]]; then
          record_capability "tasks-render" "skip" "$_tr_slug — no tasks.md replica to re-derive"
          continue
        fi
        : > "$_tr_err"
        if FINDINGS_OUTPUT="$_tr_sink" "$_tr_cap" "$_tr_dir" >/dev/null 2>"$_tr_err"; then
          record_capability "tasks-render" "ok" "$_tr_slug — tasks.md re-derived from manifest.tasks[] (armed target)"
        else
          _tr_digest="$(head -1 "$_tr_err" 2>/dev/null | sed 's/^[[:space:]]*//')"
          case "$_tr_digest" in
            *"skipped"*|*"refusing to render"*|*"refusing to write"*)
              record_capability "tasks-render" "skip" "$_tr_slug — refused, replica frozen: $_tr_digest" ;;
            *)
              record_capability "tasks-render" "error" "$_tr_slug — ${_tr_digest:-exit non-zero}" ;;
          esac
        fi
      done < <(printf '%s\n' "$_tr_targets")
      rm -f "$_tr_sink" "$_tr_err"
    fi
  fi
  # Reconcile the master<->sub aggregation axis BEFORE rendering the master _index.md
  # rollup. drift-sweep --plans --fix runs ONLY the master<->sub aggregation axis and
  # repairs each master's sub_plans[] read-replica via subplan-aggregate (single-writer
  # invariant), reading manifests fresh from disk (no upstream dep). It precedes
  # plan-index so the rollup reflects the just-reconciled sub_plans[] in the SAME close
  # (no one-close lag). subplan-aggregate is idempotent, so a second consecutive close
  # leaves the master manifest byte-stable.
  run_capability drift-sweep --plans --fix
  # Regenerate the _backlog.md read-replica AFTER the reconciler so it renders from a
  # reconciled sub_plans[] (a still-stale replica would render orphan flags). On a clean
  # adopter install this close is the only trigger for the backlog renderer — no cron
  # owner ships behind it.
  run_capability backlog-index
  run_capability plan-index
  # ACTIVE-SPOKE-ONLY: wire the 3 binder
  # generators — today triggered by ZERO session events (orphaned). They re-derive
  # the active spoke's research-index.md / decision-log.md / handoff-chronicle.md
  # from fresh plan source. All three are run_capability-compatible (block-and-log,
  # exit 0, idempotent, atomic os.replace). plan-handoff-index's full re-derive
  # absorbs the append above idempotently.
  #
  # The SINGLE research
  # declaration surface. plan-research-declare DERIVES research_artifacts[] into each active-spoke
  # plan's OWN manifest from that plan's OWN _research/ (+ decisions/target-state/deliverables/),
  # routed to the OWNING spoke via the manifest project: key (true owner). It runs
  # BEFORE plan-research-index so the render reflects the just-declared artifacts. NEVER writes
  # _library (universal-only) and NEVER invokes library-scrub --apply (the manual PROMOTION path).
  # run_capability-compatible (block-and-log, exit 0, idempotent, single-writer, atomic os.replace;
  # never clobbers an author-curated entry). Inserted OUTSIDE the is_build_dogfood boundary below
  # (605-607, permanently adjudicated no-touch); the declare writer touches only plan manifests.
  run_capability plan-research-declare --spoke "$active_spoke"
  run_capability plan-research-index --spoke "$active_spoke"
  run_capability plan-decision-log   --spoke "$active_spoke"
  run_capability plan-handoff-index  --spoke "$active_spoke"
  # Card-after-generators ordering: re-derive the situating
  # card AFTER the 3 generators — the card reads their output (research/decision/
  # handoff-chronicle pointers + the latest handoff headline), so it MUST run after
  # them so the card the next SessionStart force-ingests (T-07) reflects the
  # just-closed session's state.
  run_capability project-context-situating --spoke "$active_spoke"
  # Work-side directory map: re-derive the active spoke's work CLAUDE.md "what lives
  # where" block FROM DISK so the work surface reflects this session's file changes.
  # Runs AFTER the binder card (card = binder surface, work-map = work surface; the
  # two are disjoint). Block-and-log + idempotent + writes ONLY the marker block in
  # $WORK_HOME/<spoke>/CLAUDE.md (leave-orphan skips a marker-less/absent CLAUDE.md).
  run_capability work-map-generate --spoke "$active_spoke"
  # Work-side folder indexes: mint/refresh the active spoke's deliverables/ +
  # reference/ _index.md FROM DISK so each work folder carries a current
  # contents-enum table after this session's file changes. Runs AFTER the work-map
  # (work-map = the spoke's directory map, work-index = the per-folder content
  # indexes; both are work-surface, disjoint from the binder card). Block-and-log +
  # idempotent + writes ONLY _index.md files under $WORK_HOME/<spoke>/.../{deliverables,
  # reference}/ (defensive skip for an absent spoke / target subfolder / marker-less index).
  run_capability work-index-maintain --spoke "$active_spoke"
  # sub 09 (G-LIFECYCLE) T-1: close-time plan-terminal-lag
  # SURFACE-AND-WALK. Emits a `plan-terminal-lag` finding when a plan is
  # non-terminal under a TERMINAL parent_plan master and PROMPTS the walk in its
  # report — it does NOT auto-close, never auto-stamps `verified` (the
  # dogfood-harness machine-gate is preserved), and touches no aggregation
  # (unchanged). Runs AFTER the binder card (@project-context-situating) and
  # adjacent to plan-parent-resolve. The lag scan reads plan+master manifests fresh
  # from disk, so it carries no read-replica dependency — the master<->sub
  # reconciler (drift-sweep --plans --fix) already ran above, before plan-index, and
  # this scan's position relative to it does not change its result.
  # Findings flow into the per-run sink via run_capability's FINDINGS_OUTPUT
  # wiring; the cap exits non-zero on findings (mirroring handoff-disposition-check)
  # while session-close stays advisory (run_capability records it and returns 0).
  run_capability plan-terminal-lag-check
  run_capability plan-parent-resolve
  # Chain the vault-health writers-* refreshers (R-44 _index regen).
  # writers-index-refresh -> Vault Writers/_index.md catalog;
  # writers-overlap-refresh -> _overlap-matrix.md. writers-health-audit is NOT
  # chained here — it is a findings-JSONL no-vault-write sweep (cron_block:daily,
  # registry-declared); its scheduled home is the registry's cron_block
  # declaration, not this close chain. The cron_block:daily declaration is
  # intact in capability-registry.json.
  run_capability writers-index-refresh
  run_capability writers-overlap-refresh
  # governance-parity-audit R-37 backstop. Split so the R-37 enforcement
  # backstop reaches adopters: the master-slot + file-type-contract-parity arms are
  # adopter-satisfiable (the governance dir resolver falls back to the live install's
  # governance/, which ships the composed master + the file-type contracts), so the
  # default audit fires at EVERY close. The --upgrade shadow-guard arm needs a
  # repo-only diff-context, so on the build box the audit runs --upgrade (base arms +
  # shadow walk); on an adopter it runs the base arms only.
  if is_build_dogfood; then
    run_capability governance-parity-audit --upgrade
  else
    run_capability governance-parity-audit
  fi
  # The registry/manifest meta-gates. Both declare the session-close-step-2 invocation
  # mode in capability-registry.json yet had no caller at close, so the meta-gate tier was
  # inert on an adopter. Honor the declared mode: invoke each exactly ONCE here.
  # capability-registry-parity walks the registry <-> on-disk capability-body parity;
  # librarian-manifest-validate checks the librarian manifest shape. Both are advisory
  # (findings route to the per-run sink; session-close stays exit 0). Each also carries a
  # monday rolling cron_block, but it is DELIBERATELY not enumerated in the sweep_due()
  # cadence roster below — the step-2 mode is its single fire, so there is no double-fire.
  run_capability capability-registry-parity
  run_capability librarian-manifest-validate
  # The reach-verified coverage guard: a standing, report-only regression guard
  # over the sentinel corpus. It self-gates on corpus presence (a no-op when the
  # corpus is absent — every adopter install), so it needs NO is_build_dogfood
  # gate and is placed OUTSIDE the boundary above (never touches it). Findings
  # flow into the per-run sink via run_capability's FINDINGS_OUTPUT wiring; the
  # cap exits 0 (report-only), so session-close stays advisory.
  run_capability coverage-guard
}

# ---- Step 2b: rename cascade -----------------------------------------------
# Detect renames in the last 24h across VAULT + PLANS repos; cascade inbound
# wikilinks (dry-run only — user runs --apply separately). Idempotent:
# re-running without new commits produces zero new findings. The rename-history
# append step is retired from this chain — its canonical store moved and no
# populator ships; that standalone history capability stays available ad-hoc /
# via librarian-full.
step2b_rename_cascade() {
  if [[ "$TEST_MODE" == "true" ]]; then
    record_capability "rename-detect" "stub" "test-mode"
    record_capability "rename-cascade" "stub" "test-mode"
    return 0
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    record_capability "rename-cascade-pipeline" "dry-run" "would invoke rename-detect | rename-cascade"
    return 0
  fi
  local rd="$CAPS_DIR/rename-detect.sh"
  local rc="$CAPS_DIR/rename-cascade.sh"
  if [[ ! -x "$rd" || ! -x "$rc" ]]; then
    record_capability "rename-cascade-pipeline" "skip" "not-installed"
    return 0
  fi
  # Capture the rename-record NDJSON once, feed the cascade consumer.
  # Set FINDINGS_OUTPUT in the capability environment so any findings these caps
  # emit land in the shared per-run sink. rename-detect's STDOUT is its
  # rename-record data pipeline (captured to $tmp_nd, fed to the cascade) — NOT
  # findings — so it must stay on stdout; setting FINDINGS_OUTPUT routes its
  # findings (if any) to the sink and keeps the data channel clean.
  local tmp_nd="${TMPDIR:-/tmp}/session-close-rename-$$.ndjson"
  # --persist-history: each detected rename is ALSO appended (deduped) to the
  # librarian-manifest rename_history[] so a move detected at THIS close stays
  # repairable after the 24h git window closes (rename-cascade --from-history).
  if FINDINGS_OUTPUT="$RUN_FINDINGS_NDJSON" "$rd" --since "24 hours ago" --persist-history > "$tmp_nd" 2>/dev/null; then
    record_capability "rename-detect" "ok" "$(wc -l < "$tmp_nd" | tr -d ' ') record(s)"
  else
    record_capability "rename-detect" "error" "exit $?"
    rm -f "$tmp_nd"
    return 0
  fi
  if [[ -s "$tmp_nd" ]]; then
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

# ---- Step 2d: trinity-drift-detect (trinity-status axis) --------------------
# After 2c pending-reconciliation, walk all plan dirs for spec/manifest/tasks-
# ledger (artifact/ledger) drift. Advisory. Uses the shared find-emission
# contract (FINDINGS_OUTPUT honored). Scoped runs still invoke — detection is
# cheap + read-only. Restricted to `--axis trinity-status`: the master<->sub
# aggregation axis is already covered by drift-sweep --plans (--axis master-sub),
# so the two close call-sites emit DISJOINT axes — 0 duplication, both covered.
step2d_trinity_drift() {
  run_capability trinity-drift-detect --axis trinity-status
}

# ---- Step 2e: cadence-gated maintenance roster -----------------------------
# The reconciler / auditor / vault-maintenance / cross-project-hygiene capabilities that
# declare a cron_block cadence in capability-registry.json have no background scheduler on
# an adopter install — this detached close is their deterministic trigger. sweep_due()
# (hooks/lib/cadence.sh) fires each one only when its rolling window has elapsed (a cold
# ledger fires once, then the window governs), stamping a durable per-capability ledger so
# an in-window re-close skips it. The roster is an EXPLICIT per-capability list, not a blind
# registry enumeration: the two session-close-step-2 meta-gates and the dormant-until-opt-in
# audits are wired (or gated) elsewhere and must not double-fire here. Findings flow into the
# per-run sink and the triage digest. index-maintain runs dry-run-first (no destructive
# re-derive on a clean adopter); the two memory caps sweep every project memory dir
# (--all-projects); rules-hygiene runs headless (its deterministic drift classes emit while
# the judgment class stays interactive-gated).
step2e_cadence_roster() {
  if [[ "$TEST_MODE" == "true" ]]; then
    record_capability "cadence-roster" "stub" "test-mode"
    return 0
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    record_capability "cadence-roster" "dry-run" "would consult sweep_due() for the schedulable maintenance roster"
    return 0
  fi
  [[ "$CADENCE_AVAILABLE" == "1" ]] || return 0
  # Reconciler + auditor tier.
  sweep_due index-maintain        >/dev/null 2>&1 && run_capability index-maintain --dry-run
  sweep_due rules-index           >/dev/null 2>&1 && run_capability rules-index
  sweep_due library-index         >/dev/null 2>&1 && run_capability library-index
  sweep_due skill-parity          >/dev/null 2>&1 && run_capability skill-parity
  sweep_due waiver-audit          >/dev/null 2>&1 && run_capability waiver-audit
  sweep_due tag-coverage-audit    >/dev/null 2>&1 && run_capability tag-coverage-audit
  # Mechanical vault-maintenance tier.
  sweep_due wikilink-repair       >/dev/null 2>&1 && run_capability wikilink-repair
  sweep_due log-archive           >/dev/null 2>&1 && run_capability log-archive
  sweep_due log-subtype-canonical >/dev/null 2>&1 && run_capability log-subtype-canonical
  sweep_due library-log-rotate    >/dev/null 2>&1 && run_capability library-log-rotate
  # Cross-project hygiene tier.
  sweep_due memory-hygiene        >/dev/null 2>&1 && run_capability memory-hygiene --all-projects
  sweep_due memory-staleness      >/dev/null 2>&1 && run_capability memory-staleness --all-projects
  sweep_due rules-hygiene         >/dev/null 2>&1 && run_capability rules-hygiene
}

# ---- (former Step 3: sync-check / Step 4c: architect-triage) ---------------
# (T-01 + T-04 fix-tail): sync-check and architect-triage are
# -CUT capabilities (bodies absent + unregistered). Their run_capability
# calls were removed (T-01), the emptied step functions were dropped, and their
# orchestration-tail invocations struck (T-04 fix-tail), so the chain no longer
# carries dead "skip: not-installed" references. The registry session-close
# dependencies[] strip for the same 3 caps is/WS-G (regen, never hand-edit).

# ---- Step 5 (backup): REMOVED — T-1 -------------------------------
# The close chain no longer runs backup, so the orchestrator is structurally
# commit-free (no git add/commit/push reachable). backup remains the standalone
# /librarian backup capability (SECURITY.md:11 "never automatic"); the MANUAL
# /librarian session-close OFFERS it, the detached auto path never does.

# ---- Step 6: write aggregated log ------------------------------------------

# Idempotency: idempotent_guard is defined (and FIRST evaluated) at chain start —
# see the early-exit above "orchestration state". write_log re-checks it here as
# the belt: the start-time check is what dedupes a back-to-back re-invocation (the
# chain's own runtime exceeds the 60s window, so an at-write-only check evaluated
# minutes after the first receipt could never fire); the write-time check keeps a
# slow overlapping pair from double-writing.

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
    echo "- Findings: $FINDINGS_COUNT"
    echo "- Scope: $SCOPE"
    echo ""
    if [[ -n "$FINDINGS_DIGEST" ]]; then
      echo "## Findings Digest (top categories)"
      echo ""
      echo "$FINDINGS_DIGEST"
      echo ""
    fi
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
step2e_cadence_roster

# Count the per-run findings sink AFTER the capability chain and BEFORE write_log emits
# `findings-total:`. FINDINGS_COUNT reflects the REAL count of findings every chained
# capability routed to RUN_FINDINGS_NDJSON. Clean vault is 0 (empty sink); a vault with
# drift is the non-zero line count.
#
# Detect-tier digest: the upstream detect-tier precision fixes made findings-total a real
# 0-baseline (a clean adopter close is 0 — no false-positive noise floor to threshold on),
# so the sink is a trustworthy signal rather than a large floor to count-then-discard.
# Summarize it into a BOUNDED top-N-by-category triage digest rendered in the close log, so
# a high-finding close is triaged (top categories + their counts) instead of flooding the
# log or being silently dropped. No threshold gate — the digest surfaces whatever the run
# produced, bounded to a fixed cap of rendered lines.
FINDINGS_DIGEST=""
if [[ -f "$RUN_FINDINGS_NDJSON" ]]; then
  FINDINGS_COUNT=$(wc -l < "$RUN_FINDINGS_NDJSON" | tr -d ' ')
  if [[ "$FINDINGS_COUNT" -gt 0 ]] && command -v python3 >/dev/null 2>&1; then
    FINDINGS_DIGEST="$(python3 - "$RUN_FINDINGS_NDJSON" 2>/dev/null <<'PY'
import json, sys
from collections import Counter
path = sys.argv[1]
TOP_N = 10
cats = Counter()
with open(path, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            d = json.loads(line)
        except Exception:
            cats["unparseable"] += 1
            continue
        cat = d.get("finding") or d.get("category") or "uncategorized"
        cats[str(cat)] += 1
for cat, n in cats.most_common(TOP_N):
    print("- %s: %d" % (cat, n))
extra = len(cats) - TOP_N
if extra > 0:
    print("- ... and %d more categor%s (top %d shown)" % (extra, "y" if extra == 1 else "ies", TOP_N))
PY
)"
  fi
fi

write_log

rm -f "$RUN_FINDINGS_NDJSON"
# Tidy the dead-switch throwaway plans root, if the corpus-isolation guard created one.
[[ -n "${_SC_DEAD_PLANS:-}" ]] && rm -rf "$_SC_DEAD_PLANS" 2>/dev/null

# T-4 (B-1 #3): session-close stays advisory (Exit 0 always) for runtime
# capability errors and benign environmental degradation — but a REQUIRED cap
# whose body is PRESENT ON DISK yet NON-EXEC is a delivery-mode defect the gate
# MUST observe (the dead-R-40 placement-validate class that shipped GREEN in
# public v1.1.1). For that class ONLY, exit non-zero so the orchestrator /
# clean-room smoke cannot read a non-exec required cap as skip-as-success.
if [[ "$NONEXEC_REQUIRED_COUNT" -gt 0 ]]; then
  echo "session-close: $NONEXEC_REQUIRED_COUNT required capability body(ies) present-but-NON-EXEC — exiting non-zero (delivery-mode defect, not a runtime advisory failure)" >&2
  exit 1
fi
exit 0
