#!/usr/bin/env bash
# skills/meeting-note-ingestor/ingest.sh
#
# Foundation-portable, source-agnostic transcript ingestor. File path → structured
# meeting note (frontmatter + cleaned body). Source-agnostic and portable; Granola
# becomes one connector (skills/meeting-note-ingestor-granola wraps this).
#
# OUTPUT CONTRACT (R-43):
#   Files written: zero by default (stdout). When --output PATH supplied, writes
#                  one structured note file at PATH.
#   Schema-types:  Frontmatter contains two inline provenance fields
#                  (generated_by, generated_from) PLUS meeting-note-specific
#                  fields (title, date, source_format, source_path,
#                  participants[]). Provenance-frontmatter is DROPPED:
#                  no pf_emit, no provenance-frontmatter-schema.json.
#   Pre-write validation: transcript file existence + parser availability
#                  checked before normalization. Empty transcript →
#                  graceful-degrade frontmatter with empty body.
#   Failure mode:  BLOCK AND LOG. Non-zero exit on pre-flight failure or
#                  unsupported format with no override. Stdout silent on
#                  failure.
#
# DISPATCH:
#   1. --format <fmt> if supplied (override).
#   2. Else granola sniff (filename heuristic: granola-*.json, *.granola.json).
#   3. Else onboarding/seed-content/format-detector.sh (covers vtt, word,
#      zoom-transcript, llm-export, markdown, plaintext, pdf).
#   4. Granola JSON sniff promotes llm-export → granola when shape matches
#      (top-level title + transcript[]).
#
# OUTPUT: stdout by default; --output PATH writes a file; --output - explicit stdout.
#
# CONSTRAINTS (R-23): bash 3.2.57 compatible — no `declare -A`, no `mapfile`,
# no `${var,,}`. `jq` REQUIRED on PATH. Format-parsers reused; granola.sh
# parser co-located here (transcript-specific, not generic seed-content shape).

set -u

_usage() {
  cat >&2 <<'EOF'
Usage: ingest.sh --transcript PATH [options]

Required:
  --transcript PATH         Input transcript file (any format below).

Options:
  --format FMT              Override auto-detection. Supported:
                            otter-vtt | word | zoom-transcript | llm-export |
                            granola | markdown | plaintext.
  --output PATH|-           Write structured note to PATH; - = stdout (default).
  --title STR               Override extracted/derived title.
  --date YYYY-MM-DD         Override extracted/derived date.
  --surface-id ID           Provenance surface_id (default: meeting-note-ingestor).
  --seed-parsers-dir PATH   Override format-parsers dir.
  --format-detector PATH    Override format-detector.sh path.
  --ingestor-parsers-dir PATH  Override co-located parsers dir (granola.sh lives here).
  -h|--help                 Show this help.

Exit codes: 0 success; 2 pre-flight or argument failure; 3 unsupported format.
EOF
}

# --- bootstrap ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd)"

TRANSCRIPT=""
FMT_OVERRIDE=""
OUTPUT="-"
TITLE_OVERRIDE=""
DATE_OVERRIDE=""
SURFACE_ID="meeting-note-ingestor"
SEED_PARSERS_DIR="$REPO_ROOT/onboarding/seed-content/format-parsers"
FORMAT_DETECTOR="$REPO_ROOT/onboarding/seed-content/format-detector.sh"
INGESTOR_PARSERS_DIR="$SCRIPT_DIR/parsers"
# Provenance-frontmatter is DROPPED entirely. This was
# the one shipping pf_emit consumer; it is decoupled to inline printf below. No
# lib/provenance-frontmatter.sh source, no --pf-lib flag, no PF_LIB pre-flight.

while [ $# -gt 0 ]; do
  case "$1" in
    --transcript)         TRANSCRIPT="$2"; shift 2 ;;
    --format)             FMT_OVERRIDE="$2"; shift 2 ;;
    --output)             OUTPUT="$2"; shift 2 ;;
    --title)              TITLE_OVERRIDE="$2"; shift 2 ;;
    --date)               DATE_OVERRIDE="$2"; shift 2 ;;
    --surface-id)         SURFACE_ID="$2"; shift 2 ;;
    --seed-parsers-dir)   SEED_PARSERS_DIR="$2"; shift 2 ;;
    --format-detector)    FORMAT_DETECTOR="$2"; shift 2 ;;
    --ingestor-parsers-dir) INGESTOR_PARSERS_DIR="$2"; shift 2 ;;
    -h|--help)            _usage; exit 0 ;;
    *)
      printf 'ingest.sh: unknown arg: %s\n' "$1" >&2
      _usage
      exit 2
      ;;
  esac
done

# --- pre-flight ---

if [ -z "$TRANSCRIPT" ]; then
  printf 'ingest.sh FAIL: --transcript required\n' >&2
  exit 2
fi
if [ ! -f "$TRANSCRIPT" ]; then
  printf 'ingest.sh FAIL: transcript not found: %s\n' "$TRANSCRIPT" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'ingest.sh FAIL: jq required on PATH\n' >&2
  exit 2
fi

# --- format detection ---

_detect_format() {
  local p="$1"
  local base_lc
  base_lc="$(basename "$p" | tr '[:upper:]' '[:lower:]')"

  # Granola filename heuristic.
  case "$base_lc" in
    *.granola.json|granola-*.json|granola_*.json)
      printf 'granola\n'; return 0 ;;
  esac

  # format-detector.
  local fmt="unsupported"
  if [ -f "$FORMAT_DETECTOR" ]; then
    fmt="$(bash "$FORMAT_DETECTOR" "$p" 2>/dev/null || printf 'unsupported\n')"
  fi

  # JSON shape sniff: promote llm-export → granola when granola-shaped.
  if [ "$fmt" = "llm-export" ] || [ "$fmt" = "plaintext" ]; then
    if jq -e '
      type == "object" and
      (has("title") or has("meeting_title")) and
      (has("transcript") or has("body") or has("attendees"))
    ' "$p" >/dev/null 2>&1; then
      fmt="granola"
    fi
  fi

  printf '%s\n' "$fmt"
}

if [ -n "$FMT_OVERRIDE" ]; then
  FORMAT="$FMT_OVERRIDE"
else
  FORMAT="$(_detect_format "$TRANSCRIPT")"
fi

case "$FORMAT" in
  unsupported)
    printf 'ingest.sh FAIL: unsupported format for %s (use --format to override)\n' "$TRANSCRIPT" >&2
    exit 3
    ;;
  pdf)
    # PDFs aren't typical transcript shapes; require explicit --format if user really wants it.
    if [ -z "$FMT_OVERRIDE" ]; then
      printf 'ingest.sh FAIL: pdf detected; pass --format pdf explicitly to ingest as transcript\n' >&2
      exit 3
    fi
    ;;
esac

# --- normalization ---

# Granola path: parser emits JSON {title, date, participants[], body}.
# Other formats: parser emits cleaned plaintext on stdout.

TITLE_FROM_PARSER=""
DATE_FROM_PARSER=""
BODY=""
PARTICIPANTS_FROM_PARSER=""

if [ "$FORMAT" = "granola" ]; then
  granola_parser="$INGESTOR_PARSERS_DIR/granola.sh"
  if [ ! -f "$granola_parser" ]; then
    printf 'ingest.sh FAIL: granola parser not found: %s\n' "$granola_parser" >&2
    exit 2
  fi
  meta_json="$(bash "$granola_parser" "$TRANSCRIPT" 2>/dev/null || printf '{}\n')"
  if ! printf '%s' "$meta_json" | jq -e . >/dev/null 2>&1; then
    printf 'ingest.sh FAIL: granola parser emitted invalid JSON\n' >&2
    exit 2
  fi
  TITLE_FROM_PARSER="$(printf '%s' "$meta_json" | jq -r '.title // ""')"
  DATE_FROM_PARSER="$(printf '%s' "$meta_json" | jq -r '.date // ""')"
  BODY="$(printf '%s' "$meta_json" | jq -r '.body // ""')"
  PARTICIPANTS_FROM_PARSER="$(printf '%s' "$meta_json" | jq -r '.participants[]?' 2>/dev/null || true)"
else
  parser="$SEED_PARSERS_DIR/$FORMAT.sh"
  if [ ! -f "$parser" ]; then
    printf 'ingest.sh FAIL: no parser for format=%s at %s\n' "$FORMAT" "$parser" >&2
    exit 2
  fi
  BODY="$(bash "$parser" "$TRANSCRIPT" 2>/dev/null || printf '')"
fi

# --- participant extraction (post-normalization, when not granola-supplied) ---

_extract_participants() {
  local body="$1"
  # Match leading speaker labels: "Name:", "First Last:", "Pierre-Olivier:", "Speaker 1:".
  # Filter common false-positives via post-grep allowlist of patterns.
  printf '%s\n' "$body" \
    | grep -oE '^(Speaker [0-9]+|[A-Z][A-Za-z-]+([ ][A-Z][A-Za-z-]+)?):' 2>/dev/null \
    | sed 's/:$//' \
    | grep -vE '^(WEBVTT|NOTE|STYLE|REGION|Cue|Chapter|Date|Time|Subject|From|To|Topic)$' \
    | sort -u
}

if [ -n "$PARTICIPANTS_FROM_PARSER" ]; then
  PARTICIPANTS="$PARTICIPANTS_FROM_PARSER"
else
  PARTICIPANTS="$(_extract_participants "$BODY" || true)"
fi

# --- title + date resolution ---

_filename_stem() {
  local f
  f="$(basename "$1")"
  # Strip extension(s); also strip leading YYYY-MM-DD-{space|-}.
  f="${f%.*}"
  # If filename has multiple dots (granola.json), strip again.
  case "$f" in
    *.granola) f="${f%.granola}" ;;
  esac
  # Strip leading date prefix.
  printf '%s' "$f" | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}[- _]*//'
}

if [ -n "$TITLE_OVERRIDE" ]; then
  TITLE="$TITLE_OVERRIDE"
elif [ -n "$TITLE_FROM_PARSER" ]; then
  TITLE="$TITLE_FROM_PARSER"
else
  TITLE="$(_filename_stem "$TRANSCRIPT")"
  [ -n "$TITLE" ] || TITLE="Meeting Note"
fi

_filename_date() {
  local b
  b="$(basename "$1")"
  printf '%s' "$b" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1
}

_isodate_only() {
  # Strip a possible time component from an ISO timestamp.
  printf '%s' "$1" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1
}

if [ -n "$DATE_OVERRIDE" ]; then
  DATE="$DATE_OVERRIDE"
elif [ -n "$DATE_FROM_PARSER" ]; then
  DATE="$(_isodate_only "$DATE_FROM_PARSER")"
  [ -n "$DATE" ] || DATE="$DATE_FROM_PARSER"
else
  DATE="$(_filename_date "$TRANSCRIPT")"
  if [ -z "$DATE" ]; then
    # mtime fallback: BSD date (-r), GNU date (-d @epoch).
    if date -r "$TRANSCRIPT" -u +%Y-%m-%d >/dev/null 2>&1; then
      DATE="$(date -r "$TRANSCRIPT" -u +%Y-%m-%d)"
    else
      epoch="$(stat -f %m "$TRANSCRIPT" 2>/dev/null || stat -c %Y "$TRANSCRIPT" 2>/dev/null || printf '')"
      if [ -n "$epoch" ]; then
        DATE="$(date -u -d "@$epoch" +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)"
      else
        DATE="$(date -u +%Y-%m-%d)"
      fi
    fi
  fi
fi

# --- frontmatter assembly ---

# 1. Provenance fields: inline printf for the two
# generated lines that pf_emit used to produce. provenance-frontmatter.sh is
# DROPPED entirely — never sourced. generated_by names this surface; generated_
# from names the source transcript. (source_path / source_format are emitted
# separately below in _emit_note — they are not pf-only fields.)
PF_GENERATED_FROM_ESC="$(printf '%s' "$TRANSCRIPT" | sed 's/\\/\\\\/g; s/"/\\"/g')"
PF_INNER="$(printf 'generated_by: %s\ngenerated_from: "%s"' "$SURFACE_ID" "$PF_GENERATED_FROM_ESC")"

# 2. Meeting-note fields. YAML escape for title (double-quote-safe).
_yaml_escape_dq() {
  # Escape backslashes and double-quotes.
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}
TITLE_ESC="$(_yaml_escape_dq "$TITLE")"
SOURCE_PATH_ESC="$(_yaml_escape_dq "$TRANSCRIPT")"

# 3. Participants list as YAML.
_emit_participants_yaml() {
  if [ -z "$PARTICIPANTS" ]; then
    printf 'participants: []\n'
    return 0
  fi
  printf 'participants:\n'
  printf '%s\n' "$PARTICIPANTS" | while IFS= read -r p; do
    [ -z "$p" ] && continue
    p_esc="$(_yaml_escape_dq "$p")"
    printf '  - "%s"\n' "$p_esc"
  done
}

# --- emit structured note ---

_emit_note() {
  printf -- '---\n'
  # PF_INNER from awk-strip lacks the trailing newline (command-substitution
  # eats it); explicitly append one so the next field starts on its own line.
  printf '%s\n' "$PF_INNER"
  printf 'title: "%s"\n' "$TITLE_ESC"
  printf 'date: %s\n' "$DATE"
  printf 'source_format: %s\n' "$FORMAT"
  printf 'source_path: "%s"\n' "$SOURCE_PATH_ESC"
  _emit_participants_yaml
  printf -- '---\n'
  printf '\n'
  printf '# %s\n' "$TITLE"
  printf '\n'
  if [ -n "$BODY" ]; then
    # Trim trailing blanks; normalize CRLF.
    printf '%s' "$BODY" | tr -d '\r' | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}'
    printf '\n'
  else
    printf '_(empty transcript body)_\n'
  fi
}

case "$OUTPUT" in
  -|"")
    _emit_note
    ;;
  *)
    out_dir="$(dirname "$OUTPUT")"
    [ -d "$out_dir" ] || mkdir -p "$out_dir"
    _emit_note > "$OUTPUT"
    ;;
esac

exit 0
