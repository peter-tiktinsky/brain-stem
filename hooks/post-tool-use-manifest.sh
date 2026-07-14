#!/bin/bash
# post-tool-use-manifest.sh — PostToolUse manifest-verify hook.
#
# The verify-after-write surface: re-reads the
# just-written plan manifest, validates JSON well-formedness + (when a
# validator is present) schema conformance against
# schemas/plan-manifest-schema.json, and surfaces any warnings via
# additionalContext. ADVISORY only — PostToolUse runs AFTER the write and
# cannot undo it; this is defense-in-depth for what the PreToolUse
# manifest-substance branch misses.
#
# Hook contract (Claude Code PostToolUse):
#   stdin  - JSON event payload: {tool_name, tool_input: {file_path, ...}, ...}
#   stdout - Optional hookSpecificOutput JSON (advisory additionalContext).
#   timing - Advisory; never blocks the tool result.
#
# Match conditions (all must hold):
#   tool_name in {Edit, Write, MultiEdit, Update}
#   file_path matches a plan-tree manifest UNDER $PLANS_DIR (paths.sh; honors the
#   .paths.plans_root relocation override), with the ~/.claude-plans install-convention
#   literal RETAINED as a fail-open fallback:
#     $PLANS_DIR/*/manifest.json     (top-level / master manifest)
#     $PLANS_DIR/*/*/manifest.json   (depth-3 sub-plan manifest)
#
# Test-isolation env:
#   PLAN_MANIFEST_SCHEMA   - override path to plan-manifest-schema.json
#   POST_TOOL_USE_LOG      - explicit log path override
#   PLANS_DIR              - relocated plans tree (paths.sh honors a pre-set value)

set -uo pipefail

# --- derive $PLANS_DIR from paths.sh -------------------
# Match the plan-manifest against $PLANS_DIR so a RELOCATED plans tree (the
# .paths.plans_root override) is verified, not just the ~/.claude-plans literal.
# Source the repo-local lib first (dev/test), then the installed lib; a pre-set
# PLANS_DIR env wins (paths.sh honors it — test isolation). Mirrors the
# post-manifest-binder-refresh.sh PLANS_ROOT derivation. Fail-open: if paths.sh is
# unavailable, PLANS_ROOT falls back to the default and the literal fallback below
# still matches an in-convention plans tree.
_PTUM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
for _p in "$_PTUM_DIR/lib/paths.sh" "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"; do
  [ -r "$_p" ] && { . "$_p"; break; }
done
unset _p
PLANS_ROOT="${PLANS_DIR:-$HOME/.claude-plans}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac

INPUT=$(cat 2>/dev/null || echo "{}")

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

case "$TOOL_NAME" in
  Edit|Write|MultiEdit|Update) ;;
  *) exit 0 ;;
esac

[[ -z "$FILE_PATH" ]] && exit 0

# Match a plan-tree manifest (top-level OR depth-3 sub-plan) DERIVED from $PLANS_DIR
# (paths.sh) so a relocated plans tree is covered; the */.claude-plans/*/ literal is
# RETAINED as a fail-open fallback (paths.sh unavailable / PLANS_DIR unresolved). The
# bash [[ == ]] glob `*` spans '/', so "$PLANS_ROOT"/*/manifest.json covers both the
# top-level and the depth-3 sub-plan manifest.
is_plan_manifest=0
if [[ "$FILE_PATH" == "$PLANS_ROOT"/*/manifest.json ]]; then
  is_plan_manifest=1
elif [[ "$FILE_PATH" == */.claude-plans/*/manifest.json ]]; then
  is_plan_manifest=1
fi
[[ "$is_plan_manifest" == "0" ]] && exit 0

# The write has already landed — re-read the on-disk manifest.
[[ -f "$FILE_PATH" ]] || exit 0

WARNINGS=""

# --- (1) JSON well-formedness -------------------------------------------
if ! jq empty "$FILE_PATH" >/dev/null 2>&1; then
  WARNINGS="manifest.json is NOT well-formed JSON after this write — jq failed to parse ${FILE_PATH}. The manifest is the structured SoT for plan/task state; a malformed manifest breaks plan-index, the orchestrator DAG-walk, and the status guards."
  # Emit and stop: schema validation is moot on unparseable JSON.
  PAYLOAD=$(jq -n --arg ctx "[manifest-verify] $WARNINGS" \
    '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":$ctx}}' 2>/dev/null)
  [[ -n "$PAYLOAD" ]] && printf '%s\n' "$PAYLOAD"
  exit 0
fi

# --- (2) Schema conformance (when a validator is present) ---------------
# Prefer the deployed schema (CLAUDE_HOME-portable; PLAN_MANIFEST_SCHEMA test override
# wins). The ${CLAUDE_HOME:-$HOME/.claude}/schemas/... candidate is all an
# adopter needs (zero dev-repo residue in the adopter-runtime hook surface).
SCHEMA_PATH="${PLAN_MANIFEST_SCHEMA:-}"
if [[ -z "$SCHEMA_PATH" ]]; then
  for _cand in \
    "${CLAUDE_HOME:-$HOME/.claude}/schemas/plan-manifest-schema.json"; do
    if [[ -f "$_cand" ]]; then SCHEMA_PATH="$_cand"; break; fi
  done
fi

if [[ -n "$SCHEMA_PATH" && -f "$SCHEMA_PATH" ]] && command -v python3 >/dev/null 2>&1; then
  SCHEMA_ERR=$(python3 -c '
import sys, json
try:
    import jsonschema
except Exception:
    sys.exit(0)  # validator unavailable -> JSON-only check above suffices
try:
    schema = json.load(open(sys.argv[1]))
    inst = json.load(open(sys.argv[2]))
except Exception as e:
    print("could not load schema/instance: %s" % e); sys.exit(0)
v = jsonschema.Draft202012Validator(schema, format_checker=jsonschema.FormatChecker())
errs = sorted(v.iter_errors(inst), key=lambda e: list(e.path))
if errs:
    e = errs[0]
    loc = "/".join(str(p) for p in e.path) or "<root>"
    print("schema violation at %s: %s (and %d more)" % (loc, e.message, max(0, len(errs)-1)))
' "$SCHEMA_PATH" "$FILE_PATH" 2>/dev/null)
  if [[ -n "$SCHEMA_ERR" ]]; then
    WARNINGS="manifest does not conform to plan-manifest-schema.json — ${SCHEMA_ERR}"
  fi
fi

# --- Surface advisory ----------------------------------------------------
if [[ -n "$WARNINGS" ]]; then
  PAYLOAD=$(jq -n --arg ctx "[manifest-verify] $WARNINGS (advisory — the write already landed)" \
    '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":$ctx}}' 2>/dev/null)
  [[ -n "$PAYLOAD" ]] && printf '%s\n' "$PAYLOAD"
fi

exit 0
