#!/bin/bash
# promote-from-inbox.sh — Graduate a pre-plan _inbox idea note into a full plan dir.
#
# The deterministic, mechanical half of the /backlog-research --promote flow and a
# helper for /new-plan (canonical/internal R-34 mechanical-mutation boundary:
# the migration + scaffold is judgment-free given the inbox note, so it lives in a
# runtime; the skill orchestrates + frames). Ported from the
# ~/Code//skills/backlog-research/promote-from-inbox.sh and retargeted to
# this skills/new-plan/lib/ home, which owns it.
#
# Given a pre-plan idea note at $PLANS_ROOT/_inbox/<slug>.md (type: idea, per
# plans-rules.json :: inbox), it:
#   1. migrates the note body VERBATIM into 00-ideation-brief.md (## Original Idea,
#      block-quoted — lossless);
#   2. scaffolds the flat NN-<slug>/ quartet (spec.md + tasks.md + handoff.md +
#      00-ideation-brief.md) + manifest.json, assigning the next-available NN- prefix
#      at GRADUATION (inbox slugs carry NO NN- prefix — plans-rules.json :: inbox);
#   3. tombstones the note by removing it (the plan dir is the durable record).
#
# _inbox collision handling (DEFAULT (A)+(B); +.6):
#   (A) version-on-collision at _inbox/ CAPTURE — `--capture <slug>` writes a fresh
#       idea-note stub; if _inbox/<slug>.md exists it versions to <slug>-2.md,
#       <slug>-3.md, … (never clobbers a captured idea). A slug a top-level plan manifest
#       names in `promoted_from` (a graduated, tombstoned note) is held too.
#   (B) reject-on-collision at GRADUATION — if the assigned NN-<slug> plan dir OR a
#       same-base-slug plan already exists, abort (no clobber, note left intact).
#
# Failure mode is BLOCK-AND-LOG (never write-and-hope): all validation runs before any
# write; a mid-scaffold failure rolls back the created dir and leaves the note intact.
# The note is removed only after the brief is written and its body verified present.
#
# NDJSON findings (FINDINGS_OUTPUT or stdout):
#   idea-graduated (event) | promote-aborted (event) | idea-captured (event) | idea-amended (event)
#
# CLI:
#   promote-from-inbox.sh <inbox-slug>                  # graduate the note
#       # a lead note, and each --absorb note, graduates only at a funnel status the plans rules list
#       # (inbox.graduation_precondition.status); triage-apply.sh moves a new note to one of them.
#   promote-from-inbox.sh <inbox-slug> --title "X"      # override rendered title
#   promote-from-inbox.sh <inbox-slug> --project <key>  # override owning-spoke
#   promote-from-inbox.sh <inbox-slug> --dry-run        # compute + emit; no write
#   promote-from-inbox.sh <lead-slug> --absorb <slug> [--absorb <slug> ...]
#       # N:1 graduation: the manifest lists each note in absorbed_notes[] and each note is
#       # stamped disposition ABSORB, absorbed_into <new plan>; all or nothing, notes stay flat
#   promote-from-inbox.sh --capture <slug>              # (A): version-on-collision capture
#   promote-from-inbox.sh --capture <slug> --title "X"
#   promote-from-inbox.sh --capture <slug> --disposition <value> [--absorbed-into <plan-key>]
#       # a capture is born decided: --disposition is required and stamps a
#       # backlog_row.disposition_enum value at write. FIX NOW is refused (a fix-now item is fixed,
#       # not captured). ABSORB requires --absorbed-into, a plan key (optional ' :: T-N' suffix)
#       # whose manifest.json exists under the plans root. STANDALONE requires --release-class
#       # <local-release|public-release|post-release|docs> and --size <day|build> (inbox.note_frontmatter enums). NO-BUILD requires
#       # --reopen-gate <id>, an id hooks/lib/reopen-gate.sh --list names. Each class flag is
#       # refused with any other disposition; a graduation takes none of them.
#   promote-from-inbox.sh --capture <slug> --distinct-from <existing> [--distinct-from ...] --distinct-scope "<line>"
#   printf '%s\n' "<body>" | promote-from-inbox.sh --capture <slug> --amend <existing>
#       # a capture first shortlists open notes it resembles (hooks/lib/inbox-near-dup.sh: shared
#       # path:line cite, shared slug stem, title and Idea overlap) and refuses while any exist,
#       # unless --amend <existing> (appends the piped body to that note as one dated section; writes
#       # no new note; takes no disposition flag) or every shortlisted note is named by --distinct-from
#       # with a non-empty --distinct-scope (both stamped into the note's frontmatter).
#   printf '%s\n' "<body>" | promote-from-inbox.sh --capture <slug>  # piped body replaces the template sections
#       # a --capture always pipes its body: the template body is refused (a captured
#       # note must carry its body)
#   promote-from-inbox.sh --help
#
# SOLE MINT PATH — root-write redirect (the canonical one-liners the plans-root-allowlist
# guard at hooks/pre-write-guard.sh emits when it intercepts an ad-hoc root write). A durable
# artifact with no owning plan is captured then graduated through this funnel, never written
# straight to a hand-invented ~/.claude-plans/ root surface:
#   capture:   promote-from-inbox.sh --capture <slug> --disposition <value>   # write the decided idea note now
#   triage:    triage-apply.sh <slug> --classification <class> --rationale <line>  # classify it (new -> triaged)
#   graduate:  promote-from-inbox.sh <slug>                                   # mint the NN-<slug>/ plan when ready
# then precursors go in a workshop dir (workshop open <topic>-<plan-slug>) and the one synthesis moves into <plan>/_research/ with workshop promote <key> <file> --plan <plan-dir>.
# These lines are the guard's deny/ask redirect text — keep them in sync with the guard message.
#
# Workshop re-key: a graduation that finds a workshop dir named for the inbox slug
# ($CLAUDE_WORKSHOP_DIR/<inbox-slug>/) renames it to <inbox-slug>-<NN-slug>/, the key form
# library-scrub resolves to the new plan; the idea-graduated event then carries
# workshop_rekeyed. With no such dir, graduation output is unchanged.
#
# Identity field-triad: the graduated manifest stamps `title:` (human
# display name, from the inbox note title) and `project:` (the owning-spoke machine
# identity, a registry-resolved spoke key — NEVER the bare title).
#
# Attribution is decided at CAPTURE, when a human is attending — not at graduation cwd:
#   - `--capture` mechanically stamps `project:` into the new note (spoke-resolve auto
#     from cwd, or the `--project` override), so the owning spoke is recorded up front.
#   - Graduation resolves `project:` by PRECEDENCE: `--project` flag > the note's own
#     `project:` frontmatter > cwd auto-resolve fallback. The note-frontmatter tier kills
#     the drift-cwd `home`-mint class (a graduation from an unanchored session cwd no
#     longer overrides an already-attributed note).
# --project <spoke-key> is validated against the registry (no silent fallback).
#
# Env overrides:
#   PLANS_ROOT             Plan-tree root (test isolation). Else PLANS_DIR (paths.sh),
#                          else $HOME/.claude-plans.
#   TEMPLATES_DIR          Template source for the brief (default: this skill's templates/).
#   PLANS_RULES_PATH       plans-rules.json (default: foundation → live).
#   FINDINGS_OUTPUT        NDJSON sink (default: stdout).
#   FOUNDATION_TEST_MODE   Bypass the non-interactive guard.
#   CLAUDE_SESSION_ID      A capture stamps captured_session with this id, else with
#                          CLAUDE_CODE_SESSION_ID, else leaves the key blank.
#   HOOKS_STDIN_WAIT      Seconds of silence per read before a piped capture body is
#                          treated as complete (whole seconds; default 5).
#
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# skills/new-plan/lib/ -> skills/new-plan/templates/
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "${PLANS_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh" 2>/dev/null || true
fi

# Spoke-key resolver: prefer the live install, fall back to this
# skill's lib/ copy (dev-repo / test isolation). This lib lives alongside us.
for _sr in \
  "${CLAUDE_HOME:-$HOME/.claude}/skills/new-plan/lib/spoke-resolve.sh" \
  "$SCRIPT_DIR/spoke-resolve.sh"; do
  # shellcheck source=/dev/null
  if [[ -f "$_sr" ]]; then source "$_sr"; break; fi
done

# Resolve the librarian:tasks-render capability (RULING 2 /). tasks-render is the
# SINGLE writer of the tasks.md sentinel region (R-37/): the graduation emitter seeds
# manifest.tasks[], ships an EMPTY sentinel pair, and DELEGATES the region-fill to this
# capability at scaffold time — never statically pre-emitting a region the renderer owns.
# Resolve it SIBLING-FIRST (co-shipped in the same skill tree, so version-matched + hermetic
# in-repo AND in a clean install), CLAUDE_HOME as the fallback; never a hardcoded home.
TASKS_RENDER=""
for _tr in \
  "$SKILL_DIR/../librarian/capabilities/tasks-render.sh" \
  "${CLAUDE_HOME:-$HOME/.claude}/skills/librarian/capabilities/tasks-render.sh"; do
  if [[ -f "$_tr" ]]; then TASKS_RENDER="$_tr"; break; fi
done

ACTION="promote"      # promote | capture
DRY_RUN="false"
TITLE_OVERRIDE=""
PROJECT_OVERRIDE=""
DISPOSITION_SET=""; DISPOSITION=""
ABSORBED_SET=""; ABSORBED_INTO=""
RELEASE_CLASS_SET=""; RELEASE_CLASS=""
SIZE_SET=""; SIZE=""
REOPEN_GATE_SET=""; REOPEN_GATE=""
ABSORB_SET=""; ABSORB_SLUGS=""
AMEND_SET=""; AMEND=""
DISTINCT_SET=""; DISTINCT_FROM=""
SCOPE_SET=""; DISTINCT_SCOPE=""
SLUG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --capture) ACTION="capture"; SLUG="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --title) TITLE_OVERRIDE="${2:-}"; shift 2 ;;
    --project) PROJECT_OVERRIDE="${2:-}"; shift 2 ;;
    --disposition) DISPOSITION_SET="1"; DISPOSITION="${2:-}"; shift 2 ;;
    --absorbed-into) ABSORBED_SET="1"; ABSORBED_INTO="${2:-}"; shift 2 ;;
    --release-class) RELEASE_CLASS_SET="1"; RELEASE_CLASS="${2:-}"; shift 2 ;;
    --size) SIZE_SET="1"; SIZE="${2:-}"; shift 2 ;;
    --reopen-gate) REOPEN_GATE_SET="1"; REOPEN_GATE="${2:-}"; shift 2 ;;
    --absorb) ABSORB_SET="1"; ABSORB_SLUGS="${ABSORB_SLUGS}${2:-}"$'\n'; shift 2 ;;
    --amend) AMEND_SET="1"; AMEND="${2:-}"; shift 2 ;;
    --distinct-from) DISTINCT_SET="1"; DISTINCT_FROM="${DISTINCT_FROM}${2:-}"$'\n'; shift 2 ;;
    --distinct-scope) SCOPE_SET="1"; DISTINCT_SCOPE="${2:-}"; shift 2 ;;
    -h|--help) /usr/bin/awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    -*) echo "promote-from-inbox: unknown flag '$1'" >&2; exit 2 ;;
    *) if [[ -z "$SLUG" ]]; then SLUG="$1"; else echo "promote-from-inbox: unexpected arg '$1'" >&2; exit 2; fi; shift ;;
  esac
done

if [[ -z "$SLUG" ]]; then
  echo "promote-from-inbox: missing <inbox-slug> (see --help)" >&2
  exit 2
fi
# --disposition / --absorbed-into stamp a new note at capture; a graduation takes neither.
if [[ "$ACTION" != "capture" ]] && [[ -n "$DISPOSITION_SET$ABSORBED_SET" ]]; then
  echo "promote-from-inbox: --disposition and --absorbed-into apply to --capture only" >&2
  exit 2
fi
if [[ "$ACTION" != "capture" ]]; then
  _cf=""
  [[ -z "$RELEASE_CLASS_SET" ]] || _cf="--release-class"
  [[ -n "$_cf" || -z "$SIZE_SET" ]] || _cf="--size"
  [[ -n "$_cf" || -z "$REOPEN_GATE_SET" ]] || _cf="--reopen-gate"
  if [[ -n "$_cf" ]]; then
    echo "promote-from-inbox: $_cf applies to --capture only" >&2
    exit 2
  fi
fi
if [[ "$ACTION" != "capture" ]] && [[ -n "$AMEND_SET$DISTINCT_SET$SCOPE_SET" ]]; then
  echo "promote-from-inbox: --amend, --distinct-from and --distinct-scope apply to --capture only" >&2
  exit 2
fi
if [[ "$ACTION" == "capture" ]] && [[ -n "$ABSORB_SET" ]]; then
  echo "promote-from-inbox: --absorb applies to a graduation, not --capture" >&2
  exit 2
fi

# Judgment-tier non-interactive guard. Bypassed by FOUNDATION_TEST_MODE, and by a Claude
# Code tool-context session (CLAUDECODE=1): a Claude Code tool call has no tty but IS an
# authorized non-interactive context, so the SOLE mint path must graduate in-session instead
# of silently no-opping. Only a genuine headless / non-Claude-Code no-tty invocation skips.
if [[ -z "${FOUNDATION_TEST_MODE:-}" ]] && [[ -z "${CLAUDECODE:-}" ]] && [[ -z "${TTY:-}" ]] && ! [ -t 0 ]; then
  echo "promote-from-inbox: skipped (non-interactive; not a Claude Code tool-context session)" >&2
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
# Master-fallback: plans-rules.json is repo-only (install.sh Step 8.5 keeps the
# 7 loose pillars unshipped). A clean adopter ships ONLY the
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

# Resolve the owning-spoke key. Attribution is decided at CAPTURE (a
# human is attending) and RE-USED at graduation via note-frontmatter precedence:
#   --project flag  >  the note's own `project:` frontmatter  >  cwd auto-resolve.
# --capture: spoke key stamped into the new note (--project override else cwd auto).
# graduate: --project override else the note's stamped project: else cwd auto (the
#           note tier kills the drift-cwd `home`-mint class). Every path validates
#           against the registry (no silent fallback); a collision or an
#           unrecognized key BLOCKS here, before any write.
SPOKE_KEY=""
if ! type spoke_resolve_from_cwd >/dev/null 2>&1; then
  echo "promote-from-inbox: spoke-resolve.sh not found — cannot resolve owning-spoke key" >&2
  exit 1
fi
if [[ -n "$PROJECT_OVERRIDE" ]]; then
  SPOKE_KEY="$(spoke_validate_override "$PROJECT_OVERRIDE")" || exit 1
elif [[ "$ACTION" == "promote" ]]; then
  # Note-frontmatter precedence: read the graduating note's own `project:` (stamped at
  # capture) and honor it over cwd — a graduation from an unanchored session cwd no
  # longer silently re-attributes an already-owned note to `home`.
  NOTE_PROJECT=""
  _note_file="$PLANS_ROOT/_inbox/$SLUG.md"
  if [[ -f "$_note_file" ]]; then
    NOTE_PROJECT="$(awk '
      NR==1 { if ($0 ~ /^---[[:space:]]*$/) { infm=1; next } else { exit } }
      infm && /^---[[:space:]]*$/ { exit }
      infm && /^project:/ {
        line=$0; sub(/^project:[[:space:]]*/, "", line);
        sub(/[[:space:]]+$/, "", line);
        sub(/^"/, "", line); sub(/"$/, "", line);
        print line; exit
      }
    ' "$_note_file" 2>/dev/null)"
  fi
  if [[ -n "$NOTE_PROJECT" ]]; then
    SPOKE_KEY="$(spoke_validate_override "$NOTE_PROJECT")" || exit 1
  else
    SPOKE_KEY="$(spoke_resolve_from_cwd "$PWD")" || exit 1
  fi
else
  # capture: cwd auto-resolve (attribution stamped into the note up front).
  SPOKE_KEY="$(spoke_resolve_from_cwd "$PWD")" || exit 1
  # A capture run from inside the plans root resolves to `home`, which is rarely the owning spoke:
  # say so once on stderr. The capture itself continues unchanged (same exit code, same note bytes).
  if [[ "$SPOKE_KEY" == "home" ]] && [[ -d "$PLANS_ROOT" ]]; then
    _cwd_phys="$(pwd -P)"
    if _root_phys="$(cd "$PLANS_ROOT" && pwd -P)"; then
      case "$_cwd_phys/" in
        "$_root_phys"/*)
          echo "promote-from-inbox: NOTE: capture ran from inside the plans root and resolved project 'home'; pass --project <spoke-key> to file the note under its owning spoke" >&2
          ;;
      esac
    fi
  fi
fi

# Capture body: a piped stdin is the note body. The python heredoc below takes stdin, so
# bash drains the pipe first into a temp file and hands python its path as an argv element
# (data via argv, never a piped stdin). The bound is PER READ: `! [ -t 0 ]` also answers
# true for an inherited socket or fifo that never delivers EOF, so a stream that keeps
# delivering is read in full and only silence ends the read. HOOKS_STDIN_WAIT overrides the
# wait (whole seconds); a zero or non-numeric value falls back to 5, because `read -t 0`
# arms no timer on bash 3.2. Empty input keeps the template body.
BODY_FILE=""
if [[ "$ACTION" == "capture" ]] && ! [ -t 0 ]; then
  BODY_FILE="$(mktemp "${TMPDIR:-/tmp}/promote-capture-body.XXXXXX")" || {
    echo "promote-from-inbox: cannot create a temp file for the piped capture body" >&2
    exit 1
  }
  # One EXIT trap owns every temp file (the rules-slot temp above may hold one).
  trap 'rm -f "$BODY_FILE"; [[ -z "${_rt:-}" ]] || rm -f "$_rt"' EXIT
  _STDIN_WAIT="${HOOKS_STDIN_WAIT:-5}"
  case "$_STDIN_WAIT" in ''|0|*[!0-9]*) _STDIN_WAIT=5 ;; esac
  _STDIN_LINE=""
  {
    while IFS= read -r -t "$_STDIN_WAIT" _STDIN_LINE; do printf '%s\n' "$_STDIN_LINE"; done
    # A last line with no trailing newline is still body.
    if [[ -n "$_STDIN_LINE" ]]; then printf '%s' "$_STDIN_LINE"; fi
  } > "$BODY_FILE"
  unset _STDIN_WAIT _STDIN_LINE
fi

# The re-open gate reader names the registered gate ids a NO-BUILD capture may carry. It is
# found SIBLING-FIRST (co-shipped in the same foundation tree: hooks/lib/ two levels above this
# skill), the install root as the fallback; empty when neither resolves (the capture then refuses).
REOPEN_GATE_SCRIPT=""
for _rg in \
  "$SKILL_DIR/../../hooks/lib/reopen-gate.sh" \
  "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/reopen-gate.sh"; do
  if [[ -f "$_rg" ]]; then REOPEN_GATE_SCRIPT="$_rg"; break; fi
done

# The near-duplicate scorer shortlists the open notes a capture resembles. Found SIBLING-FIRST
# like the gate reader above; empty when neither resolves (a capture then refuses).
NEAR_DUP_SCRIPT=""
for _nd in \
  "$SKILL_DIR/../../hooks/lib/inbox-near-dup.sh" \
  "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/inbox-near-dup.sh"; do
  if [[ -f "$_nd" ]]; then NEAR_DUP_SCRIPT="$_nd"; break; fi
done

# The triage command a refusal names: a sibling skill of this helper's own location, so a repo run
# names the repo copy and a live run the live copy.
TRIAGE_APPLY="$(dirname "$SKILL_DIR")/backlog-triage/scripts/triage-apply.sh"

PLAN_COMMON_DIR="$SCRIPT_DIR" PYTHONDONTWRITEBYTECODE=1 \
python3 - "$ACTION" "$PLANS_ROOT" "$DRY_RUN" "$TMPL_DIR" "$RULES_PATH" "$SLUG" "$TITLE_OVERRIDE" "$SPOKE_KEY" "$TASKS_RENDER" "$BODY_FILE" "${CLAUDE_WORKSHOP_DIR:-}" \
  "$DISPOSITION_SET" "$DISPOSITION" "$ABSORBED_SET" "$ABSORBED_INTO" "$ABSORB_SLUGS" \
  "$RELEASE_CLASS_SET" "$RELEASE_CLASS" "$SIZE_SET" "$SIZE" "$REOPEN_GATE_SET" "$REOPEN_GATE" "$REOPEN_GATE_SCRIPT" "${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}" \
  "$AMEND_SET" "$AMEND" "$DISTINCT_FROM" "$SCOPE_SET" "$DISTINCT_SCOPE" "$NEAR_DUP_SCRIPT" "$TRIAGE_APPLY" <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import date

sys.path.insert(0, os.environ["PLAN_COMMON_DIR"])
from plan_common import cohort_base, q

action = sys.argv[1]
plans_root = sys.argv[2]
dry_run = sys.argv[3] == "true"
tmpl_dir = sys.argv[4]
rules_path = sys.argv[5]
slug = sys.argv[6]
title_override = sys.argv[7]
spoke_key = sys.argv[8]
tasks_render = sys.argv[9]
body_file = sys.argv[10] if len(sys.argv) > 10 else ""
workshop_dir = sys.argv[11] if len(sys.argv) > 11 else ""
disposition_set = len(sys.argv) > 12 and sys.argv[12] == "1"
disposition = sys.argv[13] if len(sys.argv) > 13 else ""
absorbed_set = len(sys.argv) > 14 and sys.argv[14] == "1"
absorbed_into = (sys.argv[15] if len(sys.argv) > 15 else "").strip()
# --absorb slugs, one per line as the wrapper collected them (each line ends in a newline).
absorb_slugs = (sys.argv[16] if len(sys.argv) > 16 else "").split("\n")[:-1]
release_class_set = len(sys.argv) > 17 and sys.argv[17] == "1"
release_class = sys.argv[18] if len(sys.argv) > 18 else ""
size_set = len(sys.argv) > 19 and sys.argv[19] == "1"
size_value = sys.argv[20] if len(sys.argv) > 20 else ""
reopen_gate_set = len(sys.argv) > 21 and sys.argv[21] == "1"
reopen_gate = sys.argv[22] if len(sys.argv) > 22 else ""
reopen_gate_script = sys.argv[23] if len(sys.argv) > 23 else ""
# The capturing session, stamped as captured_session (blank when no session id is set).
captured_session = re.sub(r"\s+", "", sys.argv[24] if len(sys.argv) > 24 else "")
# Near-duplicate handling: --amend <existing>, repeatable --distinct-from (one per line, each
# ending in a newline) with its --distinct-scope line, and the scorer's path.
amend_set = len(sys.argv) > 25 and sys.argv[25] == "1"
amend_slug = (sys.argv[26] if len(sys.argv) > 26 else "").strip()
distinct_from = [s.strip() for s in (sys.argv[27] if len(sys.argv) > 27 else "").split("\n") if s.strip()]
scope_set = len(sys.argv) > 28 and sys.argv[28] == "1"
distinct_scope = (sys.argv[29] if len(sys.argv) > 29 else "").strip()
near_dup_script = sys.argv[30] if len(sys.argv) > 30 else ""
# The triage command a graduation refusal names.
triage_apply = sys.argv[31] if len(sys.argv) > 31 else ""

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


def delegate_render(target_dir):
    """RULING 2: delegate the tasks.md sentinel-region fill to librarian:tasks-render
    (the SINGLE writer of the region, R-37/) after the graduated manifest.json is on disk,
    so a graduated plan ships one renderer-owned `## Tasks` INSIDE the sentinels rather than a
    statically pre-emitted duplicate. BEST-EFFORT: a render hiccup must NOT undo an already-valid,
    atomically-written graduation — the tasks.md still carries the EMPTY sentinel pair that the
    next manifest-touch render fills, so the duplicate-`## Tasks` defect stays closed regardless.
    stdout is muted so the capability's NDJSON findings never mix into this tool's own findings."""
    if not tasks_render or not os.path.isfile(tasks_render):
        print("promote-from-inbox: tasks-render capability not resolved (%s); tasks.md ships the "
              "empty sentinel pair, filled on the next render" % tasks_render, file=sys.stderr)
        return
    try:
        subprocess.run(["bash", tasks_render, target_dir],
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)
    except Exception as exc:
        print("promote-from-inbox: tasks-render delegation failed (%s); tasks.md ships the empty "
              "sentinel pair, filled on the next render" % exc, file=sys.stderr)


_FM_KEY_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$')


def fm_value(raw):
    """A frontmatter value as read back: a double-quoted value is JSON-decoded, or loses its
    outer quotes when JSON rejects it (a YAML-only escape stays as written); a single-quoted
    value loses its outer quotes with '' folded to '; a plain value passes through unchanged."""
    if len(raw) >= 2 and raw[0] == raw[-1] == '"':
        try:
            v = json.loads(raw)
            if isinstance(v, str):
                return v
        except ValueError:
            pass
        return raw[1:-1]
    if len(raw) >= 2 and raw[0] == raw[-1] == "'":
        return raw[1:-1].replace("''", "'")
    return raw


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
            fm[m.group(1)] = fm_value(m.group(2).strip())
    body = content[end + len("\n---\n"):]
    return fm, body


# ---- load pillar (inbox contract) ------------------------------------------
with open(rules_path, encoding="utf-8") as fh:
    rules = json.load(fh)
inbox_cfg = rules.get("inbox", {})
inbox_slug_pattern = inbox_cfg.get("slug_pattern", r"^[a-z][a-z0-9-]+$")
plan_slug_pattern = rules.get("slug_rules", {}).get("pattern", r"^[0-9]{2,}-[a-z][a-z0-9-]+$")
inbox_dir = os.path.join(plans_root, "_inbox")
# Settled home (plans-root-relative; fallback EQUALS the pillar contract). A settled
# note still OWNS its slug: capture collision-versioning probes here too, so a
# duplicate-slug capture versions instead of re-minting over settled history.
_settled_rel = inbox_cfg.get("settled_dir", "_inbox/_settled/").strip("/")
settled_dir = os.path.join(plans_root, *_settled_rel.split("/"))
# The funnel statuses a graduation or an --absorb needs (read from the rules, never a literal; an
# absent list stays empty and a graduation then refuses), and the plan statuses that end a plan.
_precond = inbox_cfg.get("graduation_precondition", {})
precond_status = _precond.get("status", []) if isinstance(_precond, dict) else []
if not isinstance(precond_status, list):
    precond_status = []
terminal_status = rules.get("lifecycle", {}).get("terminal_status", [])
if not isinstance(terminal_status, list):
    terminal_status = []


def target_plan_status(manifest_path):
    """The status key of a target plan's manifest; empty when absent or unreadable (an open plan)."""
    try:
        with open(manifest_path, encoding="utf-8") as fh:
            st = json.load(fh).get("status", "")
    except (OSError, ValueError, AttributeError):
        return ""
    return st if isinstance(st, str) else ""


# (A): version-on-collision at _inbox/ CAPTURE.
# Writes a fresh idea-note stub; if _inbox/<slug>.md already exists, versions to
# <slug>-2.md, <slug>-3.md, … (never clobbers an already-captured idea).
if action == "capture":
    if not re.match(inbox_slug_pattern, slug):
        abort("slug '%s' does not match inbox slug_pattern %s" % (slug, inbox_slug_pattern))
    # --amend <existing> appends the piped body to an open note as one dated section: no new
    # note, no disposition (the amended note keeps its own), one idea-amended event.
    if amend_set:
        if (disposition_set or absorbed_set or release_class_set or size_set or reopen_gate_set
                or distinct_from or scope_set):
            abort("--amend takes no disposition, class, size, re-open gate or --distinct-* flag: "
                  "the amended note keeps its own")
        amend_path = os.path.join(inbox_dir, amend_slug + ".md")
        if not re.match(inbox_slug_pattern, amend_slug) or not os.path.isfile(amend_path):
            abort("--amend '%s' does not name an open note under _inbox/" % amend_slug)
        add = ""
        if body_file:
            with open(body_file, encoding="utf-8") as fh:
                add = fh.read().strip("\n")
        if not add.strip():
            abort("--amend needs a piped body: the text to append")
        if next((ln for ln in add.splitlines() if ln.strip()), "").strip() == "---":
            abort("--amend body carries its own frontmatter fence; pipe the body only")
        if dry_run:
            emit({"finding": "idea-amended", "inbox_slug": amend_slug, "note_path": amend_path,
                  "dry_run": True, "detected_at": today})
            print("promote-from-inbox: dry-run amend — would append to %s" % amend_path, file=sys.stderr)
            sys.exit(0)
        with open(amend_path, encoding="utf-8") as fh:
            existing = fh.read()
        if not existing.endswith("\n"):
            existing += "\n"
        fd, tmp = tempfile.mkstemp(dir=inbox_dir, prefix="." + amend_slug + ".", suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(existing + "\n## %s\n\n%s\n" % (today, add))
        os.chmod(tmp, 0o644)
        os.replace(tmp, amend_path)
        emit({"finding": "idea-amended", "inbox_slug": amend_slug, "note_path": amend_path,
              "dry_run": False, "detected_at": today})
        print("promote-from-inbox: amended _inbox/%s.md (one dated section appended)" % amend_slug,
              file=sys.stderr)
        sys.exit(0)
    if distinct_from and not distinct_scope:
        abort("--distinct-from requires a non-empty --distinct-scope line stating what this note "
              "covers that the named note does not")
    if scope_set and not distinct_from:
        abort("--distinct-scope applies with --distinct-from <existing>")
    for d in distinct_from:
        if not os.path.isfile(os.path.join(inbox_dir, d + ".md")):
            abort("--distinct-from '%s' does not name an open note under _inbox/" % d)
    # A disposition decided before capture is stamped now, validated before any write:
    # the value is in backlog_row.disposition_enum, and ABSORB names a target that
    # resolves as backlog-index resolves one (an optional ' :: T-N' suffix stripped; no
    # absolute path, no '..'; <plans_root>/<key>/manifest.json exists).
    if absorbed_set and not (disposition_set and disposition == "ABSORB"):
        abort("--absorbed-into requires --disposition ABSORB")
    # A capture is born decided: the disposition is required, FIX NOW is not a capture value,
    # and each value carries what makes the decision real (a release class and size, an
    # absorb target, a re-open gate). All of it is validated before any write.
    nf_cfg = inbox_cfg.get("note_frontmatter", {})
    valid_classes = nf_cfg.get("release_class_enum", ["local-release", "public-release", "post-release", "docs"])
    valid_sizes = nf_cfg.get("size_enum", ["day", "build"])
    if not disposition_set:
        abort("--disposition is required: a capture is decided at write (one of %s)"
              % rules.get("backlog_row", {}).get("disposition_enum", []))
    if disposition_set:
        valid = rules.get("backlog_row", {}).get("disposition_enum", [])
        if disposition not in valid:
            abort("disposition '%s' is not in backlog_row.disposition_enum %s" % (disposition, valid))
        if disposition == "FIX NOW":
            abort("--disposition 'FIX NOW' is not a capture value: a fix-now item is fixed, not captured")
        if (release_class_set or size_set) and disposition != "STANDALONE":
            abort("--release-class and --size apply to --disposition STANDALONE only")
        if reopen_gate_set and disposition != "NO-BUILD":
            abort("--reopen-gate applies to --disposition NO-BUILD only")
        if disposition == "STANDALONE":
            if release_class not in valid_classes:
                abort("--disposition STANDALONE requires --release-class one of %s (got '%s')"
                      % (valid_classes, release_class))
            if size_value not in valid_sizes:
                abort("--disposition STANDALONE requires --size one of %s (got '%s')"
                      % (valid_sizes, size_value))
        if disposition == "NO-BUILD":
            gate_ids = None
            if reopen_gate_script and os.path.isfile(reopen_gate_script):
                try:
                    lp = subprocess.run(["bash", reopen_gate_script, "--list"], stdin=subprocess.DEVNULL,
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30)
                    if lp.returncode == 0:
                        gate_ids = lp.stdout.decode("utf-8", "replace").split("\n")
                except (OSError, subprocess.SubprocessError):
                    gate_ids = None
            if gate_ids is None:
                abort("--disposition NO-BUILD needs the re-open gate registry, which could not be read "
                      "(hooks/lib/reopen-gate.sh --list)")
            if not reopen_gate_set or reopen_gate not in [g for g in gate_ids if g]:
                abort("--disposition NO-BUILD requires --reopen-gate <id> naming a registered gate %s "
                      "(got '%s')" % ([g for g in gate_ids if g], reopen_gate))
        if disposition == "ABSORB":
            if not absorbed_set:
                abort("--disposition ABSORB requires --absorbed-into <plan-key>")
            key = re.split(r"\s*::\s*", absorbed_into, maxsplit=1)[0].strip()
            if (not key or key.startswith("/") or ".." in key.split("/")
                    or not os.path.isfile(os.path.join(plans_root, key, "manifest.json"))):
                abort("--absorbed-into '%s' does not resolve to a plan dir with a manifest.json "
                      "under the plans root" % absorbed_into)
            tstatus = target_plan_status(os.path.join(plans_root, key, "manifest.json"))
            if tstatus and tstatus in terminal_status:
                abort("--absorbed-into '%s' names a terminal plan (status %s); an absorbed note "
                      "needs an open target" % (absorbed_into, tstatus))
    # A piped body (drained by the bash wrapper into body_file) replaces the three template
    # sections. The script owns the frontmatter, so a body that opens with its own `---`
    # fence is refused before anything is written, never nested under the stamped one.
    body = ""
    if body_file:
        with open(body_file, encoding="utf-8") as fh:
            body = fh.read().strip("\n")
    body_source = "stdin" if body.strip() else "template"
    first_line = next((ln for ln in body.splitlines() if ln.strip()), "")
    if first_line.strip() == "---":
        print("promote-from-inbox: piped body carries its own frontmatter; the script stamps "
              "the frontmatter, so pipe the body only", file=sys.stderr)
        sys.exit(2)
    # A capture is born decided, so a template body here is a hollow decided note — the
    # body the decision was made on never arrived. Refuse it before any write (the check
    # sits ahead of the near-duplicate scorer and the dry-run branch, so nothing lands at
    # any stage); every capture reaching this point carries a disposition.
    if body_source == "template":
        abort("a --capture takes its body as a piped body: a captured note must carry its body. "
              "Pipe it — printf '%%s\\n' \"<body>\" | promote-from-inbox.sh --capture <slug> "
              "--disposition %s ..." % disposition)
    os.makedirs(inbox_dir, exist_ok=True)
    final_slug = slug
    note_path = os.path.join(inbox_dir, final_slug + ".md")
    n = 1
    # A graduation tombstones its note, so the slug is recorded only in the minted plan's
    # manifest `promoted_from`; an unreadable manifest is skipped.
    graduated_refs = set()
    for entry in os.listdir(plans_root):
        mpath = os.path.join(plans_root, entry, "manifest.json")
        if entry.startswith((".", "_")) or not os.path.isfile(mpath):
            continue
        try:
            with open(mpath, encoding="utf-8") as fh:
                pf = json.load(fh).get("promoted_from", "")
        except (OSError, ValueError, AttributeError):
            continue
        if isinstance(pf, str):
            graduated_refs.add(pf.strip())
    # A slug is HELD by an active note, a settled one or a graduated plan — a settled note
    # keeps owning its slug (duplicate capture must version, never re-mint over history).
    while (os.path.exists(note_path)
           or os.path.exists(os.path.join(settled_dir, final_slug + ".md"))
           or "_inbox/%s.md" % final_slug in graduated_refs):
        n += 1
        final_slug = "%s-%d" % (slug, n)
        note_path = os.path.join(inbox_dir, final_slug + ".md")
    title = title_override.strip() or final_slug.replace("-", " ").title()
    # Shortlist the open notes this capture resembles; refuse while any is not named by
    # --distinct-from (the scorer fails closed: an unreadable scorer or threshold aborts).
    if not near_dup_script or not os.path.isfile(near_dup_script):
        abort("the near-duplicate scorer (hooks/lib/inbox-near-dup.sh) could not be found")
    nd_cmd = ["bash", near_dup_script, "--candidates", "--slug", final_slug, "--title", title,
              "--inbox", inbox_dir]
    if body_file:
        nd_cmd += ["--body-file", body_file]
    try:
        nd = subprocess.run(nd_cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=60,
                            env=dict(os.environ, PLANS_RULES_PATH=rules_path))
    except (OSError, subprocess.SubprocessError) as exc:
        abort("the near-duplicate scorer could not be run (%s)" % exc)
    if nd.returncode != 0:
        abort("the near-duplicate scorer exited %d: %s"
              % (nd.returncode, nd.stderr.decode("utf-8", "replace").strip()))
    near = [ln.split("\t")[0] for ln in nd.stdout.decode("utf-8", "replace").split("\n") if ln.strip()]
    if [c for c in near if c not in distinct_from]:
        abort("near-duplicate of open note(s) %s: re-run with --amend <existing> to add to one, or "
              "with --distinct-from <existing> for each plus --distinct-scope \"<what this adds>\""
              % ", ".join(near), candidates=near)
    # Field-parity with templates/idea-note-template.md (same frontmatter key set):
    # title/type/status/created/updated/project/captured_session/disposition/tags. `project:`
    # is stamped mechanically from the resolved owning-spoke key (attribution decided at
    # capture); `captured_session:` is the session id that made the capture (blank if unset).
    # The disposition target keys (promoted_to/absorbed_into) + terminal resolution:
    # are set later (triage / graduation / the backlog-index closure loop), documented
    # in the template comment — not authored empty at capture. A --disposition decided
    # before capture is stamped plain (an enum value); its ABSORB target follows quoted.
    disposition_lines = "disposition:%s\n" % ((" " + disposition) if disposition_set else "")
    if disposition_set and disposition == "ABSORB":
        disposition_lines += "absorbed_into: %s\n" % q(absorbed_into)
    if disposition_set and disposition == "STANDALONE":
        disposition_lines += "release_class: %s\nsize: %s\n" % (release_class, size_value)
    if disposition_set and disposition == "NO-BUILD":
        disposition_lines += "reopen_gate: %s\n" % reopen_gate
    if distinct_from:
        disposition_lines += "distinct_from: %s\ndistinct_scope: %s\n" % (", ".join(distinct_from), q(distinct_scope))
    note = (
        "---\n"
        "title: %s\n"
        "type: idea\n"
        "status: new\n"
        "created: %s\n"
        "updated: %s\n"
        "project: %s\n"
        "captured_session:%s\n"
        "%s"
        "tags: []\n"
        "---\n\n"
    ) % (q(title), today, today, spoke_key, (" " + captured_session) if captured_session else "", disposition_lines)
    if body_source == "stdin":
        note += body + "\n"
    else:
        note += (
            "## Idea\n\n"
            "{One paragraph: what's the idea?}\n\n"
            "## Why\n\n"
            "{Why does it matter? What problem does it solve?}\n\n"
            "## Notes\n\n"
            "{Free-form. Grows in place across funnel stages until graduation.}\n"
        )
    if dry_run:
        emit({"finding": "idea-captured", "inbox_slug": final_slug, "note_path": note_path,
              "versioned": final_slug != slug, "body_source": body_source, "dry_run": True,
              "detected_at": today})
        print("promote-from-inbox: dry-run capture — would write %s" % note_path, file=sys.stderr)
        sys.exit(0)
    fd, tmp = tempfile.mkstemp(dir=inbox_dir, prefix="." + final_slug + ".", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(note)
    os.chmod(tmp, 0o644)
    os.replace(tmp, note_path)
    emit({"finding": "idea-captured", "inbox_slug": final_slug, "note_path": note_path,
          "versioned": final_slug != slug, "body_source": body_source, "dry_run": False,
          "detected_at": today})
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
if not precond_status:
    abort("plans rules carry no inbox.graduation_precondition.status list; the rules bundle "
          "predates this helper")
lead_status = fm.get("status", "").strip()
if lead_status not in precond_status:
    abort("graduation of %s refused: status is '%s'; a note graduates at status %s (plans rules "
          "inbox.graduation_precondition); triage it first: bash %s %s --classification "
          "NOVEL|OVERLAP --rationale \"<one line>\""
          % (slug, lead_status, " or ".join(precond_status), triage_apply, slug),
          status=lead_status, precondition="inbox.graduation_precondition")

note_title = fm.get("title", "").strip()
title = title_override.strip() or note_title or slug.replace("-", " ").title()

# ---- serialize NN numbering against every concurrent mint -----------------
# An exclusive flock(2) on the plans-root directory fd, blocking, held until the new plan
# dir exists. The kernel releases it at exit or death, so no abort path needs an unlock
# and no stale lock can exist; no lock file is created. A dry run takes none.
nn_lock_fd = None
if not dry_run:
    import fcntl
    nn_lock_fd = os.open(plans_root, os.O_RDONLY)
    fcntl.flock(nn_lock_fd, fcntl.LOCK_EX)

# ---- N:1 graduation: validate every --absorb note (under the lock) ---------
# Each absorbed note exists flat as an idea, is neither the lead nor given twice, carries no
# absorbed_into / promoted_to / resolution, and has an empty or ABSORB disposition (any other
# value is a decision this run never overwrites). With --absorb the lock is held until the
# last stamp, so a concurrent --absorb of the same note reads it stamped and refuses.
absorb_notes = []  # (slug, path, original bytes)
for a in absorb_slugs:
    if not re.match(inbox_slug_pattern, a):
        abort("--absorb '%s' does not match inbox slug_pattern %s" % (a, inbox_slug_pattern))
    if a == slug:
        abort("--absorb %s names the lead note" % a)
    if a in [x[0] for x in absorb_notes]:
        abort("--absorb %s is given twice" % a)
    apath = os.path.join(inbox_dir, a + ".md")
    if not os.path.isfile(apath):
        abort("--absorb %s: no flat note _inbox/%s.md" % (a, a), absorb=a)
    with open(apath, "rb") as fh:
        araw = fh.read()
    try:
        afm, _abody = split_frontmatter(araw.decode("utf-8"))
    except UnicodeDecodeError:
        afm = None
    if afm is None or afm.get("type", "").strip() != "idea":
        abort("--absorb %s: _inbox/%s.md is not a type: idea note" % (a, a), absorb=a)
    a_status = afm.get("status", "").strip()
    if a_status not in precond_status:
        abort("--absorb %s: status is '%s'; a note is absorbed at status %s (plans rules "
              "inbox.graduation_precondition); triage it first: bash %s %s --classification "
              "NOVEL|OVERLAP --rationale \"<one line>\""
              % (a, a_status, " or ".join(precond_status), triage_apply, a),
              absorb=a, status=a_status, precondition="inbox.graduation_precondition")
    for k in ("absorbed_into", "promoted_to", "resolution"):
        if afm.get(k, "").strip():
            abort("--absorb %s: the note already carries %s" % (a, k), absorb=a)
    if afm.get("disposition", "").strip() not in ("", "ABSORB"):
        abort("--absorb %s: the note carries disposition %s; only an empty or ABSORB "
              "disposition is stamped" % (a, afm.get("disposition", "").strip()), absorb=a)
    absorb_notes.append((a, apath, araw))

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

cb = cohort_base(plan_dir)

# This literal is its OWN mint surface: it discards the brief template's
# frontmatter below and prepends this block, so the full cohort must be
# emitted here in its own right — template conformance does not reach it.
brief_frontmatter = (
    "---\n"
    "title: %s\n"
    "type: ideation-brief\n"
    "description: %s\n"
    "created: %s\n"
    "updated: %s\n"
    "id: %s-ideation-brief\n"
    "schema_version: 1\n"
    "promoted_from: _inbox/%s.md\n"
    "promoted_at: %s\n"
    "---\n\n"
) % (q(title + " — Ideation Brief"), q("Ideation brief for %s." % title), today, today, cb, slug, today)


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
            .replace("{{slug}}", slug)
            .replace("{{cohort_base}}", cb))


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
    "---\ntitle: %s\ntype: spec\ndescription: %s\n"
    "created: %s\nupdated: %s\nid: %s-spec\nschema_version: 1\n---\n\n"
    "# %s — Spec\n\n"
    "**Goal:** {One sentence. When this ships, what is true that wasn't true before?}\n\n"
    "## Problem Statement\n\n{2-4 sentences — frozen at scaffold time.}\n\n"
    "## Constraints\n\n- {Hard constraint}\n- {Anti-scope lock}\n\n"
    "## Solution Approach\n\n{3-8 sentences.}\n\n"
    "{Amendments: a spec-changing ruling runs `plan-rule --spec-change`, which mints "
    "decisions/ADR-NN-<slug>.md and adds one pointer line under `## Amendment register`.}\n"
) % (q(title + " — Spec"), q("Spec for %s." % title), today, today, cb, title)

# RULING 2: ship frontmatter + preface + an EMPTY tasks:start/tasks:end sentinel
# pair ONLY. The outside `## Tasks` + `### T-1` block is GONE — librarian:tasks-render (the
# single writer of the region,/R-37) fills it from manifest.tasks[] via delegate_render()
# after the graduation scaffold lands, so a graduated plan never carries a duplicate `## Tasks`.
tasks_content = (
    "---\ntitle: %s\ntype: tasks\ndescription: %s\n"
    "created: %s\nupdated: %s\nid: %s-tasks\nschema_version: 1\n---\n\n"
    "# %s — Tasks\n\n**Spec:** `%s/spec.md`\n**Last Updated:** %s\n\n"
    "## Status Key\n\n`not-started` | `in-progress` | `done` | `blocked` | `cut`\n\n"
    "<!-- ledger-at-top + per-task-at-bottom; the tasks:start/end sentinel pair bounds the "
    "librarian:tasks-render region (the SINGLE writer,/R-37). This graduation emitter "
    "ships an EMPTY pair and delegates the fill to tasks-render at scaffold time (RULING 2 / "
    ") — NEVER hand-author inside the sentinels; task-state SoT = manifest.tasks[]. -->\n\n"
    "<!-- tasks:start -->\n\n<!-- tasks:end -->\n"
) % (q(title + " — Tasks"), q("Manifest-derived task replica for %s." % title),
     today, today, cb, title, plan_dir, today)

handoff_content = (
    "---\ntitle: %s\ntype: handoff\ndescription: %s\n"
    "created: %s\nupdated: %s\nid: %s-handoff\nschema_version: 1\n---\n\n"
    "# %s — Handoff\n\nAppend-only session record. Newest entry at top.\n\n"
    "## Session 0 — scaffold (promoted from _inbox)\n\n**Date:** %s\n**Next session:** T-1 — Define spec\n\n"
    "### Scope\n{Graduated from _inbox/%s.md. Idea body migrated to 00-ideation-brief.md.}\n\n---\n"
) % (q(title + " — Handoff"), q("Append-only session handoff record for %s." % title),
     today, today, cb, title, today, slug)

manifest = {
    "schema_version": 1,
    "title": title,
    "project": spoke_key,
    "spec_path": os.path.join(plan_dir, "spec.md"),
    "architecture_path": None,
    "type": "plan",
    "status": "planned",
    "phase_2_scaffolded_at": today,
    # T-3: seed `updated` at graduation (mechanical seeding at every
    # manifest-creation surface) so the backlog-index Updated cell is populated from birth.
    "updated": today,
    "research_driven": True,
    "promoted_from": "_inbox/%s.md" % slug,
    "disposition": "STANDALONE",
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
absorbed_refs = ["_inbox/%s.md" % a for a, _p, _r in absorb_notes]
if absorbed_refs:
    manifest["absorbed_notes"] = absorbed_refs
manifest_content = json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"

files = {
    "spec.md": spec_content,
    "tasks.md": tasks_content,
    "handoff.md": handoff_content,
    "00-ideation-brief.md": brief_content,
    "manifest.json": manifest_content,
}

# ---- dry-run: report + exit, no writes -------------------------------------
if dry_run:
    dry_event = {
        "finding": "idea-graduated", "inbox_slug": slug, "plan_slug": plan_slug,
        "plan_dir": plan_dir, "title": title, "project": spoke_key,
        "body_chars_migrated": len(note_body.strip()),
        "tombstoned": False, "dry_run": True, "detected_at": today,
    }
    if absorbed_refs:
        dry_event["absorbed_notes"] = absorbed_refs
    emit(dry_event)
    print("promote-from-inbox: dry-run — would create %s and remove %s"
          % (plan_dir, note_path), file=sys.stderr)
    sys.exit(0)

# ---- scaffold (block-and-log; rollback on any failure) ---------------------
created = False
try:
    os.makedirs(plan_dir)
    created = True
    if not absorb_notes:
        os.close(nn_lock_fd)  # the plan dir exists: its NN is taken, release the numbering lock
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

# RULING 2: renderer fills the empty sentinel region from manifest.tasks[] (best-effort).
delegate_render(plan_dir)

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


def stamp_absorbed(text, key):
    """One absorbed note with disposition ABSORB, absorbed_into <key> (a bare plan key is a
    safe plain scalar) and updated today in its frontmatter; the body bytes are untouched."""
    end = text.find("\n---\n", 4)
    out, seen_disposition, seen_updated = [], False, False
    for line in text[4:end].split("\n"):
        m = _FM_KEY_RE.match(line)
        name = m.group(1) if m else None
        if name == "disposition":
            out += ["disposition: ABSORB", "absorbed_into: %s" % key]
            seen_disposition = True
        elif name == "absorbed_into":
            continue  # validated blank; replaced by the line written after disposition:
        elif name == "updated":
            out.append("updated: %s" % today)
            seen_updated = True
        else:
            out.append(line)
    if not seen_disposition:
        out += ["disposition: ABSORB", "absorbed_into: %s" % key]
    if not seen_updated:
        out.append("updated: %s" % today)
    return "---\n" + "\n".join(out) + text[end:]


# ---- stamp each absorbed note: all or nothing with the scaffold ------------
# Each note is replaced atomically (temp + replace). If any stamp fails, the stamped notes
# get their original bytes back, the plan dir is removed and the lead note stays.
stamped = []
try:
    for a, apath, araw in absorb_notes:
        stamped_text = stamp_absorbed(araw.decode("utf-8"), plan_slug)
        fd, tmp = tempfile.mkstemp(dir=inbox_dir, prefix="." + a + ".", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
                fh.write(stamped_text)
            shutil.copymode(apath, tmp)
            os.replace(tmp, apath)
        except BaseException:
            if os.path.exists(tmp):
                os.remove(tmp)
            raise
        stamped.append((apath, araw))
except Exception as exc:
    for apath, araw in stamped:
        with open(apath, "wb") as fh:
            fh.write(araw)
    shutil.rmtree(plan_dir, ignore_errors=True)
    abort("absorbed-note stamp failed (%s); stamped notes restored, plan dir removed, "
          "lead note untouched" % exc)
if absorb_notes:
    os.close(nn_lock_fd)  # the last absorbed note is stamped: release the numbering lock

os.remove(note_path)  # tombstone: body losslessly preserved in the brief

# Workshop re-key: <inbox-slug>/ -> <inbox-slug>-<plan_slug>/, the key form library-scrub
# resolves to this plan. Best-effort: a missing dir or a taken target leaves both untouched.
ws_rekeyed = ""
if workshop_dir and os.path.isdir(os.path.join(workshop_dir, slug)):
    ws_dst = os.path.join(workshop_dir, "%s-%s" % (slug, plan_slug))
    if not os.path.lexists(ws_dst):
        try:
            os.rename(os.path.join(workshop_dir, slug), ws_dst)
            ws_rekeyed = ws_dst
        except OSError:
            pass

event = {
    "finding": "idea-graduated", "inbox_slug": slug, "plan_slug": plan_slug,
    "plan_dir": plan_dir, "title": title, "project": spoke_key,
    "body_chars_migrated": len(note_body.strip()),
    "tombstoned": True, "dry_run": False, "detected_at": today,
}
if ws_rekeyed:
    event["workshop_rekeyed"] = ws_rekeyed
if absorbed_refs:
    event["absorbed_notes"] = absorbed_refs
emit(event)
print("promote-from-inbox: graduated _inbox/%s → %s (note removed)"
      % (slug, plan_slug), file=sys.stderr)
if ws_rekeyed:
    print("promote-from-inbox: workshop %s → %s" % (slug, os.path.basename(ws_rekeyed)),
          file=sys.stderr)
PY
