#!/bin/bash
# hooks/lib/derive-description.sh — SHARED one-line description-derivation helper.
# Emits a single trimmed one-line description (<=200 chars) for a note to stdout.
# Derivation order (most-optimal-level-of-effort, per the FROZEN decision #3):
#   1. HEURISTIC (zero AI cost) — the first H1 heading, else the first prose line
#      of the body (frontmatter stripped). This covers the overwhelming majority.
#   2. CHEAP MODEL (Haiku-class, OPT-IN) — only when the heuristic is weak AND
#      DERIVE_DESC_MODEL=1 AND the `claude` CLI is present. OFF by default so the
#      write-time auto-stamp path stays deterministic + fast; the frontmatter-enforce
#      --fix backfill (a batch/opt-in context) may enable it.
#   3. DETERMINISTIC FALLBACK — the filename stem, so the helper is never empty.
# Consumers (SHARED — one derivation contract, two callers):
#   - hooks/post-write-verify.sh forward-governance cohort auto-stamp (T-7)
#   - skills/librarian/capabilities/frontmatter-enforce.sh --fix backfill (T-8)
# Usage: derive-description.sh <file_path>   (the file must exist on disk)
# Bash 3.2 clean (R-23). Argv-based python heredoc (R-24). Never fails hard.
set -uo pipefail

FILE="${1:-}"
[ -n "$FILE" ] || { printf '\n'; exit 0; }
[ -f "$FILE" ] || { printf '\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf '\n'; exit 0; }

# Heredoc python is run as a BARE command (NOT inside $()): bash 3.2 mis-parses a
# heredoc nested in command substitution (R-24 argv-heredoc precedent — same as
# memory-auto-stamp.sh). Output is routed through a temp file, then read.
_dd_tmp="$(mktemp 2>/dev/null || echo "")"
DESC=""
if [ -n "$_dd_tmp" ]; then
  python3 - "$FILE" > "$_dd_tmp" 2>/dev/null <<'PY'
import sys, re
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        text = fh.read()
except Exception:
    print(""); sys.exit(0)
# Strip a leading YAML frontmatter block.
if text.startswith("---\n"):
    end = text.find("\n---", 3)
    if end != -1:
        text = text[end + 4:]
def clean(s):
    s = re.sub(r"\s+", " ", s.strip())
    return s[:200].rstrip()
lines = text.split("\n")
# 1) first H1 heading
for ln in lines:
    m = re.match(r"^#\s+(.+?)\s*$", ln)
    if m:
        t = clean(m.group(1))
        if len(t) >= 3:
            print(t); sys.exit(0)
# 2) first non-blank, non-heading, non-structural prose line
for ln in lines:
    s = ln.strip()
    if not s:
        continue
    if s[:1] in ("#", "|", ">") or s.startswith("<!--") or s.startswith("- ") \
       or s.startswith("* ") or s.startswith("```") or s.startswith("---"):
        continue
    t = clean(s)
    if len(t) >= 3:
        print(t); sys.exit(0)
print("")
PY
  DESC="$(head -1 "$_dd_tmp" 2>/dev/null || true)"
  rm -f "$_dd_tmp"
fi

# 2) Cheap-model fallback — OPT-IN only (OFF at write-time for determinism/speed).
if [ -z "$DESC" ] && [ "${DERIVE_DESC_MODEL:-0}" = "1" ] && command -v claude >/dev/null 2>&1; then
  _dd_body="$(sed -n '1,80p' "$FILE" 2>/dev/null || true)"
  _dd_out="$(printf 'In ONE plain sentence (<=160 chars, no preamble, no surrounding quotes), describe what this note is about:\n\n%s\n' "$_dd_body" \
    | claude -p --model haiku 2>/dev/null | head -1 || true)"
  _dd_out="$(printf '%s' "$_dd_out" | tr -d '\r' | sed -e 's/^["'"'"' ]*//' -e 's/["'"'"' ]*$//')"
  [ -n "$_dd_out" ] && DESC="$(printf '%s' "$_dd_out" | cut -c1-200)"
fi

# 3) Deterministic final fallback (never empty): the filename stem.
if [ -z "$DESC" ]; then
  _dd_base="${FILE##*/}"; _dd_base="${_dd_base%.md}"
  _dd_base="$(printf '%s' "$_dd_base" | tr '_-' '  ')"
  DESC="Notes on ${_dd_base}."
fi

printf '%s\n' "$DESC"
exit 0
