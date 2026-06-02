# dates.sh — BSD/GNU-portable date math helpers for librarian capabilities.
#
# Co-shipped with the `log-archive` capability extraction. Provides shell-level
# date operations for capabilities that walk the filesystem in bash (as opposed
# to Python-heredoc capabilities like stale-detect, which do date math inline in
# Python and do not need this helper).
#
# Usage:
#   source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/dates.sh"
#   now=$(iso_now)
#   age=$(days_since "2026-04-14")
#   if is_stale "$file" 30; then ...; fi
#   ww=$(week_of_year "2026-04-21")
#
# Consumers:
#   - capabilities/log-archive.sh   (week_of_year + days_since)
#
# Scope note: Python-heredoc capabilities (stale-detect, plan-index, etc.)
# do their date math inline in Python and correctly do not source this
# helper. The shell/Python abstraction boundary makes sourcing here a no-op
# for those capabilities. This helper's scope is strictly shell-level
# consumers.
#
# Bash 3.2 clean per R-23 (macOS /bin/bash). Python fallback for week_of_year
# because BSD and GNU `date` disagree on `%V` in certain edge cases;
# Python's datetime.isocalendar() is authoritative. days_since uses Python
# for the same portability guarantee.

# Idempotent paths.sh source guard — matches hooks/lib/manifest.sh pattern.
if [[ -z "${VAULT_LOGS:-}" ]]; then
  # shellcheck source=/dev/null
  source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh" 2>/dev/null \
    || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/paths.sh"
fi

# iso_now — UTC ISO-8601 timestamp to the second.
# Matches manifest_iso_now output shape exactly for cross-consumer consistency.
iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%S"
}

# days_since <YYYY-MM-DD>
# Integer days between input date and today. Empty/malformed input → -1.
# Python-backed for BSD/GNU portability.
days_since() {
  local input="${1:-}"
  if [[ -z "$input" ]]; then
    printf '%s' "-1"
    return 0
  fi
  python3 - "$input" <<'PY' 2>/dev/null || printf '%s' "-1"
import sys
from datetime import date
try:
    y, m, d = sys.argv[1].strip()[:10].split("-")
    target = date(int(y), int(m), int(d))
    today = date.today()
    print((today - target).days)
except Exception:
    print(-1)
PY
}

# is_stale <file> <day-threshold>
# Exit 0 (stale) if the file's frontmatter `updated:` field (or mtime
# fallback) is older than <day-threshold> days. Exit 1 (fresh) otherwise
# or if file missing.
is_stale() {
  local file="${1:-}"
  local threshold="${2:-}"
  if [[ ! -f "$file" ]] || [[ -z "$threshold" ]]; then
    return 1
  fi
  python3 - "$file" "$threshold" <<'PY' 2>/dev/null
import sys, os, re, time
from datetime import date
path = sys.argv[1]
try:
    threshold = int(sys.argv[2])
except ValueError:
    sys.exit(1)
try:
    with open(path, "rb") as f:
        head = f.read(4096).decode("utf-8", errors="ignore")
    m = re.search(r'^updated:\s*["\']?(\d{4}-\d{2}-\d{2})', head, re.MULTILINE)
    if m:
        y, mo, d = m.group(1).split("-")
        diff = (date.today() - date(int(y), int(mo), int(d))).days
    else:
        diff = int((time.time() - os.path.getmtime(path)) / 86400)
    sys.exit(0 if diff > threshold else 1)
except Exception:
    sys.exit(1)
PY
}

# week_of_year <YYYY-MM-DD>
# ISO-8601 week number (01-53) as 2-digit zero-padded string.
# Python-backed — BSD/GNU `date -d %V` disagree on year-boundary weeks.
week_of_year() {
  local input="${1:-}"
  if [[ -z "$input" ]]; then
    printf '%s' "00"
    return 0
  fi
  python3 - "$input" <<'PY' 2>/dev/null || printf '%s' "00"
import sys
from datetime import date
try:
    y, m, d = sys.argv[1].strip()[:10].split("-")
    iso_year, iso_week, _ = date(int(y), int(m), int(d)).isocalendar()
    print("%02d" % iso_week)
except Exception:
    print("00")
PY
}
