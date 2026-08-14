#!/bin/bash
# library-log-rotate — the librarian (rotation/audit) half of the composite
# composite maintainer for the library global change log _library/log.md.
#
# disjoint-surface contract: the appender HOOK (hooks/library-log-append.sh)
# is the SOLE appender of routine entries; THIS librarian capability owns rotation,
# audit, and any full re-derive — and NEVER appends a routine entry. The two
# surfaces are disjoint by construction (append-tail vs. rotate/rebuild).
#
# Rotation (size_limits {max_lines: 2000, split_strategy: rotate to
# log-archive/<YYYY>.md at threshold} — calibrated to one-liner density, NOT the
# handoff block-entry cap): when log.md exceeds the threshold, the event lines are
# MOVED out of the live log into per-year archives _library/log-archive/<YYYY>.md
# (grouped by each line's ISO-date year), the C-FM-LOG frontmatter is preserved,
# and the live log continues fresh (frontmatter + a rotation-marker line) so the
# appender keeps appending to a small live tail. Each per-year archive is itself a
# C-FM-LOG log artifact (type: log, log-type: library-change) so it stays a
# governed surface, compliant with R-47 and R-05.
#
# Audit: emits a rotation finding (how many lines moved, to which archives) and a
# rotation-not-due finding when invoked under threshold (idempotent no-op).
#
# Output Contract (per CLAUDE.md skill-creation rule):
#   Files written (ONLY when over threshold):
#     - {LIBRARY}/log-archive/<YYYY>.md   the rotated-out event lines for year
#                                          <YYYY> (created or appended; each
#                                          carries C-FM-LOG frontmatter). Atomic.
#     - {LIBRARY}/log.md                   reset to frontmatter + a rotation
#                                          marker; the live tail continues. Atomic.
#     - librarian-finding NDJSON to stdout (or $FINDINGS_OUTPUT).
#   Schema: governance/frontmatter-rules.json#types.log (the strict-tier log
#     contract every archive + the live log conform to).
#   Pre-write validation:
#     - the library home + log.md must resolve (absent -> block-and-log, exit 0,
#       never crash — nothing to rotate).
#     - under threshold -> rotation-not-due finding, ZERO writes (idempotent).
#     - atomic temp+os.replace on every write.
#   Failure mode: BLOCK-AND-LOG. A malformed log emits a finding and writes
#     nothing. Never write-and-hope.
#   Maintainer-provenance: this capability writes ONLY the
#     rotation/archive role surface of the composite. It NEVER appends a routine
#     event line (the hook owns that); it rotates + audits only.
#
# CLI:
#   library-log-rotate.sh             # rotate when over threshold (default)
#   library-log-rotate.sh --dry-run   # report would-rotate counts; NO writes
#   library-log-rotate.sh --help
#
# Env overrides (testing):
#   LIBRARY_DIR    library home (default: $PLANS_DIR/_library -> $PLANS_ROOT/_library).
#   PLANS_DIR / PLANS_ROOT  plan-tree root (test isolation; resolved via paths.sh).
#   LOG_MAX_LINES  rotation threshold (default 2000 per size_limits).
#   FINDINGS_OUTPUT  NDJSON sink (default: stdout).
#
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24.

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_ROOT="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)"
_REPO_LIB="$_REPO_ROOT/hooks/lib"

if [[ -z "${PLANS_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; } || true
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || { [ -r "$_REPO_LIB/findings.sh" ] && source "$_REPO_LIB/findings.sh"; } || true

DRY_RUN="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) sed -n '2,57p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "library-log-rotate: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

PLANS_ROOT="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac
LIBRARY="${LIBRARY_DIR:-${PLANS_DIR:-$PLANS_ROOT}/_library}"
case "$LIBRARY" in */) LIBRARY="${LIBRARY%/}" ;; esac

LOG_MD="$LIBRARY/log.md"
LOG_MAX_LINES="${LOG_MAX_LINES:-2000}"

# resolve the governance dir + composed bundle so the body
# READS its two DECLARED deps (governance/frontmatter-rules.json types.log +
# governance/log-subtype-registry.json) instead of hardcoding the C-FM-LOG template
# + LOG_SUBTYPE. CLAUDE_HOME-first, repo fallback. READ-ONLY consume — neither pillar
# is edited, so NO master rebuild. log-subtype-registry.json ships standalone;
# frontmatter-rules.json is a repo-only pillar composed into foundation-master
# (.frontmatter.types.log) so the python body reads the loose pillar first, else the bundle.
GOV_DIR="${GOVERNANCE_DIR:-}"
if [ -z "$GOV_DIR" ] || [ ! -d "$GOV_DIR" ]; then
  for cand in "$CLAUDE_HOME_RES/governance" "$_REPO_ROOT/governance"; do
    [ -d "$cand" ] && { GOV_DIR="$cand"; break; }
  done
fi
BUNDLE=""
for cand in \
  "$CLAUDE_HOME_RES/governance/foundation-master.json" \
  "$GOV_DIR/foundation-master.json"; do
  [ -f "$cand" ] && { BUNDLE="$cand"; break; }
done

# Canonical governance read: route the foundation-master read through the
# R-52 union-load merger (hooks/lib/foundation-overlay-load.sh) so an adopter's overlay-master
# amendments to .frontmatter.types.log are honored — never consume foundation-master RAW.
# Materialize the merged union once and redirect $BUNDLE at it; the python body reads
# .frontmatter.types.log from the merged view. Degrades to the raw bundle if the merger is
# unavailable (loud-safe), and to the loose frontmatter-rules.json pillar under $GOV_DIR when
# the bundle is absent (dev-repo authoring). log-subtype-registry.json is a standalone-shipped
# registry (NOT a bundle slot; not one of the 7 R-52 pillars) read directly, matching the
# log-subtype-canonical read precedent.
_OVL="${FOUNDATION_OVERLAY_LOAD:-$CLAUDE_HOME_RES/hooks/lib/foundation-overlay-load.sh}"
[ -x "$_OVL" ] || _OVL="$_REPO_ROOT/hooks/lib/foundation-overlay-load.sh"
if [ -x "$_OVL" ] && [ -n "$BUNDLE" ] && [ -f "$BUNDLE" ]; then
  _UNION="$(mktemp 2>/dev/null || true)"
  if [ -n "$_UNION" ] && bash "$_OVL" --foundation-path "$BUNDLE" \
        --overlay-path "$(dirname "$BUNDLE")/overlay-master.json" --force-override > "$_UNION" 2>/dev/null \
        && [ -s "$_UNION" ]; then
    BUNDLE="$_UNION"; trap 'rm -f "$_UNION"' EXIT
  elif [ -n "$_UNION" ]; then rm -f "$_UNION"; fi
fi

python3 - "$LIBRARY" "$LOG_MD" "$LOG_MAX_LINES" "$DRY_RUN" "${GOV_DIR:-}" "${BUNDLE:-}" <<'PY'
import json, os, re, sys, tempfile
from datetime import date, datetime, timezone

library, log_md, max_lines_s, dry_s = sys.argv[1:5]
gov_dir = sys.argv[5] if len(sys.argv) > 5 else ""
bundle_path = sys.argv[6] if len(sys.argv) > 6 else ""
dry_run = (dry_s == "true")
try:
    max_lines = int(max_lines_s)
except ValueError:
    max_lines = 2000

out = os.environ.get("FINDINGS_OUTPUT", "")
today = date.today().isoformat()
now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
LOG_SUBTYPE = "library-change"

# READ the two DECLARED governance deps instead of hardcoding
# the C-FM-LOG template. (1) log-subtype-registry.json — validate LOG_SUBTYPE is a
# registered log subtype (block-and-log below if absent; never emit a non-registered
# subtype). (2) frontmatter-rules.json types.log — derive the emitted frontmatter's
# FIELD SET (required ++ optional) from the strict-tier log contract, so governed log
# frontmatter can no longer drift silently from the contract. READ-ONLY consume.
def _load_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None

# log-subtype-registry.json ships standalone under governance/ (bundle-composed only
# if the loose file is unavailable is NOT applicable — it does not compose into the
# master; read it from gov_dir, repo fallback handled by the bash resolver).
_registered = set()
if gov_dir:
    _reg = _load_json(os.path.join(gov_dir, "log-subtype-registry.json"))
    if isinstance(_reg, dict) and isinstance(_reg.get("log_subtypes"), list):
        for _s in _reg["log_subtypes"]:
            if isinstance(_s, dict) and _s.get("subtype"):
                _registered.add(_s["subtype"])

# frontmatter-rules.json types.log — loose pillar (gov_dir) first, then the composed
# bundle (.frontmatter.types.log). Degrade to the deterministic floor below (which IS
# the shipped types.log contract, byte-for-byte) only when NEITHER resolves — a dead
# branch in any real install (frontmatter-rules.json always ships). This floor is
# deliberately quiet; the loud block-and-log requirement applies to the
# log-subtype-registry check, not this resolution chain.
_types_log = None
if gov_dir:
    _fr = _load_json(os.path.join(gov_dir, "frontmatter-rules.json"))
    if isinstance(_fr, dict):
        _types_log = (_fr.get("types") or {}).get("log")
if _types_log is None and bundle_path:
    _bundle = _load_json(bundle_path)
    if isinstance(_bundle, dict):
        _types_log = ((_bundle.get("frontmatter") or {}).get("types") or {}).get("log")
if isinstance(_types_log, dict):
    _fm_required = [f for f in (_types_log.get("required") or []) if isinstance(f, str)]
    _fm_optional = [f for f in (_types_log.get("optional") or []) if isinstance(f, str)]
else:
    _fm_required = ["type", "log-type", "date", "timestamp"]
    _fm_optional = ["tags"]

# event-line shape: YYYY-MM-DDTHH:MM:SSZ [ACTION] <path> — <note>
EVENT_RE = re.compile(r"^(\d{4})-\d{2}-\d{2}T[0-9:]+Z?\s+\[[A-Z]+\]\s+\S+")

def emit(d):
    line = json.dumps(d, ensure_ascii=False)
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

def atomic_write(target, content):
    d = os.path.dirname(target) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix="._logrot.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(content)
        os.replace(tmp, target)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise

def log_frontmatter(title, blurb):
    # the emitted frontmatter FIELD SET is DERIVED from the types.log contract
    # (required ++ optional), not a hardcoded template. Each field is populated from
    # the value provider; a REQUIRED contract field with no known value is emitted as
    # an empty placeholder so the drift is VISIBLE (a required field is never omitted),
    # while an unknown OPTIONAL field is skipped. The real contract (required
    # [type,log-type,date,timestamp] + optional [tags]) reproduces the prior template
    # byte-for-byte; a contract change (added/removed field) is now reflected.
    provider = {
        "type": "log",
        "log-type": LOG_SUBTYPE,
        "date": today,
        "timestamp": now_iso,
        "tags": "[\"#log/%s\"]" % LOG_SUBTYPE,
        "subtype": LOG_SUBTYPE,
    }
    lines = ["---"]
    seen = set()
    for field in list(_fm_required) + list(_fm_optional):
        if field in seen:
            continue
        seen.add(field)
        if field in provider:
            lines.append("%s: %s" % (field, provider[field]))
        elif field in _fm_required:
            lines.append("%s:" % field)
    lines.append("---")
    lines += ["", "# %s" % title, "", blurb, ""]
    return "\n".join(lines) + "\n"

# --- block-and-log: nothing to rotate ---------------------------------------
if not os.path.isfile(log_md):
    emit({"finding": "library-log-rotate-blocked", "file": log_md,
          "reason": "log-absent", "detected_at": today})
    print("library-log-rotate: log.md absent (%s); nothing to rotate" % log_md,
          file=sys.stderr)
    sys.exit(0)

try:
    with open(log_md, encoding="utf-8") as fh:
        text = fh.read()
except OSError as exc:
    emit({"finding": "library-log-rotate-blocked", "file": log_md,
          "reason": "read-failed", "error": str(exc), "detected_at": today})
    sys.exit(0)

total_lines = sum(1 for _ in text.splitlines())

# --- under threshold -> idempotent no-op ------------------------------------
if total_lines <= max_lines:
    emit({"finding": "library-log-rotation-not-due", "file": log_md,
          "lines": total_lines, "max_lines": max_lines, "detected_at": today})
    print("library-log-rotate: %d <= %d lines; rotation not due" % (total_lines, max_lines),
          file=sys.stderr)
    sys.exit(0)

# --- split the live log: frontmatter (kept) vs event lines (rotated out) -----
# Frontmatter is everything up to and including the closing --- fence; the
# preamble prose between the fence and the first event line is kept on the live
# log. Event lines (the ones matching EVENT_RE) are the rotation payload.
lines = text.split("\n")
# locate the frontmatter close fence
fm_end = -1
if lines and lines[0].strip() == "---":
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            fm_end = i
            break

event_lines = []
kept_preamble = []
for idx, ln in enumerate(lines):
    if fm_end >= 0 and idx <= fm_end:
        continue  # frontmatter body — handled by reseeding the live log below
    if EVENT_RE.match(ln):
        event_lines.append(ln)
    else:
        # non-event prose (the bootstrap blurb) — keep it on the live log
        if ln.strip():
            kept_preamble.append(ln)

if not event_lines:
    emit({"finding": "library-log-rotation-not-due", "file": log_md,
          "lines": total_lines, "max_lines": max_lines,
          "reason": "over-line-count-but-no-event-lines-to-rotate",
          "detected_at": today})
    print("library-log-rotate: over threshold but no event lines; no-op",
          file=sys.stderr)
    sys.exit(0)

# group event lines by their ISO-date year
by_year = {}
for ln in event_lines:
    m = EVENT_RE.match(ln)
    yr = m.group(1) if m else "unknown"
    by_year.setdefault(yr, []).append(ln)

if dry_run:
    emit({"finding": "library-log-rotation-would-rotate", "file": log_md,
          "lines": total_lines, "max_lines": max_lines,
          "events": len(event_lines),
          "archives": ",".join(sorted("%s.md" % y for y in by_year)),
          "detected_at": today})
    print("library-log-rotate: DRY-RUN would rotate %d events -> %s"
          % (len(event_lines), ", ".join(sorted("%s.md" % y for y in by_year))),
          file=sys.stderr)
    sys.exit(0)

# block-and-log if LOG_SUBTYPE is not a registered log subtype —
# NEVER silently write a non-registered subtype's frontmatter. Enforced only when the
# registry actually RESOLVED (a non-empty registered set); an unresolvable registry
# degrades (cannot validate) rather than blocking every rotation.
if _registered and LOG_SUBTYPE not in _registered:
    emit({"finding": "library-log-subtype-unregistered", "file": log_md,
          "subtype": LOG_SUBTYPE,
          "reason": "subtype-absent-from-log-subtype-registry",
          "detected_at": today})
    print("library-log-rotate: subtype '%s' not registered; block-and-log (no write)"
          % LOG_SUBTYPE, file=sys.stderr)
    sys.exit(0)

archive_dir = os.path.join(library, "log-archive")
os.makedirs(archive_dir, exist_ok=True)
written_archives = []
for yr in sorted(by_year):
    arc_path = os.path.join(archive_dir, "%s.md" % yr)
    payload = "\n".join(by_year[yr]) + "\n"
    if os.path.isfile(arc_path):
        try:
            with open(arc_path, encoding="utf-8") as fh:
                cur = fh.read()
        except OSError:
            cur = ""
        if cur and not cur.endswith("\n"):
            cur += "\n"
        new_arc = cur + payload
    else:
        blurb = ("Rotated library change-log events for %s (split_strategy: "
                 "rotate to log-archive/<YYYY>.md). Append-only.") % yr
        new_arc = log_frontmatter("Library Change Log — %s" % yr, blurb) + payload
    atomic_write(arc_path, new_arc)
    written_archives.append(arc_path)

# --- reset the live log: frontmatter + preamble + a rotation marker ----------
# Reseed a fresh C-FM-LOG frontmatter (the live log continues from empty tail).
live_blurb = ("Global append-only change log for the library (per-article changelogs "
              "are killed). One ISO-timestamped line per promotion / amend / supersede "
              "event: `YYYY-MM-DDTHH:MM:SSZ [ACTION] <path> — <note>`. Rotates to "
              "`log-archive/<YYYY>.md` past %d lines." % max_lines)
live = log_frontmatter("Library Change Log", live_blurb)
# an AUDIT marker line records the rotation in the live log (this is the
# librarian's rotation/audit role — NOT a routine append; the ACTION is AUDIT).
marker = "%s [AUDIT] log-archive/ — rotated %d events to %s" % (
    now_iso, len(event_lines), ", ".join(os.path.basename(p) for p in sorted(written_archives)))
live += marker + "\n"
atomic_write(log_md, live)

emit({"finding": "library-log-rotated", "file": log_md,
      "events_rotated": len(event_lines), "from_lines": total_lines,
      "archives": ",".join(sorted(os.path.basename(p) for p in written_archives)),
      "max_lines": max_lines, "detected_at": today})
print("library-log-rotate: rotated %d events -> %s (live log reset)"
      % (len(event_lines), ", ".join(os.path.basename(p) for p in sorted(written_archives))),
      file=sys.stderr)
PY
exit 0
