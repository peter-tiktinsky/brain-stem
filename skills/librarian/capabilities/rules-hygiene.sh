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
#   hook-redundant   — the rule BODY names a shipped inline-blocking hook verbatim
#                     (allowlist below): the rule restates enforcement the hook
#                     already delivers at write/ask time. Informational (valid:true);
#                     the predicate reads the BODY only, never the frontmatter.
#
# Judgment class (emit NDJSON candidate on stdout):
#   one-concern      — a rule body carrying >1 top-level `# ` heading is usually two
#                     rules wearing one filename (the size_ceiling rationale). Claude
#                     adjudicates whether to split.
#
# Test isolation: state points at a throwaway dir, never the live tree.
#
# Tier: judgment. Output Contract: propose-only (writes NOTHING) + block-and-log on
# its own schema-read. Cron block: weekly. The non-interactive gate is SPLIT, not a
# whole-capability skip: the deterministic classes always run, and only the one-concern
# judgment class is suppressed — and only when the invocation is genuinely headless
# (no controlling tty, and neither FOUNDATION_TEST_MODE nor CLAUDECODE set).
#
# CLI:
#   rules-hygiene.sh                     # scan global (+ cwd project) rules dirs
#   rules-hygiene.sh --scope <dir>       # scan one rules dir
#   rules-hygiene.sh --dry-run           # summary counts only
#   rules-hygiene.sh --check-load <rule-name> [--log PATH]
#                                        # did a path-scoped rule load (read-only query)
#   rules-hygiene.sh --compare-retired <rule-basename> [--rules-dir DIR]
#                                        # a retired rule beside what now delivers it (read-only)
#   rules-hygiene.sh --help              # usage
#
# --check-load answers "did my path-scoped rule load": it reads the instructions-loaded log that
# the InstructionsLoaded hook writes and reports whether a row with load_reason path_glob_match
# names the rule file (<rule-name> with or without .md). Output and exit: LOADED (exit 0), NOT
# loaded (exit 1), no log at the path (exit 3), a refused argument (exit 2). It reads only rows
# that carry a file_path (the log mixes in a second record shape without one). The log defaults to
# the path hooks/lib/instructions-loaded-rows.sh resolves under the hooks state directory, the way
# the hook resolves it, and the rows are read through that library (the rotated generation first).
# It cannot be combined with --scope or --dry-run, and --log needs --check-load.
#
# The compare mode takes one of the four retired rule basenames (00-project-binder-pointer.md,
# 10-pre-research-library-check.md, 20-work-project-register.md, 30-durable-artifact-routing.md) and
# prints, in order: the rule file (<rules-dir>/<basename>, the rules dir defaulting to
# $CLAUDE_HOME/rules), the leading comment block of the shipped hook that delivers the same guidance
# now (at most 60 lines), for the two rules the write guard carries the guard lines naming that rule's
# tag (at most six, each clipped to 300 bytes), and a closing line that leaves the keep-or-delete
# ruling to you. Exit 0 printed, 2 refused (no name, a name outside the four, an empty --rules-dir,
# an absent rule file), 3 the hook is missing from the install. It cannot be combined with --scope,
# --dry-run or --check-load, and --rules-dir needs it.
#
# Env overrides:
#   RULES_DIR              Single rules dir (sibling convention; --scope wins).
#   CLAUDE_HOME            (default: $HOME/.claude) — global rules dir = $CLAUDE_HOME/rules.
#   RULES_SCHEMA_PATH      (default: $FOUNDATION_REPO/schemas/rules-schema.json
#                          -> $CLAUDE_HOME/schemas/rules-schema.json)
#   RULES_MAX_LINES        Body line ceiling (default: 500).
#   FINDINGS_OUTPUT        (default: stdout)
#   FOUNDATION_TEST_MODE   Bypass non-interactive guard (test/CI runners).
#   CLAUDECODE             Set by a Claude Code tool-context session. Marks the run
#                          ATTENDED, so the judgment class is NOT suppressed.
#   HOOKS_STATE_OVERRIDE, HOOKS_STATE, CLAUDE_STATE_ROOT, XDG_STATE_HOME
#                          The state directory chain --check-load reads its default log from.
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

SCOPE=""
DRY_RUN="false"
SCOPE_SET=0; DRY_SET=0; CL_SET=0; CL_NAME=""; LOG_SET=0; LOG_PATH=""
CR_SET=0; CR_NAME=""; RD_SET=0; RD_PATH=""

# Which flags were named, read before the parse below (a flag's value is skipped, so a value that
# spells a flag does not count).
_prev=""
for _a in "$@"; do
  case "$_prev" in --scope|--check-load|--log|--compare-retired|--rules-dir) _prev=""; continue ;; esac
  case "$_a" in --scope) SCOPE_SET=1 ;; --dry-run) DRY_SET=1 ;; esac
  _prev="$_a"
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --check-load) CL_SET=1; CL_NAME="${2-}"; if [[ $# -ge 2 ]]; then shift 2; else shift; fi ;;
    --log) LOG_SET=1; LOG_PATH="${2-}"; if [[ $# -ge 2 ]]; then shift 2; else shift; fi ;;
    --compare-retired) CR_SET=1; CR_NAME="${2-}"; if [[ $# -ge 2 ]]; then shift 2; else shift; fi ;;
    --rules-dir) RD_SET=1; RD_PATH="${2-}"; if [[ $# -ge 2 ]]; then shift 2; else shift; fi ;;
    -h|--help) awk 'NR>1{ if ($0=="") exit; print }' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "rules-hygiene: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# --- Query modes -------------------------------------------------------------
# Once the whole argv is read, the mode rules run in a fixed order, each a refusal with exit 2
# and nothing on stdout: a mode with --scope or --dry-run (--scope named first), then a flag that
# needs its mode, then the mode's own argument checks.
_refuse() { echo "rules-hygiene: refused: $1" >&2; exit 2; }
if [[ "$CL_SET" -eq 1 && "$CR_SET" -eq 1 ]]; then _refuse "--check-load and --compare-retired cannot be combined"; fi
if [[ "$CL_SET" -eq 1 ]]; then
  if [[ "$SCOPE_SET" -eq 1 ]]; then _refuse "--check-load cannot be combined with --scope"; fi
  if [[ "$DRY_SET" -eq 1 ]]; then _refuse "--check-load cannot be combined with --dry-run"; fi
fi
if [[ "$CR_SET" -eq 1 ]]; then
  if [[ "$SCOPE_SET" -eq 1 ]]; then _refuse "--compare-retired cannot be combined with --scope"; fi
  if [[ "$DRY_SET" -eq 1 ]]; then _refuse "--compare-retired cannot be combined with --dry-run"; fi
fi
if [[ "$LOG_SET" -eq 1 && "$CL_SET" -ne 1 ]]; then _refuse "--log needs --check-load"; fi
if [[ "$RD_SET" -eq 1 && "$CR_SET" -ne 1 ]]; then _refuse "--rules-dir needs --compare-retired"; fi

# --compare-retired: a retired rule file beside the shipped hook that delivers its guidance now. The
# roster maps each retired rule to that hook and, for the two rules the write guard carries, the tag
# that guard's lines are found by. Read-only.
if [[ "$CR_SET" -eq 1 ]]; then
  export LC_ALL=C
  [[ -n "$CR_NAME" ]] || _refuse "--compare-retired needs a rule name"
  CR_CARRIER=""; CR_ANCHOR=""
  case "$CR_NAME" in
    00-project-binder-pointer.md) CR_CARRIER="hooks/session-start-project-context.sh" ;;
    10-pre-research-library-check.md) CR_CARRIER="hooks/pre-research-check.sh" ;;
    20-work-project-register.md) CR_CARRIER="hooks/pre-write-guard.sh"; CR_ANCHOR="[WORK SPOKE]" ;;
    30-durable-artifact-routing.md) CR_CARRIER="hooks/pre-write-guard.sh"; CR_ANCHOR="[LIBRARY]" ;;
    *) _refuse "'$CR_NAME' is not a retired rule (one of: 00-project-binder-pointer.md, 10-pre-research-library-check.md, 20-work-project-register.md, 30-durable-artifact-routing.md)" ;;
  esac
  if [[ "$RD_SET" -eq 1 && -z "$RD_PATH" ]]; then _refuse "--rules-dir needs a value"; fi
  CR_DIR="${RD_PATH:-$CLAUDE_HOME_RES/rules}"
  case "$CR_DIR" in /*) ;; *) CR_DIR="$PWD/$CR_DIR" ;; esac
  CR_RULE="${CR_DIR%/}/$CR_NAME"
  [[ -f "$CR_RULE" && -r "$CR_RULE" ]] || _refuse "rules/$CR_NAME is absent — nothing to compare"
  CR_HOOK="$CLAUDE_HOME_RES/$CR_CARRIER"
  if [[ ! -f "$CR_HOOK" || ! -r "$CR_HOOK" ]]; then
    echo "rules-hygiene: refused: carrier $CR_CARRIER not found at $CR_HOOK" >&2
    exit 3
  fi
  printf '== rule: %s (%s line(s)) ==\n' "$CR_RULE" "$(awk 'END { print NR }' "$CR_RULE")"
  cat "$CR_RULE"
  if [[ -n "$(tail -c 1 "$CR_RULE")" ]]; then printf '\n'; fi
  printf '== delivered by: %s ==\n' "$CR_CARRIER"
  awk 'NR == 1 && /^#!/ { next } /^#/ { if (++n <= 60) { sub(/^# ?/, ""); print } next } { exit }' "$CR_HOOK"
  if [[ -n "$CR_ANCHOR" ]]; then
    printf "== carrier lines naming '%s' ==\n" "$CR_ANCHOR"
    awk -v a="$CR_ANCHOR" 'index($0, a) && ++n <= 6 { print substr($0, 1, 300) }' "$CR_HOOK"
  fi
  printf '== end: the keep-or-delete ruling is yours ==\n'
  exit 0
fi

if [[ "$CL_SET" -eq 1 ]]; then
  export LC_ALL=C
  [[ -n "$CL_NAME" ]] || _refuse "--check-load needs a rule name"
  case "$CL_NAME" in
    [!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) _refuse "'$CL_NAME' is not a plain rule name" ;;
  esac
  if [[ "$LOG_SET" -eq 1 && -z "$LOG_PATH" ]]; then _refuse "--log needs a value"; fi
  # The state directory chain of the hook that writes the log, evaluated after the paths lib is
  # sourced (that lib derives HOOKS_STATE and CLAUDE_STATE_ROOT from the user manifest). The
  # top of this script skips the source while VAULT_LOGS is set, so do it here in that case.
  if [[ -n "${VAULT_LOGS:-}" ]]; then
    # shellcheck source=/dev/null
    { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
      || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; } || true
  fi
  # The log is read through the one shared reader: its path chain, and its rows with the rotated
  # generation first. The rows go to a temp file, removed on every exit, that the scan below reads.
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/instructions-loaded-rows.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/instructions-loaded-rows.sh"; } \
    || source "$_REPO_LIB/instructions-loaded-rows.sh"
  LOAD_LOG="${LOG_PATH:-$(ilr_log_path)}"
  CL_ROWS="$(mktemp "${TMPDIR:-/tmp}/rules-hygiene-rows.XXXXXX")" || _refuse "cannot create a temp file under ${TMPDIR:-/tmp}"
  trap 'rm -f "$CL_ROWS"' EXIT
  CL_RC=0
  ilr_rows "$LOAD_LOG" > "$CL_ROWS" || CL_RC=$?
  if [[ "$CL_RC" -eq 3 ]]; then
    printf 'rules-hygiene: check-load: no instructions-loaded log at %s\n' "$LOAD_LOG"
    exit 3
  fi
  if [[ "$CL_RC" -ne 0 ]]; then exit "$CL_RC"; fi
  # shellcheck disable=SC2016
  python3 - "$CL_ROWS" "$CL_NAME" <<'PY' || exit $?
import json
import os
import sys

rows_path, name = sys.argv[1], sys.argv[2]
target = (name[:-3] if name.endswith(".md") else name) + ".md"

naming = []
with open(rows_path, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if not isinstance(row, dict) or row.get("event") != "instructions-loaded":
            continue
        fpath = row.get("file_path")
        if not isinstance(fpath, str) or not fpath:
            continue
        if os.path.basename(fpath) == target:
            naming.append(row)

glob_rows = [r for r in naming if r.get("load_reason") == "path_glob_match"]
if glob_rows:
    last = glob_rows[0]
    for r in glob_rows:
        if str(r.get("ts", "")) >= str(last.get("ts", "")):
            last = r
    print("rules-hygiene: check-load: %s LOADED by path_glob_match %d time(s); last %s session %s file %s"
          % (target, len(glob_rows), last.get("ts", ""), last.get("session_id", ""), last.get("file_path", "")))
    sys.exit(0)
if naming:
    reasons = sorted(set(str(r.get("load_reason") or "-") for r in naming))
    print("rules-hygiene: check-load: %s NOT loaded by path_glob_match; %d row(s) name it (load_reason: %s)"
          % (target, len(naming), ", ".join(reasons)))
else:
    print("rules-hygiene: check-load: %s NOT loaded by path_glob_match; no row names it" % target)
sys.exit(1)
PY
fi

# SPLIT the non-interactive gate. The DETERMINISTIC classes
# (size/frontmatter/dead-glob) RUN headless — an unattended weekly cron MUST audit the rules
# corpus — while only the JUDGMENT class (one-concern) stays interactive-gated. Was: the WHOLE
# cap self-exited 0 on a no-TTY cron, so the rules corpus was NEVER audited unattended. HEADLESS
# is passed to the python body, which suppresses ONLY the judgment NDJSON candidates.
#
# CLAUDECODE=1 is an ATTENDED context, not a headless one (the condition the sibling
# judgment-tier capabilities already carry — promote-from-inbox.sh, library-scrub.sh,
# memory-globalize.sh, memory-hygiene.sh). A Claude Code tool call has no controlling tty
# but IS an operator-attended session, so classifying it headless suppressed the one-concern
# candidates with the operator sitting there asking for them. Only a genuine
# non-Claude-Code no-tty invocation (a cron sweep) is headless.
HEADLESS="false"
if [[ -z "${FOUNDATION_TEST_MODE:-}" ]] && [[ -z "${CLAUDECODE:-}" ]] \
   && [[ -z "${TTY:-}" ]] && ! [ -t 0 ]; then
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

# The inline-blocking allowlist: shipped hooks whose name appearing verbatim in a
# rule BODY marks the rule as restating enforcement the hook already delivers at
# the moment it applies (write-time / ask-time). Kept here — the retired compaction
# stub contract that used to carry it is gone.
HOOK_REDUNDANT_ALLOWLIST = ("pre-write-guard.sh", "pre-asq-guard.sh")


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
    "hook_redundant": 0, "one_concern": 0, "no_frontmatter": 0,
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

        # ---- hook-redundant (deterministic, informational) -----------------
        # A rule BODY naming a shipped inline-blocking hook verbatim restates
        # enforcement the hook already delivers at the moment it applies. The
        # predicate reads the BODY only — a frontmatter description naming the
        # hook is a pointer, not a restatement. Informational (valid:true): the
        # author keeps only what the hook does not do, or deletes the rule.
        for hook_base in HOOK_REDUNDANT_ALLOWLIST:
            if hook_base in body:
                emit({
                    "finding": "rules-hygiene", "file": entry,
                    "category": "hook-redundant", "rule_dir": rule_dir,
                    "rule_scope": rscope, "valid": True, "hook": hook_base,
                    "reason": "this rule restates a hook that enforces it (%s); keep only what the hook does not do, or delete it" % hook_base,
                })
                counts["hook_redundant"] += 1

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
    total = counts["size"] + counts["frontmatter"] + counts["dead_glob"] + counts["hook_redundant"] + counts["one_concern"] + counts["no_frontmatter"]
    print("rules-hygiene: scanned=%d findings=%d counts=%s" % (counts["scanned"], total, dict(counts)), file=sys.stderr)
PY

exit 0
