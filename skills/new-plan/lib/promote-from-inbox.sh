#!/bin/bash
# promote-from-inbox.sh — Graduate a pre-plan _inbox idea note into a full plan dir.
# The deterministic, mechanical half of the /backlog-research --promote flow and a
# helper for /new-plan (canonical/internal R-34 mechanical-mutation boundary:
# the migration + scaffold is judgment-free given the inbox note, so it lives in a
# runtime; the skill orchestrates + frames). Ported from the
# ~/Code//skills/backlog-research/promote-from-inbox.sh and retargeted to
# this skills/new-plan/lib/ home (OWNS; REC-2 roster member).
# Given a pre-plan idea note at $PLANS_ROOT/_inbox/<slug>.md (type: idea, per
# plans-rules.json :: inbox), it:
#   1. migrates the note body VERBATIM into 00-ideation-brief.md (## Original Idea,
#      block-quoted — lossless);
#   2. scaffolds the flat NN-<slug>/ quartet (spec.md + tasks.md + handoff.md +
#      00-ideation-brief.md) + manifest.json, assigning the next-available NN- prefix
#      at GRADUATION (inbox slugs carry NO NN- prefix — plans-rules.json :: inbox);
#   3. tombstones the note by removing it (the plan dir is the durable record).
# _inbox collision handling (DEFAULT (A)+(B); +.6):
#   (A) version-on-collision at _inbox/ CAPTURE — `--capture <slug>` writes a fresh
#       idea-note stub; if _inbox/<slug>.md exists it versions to <slug>-2.md,
#       <slug>-3.md, … (never clobbers a captured idea).
#   (B) reject-on-collision at GRADUATION — if the assigned NN-<slug> plan dir OR a
#       same-base-slug plan already exists, abort (no clobber, note left intact).
# Failure mode is BLOCK-AND-LOG (never write-and-hope): all validation runs before any
# write; a mid-scaffold failure rolls back the created dir and leaves the note intact.
# The note is removed only after the brief is written and its body verified present.
# NDJSON findings (FINDINGS_OUTPUT or stdout):
#   idea-graduated (event) | promote-aborted (event) | idea-captured (event)
# CLI:
#   promote-from-inbox.sh <inbox-slug>                  # graduate the note
#   promote-from-inbox.sh <inbox-slug> --title "X"      # override rendered title
#   promote-from-inbox.sh <inbox-slug> --project <key>  # override owning-spoke (R-ARCH-14)
#   promote-from-inbox.sh <inbox-slug> --dry-run        # compute + emit; no write
#   promote-from-inbox.sh --capture <slug>              # (A): version-on-collision capture
#   promote-from-inbox.sh --capture <slug> --title "X"
#   promote-from-inbox.sh --help
# Identity field-triad (R-ARCH-PID): the graduated manifest stamps `title:` (human
# display name, from the inbox note title) and `project:` (the owning-spoke machine
# identity, resolved from the session cwd through the anchored-spoke registry — NEVER
# the bare title). --project <spoke-key> overrides the auto-resolved spoke.
# Env overrides:
#   PLANS_ROOT             Plan-tree root (test isolation). Else PLANS_DIR (paths.sh),
#                          else $HOME/.claude-plans.
#   TEMPLATES_DIR          Template source for the brief (default: this skill's templates/).
#   PLANS_RULES_PATH       plans-rules.json (default: foundation → live).
#   FINDINGS_OUTPUT        NDJSON sink (default: stdout).
#   FOUNDATION_TEST_MODE   Bypass the non-interactive guard.
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# skills/new-plan/lib/ -> skills/new-plan/templates/
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "${PLANS_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh" 2>/dev/null || true
fi

# Spoke-key resolver (R-ARCH-13/14): prefer the live install, fall back to this
# skill's lib/ copy (dev-repo / test isolation). This lib lives alongside us.
for _sr in \
  "${CLAUDE_HOME:-$HOME/.claude}/skills/new-plan/lib/spoke-resolve.sh" \
  "$SCRIPT_DIR/spoke-resolve.sh"; do
  # shellcheck source=/dev/null
  if [[ -f "$_sr" ]]; then source "$_sr"; break; fi
done

ACTION="promote"      # promote | capture
DRY_RUN="false"
TITLE_OVERRIDE=""
PROJECT_OVERRIDE=""
SLUG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --capture) ACTION="capture"; SLUG="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --title) TITLE_OVERRIDE="${2:-}"; shift 2 ;;
    --project) PROJECT_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help) /usr/bin/sed -n '2,52p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "promote-from-inbox: unknown flag '$1'" >&2; exit 2 ;;
    *) if [[ -z "$SLUG" ]]; then SLUG="$1"; else echo "promote-from-inbox: unexpected arg '$1'" >&2; exit 2; fi; shift ;;
  esac
done

if [[ -z "$SLUG" ]]; then
  echo "promote-from-inbox: missing <inbox-slug> (see --help)" >&2
  exit 2
fi

# Judgment-tier non-interactive guard. Bypassed by FOUNDATION_TEST_MODE.
if [[ -z "${FOUNDATION_TEST_MODE:-}" ]] && [[ -z "${TTY:-}" ]] && ! [ -t 0 ]; then
  echo "promote-from-inbox: skipped (non-interactive)" >&2
  exit 0
fi

# Resolve plan-tree root (test override -> paths.sh -> default).
PLANS_ROOT="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
case "$PLANS_ROOT" in */) PLANS_ROOT="${PLANS_ROOT%/}" ;; esac
# Self-heal the plan-tree root if absent (see new-plan.sh).
mkdir -p "$PLANS_ROOT" || { echo "promote-from-inbox: cannot create PLANS_ROOT: $PLANS_ROOT" >&2; exit 1; }

# Resolve template dir (test override -> this skill's templates/).
TMPL_DIR="${TEMPLATES_DIR:-$SKILL_DIR/templates}"
if [[ ! -d "$TMPL_DIR" ]]; then
  echo "promote-from-inbox: templates dir not found: $TMPL_DIR (set TEMPLATES_DIR)" >&2
  exit 1
fi

# Resolve plans-rules.json (test override -> foundation-repo -> live install).
RULES_PATH="${PLANS_RULES_PATH:-}"
if [[ -z "$RULES_PATH" ]]; then
  for candidate in \
    "${CLAUDE_HOME:-$HOME/.claude}/governance/plans-rules.json"; do
    if [[ -f "$candidate" ]]; then RULES_PATH="$candidate"; break; fi
  done
fi
# install.sh Step 8.5 keeps the 7 loose pillars unshipped). A clean adopter ships ONLY the
# two bundles (foundation-master + overlay-master), which governance consumers read as ONE
# merged view via hooks/lib/foundation-overlay-load.sh (the R-52 union-load primitive —
# overlay overlaid on foundation). When the loose pillar is absent, resolve the EFFECTIVE
# `.plans` slot through that merger (--force-override = read posture per pre-write-guard:91)
# so the cap reads the REAL register instead of hard-exiting on a clean install.
if [[ -z "$RULES_PATH" || ! -f "$RULES_PATH" ]]; then
  _REPO_ROOT="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)"
  for _loader in \
    "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/foundation-overlay-load.sh" \
    "$_REPO_ROOT/hooks/lib/foundation-overlay-load.sh"; do
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
  echo "promote-from-inbox: plans-rules.json not found and no foundation-master+overlay bundle (set PLANS_RULES_PATH)" >&2
  exit 1
fi

# Resolve the owning-spoke key (R-ARCH-13/14) for the graduation path. --project
# overrides the cwd auto-resolution; either way the value must be a registered
# spoke key. A collision or unrecognized override BLOCKS here, before any write.
# (capture writes only an _inbox idea note — no manifest — so the spoke key is
# resolved unconditionally but consumed only on graduation.)
SPOKE_KEY=""
if [[ "$ACTION" == "promote" ]]; then
  if ! type spoke_resolve_from_cwd >/dev/null 2>&1; then
    echo "promote-from-inbox: spoke-resolve.sh not found — cannot resolve owning-spoke key (R-ARCH-13)" >&2
    exit 1
  fi
  if [[ -n "$PROJECT_OVERRIDE" ]]; then
    SPOKE_KEY="$(spoke_validate_override "$PROJECT_OVERRIDE")" || exit 1
  else
    SPOKE_KEY="$(spoke_resolve_from_cwd "$PWD")" || exit 1
  fi
fi

python3 - "$ACTION" "$PLANS_ROOT" "$DRY_RUN" "$TMPL_DIR" "$RULES_PATH" "$SLUG" "$TITLE_OVERRIDE" "$SPOKE_KEY" <<'PY'
import json
import os
import re
import shutil
import sys
import tempfile
from datetime import date

action = sys.argv[1]
plans_root = sys.argv[2]
dry_run = sys.argv[3] == "true"
tmpl_dir = sys.argv[4]
rules_path = sys.argv[5]
slug = sys.argv[6]
title_override = sys.argv[7]
spoke_key = sys.argv[8]

today = date.today().isoformat()


def emit(d):
    out = os.environ.get("FINDINGS_OUTPUT", "")
    line = json.dumps(d, separators=(", ", ": "), sort_keys=False)
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        print(line)


def abort(reason, **extra):
    rec = {"finding": "promote-aborted", "inbox_slug": slug,
           "reason": reason, "detected_at": today}
    rec.update(extra)
    emit(rec)
    print("promote-from-inbox: aborted — %s" % reason, file=sys.stderr)
    sys.exit(1)


_FM_KEY_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$')


def split_frontmatter(content):
    if not content.startswith("---\n"):
        return None, content
    end = content.find("\n---\n", 4)
    if end < 0:
        return None, content
    fm = {}
    for line in content[4:end].split("\n"):
        m = _FM_KEY_RE.match(line)
        if m:
            fm[m.group(1)] = m.group(2).strip()
    body = content[end + len("\n---\n"):]
    return fm, body


# ---- load pillar (inbox contract) ------------------------------------------
with open(rules_path, encoding="utf-8") as fh:
    rules = json.load(fh)
inbox_cfg = rules.get("inbox", {})
inbox_slug_pattern = inbox_cfg.get("slug_pattern", r"^[a-z][a-z0-9-]+$")
plan_slug_pattern = rules.get("slug_rules", {}).get("pattern", r"^[0-9]{2}-[a-z][a-z0-9-]+$")
inbox_dir = os.path.join(plans_root, "_inbox")


# Writes a fresh idea-note stub; if _inbox/<slug>.md already exists, versions to
# <slug>-2.md, <slug>-3.md, … (never clobbers an already-captured idea).
if action == "capture":
    if not re.match(inbox_slug_pattern, slug):
        abort("slug '%s' does not match inbox slug_pattern %s" % (slug, inbox_slug_pattern))
    os.makedirs(inbox_dir, exist_ok=True)
    final_slug = slug
    note_path = os.path.join(inbox_dir, final_slug + ".md")
    n = 1
    while os.path.exists(note_path):
        n += 1
        final_slug = "%s-%d" % (slug, n)
        note_path = os.path.join(inbox_dir, final_slug + ".md")
    title = title_override.strip() or final_slug.replace("-", " ").title()
    note = (
        "---\n"
        "title: %s\n"
        "type: idea\n"
        "status: new\n"
        "created: %s\n"
        "---\n\n"
        "## Idea\n\n"
        "{One paragraph: what's the idea?}\n\n"
        "## Why\n\n"
        "{Why does it matter? What problem does it solve?}\n\n"
        "## Notes\n\n"
        "{Free-form. Grows in place across funnel stages until graduation.}\n"
    ) % (title, today)
    if dry_run:
        emit({"finding": "idea-captured", "inbox_slug": final_slug, "note_path": note_path,
              "versioned": final_slug != slug, "dry_run": True, "detected_at": today})
        print("promote-from-inbox: dry-run capture — would write %s" % note_path, file=sys.stderr)
        sys.exit(0)
    fd, tmp = tempfile.mkstemp(dir=inbox_dir, prefix="." + final_slug + ".", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(note)
    os.chmod(tmp, 0o644)
    os.replace(tmp, note_path)
    emit({"finding": "idea-captured", "inbox_slug": final_slug, "note_path": note_path,
          "versioned": final_slug != slug, "dry_run": False, "detected_at": today})
    print("promote-from-inbox: captured _inbox/%s.md%s"
          % (final_slug, " (versioned on collision)" if final_slug != slug else ""), file=sys.stderr)
    sys.exit(0)


# GRADUATION (default action).
# ---- validate inbox note ---------------------------------------------------
if not re.match(inbox_slug_pattern, slug):
    abort("slug '%s' does not match inbox slug_pattern %s" % (slug, inbox_slug_pattern))

note_path = os.path.join(inbox_dir, slug + ".md")
if not os.path.isfile(note_path):
    abort("inbox note not found: %s" % note_path, note_path=note_path)

with open(note_path, encoding="utf-8") as fh:
    note_content = fh.read()
fm, note_body = split_frontmatter(note_content)
if fm is None:
    abort("inbox note has no frontmatter: %s" % note_path)
if fm.get("type", "").strip() != "idea":
    abort("inbox note type is '%s', expected 'idea'" % fm.get("type", ""))

note_title = fm.get("title", "").strip()
title = title_override.strip() or note_title or slug.replace("-", " ").title()

# ---- compute next-available NN- prefix (assigned at GRADUATION) ------------
max_prefix = 0
width = 2
for entry in os.listdir(plans_root):
    m = re.match(r"^([0-9]+)", entry)
    if m:
        n = int(m.group(1))
        if n > max_prefix:
            max_prefix = n
        width = max(width, len(m.group(1)))
nn = str(max_prefix + 1).zfill(width)
plan_slug = "%s-%s" % (nn, slug)
plan_dir = os.path.join(plans_root, plan_slug)

if not re.match(plan_slug_pattern, plan_slug):
    abort("computed plan slug '%s' fails plan slug_pattern %s" % (plan_slug, plan_slug_pattern))

# ---- (B): reject-on-collision at GRADUATION -------------------------
if os.path.exists(plan_dir):
    abort("target plan dir already exists: %s (reject-on-collision; B)" % plan_dir, plan_dir=plan_dir)
for entry in os.listdir(plans_root):
    if entry.startswith(".") or entry.startswith("_"):
        continue
    base = re.sub(r"^[0-9]+-", "", entry)
    if base == slug:
        abort("slug collision with existing plan: %s (reject-on-collision; B)" % entry, collision=entry)

# ---- build the ideation brief (lossless body migration) --------------------
quoted = "\n".join(("> " + ln) if ln else ">" for ln in note_body.rstrip("\n").split("\n"))

brief_frontmatter = (
    "---\n"
    "title: %s — Ideation Brief\n"
    "type: ideation-brief\n"
    "status: planned\n"
    "created: %s\n"
    "updated: %s\n"
    "promoted_from: _inbox/%s.md\n"
    "promoted_at: %s\n"
    "---\n\n"
) % (title, today, today, slug, today)


def tmpl(name):
    p = os.path.join(tmpl_dir, name)
    if not os.path.isfile(p):
        abort("template missing: %s" % p, template=name)
    with open(p, encoding="utf-8") as fh:
        return fh.read()


def render(text):
    return (text
            .replace("{{title}}", title)
            .replace("{{date}}", today)
            .replace("{{plan_dir}}", plan_dir)
            .replace("{{slug}}", slug))


# brief body from the new-plan brief template; strip its own frontmatter (we prepend
# the promoted-from frontmatter) and migrate the note body into ## Original Idea.
brief_raw = render(tmpl("00-ideation-brief.md.tmpl"))
_bfm, brief_body = split_frontmatter(brief_raw)
if brief_body is None:
    brief_body = brief_raw
placeholder = ("> {{Verbatim text from the backlog entry or user request. No editing. "
               "Replaced by the migrated note body on graduation via promote-from-inbox.}}")
if placeholder in brief_body:
    brief_body = brief_body.replace(placeholder, quoted)
else:
    brief_body = re.sub(r"(##\s+Original Idea\s*\n)",
                        r"\1\n" + quoted.replace("\\", "\\\\") + "\n",
                        brief_body, count=1)
brief_content = brief_frontmatter + brief_body.lstrip("\n")
if not brief_content.endswith("\n"):
    brief_content += "\n"

# ---- build the flat quartet (inline; the new-plan home owns no flat .tmpl) --
spec_content = (
    "---\ntitle: %s — Spec\ntype: spec\nstatus: planned\ncreated: %s\nupdated: %s\n---\n\n"
    "# %s — Spec\n\n**Status:** planned\n**Created:** %s\n**Parent:** —\n"
    "**Goal:** {One sentence. When this ships, what is true that wasn't true before?}\n\n"
    "## Problem Statement\n\n{2-4 sentences — frozen at scaffold time.}\n\n"
    "## Constraints\n\n- {Hard constraint}\n- {Anti-scope lock}\n\n"
    "## Solution Approach\n\n{3-8 sentences. Post-Session-1 amendment blocks land here.}\n"
) % (title, today, today, title, today)

tasks_content = (
    "---\ntitle: %s — Tasks\ntype: tasks\nstatus: planned\ncreated: %s\nupdated: %s\n---\n\n"
    "# %s — Tasks\n\n**Spec:** `%s/spec.md`\n**Last Updated:** %s\n\n"
    "## Status Key\n\n`not-started` | `in-progress` | `done` | `blocked` | `cut`\n\n"
    "<!-- tasks:start -->\n\n## Task ledger\n\n"
    "| ID | Title | Status | Depends on | Notes |\n|----|-------|--------|-----------|-------|\n"
    "| T-1 | Define spec | not-started | — | flesh out spec.md |\n\n"
    "<!-- tasks:end -->\n\n---\n\n## Tasks\n\n### T-1: Define spec\n\n"
    "**Status:** not-started\n**Dependencies:** none\n"
    "**Description:** Flesh out spec.md from the migrated ideation brief; replace placeholders.\n\n"
    "**Acceptance Criteria:**\n- [ ] Complete all spec.md sections\n- [ ] Replace placeholder rows\n\n---\n"
) % (title, today, today, title, plan_dir, today)

handoff_content = (
    "---\ntitle: %s — Handoff\ntype: handoff\nstatus: draft\ncreated: %s\nupdated: %s\n---\n\n"
    "# %s — Handoff\n\nAppend-only session record. Newest entry at top.\n\n"
    "## Session 0 — scaffold (promoted from _inbox)\n\n**Date:** %s\n**Next session:** T-1 — Define spec\n\n"
    "### Scope\n{Graduated from _inbox/%s.md. Idea body migrated to 00-ideation-brief.md.}\n\n---\n"
) % (title, today, today, title, today, slug)

manifest = {
    "schema_version": 1,
    "title": title,
    "project": spoke_key,
    "spec_path": os.path.join(plan_dir, "spec.md"),
    "architecture_path": None,
    "type": "plan",
    "status": "planned",
    "phase_2_scaffolded_at": today,
    "research_driven": True,
    "promoted_from": "_inbox/%s.md" % slug,
    "tasks": [
        {
            "id": "T-1",
            "title": "Define spec",
            "description": ("Flesh out spec.md (Problem / Constraints / Solution Approach) "
                            "from the migrated ideation brief; replace all template placeholders."),
            "acceptance_criteria": [
                "Complete all spec.md sections",
                "Replace template placeholder rows",
            ],
            "file_references": [os.path.join(plan_dir, "spec.md")],
            "depends_on": [],
            "max_budget_usd": 2,
        }
    ],
}
manifest_content = json.dumps(manifest, indent=2) + "\n"

files = {
    "spec.md": spec_content,
    "tasks.md": tasks_content,
    "handoff.md": handoff_content,
    "00-ideation-brief.md": brief_content,
    "manifest.json": manifest_content,
}

# ---- dry-run: report + exit, no writes -------------------------------------
if dry_run:
    emit({
        "finding": "idea-graduated", "inbox_slug": slug, "plan_slug": plan_slug,
        "plan_dir": plan_dir, "title": title, "project": spoke_key,
        "body_chars_migrated": len(note_body.strip()),
        "tombstoned": False, "dry_run": True, "detected_at": today,
    })
    print("promote-from-inbox: dry-run — would create %s and remove %s"
          % (plan_dir, note_path), file=sys.stderr)
    sys.exit(0)

# ---- scaffold (block-and-log; rollback on any failure) ---------------------
created = False
try:
    os.makedirs(plan_dir)
    created = True
    for name, content in files.items():
        d = os.path.dirname(os.path.join(plan_dir, name)) or plan_dir
        fd, tmp = tempfile.mkstemp(dir=d, prefix="." + name + ".", suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(content)
        os.chmod(tmp, 0o644)
        os.replace(tmp, os.path.join(plan_dir, name))
except Exception as exc:
    if created and os.path.isdir(plan_dir):
        shutil.rmtree(plan_dir, ignore_errors=True)
    abort("scaffold write failed (%s); rolled back, inbox note untouched" % exc)

# ---- verify the brief carries the migrated body, THEN tombstone ------------
brief_on_disk = os.path.join(plan_dir, "00-ideation-brief.md")
probe = (note_body.strip().split("\n")[0] if note_body.strip() else "")
ok = os.path.isfile(brief_on_disk)
if ok and probe:
    with open(brief_on_disk, encoding="utf-8") as fh:
        ok = probe in fh.read()
if not ok:
    shutil.rmtree(plan_dir, ignore_errors=True)
    abort("post-write verification failed (brief missing migrated body); rolled back")

os.remove(note_path)  # tombstone: body losslessly preserved in the brief

emit({
    "finding": "idea-graduated", "inbox_slug": slug, "plan_slug": plan_slug,
    "plan_dir": plan_dir, "title": title, "project": spoke_key,
    "body_chars_migrated": len(note_body.strip()),
    "tombstoned": True, "dry_run": False, "detected_at": today,
})
print("promote-from-inbox: graduated _inbox/%s → %s (note removed)"
      % (slug, plan_slug), file=sys.stderr)
PY
