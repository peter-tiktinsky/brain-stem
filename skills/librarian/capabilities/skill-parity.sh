#!/bin/bash
# skill-parity — Mechanical frontmatter parity check for ~/.claude/skills/*/SKILL.md.
#
# Handles the mechanical (bash-checkable) subset of skill-config auditing.
# Bash-vs-LLM boundary: this capability handles checks resolvable
# without body interpretation; richer frontmatter proposals (effort calibration,
# argument-hint, description rewrite, disable-model-invocation heuristics) live
# outside this capability, where LLM judgment is available.
#
# Checks per skill:
#   1. YAML frontmatter block present (starts with `---` on line 1)
#   2. `name:` field present
#   3. `name:` value matches directory basename
#   4. `description:` field present
#   5. `description:` value length 1–1024 chars
#   6. every top-level frontmatter key is one Claude Code recognizes (the twenty
#      listed in RECOGNIZED_KEYS below) or one of the named extension keys
#      (EXTENSION_KEYS: `type`); the platform ignores any other key without a
#      warning, so a misspelled key silently does nothing. Free-form data of
#      your own belongs under the `metadata:` map, whose nested keys are not read.
#   7. `description:` plus `when_to_use:` (joined by one space) fits the 1,536
#      characters the skill listing keeps by default; plain, single-quoted,
#      double-quoted and block (`>`, `|` and their `-`/`+` forms) scalars are
#      resolved before counting
#
# Findings (one per skill, per check failure):
#   - skill-parity-missing-frontmatter
#   - skill-parity-missing-name
#   - skill-parity-name-mismatch         (attrs: expected, actual)
#   - skill-parity-missing-description
#   - skill-parity-description-length    (attrs: length, limit)
#   - skill-parity-unknown-frontmatter-key  (attrs: skill, key)
#   - skill-parity-listing-length        (attrs: skill, length, limit)
#
# CLI:
#   skill-parity.sh                      # --check default
#   skill-parity.sh --check              # emit findings, no writes
#   skill-parity.sh --fix                # print the source-side fix for a missing `name:`; writes nothing
#   skill-parity.sh --scope <dir>        # narrow to one skill directory
#   skill-parity.sh --dry-run            # summary counts only
#
# `--fix` authority:
#   PRINTS:  the file and the `name:` line (the directory basename) to add in the
#            source repo, where the skill is authored
#   NEVER:   write any file, modify existing fields, rewrite descriptions
#
# Bash 3.2 clean per R-23.

set -euo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"

if [[ -z "${VAULT_LOGS:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; }
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || source "$_REPO_LIB/findings.sh"

SCOPE=""
MODE="check"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)   SCOPE="$2"; shift 2 ;;
    --check)   MODE="check"; shift ;;
    --fix)     MODE="fix"; shift ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    *) echo "skill-parity: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

SKILLS_ROOT="${SKILL_PARITY_SKILLS_ROOT_OVERRIDE:-$CLAUDE_HOME_RES/skills}"
TARGET_ROOT="${SCOPE:-$SKILLS_ROOT}"

python3 - "$TARGET_ROOT" "$SKILLS_ROOT" "$MODE" "$DRY_RUN" <<'PY'
import json, os, re, sys

target_root, skills_root, mode, dry_run_s = sys.argv[1:5]
dry_run = (dry_run_s == "true")
findings_out = os.environ.get("FINDINGS_OUTPUT", "")

# The twenty top-level SKILL.md frontmatter keys Claude Code recognizes; it ignores any other key
# without reporting an error, so a misspelling would silently do nothing.
RECOGNIZED_KEYS = frozenset((
    "name", "description", "when_to_use", "argument-hint", "arguments",
    "disable-model-invocation", "user-invocable", "allowed-tools", "disallowed-tools",
    "model", "effort", "context", "agent", "background", "hooks", "paths", "shell",
    "metadata", "license", "compatibility",
))
# The named extension set: the one key outside the recognized list that a shipped skill carries.
EXTENSION_KEYS = ("type",)
# The skill listing keeps this many characters of description plus when_to_use by default
# (the platform setting skillListingMaxDescChars).
LISTING_LIMIT = 1536

def emit(payload):
    line = json.dumps(payload, ensure_ascii=False)
    if findings_out:
        with open(findings_out, "a") as f:
            f.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

def finding(name, file, **attrs):
    return {"finding": name, "file": file, **{k: str(v) for k, v in attrs.items()}}

FM_START = re.compile(r"^---\s*$")
FIELD_RE = re.compile(r"^([A-Za-z][A-Za-z0-9_-]*)\s*:\s*(.*?)\s*$")

def parse_frontmatter(text):
    lines = text.splitlines()
    if not lines or not FM_START.match(lines[0]):
        return None
    fields = {}
    end = None
    for i in range(1, len(lines)):
        if FM_START.match(lines[i]):
            end = i
            break
        m = FIELD_RE.match(lines[i])
        if m:
            key, val = m.group(1), m.group(2)
            if val.startswith('"') and val.endswith('"') and len(val) >= 2:
                val = val[1:-1]
            fields[key] = val
    if end is None:
        return None
    return fields, end

BLOCK_RE = re.compile(r"^[>|](?:[-+][1-9]?|[1-9][-+]?)?$")

def resolve_scalar(lines, key):
    """The value of a top-level key as the skill listing reads it, or None when the key is absent.

    Plain scalars as written. Single-quoted scalars read a doubled quote as one quote.
    Double-quoted scalars read an escaped quote as a quote and an escaped backslash as a
    backslash, and leave any other escape as written. Block scalars (the folded and literal
    indicators with their strip and keep forms) are the indented continuation lines joined by
    one space. When a key repeats, the last one wins."""
    for i in range(len(lines) - 1, -1, -1):
        m = FIELD_RE.match(lines[i])
        if not m or m.group(1) != key:
            continue
        val = m.group(2)
        if BLOCK_RE.match(val):
            parts = []
            for nxt in lines[i + 1:]:
                if nxt.strip() == "":
                    continue
                if not nxt[0].isspace():
                    break
                parts.append(nxt.strip())
            return " ".join(parts)
        if len(val) >= 2 and val[0] == "'" and val[-1] == "'":
            return val[1:-1].replace("''", "'")
        if len(val) >= 2 and val[0] == '"' and val[-1] == '"':
            return re.sub(r'\\(["\\])', r"\1", val[1:-1])
        return val
    return None

def iter_skill_files(root, skills_root):
    if os.path.isfile(root) and root.endswith("SKILL.md"):
        yield root
        return
    if os.path.isdir(root) and os.path.basename(os.path.realpath(root)) != "skills":
        candidate = os.path.join(root, "SKILL.md")
        if os.path.isfile(candidate):
            yield candidate
            return
    if not os.path.isdir(root):
        return
    for entry in sorted(os.listdir(root)):
        sub = os.path.join(root, entry)
        if not os.path.isdir(sub):
            continue
        candidate = os.path.join(sub, "SKILL.md")
        if os.path.isfile(candidate):
            yield candidate

total = 0
findings_count = 0

for skill_md in iter_skill_files(target_root, skills_root):
    total += 1
    rel = os.path.relpath(skill_md, skills_root) if skill_md.startswith(skills_root) else skill_md
    skill_dir = os.path.basename(os.path.dirname(skill_md))
    with open(skill_md, encoding="utf-8") as f:
        text = f.read()
    fm = parse_frontmatter(text)
    if fm is None:
        if not dry_run:
            emit(finding("skill-parity-missing-frontmatter", rel, skill=skill_dir))
        findings_count += 1
        continue
    fields, fm_end = fm
    name = fields.get("name")
    if name is None:
        if not dry_run:
            attrs = {}
            if mode == "fix":
                attrs["fix"] = f"add the line name: {skill_dir} to skills/{skill_dir}/SKILL.md in the source repo"
            emit(finding("skill-parity-missing-name", rel, skill=skill_dir, **attrs))
        findings_count += 1
    if name is not None and name != skill_dir:
        if not dry_run:
            emit(finding("skill-parity-name-mismatch", rel,
                         skill=skill_dir, expected=skill_dir, actual=name))
        findings_count += 1
    desc = fields.get("description")
    if desc is None:
        if not dry_run:
            emit(finding("skill-parity-missing-description", rel, skill=skill_dir))
        findings_count += 1
    else:
        dlen = len(desc)
        if dlen == 0 or dlen > 1024:
            if not dry_run:
                emit(finding("skill-parity-description-length", rel,
                             skill=skill_dir, length=dlen, limit=1024))
            findings_count += 1
    for key in fields:
        if key not in RECOGNIZED_KEYS and key not in EXTENSION_KEYS:
            if not dry_run:
                emit(finding("skill-parity-unknown-frontmatter-key", rel,
                             skill=skill_dir, key=key))
            findings_count += 1
    fm_lines = text.splitlines()[1:fm_end]
    listing = " ".join(v for v in (resolve_scalar(fm_lines, "description"),
                                   resolve_scalar(fm_lines, "when_to_use")) if v)
    if len(listing) > LISTING_LIMIT:
        if not dry_run:
            emit(finding("skill-parity-listing-length", rel,
                         skill=skill_dir, length=len(listing), limit=LISTING_LIMIT))
        findings_count += 1

if dry_run:
    sys.stdout.write(f"skill-parity: scanned={total} findings={findings_count}\n")
else:
    emit({"summary": "skill-parity", "scanned": total,
          "findings": findings_count, "mode": mode})
PY
