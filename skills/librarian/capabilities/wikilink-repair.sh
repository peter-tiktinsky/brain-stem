#!/bin/bash
# wikilink-repair — Detect broken [[wikilinks]] across the vault and propose
# repairs from the doc-dependency registry seed (no heuristic fuzzy match).
#
# Landed: T-3 (2026-04-20, parallel session with T-5). Uses's
# lib/path.sh + lib/findings.sh helpers from day one (no inline path parsing,
# no inline JSON finding writes).
#
# Repair-seed policy (per T-3 spec §Acceptance Criteria):
#   - Only proposes a repair when the broken wikilink's target basename
#     exactly matches the basename of a `primary` or `mirrors[]` entry in
#     ~/.claude/hooks/doc-dependencies.json. The registry is treated as the
#     authoritative rename-aware source of truth for any file that has a
#     cascade-review mirror relationship.
#   - NO heuristic / fuzzy match. If a broken target has no registry seed,
#     it is logged as `broken-wikilink` for manual triage — not auto-repaired.
#   - Multiple candidates: logged with `ambiguous` flag; no auto-repair.
#
# Default mode is DRY-RUN. Use --apply to rewrite files (explicit opt-in per batch).
#
# CLI:
#   wikilink-repair.sh                        # dry-run; emit findings to stdout / FINDINGS_OUTPUT
#   wikilink-repair.sh --apply                # rewrite repairable wikilinks (opt-in)
#   wikilink-repair.sh --scope <path>         # limit to a vault subtree
#   wikilink-repair.sh --report <path>        # write markdown summary
#
# MEMORY-NAMESPACE RESOLUTION (resolution only, never repair). A wikilink whose target
# lives in the memory corpus — feedback_*/reference_*/project_* under $CLAUDE_HOME/rules,
# $CLAUDE_HOME/memory and $CLAUDE_HOME/projects/*/memory — resolves for the reader but
# lives OUTSIDE the vault, so a vault-only walk called it broken. That was a standing
# ~13% noise floor on the broken-wikilink class, and a noise floor is how a real break
# stops being read.
#
# The namespace is ENUMERATED FROM DISK AT SCAN TIME, never a static prefix list. A
# `feedback_`/`reference_`/`project_` prefix allowlist encodes ONE corpus's naming
# convention, is wrong for an adopter who names memories differently, and would suppress
# a genuinely DEAD memory ref by prefix alone. Enumerating means a link resolves because
# the file is THERE — and a link to a deleted memory is still reported broken.
#
# Consulted ONLY when the vault yields ZERO candidates, so it never turns a
# unique-basename resolution into an ambiguity and never seeds a repair proposal:
# memory targets are outside this capability's rewrite scope by construction.
#
# Env overrides (testing):
#   VAULT_ROOT, DOC_DEP_FILE, FINDINGS_OUTPUT
#   MEMORY_NS_ROOTS — colon-separated memory-namespace roots (default: the three
#                     $CLAUDE_HOME surfaces above). Empty string = disable.
#
# Exits non-zero on: unknown flag. Never fails on missing files or parse errors
# (defensive — emits a warning finding instead).
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

DOC_DEP_FILE_EFF="${DOC_DEP_FILE:-$CLAUDE_HOME_RES/hooks/doc-dependencies.json}"
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

# Source the shared vault-view walker + materialize its file
# list so the broken-wikilink scan descends the followed symlink view (2630 md) via the
# ONE primitive instead of os.walk(followlinks=False) (4 md). The python block reads
# WLR_WALK_LIST and FALLS BACK to os.walk when it is empty (symlink-inert floor).
WLR_WALK_LIST=""
_VVW_LIB="${VAULT_VIEW_WALK:-$CLAUDE_HOME_RES/hooks/lib/vault-view-walk.sh}"
[ -r "$_VVW_LIB" ] || _VVW_LIB="$_REPO_LIB/vault-view-walk.sh"
if [ -r "$_VVW_LIB" ]; then
  # shellcheck source=/dev/null
  . "$_VVW_LIB"
  if command -v vault_view_walk >/dev/null 2>&1; then
    WLR_WALK_LIST="$(mktemp -t wlr-walk.XXXXXX)"
    # Compose the cleanup so an earlier _UNION doc-dep temp (line ~86) is still removed.
    trap 'rm -f "${WLR_WALK_LIST:-}" "${_UNION:-}"' EXIT
    vault_view_walk "$SCOPE_ROOT" > "$WLR_WALK_LIST" 2>/dev/null || true
  fi
fi
export WLR_WALK_LIST

# The resolved CLAUDE_HOME the memory-namespace enumeration keys off, exported so the
# python block never re-derives it (an unset CLAUDE_HOME would silently empty the
# namespace and quietly restore the noise floor).
MEMORY_NS_HOME="$CLAUDE_HOME_RES"
export MEMORY_NS_HOME

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
    "/Logs/foundations-essays/", "/Logs/backlog-progress/",
    "/_test",
)

# All existing .md basenames — for "target file exists somewhere in vault?" check
all_md_by_basename = defaultdict(set)
md_files = []
# Enumerate via the shared vault-view walker (file list at
# $WLR_WALK_LIST) so the scan descends the followed symlink view (2630 md) instead of
# os.walk followlinks=False (4 md). EXEMPT_DIRS pruned here; rel computed against the
# walker's pwd -P-normalized root. FALL BACK to os.walk when the list is empty (floor).
scope_real = os.path.realpath(scope_root)
walk_list_path = os.environ.get("WLR_WALK_LIST", "")
_walk_lines = []
if walk_list_path and os.path.isfile(walk_list_path):
    try:
        with open(walk_list_path) as _wf:
            _walk_lines = _wf.read().split("\n")
    except Exception:
        _walk_lines = []
_used_walker = False
for full in _walk_lines:
    if not full or not full.endswith(".md"):
        continue
    if any(ex in full + "/" for ex in EXEMPT_DIRS):
        continue
    fn = os.path.basename(full)
    rel = os.path.relpath(full, scope_real)
    all_md_by_basename[fn].add(rel)
    md_files.append(full)
    _used_walker = True
if not _used_walker:
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

# --- memory namespace: RESOLUTION ONLY, enumerated from disk at scan time ------------
# Lowercased stems of every .md in the memory corpus. Consulted ONLY for a target with
# ZERO vault candidates, so it can turn a false break into a resolution but can never
# mask a real one: a ref to a deleted memory finds no file and stays broken. Nothing
# here becomes a repair candidate — memory files are outside this cap's rewrite scope.
def memory_namespace_stems():
    raw = os.environ.get("MEMORY_NS_ROOTS")
    if raw is not None:
        roots = [r for r in raw.split(os.pathsep) if r]
    else:
        home = os.environ.get("MEMORY_NS_HOME") or os.path.join(os.path.expanduser("~"), ".claude")
        roots = [os.path.join(home, "rules"), os.path.join(home, "memory")]
        try:
            projects = os.path.join(home, "projects")
            roots += [os.path.join(projects, d, "memory") for d in os.listdir(projects)]
        except OSError:
            pass
    stems = set()
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dp, dns, fns in os.walk(root):
            dns[:] = [d for d in dns if not d.startswith(".")]
            for fn in fns:
                if fn.endswith(".md"):
                    stems.add(fn[:-3].lower())
    return stems

MEMORY_NS = memory_namespace_stems()

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

    rel_path = os.path.relpath(path, scope_real)   # scope_real: match the walker root norm
    for m in WL.finditer(content):
        target = m.group(1).strip()
        # Strip trailing backslash escape artifact — Obsidian renders
        # `[[Target\]]` as `[[Target]]`; the regex captures `Target\` verbatim.
        # Eliminates the largest false-positive class on this finding.
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

        # ONE resolver modeling Obsidian's basename-uniqueness rule, in BOTH
        # directions. `candidates` = every vault file sharing the target basename;
        # `seed` = doc-dependency-registry basenames.
        #   - an exact rel-path match (path-qualified) always resolves;
        #   - EXACTLY ONE candidate  -> RESOLVED: a stale-path-but-unique-basename
        #     link resolves in Obsidian, so it is not broken (this is the direction
        #     that used to over-flag when the registry shipped empty). When the link
        #     is a stale PATH and the registry seeds the rename, propose canonicalizing
        #     it (an opt-in repair suggestion, NOT a broken finding; emits nothing on
        #     a clean adopter whose registry ships empty);
        #   - MULTIPLE candidates    -> AMBIGUOUS / flagged: Obsidian cannot resolve
        #     a bare/partial target deterministically (this is the direction that used
        #     to silently pass, a false negative);
        #   - ZERO candidates        -> genuinely broken / flagged: a true-broken
        #     memory ref living OUTSIDE the vault stays flagged.
        candidates = all_md_by_basename.get(target_base_md, set())
        seed = seed_by_basename.get(target_base_md, set())
        path_qualified = ("/" in target)

        # An exact rel-path match (path-qualified) resolves regardless of multiplicity.
        if path_qualified:
            tgt_rel = target if target.endswith(".md") else target + ".md"
            if any(c == tgt_rel for c in candidates):
                continue

        if len(candidates) == 1:
            # Basename resolves to exactly one vault file -> Obsidian resolves it.
            if path_qualified and seed:
                # Stale path + registry knows the rename -> propose canonicalization.
                new_rel = next(iter(candidates))
                new_target = new_rel[:-3] if new_rel.endswith(".md") else new_rel
                emit({"finding": "wikilink-repair-suggestion",
                      "file": rel_path, "old_target": target,
                      "new_target": new_target,
                      "seed": "doc-dependency-registry",
                      "apply": apply})
                proposed += 1
                if apply:
                    per_file_rewrites[path].append((target, new_target))
                    applied += 1
            # else: bare unique basename OR a path-qualified stale path with no
            # registry seed -> RESOLVED via basename-uniqueness; emit nothing.
            continue
        elif len(candidates) >= 2:
            # Ambiguous: multiple vault files share this basename; Obsidian cannot
            # resolve a bare/partial target deterministically -> flag for review.
            broken_count += 1
            emit({"finding": "broken-wikilink",
                  "file": rel_path, "target": target,
                  "candidates": sorted(list(candidates)),
                  "in_registry": bool(seed),
                  "ambiguous": True,
                  "note": "Ambiguous: %d vault files share this basename; Obsidian cannot resolve deterministically." % len(candidates)})
            unresolved += 1
        elif target_base_md[:-3].lower() in MEMORY_NS:
            # Zero VAULT candidates, but the target is a real file in the memory
            # corpus — it resolves for the reader, so it is not broken and not a
            # repair candidate. Reached only on the zero-candidate path, so this can
            # never convert a unique-basename resolution into an ambiguity.
            continue
        else:
            # Zero candidates -> genuinely broken.
            broken_count += 1
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
