#!/bin/bash
# rules-hygiene — Lifecycle maintenance for the .claude/rules/ global+project surface.
#
# Sibling to memory-hygiene (memory layer) — this is the RULES layer
# auditor. Rules files (~/.claude/rules/*.md global + <project>/.claude/rules/*.md
# project) get the same governance treatment memory already has: a schema contract
# (schemas/rules-schema.json) + a propose-only hygiene capability that flags
# drift for /librarian-runtime synthesis. NO --apply / NO writes — propose-only.
#
# Tier 3 hybrid pattern (mirrors memory-hygiene). A shell+python prefilter handles
# the deterministic drift classes as direct findings and emits NDJSON candidates
# for the one judgment class Claude synthesizes at /librarian runtime.
#
# Deterministic classes (emit `finding`):
#   size            — rule body line-count vs the 500-line ceiling
#                     (rules-schema.json :: _design_notes.size_ceiling — documentary
#                     in the schema, ENFORCED here). green/yellow/red bands like the
#                     MEMORY.md budget (memory-hygiene #8); emitted at >= yellow.
#   frontmatter      — frontmatter invalid vs rules-schema.json (block-and-log style:
#                     missing required `description`; promoted rule missing
#                     `source_memory`; bad `provenance` enum). jsonschema Draft7 gate
#                     when importable; structural fallback otherwise.
#   dead-glob        — a `paths:` glob that matches NOTHING on disk under the rule's
#                     base dir (conclusive for project rules; advisory for global
#                     rules whose globs activate against the runtime project — payload
#                     carries rule_scope so synthesis weighs it).
#
# Judgment class (emit NDJSON candidate on stdout):
#   one-concern      — a rule body carrying >1 top-level `# ` heading is usually two
#                     rules wearing one filename (the size_ceiling rationale). Claude
#                     adjudicates whether to split.
#
# Test isolation per [[feedback_test_isolation_for_hooks_state]].
#
# Tier: judgment. Output Contract: propose-only (writes NOTHING) + block-and-log on
# its own schema-read. Cron block: skip-non-interactive. Exits 0 with a "skipped
# (non-interactive)" log line when invoked outside a TTY and FOUNDATION_TEST_MODE unset.
#
# CLI:
#   rules-hygiene.sh                     # scan global (+ cwd project) rules dirs
#   rules-hygiene.sh --scope <dir>       # scan one rules dir
#   rules-hygiene.sh --dry-run           # summary counts only
#   rules-hygiene.sh --help              # usage
#
# Env overrides:
#   RULES_DIR              Single rules dir (sibling convention; --scope wins).
#   CLAUDE_HOME            (default: $HOME/.claude) — global rules dir = $CLAUDE_HOME/rules.
#   RULES_SCHEMA_PATH      (default: $FOUNDATION_REPO/schemas/rules-schema.json
#                          -> $CLAUDE_HOME/schemas/rules-schema.json)
#   RULES_MAX_LINES        Body line ceiling (default: 500).
#   FINDINGS_OUTPUT        (default: stdout)
#   FOUNDATION_TEST_MODE   Bypass non-interactive guard (test/CI runners).
#
# Bash 3.2 clean per R-23. Argv-based Python heredocs per R-24
# ([[feedback_python_heredoc_argv]]).

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
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "rules-hygiene: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# SPLIT the non-interactive gate. The DETERMINISTIC classes
# (size/frontmatter/dead-glob) RUN headless — an unattended weekly cron MUST audit the rules
# corpus — while only the JUDGMENT class (one-concern) stays interactive-gated. Was: the WHOLE
# cap self-exited 0 on a no-TTY cron, so the rules corpus was NEVER audited unattended. HEADLESS
# is passed to the python body, which suppresses ONLY the judgment NDJSON candidates.
HEADLESS="false"
if [[ -z "${FOUNDATION_TEST_MODE:-}" ]] && [[ -z "${TTY:-}" ]] && ! [ -t 0 ]; then
  HEADLESS="true"
fi

CLAUDE_HOME_RESOLVED="${CLAUDE_HOME:-$HOME/.claude}"

# --- Resolve the set of rules dirs to scan ----------------------------------
# Precedence: --scope (single) > RULES_DIR env (single) > global + cwd project.
RULE_DIRS=""
if [[ -n "$SCOPE" ]]; then
  RULE_DIRS="$SCOPE"
elif [[ -n "${RULES_DIR:-}" ]]; then
  RULE_DIRS="$RULES_DIR"
else
  RULE_DIRS="$CLAUDE_HOME_RESOLVED/rules"
  if [[ -d "$PWD/.claude/rules" ]] && [[ "$PWD/.claude/rules" != "$CLAUDE_HOME_RESOLVED/rules" ]]; then
    RULE_DIRS="${RULE_DIRS}:$PWD/.claude/rules"
  fi
fi

# Resolve rules-schema.json (foundation-repo -> live install).
SCHEMA_PATH="${RULES_SCHEMA_PATH:-}"
if [[ -z "$SCHEMA_PATH" ]]; then
  for candidate in \
    "$CLAUDE_HOME_RESOLVED/schemas/rules-schema.json"; do
    if [[ -f "$candidate" ]]; then SCHEMA_PATH="$candidate"; break; fi
  done
fi

RULES_MAX_LINES="${RULES_MAX_LINES:-500}"

python3 - "$RULE_DIRS" "$SCHEMA_PATH" "$RULES_MAX_LINES" "$DRY_RUN" "$CLAUDE_HOME_RESOLVED" "$HEADLESS" <<'PY'
import glob as globmod
import hashlib
import json
import os
import re
import sys

rule_dirs = [d for d in sys.argv[1].split(":") if d]
schema_path = sys.argv[2]
try:
    max_lines = int(sys.argv[3])
except ValueError:
    max_lines = 500
dry_run = sys.argv[4] == "true"
claude_home = os.path.realpath(sys.argv[5]) if sys.argv[5] else ""
# headless -> run the deterministic classes, suppress the judgment
# (one-concern) NDJSON candidate (it needs interactive adjudication).
headless = (len(sys.argv) > 6 and sys.argv[6] == "true")

findings_out = os.environ.get("FINDINGS_OUTPUT", "")

FM_KEY_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$')
H1_RE = re.compile(r'^#\s+\S', re.MULTILINE)


# ---- optional jsonschema gate (degrade to structural if unavailable) -------
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


def validate_fm(fm):
    """Return (ok, reason). jsonschema when available; structural fallback."""
    if _validator is not None:
        errs = sorted(_validator.iter_errors(fm), key=lambda e: list(e.path))
        if errs:
            return False, "rules-schema: %s" % errs[0].message
        return True, ""
    # structural fallback (mirrors rules-schema required + allOf conditional + enum)
    if not fm.get("description"):
        return False, "structural: missing required 'description'"
    prov = fm.get("provenance")
    if prov is not None and prov not in ("hand-authored", "promoted-from-memory"):
        return False, "structural: invalid provenance '%s'" % prov
    if prov == "promoted-from-memory" and not fm.get("source_memory"):
        return False, "structural: promoted rule missing 'source_memory'"
    return True, ""


def unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
        return v[1:-1]
    return v


def parse_rule(path):
    """Return (fm_dict_or_None, body_str, had_frontmatter)."""
    try:
        with open(path, encoding="utf-8") as fh:
            content = fh.read()
    except OSError:
        return None, "", False
    if not content.startswith("---\n"):
        return None, content, False
    end = content.find("\n---\n", 4)
    if end < 0:
        return None, content, False
    fm_block = content[4:end]
    body = content[end + 5:]
    fm = {}
    for line in fm_block.split("\n"):
        m = FM_KEY_RE.match(line)
        if not m:
            continue
        key, raw = m.group(1), m.group(2).strip()
        if raw.startswith("[") and raw.endswith("]"):
            inner = raw[1:-1].strip()
            fm[key] = [unquote(t) for t in inner.split(",") if unquote(t)] if inner else []
        else:
            fm[key] = unquote(raw)
    return fm, body, True


def emit(payload):
    if dry_run:
        return  # --dry-run: summary counts only, no findings
    line = json.dumps(payload, ensure_ascii=False)
    if findings_out:
        with open(findings_out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")


def candidate_id(check, subject):
    h = hashlib.sha256(("rules-hygiene|%s|%s" % (check, subject)).encode("utf-8")).hexdigest()
    return h[:16]


def base_for(rule_dir):
    """Directory globs in this rule dir resolve against."""
    rd = rule_dir.rstrip("/")
    suffix = os.path.join(".claude", "rules")
    if rd.endswith(os.sep + suffix):
        return rd[:-(len(suffix) + 1)]
    return rd


def scope_of(rule_dir):
    rp = os.path.realpath(rule_dir)
    if claude_home and (rp == os.path.join(claude_home, "rules") or rp.startswith(claude_home + os.sep)):
        return "global"
    return "project"


counts = {
    "scanned": 0, "size": 0, "frontmatter": 0, "dead_glob": 0,
    "one_concern": 0, "no_frontmatter": 0,
}

for rule_dir in rule_dirs:
    if not os.path.isdir(rule_dir):
        continue
    base = base_for(rule_dir)
    rscope = scope_of(rule_dir)
    for entry in sorted(os.listdir(rule_dir)):
        if not entry.endswith(".md"):
            continue
        full = os.path.join(rule_dir, entry)
        if not os.path.isfile(full):
            continue
        counts["scanned"] += 1

        fm, body, had_fm = parse_rule(full)

        # ---- frontmatter validity (block-and-log style) --------------------
        if not had_fm or fm is None:
            emit({
                "finding": "rules-hygiene", "file": entry, "category": "frontmatter",
                "rule_dir": rule_dir, "rule_scope": rscope, "valid": False,
                "reason": "no parseable YAML frontmatter (rules-schema requires `description`)",
            })
            counts["no_frontmatter"] += 1
        else:
            ok, reason = validate_fm(fm)
            if not ok:
                emit({
                    "finding": "rules-hygiene", "file": entry, "category": "frontmatter",
                    "rule_dir": rule_dir, "rule_scope": rscope, "valid": False,
                    "reason": reason,
                })
                counts["frontmatter"] += 1

        # ---- size (body line-count vs ceiling; green/yellow/red) -----------
        body_lines = len(body.splitlines())
        pct = int((body_lines / float(max_lines)) * 100) if max_lines > 0 else 0
        if pct >= 90:
            status = "red"
        elif pct >= 75:
            status = "yellow"
        else:
            status = "green"
        if status != "green":
            emit({
                "finding": "rules-hygiene", "file": entry, "category": "size",
                "rule_dir": rule_dir, "rule_scope": rscope, "status": status,
                "body_lines": body_lines, "cap": max_lines, "percentage": pct,
                "reason": "rule body %d/%d lines (%d%%) — %s; one concern per file, split when it outgrows a domain" % (
                    body_lines, max_lines, pct, status),
            })
            counts["size"] += 1

        # ---- dead-glob (paths: patterns that match nothing on disk) --------
        paths = fm.get("paths") if fm else None
        if isinstance(paths, list):
            for pat in paths:
                if not pat:
                    continue
                matches = globmod.glob(os.path.join(base, pat), recursive=True)
                if not matches:
                    emit({
                        "finding": "rules-hygiene", "file": entry, "category": "dead-glob",
                        "rule_dir": rule_dir, "rule_scope": rscope,
                        "pattern": pat, "base": base,
                        "reason": "paths: glob '%s' matches nothing under %s%s" % (
                            pat, base,
                            " (global rule — globs activate against the runtime project; advisory)"
                            if rscope == "global" else ""),
                    })
                    counts["dead_glob"] += 1

        # ---- one-concern candidate (JUDGMENT) ------------------------------
        # suppressed headless — the judgment class needs interactive adjudication; the
        # deterministic classes above already ran unattended.
        h1s = H1_RE.findall(body)
        if len(h1s) > 1 and not headless:
            subject = entry
            emit({
                "capability": "rules-hygiene", "check": "one-concern",
                "candidate_id": candidate_id("one-concern", subject),
                "subject": subject,
                "evidence": {
                    "file_path": full, "rule_dir": rule_dir, "rule_scope": rscope,
                    "h1_count": len(h1s), "body_lines": body_lines,
                    "description": (fm.get("description", "") if fm else "")[:200],
                },
                "score": 0.6,
                "notes": "rule body carries %d top-level '# ' headings — likely two rules in one file; adjudicate whether to split" % len(h1s),
            })
            counts["one_concern"] += 1

if dry_run:
    total = counts["size"] + counts["frontmatter"] + counts["dead_glob"] + counts["one_concern"] + counts["no_frontmatter"]
    print("rules-hygiene: scanned=%d findings=%d counts=%s" % (counts["scanned"], total, dict(counts)), file=sys.stderr)
PY

exit 0
