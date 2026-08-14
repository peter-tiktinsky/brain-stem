#!/bin/bash
# memory-globalize — Promote `scope: global` project memories to ~/.claude/rules/.
#
# Part of T-6 (memory-scope-routing). The `scope:` field on a memory
# (schemas/memory-schema.json :: scope) is the typed router between the project
# layer (per-git-root MEMORY.md, capped, isolated) and the global layer
# (~/.claude/rules/*.md, loaded every session). Auto-capture feeds the project
# layer; this capability is the PROMOTION TRANSPORT that elevates a
# `scope: global` memory into a rule conforming to schemas/rules-schema.json.
#
# Scan predicate (T-6 design): EXPLICIT `scope: global` only by default
# — the act of writing `scope: global` is the operator's promotion signal.
# `--include-default-scope` widens the scan to absent-scope memories (the
# schema's literal "default if absent = global" reading); off by default so a
# sweep does not mass-propose the entire project corpus.
#
# Idempotency: a memory already carrying `promoted_to:` is skipped (re-run-safe).
# Bidirectional lineage = rule `source_memory:` <-> memory `promoted_to:`
# (lean-pointer disposition; source memory is NOT moved or deleted).
#
# GOVERNANCE: writes ONLY to ~/.claude/rules/ — NEVER opens ~/.claude/CLAUDE.md
# for write (rules-only-never-CLAUDE.md,-memory-management.md.2
# +.5 — the canonical SoT recording the principle; re-point off the
# dangling docs/decisions/0007 path).
#
# Output Contract (per CLAUDE.md skill-creation rule):
#   Files written (ONLY in --apply mode; propose mode writes nothing):
#     1. $RULES_DIR/<rule-name>.md            — the promoted rule (atomic temp+rename)
#     2. <source-memory>.md frontmatter        — stamped with `promoted_to:` (atomic)
#   Schema gated by: schemas/rules-schema.json (Draft-07). The transformed rule
#     frontmatter is validated as an object BEFORE any write (jsonschema when
#     importable; structural fallback otherwise).
#   Pre-write validation steps:
#     - memory must carry a non-empty `description:` (the rule retrieval hook).
#     - transformed frontmatter must validate against rules-schema.json.
#     - target rule path must not already belong to a DIFFERENT source memory
#       (name-collision guard).
#   Failure mode: BLOCK-AND-LOG. A candidate that fails validation or collides
#     emits a `promotion-blocked` finding and is skipped; no partial write.
#     Never write-and-hope.
#
# NDJSON schema (one line per candidate / event):
#   propose:  { "finding":"memory-globalize", "file":"<memory.md>",
#               "category":"promotion-candidate", "source_memory":"<slug>",
#               "target_rule":"<name>.md", "rules_dir":"<dir>",
#               "description":"<rule hook>", "scope":"global|absent",
#               "valid":true, "memory_dir":"<dir>" }
#   blocked:  { "finding":"memory-globalize", "file":"<memory.md>",
#               "category":"promotion-blocked", "reason":"...",
#               "source_memory":"<slug>", "valid":false, "memory_dir":"<dir>" }
#   applied:  { "finding":"memory-globalize", "file":"<memory.md>",
#               "category":"promoted", "source_memory":"<slug>",
#               "target_rule":"<name>.md", "written":"<full path>",
#               "memory_dir":"<dir>" }
#
# Tier: judgment. requires_confirmation: true (propose-then-confirm default;
# --apply is the confirm gate). Cron block: skip-non-interactive.
#
# CLI:
#   memory-globalize.sh                          # propose (NDJSON candidates; NO writes)
#   memory-globalize.sh --apply                  # confirm: write rules + stamp pointers
#   memory-globalize.sh --scope <dir>            # one memory dir (else sweep all projects)
#   memory-globalize.sh --include-default-scope  # also treat absent-scope as candidate
#   memory-globalize.sh --dry-run                # summary counts only; no findings/writes
#   memory-globalize.sh --help                   # usage
#
# Env overrides:
#   MEMORY_DIR              Single memory dir (sibling convention; else sweep
#                           $CLAUDE_HOME/projects/*/memory). --scope wins over env.
#   RULES_DIR               Promotion target (default: $CLAUDE_HOME/rules).
#   RULES_SCHEMA_PATH       (default: $FOUNDATION_REPO/schemas/rules-schema.json
#                           -> $CLAUDE_HOME/schemas/rules-schema.json)
#   FINDINGS_OUTPUT         (default: stdout)
#   FOUNDATION_TEST_MODE    Bypass non-interactive guard (test/CI runners).
#   MEMORY_GLOBALIZE_AUTO   Bypass non-interactive guard for the T-7 fully-auto
#                           surface (kept distinct from FOUNDATION_TEST_MODE so
#                           prod-auto and test-mode never alias).
#
# Bash 3.2 clean per R-23. Argv-based Python heredocs per R-24
# (data via argv, never a piped stdin).

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

APPLY="false"
SCOPE=""
DRY_RUN="false"
INCLUDE_DEFAULT="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY="true"; shift ;;
    --scope) SCOPE="$2"; shift 2 ;;
    --include-default-scope) INCLUDE_DEFAULT="true"; shift ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) sed -n '2,77p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "memory-globalize: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# Judgment-tier non-interactive guard. Two distinct bypasses, kept separate so
# prod-auto and test-mode never alias (T-7):
#   FOUNDATION_TEST_MODE   — synthetic harnesses / CI runners.
#   MEMORY_GLOBALIZE_AUTO  — the T-7 fully-auto surface (the toggle-gated
#                            PostToolUse hook fires this with --apply when the
#                            operator opts into fully-auto promotion).
if [[ -z "${FOUNDATION_TEST_MODE:-}" ]] && [[ -z "${MEMORY_GLOBALIZE_AUTO:-}" ]] \
   && [[ -z "${CLAUDECODE:-}" ]] && [[ -z "${TTY:-}" ]] && ! [ -t 0 ]; then
  echo "memory-globalize: skipped (non-interactive)" >&2
  exit 0
fi

# --- Resolve the set of memory dirs to scan ---------------------------------
# Precedence: --scope (single) > MEMORY_DIR env (single) > sweep all projects.
CLAUDE_HOME_RESOLVED="${CLAUDE_HOME:-$HOME/.claude}"
MEM_DIRS=""
if [[ -n "$SCOPE" ]]; then
  MEM_DIRS="$SCOPE"
elif [[ -n "${MEMORY_DIR:-}" ]]; then
  MEM_DIRS="$MEMORY_DIR"
else
  for d in "$CLAUDE_HOME_RESOLVED"/projects/*/memory; do
    [[ -d "$d" ]] || continue
    MEM_DIRS="${MEM_DIRS}:${d}"
  done
  MEM_DIRS="${MEM_DIRS#:}"
fi

if [[ -z "$MEM_DIRS" ]]; then
  echo "memory-globalize: no memory dirs to scan (sweep found none under $CLAUDE_HOME_RESOLVED/projects)" >&2
  exit 0
fi

RULES_DIR="${RULES_DIR:-$CLAUDE_HOME_RESOLVED/rules}"

# Resolve rules-schema.json (foundation-repo -> live install).
SCHEMA_PATH="${RULES_SCHEMA_PATH:-}"
if [[ -z "$SCHEMA_PATH" ]]; then
  for candidate in \
    "$CLAUDE_HOME_RESOLVED/schemas/rules-schema.json"; do
    if [[ -f "$candidate" ]]; then SCHEMA_PATH="$candidate"; break; fi
  done
fi

python3 - "$MEM_DIRS" "$RULES_DIR" "$SCHEMA_PATH" "$APPLY" "$DRY_RUN" "$INCLUDE_DEFAULT" <<'PY'
import json
import os
import re
import sys
import tempfile
from datetime import date

mem_dirs = [d for d in sys.argv[1].split(":") if d]
rules_dir = sys.argv[2]
schema_path = sys.argv[3]
apply_mode = sys.argv[4] == "true"
dry_run = sys.argv[5] == "true"
include_default = sys.argv[6] == "true"

today = date.today().isoformat()

PROVENANCE_PREFIX_RE = re.compile(r'^(user|feedback|project|reference|episode)_')
FM_KEY_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$')


# ---- optional jsonschema gate (degrade to structural if unavailable) ------
_schema = None
if schema_path and os.path.isfile(schema_path):
    try:
        with open(schema_path, encoding="utf-8") as fh:
            _schema = json.load(fh)
    except (OSError, json.JSONDecodeError):
        _schema = None

_validator = None
if _schema is not None:
    try:
        import jsonschema  # type: ignore
        _validator = jsonschema.Draft7Validator(_schema)
    except ImportError:
        _validator = None


def validate_rule(fm):
    """Return (ok, reason). jsonschema when available; structural fallback."""
    if _validator is not None:
        errs = sorted(_validator.iter_errors(fm), key=lambda e: e.path)
        if errs:
            return False, "rules-schema: %s" % errs[0].message
        return True, ""
    # structural fallback (mirrors rules-schema required + allOf conditional)
    if not fm.get("description"):
        return False, "structural: missing required 'description'"
    if fm.get("provenance") == "promoted-from-memory" and not fm.get("source_memory"):
        return False, "structural: promoted rule missing 'source_memory'"
    return True, ""


def parse_memory(path):
    """Return (fm_dict, body_str, fm_line_count) or (None, None, 0)."""
    try:
        with open(path, encoding="utf-8") as fh:
            content = fh.read()
    except OSError:
        return None, None, 0
    if not content.startswith("---\n"):
        return None, None, 0
    end = content.find("\n---\n", 4)
    if end < 0:
        return None, None, 0
    fm_block = content[4:end]
    body = content[end + 5:]
    fm = {}
    for line in fm_block.split("\n"):
        m = FM_KEY_RE.match(line)
        if m:
            fm[m.group(1)] = m.group(2).strip()
    return fm, body, fm_block.count("\n") + 1


def unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
        return v[1:-1]
    return v


def parse_inline_tags(raw):
    """Parse `tags: [a, b]` inline array; return list or None for block/empty."""
    raw = raw.strip()
    if not (raw.startswith("[") and raw.endswith("]")):
        return None
    inner = raw[1:-1].strip()
    if not inner:
        return []
    return [unquote(t) for t in inner.split(",") if unquote(t)]


def rule_name_from(slug):
    name = PROVENANCE_PREFIX_RE.sub("", slug)
    name = name.replace("_", "-").lower()
    name = re.sub(r'[^a-z0-9-]+', '-', name)
    name = re.sub(r'-+', '-', name).strip("-")
    return name or slug


def rule_source_memory(path, fm):
    return fm.get("name") or os.path.basename(path)[:-3]


def emit(payload):
    out = os.environ.get("FINDINGS_OUTPUT", "")
    line = json.dumps(payload, ensure_ascii=False, separators=(", ", ": "))
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")


def yaml_str(s):
    """Defensive YAML-safe scalar (JSON flow scalar is valid YAML)."""
    return json.dumps(s, ensure_ascii=False)


def write_rule_file(target, fm, body):
    lines = ["---"]
    lines.append("description: %s" % yaml_str(fm["description"]))
    lines.append("provenance: %s" % fm["provenance"])
    lines.append("source_memory: %s" % fm["source_memory"])
    lines.append("promoted_at: %s" % fm["promoted_at"])
    if fm.get("tags") is not None:
        items = ", ".join(yaml_str(t) for t in fm["tags"])
        lines.append("tags: [%s]" % items)
    lines.append("---")
    out = "\n".join(lines) + "\n" + body
    if not out.endswith("\n"):
        out += "\n"
    d = os.path.dirname(target)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(out)
        os.replace(tmp, target)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def stamp_promoted_to(mem_path, rule_stem):
    """Insert `promoted_to: <rule_stem>` into the source memory frontmatter."""
    with open(mem_path, encoding="utf-8") as fh:
        content = fh.read()
    end = content.find("\n---\n", 4)
    if end < 0:
        return False
    head = content[:end]                 # includes opening ---\n + fm body
    tail = content[end:]                 # starts at \n---\n
    if re.search(r'^promoted_to:', head, re.MULTILINE):
        return True  # already stamped
    new_content = head + "\npromoted_to: %s" % rule_stem + tail
    d = os.path.dirname(mem_path)
    fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(new_content)
        os.replace(tmp, mem_path)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    return True


def existing_rule_source(target):
    """Return source_memory of an existing rule file at target, else None."""
    if not os.path.isfile(target):
        return None
    fm, _, _ = parse_memory(target)
    if not fm:
        return ""
    return fm.get("source_memory", "")


counts = {
    "scanned": 0, "candidates": 0, "promoted": 0, "blocked": 0,
    "skipped_already_promoted": 0, "skipped_project_scope": 0,
    "skipped_absent_scope": 0, "skipped_no_frontmatter": 0,
    "skipped_collision": 0,
}

for memory_dir in mem_dirs:
    if not os.path.isdir(memory_dir):
        continue
    for entry in sorted(os.listdir(memory_dir)):
        if not entry.endswith(".md") or entry == "MEMORY.md":
            continue
        full = os.path.join(memory_dir, entry)
        if not os.path.isfile(full):
            continue
        counts["scanned"] += 1

        fm, body, _ = parse_memory(full)
        if fm is None:
            counts["skipped_no_frontmatter"] += 1
            continue

        scope_raw = unquote(fm.get("scope", "")).strip()
        if scope_raw == "global":
            scope_label = "global"
        elif scope_raw == "":
            if not include_default:
                counts["skipped_absent_scope"] += 1
                continue
            scope_label = "absent"
        else:  # project:<slug> | engagement:<name> | anything else
            counts["skipped_project_scope"] += 1
            continue

        # Idempotency: already promoted.
        if fm.get("promoted_to"):
            counts["skipped_already_promoted"] += 1
            continue

        src_slug = rule_source_memory(full, fm)
        rname = rule_name_from(src_slug)
        target = os.path.join(rules_dir, rname + ".md")

        description = unquote(fm.get("description", "")).strip()
        rule_fm = {
            "description": description,
            "provenance": "promoted-from-memory",
            "source_memory": src_slug,
            "promoted_at": today,
        }
        tags = parse_inline_tags(fm.get("tags", ""))
        if tags is not None:
            rule_fm["tags"] = tags

        ok, reason = validate_rule(rule_fm)
        if not ok:
            counts["blocked"] += 1
            if not dry_run:
                emit({
                    "finding": "memory-globalize", "file": entry,
                    "category": "promotion-blocked", "reason": reason,
                    "source_memory": src_slug, "valid": False,
                    "memory_dir": memory_dir,
                })
            continue

        # Name-collision guard: target owned by a DIFFERENT source memory.
        existing_src = existing_rule_source(target)
        if existing_src is not None and existing_src != src_slug:
            counts["skipped_collision"] += 1
            if not dry_run:
                emit({
                    "finding": "memory-globalize", "file": entry,
                    "category": "promotion-blocked",
                    "reason": "target rule %s already owned by source_memory=%s" % (
                        rname + ".md", existing_src or "<none>"),
                    "source_memory": src_slug, "valid": False,
                    "memory_dir": memory_dir,
                })
            continue

        counts["candidates"] += 1

        if apply_mode:
            write_rule_file(target, rule_fm, body)
            stamp_promoted_to(full, rname)
            counts["promoted"] += 1
            if not dry_run:
                emit({
                    "finding": "memory-globalize", "file": entry,
                    "category": "promoted", "source_memory": src_slug,
                    "target_rule": rname + ".md", "written": target,
                    "memory_dir": memory_dir,
                })
        else:
            if not dry_run:
                emit({
                    "finding": "memory-globalize", "file": entry,
                    "category": "promotion-candidate", "source_memory": src_slug,
                    "target_rule": rname + ".md", "rules_dir": rules_dir,
                    "description": description, "scope": scope_label,
                    "valid": True, "memory_dir": memory_dir,
                })

if dry_run:
    mode = "apply" if apply_mode else "propose"
    print("memory-globalize: dry-run summary (mode=%s, dirs=%d)" % (mode, len(mem_dirs)), file=sys.stderr)
    print("  scanned=%d candidates=%d promoted=%d blocked=%d" % (
        counts["scanned"], counts["candidates"], counts["promoted"], counts["blocked"],
    ), file=sys.stderr)
    print("  skipped: already_promoted=%d project_scope=%d absent_scope=%d collision=%d no_frontmatter=%d" % (
        counts["skipped_already_promoted"], counts["skipped_project_scope"],
        counts["skipped_absent_scope"], counts["skipped_collision"],
        counts["skipped_no_frontmatter"],
    ), file=sys.stderr)
PY

exit 0
