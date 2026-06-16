#!/bin/bash
# wikilink-repair — Detect broken [[wikilinks]] across the vault and propose
# repairs from the doc-dependency registry seed (no heuristic fuzzy match).
# Landed: T-3 (2026-04-20, parallel session with T-5). Uses's
# lib/path.sh + lib/findings.sh helpers from day one (no inline path parsing,
# no inline JSON finding writes).
# Repair-seed policy (per T-3 spec §Acceptance Criteria):
#   - Only proposes a repair when the broken wikilink's target basename
#     exactly matches the basename of a `primary` or `mirrors[]` entry in
#     ~/.claude/hooks/doc-dependencies.json. The registry is treated as the
#     authoritative rename-aware source of truth for any file that has a
#     cascade-review mirror relationship.
#   - NO heuristic / fuzzy match. If a broken target has no registry seed,
#     it is logged as `broken-wikilink` for manual triage — not auto-repaired.
#   - Multiple candidates: logged with `ambiguous` flag; no auto-repair.
# Default mode is DRY-RUN. Use --apply to rewrite files (explicit opt-in per batch).
# CLI:
#   wikilink-repair.sh                        # dry-run; emit findings to stdout / FINDINGS_OUTPUT
#   wikilink-repair.sh --apply                # rewrite repairable wikilinks (opt-in)
#   wikilink-repair.sh --scope <path>         # limit to a vault subtree
#   wikilink-repair.sh --report <path>        # write markdown summary
# Env overrides (testing):
#   VAULT_ROOT, DOC_DEP_FILE, FINDINGS_OUTPUT
# Exits non-zero on: unknown flag. Never fails on missing files or parse errors
# (defensive — emits a warning finding instead).
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

DOC_DEP_FILE_EFF="${DOC_DEP_FILE:-$HOME/.claude/hooks/doc-dependencies.json}"
APPLY="false"
SCOPE_PATH=""
REPORT_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY="true"; shift ;;
    --scope) SCOPE_PATH="$2"; shift 2 ;;
    --report) REPORT_PATH="$2"; shift 2 ;;
    --dry-run) shift ;;  # default; kept for CLI-contract symmetry with other capabilities
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "wikilink-repair: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

SCOPE_ROOT="${SCOPE_PATH:-$VAULT_ROOT}"

# Canonical governance read: the doc-dependencies
# registry (.entries) this cap consumes is the REPO-ONLY doc-dependencies pillar, composed into
# the SHIPPED foundation-master .doc_dependencies slot. The legacy $CLAUDE_HOME/hooks/
# doc-dependencies.json default is DANGLING (never shipped), so a clean adopter degraded silently.
# When the resolved file is absent/unreadable, read the EFFECTIVE merged .doc_dependencies slot via
# the R-52 merger (overlay-amendable pillar; .entries top-level matches the python read). An
# explicit DOC_DEP_FILE override (present + readable) is preserved.
if [[ ! -r "$DOC_DEP_FILE_EFF" ]] || ! jq empty "$DOC_DEP_FILE_EFF" >/dev/null 2>&1; then
  _OVL="${FOUNDATION_OVERLAY_LOAD:-$CLAUDE_HOME_RES/hooks/lib/foundation-overlay-load.sh}"
  [[ -x "$_OVL" ]] || _OVL="$_REPO_LIB/foundation-overlay-load.sh"
  _FM="$CLAUDE_HOME_RES/governance/foundation-master.json"
  if [[ -x "$_OVL" ]] && [[ -f "$_FM" ]]; then
    _UNION="$(mktemp 2>/dev/null || true)"
    if [[ -n "$_UNION" ]] && bash "$_OVL" --foundation-path "$_FM" \
          --overlay-path "$(dirname "$_FM")/overlay-master.json" --query '.doc_dependencies' --force-override > "$_UNION" 2>/dev/null \
          && [[ -s "$_UNION" ]] && [[ "$(head -c4 "$_UNION" 2>/dev/null)" != null ]]; then
      DOC_DEP_FILE_EFF="$_UNION"; trap 'rm -f "$_UNION"' EXIT
    elif [[ -n "$_UNION" ]]; then rm -f "$_UNION"; fi
  fi
fi

python3 - "$SCOPE_ROOT" "$DOC_DEP_FILE_EFF" "$APPLY" "$REPORT_PATH" <<'PY'
import json, os, re, sys
from collections import defaultdict
from datetime import datetime, timezone

scope_root, dep_path, apply_s, report_path = sys.argv[1:5]
apply = (apply_s == "true")
findings_out = os.environ.get("FINDINGS_OUTPUT", "")

def emit(payload):
    line = json.dumps(payload, ensure_ascii=False)
    if findings_out:
        with open(findings_out, "a") as f:
            f.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

# ---------- Registered seed: primary + mirrors basenames → full paths ----------
seed_by_basename = defaultdict(set)
try:
    with open(dep_path) as f:
        dep_doc = json.load(f)
    for e in (dep_doc.get("entries", []) or []):
        if not isinstance(e, dict):
            continue
        for key in ("primary",):
            val = e.get(key) or ""
            if val:
                seed_by_basename[os.path.basename(val)].add(val)
        for m in (e.get("mirrors") or []):
            if isinstance(m, dict):
                f_m = m.get("file") or ""
                if f_m:
                    seed_by_basename[os.path.basename(f_m)].add(f_m)
except Exception as ex:
    emit({"finding": "wikilink-repair-warning",
          "note": "doc-dependencies.json not loadable: %s" % ex})

# ---------- Walk vault, find broken [[wikilinks]] ----------
EXEMPT_DIRS = (
    "/Archive/", "/.git/", "/.claude/projects/",
    "/Logs/foundations-essays/", "//",
    "/_test",
)

# All existing .md basenames — for "target file exists somewhere in vault?" check
all_md_by_basename = defaultdict(set)
md_files = []
for dirpath, dirnames, filenames in os.walk(scope_root):
    # prune hidden and exempt
    dirnames[:] = [d for d in dirnames if not d.startswith('.')]
    if any(ex in dirpath + "/" for ex in EXEMPT_DIRS):
        continue
    for fn in filenames:
        if fn.endswith(".md"):
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, scope_root)
            all_md_by_basename[fn].add(rel)
            md_files.append(full)

# Wikilink pattern — captures target and optional alias
WL = re.compile(r"\[\[([^\]\|\#]+)(?:#[^\]\|]+)?(?:\|[^\]]+)?\]\]")

broken_count = 0
proposed = 0
applied = 0
unresolved = 0
per_file_rewrites = defaultdict(list)

for path in md_files:
    try:
        content = open(path).read()
    except Exception:
        continue
    # Skip if no wikilinks
    if "[[" not in content:
        continue
    # Strip fenced code blocks and inline code spans — wikilinks inside code
    # are documentation examples, not real links (matches R-48 hook behavior).
    content = re.sub(r'```[\s\S]*?```', '', content)
    content = re.sub(r'~~~[\s\S]*?~~~', '', content)
    content = re.sub(r'``[^`\n]+``', '', content)
    content = re.sub(r'`[^`\n]+`', '', content)

    rel_path = os.path.relpath(path, scope_root)
    for m in WL.finditer(content):
        target = m.group(1).strip()
        # Strip trailing backslash escape artifact — Obsidian renders
        # `[[Target\]]` as `[[Target]]`; the regex captures `Target\` verbatim.
        target = re.sub(r"\\+$", "", target)
        if not target:
            continue
        # Strip common path decorations — Obsidian accepts bare basename or partial paths
        target_base = os.path.basename(target) if "/" in target else target
        if not target_base.endswith(".md"):
            target_base_md = target_base + ".md"
        else:
            target_base_md = target_base
            target_base = target_base[:-3]

        # Check #1 — does target exist as a vault file (any path)?
        candidates = all_md_by_basename.get(target_base_md, set())
        if candidates:
            # If the target path was already explicit and lives at exactly one of the candidates, it's fine
            if "/" in target:
                # user specified a path — check if that exact rel path exists
                tgt_rel = target if target.endswith(".md") else target + ".md"
                exists = any(c == tgt_rel for c in candidates)
                if exists:
                    continue
                # stale path → broken
                broken_count += 1
                # check registry seed for basename
                seed = seed_by_basename.get(target_base_md, set())
                if len(candidates) == 1 and seed:
                    # single-candidate + registry seed confirms → propose repair
                    new_rel = next(iter(candidates))
                    emit({"finding": "wikilink-repair-suggestion",
                          "file": rel_path, "old_target": target,
                          "new_target": new_rel[:-3] if new_rel.endswith(".md") else new_rel,
                          "seed": "doc-dependency-registry",
                          "apply": apply})
                    proposed += 1
                    if apply:
                        per_file_rewrites[path].append((target, new_rel[:-3] if new_rel.endswith(".md") else new_rel))
                        applied += 1
                else:
                    emit({"finding": "broken-wikilink",
                          "file": rel_path, "target": target,
                          "candidates": sorted(list(candidates)),
                          "in_registry": bool(seed),
                          "note": "No single-candidate + registry-seed match; manual review."})
                    unresolved += 1
            else:
                # bare basename — Obsidian resolves by basename; if exactly one candidate, link is fine
                continue
        else:
            # target file doesn't exist anywhere in vault
            broken_count += 1
            seed = seed_by_basename.get(target_base_md, set())
            if seed:
                # registry knows this file name but it's not in vault — likely renamed/moved
                emit({"finding": "broken-wikilink-registry-known",
                      "file": rel_path, "target": target,
                      "registry_candidates": sorted(list(seed)),
                      "note": "Target missing from vault but present in doc-dependency registry. Manual review — registry may be stale."})
            else:
                emit({"finding": "broken-wikilink",
                      "file": rel_path, "target": target,
                      "candidates": [], "in_registry": False,
                      "note": "Target not found in vault, no registry seed."})
            unresolved += 1

# ---------- Apply rewrites if requested ----------
if apply and per_file_rewrites:
    for path, rewrites in per_file_rewrites.items():
        content = open(path).read()
        for old_tgt, new_tgt in rewrites:
            # Replace exact [[old_tgt]] occurrences (preserving alias/section)
            def repl(m):
                tgt = m.group(1).strip()
                if tgt == old_tgt:
                    # Preserve section (#) and alias (|) and closing ]]
                    rest = m.group(0)[2 + len(m.group(1)):]
                    return "[[" + new_tgt + rest
                return m.group(0)
            content = WL.sub(repl, content)
        tmp = path + ".tmp." + str(os.getpid())
        with open(tmp, "w") as f:
            f.write(content)
        os.replace(tmp, path)

print("wikilink-repair: scanned=%d broken=%d proposed_repairs=%d applied=%d unresolved=%d" % (
    len(md_files), broken_count, proposed, applied, unresolved), file=sys.stderr)

if report_path:
    # self-stamp the COMPLETE log contract so the audit report is findable
    # (R-47 #log/<subtype> tag) + non-orphan. The log contract = type +
    # log-type + date + timestamp + the R-47 tag.
    _now = datetime.now(timezone.utc).astimezone()
    lines = []
    lines.append("---")
    lines.append("title: Wikilink Repair Report")
    lines.append("type: log")
    lines.append("log-type: audit-report")
    lines.append("date: %s" % _now.strftime("%Y-%m-%d"))
    lines.append("timestamp: %s" % _now.isoformat())
    lines.append('tags: ["#log/audit-report"]')
    lines.append("---")
    lines.append("")
    lines.append("# Wikilink Repair Report")
    lines.append("")
    lines.append("- Files scanned: %d" % len(md_files))
    lines.append("- Broken wikilinks: %d" % broken_count)
    lines.append("- Registry-seeded repair proposals: %d" % proposed)
    lines.append("- Applied: %d" % applied)
    lines.append("- Unresolved (manual review): %d" % unresolved)
    with open(report_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("report written: %s" % report_path)
PY
