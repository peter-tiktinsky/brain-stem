#!/bin/bash
# skill-parity — Mechanical frontmatter parity check for ~/.claude/skills/*/SKILL.md.
#
# Handles the mechanical (bash-checkable) subset of skill-config auditing.
# Bash-vs-LLM boundary: this capability handles checks resolvable
# without body interpretation; richer frontmatter proposals (effort calibration,
# argument-hint, description rewrite, disable-model-invocation heuristics) live
# in `/skill-optimizer --skill {name}` where LLM judgment is available.
#
# Checks per skill:
#   1. YAML frontmatter block present (starts with `---` on line 1)
#   2. `name:` field present
#   3. `name:` value matches directory basename
#   4. `description:` field present
#   5. `description:` value length 1–1024 chars
#
# Findings (one per skill, per check failure):
#   - skill-parity-missing-frontmatter
#   - skill-parity-missing-name
#   - skill-parity-name-mismatch         (attrs: expected, actual)
#   - skill-parity-missing-description
#   - skill-parity-description-length    (attrs: length, limit)
#
# CLI:
#   skill-parity.sh                      # --check default
#   skill-parity.sh --check              # emit findings, no writes
#   skill-parity.sh --fix                # auto-add missing `name:` from dir basename
#   skill-parity.sh --scope <dir>        # narrow to one skill directory
#   skill-parity.sh --dry-run            # summary counts only
#
# `--fix` authority:
#   AUTO:    add missing `name:` line from directory basename (purely mechanical)
#   NEVER:   modify existing fields, rewrite descriptions, add other fields
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
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "skill-parity: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

SKILLS_ROOT="${SKILL_PARITY_SKILLS_ROOT_OVERRIDE:-$HOME/.claude/skills}"
TARGET_ROOT="${SCOPE:-$SKILLS_ROOT}"

python3 - "$TARGET_ROOT" "$SKILLS_ROOT" "$MODE" "$DRY_RUN" <<'PY'
import json, os, re, sys

target_root, skills_root, mode, dry_run_s = sys.argv[1:5]
dry_run = (dry_run_s == "true")
findings_out = os.environ.get("FINDINGS_OUTPUT", "")

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
fixed_count = 0

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
    fields, _ = fm
    name = fields.get("name")
    if name is None:
        if mode == "fix":
            lines = text.splitlines()
            insert_at = 1
            new_line = f"name: {skill_dir}"
            lines.insert(insert_at, new_line)
            with open(skill_md, "w", encoding="utf-8") as f:
                f.write("\n".join(lines) + ("\n" if text.endswith("\n") else ""))
            fixed_count += 1
            name = skill_dir
        else:
            if not dry_run:
                emit(finding("skill-parity-missing-name", rel, skill=skill_dir))
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

if dry_run:
    sys.stdout.write(f"skill-parity: scanned={total} findings={findings_count}")
    if mode == "fix":
        sys.stdout.write(f" fixed={fixed_count}")
    sys.stdout.write("\n")
else:
    summary = {"summary": "skill-parity", "scanned": total,
               "findings": findings_count, "mode": mode}
    if mode == "fix":
        summary["fixed"] = fixed_count
    emit(summary)
PY
