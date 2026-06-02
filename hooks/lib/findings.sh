# hooks/lib/findings.sh — Canonical finding-emission contract for librarian
# capabilities (and any hook that surfaces drift findings).
#
# This file IS the finding contract. There is no
# `schemas/librarian-finding-schema.json`: that schema does NOT exist and is
# NOT created — the shape a finding takes is whatever emit_finding / emit_event
# produce here. The librarian capabilities source THIS helper for finding
# emission; no standalone finding JSON Schema ships.
#
# Source it — do not execute it:
#   source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/findings.sh"
#   emit_finding <name> <file> [<key> <value> ...]
#   emit_event '<raw JSON line>'
#
# findings.sh lives at hooks/lib/findings.sh alongside the path/registry
# substrate (hooks/lib/paths.sh + hooks/lib/registry.sh). The source-repo
# lib/ is translated to the install hooks/lib/ home.
#
# Output routing: if the FINDINGS_OUTPUT env var is set and non-empty, append
# each line to that file; otherwise echo to stdout. Mirrors the inline
# OUTPUT-or-stdout pattern the extracted capabilities reimplemented before the
# helper was consolidated.
#
# Finding shape (emit_finding):
#   { "finding": "<name>", "file": "<file>"[, "<k>": "<v>" ...] }
#
# All emit_finding values are wrapped as JSON strings. For numeric/boolean
# values or nested objects, pre-format the JSON line and pass it via
# emit_event instead (the line is emitted verbatim).
#
# Failure mode: block-and-log, never write-and-hope. emit_finding/emit_event
# never mutate vault or governance content — they only append a finding line
# to FINDINGS_OUTPUT or stdout. A capability that cannot validate its inputs
# MUST abort (exit non-zero) BEFORE emitting findings, rather than emit
# findings against a malformed input set.
#
# Bash 3.2 clean per R-23: no associative arrays, no ${var,,} case-conversion,
# no readarray/mapfile, no =~ capture groups.

# emit_event — emit one pre-formatted JSON line to FINDINGS_OUTPUT or stdout.
emit_event() {
  local payload="$1"
  if [ -n "${FINDINGS_OUTPUT:-}" ]; then
    printf '%s\n' "$payload" >> "$FINDINGS_OUTPUT"
  else
    printf '%s\n' "$payload"
  fi
}

# _json_escape — escape a value for inclusion as a JSON string literal.
# Handles backslash, double-quote, tab, carriage-return and newline so a
# finding payload carrying user-derived text cannot break the JSON line.
_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//	/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# emit_finding — emit a structured finding line. The first two positional args
# are the finding name + the file/subject; remaining args are key/value pairs.
emit_finding() {
  local name file json k v
  name="$(_json_escape "$1")"
  file="$(_json_escape "$2")"
  shift 2
  json="{ \"finding\": \"${name}\", \"file\": \"${file}\""
  while [ $# -ge 2 ]; do
    k="$(_json_escape "$1")"
    v="$(_json_escape "$2")"
    json="${json}, \"${k}\": \"${v}\""
    shift 2
  done
  json="${json} }"
  emit_event "$json"
}
