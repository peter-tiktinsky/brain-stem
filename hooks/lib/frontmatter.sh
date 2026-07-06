# frontmatter.sh — shared YAML frontmatter parsing for librarian capabilities.
# First consumer: plan-parent-resolve. Existing capabilities inline their own
# awk/grep/sed combos; migration to this helper is deferred to a future
# librarian-internal consolidation session.
# Usage:
#   source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/frontmatter.sh"
#   fm_has_frontmatter "$file"
#   val=$(fm_get_field "$file" "parent_plan")
#   fm_has_field "$file" "status" && echo "has status"
# Contract:
# - All functions are read-only.
# - All functions tolerate missing files (return 1 / empty).
# - fm_get_field reads only the YAML frontmatter block (between the first two
#   `---` lines). It does NOT read body content even if the body has `key: val`
#   lines. This prevents false matches on prose.
# - fm_get_field strips surrounding whitespace and trailing comments, but does
#   NOT unquote values. Consumers handle quotes if needed.
# - Bash 3.2 clean per R-23 (macOS /bin/bash compatibility).

fm_has_frontmatter() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  head -n 1 "$file" 2>/dev/null | grep -qE '^---[[:space:]]*$'
}

fm_get_field() {
  local file="$1" field="$2"
  [[ -f "$file" ]] || return 1
  [[ -n "$field" ]] || return 1
  awk -v f="$field" '
    BEGIN { n = 0 }
    /^---[[:space:]]*$/ {
      n++
      if (n >= 2) exit
      next
    }
    n == 1 {
      # Match "field:" at start of line, capture value
      if ($0 ~ "^"f"[[:space:]]*:") {
        # Strip "field:" prefix
        sub("^"f"[[:space:]]*:[[:space:]]*", "")
        # Strip trailing whitespace
        sub("[[:space:]]+$", "")
        # : coerce bare YAML null tokens to empty (mirrors the JSON path,
        # which turns JSON null into "" via an isinstance(str) check). A quoted
        # "null" is a legitimate string value and is NOT coerced — it retains its
        # quotes here because the parser does not unquote.
        if ($0 == "null" || $0 == "Null" || $0 == "NULL" || $0 == "~") {
          $0 = ""
        }
        print
        exit
      }
    }
  ' "$file"
}

fm_has_field() {
  local v
  v=$(fm_get_field "$1" "$2")
  [[ -n "$v" ]]
}
