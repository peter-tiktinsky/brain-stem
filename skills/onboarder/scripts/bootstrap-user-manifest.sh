#!/usr/bin/env bash
# skills/onboarder/scripts/bootstrap-user-manifest.sh — Tier-2 slim manifest writer.
#
# Uses the atomic-write + validate + audit-log + rollback discipline, reduced to
# emit user-manifest.json ONLY. The other three writers (plans-schema /
# vault-schema / orchestration) and the memory-seed surface are Tier-3 and are
# not on the GA path.
#
# OUTPUT CONTRACT (R-43):
#   File written (atomic tmp+rename):
#     1. $CLAUDE_HOME/user-manifest.json   (slim Tier-2 instance, schema 2.0.0)
#   Audit log (append-only JSONL):
#     $CLAUDE_HOME/onboarding/audit/bootstrap-user-manifest.jsonl
#       Records carry STRUCTURAL METADATA ONLY (run_id, ts, section ids,
#       manifest top-level keys, status) — never user-provided strings, per
#       the reference-leak floor.
#   Schema-type: $CLAUDE_HOME/schemas/user-manifest-schema.json (Draft-07).
#   Pre-write validation: validate the merged instance against the schema.
#     Validator priority: python3 jsonschema (Draft7) -> ajv -> jq structural
#     (JSON parses + top-level required[] keys present).
#   Failure mode: BLOCK AND LOG. Any merge/validate/IO failure rolls back the
#     run tmp, appends a {status: BOOTSTRAP_FAILED} terminator, exits non-zero.
#     The live target is never partially written (atomic rename semantics).
#
# INPUT CONTRACT:
#   Reads slim per-section fragments from $INPUTS_DIR:
#     user-fragment-A.json   (Section A — deterministic discovery; required)
#     user-fragment-B.json   (Section B' — role/org + prose; optional)
#   Each fragment shape: { "section_id": "<A|B>", "populated": { <nested
#   user-manifest object slice> } }. The writer deep-merges the .populated
#   objects (jq recursive object merge), then injects system fields.
#   Section A is required (carries identity.name); B is optional (a
#   voice-optional interview may skip the prose section). Section C was cut
#   (clusters defer to the runtime propose-and-validate folder flow).
#
# USAGE:
#   bootstrap-user-manifest.sh [--force] [--dry-run]
#                              [--inputs-dir DIR] [--schema PATH]
#                              [--out PATH] [--audit-log PATH]
#
#   --force        overwrite a differing live target (default: write .new + diff, exit 2)
#   --dry-run      emit unified diff (current vs would-write); ZERO live mutations
#   --inputs-dir   where user-fragment-{A,B,C}.json live
#                  (default: $CLAUDE_HOME/onboarding)
#   --schema       user-manifest-schema.json path
#                  (default: $CLAUDE_HOME/schemas/user-manifest-schema.json)
#   --out          live user-manifest.json target
#                  (default: $CLAUDE_HOME/user-manifest.json)
#   --audit-log    JSONL audit destination
#                  (default: $CLAUDE_HOME/onboarding/audit/bootstrap-user-manifest.jsonl)
#
# CONSTRAINTS (R-23): bash 3.2.57 — no `declare -A`, no `mapfile`, no `${var,,}`.
#   jq required on PATH; python3/ajv optional (jq structural fallback).
#
# Exit codes:
#   0   success | dry-run | skip-identical
#   2   bad invocation / missing dependency / target differs without --force
#   1   BOOTSTRAP_FAILED (merge/validate/IO; rolled back + logged)
#
set -u
LC_ALL=C

diag() { printf 'bootstrap-user-manifest FAIL: %s\n' "$1" >&2; }
info() { printf 'bootstrap-user-manifest: %s\n' "$1" >&2; }

# --- source paths.sh if present (post-install runtime) ---
PATHS_SH="${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
if [ -r "$PATHS_SH" ]; then
  # shellcheck source=/dev/null
  . "$PATHS_SH"
fi

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"

# --- defaults + arg parse ---
FORCE=0
DRY_RUN=0
INPUTS_DIR="$CLAUDE_HOME/onboarding"
SCHEMA="$CLAUDE_HOME/schemas/user-manifest-schema.json"
OUT="$CLAUDE_HOME/user-manifest.json"
AUDIT_LOG="$CLAUDE_HOME/onboarding/audit/bootstrap-user-manifest.jsonl"

while [ $# -gt 0 ]; do
  case "$1" in
    --force)      FORCE=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --inputs-dir) INPUTS_DIR="$2"; shift 2 ;;
    --schema)     SCHEMA="$2"; shift 2 ;;
    --out)        OUT="$2"; shift 2 ;;
    --audit-log)  AUDIT_LOG="$2"; shift 2 ;;
    -h|--help)    sed -n '2,60p' "$0"; exit 0 ;;
    *)            diag "unknown arg: $1"; exit 2 ;;
  esac
done

# --- preflight ---
command -v jq >/dev/null 2>&1 || { diag "jq not on PATH"; exit 2; }
[ -d "$INPUTS_DIR" ] || { diag "inputs dir not found: $INPUTS_DIR"; exit 2; }
[ -f "$SCHEMA" ]     || { diag "schema not found: $SCHEMA"; exit 2; }

# --- run constants ---
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TMPDIR_RUN="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-user-manifest.XXXXXX")"
trap 'rm -rf "$TMPDIR_RUN" 2>/dev/null' EXIT

# --- audit helpers (structural metadata only; skipped under --dry-run) ---
[ "$DRY_RUN" = "1" ] || mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null

audit_event() {
  # $1=event $2=msg(structural) [$3=json-extra]
  [ "$DRY_RUN" = "1" ] && return 0
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg run "$RUN_ID" \
    --arg ev "$1" --arg msg "$2" --argjson extra "${3:-null}" \
    '{ts:$ts, run_id:$run, event:$ev, message:$msg} + (if $extra == null then {} else $extra end)' \
    >> "$AUDIT_LOG" 2>/dev/null || true
}

fail() {
  rm -rf "$TMPDIR_RUN" 2>/dev/null
  audit_event "BOOTSTRAP_FAILED" "${1:-unspecified}"
  diag "BOOTSTRAP_FAILED: ${1:-unspecified}"
  exit 1
}

# --- validators ---
validate_instance() {
  # $1=instance $2=schema. 0 pass, non-zero fail.
  if command -v python3 >/dev/null 2>&1 && python3 -c "import jsonschema" 2>/dev/null; then
    python3 - "$2" "$1" <<'PY' 2>&1
import json, sys
from jsonschema import Draft7Validator
schema = json.load(open(sys.argv[1]))
inst = json.load(open(sys.argv[2]))
errs = sorted(Draft7Validator(schema).iter_errors(inst), key=lambda e: e.path)
if errs:
    for e in errs:
        loc = "/".join(str(p) for p in e.path) or "<root>"
        print("schema: %s: %s" % (loc, e.message), file=sys.stderr)
    sys.exit(1)
PY
    return $?
  fi
  if command -v ajv >/dev/null 2>&1; then
    ajv validate -s "$2" -d "$1" --strict=false >/dev/null 2>&1
    return $?
  fi
  # jq structural fallback: parses + top-level required[] present.
  jq -e . "$1" >/dev/null 2>&1 || return 1
  local req k
  req="$(jq -r '.required[]? // empty' "$2" 2>/dev/null)"
  for k in $req; do
    jq -e --arg k "$k" 'has($k)' "$1" >/dev/null 2>&1 || {
      diag "structural: instance missing required key: $k"; return 1; }
  done
  return 0
}

# --- 1. collect + validate fragments ---
FRAG_A="$INPUTS_DIR/user-fragment-A.json"
[ -f "$FRAG_A" ] || fail "missing required Section A fragment: $FRAG_A"

SECTIONS_MERGED=""
MERGE_INPUTS=""
for s in A B; do
  f="$INPUTS_DIR/user-fragment-${s}.json"
  [ -f "$f" ] || continue
  jq -e . "$f" >/dev/null 2>&1 || fail "fragment $f: invalid JSON"
  sid="$(jq -r '.section_id // empty' "$f")"
  [ "$sid" = "$s" ] || fail "fragment $f: section_id='$sid' (expected '$s')"
  jq -e '.populated | type == "object"' "$f" >/dev/null 2>&1 \
    || fail "fragment $f: '.populated' must be an object"
  MERGE_INPUTS="$MERGE_INPUTS $f"
  SECTIONS_MERGED="${SECTIONS_MERGED}${SECTIONS_MERGED:+,}$s"
done

# --- 2. deep-merge .populated objects (recursive object merge; later wins) ---
MERGED="$TMPDIR_RUN/merged.json"
# shellcheck disable=SC2086
jq -s 'reduce .[] as $f ({}; . * ($f.populated // {}))' $MERGE_INPUTS > "$MERGED" \
  || fail "fragment deep-merge failed"

# --- 3. inject system fields + normalize mirrors ---
FINAL="$TMPDIR_RUN/user-manifest.json"
jq --arg ts "$RUN_TS" '
  # Ensure object containers exist.
  .identity = (.identity // {})
  | .paths   = (.paths   // {})
  | .vault   = (.vault   // {})
  | .system  = (.system  // {})
  # system fields (writer-owned; not interview-captured).
  | .system.schema_version = "2.0.0"
  | .system.created_date = $ts
  | .system.onboarding_complete = true
  # vault.root mirrors paths.vault_root when unset.
  | (if (.vault.root // null) == null then .vault.root = (.paths.vault_root // null) else . end)
' "$MERGED" > "$FINAL" || fail "system-field injection failed"

# --- 4. validate against slim schema ---
if ! validate_instance "$FINAL" "$SCHEMA"; then
  fail "user-manifest validation failed against $SCHEMA"
fi

TOP_KEYS="$(jq -c 'keys' "$FINAL")"

# --- 5. dry-run: diff + exit, zero mutations ---
if [ "$DRY_RUN" = "1" ]; then
  if [ -f "$OUT" ]; then
    if cmp -s "$FINAL" "$OUT"; then
      echo "DRY-RUN: user-manifest — no-op (byte-match) at $OUT" >&2
    else
      echo "DRY-RUN: user-manifest — would-update at $OUT (unified diff):" >&2
      diff -u "$OUT" "$FINAL" >&2 || true
    fi
  else
    echo "DRY-RUN: user-manifest — would-create at $OUT:" >&2
    diff -u /dev/null "$FINAL" >&2 || true
  fi
  echo "DRY-RUN: complete — zero filesystem mutations; sections merged: ${SECTIONS_MERGED}" >&2
  exit 0
fi

# --- 6. idempotent atomic write ---
if [ -f "$OUT" ]; then
  if cmp -s "$FINAL" "$OUT"; then
    audit_event "skip-identical" "user-manifest already matches at target" \
      "$(jq -nc --argjson s "$(jq -nc --arg v "$SECTIONS_MERGED" '$v')" '{sections_merged:$s}')"
    info "user-manifest.json already up to date (byte-match) — no write"
    exit 0
  fi
  if [ "$FORCE" != "1" ]; then
    cp "$FINAL" "${OUT}.new" || fail "could not stage ${OUT}.new"
    echo "DIFF: user-manifest differs at $OUT (--force to overwrite). Staged at ${OUT}.new" >&2
    diff -u "$OUT" "$FINAL" | head -60 >&2 || true
    audit_event "differs-no-force" "live target differs; .new staged; --force to overwrite"
    exit 2
  fi
fi

mkdir -p "$(dirname "$OUT")" 2>/dev/null || fail "cannot create target dir for $OUT"
FINAL_TMP="${OUT}.tmp.${RUN_ID}"
cp "$FINAL" "$FINAL_TMP" || fail "stage to ${FINAL_TMP} failed"
mv "$FINAL_TMP" "$OUT" || { rm -f "$FINAL_TMP"; fail "atomic rename to $OUT failed"; }

audit_event "BOOTSTRAP_COMPLETED" "user-manifest.json written" \
  "$(jq -nc --arg sm "$SECTIONS_MERGED" --argjson tk "$TOP_KEYS" \
       '{sections_merged:$sm, top_level_keys:$tk}')"
info "user-manifest.json written to $OUT (sections merged: ${SECTIONS_MERGED})"
exit 0
