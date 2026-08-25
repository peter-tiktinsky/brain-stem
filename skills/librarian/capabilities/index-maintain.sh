#!/bin/bash
# index-maintain — Audit-time reconciler for every non-exempt folder's
# _index.md contents-enum table against filesystem reality. The first canonical
# self-healing capability under the R-34 boundary.
#
# NET-NEW librarian body (1.1 line 136 — replaces the phantom
# doc-reference). Authored from the authoring-spec index-maintain.md
# (REFERENCE only —(a)).
#
# R-34 self-healing boundary (enforced by code structure):
#   In bounds (auto-corrected): Lines (wc -l), Type (frontmatter type:),
#     missing/orphan rows, updated: bump, auto-bootstrap of a missing non-exempt
#     _index.md, and the bounded frontmatter re-mint on an existing index — the
#     heal set tracks the staleness-flag set: type: (const `index` per the mandate
#     contract; absent inserted, wrong rewritten), tags: (bootstrap default seeded
#     ONLY when the key line is entirely absent — a present key is never
#     rewritten), parent_folder: (path-derived root-relative parent at depth>=2;
#     absent or divergent values heal). Atomic, dry-run-aware. These flow through
#     the AUTO-CORRECT branch.
#   Out of bounds (flagged, never overwritten): descriptions, ordering,
#     exemption-list decisions, folder-context paragraph, created: (unknowable for
#     an existing file), every human-authored/foreign frontmatter key (e.g. a
#     hand-era engagement:/status:/owner: shape — preserved, never auto-removed),
#     and whole-frontmatter-block creation on a file with no block. These flow
#     through the SEMANTIC-DRIFT branch which emits findings and NEVER writes vault
#     content.
#   The two branches are not interchangeable — the semantic branch has no
#     write-to-vault code path.
#
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
#
# Finding categories (7 — §Finding categories):
#   bootstrap-auto-created     (info-event) created a missing non-exempt _index.md
#   index-row-drift-mechanical (info-event) auto-corrected Lines/Type/missing/orphan row
#   index-row-drift-semantic   (warning, --deep) description/ordering drift — NO auto-overwrite
#   index-stale-frontmatter    (warning) _index.md frontmatter fails the index contract
#   parent-folder-healed       (info-event) parent_folder: line healed to the
#     path-derived root-relative parent (AUTO-CORRECT; dry-run emits with dry_run:true)
#   index-frontmatter-healed   (info-event) bounded FM re-mint applied on an
#     existing index (healed_keys[]: type const / absent-key tags default seed)
#   index-orphan-folder        (warning) parent_folder: does not resolve (root-join)
#   index-exemption-conflict   (warning) STRAY _index.md at an exempt path — a
#     file matching another capability's declared writes[] target (capability
#     registry) is writer-owned and NOT flagged
#   mandate-violation          (warning) non-exempt folder lacks _index.md AND bootstrap failed
#   work-master-deliverables-conflict (warning, advisory) a Work/<spoke> MASTER
#     (sub-projects own deliverables/reference) ALSO carries a non-empty top-level
#     deliverables/ or reference/ — read-only, never auto-relocated (the
#     master-deliverables-conflict audit; MASTER-PENDING spokes with no qualifying
#     child are benign and not flagged)
#
# CLI:
#   index-maintain.sh             # Tier 2 sweep (mechanical auto-correct)
#   index-maintain.sh --deep      # Tier 3 (+ semantic-drift findings, no auto-overwrite)
#   index-maintain.sh --dry-run   # findings + would-be corrections, no write
#   index-maintain.sh --help
#
# Env overrides (testing):
#   VAULT_ROOT        vault root to walk (required for any real sweep)
#   GOVERNANCE_DIR    governance root (default: foundation-repo -> live install)
#   FINDINGS_OUTPUT   NDJSON sink (default: stdout)
#
# Bash 3.2 clean per R-23. Argv-based Python heredoc per R-24.

set -uo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
# shellcheck source=/dev/null
source "$CLAUDE_HOME_RES/hooks/lib/findings.sh" 2>/dev/null \
  || source "$(cd "$(dirname "$0")/../../.." && pwd)/hooks/lib/findings.sh"
# G5 (S4 T-1): source the manifest API so the summary subtree persists to
# the librarian-manifest via manifest_set — makes the registry's declared
# writes_manifest_subtree: "drift_findings.index_maintain" REAL, so it is removed
# from _parity_pending_manifest_writes[] in the same commit. manifest.sh sources
# paths.sh itself (idempotent guard) → $CLAUDE_STATE_ROOT/$COORD_DIR resolve.
# shellcheck source=/dev/null
source "$CLAUDE_HOME_RES/hooks/lib/manifest.sh" 2>/dev/null \
  || source "$(cd "$(dirname "$0")/../../.." && pwd)/hooks/lib/manifest.sh"

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

# G5 (S4 T-1): capture a machine-readable summary subtree the bash layer
# persists to the manifest (drift_findings.index_maintain) via manifest_set AFTER
# the PY heredoc — mirrors placement-validate.sh's MANIFEST_SUBTREE_OUT / manifest_set
# pattern. Kept off stdout so the NDJSON findings stream is never polluted.
MANIFEST_SUBTREE_OUT="$(mktemp -t index-subtree-XXXXXX)"
export MANIFEST_SUBTREE_OUT

# Writer-owned exemption-conflict skip inputs: the capability registry (the
# parity-checked declared-writes SoT) and the plans root (placeholder resolution
# for {PLANS_ROOT}/{library} targets). Env-overridable for test isolation; a
# missing/unreadable registry fails closed to the flag-everything behavior.
CAP_REGISTRY="${CAPABILITY_REGISTRY:-$(cd "$(dirname "$0")/.." && pwd)/capability-registry.json}"
PLANS_ROOT_RES="${PLANS_DIR:-$HOME/.claude-plans}"

python3 - "$VROOT" "${GOV_DIR:-}" "$DEEP" "$DRY_RUN" "$BUNDLE" "$CAP_REGISTRY" "$PLANS_ROOT_RES" <<'PY'
import json, os, re, sys, tempfile, fnmatch
from datetime import date, datetime, timezone

vroot, gov_dir, deep_s, dry_s = sys.argv[1:5]
bundle_path = sys.argv[5] if len(sys.argv) > 5 else ""
registry_path = sys.argv[6] if len(sys.argv) > 6 else ""
plans_root = sys.argv[7] if len(sys.argv) > 7 else ""
deep = (deep_s == "true")
dry_run = (dry_s == "true")
today = date.today().isoformat()
out = os.environ.get("FINDINGS_OUTPUT", "")
subtree_out = os.environ.get("MANIFEST_SUBTREE_OUT", "")

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
# DEAD-IN-PRACTICE default: a non-empty pillar
# mandates._index_md.exemption_paths UNCONDITIONALLY replaces this at the
# `if isinstance(ep, list) and ep` gate below; kept coherent with the pillar
# (also the four foreign symlink surfaces Plans/Projects/Wiki/Skills)
# ONLY for the bundle-less AND pillar-less fallback (never reached in a real sweep).
exempt_globs = ["Archive/**", "Daily/**", "Inbox/**", "Logs/**", "Work/**",
                "Plans/**", "Projects/**", "Wiki/**", "Skills/**"]
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

def md_target(t):
    # minimal percent-quoting so a markdown link target survives spaces/parens
    return t.replace(" ", "%20").replace("(", "%28").replace(")", "%29")

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

# "Exempt from the MANDATE to exist" is not "forbidden to EXIST": an _index.md at
# an exempt path that matches ANOTHER capability's declared writes[] target in the
# capability registry is writer-owned (nonconformance heals at that writer) and is
# NOT an exemption conflict. The skip set derives from the registry — the
# parity-checked SoT — never a hardcoded path list; index-maintain's own entry is
# EXCLUDED (its {VAULT_ROOT}/** target is the mandate population itself, not an
# ownership claim over exempt paths). A missing/unreadable registry yields an
# empty set (fail-closed to the flag-everything behavior — the arm is a warning).
def _expand_braces(glob):
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

def _writer_owned_globs():
    globs = []
    if not registry_path:
        return globs
    try:
        with open(registry_path, encoding="utf-8") as fh:
            reg = json.load(fh)
    except Exception:
        return globs
    caps = reg.get("capabilities", {}) if isinstance(reg, dict) else {}
    pr = os.path.realpath(plans_root) if plans_root else ""
    lib_root = os.path.join(pr, "_library") if pr else ""
    wh = os.environ.get("WORK_HOME", "") or os.environ.get("BRAIN_STEM_WORK_HOME", "")
    wh = os.path.realpath(wh) if wh else ""
    vr = os.path.realpath(vroot)
    for name, cap in caps.items():
        if name == "index-maintain" or not isinstance(cap, dict):
            continue
        for w in ((cap.get("output_contract") or {}).get("writes") or []):
            if not isinstance(w, str):
                continue
            token = w.split(" ", 1)[0].strip()
            if not token.endswith("/_index.md"):
                continue
            token = token.replace("{PLANS_ROOT}", pr or "\0")
            token = token.replace("{library}", lib_root or "\0")
            token = token.replace("{VAULT_ROOT}", vr)
            token = token.replace("$WORK_HOME", wh or "\0")
            token = re.sub(r"<[^>/]+>", "*", token)
            token = token.replace("/.../", "/*/")
            for t in _expand_braces(token):
                if "\0" in t or "{" in t:
                    continue  # placeholder unresolvable in this environment
                globs.append(t)
    return globs

_owned_globs = _writer_owned_globs()

def _writer_owned(path):
    rp = os.path.realpath(path)
    for g in _owned_globs:
        if fnmatch.fnmatch(rp, g):
            return g
    return None

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
        # index-exemption-conflict — a STRAY _index.md at an exempt path. A file
        # matching another capability's declared writes[] target is writer-owned
        # and skipped (see _writer_owned above) — exempt-from-mandate is not
        # forbidden-to-exist (mandatory-files-rules.json :: exemption_semantics).
        if os.path.isfile(idx_path) and not _writer_owned(idx_path):
            emit({"finding": "index-exemption-conflict", "file": idx_path,
                  "matched_exemption_glob": exempt,
                  "recommended_action": "review-exemption-or-remove",
                  "detected_at": today, "first_seen": today})
        continue

    def _nonzero(pth):
        try:
            return os.path.getsize(pth) > 0
        except Exception:
            return False

    # zero-byte .md children are non-authored placeholders — excluded from
    # enumeration (they enter the table when they gain content).
    children = [f for f in filenames
                if f.endswith(".md") and f != "_index.md" and not f.startswith(".")
                and _nonzero(os.path.join(dirpath, f))]

    # vault-root surfaces: at the ROOT index only, direct child dirs render as
    # `surface`-type rows (File -> markdown link, Description -> resolved target)
    # so a symlink-hub root is navigable instead of tabling 2 files while the
    # hubs stay invisible. Description is DERIVED (re-resolved each splice).
    surfaces = []
    if not rel:
        for d in sorted(dirnames):
            _dp = os.path.join(dirpath, d)
            if os.path.islink(_dp):
                surfaces.append((d, "→ %s" % os.path.realpath(_dp)))
            else:
                surfaces.append((d, "(directory)"))

    if not children and not surfaces and not os.path.isfile(idx_path):
        continue

    if not os.path.isfile(idx_path):
        # auto-bootstrap a missing non-exempt _index.md (AUTO-CORRECT branch).
        rows = []
        for d, dest in surfaces:
            rows.append("| [%s](%s/) | — | surface | %s |" % (d, md_target(d), dest))
        for c in sorted(children):
            cp = os.path.join(dirpath, c)
            rows.append("| [%s](%s) | %d | %s | |" % (c[:-3], md_target(c), line_count(cp), file_type(cp) or "—"))
        folder = os.path.basename(dirpath) or os.path.basename(vroot)
        # parent_folder (contract shape): the indexed folder's PARENT as a
        # root-relative path — at depth 2 this equals the parent's basename, at
        # depth >= 3 it is path-qualified (e.g. Work/<spoke>). Emitted at depth >= 2
        # only (conditional_required per the _index.md contract).
        parent = os.path.dirname(rel).replace(os.sep, "/") if rel and os.sep in rel else ""
        fm_lines = ["---", "type: index"]
        if parent:
            fm_lines.append("parent_folder: %s" % parent)
        _cohort_slug = re.sub(r"[^a-z0-9]+", "-", (rel or folder).lower()).strip("-") or "index"
        fm_lines += ["description: Folder index for %s." % folder, "created: %s" % today, "tags: [\"#scope/reference\"]", "updated: %s" % today, "id: index-%s" % _cohort_slug, "schema_version: 1", "---", ""]
        body = "\n".join(fm_lines)
        body += "# %s\n\n*[Folder context paragraph: 2-4 sentences describing what lives here, what doesn't, why the folder exists. Pedagogical.]*\n\n" % folder
        body += "## Contents\n\n" + START + "\n\n"
        body += "| File | Lines | Type | Description |\n|---|---|---|---|\n"
        body += ("\n".join(rows) + "\n") if rows else ""
        body += "\n" + END + "\n"
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

    depth = len([p for p in rel.split(os.sep) if p]) if rel else 0

    # frontmatter heal (AUTO-CORRECT branch): the bounded re-mint set tracks the
    # staleness-flag set — type: (const `index` per the mandate contract; absent
    # inserted, wrong rewritten), tags: (bootstrap default seeded ONLY when the
    # key line is entirely ABSENT — a present key is never rewritten, because an
    # empty inline value is indistinguishable from a multi-line YAML list head and
    # rewriting it would orphan the list items), parent_folder: (the path-derived
    # root-relative parent at depth>=2). created:/description: and every
    # human-authored key (e.g. a hand-era engagement:/status:/owner: shape) are
    # NEVER touched — additions land around them. A file with no frontmatter
    # block at all stays flag-only (whole-block creation is out of bounds). One
    # atomic write; dry-run emits findings and mirrors the healed state in-memory
    # without writing.
    if text.startswith("---"):
        fm_end = text.find("\n---", 3)
        if fm_end != -1:
            fm_block = text[3:fm_end]
            fm_lines = fm_block.split("\n")
            healed_keys = []
            pf_from = None
            pf_to = None

            def _key_line_idx(key):
                for i, ln in enumerate(fm_lines):
                    if re.match(r"^%s:(\s|$)" % key, ln):
                        return i
                return -1

            def _insert_after_type(line):
                ti = _key_line_idx("type")
                fm_lines.insert(ti + 1 if ti >= 0 else 1, line)

            ti = _key_line_idx("type")
            if ti < 0:
                fm_lines.insert(1, "type: index")
                healed_keys.append("type")
            elif fm.get("type") != "index":
                fm_lines[ti] = "type: index"
                healed_keys.append("type")

            if _key_line_idx("tags") < 0:
                _insert_after_type('tags: ["#scope/reference"]')
                healed_keys.append("tags")

            if depth >= 2:
                derived_pf = os.path.dirname(rel).replace(os.sep, "/")
                cur_pf = fm.get("parent_folder", "")
                if derived_pf and cur_pf != derived_pf:
                    pi = _key_line_idx("parent_folder")
                    if pi >= 0:
                        fm_lines[pi] = "parent_folder: %s" % derived_pf
                    else:
                        _insert_after_type("parent_folder: %s" % derived_pf)
                    pf_from, pf_to = cur_pf, derived_pf

            if healed_keys or pf_to is not None:
                healed_text = "---" + "\n".join(fm_lines) + text[fm_end:]
                heal_ok = True
                if not dry_run:
                    try:
                        fd, tmp = tempfile.mkstemp(dir=dirpath, prefix="._index.", suffix=".tmp")
                        with os.fdopen(fd, "w", encoding="utf-8") as fh:
                            fh.write(healed_text)
                        os.replace(tmp, idx_path)
                    except Exception as exc:
                        heal_ok = False
                        emit({"finding": "mandate-violation", "file": idx_path,
                              "heal_error": str(exc),
                              "detected_at": today, "first_seen": today})
                if heal_ok:
                    text = healed_text
                    fm, _, _ = parse_fm(text)
                    if pf_to is not None:
                        emit({"finding": "parent-folder-healed", "file": idx_path,
                              "healed_from": pf_from, "healed_to": pf_to,
                              "dry_run": dry_run, "detected_at": today})
                    if healed_keys:
                        emit({"finding": "index-frontmatter-healed", "file": idx_path,
                              "healed_keys": healed_keys,
                              "dry_run": dry_run, "detected_at": today})

    # index-stale-frontmatter (SEMANTIC/flag branch — emit, no auto-fix of FM
    # shape beyond updated: bump). parent_folder is demanded at depth >= 2 only,
    # matching the contract's conditional_required (depth-1 indexes omit it).
    missing_fields = []
    if fm.get("type") != "index":
        missing_fields.append("type")
    if not fm.get("tags"):
        missing_fields.append("tags")
    if depth >= 2 and "parent_folder" not in fm:
        missing_fields.append("parent_folder")
    if missing_fields:
        emit({"finding": "index-stale-frontmatter", "file": idx_path,
              "missing_or_invalid_fields": missing_fields,
              "detected_at": today, "first_seen": today})

    # index-orphan-folder — single-mode: the contract's parent_folder is
    # root-relative, so the ONE canonical resolution is a root join (which also
    # resolves across the vault's symlink hubs, e.g. Work/). The former
    # sibling-relative probe existed only to half-tolerate bare-basename values
    # (silent pass at depth 2, false orphan at depth >= 3) and is deliberately
    # removed with them.
    pf = fm.get("parent_folder", "")
    if pf and not os.path.isdir(os.path.join(vroot, pf)):
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
    # track the human header row and the delimiter row SEPARATELY. A
    # pipe-line that is neither the delimiter nor a `[[`-row, seen BEFORE any data
    # row (existing_rows still empty), IS the operator-tuned header — preserve it
    # verbatim on re-splice; a headerless region self-heals (header_row stays None).
    header_row = None
    delim_row = None
    for ln in region.split("\n"):
        st = ln.strip()
        if not st.startswith("|"):
            continue
        if "---" in st and set(st) <= set("|-: "):
            delim_row = ln
            continue
        cols = [c.strip() for c in st.strip("|").split("|")]
        # data rows carry either the retired wikilink grammar (live files converge
        # on their next drifted re-splice) or the ruled markdown-link grammar;
        # both key on the display label.
        m = re.match(r"\[\[(.+?)\]\]", cols[0]) if cols else None
        if not m and cols:
            m = re.match(r"\[([^\]]+)\]\([^)]*\)", cols[0])
        if m:
            existing_rows[m.group(1)] = cols
        elif not existing_rows:
            header_row = ln

    new_rows = []
    drifted = False
    seen = set()
    for d, dest in surfaces:
        seen.add(d)
        srow = ["[%s](%s/)" % (d, md_target(d)), "—", "surface", dest]
        if d in existing_rows:
            old = existing_rows[d]
            if (old[3] if len(old) > 3 else "") != dest or (old[2] if len(old) > 2 else "") != "surface":
                drifted = True
                emit({"finding": "index-row-drift-mechanical", "file": idx_path,
                      "drift_type": "surface-resolution", "child_file": d + "/",
                      "before": (old[3] if len(old) > 3 else ""), "after": dest,
                      "detected_at": today})
        else:
            drifted = True
            emit({"finding": "index-row-drift-mechanical", "file": idx_path,
                  "drift_type": "missing-row", "child_file": d + "/",
                  "before": "", "after": "row-added", "detected_at": today})
        new_rows.append("| %s | %s | %s | %s |" % tuple(srow))
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
            new_rows.append("| [%s](%s.md) | %s | %s | %s |" % (name, md_target(name), lc, ty, desc))
        else:
            drifted = True
            emit({"finding": "index-row-drift-mechanical", "file": idx_path,
                  "drift_type": "missing-row", "child_file": c,
                  "before": "", "after": "row-added", "detected_at": today})
            new_rows.append("| [%s](%s.md) | %s | %s | |" % (name, md_target(name), lc, ty))
    for name in existing_rows:
        if name not in seen:
            drifted = True
            emit({"finding": "index-row-drift-mechanical", "file": idx_path,
                  "drift_type": "orphan-row", "child_file": name + ".md",
                  "before": "row-present", "after": "row-removed", "detected_at": today})

    # a damaged HEADERLESS region (no human header captured) is repaired even
    # when no rows drifted — force a re-splice so the canonical header is reconstructed.
    if header_row is None:
        drifted = True

    if drifted and not dry_run:
        # assemble the header from the SURVIVING rows, falling back to the
        # bootstrap-branch canonical 2-line header (see :334) when the region carried
        # none — preserves an operator-tuned header, self-heals a damaged one.
        canonical_header = "| File | Lines | Type | Description |"
        canonical_delimiter = "|---|---|---|---|"
        hdr = (header_row or canonical_header) + "\n" + (delim_row or canonical_delimiter)
        new_region = "\n\n" + hdr + "\n" + "\n".join(new_rows) + "\n\n"
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

# (Option A store): the per-folder sub-project declaration marker. This
# python predicate is the MIRROR of work-spoke-layout.sh's declared_subproject —
# the lib is bash and this capability is python, so they cannot share source; the
# mirror is kept in DECLARATION-FIRST precedence-parity with the lib (a documented
# cross-language duplicate, exercised by the ac-index-maintain-work-followlinks
# fixture). Presence of the marker declares a child a sub-project regardless of shape.
_SUBPROJECT_MARKER = ".claude-subproject"

def _is_declared_subproject(base):
    return os.path.isfile(os.path.join(base, _SUBPROJECT_MARKER))

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
        # that are DECLARED sub-projects (own the .claude-subproject marker) OR,
        # failing that, hold their OWN deliverables/ or reference/ (declaration-first,
        # shape-fallback — in parity with work-spoke-layout.sh classify_top_level).
        try:
            children = [c.name for c in os.scandir(sp_path)
                        if c.is_dir() and not c.name.startswith(".")
                        and c.name not in ("deliverables", "reference")]
        except Exception:
            children = []
        qualifying = [c for c in children
                      if _is_declared_subproject(os.path.join(sp_path, c))
                      or _has_deliverables_or_reference(os.path.join(sp_path, c))]
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

# G5 (S4 T-1): write the summary subtree (bootstraps/corrections/deep/
# dry_run) the bash layer persists via manifest_set '.drift_findings.index_maintain'.
# Additive summary only — no change to the finding stream or the vault _index.md writes.
if subtree_out:
    subtree = {
        "last_scan": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S"),
        "bootstraps": bootstraps,
        "corrections": corrections,
        "deep": deep,
        "dry_run": dry_run,
    }
    with open(subtree_out, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(subtree, ensure_ascii=False))
PY

# G5 (S4 T-1): persist the index-maintain summary subtree to the
# librarian-manifest — makes the registry's declared
# writes_manifest_subtree: "drift_findings.index_maintain" real (removed from
# _parity_pending_manifest_writes[] in the same commit), mirroring
# placement-validate's own walker. manifest+lock live under always-creatable
# $CLAUDE_STATE_ROOT/$COORD_DIR (G2), so the persist needs no non-empty
# VAULT_LOGS. Gate only on having a subtree to write.
if [ -s "$MANIFEST_SUBTREE_OUT" ]; then
  manifest_set '.drift_findings.index_maintain' "$(cat "$MANIFEST_SUBTREE_OUT")"
fi
rm -f "$MANIFEST_SUBTREE_OUT"
