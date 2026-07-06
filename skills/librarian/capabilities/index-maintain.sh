#!/bin/bash
# index-maintain — Audit-time reconciler for every non-exempt folder's
# _index.md contents-enum table against filesystem reality. The first canonical
# self-healing capability under the R-34 boundary.
# NET-NEW librarian body (1.1 line 136 — replaces the phantom
# doc-reference). Authored from the authoring-spec index-maintain.md
# (REFERENCE only —(a)).
# R-34 self-healing boundary (enforced by code structure):
#   In bounds (auto-corrected): Lines (wc -l), Type (frontmatter type:),
#     missing/orphan rows, updated: bump, auto-bootstrap of a missing non-exempt
#     _index.md. These flow through the AUTO-CORRECT branch.
#   Out of bounds (flagged, never overwritten): descriptions, ordering,
#     exemption-list decisions, folder-context paragraph. These flow through the
#     SEMANTIC-DRIFT branch which emits findings and NEVER writes vault content.
#   The two branches are not interchangeable — the semantic branch has no
#     write-to-vault code path.
# Output Contract
#   Files written: vault _index.md (bounded mechanical scope — sentinel-bounded
#     contents-enum region + updated: frontmatter only); findings to stdout
#     (NDJSON via hooks/lib/findings.sh) or $FINDINGS_OUTPUT.
#   Schema gate: _index.md writes conform to the contents-enum sentinel shape
#     (<!-- contents-enum:start --> / <!-- contents-enum:end -->); column count
#     + order preserved; row pattern preserved.
#   Pre-write validation: read mandates._index_md (matcher + exemption list)
#     from mandatory-files-rules.json; abort the run (block-and-log) if the
#     mandatory-files pillar JSON is malformed.
#   Failure mode: block-and-log; never write-and-hope. Atomic temp+rename.
#     Survivorship: content outside the sentinels preserved verbatim.
# Finding categories (7 — §Finding categories):
#   bootstrap-auto-created     (info-event) created a missing non-exempt _index.md
#   index-row-drift-mechanical (info-event) auto-corrected Lines/Type/missing/orphan row
#   index-row-drift-semantic   (warning, --deep) description/ordering drift — NO auto-overwrite
#   index-stale-frontmatter    (warning) _index.md frontmatter fails the index contract
#   index-orphan-folder        (warning) parent_folder: does not resolve
#   index-exemption-conflict   (warning) _index.md exists at an exempt path
#   mandate-violation          (warning) non-exempt folder lacks _index.md AND bootstrap failed
#   work-master-deliverables-conflict (warning, advisory) a Work/<spoke> MASTER
#     (sub-projects own deliverables/reference) ALSO carries a non-empty top-level
#     deliverables/ or reference/ — read-only, never auto-relocated (the
#     master-deliverables-conflict audit; MASTER-PENDING spokes with no qualifying
#     child are benign and not flagged)
# CLI:
#   index-maintain.sh             # Tier 2 sweep (mechanical auto-correct)
#   index-maintain.sh --deep      # Tier 3 (+ semantic-drift findings, no auto-overwrite)
#   index-maintain.sh --dry-run   # findings + would-be corrections, no write
#   index-maintain.sh --help
# Env overrides (testing):
#   VAULT_ROOT        vault root to walk (required for any real sweep)
#   GOVERNANCE_DIR    governance root (default: foundation-repo -> live install)
#   FINDINGS_OUTPUT   NDJSON sink (default: stdout)
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24.

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
# shellcheck source=/dev/null
source "$CLAUDE_HOME_RES/hooks/lib/findings.sh" 2>/dev/null \
  || source "$(cd "$(dirname "$0")/../../.." && pwd)/hooks/lib/findings.sh"

DEEP="false"
DRY_RUN="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --deep)    DEEP="true"; shift ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "index-maintain: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

GOV_DIR="${GOVERNANCE_DIR:-}"
if [ -z "$GOV_DIR" ]; then
  for cand in \
    "$CLAUDE_HOME_RES/governance"; do
    [ -d "$cand" ] && { GOV_DIR="$cand"; break; }
  done
fi

# Tier-1: mandatory-files-rules.json is repo-only —
# it does NOT ship to a fresh adopter, where only the composed
# governance/foundation-master.json bundle lands. Resolve the SHIPPED bundle via
# ${CLAUDE_HOME:-$HOME/.claude} FIRST; the Python body reads the composed
# .mandatory_files slot from it (instead of degrading to the hardcoded default
# exemption list), falling back to the loose pillar only when the bundle is absent.
BUNDLE=""
for cand in \
  "$CLAUDE_HOME_RES/governance/foundation-master.json" \
  "$GOV_DIR/foundation-master.json"; do
  [ -f "$cand" ] && { BUNDLE="$cand"; break; }
done

# Canonical governance read: route the bundle read through the R-52 union-load
# merger (hooks/lib/foundation-overlay-load.sh) so an adopter's overlay-master.json amendments
# to .mandatory_files are honored — never consume foundation-master RAW. Materialize the merged
# union once (full-union: same top-level shape as foundation-master) and redirect $BUNDLE at it,
# so the python3 body below reads .mandatory_files from the merged view unchanged. Degrades to
# the raw bundle if the merger is unavailable (loud-safe, never broken).
_OVL="${FOUNDATION_OVERLAY_LOAD:-${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/foundation-overlay-load.sh}"
[ -x "$_OVL" ] || _OVL="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib/foundation-overlay-load.sh"
if [ -x "$_OVL" ] && [ -n "$BUNDLE" ] && [ -f "$BUNDLE" ]; then
  _UNION="$(mktemp 2>/dev/null || true)"
  if [ -n "$_UNION" ] && bash "$_OVL" --foundation-path "$BUNDLE" \
        --overlay-path "$(dirname "$BUNDLE")/overlay-master.json" --force-override > "$_UNION" 2>/dev/null \
        && [ -s "$_UNION" ]; then
    BUNDLE="$_UNION"; trap 'rm -f "$_UNION"' EXIT
  elif [ -n "$_UNION" ]; then rm -f "$_UNION"; fi
fi

VROOT="${VAULT_ROOT:-}"
if [ -z "$VROOT" ] || [ ! -d "$VROOT" ]; then
  echo "index-maintain: VAULT_ROOT unset or absent; nothing to sweep" >&2
  exit 0
fi

python3 - "$VROOT" "${GOV_DIR:-}" "$DEEP" "$DRY_RUN" "$BUNDLE" <<'PY'
import json, os, re, sys, tempfile, fnmatch
from datetime import date

vroot, gov_dir, deep_s, dry_s = sys.argv[1:5]
bundle_path = sys.argv[5] if len(sys.argv) > 5 else ""
deep = (deep_s == "true")
dry_run = (dry_s == "true")
today = date.today().isoformat()
out = os.environ.get("FINDINGS_OUTPUT", "")

START = "<!-- contents-enum:start -->"
END = "<!-- contents-enum:end -->"

def emit(d):
    line = json.dumps(d, ensure_ascii=False)
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")

# --- block-and-log: load + validate the mandatory-files pillar -------------
# Tier-1: bundle-first. The shipped foundation-master.json
# carries the composed .mandatory_files slot; read mandates._index_md from it on
# a fresh adopter (the loose pillar is repo-only). Fall back to the loose pillar
# under gov_dir when the bundle is absent (dev-repo authoring).
exempt_globs = ["Archive/**", "Daily/**", "Inbox/**", "Logs/**", "Work/**"]
# Single SoT for de-exemption: the overlay's path_routing rules. A walked dir
# matching a REGISTERED glob is de-exempted even when a static exemption (e.g.
# Work/**) covers it — registered-glob WINS. There is NO second
# de_exemption_paths list; registration in the overlay IS the de-exemption.
registered_globs = []
# Read the FULL union bundle once (not just .mandatory_files): derive both the
# _index mandate exemption list AND the registered path_routing rule patterns
# from the SAME merged view ($BUNDLE is the overlay-merged union per the loader
# above — frontmatter.path_routing.rules carries every /govern register glob).
bundle = None
mf = None
if bundle_path and os.path.isfile(bundle_path):
    try:
        with open(bundle_path, encoding="utf-8") as fh:
            bundle = json.load(fh)
        mf = (bundle.get("mandatory_files") or {})
    except Exception as exc:
        print("index-maintain: foundation-master.json malformed; "
              "aborting (block-and-log): %s" % exc, file=sys.stderr)
        sys.exit(1)
elif gov_dir:
    mfp = os.path.join(gov_dir, "mandatory-files-rules.json")
    if os.path.isfile(mfp):
        try:
            with open(mfp, encoding="utf-8") as fh:
                mf = json.load(fh)
        except Exception as exc:
            print("index-maintain: mandatory-files-rules.json malformed; "
                  "aborting (block-and-log): %s" % exc, file=sys.stderr)
            sys.exit(1)
if isinstance(mf, dict):
    mandates = mf.get("mandates") or {}
    idx_mandate = mandates.get("_index_md") or {}
    ep = idx_mandate.get("exemption_paths")
    if isinstance(ep, list) and ep:
        exempt_globs = ep
if isinstance(bundle, dict):
    rules = (((bundle.get("frontmatter") or {}).get("path_routing") or {}).get("rules") or [])
    if isinstance(rules, list):
        for r in rules:
            if isinstance(r, dict):
                pat = r.get("pattern")
                if isinstance(pat, str) and pat:
                    registered_globs.append(pat)

def _expand_braces(glob):
    # Expand a {a,b} alternation into brace-free globs (fnmatch has no brace
    # support); left-to-right, recursive for multiple groups. A brace-free glob
    # returns unchanged, so existing single-pattern behaviour is preserved.
    i = glob.find("{")
    if i < 0:
        return [glob]
    j = glob.find("}", i)
    if j < 0:
        return [glob]
    pre, opts, post = glob[:i], glob[i + 1:j], glob[j + 1:]
    out = []
    for opt in opts.split(","):
        out.extend(_expand_braces(pre + opt + post))
    return out

def _glob_match(rel, glob):
    # Match rel against glob via fnmatch (which expands `*`/`**` across path
    # segments). Brace alternations (Work/<spoke>/*/{deliverables,reference}/**)
    # are pre-expanded because fnmatch cannot match braces. Also match the base
    # dir of a `/**` glob so the registered folder itself de-exempts, not only
    # its leaves.
    for g in _expand_braces(glob):
        if fnmatch.fnmatch(rel, g):
            return True
        if g.endswith("/**") and fnmatch.fnmatch(rel, g[:-3]):
            return True
    return False

def is_registered(rel):
    rel = rel.replace(os.sep, "/")
    for g in registered_globs:
        if _glob_match(rel, g):
            return g
    return None

def is_exempt(rel):
    # Registered-glob WINS: a dir under a registered overlay rule is NOT exempt,
    # even when a static glob (Work/**) covers it.
    if is_registered(rel):
        return None
    rel = rel.replace(os.sep, "/")
    for g in exempt_globs:
        if _glob_match(rel, g):
            return g
    return None

def parse_fm(text):
    if not text.startswith("---"):
        return {}, None, None
    end = text.find("\n---", 3)
    if end == -1:
        return {}, None, None
    body = text[3:end]
    fm = {}
    for line in body.splitlines():
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*?)\s*$", line)
        if m:
            fm[m.group(1)] = m.group(2)
    return fm, 3, end

def file_type(path):
    try:
        with open(path, encoding="utf-8") as fh:
            head = fh.read(2048)
    except Exception:
        return ""
    fm, _, _ = parse_fm(head)
    return fm.get("type", "")

def line_count(path):
    try:
        with open(path, "rb") as fh:
            return sum(1 for _ in fh)
    except Exception:
        return 0

corrections = 0
bootstraps = 0

# FIX #7: followlinks=True so the Tier-2 sweep can descend the Work/
# symlink (a vault-view of the external work-home) and reach a registered
# (-de-exempted) Work subdir; without it's overlay-derived de-exemption
# is inert (the walk never gets there). Work/** stays exempt-by-default (the
# is_exempt gate below is the regression guard — only registered globs de-exempt).
# Symlink-loop guard: track realpath(dirpath) in a visited set and prune any subdir
# whose realpath is already visited so a self-referential symlink cannot hang the walk.
_im_visited = set()
for dirpath, dirnames, filenames in os.walk(vroot, followlinks=True):
    _rp = os.path.realpath(dirpath)
    if _rp in _im_visited:
        dirnames[:] = []
        continue
    _im_visited.add(_rp)
    dirnames[:] = [d for d in dirnames
                   if os.path.realpath(os.path.join(dirpath, d)) not in _im_visited]
    dirnames[:] = [d for d in dirnames if not d.startswith(".")]
    rel = os.path.relpath(dirpath, vroot)
    if rel == ".":
        rel = ""
    exempt = is_exempt(rel) if rel else None
    idx_path = os.path.join(dirpath, "_index.md")

    if exempt:
        # index-exemption-conflict — _index.md present at an exempt path.
        if os.path.isfile(idx_path):
            emit({"finding": "index-exemption-conflict", "file": idx_path,
                  "matched_exemption_glob": exempt,
                  "recommended_action": "review-exemption-or-remove",
                  "detected_at": today, "first_seen": today})
        continue

    children = [f for f in filenames
                if f.endswith(".md") and f != "_index.md" and not f.startswith(".")]
    if not children and not os.path.isfile(idx_path):
        continue

    if not os.path.isfile(idx_path):
        # auto-bootstrap a missing non-exempt _index.md (AUTO-CORRECT branch).
        rows = []
        for c in sorted(children):
            cp = os.path.join(dirpath, c)
            rows.append("| [[%s]] | %d | %s | |" % (c[:-3], line_count(cp), file_type(cp) or "—"))
        folder = os.path.basename(dirpath) or os.path.basename(vroot)
        parent = os.path.basename(os.path.dirname(dirpath)) if rel and os.sep in rel else ""
        fm_lines = ["---", "type: index"]
        if parent:
            fm_lines.append("parent_folder: %s" % parent)
        _cohort_slug = re.sub(r"[^a-z0-9]+", "-", (rel or folder).lower()).strip("-") or "index"
        fm_lines += ["description: Folder index for %s." % folder, "created: %s" % today, "tags: [\"#scope/reference\"]", "updated: %s" % today, "id: index-%s" % _cohort_slug, "schema_version: 1", "---", ""]
        body = "\n".join(fm_lines)
        body += "# %s\n\n_Folder index (auto-bootstrapped). Add a folder-context paragraph._\n\n" % folder
        body += "## Contents\n\n" + START + "\n"
        body += "| Name | Lines | Type | Description |\n|------|-------|------|-------------|\n"
        body += ("\n".join(rows) + "\n") if rows else ""
        body += END + "\n"
        if not dry_run:
            try:
                fd, tmp = tempfile.mkstemp(dir=dirpath, prefix="._index.", suffix=".tmp")
                with os.fdopen(fd, "w", encoding="utf-8") as fh:
                    fh.write(body)
                os.replace(tmp, idx_path)
            except Exception as exc:
                emit({"finding": "mandate-violation", "file": dirpath,
                      "bootstrap_error": str(exc),
                      "detected_at": today, "first_seen": today})
                continue
        bootstraps += 1
        emit({"finding": "bootstrap-auto-created", "file": idx_path,
              "frontmatter_inferred": True, "exemption_check_result": "non-exempt",
              "detected_at": today})
        continue

    # existing _index.md: reconcile rows (AUTO-CORRECT) + validate frontmatter.
    with open(idx_path, encoding="utf-8") as fh:
        text = fh.read()
    fm, _, _ = parse_fm(text)

    # index-stale-frontmatter (SEMANTIC/flag branch — emit, no auto-fix of FM
    # shape beyond updated: bump).
    missing_fields = []
    if fm.get("type") != "index":
        missing_fields.append("type")
    if not fm.get("tags"):
        missing_fields.append("tags")
    depth = len([p for p in rel.split(os.sep) if p]) if rel else 0
    if depth >= 1 and "parent_folder" not in fm:
        missing_fields.append("parent_folder")
    if missing_fields:
        emit({"finding": "index-stale-frontmatter", "file": idx_path,
              "missing_or_invalid_fields": missing_fields,
              "detected_at": today, "first_seen": today})

    # index-orphan-folder
    pf = fm.get("parent_folder", "")
    if pf:
        cand = os.path.join(os.path.dirname(dirpath), pf)
        if not os.path.isdir(cand) and not os.path.isdir(os.path.join(vroot, pf)):
            emit({"finding": "index-orphan-folder", "file": idx_path,
                  "declared_parent_folder": pf, "resolved_parent_folder_exists": False,
                  "detected_at": today, "first_seen": today})

    s_idx = text.find(START)
    e_idx = text.find(END)
    if s_idx < 0 or e_idx <= s_idx:
        # no sentinel region — flag as semantic (operator-tuned table); do not
        # mechanically rewrite a non-sentinel-bounded table.
        if deep:
            emit({"finding": "index-row-drift-semantic", "file": idx_path,
                  "drift_type": "no-sentinel-region",
                  "suggested_correction": "wrap the contents table in contents-enum sentinels",
                  "detected_at": today, "first_seen": today})
        continue

    region = text[s_idx + len(START):e_idx]
    existing_rows = {}
    header_lines = []
    for ln in region.split("\n"):
        st = ln.strip()
        if not st.startswith("|"):
            continue
        if "---" in st and set(st) <= set("|-: "):
            header_lines.append(ln)
            continue
        cols = [c.strip() for c in st.strip("|").split("|")]
        m = re.match(r"\[\[(.+?)\]\]", cols[0]) if cols else None
        if m:
            existing_rows[m.group(1)] = cols

    new_rows = []
    drifted = False
    seen = set()
    for c in sorted(children):
        name = c[:-3]
        seen.add(name)
        cp = os.path.join(dirpath, c)
        lc = str(line_count(cp))
        ty = file_type(cp) or "—"
        if name in existing_rows:
            cols = existing_rows[name]
            desc = cols[3] if len(cols) > 3 else ""
            old_lc = cols[1] if len(cols) > 1 else ""
            old_ty = cols[2] if len(cols) > 2 else ""
            if old_lc != lc or old_ty != ty:
                drifted = True
                emit({"finding": "index-row-drift-mechanical", "file": idx_path,
                      "drift_type": "line-or-type", "child_file": c,
                      "before": "%s/%s" % (old_lc, old_ty), "after": "%s/%s" % (lc, ty),
                      "detected_at": today})
                # SEMANTIC --deep: description vs filename coherence
            if deep and desc and name.lower() not in desc.lower():
                emit({"finding": "index-row-drift-semantic", "file": idx_path,
                      "drift_type": "description-coherence", "row_wikilink": name,
                      "suggested_correction": "review description vs file H1",
                      "detected_at": today, "first_seen": today})
            new_rows.append("| [[%s]] | %s | %s | %s |" % (name, lc, ty, desc))
        else:
            drifted = True
            emit({"finding": "index-row-drift-mechanical", "file": idx_path,
                  "drift_type": "missing-row", "child_file": c,
                  "before": "", "after": "row-added", "detected_at": today})
            new_rows.append("| [[%s]] | %s | %s | |" % (name, lc, ty))
    for name in existing_rows:
        if name not in seen:
            drifted = True
            emit({"finding": "index-row-drift-mechanical", "file": idx_path,
                  "drift_type": "orphan-row", "child_file": name + ".md",
                  "before": "row-present", "after": "row-removed", "detected_at": today})

    if drifted and not dry_run:
        hdr = "\n".join(header_lines) if header_lines else \
              "| Name | Lines | Type | Description |\n|------|-------|------|-------------|"
        new_region = "\n" + hdr + "\n" + "\n".join(new_rows) + "\n"
        new_text = text[:s_idx + len(START)] + new_region + text[e_idx:]
        # bump updated:
        new_text = re.sub(r"(?m)^updated:.*$", "updated: %s" % today, new_text, count=1)
        try:
            fd, tmp = tempfile.mkstemp(dir=dirpath, prefix="._index.", suffix=".tmp")
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(new_text)
            os.replace(tmp, idx_path)
            corrections += 1
        except Exception as exc:
            print("index-maintain: write failed for %s: %s" % (idx_path, exc), file=sys.stderr)

# --- the master-deliverables-conflict audit: work-master-deliverables-conflict (advisory, audit-time) -
# A Work/<spoke> that is a MASTER (its sub-projects own the deliverables/reference)
# must hold NO non-empty top-level deliverables/ or reference/. This is a read-only
# advisory finding — never auto-corrected, never relocated (relocation is the
# operator's call). MASTER discriminator:
#   MASTER  iff  top-level deliverables/ ABSENT AND top-level reference/ ABSENT
#                AND >=1 child dir holding its own deliverables/ or reference/.
#   MASTER-PENDING  = no-top-deliverables/reference spoke with ZERO qualifying
#                     children (a master awaiting its first sub-project) — BENIGN,
#                     nothing to conflict.
# The "absence of top-level deliverables/reference" is the load-bearing condition;
# a flat project ALWAYS has top-level deliverables/, so a flat project never enters
# either MASTER arm and is never flagged here. The conflict case the audit catches:
# a master that ALSO carries a non-empty top-level deliverables/ or reference/.
def _dir_nonempty(p):
    try:
        return os.path.isdir(p) and any(os.scandir(p))
    except Exception:
        return False

def _has_deliverables_or_reference(base):
    return (os.path.isdir(os.path.join(base, "deliverables"))
            or os.path.isdir(os.path.join(base, "reference")))

work_root = os.path.join(vroot, "Work")
if os.path.isdir(work_root):
    try:
        spokes = sorted(d.name for d in os.scandir(work_root) if d.is_dir())
    except Exception:
        spokes = []
    for spoke in spokes:
        if spoke.startswith("."):
            continue
        sp_path = os.path.join(work_root, spoke)
        top_deliverables = os.path.join(sp_path, "deliverables")
        top_reference = os.path.join(sp_path, "reference")
        top_has = os.path.isdir(top_deliverables) or os.path.isdir(top_reference)
        # Qualifying children: child dirs (not deliverables/reference themselves)
        # that hold their OWN deliverables/ or reference/.
        try:
            children = [c.name for c in os.scandir(sp_path)
                        if c.is_dir() and not c.name.startswith(".")
                        and c.name not in ("deliverables", "reference")]
        except Exception:
            children = []
        qualifying = [c for c in children
                      if _has_deliverables_or_reference(os.path.join(sp_path, c))]
        if not top_has:
            # No top-level deliverables/reference. MASTER (>=1 qualifying child)
            # or MASTER-PENDING (zero) — both benign for THIS conflict check
            # (a master with no top-level deliverables is exactly the invariant).
            continue
        # top_has is True: a flat project (NOT a master) UNLESS it also has a
        # qualifying child — in which case it is a master that VIOLATES the
        # master-holds-no-deliverables invariant.
        if qualifying:
            conflict_dirs = []
            if _dir_nonempty(top_deliverables):
                conflict_dirs.append("deliverables")
            if _dir_nonempty(top_reference):
                conflict_dirs.append("reference")
            if conflict_dirs:
                emit({"finding": "work-master-deliverables-conflict",
                      "file": sp_path,
                      "spoke": spoke,
                      "conflicting_top_level_dirs": conflict_dirs,
                      "qualifying_sub_projects": sorted(qualifying),
                      "recommended_action": "relocate-top-level-deliverables-into-a-sub-project",
                      "detected_at": today, "first_seen": today})

print("index-maintain: bootstraps=%d corrections=%d deep=%s dry_run=%s"
      % (bootstraps, corrections, deep, dry_run), file=sys.stderr)
PY
