#!/bin/bash
# rules-compact — compact a hook-backstopped rule to an always-on STUB, moving
# its narrative out of the loaded corpus.
#
# WHY THIS EXISTS: every file under a `rules/` directory is re-sent with each
# request of each session and re-created for every subagent, so a byte of rule
# narrative is paid on every turn of every worker. A rule whose enforcement is a
# hook that fires regardless of model cooperation does not need its narrative in
# that always-on channel — the hook already blocks the behaviour at its trigger.
# What the hook does NOT carry is the operative instruction the operator must
# hold, the escape hatch, and the one-line why. Compaction keeps exactly those
# three things in `rules/` and moves everything else to a rationale file OUTSIDE
# the rules directory, where nothing loads it.
#
# FAIL-SAFE: compaction is refused unless the backstop RESOLVES — the rule must
# declare `enforced_by:` naming a hook script that is registered in
# settings.json, present on disk, and INLINE-BLOCKING. A rule whose backstop
# cannot be resolved keeps its full text; the capability never trades a rule's
# body for a hook that is not there.
#
# THE STUB CONTRACT — ONE mechanism, and it is markers.
#
# The operator marks the source. Two trailing HTML-comment markers, and nothing
# else, decide what survives:
#
#   <!-- keep -->   on every OPERATIVE line (the instruction the operator must
#                   hold) and on the ESCAPE-HATCH line. Repeatable.
#   <!-- why -->    on the ONE line that states why the rule exists. Exactly one.
#
# A marker is recognised only at END OF LINE, so a marker inside prose is inert.
# A line carrying both markers is treated as the why (it is emitted once, in the
# why position, never twice).
#
# The stub is then, in order:
#   1. the ORIGINAL frontmatter block, verbatim, plus two stamped fields —
#      `compacted_from_bytes:` (the source size) and `rationale:` (the resolved
#      absolute path of the rationale file);
#   2. every `<!-- keep -->` line, in source order, with its marker stripped;
#   3. the `<!-- why -->` line, marker stripped;
#   4. exactly ONE pointer line: `Full rationale: <resolved absolute path>`.
#
# The rationale file is the ORIGINAL FILE BYTES, verbatim. Round-trip is
# lossless BY CONSTRUCTION: nothing is summarised, rewritten or dropped — the
# source is moved, and a subset of its lines is copied forward. Reading the stub
# plus the rationale reproduces the source exactly.
#
# Marked but unmarkable: a rule that declares a resolvable backstop yet carries
# no `<!-- keep -->` line, or no `<!-- why -->` line, is REFUSED. An unmarked
# rule would compact to an empty stub, which is a silent content loss.
#
# WHEN A RULE IS COMPACTABLE (all four, in this order):
#   0. It is not pipeline-owned. A file with NO frontmatter whose basename is
#      `NN-*.md` or `README.md` is a seed-once installer entry — refused
#      unconditionally, marked or not. The direction is fail-safe: a
#      hand-authored rule without frontmatter is misclassified as pipeline-owned
#      and merely refused (add a `description:` line and re-run); nothing
#      pipeline-owned can ever be compacted.
#   1. Its frontmatter declares `enforced_by:`.
#   2. That value names a hook script REGISTERED in settings.json (any
#      hooks.<event>[].hooks[].command whose basename matches) and PRESENT at
#      <hooks dir>/<basename>.
#   3. That script is INLINE-BLOCKING per the allowlist declared below.
#
# THE INLINE-BLOCKING ALLOWLIST (declared, not inferred). Only a PreToolUse hook
# can emit a deny inside the tool call itself, so only those qualify:
#       pre-write-guard.sh   pre-asq-guard.sh
# Extend the list by adding a script basename to INLINE_BLOCKING below. A
# session-close librarian capability — the handoff-disposition check is the
# worked case — is NOT inline-blocking: it is reached through a detached
# SessionEnd spawn whose exit status is discarded, so it cannot block, and a
# rule backed only by it keeps its full text.
#
# WORKED EXAMPLE — the three hook-backstopped operator rules.
#
# In a corpus of behavioural-doctrine rules, exactly three are backed by an
# inline-blocking hook, and they are the whole compactable set:
#
#   rule (by purpose)                       enforced_by            before -> stub
#   decision-quality protocol (the          pre-asq-guard.sh       7,093B -> ~1.2KB
#     4-element research pass before a
#     substantive fork)
#   hard-constraints-override-spec-text     pre-asq-guard.sh       2,015B -> ~600B
#     (a stated constraint beats a spec)
#   keep the claude-mem SessionEnd hook     pre-write-guard.sh     2,641B -> ~500B
#     running (R-24 settings.json DENY)
#
# What each stub keeps is exactly what its hook does NOT carry: for the
# decision-quality rule, the four elements as a list (the hook's deny enforces
# an annotation grammar, not the pass itself); for keep-claude-mem, the
# `CLAUDE_MEM_DISABLE_OK=1` escape hatch (the hook denies removal but teaches
# nothing); for hard-constraints, the how-to-apply bullets (the hook fires only
# on AskUserQuestion, so a prose option table is outside it).
#
# The follow-ups-disposition rule is NOT in the set, and the reason is the
# predicate: its backstop is the session-close handoff-disposition capability,
# which is triggered deterministically but not inline-blocking. It keeps its
# full text.
#
# ON A FRESH INSTALL `--propose` LISTS ZERO CANDIDATES. No seeded rule carries
# `enforced_by:` — the field is an operator stamp, and the stamp is the
# operator's assertion that the named hook really backs this rule. Nothing is
# compacted until it is stamped and marked. This example is DOCUMENTATION: it
# describes what compaction would do, and running it is always the operator's
# own `--apply`.
#
# Output Contract (per the skill-creation rule):
#   Files written (ONLY in --apply mode; propose writes nothing):
#     1. $RATIONALE_DIR/<rule>.md   — the source file, byte-for-byte (written
#        FIRST, so the stub's pointer is valid the instant the stub lands)
#     2. $RULES_DIR/<rule>.md       — the stub (atomic temp+rename)
#   Schema gated by: schemas/rules-schema.json (Draft-07). The STUB frontmatter
#     is validated BEFORE either write (jsonschema when importable; structural
#     fallback mirroring the contract otherwise).
#   Failure mode: BLOCK-AND-LOG. A rule that fails any check is skipped with a
#     `rules-compact-refused` finding carrying `reason`; no partial write.
#   Idempotent: a stub already carrying `rationale:` with that file present is
#     reported `already-compacted` and left byte-unchanged.
#
# TWO DISPOSITIONS FOR THE SAME REFUSAL, because a survey must not fail:
#   TARGETED (one or more `--rule <name>`): a refusal is TERMINAL — the finding
#     is emitted and the run exits 3. Asking to compact a specific rule that
#     cannot be compacted is an error.
#   SWEEP (no `--rule`): every non-candidate emits the same finding, with the
#     same reason, and is skipped — but the run exits 0. A sweep over a real
#     rules directory always meets pipeline-owned and unstamped files; reporting
#     them is the point, failing on them would make the survey unusable.
#
# NDJSON shape (one line per rule):
#   candidate: { "finding":"rules-compact", "file":"<rule>.md",
#                "category":"compaction-candidate", "enforced_by":"<hook>",
#                "source_bytes":"N", "stub_bytes":"N", "stub_pct":"NN.N",
#                "rationale":"<path>", "rules_dir":"<dir>" }
#   applied:   { "finding":"rules-compact", "category":"compacted",
#                "written":"<stub path>", ... same measurements }
#   refused:   { "finding":"rules-compact-refused", "file":"<rule>.md",
#                "reason":"<why>", "rules_dir":"<dir>" }
#   no-op:     { "finding":"rules-compact", "category":"already-compacted", ... }
#
# Tier: judgment. requires_confirmation: true (propose-then-confirm; --apply is
# the confirm gate). Cron block: skip-non-interactive.
#
# CLI:
#   rules-compact.sh                    # propose: survey $RULES_DIR (NO writes)
#   rules-compact.sh --propose          # same, explicit
#   rules-compact.sh --rule <name>      # target one rule (repeatable); refusal exits 3
#   rules-compact.sh --apply            # confirm: write rationale + stub
#   rules-compact.sh --dry-run          # summary counts only; no findings/writes
#   rules-compact.sh --help             # usage
#
# Env overrides:
#   CLAUDE_HOME        live install root (default $HOME/.claude)
#   RULES_DIR          rules corpus to scan   (default $CLAUDE_HOME/rules)
#   RATIONALE_DIR      rationale home         (default $CLAUDE_HOME/rules-rationale)
#   SETTINGS_PATH      hook registry to read  (default $CLAUDE_HOME/settings.json)
#   HOOKS_DIR          hook scripts on disk   (default $CLAUDE_HOME/hooks)
#   RULES_SCHEMA_PATH  (default $CLAUDE_HOME/schemas/rules-schema.json)
#   FINDINGS_OUTPUT    findings routing (append file; default stdout)
#   FOUNDATION_TEST_MODE  bypass the non-interactive guard (test/CI runners)
#
# Exit codes: 0 ok (survey, or apply with no targeted refusal); 2 usage error;
# 3 a TARGETED rule was refused.
#
# Bash 3.2 clean per R-23. Data reaches python via argv, never a piped stdin.

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"

if [ -z "${CLAUDE_STATE_ROOT:-}" ]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && . "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && . "$_REPO_LIB/paths.sh"; }
fi
# The finding contract. The python emitter below writes the identical line shape
# (hooks/lib/findings.sh :: emit_finding) so one reader parses both halves.
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && . "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || . "$_REPO_LIB/findings.sh"

APPLY="false"
DRY_RUN="false"
TARGETS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --propose) APPLY="false"; shift ;;
    --apply) APPLY="true"; shift ;;
    --rule)
      [ $# -ge 2 ] || { echo "rules-compact: --rule needs a rule name" >&2; exit 2; }
      TARGETS="${TARGETS}:${2}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) sed -n '2,168p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "rules-compact: unknown flag '$1'" >&2; exit 2 ;;
  esac
done
TARGETS="${TARGETS#:}"

# Judgment-tier non-interactive guard, mirroring memory-globalize: an
# operator-attended Claude Code session runs; a genuinely headless invocation
# skips, so no cron path can ever rewrite a rule unattended.
if [ -z "${FOUNDATION_TEST_MODE:-}" ] && [ -z "${CLAUDECODE:-}" ] \
   && [ -z "${TTY:-}" ] && ! [ -t 0 ]; then
  echo "rules-compact: skipped (non-interactive)" >&2
  exit 0
fi

command -v python3 >/dev/null 2>&1 || {
  echo "rules-compact: python3 unavailable — clean skip (nothing measured)" >&2
  exit 0
}

RULES_DIR_RES="${RULES_DIR:-$CLAUDE_HOME_RES/rules}"
RATIONALE_DIR_RES="${RATIONALE_DIR:-$CLAUDE_HOME_RES/rules-rationale}"
SETTINGS_PATH_RES="${SETTINGS_PATH:-$CLAUDE_HOME_RES/settings.json}"
HOOKS_DIR_RES="${HOOKS_DIR:-$CLAUDE_HOME_RES/hooks}"

SCHEMA_PATH="${RULES_SCHEMA_PATH:-}"
if [ -z "$SCHEMA_PATH" ]; then
  if [ -f "$CLAUDE_HOME_RES/schemas/rules-schema.json" ]; then
    SCHEMA_PATH="$CLAUDE_HOME_RES/schemas/rules-schema.json"
  fi
fi

if [ ! -d "$RULES_DIR_RES" ]; then
  echo "rules-compact: no rules dir at $RULES_DIR_RES — nothing to do" >&2
  exit 0
fi

python3 - "$RULES_DIR_RES" "$RATIONALE_DIR_RES" "$SETTINGS_PATH_RES" \
           "$HOOKS_DIR_RES" "$SCHEMA_PATH" "$APPLY" "$DRY_RUN" "$TARGETS" <<'PY'
import json
import os
import re
import sys
import tempfile

rules_dir = sys.argv[1]
rationale_dir = sys.argv[2]
settings_path = sys.argv[3]
hooks_dir = sys.argv[4]
schema_path = sys.argv[5]
apply_mode = sys.argv[6] == "true"
dry_run = sys.argv[7] == "true"
targets = [t for t in sys.argv[8].split(":") if t]

# The declared inline-blocking allowlist. Extend by adding a script basename.
INLINE_BLOCKING = ("pre-write-guard.sh", "pre-asq-guard.sh")

CLASS_A_RE = re.compile(r'^(?:\d{2}-.*\.md|README\.md)$')
FM_KEY_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$')
KEEP_RE = re.compile(r'^(.*?)\s*<!--\s*keep\s*-->\s*$')
WHY_RE = re.compile(r'^(.*?)\s*<!--\s*why\s*-->\s*$')


def emit(payload):
    out = os.environ.get("FINDINGS_OUTPUT", "")
    line = json.dumps(payload, ensure_ascii=False, separators=(", ", ": "))
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")


def refuse(entry, reason):
    if not dry_run:
        emit({"finding": "rules-compact-refused", "file": entry,
              "reason": reason, "rules_dir": rules_dir})


# ---- optional jsonschema gate (degrade to structural if unavailable) --------
_schema = None
if schema_path and os.path.isfile(schema_path):
    try:
        with open(schema_path, encoding="utf-8") as fh:
            _schema = json.load(fh)
    except (OSError, ValueError):
        _schema = None

_validator = None
if _schema is not None:
    try:
        import jsonschema  # type: ignore
        _validator = jsonschema.Draft7Validator(_schema)
    except ImportError:
        _validator = None


def validate_stub_fm(fm):
    """Return (ok, reason) for the stub frontmatter. Structural fallback mirrors
    the rules-schema contract: a non-empty description, and enforced_by a
    non-empty string."""
    if _validator is not None:
        errs = sorted(_validator.iter_errors(fm), key=lambda e: e.path)
        if errs:
            return False, "rules-schema: %s" % errs[0].message
        return True, ""
    if not fm.get("description"):
        return False, "structural: missing required 'description'"
    if not isinstance(fm.get("enforced_by", ""), str) or not fm.get("enforced_by"):
        return False, "structural: 'enforced_by' must be a non-empty string"
    return True, ""


def read_text(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except (OSError, UnicodeDecodeError):
        return None


def split_frontmatter(text):
    """Return (fm_block, body) or (None, text) when there is no closed block."""
    if not text.startswith("---\n"):
        return None, text
    end = text.find("\n---\n", 3)
    if end < 0:
        return None, text
    return text[4:end], text[end + 5:]


def parse_fm(fm_block):
    fm = {}
    for line in fm_block.split("\n"):
        m = FM_KEY_RE.match(line)
        if m:
            fm[m.group(1)] = m.group(2).strip()
    return fm


def unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
        return v[1:-1]
    return v


def registered_hook_basenames(path):
    """Every hooks.<event>[].hooks[].command basename in settings.json."""
    names = set()
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return names
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        return names
    for groups in hooks.values():
        if not isinstance(groups, list):
            continue
        for group in groups:
            if not isinstance(group, dict):
                continue
            for hook in group.get("hooks", []) or []:
                if isinstance(hook, dict) and isinstance(hook.get("command"), str):
                    names.add(os.path.basename(hook["command"].strip()))
    return names


def atomic_write(target, content):
    d = os.path.dirname(target)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(content)
        os.replace(tmp, target)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def build_stub(fm_block, body, source_bytes, rationale_path):
    """Return (stub_text, reason) — reason non-empty means refuse."""
    kept, why = [], None
    for line in body.split("\n"):
        mw = WHY_RE.match(line)
        if mw:
            if why is None:
                why = mw.group(1).rstrip()
            continue
        mk = KEEP_RE.match(line)
        if mk:
            kept.append(mk.group(1).rstrip())
    if not kept:
        return "", "no '<!-- keep -->' marker: an unmarked rule would compact to an empty stub"
    if why is None:
        return "", "no '<!-- why -->' marker: the stub must carry the one-line why"
    out = ["---"]
    out.extend(fm_block.split("\n"))
    out.append("compacted_from_bytes: %d" % source_bytes)
    out.append("rationale: %s" % rationale_path)
    out.append("---")
    out.extend(kept)
    out.append("")
    out.append(why)
    out.append("")
    out.append("Full rationale: %s" % rationale_path)
    return "\n".join(out) + "\n", ""


registered = registered_hook_basenames(settings_path)

counts = {"scanned": 0, "candidates": 0, "compacted": 0, "refused": 0,
          "already": 0}
targeted_refusal = False

if targets:
    entries = []
    for t in targets:
        entries.append(t if t.endswith(".md") else t + ".md")
else:
    entries = [e for e in sorted(os.listdir(rules_dir)) if e.endswith(".md")]

for entry in entries:
    full = os.path.join(rules_dir, entry)
    if not os.path.isfile(full):
        counts["refused"] += 1
        targeted_refusal = targeted_refusal or bool(targets)
        refuse(entry, "no such rule under %s" % rules_dir)
        continue
    counts["scanned"] += 1

    text = read_text(full)
    if text is None:
        counts["refused"] += 1
        targeted_refusal = targeted_refusal or bool(targets)
        refuse(entry, "unreadable")
        continue

    fm_block, body = split_frontmatter(text)

    # (0) pipeline-owned refusal — unconditional, marked or not.
    if fm_block is None:
        counts["refused"] += 1
        targeted_refusal = targeted_refusal or bool(targets)
        if CLASS_A_RE.match(entry):
            refuse(entry, "pipeline-owned seed entry (no frontmatter, installer "
                          "naming) — a change to it ships as an installer migration")
        else:
            refuse(entry, "no frontmatter block: cannot declare 'enforced_by'")
        continue

    fm = parse_fm(fm_block)

    # Idempotency: an already-compacted stub is a no-op, never a refusal.
    already = unquote(fm.get("rationale", ""))
    if already and os.path.isfile(already):
        counts["already"] += 1
        if not dry_run:
            emit({"finding": "rules-compact", "file": entry,
                  "category": "already-compacted", "rationale": already,
                  "rules_dir": rules_dir})
        continue

    enforced = unquote(fm.get("enforced_by", ""))
    if not enforced:
        counts["refused"] += 1
        targeted_refusal = targeted_refusal or bool(targets)
        refuse(entry, "no 'enforced_by:' — the rule declares no hook backstop")
        continue

    hook = os.path.basename(enforced)
    if enforced.startswith("probe:"):
        counts["refused"] += 1
        targeted_refusal = targeted_refusal or bool(targets)
        refuse(entry, "'probe:' backstop variant names no hook script and is not "
                      "inline-blocking")
        continue
    if hook not in registered:
        counts["refused"] += 1
        targeted_refusal = targeted_refusal or bool(targets)
        refuse(entry, "backstop %s is not registered in %s" % (hook, settings_path))
        continue
    if not os.path.isfile(os.path.join(hooks_dir, hook)):
        counts["refused"] += 1
        targeted_refusal = targeted_refusal or bool(targets)
        refuse(entry, "backstop %s is registered but absent from %s" % (hook, hooks_dir))
        continue
    if hook not in INLINE_BLOCKING:
        counts["refused"] += 1
        targeted_refusal = targeted_refusal or bool(targets)
        refuse(entry, "backstop %s is not inline-blocking (only a PreToolUse hook "
                      "can deny inside the tool call)" % hook)
        continue

    source_bytes = len(text.encode("utf-8"))
    rationale_path = os.path.join(rationale_dir, entry)
    stub, reason = build_stub(fm_block, body, source_bytes, rationale_path)
    if reason:
        counts["refused"] += 1
        targeted_refusal = targeted_refusal or bool(targets)
        refuse(entry, reason)
        continue

    # Schema gate on the STUB frontmatter, BEFORE any write. Only scalars the
    # parser can faithfully represent are validated; a key whose value is an
    # indented block (e.g. a `paths:` list) is omitted rather than misread.
    stub_fm = {}
    for k, v in fm.items():
        v = unquote(v)
        if v:
            stub_fm[k] = v
    stub_fm["enforced_by"] = hook
    ok, sreason = validate_stub_fm(stub_fm)
    if not ok:
        counts["refused"] += 1
        targeted_refusal = targeted_refusal or bool(targets)
        refuse(entry, sreason)
        continue

    stub_bytes = len(stub.encode("utf-8"))
    pct = (100.0 * stub_bytes / source_bytes) if source_bytes else 0.0
    counts["candidates"] += 1

    if apply_mode:
        # Rationale FIRST, so the stub's pointer resolves the instant it lands.
        atomic_write(rationale_path, text)
        atomic_write(full, stub)
        counts["compacted"] += 1
        if not dry_run:
            emit({"finding": "rules-compact", "file": entry,
                  "category": "compacted", "enforced_by": hook,
                  "source_bytes": str(source_bytes), "stub_bytes": str(stub_bytes),
                  "stub_pct": "%.1f" % pct, "rationale": rationale_path,
                  "written": full, "rules_dir": rules_dir})
    else:
        if not dry_run:
            emit({"finding": "rules-compact", "file": entry,
                  "category": "compaction-candidate", "enforced_by": hook,
                  "source_bytes": str(source_bytes), "stub_bytes": str(stub_bytes),
                  "stub_pct": "%.1f" % pct, "rationale": rationale_path,
                  "rules_dir": rules_dir})

if dry_run:
    mode = "apply" if apply_mode else "propose"
    print("rules-compact: dry-run summary (mode=%s, dir=%s)" % (mode, rules_dir),
          file=sys.stderr)
    print("  scanned=%d candidates=%d compacted=%d refused=%d already_compacted=%d"
          % (counts["scanned"], counts["candidates"], counts["compacted"],
             counts["refused"], counts["already"]), file=sys.stderr)

sys.exit(3 if targeted_refusal else 0)
PY
RC=$?

exit "$RC"
