#!/bin/bash
# BASH-BLINDNESS (R-5, documented-by-design): this Edit|Write write-time governor is blind to Bash-tool writes (heredoc/cp/mv/tee/python) — the "honest residual" labeled at placement-validate.sh:95-96; the rule-30 Phase-2 PreToolUse Bash command-screen escalation is data-gated + NOT built.
# post-tool-use-manifest.sh — PostToolUse manifest-verify hook ((c)).
#
# mints the (c) verify-after-write surface: re-reads the
# just-written plan manifest, validates JSON well-formedness + (when a
# validator is present) schema conformance against
# schemas/plan-manifest-schema.json, and surfaces any warnings via
# additionalContext. ADVISORY only — PostToolUse runs AFTER the write and
# cannot undo it; this is defense-in-depth for what the PreToolUse
# manifest-substance branch ((a)) misses.
#
# plan-manifest-schema degrade-contract: ADVISORY validator — constructs a Draft202012Validator against plan-manifest-schema; a schema-invalid manifest yields an additionalContext warning and STILL exits 0 (never blocks the write, never freezes a read-replica).
# Scope note: this is the (c) verify body.
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
#   A path spelled through the vault's Plans/ symlink ($VAULT_ROOT/Plans/...) is
#   first canonicalized to the physical plans root, but only when that symlink's
#   target IS the plans root; a real Plans/ directory is never rewritten.
#
# Inbox arm (same tool_name gate, checked before the manifest match):
#   file_path is an idea note one level deep, $PLANS_DIR/_inbox/<name>.md, with the
#   */.claude-plans/_inbox/<name>.md literal as the same fail-open fallback; <name>
#   never starts with `_`, so _settled/ notes and _index.md stay silent. The note is
#   re-read from disk: an empty disposition, or one outside the plans-rules
#   backlog_row.disposition_enum, prints one additionalContext naming the note and
#   the enum, then one of three tails: `/backlog-triage --item <slug>` for an empty
#   disposition on a note whose status is new or absent; the redecide-idea.sh command
#   that sets the disposition, for an empty disposition on any other status; the
#   redecide-idea.sh command that replaces it, for a disposition outside the enum on
#   any status. Any other note prints nothing. A Bash-tool write of the note (a --capture) is
#   invisible here, so the prompt comes on the session's next Edit/Write of the note.
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

# Read the PostToolUse payload. The `|| echo "{}"` this replaces only ever fired on a
# `cat` that FAILED — an empty or closed stdin exits 0 and yields the empty string —
# so the empty capture below is the same value the old default path already produced,
# and jq reads "" and "{}" identically here (both give an empty .tool_name).
# BOUNDED capture: `[ ! -t 0 ]` tests "is stdin a TERMINAL", not "will stdin deliver
# EOF" — an inherited socket/fifo answers "not a tty" and NEVER EOFs, so the bare
# `cat` this replaces sleeps forever and the hook hangs with zero output. The timeout
# is on EVERY read and each line accumulates as it arrives, so a stream that keeps
# delivering is never truncated; blank lines are PRESERVED and the trailing-newline
# trim reproduces `$(cat)` exactly, so the payload reaches jq byte-identical.
# HOOKS_STDIN_WAIT overrides (whole seconds); a zero/non-numeric value falls back
# rather than reaching `read -t 0`, which on bash 3.2 arms no timer at all.
# The two reference implementations under skills/librarian/capabilities/ are NOT
# equivalent and this is neither: handoff-disposition-check.sh re-arms per read but
# DROPS blank lines; rename-cascade.sh bounds only the FIRST read, then free-runs an
# unbounded `cat`. This is the byte-preserving form the other hook drains carry.
INPUT=""
if [ ! -t 0 ]; then
  _STDIN_WAIT="${HOOKS_STDIN_WAIT:-5}"
  case "$_STDIN_WAIT" in ''|0|*[!0-9]*) _STDIN_WAIT=5 ;; esac
  _STDIN_LINE=""
  while IFS= read -r -t "$_STDIN_WAIT" _STDIN_LINE || [ -n "$_STDIN_LINE" ]; do
    INPUT="${INPUT}${_STDIN_LINE}"$'\n'
    _STDIN_LINE=""
  done
  while [ "${INPUT%$'\n'}" != "$INPUT" ]; do INPUT="${INPUT%$'\n'}"; done
  unset _STDIN_WAIT _STDIN_LINE
fi

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

case "$TOOL_NAME" in
  Edit|Write|MultiEdit|Update) ;;
  *) exit 0 ;;
esac

[[ -z "$FILE_PATH" ]] && exit 0

# Plans-address convergence: a manifest written through the vault's Plans/
# spelling ($VAULT_ROOT/Plans/<plan>/manifest.json) is the same file as its
# physical plans-root path, and is verified the same way. This is the rule of the
# PreToolUse guard's PLANS_ADDR_CONV prelude (hooks/pre-write-guard.sh): rewrite
# ONLY when $VAULT_ROOT/Plans is a symlink whose canonical target IS the plans
# root (pwd -P comparison). A real Plans/ directory in a vault, or a symlink that
# points elsewhere, is never rewritten. Any resolution error leaves FILE_PATH
# untouched (fail-open).
if [[ "${VAULT_CONFIGURED:-0}" == "1" ]] && [[ -n "${VAULT_ROOT:-}" ]] \
   && [[ "$FILE_PATH" == "$VAULT_ROOT/Plans/"* ]] && [[ -L "$VAULT_ROOT/Plans" ]]; then
  _PC_LINK_CANON="$(cd "$VAULT_ROOT/Plans" 2>/dev/null && pwd -P 2>/dev/null || true)"
  _PC_PLANS_CANON="$(cd "$PLANS_ROOT" 2>/dev/null && pwd -P 2>/dev/null || true)"
  if [[ -n "$_PC_LINK_CANON" ]] && [[ -n "$_PC_PLANS_CANON" ]] \
     && [[ "$_PC_LINK_CANON" == "$_PC_PLANS_CANON" ]]; then
    FILE_PATH="$PLANS_ROOT/${FILE_PATH#$VAULT_ROOT/Plans/}"
  fi
  unset _PC_LINK_CANON _PC_PLANS_CANON
fi

# --- inbox arm: an idea note with no in-enum disposition prompts triage ----
# awk and jq only (no python block). The enum resolves as promote-from-inbox.sh
# resolves plans-rules.json (PLANS_RULES_PATH, the loose pillar, then the
# foundation-overlay `.plans` slot), with a pillar-equal literal fallback.
_INBOX_NAME=""
case "$FILE_PATH" in
  "$PLANS_ROOT"/_inbox/*.md) _INBOX_NAME="${FILE_PATH#"$PLANS_ROOT"/_inbox/}" ;;
  */.claude-plans/_inbox/*.md) _INBOX_NAME="${FILE_PATH##*/.claude-plans/_inbox/}" ;;
esac
case "$_INBOX_NAME" in */*|_*) _INBOX_NAME="" ;; esac
if [[ -n "$_INBOX_NAME" ]]; then
  [[ -f "$FILE_PATH" ]] || exit 0
  _INBOX_SLUG="${_INBOX_NAME%.md}"
  _fm_value() { # _fm_value <key> <file>: the frontmatter value, trimmed and unquoted
    awk -v key="$1" '
      NR==1 { if ($0 ~ /^---[[:space:]]*$/) { infm=1; next } else { exit } }
      infm && /^---[[:space:]]*$/ { exit }
      infm && index($0, key ":") == 1 {
        v=substr($0, length(key) + 2); sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
        if (v ~ /^".*"$/) { v=substr(v, 2, length(v) - 2) }
        print v; exit
      }' "$2" 2>/dev/null
  }
  _INBOX_STATUS="$(_fm_value status "$FILE_PATH")"
  _INBOX_DISP="$(_fm_value disposition "$FILE_PATH")"
  _RULES="${PLANS_RULES_PATH:-}"
  [[ -n "$_RULES" && -f "$_RULES" ]] || _RULES="${CLAUDE_HOME:-$HOME/.claude}/governance/plans-rules.json"
  # A corrupt pillar or a failing loader reports on stderr; the literal fallback below
  # still lets the prompt name an enum.
  _ENUM=""
  if [[ -f "$_RULES" ]]; then
    _ENUM="$(jq -r '.backlog_row.disposition_enum[]? // empty' "$_RULES")"
  else
    for _loader in "$_PTUM_DIR/lib/foundation-overlay-load.sh" \
        "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/foundation-overlay-load.sh"; do
      [[ -x "$_loader" ]] || continue
      _ENUM="$(bash "$_loader" --query '.plans' --force-override \
        | jq -r '.backlog_row.disposition_enum[]? // empty')"
      [[ -n "$_ENUM" ]] && break
    done
  fi
  [[ -n "$_ENUM" ]] || _ENUM="$(printf '%s\n' "FIX NOW" "ABSORB" "STANDALONE" "NO-BUILD")"
  if [[ -n "$_INBOX_DISP" ]] && printf '%s\n' "$_ENUM" | grep -qxF -- "$_INBOX_DISP"; then
    exit 0
  fi
  _ENUM_LIST="$(printf '%s\n' "$_ENUM" | awk 'NF { printf "%s%s", (n++ ? ", " : ""), $0 }')"
  if [[ -z "$_INBOX_DISP" ]]; then
    _CTX="[inbox-triage] _inbox/${_INBOX_NAME} has no disposition. A disposition is one of: ${_ENUM_LIST}."
  else
    _CTX="[inbox-triage] _inbox/${_INBOX_NAME} carries disposition '${_INBOX_DISP}', which is not one of: ${_ENUM_LIST}."
  fi
  _REDECIDE='bash ${CLAUDE_HOME:-$HOME/.claude}/skills/backlog-triage/scripts/redecide-idea.sh'
  if [[ -n "$_INBOX_DISP" ]]; then
    _CTX="${_CTX} Replace it with: ${_REDECIDE} ${_INBOX_SLUG} --disposition <value> --rationale \"<one line>\" (a DEFERRED note takes --disposition NO-BUILD --reopen-gate manual)."
  elif [[ -z "$_INBOX_STATUS" || "$_INBOX_STATUS" == "new" ]]; then
    _CTX="${_CTX} Triage it now: /backlog-triage --item ${_INBOX_SLUG}"
  else
    _CTX="${_CTX} Set the disposition with: ${_REDECIDE} ${_INBOX_SLUG} --disposition <value> --rationale \"<one line>\" (its status is ${_INBOX_STATUS})."
  fi
  PAYLOAD=$(jq -n --arg ctx "$_CTX" \
    '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":$ctx}}')
  [[ -n "$PAYLOAD" ]] && printf '%s\n' "$PAYLOAD"
  exit 0
fi

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
  PAYLOAD=$(jq -n --arg ctx "[(c) manifest-verify] $WARNINGS" \
    '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":$ctx}}' 2>/dev/null)
  [[ -n "$PAYLOAD" ]] && printf '%s\n' "$PAYLOAD"
  exit 0
fi

# --- (2) Schema conformance (when a validator is present) ---------------
# Prefer the deployed schema (CLAUDE_HOME-portable; PLAN_MANIFEST_SCHEMA test override
# wins). The bare dev-repo fallback is dropped — the
# ${CLAUDE_HOME:-$HOME/.claude}/schemas/... candidate is all an adopter needs (zero
# dev-repo residue in the adopter-runtime hook surface).
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

# --- (3) Library promotion: queue a newly completed plan ------------------
# Reads the mode first (unset or `off`: nothing runs), then, when the written
# manifest's status is `completed`, runs the library-scrub.sh --candidates mode: a
# pre-filtered scan with no model call that queues the plan for the Stop hook's
# offer. Every state write stays in that capability, under its lock.
_LP_HOST=""
for _c in "${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/capabilities/library-scrub.sh" \
          "$(cd "$_PTUM_DIR/.." 2>/dev/null && pwd)/skills/librarian/capabilities/library-scrub.sh"; do
  if [[ -f "$_c" ]]; then _LP_HOST="$_c"; break; fi
done
unset _c
if [[ -n "$_LP_HOST" ]]; then
  case "$(bash "$_LP_HOST" --mode get 2>/dev/null </dev/null)" in
    prompt|auto)
      if [[ "$(jq -r '.status // empty' "$FILE_PATH" 2>/dev/null)" == "completed" ]]; then
        bash "$_LP_HOST" --candidates >/dev/null 2>&1 </dev/null || true
      fi ;;
  esac
fi

# --- Surface advisory ----------------------------------------------------
if [[ -n "$WARNINGS" ]]; then
  PAYLOAD=$(jq -n --arg ctx "[(c) manifest-verify] $WARNINGS (advisory — the write already landed)" \
    '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":$ctx}}' 2>/dev/null)
  [[ -n "$PAYLOAD" ]] && printf '%s\n' "$PAYLOAD"
fi

exit 0
