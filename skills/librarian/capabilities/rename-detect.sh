#!/bin/bash
# rename-detect — Detect file renames via git log across vault + plans repos.
#
# Scans the last 24h (default)
# of `git log --diff-filter=R --name-status -M90` across $VAULT_ROOT and
# $PLANS_DIR, emitting one NDJSON record per rename:
#
#   {"root":"...","old_path":"...","new_path":"...","commit_sha":"...",
#    "committed_at":"<ISO8601>","similarity":95}
#
# Upstream signal for rename-cascade.sh. Pipe-composable:
#   rename-detect.sh | rename-cascade.sh
#
# Sources lib/manifest.sh; when --register is passed, each detected rename is
# appended to the findings registry under drift_findings.rename_detected.
#
# CLI:
#   rename-detect.sh                         # emit NDJSON to stdout / FINDINGS_OUTPUT
#   rename-detect.sh --since <iso8601>       # override 24h default (git-parsable)
#   rename-detect.sh --root <path>           # override configured roots (repeatable)
#   rename-detect.sh --register              # also append findings via manifest.sh
#   rename-detect.sh --persist-history       # ALSO append each record to the
#                                            # librarian-manifest rename_history[]
#                                            # (named populator: manifest.sh
#                                            # manifest_append_rename_history,
#                                            # dedup on commit+from+to) so the
#                                            # move outlives the 24h git window
#                                            # and stays repairable later via
#                                            # rename-cascade --from-history
#   rename-detect.sh --min-similarity <int>  # filter by R-score (default: 0 = all)
#   rename-detect.sh --help
#
# Env overrides (testing):
#   RENAME_DETECT_ROOTS  colon-separated list; overrides default roots.
#   FINDINGS_OUTPUT      redirect NDJSON emission to file.
#
# Exits:
#   0 on success or empty-window (no-op is not a failure).
#   2 on unknown flag.
#
# Bash 3.2 clean per R-23. No declare -A, no =~, no ${var,,}.

set -euo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"

if [[ -z "${VAULT_LOGS:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; }
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || source "$_REPO_LIB/findings.sh"

SINCE="24 hours ago"
MIN_SIM="0"
REGISTER="false"
PERSIST_HISTORY="false"
ROOTS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="$2"; shift 2 ;;
    --root) ROOTS="${ROOTS}${ROOTS:+:}$2"; shift 2 ;;
    --register) REGISTER="true"; shift ;;
    --persist-history) PERSIST_HISTORY="true"; shift ;;
    --min-similarity) MIN_SIM="$2"; shift 2 ;;
    -h|--help)
      awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"
      exit 0
      ;;
    *) echo "rename-detect: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# Root selection precedence: --root flag > RENAME_DETECT_ROOTS env > defaults.
if [[ -z "$ROOTS" ]]; then
  # the root registry reaches the vault + plans repos AND
  # ~/.claude (CLAUDE_GIT_REPO — governance/*.json, SKILL.md, rules/*.md, schemas/*.json,
  # projects/*/memory, settings.json renames) AND ~/work (WORK_HOME — work-spoke renames).
  # ~/.claude is a git repo (process_root scans it directly); ~/work has NO top-level
  # .git, so process_root treats it as a spoke-container and scans each ~/work/<spoke>
  # that is its OWN git repo (per-spoke .git detection — a bare root-list add would
  # short-circuit on the :84 missing-top-level-.git guard).
  ROOTS="${RENAME_DETECT_ROOTS:-$VAULT_ROOT:$PLANS_DIR:${CLAUDE_GIT_REPO:-}:${WORK_HOME:-}}"
fi

# Optional late-source of manifest.sh so --register / --persist-history don't
# cost anything when unused (manifest.sh spins up python3 per call).
if [[ "$REGISTER" == "true" || "$PERSIST_HISTORY" == "true" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/manifest.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/manifest.sh"; } \
    || source "$_REPO_LIB/manifest.sh"
fi

# --persist-history: mirror every emitted record into a temp NDJSON and append
# it to the librarian-manifest rename_history[] at exit (the named populator:
# manifest_append_rename_history, hooks/lib/manifest.sh — dedup on
# commit+from+to). This is the durable trail that lets a rename outlive the
# 24-hour git-log window: detect once, repair any time later via
# rename-cascade --from-history. Flag-gated so a bare ad-hoc pipe stays
# read-only against shared state.
HISTORY_TMP=""
if [[ "$PERSIST_HISTORY" == "true" ]]; then
  HISTORY_TMP=$(mktemp -t rename-detect-history.XXXXXX)
  trap 'rm -f "${HISTORY_TMP:-}"' EXIT
fi

# process_root — dispatch a configured root. A root that is itself a git repo is
# scanned directly (vault / plans / ~/.claude). A NON-git root (e.g. ~/work) is treated
# as a SPOKE-CONTAINER: each immediate child that is its own git repo is scanned (via
# per-spoke .git detection — the ~/work tree has no top-level .git, so a bare root-list
# add would hit the scan_git_repo :84 guard and short-circuit, missing every spoke).
process_root() {
  local root="$1" child
  [[ -z "$root" ]] && return 0
  if [[ -d "$root/.git" ]]; then
    scan_git_repo "$root"
    return 0
  fi
  [[ -d "$root" ]] || return 0
  for child in "$root"/*; do
    [[ -d "$child/.git" ]] && scan_git_repo "$child"
  done
  return 0
}

scan_git_repo() {
  local root="$1"
  [[ -z "$root" ]] && return 0
  [[ ! -d "$root/.git" ]] && return 0

  # Use process substitution-free loop for bash 3.2 compat.
  local log_output
  log_output=$(git -C "$root" log \
    --diff-filter=R \
    --name-status \
    -M90 \
    --since="$SINCE" \
    --format='__COMMIT__%H%n__ISO__%aI' 2>/dev/null || true)
  [[ -z "$log_output" ]] && return 0

  local commit_sha=""
  local committed_at=""
  local line
  # shellcheck disable=SC2030,SC2031
  while IFS= read -r line; do
    case "$line" in
      __COMMIT__*)
        commit_sha="${line#__COMMIT__}"
        ;;
      __ISO__*)
        committed_at="${line#__ISO__}"
        ;;
      R*)
        # R<score>\t<old_path>\t<new_path>
        # Peel score + paths using IFS=tab.
        local score old_path new_path rest
        rest="$line"
        score="${rest%%	*}"
        rest="${rest#*	}"
        old_path="${rest%%	*}"
        new_path="${rest#*	}"
        # score has leading 'R' e.g. R095 — strip it.
        score="${score#R}"
        # Bash 3.2 arithmetic compare on leading-zero numbers: strip zeros.
        local score_n="${score##0}"
        [[ -z "$score_n" ]] && score_n="0"
        if [[ "$score_n" -lt "$MIN_SIM" ]]; then
          continue
        fi
        emit_record "$root" "$old_path" "$new_path" "$commit_sha" "$committed_at" "$score_n"
        ;;
      "")
        # blank separator between commits
        :
        ;;
      *)
        # non-rename line (shouldn't happen with diff-filter=R) — ignore
        :
        ;;
    esac
  done <<EOF
$log_output
EOF
}

emit_record() {
  local root="$1" old_path="$2" new_path="$3" sha="$4" ts="$5" sim="$6"
  # Pure-shell JSON: escape backslashes + quotes in string fields.
  local r o n
  r=$(json_escape "$root")
  o=$(json_escape "$old_path")
  n=$(json_escape "$new_path")
  local payload
  payload="{\"root\":\"$r\",\"old_path\":\"$o\",\"new_path\":\"$n\",\"commit_sha\":\"$sha\",\"committed_at\":\"$ts\",\"similarity\":$sim}"
  emit_event "$payload"
  if [[ "$REGISTER" == "true" ]]; then
    manifest_append_finding rename_detected "$payload" || true
  fi
  if [[ -n "$HISTORY_TMP" ]]; then
    printf '%s\n' "$payload" >> "$HISTORY_TMP"
  fi
}

json_escape() {
  # Escape backslashes and double quotes for safe JSON string interpolation.
  # No tab/newline handling needed — git-reported paths use forward slashes.
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# Split ROOTS on ':' — bash 3.2 safe.
OLD_IFS="$IFS"
IFS=:
for r in $ROOTS; do
  IFS="$OLD_IFS"
  process_root "$r"
  IFS=:
done
IFS="$OLD_IFS"

if [[ -n "$HISTORY_TMP" && -s "$HISTORY_TMP" ]]; then
  manifest_append_rename_history "$HISTORY_TMP" || true
fi

exit 0
