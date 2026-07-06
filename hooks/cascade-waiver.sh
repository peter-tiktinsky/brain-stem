# cascade-waiver.sh — Canonical writer for $HOOKS_STATE/cascade-waivers.json.
# Home: hooks/cascade-waiver.sh (top-level), so the install-time
# lib/→hooks/lib/ translation does NOT apply here.
# Single forward-looking writer for cascade-rule waivers. Every agent / skill /
# hook that files a waiver must source this file and call `cascade_waiver_write`.
# Reads tolerate four historical drift shapes for back-compat; writes always
# emit the canonical sessions.<id>.waivers[] form documented below.
# Usage:
#   source "${CLAUDE_HOME:-$HOME/.claude}/hooks/cascade-waiver.sh"
#   cascade_waiver_write <entry_id> <reason> [ttl_days]
#   Optional env: CLAUDE_SESSION_ID (preferred). If unset, caller may set
#   CASCADE_WAIVER_SESSION_ID for a deterministic label. If neither is set,
#   helper falls back to "unknown-$(date +%s)".
# Shape contract (CANONICAL — all future writes use this shape):
#     "sessions": {
#       "<session-id>": {
#         "waivers": [
#           { "entry_id": "<registered-dep-id>",
#             "reason": "<free-text justification>",
#             "ts": "<YYYY-MM-DDTHH:MM:SS±HH:MM>",
#             "expires_at": "<YYYY-MM-DDTHH:MM:SS±HH:MM>" },
# Waivers carry expires_at — a TTL after which the waiver no longer
# suppresses the cascade (consumers MUST treat an expired waiver as absent and
# re-surface the dependency). Default TTL = 30 days from ts; override with the
# optional ttl_days arg or CASCADE_WAIVER_TTL_DAYS env. expires_at is additive:
# reads of legacy waivers without the field treat them as non-expiring for
# back-compat.
# Bash 3.2 clean per R-23. Atomic writes via temp-file + mv.

# Idempotent paths.sh source guard. Resolve via $SCRIPT_DIR-relative lib (this
# file ships at hooks/; lib lives at hooks/lib/) — portable.
if [[ -z "${HOOKS_STATE:-}" ]]; then
  _cw_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck source=/dev/null
  source "$_cw_dir/lib/paths.sh"
  unset _cw_dir
fi

CASCADE_WAIVER_PATH="${CASCADE_WAIVER_PATH:-$HOOKS_STATE/cascade-waivers.json}"
CASCADE_WAIVER_TTL_DAYS="${CASCADE_WAIVER_TTL_DAYS:-30}"

# cascade_waiver_write <entry_id> <reason> [ttl_days]
# Appends one waiver in canonical shape (with expires_at) under the resolved
# session id. Prints the resolved session id to stdout on success.
cascade_waiver_write() {
  local entry_id="$1"
  local reason="$2"
  local ttl_days="${3:-$CASCADE_WAIVER_TTL_DAYS}"
  if [[ -z "$entry_id" ]] || [[ -z "$reason" ]]; then
    echo "cascade_waiver_write: entry_id and reason required" >&2
    return 1
  fi
  local sid="${CLAUDE_SESSION_ID:-${CASCADE_WAIVER_SESSION_ID:-unknown-$(date +%s)}}"
  local ts expires_at
  ts=$(date +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\(..\)$/:\1/')
  # expires_at = ts + ttl_days. Computed in UTC-offset-preserving local time via
  # epoch arithmetic (macOS date -v / -r).
  local now_epoch exp_epoch
  now_epoch=$(date +%s)
  exp_epoch=$(( now_epoch + ttl_days * 86400 ))
  expires_at=$(date -r "$exp_epoch" +"%Y-%m-%dT%H:%M:%S%z" 2>/dev/null | sed 's/\(..\)$/:\1/')
  [[ -z "$expires_at" ]] && expires_at="$ts"  # degrade: never-write an empty field
  local tmp="${CASCADE_WAIVER_PATH}.tmp.$$"
  python3 - "$CASCADE_WAIVER_PATH" "$sid" "$entry_id" "$reason" "$ts" "$tmp" "$expires_at" <<'PY'
import json, os, sys
path, sid, eid, reason, ts, tmp, expires_at = sys.argv[1:8]
try:
    with open(path) as f:
        doc = json.load(f)
except Exception:
    doc = {}

waiver = {"entry_id": eid, "reason": reason, "ts": ts, "expires_at": expires_at}

# Resolve the current entries list for this session, normalizing any of the
# 4 historical drift shapes to the canonical sessions.<sid>.waivers[] form.
entries = None

if isinstance(doc.get("sessions"), dict):
    slot = doc["sessions"].get(sid)
    if isinstance(slot, dict) and isinstance(slot.get("waivers"), list):
        entries = slot["waivers"]
    elif isinstance(slot, list):
        entries = [e for e in slot if isinstance(e, dict)]
        doc["sessions"][sid] = {"waivers": entries}
else:
    doc["sessions"] = {}

if sid in doc and sid not in doc["sessions"]:
    legacy = doc.pop(sid)
    if isinstance(legacy, dict) and isinstance(legacy.get("waivers"), list):
        entries = [e for e in legacy["waivers"] if isinstance(e, dict)]
    elif isinstance(legacy, list):
        entries = []
        for item in legacy:
            if isinstance(item, dict):
                if "waivers" in item and isinstance(item["waivers"], list):
                    entries.extend(e for e in item["waivers"] if isinstance(e, dict))
                else:
                    entries.append(item)
    doc["sessions"][sid] = {"waivers": entries or []}

if entries is None:
    doc["sessions"][sid] = {"waivers": []}
    entries = doc["sessions"][sid]["waivers"]

entries.append(waiver)

with open(tmp, "w") as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
os.replace(tmp, path)
PY
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "cascade_waiver_write: python write failed (rc=$rc)" >&2
    return $rc
  fi
  echo "$sid"
}
