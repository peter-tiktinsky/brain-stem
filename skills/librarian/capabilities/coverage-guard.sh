#!/bin/bash
# coverage-guard — the reach-verified coverage guard (standing regression guard).
#
# Reads the always-present sentinel/canary corpus + its carried allowlist files
# and asserts TWO invariants over the real corpus:
#
#   (1) corpus GREEN  — every declared sentinel's fixture EXISTS on disk, is
#       FIRED in the install-verify orchestrator (registered — cannot silently
#       lose a test), and CATCHES its planted defect (the fixture exits 0). This
#       is a REACH-VERIFIED check: it proves each managed surface's sentinel is
#       caught by >=1 real capability emit, not merely declared.
#   (2) allowlist EMPTY — the main corpus `_parity_pending` AND every carried
#       sub-file's `_parity_pending` are `[]` (no surface deferred its drain).
#
# It is NOT a declaration-only zero-owner / self-attestation check (a check that
# reads a covers list and trusts it green-passes even when a real defect escapes).
# Reach is proven by running the corpus, never by a declaration.
#
# Output contract
#   Report-only: emits coverage-guard findings via hooks/lib/findings.sh
#   (block-and-log). A non-empty allowlist or an escaped sentinel (fixture
#   missing / not fired / RED) emits a finding — NEVER a DENY. Exit is 0 always
#   (a non-zero finding count does not change the exit); exit 2 only on an
#   unknown flag.
#   Self-parity: writes a scan-summary subtree to the librarian manifest
#   (drift_findings.coverage_guard) via manifest_set, so the declared
#   writes_manifest_subtree is a real write, not a fiction.
#
# Adopter-degrade
#   The sentinel corpus is test infrastructure and is not present on an adopter
#   install. When the corpus is absent, this is a block-and-log no-op (exit 0):
#   it records a no-op scan summary and returns without findings.
#
# Usage
#   coverage-guard.sh            # check (default)
#   coverage-guard.sh --check    # explicit
#   coverage-guard.sh --dry-run  # summary to stdout, no findings, no manifest write
#
# Env overrides (testing)
#   COVERAGE_GUARD_CORPUS   absolute path to the sentinel corpus JSON (overrides the
#                           default resolution below)
#   FOUNDATION_REPO         source-repo root; when unset the repo root is derived
#                           from this script's own location (no build-path hardcode)
#   FINDINGS_OUTPUT         append findings here instead of stdout
#   MANIFEST_PATH           relocate the librarian manifest (manifest.sh honors it)
#
# Bash 3.2 clean per R-23; argv-based python3 per R-24. block-and-log per the
# librarian failure-mode contract.

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- finding + manifest helpers (CLAUDE_HOME-first, dev-tree fallback) ---------
# shellcheck source=/dev/null
source "$CLAUDE_HOME_RES/hooks/lib/findings.sh" 2>/dev/null \
  || source "$(cd "$SCRIPT_DIR/../../.." && pwd)/hooks/lib/findings.sh"
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/manifest.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/manifest.sh"; } \
  || source "$(cd "$SCRIPT_DIR/../../.." && pwd)/hooks/lib/manifest.sh" 2>/dev/null || true

MODE="check"
while [ $# -gt 0 ]; do
  case "$1" in
    --check)   MODE="check"; shift ;;
    --dry-run) MODE="dry-run"; shift ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "coverage-guard: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# Resolve the sentinel corpus: an explicit override wins; else $FOUNDATION_REPO
# when set; else derive the repo root from this script's own location
# (.../skills/librarian/capabilities -> repo root). On an adopter install that
# derived root has no internal/tests/, so the corpus is absent and the guard is a
# clean no-op — no build-box path is ever hardcoded (portability-clean).
if [ -n "${COVERAGE_GUARD_CORPUS:-}" ]; then
  CORPUS="$COVERAGE_GUARD_CORPUS"
elif [ -n "${FOUNDATION_REPO:-}" ]; then
  CORPUS="$FOUNDATION_REPO/internal/tests/_sentinel-corpus.json"
else
  CORPUS="$(cd "$SCRIPT_DIR/../../.." 2>/dev/null && pwd)/internal/tests/_sentinel-corpus.json"
fi

# _cg_manifest_write <corpus> <total> <escaped> <scopes> <nonempty> <findings>
# C5 self-parity: record a real scan-summary under drift_findings.coverage_guard.
# Best-effort — a state-tier that cannot be resolved (adopter, no python3) must
# not crash the report-only guard.
_cg_manifest_write() {
  [ "$MODE" = "dry-run" ] && return 0
  command -v python3 >/dev/null 2>&1 || return 0
  command -v manifest_set >/dev/null 2>&1 || return 0
  local _now summary
  _now="$(manifest_iso_now 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S)"
  summary="$(python3 - "$_now" "$1" "$2" "$3" "$4" "$5" "$6" <<'PY' 2>/dev/null
import json, sys
print(json.dumps({
    "last_scan": sys.argv[1],
    "corpus": sys.argv[2],
    "sentinels_total": int(sys.argv[3]),
    "sentinels_escaped": int(sys.argv[4]),
    "allowlist_scopes_checked": int(sys.argv[5]),
    "allowlist_nonempty": int(sys.argv[6]),
    "findings": int(sys.argv[7]),
}))
PY
)"
  [ -n "$summary" ] || return 0
  manifest_set ".drift_findings.coverage_guard" "$summary" 2>/dev/null || true
}

# --- adopter-degrade: corpus absent -> block-and-log no-op, exit 0 -------------
if [ ! -f "$CORPUS" ]; then
  if [ "$MODE" != "dry-run" ]; then
    emit_finding "coverage-guard-corpus-absent" "$CORPUS" \
      "level" "info" \
      "detail" "sentinel corpus not present (test infrastructure, not shipped) — coverage-guard is a no-op on this install"
  fi
  _cg_manifest_write "$CORPUS" 0 0 0 0 0
  echo "## Coverage Guard (no-op: corpus absent)"
  echo ""
  echo "- corpus not found: $CORPUS"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  if [ "$MODE" != "dry-run" ]; then
    emit_finding "coverage-guard-degraded" "$CORPUS" \
      "level" "info" "detail" "jq unavailable — coverage-guard cannot parse the corpus; no-op"
  fi
  echo "## Coverage Guard (no-op: jq unavailable)"
  exit 0
fi

if ! jq empty "$CORPUS" >/dev/null 2>&1; then
  [ "$MODE" != "dry-run" ] && emit_finding "coverage-guard-corpus-invalid" "$CORPUS" "level" "error" "detail" "jq parse failed"
  echo "## Coverage Guard (1 finding: corpus does not parse)"
  echo "- coverage-guard-corpus-invalid: $CORPUS"
  _cg_manifest_write "$CORPUS" 0 0 0 0 1
  exit 0
fi

TESTS_DIR="$(cd "$(dirname "$CORPUS")" && pwd)"
REPO="$(cd "$(dirname "$CORPUS")/../.." && pwd)"
ORCH="$TESTS_DIR/install-verify-orchestrator.sh"

SENTINELS_TOTAL=0
SENTINELS_ESCAPED=0
ALLOWLIST_SCOPES=0
ALLOWLIST_NONEMPTY=0
FINDINGS_N=0
REPORT=""

# === (1) corpus GREEN — every sentinel's fixture EXISTS + FIRED + CATCHES ======
# The fixture is invoked with stdin redirected from /dev/null so a fixture that
# reads stdin cannot drain the enumerating stream (the reach loop must reach
# EVERY sentinel, not truncate at the first stdin-reader).
while IFS=$'\t' read -r sid fx; do
  [ -n "$fx" ] || continue
  SENTINELS_TOTAL=$((SENTINELS_TOTAL + 1))
  bn="${fx##*/}"
  fpath="$REPO/$fx"
  if [ ! -f "$fpath" ]; then
    SENTINELS_ESCAPED=$((SENTINELS_ESCAPED + 1)); FINDINGS_N=$((FINDINGS_N + 1))
    [ "$MODE" != "dry-run" ] && emit_finding "coverage-guard-sentinel-escaped" "$fx" \
      "level" "error" "sentinel_id" "$sid" "reason" "fixture-missing"
    REPORT="${REPORT}- coverage-guard-sentinel-escaped: id=$sid $bn (fixture missing)"$'\n'
    continue
  fi
  if [ -f "$ORCH" ] && ! grep -Eq "fire \"[^\"]+\" +\"$bn\"" "$ORCH"; then
    SENTINELS_ESCAPED=$((SENTINELS_ESCAPED + 1)); FINDINGS_N=$((FINDINGS_N + 1))
    [ "$MODE" != "dry-run" ] && emit_finding "coverage-guard-sentinel-escaped" "$fx" \
      "level" "error" "sentinel_id" "$sid" "reason" "not-fired-in-orchestrator"
    REPORT="${REPORT}- coverage-guard-sentinel-escaped: id=$sid $bn (not fired in orchestrator)"$'\n'
    continue
  fi
  # Invoke each fixture in a CLEAN env (env -i + a curated minimal passthrough) so
  # the caller's environment cannot defeat the fixture's own isolation. This guard
  # sources hooks/lib/paths.sh (via manifest.sh), which EXPORTS the runtime path
  # vars (VAULT_ROOT / PLANS_DIR / WORK_HOME / CLAUDE_GIT_REPO / CLAUDE_STATE_ROOT
  # ...); a session-close invocation adds FINDINGS_OUTPUT + HOOKS_STATE. Leaking
  # any of those into a fixture points it at live roots and breaks the very
  # isolation the fixture builds — so the fixtures must run from the same clean env
  # the orchestrator invokes them in. Each gets its OWN fresh runtime-state jail;
  # stdin from /dev/null so a stdin-reading fixture cannot drain the enumeration.
  _cg_hs="$(mktemp -d 2>/dev/null)"
  if env -i \
       HOME="${HOME:-}" PATH="${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
       TMPDIR="${TMPDIR:-/tmp}" LANG="${LANG:-en_US.UTF-8}" \
       USER="${USER:-}" LOGNAME="${LOGNAME:-}" \
       FOUNDATION_REPO="$REPO" HOOKS_STATE_OVERRIDE="$_cg_hs" \
       CLAUDE_HOME="$_cg_hs/no-claude-home" \
       bash "$fpath" >/dev/null 2>&1 </dev/null; then
    rm -rf "$_cg_hs"
  else
    rm -rf "$_cg_hs"
    SENTINELS_ESCAPED=$((SENTINELS_ESCAPED + 1)); FINDINGS_N=$((FINDINGS_N + 1))
    [ "$MODE" != "dry-run" ] && emit_finding "coverage-guard-sentinel-escaped" "$fx" \
      "level" "error" "sentinel_id" "$sid" "reason" "fixture-red"
    REPORT="${REPORT}- coverage-guard-sentinel-escaped: id=$sid $bn (fixture RED — planted defect not caught)"$'\n'
  fi
done < <(jq -r '.sentinels[] | [(.id|tostring), .fixture] | @tsv' "$CORPUS")

# === (2) allowlist EMPTY — main corpus + every carried sub file ================
ALLOWLIST_SCOPES=$((ALLOWLIST_SCOPES + 1))
MAIN_PP="$(jq -r '._parity_pending | length' "$CORPUS" 2>/dev/null || echo -1)"
if [ "$MAIN_PP" != "0" ]; then
  ALLOWLIST_NONEMPTY=$((ALLOWLIST_NONEMPTY + 1)); FINDINGS_N=$((FINDINGS_N + 1))
  [ "$MODE" != "dry-run" ] && emit_finding "coverage-guard-allowlist-nonempty" "$CORPUS" \
    "level" "error" "scope" "main" "pending" "$MAIN_PP"
  REPORT="${REPORT}- coverage-guard-allowlist-nonempty: scope=main pending=$MAIN_PP"$'\n'
fi

while IFS=$'\t' read -r ckey cref; do
  [ -n "$ckey" ] || continue
  ALLOWLIST_SCOPES=$((ALLOWLIST_SCOPES + 1))
  cpath="$REPO/$cref"
  if [ ! -f "$cpath" ]; then
    FINDINGS_N=$((FINDINGS_N + 1))
    [ "$MODE" != "dry-run" ] && emit_finding "coverage-guard-carried-unresolved" "$cref" \
      "level" "error" "scope" "$ckey" "detail" "carried allowlist file declared but absent"
    REPORT="${REPORT}- coverage-guard-carried-unresolved: scope=$ckey $cref (declared, absent)"$'\n'
    continue
  fi
  cpp="$(jq -r '._parity_pending | length' "$cpath" 2>/dev/null || echo -1)"
  if [ "$cpp" != "0" ]; then
    ALLOWLIST_NONEMPTY=$((ALLOWLIST_NONEMPTY + 1)); FINDINGS_N=$((FINDINGS_N + 1))
    [ "$MODE" != "dry-run" ] && emit_finding "coverage-guard-allowlist-nonempty" "$cpath" \
      "level" "error" "scope" "$ckey" "pending" "$cpp"
    REPORT="${REPORT}- coverage-guard-allowlist-nonempty: scope=$ckey pending=$cpp"$'\n'
  fi
done < <(jq -r '(._carried_forward // {}) | to_entries[] | [.key, .value] | @tsv' "$CORPUS")

# === self-parity manifest write + report ======================================
_cg_manifest_write "$CORPUS" "$SENTINELS_TOTAL" "$SENTINELS_ESCAPED" "$ALLOWLIST_SCOPES" "$ALLOWLIST_NONEMPTY" "$FINDINGS_N"

printf '## Coverage Guard (%d finding%s: sentinels=%d escaped=%d allowlist-scopes=%d allowlist-nonempty=%d)\n\n' \
  "$FINDINGS_N" "$([ "$FINDINGS_N" = "1" ] && echo '' || echo 's')" \
  "$SENTINELS_TOTAL" "$SENTINELS_ESCAPED" "$ALLOWLIST_SCOPES" "$ALLOWLIST_NONEMPTY"
if [ -n "$REPORT" ]; then
  printf '%s' "$REPORT"
else
  echo "- corpus GREEN + allowlist empty (no coverage regression)."
fi
exit 0
