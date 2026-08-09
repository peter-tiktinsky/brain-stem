#!/bin/bash
# librarian-manifest-validate — Validate a librarian-manifest.json payload against
# schemas/librarian-manifest-schema.json (block-and-log DENY on a schema-invalid
# manifest). Mechanical-tier.
#
# STATUS — schema validator, wired at session-close (the close-step-2 manifest-validation
# step, advisory) AND invocable ad-hoc. Behaviorally CORRECT on direct invoke
# (`--file bad.json` -> rc=1 DENY; a schema-valid manifest -> exit 0 silent). Earlier
# headers claimed a "runtime gate / writes_manifest_subtree consumer mandate" — that was
# fiction; the actual reach is the session-close close-step-2 wiring plus ad-hoc invoke.
#
# Invocation:
#   librarian-manifest-validate.sh                       # validate live manifest
#   librarian-manifest-validate.sh --file <path>         # validate <path>
#   librarian-manifest-validate.sh --stdin               # read JSON from stdin
#   librarian-manifest-validate.sh --schema-file <path>  # override schema
#   librarian-manifest-validate.sh --dry-run             # report-only, no log
#
# Validator tier selection (auto, override via MANIFEST_VALIDATOR):
#   - tier-1 ajv   — preferred if `ajv` binary in $PATH (full draft 2020-12)
#   - tier-2 python-jsonschema — fallback if `python3 -m jsonschema` works
#   - tier-3 minimal — ALWAYS available; verifies JSON parses + top-level
#                       required[] keys present + schema_version matches const
#
# Block-and-log semantics:
#   - schema-valid input: exit 0 silent (no findings emitted)
#   - schema-invalid input: emit finding to FINDINGS_OUTPUT/stdout + log
#                           diagnostic to $CLAUDE_HOME/logs/librarian-errors/
#                           + exit 1 (DENY)
#   - missing schema file: graceful skip with advisory finding + exit 0
#   - no validator available + tier-3 unreachable (Python broken): advisory + 0
#
# Env overrides (testing):
#   MANIFEST_VALIDATOR    — force tier selection: ajv | python-jsonschema | minimal
#   SCHEMAS_DIR           — relocate schemas/ root (default: $CLAUDE_HOME/schemas)
#   MANIFEST_PATH         — override target manifest path (default: live manifest)
#   FINDINGS_OUTPUT       — append findings to this file instead of stdout
#   ERROR_LOG_DIR         — override $CLAUDE_HOME/logs/librarian-errors/
#
# Exit codes:
#   0 — validation passed OR graceful skip (advisory emitted)
#   1 — validation failed (DENY; finding + diagnostic written)
#   2 — unknown flag
#   3 — payload file missing or unreadable
#
# Bash 3.2 clean per R-23.

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"

# Capture caller-provided env BEFORE sourcing paths.sh (which exports
# SCHEMAS_DIR + ERROR_LOG_DIR derivatives unconditionally and would clobber
# test/CI overrides). paths.sh is sourced for $VAULT_LOGS (consumed by
# manifest.sh default-resolution).
__CALLER_SCHEMAS_DIR="${SCHEMAS_DIR:-}"
__CALLER_ERROR_LOG_DIR="${ERROR_LOG_DIR:-}"
__CALLER_MANIFEST_PATH="${MANIFEST_PATH:-}"

if [[ -z "${VAULT_LOGS:-}" ]]; then
  # shellcheck source=/dev/null
  source "$CLAUDE_HOME_RES/hooks/lib/paths.sh" 2>/dev/null \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; } || true
fi

# Restore caller env (paths.sh may have overwritten).
[[ -n "$__CALLER_SCHEMAS_DIR" ]] && SCHEMAS_DIR="$__CALLER_SCHEMAS_DIR"
[[ -n "$__CALLER_ERROR_LOG_DIR" ]] && ERROR_LOG_DIR="$__CALLER_ERROR_LOG_DIR"
[[ -n "$__CALLER_MANIFEST_PATH" ]] && MANIFEST_PATH="$__CALLER_MANIFEST_PATH"

# Derive librarian root from script location for in-tree fallback sourcing.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBRARIAN_ROOT_DEFAULT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBRARIAN_ROOT="${LIBRARIAN_ROOT_OVERRIDE:-$LIBRARIAN_ROOT_DEFAULT}"

# shellcheck source=/dev/null
source "$CLAUDE_HOME_RES/hooks/lib/findings.sh" 2>/dev/null \
  || source "$_REPO_LIB/findings.sh"
# shellcheck source=/dev/null
source "$CLAUDE_HOME_RES/hooks/lib/manifest.sh" 2>/dev/null \
  || source "$_REPO_LIB/manifest.sh"

SCHEMAS_DIR_RES="${SCHEMAS_DIR:-$CLAUDE_HOME_RES/schemas}"
SCHEMA_FILE="$SCHEMAS_DIR_RES/librarian-manifest-schema.json"
ERROR_LOG_DIR_RES="${ERROR_LOG_DIR:-${CLAUDE_LOG_DIR:-$CLAUDE_HOME_RES/logs}/librarian-errors}"

MODE="check"
INPUT_MODE="live"
INPUT_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)        MODE="check"; shift ;;
    --dry-run)      MODE="dry-run"; shift ;;
    --file)         INPUT_MODE="file"; INPUT_PATH="$2"; shift 2 ;;
    --stdin)        INPUT_MODE="stdin"; shift ;;
    --schema-file)  SCHEMA_FILE="$2"; shift 2 ;;
    -h|--help)      sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "librarian-manifest-validate: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# Resolve payload to a temp file (uniform downstream handling).
PAYLOAD_FILE=""
PAYLOAD_LABEL=""
TMP_FILES=""
cleanup() { [[ -n "$TMP_FILES" ]] && rm -f $TMP_FILES; }
trap cleanup EXIT

case "$INPUT_MODE" in
  live)
    # G2/D3 (plan 110 T-62): resolve via the manifest.sh new-first/old-fallback
    # READ resolver (state/manifests/ first, vault Logs/ for one release; honors
    # a caller MANIFEST_PATH override). Removed in v1.4.0 (T-60).
    PAYLOAD_FILE="$(_manifest_read_path)"
    PAYLOAD_LABEL="$PAYLOAD_FILE"
    ;;
  file)
    PAYLOAD_FILE="$INPUT_PATH"
    PAYLOAD_LABEL="$INPUT_PATH"
    ;;
  stdin)
    # Swept for the inherited-never-EOF-fd-0 class and adjudicated NOT-APPLICABLE:
    # this `cat` drain is unreachable without the explicit `--stdin` flag. The
    # default INPUT_MODE is `live` and the session-close caller passes no flags, so
    # there is no fall-through — the caller that reaches here named stdin as the
    # payload source and contracted to close it. Bounding it would trade a hang for
    # validating an empty payload, which is a wrong answer rather than a slow one.
    PAYLOAD_FILE="$(mktemp -t librarian-manifest-validate-XXXXXX)"
    TMP_FILES="$TMP_FILES $PAYLOAD_FILE"
    cat > "$PAYLOAD_FILE"
    PAYLOAD_LABEL="<stdin>"
    ;;
esac

if [[ ! -f "$PAYLOAD_FILE" ]]; then
  echo "## Librarian Manifest Validate (skipped)"
  echo ""
  echo "- payload not found: $PAYLOAD_LABEL"
  exit 3
fi

# Schema availability check (graceful skip if missing).
if [[ ! -f "$SCHEMA_FILE" ]]; then
  if [[ "$MODE" != "dry-run" ]]; then
    emit_finding "manifest-validate-schema-missing" "$PAYLOAD_LABEL" \
      "level" "advisory" \
      "schema" "$SCHEMA_FILE" \
      "detail" "schema file absent; validation skipped"
  fi
  echo "## Librarian Manifest Validate (skipped — schema missing)"
  echo ""
  echo "- manifest-validate-schema-missing: $SCHEMA_FILE"
  exit 0
fi

# Validator tier selection.
#   Force via MANIFEST_VALIDATOR env (ajv | python-jsonschema | minimal).
#   Auto: ajv > python-jsonschema > minimal.
detect_validator() {
  local forced="${MANIFEST_VALIDATOR:-}"
  if [[ -n "$forced" ]]; then
    case "$forced" in
      ajv|python-jsonschema|minimal) printf '%s' "$forced"; return 0 ;;
      *) echo "librarian-manifest-validate: unknown MANIFEST_VALIDATOR='$forced'" >&2
         exit 2 ;;
    esac
  fi
  if command -v ajv >/dev/null 2>&1; then
    printf '%s' "ajv"; return 0
  fi
  if python3 -c 'import jsonschema' >/dev/null 2>&1; then
    printf '%s' "python-jsonschema"; return 0
  fi
  printf '%s' "minimal"
}

VALIDATOR=$(detect_validator)

# Validation dispatch.
# Returns (via stdout): { "ok": bool, "errors": ["..."], "tier": "..." }
# Returns exit 0 always (errors carried in JSON payload). Caller decides DENY.
validate_ajv() {
  local out
  out=$(ajv validate -s "$SCHEMA_FILE" -d "$PAYLOAD_FILE" --strict=false 2>&1) || true
  if echo "$out" | grep -qE '\bvalid\b' && ! echo "$out" | grep -qE '\binvalid\b'; then
    printf '{"ok":true,"errors":[],"tier":"ajv"}'
  else
    python3 - "$out" <<'PY'
import json, sys
errs = sys.argv[1].splitlines()
errs = [e for e in errs if e.strip()]
print(json.dumps({"ok": False, "errors": errs, "tier": "ajv"}, ensure_ascii=True))
PY
  fi
}

validate_python_jsonschema() {
  python3 - "$SCHEMA_FILE" "$PAYLOAD_FILE" <<'PY'
import json, sys
try:
    import jsonschema
except Exception as exc:
    print(json.dumps({"ok": False, "errors": ["jsonschema import failed: " + str(exc)], "tier": "python-jsonschema"}, ensure_ascii=True))
    sys.exit(0)
schema_path, payload_path = sys.argv[1], sys.argv[2]
try:
    with open(schema_path) as f:
        schema = json.load(f)
    with open(payload_path) as f:
        payload = json.load(f)
except Exception as exc:
    print(json.dumps({"ok": False, "errors": ["parse error: " + str(exc)], "tier": "python-jsonschema"}, ensure_ascii=True))
    sys.exit(0)
v = jsonschema.Draft202012Validator(schema)
errs = []
for e in v.iter_errors(payload):
    loc = "/".join(str(p) for p in e.absolute_path) or "<root>"
    errs.append(loc + ": " + e.message)
print(json.dumps({"ok": not errs, "errors": errs, "tier": "python-jsonschema"}, ensure_ascii=True))
PY
}

validate_minimal() {
  python3 - "$SCHEMA_FILE" "$PAYLOAD_FILE" <<'PY'
import json, sys
schema_path, payload_path = sys.argv[1], sys.argv[2]
try:
    with open(schema_path) as f:
        schema = json.load(f)
    with open(payload_path) as f:
        payload = json.load(f)
except Exception as exc:
    print(json.dumps({"ok": False, "errors": ["parse error: " + str(exc)], "tier": "minimal"}, ensure_ascii=True))
    sys.exit(0)
errs = []
expected_type = schema.get("type")
if expected_type == "object" and not isinstance(payload, dict):
    errs.append("<root>: expected object, got " + type(payload).__name__)
required = schema.get("required") or []
if isinstance(payload, dict):
    for key in required:
        if key not in payload:
            errs.append("<root>: missing required key '" + key + "'")
sv_schema = schema.get("properties", {}).get("schema_version", {})
sv_const = sv_schema.get("const") if isinstance(sv_schema, dict) else None
if sv_const is not None and isinstance(payload, dict):
    actual = payload.get("schema_version")
    if actual != sv_const:
        errs.append("schema_version: expected '" + str(sv_const) + "', got '" + str(actual) + "'")
print(json.dumps({"ok": not errs, "errors": errs, "tier": "minimal"}, ensure_ascii=True))
PY
}

case "$VALIDATOR" in
  ajv)                RESULT=$(validate_ajv) ;;
  python-jsonschema)  RESULT=$(validate_python_jsonschema) ;;
  minimal)            RESULT=$(validate_minimal) ;;
esac

# Parse result.
OK=$(printf '%s' "$RESULT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("true" if d.get("ok") else "false")' 2>/dev/null || echo "false")
TIER=$(printf '%s' "$RESULT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tier",""))' 2>/dev/null || echo "$VALIDATOR")
ERR_COUNT=$(printf '%s' "$RESULT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("errors",[])))' 2>/dev/null || echo "0")

# Result handling.
if [[ "$OK" == "true" ]]; then
  echo "## Librarian Manifest Validate (PASS via $TIER)"
  echo ""
  echo "- payload: $PAYLOAD_LABEL"
  echo "- schema:  $SCHEMA_FILE"
  exit 0
fi

# DENY path. Emit finding(s) + write diagnostic + exit 1 unless dry-run.
ERRORS_JSON=$(printf '%s' "$RESULT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get("errors",[]),ensure_ascii=True))' 2>/dev/null || echo "[]")

if [[ "$MODE" != "dry-run" ]]; then
  emit_finding "manifest-validate-schema-violation" "$PAYLOAD_LABEL" \
    "level" "error" \
    "tier" "$TIER" \
    "error_count" "$ERR_COUNT" \
    "schema" "$SCHEMA_FILE"

  mkdir -p "$ERROR_LOG_DIR_RES"
  LOG_DATE=$(date -u +"%Y-%m-%d")
  LOG_FILE="$ERROR_LOG_DIR_RES/${LOG_DATE}-manifest-validate.md"
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  {
    echo "## $TS — schema violation"
    echo ""
    echo "- payload: $PAYLOAD_LABEL"
    echo "- schema:  $SCHEMA_FILE"
    echo "- tier:    $TIER"
    echo "- errors:  $ERR_COUNT"
    echo ""
    echo '```json'
    echo "$ERRORS_JSON"
    echo '```'
    echo ""
  } >> "$LOG_FILE"
fi

echo "## Librarian Manifest Validate (DENY via $TIER — $ERR_COUNT errors)"
echo ""
echo "- payload: $PAYLOAD_LABEL"
echo "- schema:  $SCHEMA_FILE"
echo "- diagnostic: $ERROR_LOG_DIR_RES/$(date -u +"%Y-%m-%d")-manifest-validate.md"

if [[ "$MODE" == "dry-run" ]]; then
  exit 0
fi
exit 1
