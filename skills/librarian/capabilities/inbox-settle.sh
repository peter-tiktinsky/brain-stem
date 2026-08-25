#!/bin/bash
# inbox-settle — Manually settle a pre-plan _inbox idea note (operator-judgment
# settlement: a note with NO plan target that the closure loop can therefore never
# auto-stamp). Stamps the terminal resolution and relocates the note to the settled
# home (<plans-root>/_inbox/_settled/) in one event.
#
# The stamper is STRICT where the renderer is lenient: --resolution must be a member
# of the governance resolution_enum (the sanctioned channel never mints vocabulary
# drift; the renderer's evidence rule + out-of-enum advisory exist to render
# hand-stamped and historical notes honestly). `superseded` requires --superseded-by
# (the pairing the governance note documents).
#
# Output Contract
#   Files written (only with --apply):
#     <plans-root>/_inbox/<slug>.md — frontmatter stamped (resolution, resolved_at,
#       updated, superseded_by when given); body byte-untouched.
#     <plans-root>/_inbox/_settled/<slug>.md — the stamped note's new home
#       (temp+rename write, then os.replace move; never clobbers an existing
#       destination — a collision refuses).
#   Default (no --apply): dry-run — reports what would happen, emits the finding
#     with dry_run:true, writes nothing.
#   Findings: inbox-note-settled (channel: inbox-settle) NDJSON via findings.sh.
#   Failure mode: block-and-log; refusals exit 1 before any write.
#
# CLI:
#   inbox-settle.sh <slug> --resolution <value> [--superseded-by <ref>] [--apply]
#   inbox-settle.sh --help
#
# Refusals (exit 1): note not found flat (a _settled/ resident reports
#   already-settled); note already carries a settling resolution; out-of-enum
#   --resolution (roster named); `superseded` without --superseded-by; destination
#   collision.
#
# Env overrides:
#   PLANS_ROOT / PLANS_DIR   plan-tree root (test isolation)
#   PLANS_RULES_PATH         plans-rules.json (default: foundation -> live)
#   FINDINGS_OUTPUT          NDJSON sink (default: stdout)
#
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24.

set -euo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"
if [[ -z "${PLANS_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; } || true
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || { [ -r "$_REPO_LIB/findings.sh" ] && source "$_REPO_LIB/findings.sh"; } || true

APPLY="false"
RESOLUTION=""
SUPERSEDED_BY=""
SLUG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY="true"; shift ;;
    --resolution) RESOLUTION="${2:-}"; shift 2 ;;
    --superseded-by) SUPERSEDED_BY="${2:-}"; shift 2 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    -*) echo "inbox-settle: unknown flag '$1'" >&2; exit 2 ;;
    *) if [[ -z "$SLUG" ]]; then SLUG="$1"; else echo "inbox-settle: unexpected arg '$1'" >&2; exit 2; fi; shift ;;
  esac
done
if [[ -z "$SLUG" ]]; then echo "inbox-settle: missing <slug> (see --help)" >&2; exit 2; fi
if [[ -z "$RESOLUTION" ]]; then echo "inbox-settle: missing --resolution <value> (see --help)" >&2; exit 2; fi

# Non-interactive --apply guard (the promote-from-inbox transplant): bypassed by
# FOUNDATION_TEST_MODE and by a Claude Code tool-context session (CLAUDECODE=1);
# only a genuine headless / non-Claude-Code no-tty invocation skips.
if [[ "$APPLY" == "true" ]] && [[ -z "${FOUNDATION_TEST_MODE:-}" ]] && [[ -z "${CLAUDECODE:-}" ]] \
   && [[ -z "${TTY:-}" ]] && ! [ -t 0 ]; then
  echo "inbox-settle: skipped (non-interactive; not a Claude Code tool-context session)" >&2
  exit 0
fi

PLANS_ROOT="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac
if [[ ! -d "$PLANS_ROOT" ]]; then
  echo "inbox-settle: PLANS_ROOT does not exist: $PLANS_ROOT" >&2
  exit 1
fi

RULES_PATH="${PLANS_RULES_PATH:-}"
if [[ -z "$RULES_PATH" ]]; then
  for candidate in \
    "$CLAUDE_HOME_RES/governance/plans-rules.json"; do
    if [[ -f "$candidate" ]]; then RULES_PATH="$candidate"; break; fi
  done
fi
# Master-fallback: on a clean adopter install the loose pillar is unshipped — resolve
# the effective `.plans` slot through the foundation+overlay union loader (read posture).
if [[ -z "$RULES_PATH" || ! -f "$RULES_PATH" ]]; then
  for _loader in \
    "$CLAUDE_HOME_RES/hooks/lib/foundation-overlay-load.sh" \
    "$_REPO_LIB/foundation-overlay-load.sh"; do
    [[ -x "$_loader" ]] || continue
    _rt="$(mktemp 2>/dev/null)" || break
    if bash "$_loader" --query '.plans' --force-override > "$_rt" 2>/dev/null \
         && [[ -s "$_rt" ]] && [[ "$(head -c4 "$_rt" 2>/dev/null)" != null ]]; then
      RULES_PATH="$_rt"; trap 'rm -f "$_rt"' EXIT; break
    fi
    rm -f "$_rt"
  done
fi
if [[ -z "$RULES_PATH" || ! -f "$RULES_PATH" ]]; then
  echo "inbox-settle: plans-rules.json not found and no foundation-master+overlay bundle (set PLANS_RULES_PATH)" >&2
  exit 1
fi

FINDINGS_OUTPUT="${FINDINGS_OUTPUT:-/dev/stdout}"
TODAY="$(date +%Y-%m-%d)"

python3 - "$PLANS_ROOT" "$RULES_PATH" "$SLUG" "$RESOLUTION" "$SUPERSEDED_BY" "$APPLY" "$TODAY" "$FINDINGS_OUTPUT" <<'PY'
import json, os, sys, tempfile

plans_root, rules_path, slug, resolution, superseded_by, apply_s, today, fout = sys.argv[1:9]
apply = apply_s == "true"

with open(rules_path, encoding="utf-8") as fh:
    rules = json.load(fh)
inbox_cfg = rules.get("inbox", rules.get("plans", {}).get("inbox", {}))
enum = inbox_cfg.get("resolution_enum",
                     ["promoted", "absorbed", "resolved", "dropped",
                      "superseded", "discharged"])
settled_rel = inbox_cfg.get("settled_dir", "_inbox/_settled/").strip("/")

def refuse(msg):
    print("inbox-settle: %s" % msg, file=sys.stderr)
    sys.exit(1)

# Strict-vocabulary gate: the sanctioned stamper never mints drift.
if resolution not in enum:
    refuse("out-of-enum --resolution '%s' — the roster is: %s" % (resolution, ", ".join(enum)))
if resolution == "superseded" and not superseded_by.strip():
    refuse("--resolution superseded requires --superseded-by <ref> (the governance pairing)")

flat = os.path.join(plans_root, "_inbox", slug + ".md")
settled_abs = os.path.join(plans_root, *settled_rel.split("/"))
dest = os.path.join(settled_abs, slug + ".md")
if not os.path.isfile(flat):
    if os.path.isfile(dest):
        refuse("note is already settled at %s/%s.md" % (settled_rel, slug))
    refuse("note not found: _inbox/%s.md" % slug)
if os.path.exists(dest):
    refuse("destination collision: %s/%s.md already exists (never clobbered)" % (settled_rel, slug))

with open(flat, encoding="utf-8") as fh:
    content = fh.read()

def parse_fm_value(key):
    if not content.startswith("---\n"):
        return ""
    end = content.find("\n---\n", 4)
    if end < 0:
        return ""
    for line in content[4:end].split("\n"):
        if line.startswith(key + ":"):
            return line[len(key) + 1:].strip().strip('"')
    return ""

existing = parse_fm_value("resolution")
if existing:
    refuse("note already carries resolution: %s (nothing to do)" % existing)
if not content.startswith("---\n") or content.find("\n---\n", 4) < 0:
    refuse("note has no frontmatter block: _inbox/%s.md" % slug)

pairs = [("resolution", resolution), ("resolved_at", today), ("updated", today)]
if superseded_by.strip():
    pairs.append(("superseded_by", superseded_by.strip()))

# apply_fm_updates (the backlog-index semantics): replace in place or append
# before the closing fence; body byte-untouched.
end = content.find("\n---\n", 4)
fm_block = content[4:end]
rest = content[end:]
updates = dict(pairs)
seen = set()
out_lines = []
for line in fm_block.split("\n"):
    key = line.split(":", 1)[0] if ":" in line else ""
    if key in updates and not line.startswith(" "):
        out_lines.append("%s: %s" % (key, updates[key]))
        seen.add(key)
    else:
        out_lines.append(line)
for k, v in pairs:
    if k not in seen:
        out_lines.append("%s: %s" % (k, v))
new_content = "---\n" + "\n".join(out_lines) + rest

finding = {"finding": "inbox-note-settled", "file": slug + ".md", "inbox_slug": slug,
           "resolution": resolution, "channel": "inbox-settle",
           "settled_path": "%s/%s.md" % (settled_rel, slug),
           "resolved_at": today, "detected_at": today, "dry_run": not apply}
if superseded_by.strip():
    finding["superseded_by"] = superseded_by.strip()

if not apply:
    with open(fout, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(finding, ensure_ascii=False) + "\n")
    print("inbox-settle: dry-run — would stamp resolution: %s and move _inbox/%s.md -> %s/%s.md"
          % (resolution, slug, settled_rel, slug), file=sys.stderr)
    sys.exit(0)

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(flat), prefix="." + slug + ".", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(new_content)
    os.replace(tmp, flat)
except Exception:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise
os.makedirs(settled_abs, exist_ok=True)
os.replace(flat, dest)
with open(fout, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(finding, ensure_ascii=False) + "\n")
print("inbox-settle: settled _inbox/%s.md -> %s/%s.md (resolution: %s)"
      % (slug, settled_rel, slug, resolution), file=sys.stderr)
PY
