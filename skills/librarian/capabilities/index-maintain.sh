#!/bin/bash
# index-maintain — Audit-time reconciler for every non-exempt folder's
# _index.md contents-enum table against filesystem reality. The first canonical
# self-healing capability under the R-34 boundary.
# NET-NEW librarian body (;1.1 line 136 — replaces the phantom
# doc-reference). Authored from the authoring-spec index-maintain.md
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
import json, os, re, sys, tempfile
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
# carries the composed .mandatory_files slot; read mandates._index_md from it on
# a fresh adopter (the loose pillar is repo-only). Fall back to the loose pillar
# under gov_dir when the bundle is absent (dev-repo authoring).
exempt_globs = ["Archive/**", "Daily/**", "Inbox/**", "Logs/**", "Meetings/**"]
mf = None
if bundle_path and os.path.isfile(bundle_path):
    try:
        with open(bundle_path, encoding="utf-8") as fh:
            mf = (json.load(fh).get("mandatory_files") or {})
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

def is_exempt(rel):
    rel = rel.replace(os.sep, "/")
    for g in exempt_globs:
        base = g.replace("/**", "").replace("**", "").rstrip("/")
        if base and (rel == base or rel.startswith(base + "/")):
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

for dirpath, dirnames, filenames in os.walk(vroot):
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
        fm_lines += ["tags: [\"#scope/reference\"]", "updated: %s" % today, "---", ""]
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

print("index-maintain: bootstraps=%d corrections=%d deep=%s dry_run=%s"
      % (bootstraps, corrections, deep, dry_run), file=sys.stderr)
PY
