#!/usr/bin/env bash
# skills/doc-amender/process.sh — event-driven LLM-amendment runner for
# prompt-guided edits to fan-in destinations (the writer-pipeline LLM lane,
# .2).
#
# Ported from the skills/doc-amender/process.sh;
# (lib defaults repointed to the shipped hooks/lib/ per; staging root resolved
# via $CLAUDE_STATE_ROOT — no bare ~/.claude or literal).
# T-03 (Layer-1 consumer runtime port).
#
# Reads amender-eligible packets from staging, joins them against
# governance/doc-dependencies.json writer-fan-in entries; for an eligible
# packet it runs the operator-authored prompt asset through `claude -p`
# (persistence.mode=llm-mediated / hybrid) OR dispatches to compose-deterministic.sh
# (persistence.mode=deterministic, T-06), then emits a REPLACEMENT packet via
# hooks/lib/staging-emit.sh --packet-kind amender-replacement. NEVER writes the
# destination directly (R-34 boundary preserved via the staging round-trip).
#
# Triggered by launchd WatchPaths on $STAGING_ROOT (NOT cron). Self-exclusion is
# critical: doc-amender's own emissions land in the same staging root and would
# re-fire WatchPaths. Filter by packet_kind ∈ {writer-emit, null}; explicitly
# drop packet_kind ∈ {amender-replacement, amender-conflict}.
#
# Debounce + single-instance: global lockf on $STAGING_ROOT/.doc-amender.lock
# (the canonical /usr/bin/lockf -k -t 0 re-exec sentinel pattern).
#
# bash 3.2 compatible. jq REQUIRED. shasum REQUIRED. claude REQUIRED for the
# llm-mediated lane (dry-run + deterministic lane skip it).

set -u

# Capture the ORIGINAL argv (indexed array) immediately after set -u, BEFORE the
# parse loop consumes $@ via shift, so the lockf re-exec forwards it verbatim +
# empty-safe. This site reaches the re-exec with an EMPTY original argv on a
# zero-CLI-arg WatchPaths tick, so the "${arr[@]+...}" form is load-bearing under
# set -u (a bare "${arr[@]}" throws unbound-variable on bash 3.2.57) —.
_DA_ORIG_ARGV=("$@")

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

# the shared libs live at hooks/lib/ (brain-stem has no top-level lib/).
# Resolve via $CLAUDE_HOME at runtime (installed layout) with a repo fallback.
_DA_CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
_DA_STATE_ROOT="${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}"
DEFAULT_STAGING_ROOT="$_DA_STATE_ROOT/vault-staging"
DEFAULT_VAULT_WRITER_STATE_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/brain-stem/vault-writers"
DEFAULT_DOC_DEPS_FILE="$REPO_ROOT/governance/doc-dependencies.json"
# hooks/lib/ default — installed layout wins, repo fallback for tests.
if [ -r "$_DA_CLAUDE_HOME/hooks/lib/staging-emit.sh" ]; then
  DEFAULT_STAGING_EMIT="$_DA_CLAUDE_HOME/hooks/lib/staging-emit.sh"
else
  DEFAULT_STAGING_EMIT="$REPO_ROOT/hooks/lib/staging-emit.sh"
fi
if [ -r "$_DA_CLAUDE_HOME/hooks/lib/manifest-record.sh" ]; then
  DEFAULT_MANIFEST_RECORD="$_DA_CLAUDE_HOME/hooks/lib/manifest-record.sh"
else
  DEFAULT_MANIFEST_RECORD="$REPO_ROOT/hooks/lib/manifest-record.sh"
fi
DEFAULT_COMPOSE_DETERMINISTIC="$SCRIPT_DIR/compose-deterministic.sh"

STAGING_ROOT=""
PROMPT_ROOT=""
DOC_DEPS_FILE="$DEFAULT_DOC_DEPS_FILE"
STAGING_EMIT="$DEFAULT_STAGING_EMIT"
MANIFEST_RECORD="$DEFAULT_MANIFEST_RECORD"
COMPOSE_DETERMINISTIC="$DEFAULT_COMPOSE_DETERMINISTIC"
AUDIT_LOG=""
DRY_RUN=0
ONCE=0

usage() {
  cat <<EOF
process.sh — doc-amender runtime (event-driven on WatchPaths fire).

Usage:
  process.sh [--staging-root PATH] [--prompt-root PATH] [--dry-run] [--once]
             [--audit-log PATH] [--doc-deps-file PATH]
             [--staging-emit PATH] [--manifest-record PATH]
             [--compose-deterministic PATH]

Defaults:
  --staging-root           \$STAGING_ROOT env (or \$CLAUDE_STATE_ROOT/vault-staging)
  --prompt-root            \$VAULT_WRITER_STATE_ROOT/prompts/
  --audit-log              \$CLAUDE_LOG_DIR/doc-amender-audit.log
                           (or /tmp/doc-amender-audit.log if unset)
  --doc-deps-file          $DEFAULT_DOC_DEPS_FILE
  --staging-emit           hooks/lib/staging-emit.sh (installed or repo)
  --manifest-record        hooks/lib/manifest-record.sh (installed or repo)
  --compose-deterministic  $DEFAULT_COMPOSE_DETERMINISTIC

Flags:
  --dry-run                Emit eligibility + prompt-resolution plan on
                           stdout; skip LLM calls and staging-emit.
  --once                   Single scan + exit (same as default behavior;
                           WatchPaths fires the process per event).

Exit codes:
  0   success (or no eligible packets)
  2   bad invocation / missing prereq
  3   per-packet errors during batch (logged; non-fatal individually)
  4   lock contention (another doc-amender fire in flight)
  5   tick-level error (doc-deps file corrupt; staging root unreadable)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --staging-root)          STAGING_ROOT="$2"; shift 2 ;;
    --prompt-root)           PROMPT_ROOT="$2"; shift 2 ;;
    --doc-deps-file)         DOC_DEPS_FILE="$2"; shift 2 ;;
    --staging-emit)          STAGING_EMIT="$2"; shift 2 ;;
    --manifest-record)       MANIFEST_RECORD="$2"; shift 2 ;;
    --compose-deterministic) COMPOSE_DETERMINISTIC="$2"; shift 2 ;;
    --audit-log)             AUDIT_LOG="$2"; shift 2 ;;
    --dry-run)               DRY_RUN=1; shift ;;
    --once)                  ONCE=1; shift ;;
    -h|--help)               usage; exit 0 ;;
    *) printf 'process.sh: unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---- resolve defaults -------------------------------------------------------

if [ -z "$STAGING_ROOT" ]; then
  STAGING_ROOT="$DEFAULT_STAGING_ROOT"
fi

if [ -z "$PROMPT_ROOT" ]; then
  vwsr="${VAULT_WRITER_STATE_ROOT:-$DEFAULT_VAULT_WRITER_STATE_ROOT}"
  PROMPT_ROOT="$vwsr/prompts"
fi

if [ -z "$AUDIT_LOG" ]; then
  AUDIT_LOG="${CLAUDE_LOG_DIR:-/tmp}/doc-amender-audit.log"
fi

# ---- pre-flight -------------------------------------------------------------

for tool in jq shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'process.sh: missing prereq: %s\n' "$tool" >&2
    exit 2
  fi
done

if [ ! -d "$STAGING_ROOT" ]; then
  # Missing staging root → silent no-op (WatchPaths fired before any writer
  # has emitted, or staging root not yet bootstrapped).
  printf 'process.sh: staging root %s does not exist; no-op\n' "$STAGING_ROOT" >&2
  exit 0
fi

# R-52 union-load fallback: the loose doc-dependencies.json is repo-only
# (composed into the SHIPPED foundation-master bundle; install.sh keeps the 7 pillars unshipped).
# When it is absent/unreadable — a clean adopter, where this cap would otherwise hard-exit — read
# the EFFECTIVE .doc_dependencies slot through the foundation⊕overlay merger (overlay wins per
# R-52) so the cap reads the canonical merged register, never a raw spoke. The merged slot's
# top-level (.entries) matches the loose spoke the downstream jq expects. Mirrors the plans-rules
# caps; an explicit --doc-deps-file override (present + readable) is preserved (no fallback).
if [ ! -r "$DOC_DEPS_FILE" ] || ! jq empty "$DOC_DEPS_FILE" >/dev/null 2>&1; then
  _OVL="${FOUNDATION_OVERLAY_LOAD:-${_DA_CLAUDE_HOME:-${CLAUDE_HOME:-$HOME/.claude}}/hooks/lib/foundation-overlay-load.sh}"
  [ -x "$_OVL" ] || _OVL="$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)/hooks/lib/foundation-overlay-load.sh"
  _FM="${_DA_CLAUDE_HOME:-${CLAUDE_HOME:-$HOME/.claude}}/governance/foundation-master.json"
  if [ -x "$_OVL" ] && [ -f "$_FM" ]; then
    _UNION="$(mktemp 2>/dev/null || true)"
    if [ -n "$_UNION" ] && bash "$_OVL" --foundation-path "$_FM" \
          --overlay-path "$(dirname "$_FM")/overlay-master.json" --query '.doc_dependencies' --force-override > "$_UNION" 2>/dev/null \
          && [ -s "$_UNION" ] && [ "$(head -c4 "$_UNION" 2>/dev/null)" != null ]; then
      DOC_DEPS_FILE="$_UNION"; trap 'rm -f "$_UNION"' EXIT
    elif [ -n "$_UNION" ]; then rm -f "$_UNION"; fi
  fi
fi

if [ ! -r "$DOC_DEPS_FILE" ]; then
  printf 'process.sh: doc-deps-file not readable: %s\n' "$DOC_DEPS_FILE" >&2
  exit 5
fi

if ! jq empty "$DOC_DEPS_FILE" >/dev/null 2>&1; then
  printf 'process.sh: doc-deps-file is not valid JSON: %s\n' "$DOC_DEPS_FILE" >&2
  exit 5
fi

if [ ! -r "$STAGING_EMIT" ]; then
  printf 'process.sh: staging-emit.sh not readable: %s\n' "$STAGING_EMIT" >&2
  exit 2
fi

if [ "$DRY_RUN" = "0" ]; then
  mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null || true
fi

# ---- lock acquisition (re-exec under global lockf for single-instance) ------
#
# Sentinel pattern: outer call (no sentinel set) re-execs $0 under lockf;
# inner call (sentinel set) proceeds with the real work. The kernel releases
# the lock on inner-process death automatically. Concurrent WatchPaths fires
# coalesce (second reads same staging state) or get rc=4 advisory.

LOCK_FILE="$STAGING_ROOT/.doc-amender.lock"

if [ -z "${DOC_AMENDER_LOCKED:-}" ]; then
  export DOC_AMENDER_LOCKED=1
  # Forward the ORIGINAL argv verbatim + empty-safe (bash-3.2 indexed array): no
  # hand-rolled string rebuild, so a space-containing arg can no longer word-split
  # at the re-exec, and a zero-CLI-arg WatchPaths tick forwards an empty array
  # safely under set -u. Convergent idiom shared with overlay-master-mutate.sh
  # + writer-reconciler/process.sh: rc=0 / || rc=$? captures the real inner exit
  # code (the prior `if ! ...; then rc=$?` read the !-negated status). The unrelated
  # SC2086 at the staging-emit producer call below is out of scope (not a $0 re-exec).
  rc=0
  /usr/bin/lockf -k -t 0 "$LOCK_FILE" "$0" "${_DA_ORIG_ARGV[@]+"${_DA_ORIG_ARGV[@]}"}" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" = "75" ]; then
      printf 'process.sh: lock contention on %s; another doc-amender fire in flight\n' "$LOCK_FILE" >&2
      exit 4
    fi
    exit "$rc"
  fi
  exit 0
fi

# ---- helpers ----------------------------------------------------------------

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Audit-log JSONL row writer.
# $1 packet  $2 writer_id  $3 destination  $4 op  $5 result  $6 prompt_id  $7 reason
audit_emit() {
  local line
  line=$(jq -nc \
    --arg ts "$(now_utc)" \
    --arg packet "$1" \
    --arg writer_id "$2" \
    --arg destination_path "$3" \
    --arg op "$4" \
    --arg result "$5" \
    --arg prompt_id "$6" \
    --arg reason "$7" \
    --arg packet_kind "amender-replacement" \
    '{ts:$ts,packet:$packet,writer_id:$writer_id,destination_path:$destination_path,op:$op,result:$result,prompt_id:$prompt_id,reason:$reason,emit_packet_kind:$packet_kind}')
  if [ "$DRY_RUN" = "0" ]; then
    printf '%s\n' "$line" >> "$AUDIT_LOG"
  else
    printf '[dry-run audit] %s\n' "$line"
  fi
}

# Write `_amender-conflict.json` sidecar next to the packet.
# $1 packet-path  $2 reason  $3 destination  $4 candidates-json (or empty)
sidecar_conflict() {
  local packet="$1" reason="$2" dest="$3" candidates="${4:-[]}"
  local sidecar="${packet}.amender-conflict.json"
  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run sidecar-conflict] %s: %s (dest=%s)\n' "$packet" "$reason" "$dest"
    return 0
  fi
  jq -nc \
    --arg ts "$(now_utc)" \
    --arg reason "$reason" \
    --arg original_packet "$packet" \
    --arg destination_path "$dest" \
    --argjson candidates "$candidates" \
    '{ts:$ts,reason:$reason,original_packet:$original_packet,destination_path:$destination_path,candidates:$candidates,packet_kind:"amender-conflict"}' \
    > "$sidecar" 2>/dev/null || true
}

# Parse frontmatter value from an .md file (simple "key: value" grep).
# $1 file  $2 key
fm_value() {
  local file="$1" key="$2"
  if [ ! -r "$file" ]; then return 1; fi
  grep "^${key}:" "$file" 2>/dev/null | head -1 | sed -e "s/^${key}:[[:space:]]*//" -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

# Glob match per shell case (treat $1 as glob, $2 as path).
glob_match() {
  local glob="$1" path="$2"
  case "$path" in
    $glob) return 0 ;;
  esac
  return 1
}

# ---- writer-fan-in eligible entries -----------------------------------------
#
# Build a tab-separated list of (consumer-glob | upstream_writers_csv) tuples
# for writer-fan-in entries with amendment_strategy=prompt-guided-amend.

ELIGIBLE_ENTRIES=$(jq -r '
  .entries[]
  | select(.kind == "writer-fan-in")
  | select(.amendment_strategy == "prompt-guided-amend")
  | [.consumer, (.upstream_writers | join(","))]
  | @tsv
' "$DOC_DEPS_FILE" 2>/dev/null)

if [ -z "$ELIGIBLE_ENTRIES" ]; then
  printf 'process.sh: no writer-fan-in entries with amendment_strategy=prompt-guided-amend; no-op\n' >&2
  exit 0
fi

# ---- prompt resolution ------------------------------------------------------

resolve_prompt_for_destination() {
  # $1 destination-path
  # Echoes prompt-file-path on single match; empty + rc=1 on zero match;
  # echoes all matches space-separated + rc=2 on multiple match.
  local dest="$1" prompt
  local matches=""
  local count=0
  if [ ! -d "$PROMPT_ROOT" ]; then
    return 1
  fi
  for prompt in "$PROMPT_ROOT"/*.md; do
    [ -f "$prompt" ] || continue
    local strategy dest_glob
    strategy=$(fm_value "$prompt" "amendment_strategy")
    # Accept all doc-amender strategies (T-05 contract): prompt-guided-amend
    # (llm-mediated), template-fill (deterministic), append-section (hybrid).
    # The persistence-mode dispatch (resolve_persistence_mode) then routes to
    # the claude -p lane or compose-deterministic.sh.
    case "$strategy" in
      prompt-guided-amend|template-fill|append-section) : ;;
      *) continue ;;
    esac
    dest_glob=$(fm_value "$prompt" "destination_glob")
    [ -n "$dest_glob" ] || continue
    if glob_match "$dest_glob" "$dest"; then
      matches="$matches $prompt"
      count=$((count + 1))
    fi
  done
  matches=$(printf '%s' "$matches" | sed 's/^ *//')
  if [ "$count" = "0" ]; then
    return 1
  fi
  if [ "$count" = "1" ]; then
    printf '%s' "$matches"
    return 0
  fi
  printf '%s' "$matches"
  return 2
}

# ---- survivorship signals ---------------------------------------------------

# Signal 1: destination frontmatter amender_paused: true.
sig1_amender_paused() {
  local dest="$1"
  if [ ! -f "$dest" ]; then return 1; fi
  local val
  val=$(fm_value "$dest" "amender_paused")
  case "$val" in
    true|True|TRUE|yes|Yes|YES) return 0 ;;
  esac
  return 1
}

# Signal 3: Karpathy `reviewed: true` checkpoint (clean pause; no LLM call,
# no sidecar). Distinct from sig2 operator-edit + sig1 amender_paused.
sig3_reviewed_checkpoint() {
  local dest="$1"
  if [ ! -f "$dest" ]; then return 1; fi
  local val
  val=$(fm_value "$dest" "reviewed")
  case "$val" in
    true|True|TRUE|yes|Yes|YES) return 0 ;;
  esac
  return 1
}

# Signal 2: operator-edit-wins.
# Signal A: last_user_edit frontmatter timestamp > packet emitted_at.
# Signal B: content-hash diff against most-recent manifest active row.
sig2_operator_edit() {
  local dest="$1" packet_emitted_at="$2"
  if [ ! -f "$dest" ]; then return 1; fi
  local lue
  lue=$(fm_value "$dest" "last_user_edit")
  if [ -n "$lue" ] && [ "$lue" \> "$packet_emitted_at" ]; then
    return 0
  fi
  local cur_sha last_sha
  cur_sha=$(shasum -a 256 "$dest" 2>/dev/null | awk '{print $1}')
  if [ -z "$cur_sha" ]; then return 1; fi
  if [ -x "$MANIFEST_RECORD" ] || [ -r "$MANIFEST_RECORD" ]; then
    last_sha=$(bash "$MANIFEST_RECORD" query-destination-history --destination-path "$dest" 2>/dev/null \
               | head -1 \
               | jq -r '.content_sha256 // empty' 2>/dev/null)
    if [ -n "$last_sha" ] && [ "$cur_sha" != "$last_sha" ]; then
      return 0
    fi
  fi
  return 1
}

# Resolve a prompt's persistence.mode from the file-type contract +
# the prompt's own frontmatter. The contract (T-05) declares the
# amendment_strategy ↔ persistence.mode mapping; a prompt MAY carry an explicit
# persistence_mode frontmatter override. Echoes one of: deterministic |
# llm-mediated | hybrid (default llm-mediated for prompt-guided-amend).
resolve_persistence_mode() {
  local prompt_path="$1"
  local explicit strategy
  explicit=$(fm_value "$prompt_path" "persistence_mode")
  if [ -n "$explicit" ]; then
    printf '%s' "$explicit"
    return 0
  fi
  strategy=$(fm_value "$prompt_path" "amendment_strategy")
  # Contract default mapping (doc-amender-prompt.md.json :: persistence_mode_default):
  #   template-fill → deterministic; append-section → hybrid;
  #   prompt-guided-amend → llm-mediated.
  case "$strategy" in
    template-fill)      printf 'deterministic' ;;
    append-section)     printf 'hybrid' ;;
    prompt-guided-amend) printf 'llm-mediated' ;;
    *)                  printf 'llm-mediated' ;;
  esac
}

# ---- per-packet processor ---------------------------------------------------

process_packet() {
  # $1 packet-path  $2 writer-id  $3 entry-consumer-glob  $4 entry-upstream-csv
  local packet="$1" writer_id="$2" entry_glob="$3" entry_upstream="$4"

  if ! jq empty "$packet" >/dev/null 2>&1; then
    audit_emit "$packet" "$writer_id" "" "parse" "FAIL" "" "packet-not-valid-json"
    return 1
  fi

  local destination packet_kind packet_emitted_at packet_body
  destination=$(jq -r '.destination_path // empty' "$packet")
  packet_kind=$(jq -r '.packet_kind // empty' "$packet")
  packet_emitted_at=$(jq -r '.emitted_at // empty' "$packet")

  # Self-exclusion filter: drop packet_kind ∈ {amender-replacement, amender-conflict}.
  case "$packet_kind" in
    amender-replacement|amender-conflict)
      return 0
      ;;
  esac

  # Eligibility join: packet.destination_path matches entry's consumer glob
  # AND packet.writer_id is in entry's upstream_writers[].
  if ! glob_match "$entry_glob" "$destination"; then
    return 0
  fi
  case ",$entry_upstream," in
    *",$writer_id,"*) : ;;
    *) return 0 ;;
  esac

  # Prompt resolution.
  local prompt_path prompt_rc candidates_json
  prompt_path=$(resolve_prompt_for_destination "$destination")
  prompt_rc=$?
  case "$prompt_rc" in
    0) : ;;
    1)
      audit_emit "$packet" "$writer_id" "$destination" "prompt-resolve" "SKIP" "" "prompt-not-found"
      return 0
      ;;
    2)
      candidates_json=$(printf '%s' "$prompt_path" | tr ' ' '\n' | jq -Rs 'split("\n") | map(select(length > 0))')
      sidecar_conflict "$packet" "prompt-resolve-multiple-matches" "$destination" "$candidates_json"
      audit_emit "$packet" "$writer_id" "$destination" "prompt-resolve" "CONFLICT" "" "multiple-matches"
      return 1
      ;;
  esac

  local prompt_id
  prompt_id=$(fm_value "$prompt_path" "prompt_id")
  if [ -z "$prompt_id" ]; then prompt_id="(unknown)"; fi

  # Survivorship signal 1: amender_paused frontmatter.
  if sig1_amender_paused "$destination"; then
    audit_emit "$packet" "$writer_id" "$destination" "survivorship-skip" "PAUSED" "$prompt_id" "amender-paused-frontmatter"
    return 0
  fi

  # Survivorship signal 3: reviewed:true checkpoint (clean pause).
  if sig3_reviewed_checkpoint "$destination"; then
    audit_emit "$packet" "$writer_id" "$destination" "survivorship-skip" "REVIEWED-CHECKPOINT" "$prompt_id" "reviewed-checkpoint-frontmatter"
    return 0
  fi

  # Survivorship signal 2: operator-edit-wins.
  if sig2_operator_edit "$destination" "$packet_emitted_at"; then
    sidecar_conflict "$packet" "operator-edit-wins" "$destination" "[]"
    audit_emit "$packet" "$writer_id" "$destination" "survivorship-skip" "OPERATOR-EDIT" "$prompt_id" "operator-edit-detected"
    return 0
  fi

  # ---- persistence-mode dispatch (B2 strategy-dispatched persistence-contract
  # runner). deterministic → compose-deterministic.sh (T-06, no claude -p);
  # llm-mediated / hybrid → the claude -p lane below. ----
  local persistence_mode
  persistence_mode=$(resolve_persistence_mode "$prompt_path")

  if [ "$persistence_mode" = "deterministic" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      printf '[dry-run apply] packet=%s prompt=%s destination=%s mode=deterministic would-dispatch=compose-deterministic.sh\n' \
        "$packet" "$prompt_path" "$destination"
      audit_emit "$packet" "$writer_id" "$destination" "deterministic-dispatch" "DRY-RUN" "$prompt_id" ""
      return 0
    fi
    if [ ! -r "$COMPOSE_DETERMINISTIC" ]; then
      audit_emit "$packet" "$writer_id" "$destination" "deterministic-dispatch" "FAIL" "$prompt_id" "compose-deterministic-missing"
      sidecar_conflict "$packet" "compose-deterministic-missing" "$destination" "[]"
      return 1
    fi
    rc=0
    STAGING_ROOT="$STAGING_ROOT" STAGING_EMIT="$STAGING_EMIT" \
      bash "$COMPOSE_DETERMINISTIC" \
        --packet "$packet" \
        --prompt "$prompt_path" \
        --destination "$destination" \
        --staging-emit "$STAGING_EMIT" 2>/dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
      audit_emit "$packet" "$writer_id" "$destination" "deterministic-dispatch" "FAIL" "$prompt_id" "compose-deterministic-rc-$rc"
      sidecar_conflict "$packet" "compose-deterministic-rc-$rc" "$destination" "[]"
      return 1
    fi
    audit_emit "$packet" "$writer_id" "$destination" "deterministic-dispatch" "OK" "$prompt_id" "amender-replacement-emitted-deterministic"
    return 0
  fi

  # ---- LLM call (llm-mediated / hybrid) ----
  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run apply] packet=%s prompt=%s destination=%s mode=%s would-emit=amender-replacement\n' \
      "$packet" "$prompt_path" "$destination" "$persistence_mode"
    audit_emit "$packet" "$writer_id" "$destination" "claude-p" "DRY-RUN" "$prompt_id" ""
    return 0
  fi

  if ! command -v claude >/dev/null 2>&1; then
    audit_emit "$packet" "$writer_id" "$destination" "claude-p" "FAIL" "$prompt_id" "claude-binary-missing"
    sidecar_conflict "$packet" "claude-binary-missing" "$destination" "[]"
    return 1
  fi

  # Compose substituted prompt body (6-var namespace):
  # packet_body, destination_current_content, destination_path,
  # upstream_writers, writer_metadata, amendment_history.
  packet_body=$(jq -r '.body // ""' "$packet")
  local dest_current_content amendment_history writer_metadata
  if [ -f "$destination" ]; then
    dest_current_content=$(cat "$destination" 2>/dev/null || printf '')
  else
    dest_current_content=""
  fi
  writer_metadata=$(jq -c '.metadata // {}' "$packet")
  if [ -x "$MANIFEST_RECORD" ] || [ -r "$MANIFEST_RECORD" ]; then
    amendment_history=$(bash "$MANIFEST_RECORD" query-destination-history --destination-path "$destination" 2>/dev/null || printf '')
  else
    amendment_history=""
  fi

  local prompt_body tmp_prompt tmp_output
  prompt_body=$(cat "$prompt_path" 2>/dev/null)
  tmp_prompt=$(mktemp -t doc-amender-prompt.XXXXXX)
  tmp_output=$(mktemp -t doc-amender-output.XXXXXX)

  {
    printf '<!-- doc-amender context block (6-var namespace) -->\n'
    printf '<destination_path>%s</destination_path>\n' "$destination"
    printf '<upstream_writers>%s</upstream_writers>\n' "$entry_upstream"
    printf '<writer_metadata>%s</writer_metadata>\n' "$writer_metadata"
    printf '<packet_body>\n%s\n</packet_body>\n' "$packet_body"
    printf '<destination_current_content>\n%s\n</destination_current_content>\n' "$dest_current_content"
    printf '<amendment_history>\n%s\n</amendment_history>\n' "$amendment_history"
    printf '\n<!-- prompt body (from %s) -->\n' "$prompt_path"
    printf '%s\n' "$prompt_body"
  } > "$tmp_prompt"

  rc=0
  claude -p < "$tmp_prompt" > "$tmp_output" 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp_prompt" "$tmp_output"
    audit_emit "$packet" "$writer_id" "$destination" "claude-p" "FAIL" "$prompt_id" "claude-p-rc-$rc"
    sidecar_conflict "$packet" "claude-p-rc-$rc" "$destination" "[]"
    return 1
  fi

  if [ ! -s "$tmp_output" ]; then
    rm -f "$tmp_prompt" "$tmp_output"
    audit_emit "$packet" "$writer_id" "$destination" "claude-p" "FAIL" "$prompt_id" "empty-output"
    sidecar_conflict "$packet" "claude-p-empty-output" "$destination" "[]"
    return 1
  fi

  rm -f "$tmp_prompt"

  # ---- emit replacement packet via staging-emit.sh ----
  local emit_writer_id="$writer_id+amender"
  local source_id
  source_id=$(jq -r '.source_id // empty' "$packet")

  STAGING_EMIT_ARGS=" --writer-id $emit_writer_id"
  STAGING_EMIT_ARGS="$STAGING_EMIT_ARGS --destination-path $destination"
  STAGING_EMIT_ARGS="$STAGING_EMIT_ARGS --output-type markdown"
  STAGING_EMIT_ARGS="$STAGING_EMIT_ARGS --body-file $tmp_output"
  STAGING_EMIT_ARGS="$STAGING_EMIT_ARGS --packet-kind amender-replacement"
  if [ -n "$source_id" ]; then
    STAGING_EMIT_ARGS="$STAGING_EMIT_ARGS --source-id $source_id"
  fi

  # shellcheck disable=SC2086
  rc=0
  STAGING_ROOT="$STAGING_ROOT" bash "$STAGING_EMIT" $STAGING_EMIT_ARGS 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp_output"
    audit_emit "$packet" "$writer_id" "$destination" "staging-emit" "FAIL" "$prompt_id" "staging-emit-rc-$rc"
    sidecar_conflict "$packet" "staging-emit-rc-$rc" "$destination" "[]"
    return 1
  fi

  rm -f "$tmp_output"
  audit_emit "$packet" "$writer_id" "$destination" "staging-emit" "OK" "$prompt_id" "amender-replacement-emitted"
  return 0
}

# ---- main batch loop --------------------------------------------------------

PROCESSED=0
ELIGIBLE=0
SUCCEEDED=0
FAILED=0
SKIPPED=0

# Iterate eligible entries × packets (bash 3.2: word-tokenized loop via temp).
ENTRIES_TMP=$(mktemp -t doc-amender-entries.XXXXXX)
printf '%s\n' "$ELIGIBLE_ENTRIES" > "$ENTRIES_TMP"

shopt -s nullglob 2>/dev/null || true
while IFS=$'\t' read -r entry_consumer entry_upstream; do
  [ -n "$entry_consumer" ] || continue
  [ -n "$entry_upstream" ] || continue
  for writer_dir in "$STAGING_ROOT"/*/; do
    [ -d "$writer_dir" ] || continue
    writer_id=$(basename "$writer_dir")
    case "$writer_id" in
      _archive|*+amender) continue ;;
    esac
    case ",$entry_upstream," in
      *",$writer_id,"*) : ;;
      *) continue ;;
    esac
    for packet in "$writer_dir"*.json; do
      [ -f "$packet" ] || continue
      case "$packet" in
        *._reconciler-error.json) continue ;;
        *.amender-conflict.json) continue ;;
      esac
      PROCESSED=$((PROCESSED + 1))
      pk=$(jq -r '.packet_kind // ""' "$packet" 2>/dev/null)
      case "$pk" in
        amender-replacement|amender-conflict) SKIPPED=$((SKIPPED + 1)); continue ;;
      esac
      ELIGIBLE=$((ELIGIBLE + 1))
      if process_packet "$packet" "$writer_id" "$entry_consumer" "$entry_upstream"; then
        SUCCEEDED=$((SUCCEEDED + 1))
      else
        FAILED=$((FAILED + 1))
      fi
    done
  done
done < "$ENTRIES_TMP"

rm -f "$ENTRIES_TMP"

printf 'process.sh: processed=%d eligible=%d succeeded=%d failed=%d skipped=%d\n' \
  "$PROCESSED" "$ELIGIBLE" "$SUCCEEDED" "$FAILED" "$SKIPPED" >&2

if [ "$FAILED" -gt 0 ]; then
  exit 3
fi
exit 0
