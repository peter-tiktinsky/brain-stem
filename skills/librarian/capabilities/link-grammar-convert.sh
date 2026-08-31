#!/bin/bash
# link-grammar-convert — Convert live-prose wikilinks to the ruled relative
# markdown-link grammar across the vault view, under the PROMOTED house pattern
# (structural-fresh seed / sibling dry-run / register-with-approval / refusal-
# gated apply) plus the invariant this operation uniquely allows:
# RESOLUTION-SET EQUALITY — every converted link must resolve to the SAME
# physical file after conversion as before, or the run refuses.
#
# PROMOTION PROVENANCE: this generalizes a conversion pattern that was
# independently re-derived five times in live remediation work before being
# promoted here (the largest such run shipped 158 files / 716 replacements).
# Eight house properties carried:
#   1. STRUCTURAL-FRESH SEED — the population re-derives from a live walk on
#      EVERY invocation; stale-seed consumption is architecturally impossible.
#   2. DRY-RUN SIBLINGS (.lgcnew), never in-place — the reviewer diffs real
#      files in place with real content.
#   3. SELF-VERIFYING PER-FILE INVARIANTS incl. reverse-mapping accounting.
#   4. REGISTER with a BLANK APPROVAL LINE that --apply refuses without.
#   5. FIVE APPLY-TIME REFUSALS: blank approval / scheduled-pipeline fire band /
#      Obsidian running / dirty target tree (beyond .lgcnew siblings) / any
#      invariant failure — PLUS a per-file changed-on-disk re-check.
#   6. AMBIGUITY ROUTED TO A JUDGMENT REGISTER, never guessed (registry-seeded
#      repair only — no heuristic fuzzy matching).
#   7. PER-BATCH GIT COMMIT (apply commits the converted set when the root is a
#      git repo; a non-repo root applies without commit and says so).
#   8. TEMP + os.replace WRITES (mkstemp in the target dir, chmod from the
#      original, write-once pre-image sidecar .pre-lgc before the mutation).
#
# GRAMMAR: [[target]] -> [target](rel/path.md); [[target|alias]] ->
# [alias](rel/path.md); [[target#anchor]] -> [target#anchor](rel/path.md#anchor)
# — alias and anchor preserved; href %-quoted; relative to the SOURCE file's
# own vault-view directory. LIVE PROSE ONLY: fenced blocks and inline-code
# spans are never converted (a wikilink there is a quotation, not a link).
# MEMORY NAMESPACE hard-excluded: a target resolving into the enumerated
# memory/rules roots stays a wikilink — that tier is exempt from the
# conversion and resolves against its own namespace, not the vault walk.
#
# Output Contract
#   Dry-run (default) writes ONLY: per-file .lgcnew siblings + the register
#     (LINK_GRAMMAR_REGISTER). No corpus file, manifest, or shared state is
#     touched — dry-run purity is fixture-TESTED, not assumed.
#   --apply (approval-gated) rewrites the seeded files atomically, leaves a
#     .pre-lgc pre-image sidecar per file, removes the .lgcnew siblings, and
#     commits per batch when the root is a git repo.
#   Findings: NDJSON via hooks/lib/findings.sh (never a local emitter).
#   Failure mode: block-and-log; any invariant failure blocks apply.
#
# CLI:
#   link-grammar-convert.sh              # dry-run: seed + siblings + register
#   link-grammar-convert.sh --apply      # apply after the register is approved
#   link-grammar-convert.sh --force      # regenerate a register whose approval
#                                        # line is already filled
#   link-grammar-convert.sh --help
#
# Env overrides:
#   VAULT_ROOT               walk root (paths.sh resolution; REQUIRED if empty)
#   LINK_GRAMMAR_REGISTER    register path (default:
#                            $HOOKS_STATE/link-grammar-convert/register.md)
#   MEMORY_NS_ROOTS          colon-separated memory-namespace roots (default:
#                            $CLAUDE_HOME rules/ + projects/*/memory/)
#   PIPELINE_FIRE_TIMES      space-separated HH:MM fire times; --apply refuses
#                            inside [fire-8min, fire+20min]; empty = no band
#   LGC_EDITOR_PROCESS       pgrep -x process name for the editor-running
#                            refusal (default: Obsidian; fixtures point it at
#                            a live shell / an impossible name to force both
#                            branches)
#   FINDINGS_OUTPUT          NDJSON sink (default: stdout)
#
# Bash 3.2 clean (R-23). Data reaches python via argv, never a piped stdin.

set -u

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib"
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
  || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; } || true
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || { [ -r "$_REPO_LIB/findings.sh" ] && source "$_REPO_LIB/findings.sh"; } || true
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/vault-view-walk.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/vault-view-walk.sh"; } \
  || { [ -r "$_REPO_LIB/vault-view-walk.sh" ] && source "$_REPO_LIB/vault-view-walk.sh"; } || true

APPLY="false"; FORCE="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY="true"; shift ;;
    --force) FORCE="true"; shift ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    *) echo "link-grammar-convert: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

VAULT_ROOT="${VAULT_ROOT:-}"
if [ -z "$VAULT_ROOT" ] || [ ! -d "$VAULT_ROOT" ]; then
  echo "link-grammar-convert: VAULT_ROOT unset or missing — nothing to walk" >&2
  exit 0
fi

# Judgment-tier non-interactive guard (transplanted from library-scrub.sh; the
# dry-run phase is read-only against the corpus and harmless, but --apply
# rewrites durable content — an unattended cron sweep must never auto-apply).
# CLAUDECODE (an attended Claude Code session) bypasses; a bare non-TTY cron
# sweep (CLAUDECODE unset) still blocks.
if [ "$APPLY" = "true" ] && [ -z "${FOUNDATION_TEST_MODE:-}" ] \
   && [ -z "${CLAUDECODE:-}" ] && [ -z "${TTY:-}" ] && ! [ -t 0 ]; then
  echo "link-grammar-convert: --apply skipped (non-interactive)" >&2
  exit 0
fi

STATE_ROOT="${HOOKS_STATE_OVERRIDE:-${HOOKS_STATE:-$HOME/.local/state/brain-stem}}"
REGISTER="${LINK_GRAMMAR_REGISTER:-$STATE_ROOT/link-grammar-convert/register.md}"

# Structural-fresh seed: the walk list re-derives on EVERY invocation.
WALK_LIST="$(mktemp -t lgc-walk.XXXXXX)" || exit 1
trap 'rm -f "${WALK_LIST:-}" "${SURFACE_ROSTER_FILE:-}"' EXIT

# Surface roster (SSOT): exemption-tier roots (memory/rules/spoke corpora stay
# wikilinks) + retired denylist. A pre-set SURFACE_ROSTER_FILE wins (test
# isolation).
if [ -z "${SURFACE_ROSTER_FILE:-}" ]; then
  _SR_LIB="${SURFACE_ROSTER_LIB:-${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/surface-roster.sh}"
  [ -r "$_SR_LIB" ] || _SR_LIB="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/hooks/lib/surface-roster.sh"
  if [ -r "$_SR_LIB" ]; then
    # shellcheck source=/dev/null
    . "$_SR_LIB"
    if command -v surface_roster_json >/dev/null 2>&1; then
      SURFACE_ROSTER_FILE="$(mktemp -t lgc-roster.XXXXXX)"
      surface_roster_json > "$SURFACE_ROSTER_FILE" 2>/dev/null || true
    fi
  fi
fi
export SURFACE_ROSTER_FILE
if command -v vault_view_walk >/dev/null 2>&1; then
  vault_view_walk "$VAULT_ROOT" > "$WALK_LIST" 2>/dev/null || true
else
  find "$VAULT_ROOT" -name '.*' -prune -o -type f -name '*.md' -print > "$WALK_LIST" 2>/dev/null || true
fi

OUT_LINES="$(mktemp -t lgc-out.XXXXXX)" || exit 1

python3 - "$VAULT_ROOT" "$WALK_LIST" "$REGISTER" "$APPLY" "$FORCE" \
          "${MEMORY_NS_ROOTS-__UNSET__}" "${CLAUDE_HOME:-$HOME/.claude}" \
          "${PIPELINE_FIRE_TIMES:-}" "$OUT_LINES" <<'PYEOF'
import collections, datetime, json, os, re, subprocess, sys, tempfile
from urllib.parse import quote as urlquote, unquote as urlunquote

(vault_root, walk_list, register, apply_s, force_s,
 mem_roots_raw, claude_home, fire_times_raw, out_lines) = sys.argv[1:10]
apply_mode = apply_s == "true"
force = force_s == "true"

# ---------- surface roster (SSOT): namespace roots + retired denylist ----------
# Loaded BEFORE the walk so retired surfaces never enter the conversion corpus.
_ROSTER_NS_ROOTS, _ROSTER_RETIRED = [], []
_sr_file = os.environ.get("SURFACE_ROSTER_FILE", "")
if _sr_file and os.path.isfile(_sr_file):
    try:
        with open(_sr_file) as _sf:
            _sr_doc = json.load(_sf)
        _ROSTER_NS_ROOTS = [e.get("path") or "" for e in _sr_doc.get("live", [])
                            if e.get("class") in ("memory-corpus", "rules-corpus", "spoke-corpus") and e.get("exists")]
        _ROSTER_RETIRED = [os.path.realpath(r.get("path")) for r in _sr_doc.get("retired", []) if r.get("path")]
    except Exception:
        pass

def _is_retired(path_s):
    rp = os.path.realpath(path_s)
    for r in _ROSTER_RETIRED:
        if rp == r or rp.startswith(r + "/"):
            return True
    return False
today = datetime.date.today().isoformat()
findings = []


def rec(kind, **kw):
    row = {"finding": kind, "detected_at": today}
    row.update(kw)
    findings.append(row)


# ---------- corpus index (structural-fresh, realpath-dedup) ----------
vault_real = os.path.realpath(vault_root)
all_paths = []
try:
    with open(walk_list, encoding="utf-8") as fh:
        for line in fh:
            p = line.rstrip("\n")
            if p.endswith(".md") and os.path.isfile(p):
                # retired-denylist surfaces never enter the conversion corpus
                if _ROSTER_RETIRED and _is_retired(p):
                    continue
                all_paths.append(p)
except OSError:
    pass

def rel_to_root(p):
    # Prefer the LOGICAL relpath (symlinked dirs inside the vault keep their
    # view-path); fall back through the realpath'd root for walkers that emit
    # resolved prefixes (e.g. macOS /var -> /private/var).
    for base in (vault_root, vault_real):
        r = os.path.relpath(p, base)
        if not r.startswith(".."):
            return r
    return os.path.relpath(os.path.realpath(p), vault_real)


canonical_rel_for_real = {}
rel_for_path = {}
for p in sorted(all_paths):
    r = os.path.realpath(p)
    rel = rel_to_root(p)
    rel_for_path[p] = rel
    if r not in canonical_rel_for_real:
        canonical_rel_for_real[r] = rel

relnoext_to_real = {}
for r, rel in canonical_rel_for_real.items():
    key = rel[:-3] if rel.lower().endswith(".md") else rel
    relnoext_to_real[key] = r
basename_index = collections.defaultdict(set)
suffix_index = collections.defaultdict(set)
for key, r in relnoext_to_real.items():
    parts = key.split("/")
    basename_index[parts[-1].lower()].add(r)
    for i in range(len(parts)):
        suffix_index["/".join(parts[i:]).lower()].add(r)

# ---------- memory namespace: enumerated roots, hard exclusion ----------
# Roots come from the surface roster (SSOT: memory-corpus + rules-corpus +
# spoke-corpus classes, loaded above the walk); MEMORY_NS_ROOTS env override
# wins; roster-unavailable floor keeps the layout-convention derive.
# Retired-denylist roots never contribute (a retired corpus is not a live
# exemption tier).
if mem_roots_raw != "__UNSET__":
    mem_roots = [x for x in mem_roots_raw.split(os.pathsep) if x]
elif _ROSTER_NS_ROOTS:
    mem_roots = [x for x in _ROSTER_NS_ROOTS if x]
else:
    mem_roots = [os.path.join(claude_home, "rules")]
    projects = os.path.join(claude_home, "projects")
    try:
        mem_roots += [os.path.join(projects, d, "memory") for d in os.listdir(projects)]
    except OSError:
        pass
mem_stems = set()
for root in mem_roots:
    if not os.path.isdir(root) or _is_retired(root):
        continue
    for dp, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if not d.startswith(".")]
        for fn in fns:
            if fn.endswith(".md"):
                mem_stems.add(fn[:-3].lower())

# ---------- resolution (registry-seeded; ambiguity NEVER guessed) ----------
def norm(t):
    t2 = t.strip()
    return t2[:-3] if t2.lower().endswith(".md") else t2


def resolve(target):
    """-> (realpath, how) | (None, 'memory-exempt') | (None, 'AMBIGUOUS:n') |
    (None, 'ZERO'). Suffix resolution mirrors Obsidian shortest-form."""
    t = norm(target)
    if not t:
        return None, "ZERO"
    if t.lower() in mem_stems and "/" not in t:
        return None, "memory-exempt"
    key = t.lower()
    if key in suffix_index:
        cands = suffix_index[key]
        if len(cands) == 1:
            return next(iter(cands)), "path"
        return None, "AMBIGUOUS:%d" % len(cands)
    b = key.split("/")[-1]
    cands = basename_index.get(b, set())
    if "/" not in t and len(cands) == 1:
        return next(iter(cands)), "basename"
    if cands and "/" not in t:
        return None, "AMBIGUOUS:%d" % len(cands)
    return None, "ZERO"


WIKILINK_RE = re.compile(r"\[\[([^\[\]]+)\]\]")
MDLINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")


def looks_like_code(raw):
    if "$" in raw or "\\" in raw:
        return True
    for op in (" == ", " != ", " && ", " || "):
        if op in raw:
            return True
    s = raw.strip()
    return s[:1] == "-" and len(s) > 1 and s[1] in "znfdexrswL"


def code_span_ranges(ln):
    ranges, start = [], None
    for i, ch in enumerate(ln):
        if ch == "`":
            if start is None:
                start = i
            else:
                ranges.append((start, i))
                start = None
    return ranges


def md_href(src_path, target_real, anchor):
    src_dir = os.path.dirname(rel_for_path.get(src_path) or
                              rel_to_root(src_path))
    tgt_rel = canonical_rel_for_real[target_real]
    href = os.path.relpath(tgt_rel, src_dir or ".")
    href = urlquote(href, safe="/")
    if anchor:
        href += "#" + anchor
    return href


def transform_text(text, src_path, reps_out, judgment_out):
    out_lines_l = []
    in_fence = False
    for ln in text.split("\n"):
        s = ln.strip()
        if s.startswith("```") or s.startswith("~~~"):
            in_fence = not in_fence
            out_lines_l.append(ln)
            continue
        if in_fence:
            out_lines_l.append(ln)
            continue
        spans = code_span_ranges(ln)

        def sub(m):
            if any(a < m.start() < b for a, b in spans):
                return m.group(0)
            raw = m.group(1)
            if looks_like_code(raw):
                return m.group(0)
            body, alias = (raw.split("|", 1) + [""])[:2] if "|" in raw else (raw, "")
            tgt, anchor = (body.split("#", 1) + [""])[:2] if "#" in body else (body, "")
            tgt_s = tgt.strip()
            real, how = resolve(tgt_s)
            if real is None:
                if how.startswith("AMBIGUOUS") or how == "ZERO":
                    judgment_out.append({"target": tgt_s, "reason": how,
                                         "file": rel_for_path.get(src_path, src_path)})
                # memory-exempt / ambiguous / zero: NEVER guessed — untouched
                return m.group(0)
            href = md_href(src_path, real, anchor.strip())
            visible = alias.strip() if alias.strip() else \
                (tgt_s + ("#" + anchor.strip() if anchor.strip() else ""))
            reps_out.append({"old": raw, "new_href": href, "visible": visible,
                             "real": real, "how": how})
            return "[%s](%s)" % (visible, href)

        out_lines_l.append(WIKILINK_RE.sub(sub, ln))
    return "\n".join(out_lines_l)


# ---------- derive the work list (structural-fresh) ----------
rows = []
judgment = []
for real, rel in sorted(canonical_rel_for_real.items(), key=lambda kv: kv[1]):
    try:
        text = open(real, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    if "[[" not in text:
        continue
    # find the LOGICAL path for this real file (first alias wins = canonical)
    src_path = None
    for p, rl in rel_for_path.items():
        if rl == rel:
            src_path = p
            break
    reps = []
    new_text = transform_text(text, src_path or real, reps, judgment)
    if reps:
        rows.append({"rel": rel, "real": real, "orig": text,
                     "new": new_text, "reps": reps})

# ---------- invariants (on the dry-run product; ALL hard-block apply) --------
def check_invariants(row):
    errs = []
    orig, new = row["orig"], row["new"]
    src_dir_rel = os.path.dirname(row["rel"])
    for r in row["reps"]:
        # invariant: target-exists
        if not os.path.isfile(r["real"]):
            errs.append("target-missing: %s" % r["real"])
        # I-RSE RESOLUTION-SET EQUALITY (the hard-blocking invariant this
        # operation uniquely allows): the NEW href must reach the SAME
        # physical file the wikilink resolved to — in BOTH frames. Logical:
        # the vault-view join an Obsidian reader navigates (lexical .. like a
        # renderer). Physical: the same href followed from the source file's
        # REAL directory (what a filesystem agent resolves). A source walked
        # through a dir-symlink can satisfy one frame and not the other —
        # that divergence blocks for human adjudication, never guessed.
        href = urlunquote(r["new_href"].split("#", 1)[0])
        tgt_l = os.path.normpath(os.path.join(vault_root, src_dir_rel, href))
        want = os.path.realpath(r["real"])
        if os.path.realpath(tgt_l) != want:
            errs.append("I-RSE resolution drift (logical): %s -> %s "
                        "(expected %s)" % (r["old"], tgt_l, r["real"]))
        else:
            phys_dir = os.path.dirname(os.path.realpath(row["real"]))
            tgt_p = os.path.realpath(os.path.join(phys_dir, href))
            if tgt_p != want:
                errs.append("I-RSE physical/logical divergence (dir-symlink "
                            "source): %s -> %s vs %s"
                            % (r["old"], tgt_p, r["real"]))
    # invariant: line-count identical
    if new.count("\n") != orig.count("\n"):
        errs.append("line-count changed")
    # invariant: idempotency — transforming the product produces zero further changes
    reps2, j2 = [], []
    transform_text(new, os.path.join(vault_root, row["rel"]), reps2, j2)
    if reps2:
        errs.append("not idempotent: %d further replacements" % len(reps2))
    # invariant: link accounting — wikilinks_out + converted == wikilinks_in, and
    # md links grew by exactly the converted count
    wl_in = len(WIKILINK_RE.findall(orig))
    wl_out = len(WIKILINK_RE.findall(new))
    if wl_out + len(row["reps"]) != wl_in:
        errs.append("wikilink accounting drift (%d out + %d conv != %d in)"
                    % (wl_out, len(row["reps"]), wl_in))
    # invariant: reverse-mapping — replacing each emitted md link with its source
    # wikilink restores the original bytes
    back = new
    for r in sorted(row["reps"], key=lambda r: -len(r["new_href"])):
        back = back.replace("[%s](%s)" % (r["visible"], r["new_href"]),
                            "[[" + r["old"] + "]]", 1)
    if back != orig:
        errs.append("reverse-mapping does not restore the original")
    return errs


all_errs = {}
for row in rows:
    errs = check_invariants(row)
    if errs:
        all_errs[row["rel"]] = errs

# ---------- apply-time refusals ----------
def in_fire_band():
    if not fire_times_raw.strip():
        return None
    now = datetime.datetime.now()
    mins = now.hour * 60 + now.minute
    for tok in fire_times_raw.split():
        try:
            h, m = tok.split(":")
            f = int(h) * 60 + int(m)
        except ValueError:
            continue
        if f - 8 <= mins <= f + 20:
            return tok
    return None


def obsidian_running():
    # process name env-parameterized so an isolated fixture can force BOTH
    # branches (point it at a running shell / at a name that cannot exist);
    # the production default stays the real editor
    name = os.environ.get("LGC_EDITOR_PROCESS", "Obsidian")
    try:
        out = subprocess.run(["pgrep", "-x", name],
                             capture_output=True, text=True)
        return out.returncode == 0
    except OSError:
        return False


def tree_dirty(root):
    try:
        out = subprocess.run(["git", "-C", root, "status", "--porcelain"],
                             capture_output=True, text=True)
    except OSError:
        return []
    if out.returncode != 0:
        return []  # not a git repo: nothing to compare against
    return [l for l in out.stdout.splitlines()
            if l.strip() and ".lgcnew" not in l and ".pre-lgc" not in l]


def approval_ok():
    if not os.path.exists(register):
        return False
    try:
        for ln in open(register, encoding="utf-8"):
            # the BLANK line's own hint text contains the token "CONFIRMED" —
            # the underscore run distinguishes blank-with-hint from filled
            if ln.startswith("APPROVAL:") and "CONFIRMED" in ln \
                    and "____" not in ln:
                return True
    except OSError:
        return False
    return False


# ---------- register + siblings (dry-run product) ----------
def write_register():
    if os.path.exists(register) and not force:
        try:
            for ln in open(register, encoding="utf-8"):
                if ln.startswith("APPROVAL:") and "CONFIRMED" in ln:
                    print("REFUSE: register approval line already filled; "
                          "--force to regenerate: %s" % register)
                    return False
        except OSError:
            pass
    lines = ["# link-grammar-convert register — %s" % today, "",
             "Seed: STRUCTURAL-FRESH (re-derived from the vault-view walk at "
             "emission time).",
             "Grammar: [[target]] -> [target](rel.md); alias and #anchor "
             "preserved; live prose only;",
             "memory namespace exempt; ambiguity routed below, never "
             "guessed.", "",
             "## Files (%d) / replacements (%d)" % (
                 len(rows), sum(len(r["reps"]) for r in rows)), "",
             "| File | Reps |", "|---|---|"]
    for r in rows:
        lines.append("| %s | %d |" % (r["rel"], len(r["reps"])))
    lines += ["", "## Invariants (dry-run product)", ""]
    if all_errs:
        for f, errs in sorted(all_errs.items()):
            for e in errs:
                lines.append("- FAIL %s: %s" % (f, e))
    else:
        lines.append("- ALL PASS (target-exists · reverse-mapping · "
                     "line-count · idempotency · link accounting · "
                     "resolution-set equality) on every file")
    lines += ["", "## Judgment register (NOT converted — adjudicate by hand)", ""]
    seen = set()
    for j in judgment:
        key = (j["target"], j["reason"])
        if key in seen:
            continue
        seen.add(key)
        lines.append("- `%s` — %s (first seen in %s)" %
                     (j["target"], j["reason"], j["file"]))
    if not seen:
        lines.append("- (empty)")
    lines += ["", "APPROVAL: ____________________  "
              "(fill `CONFIRMED <date>` to unlock --apply)", ""]
    os.makedirs(os.path.dirname(register), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(register),
                               prefix=".register.", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    os.replace(tmp, register)
    print("register written: %s" % register)
    return True


def write_siblings():
    n = 0
    for r in rows:
        with open(r["real"] + ".lgcnew", "w", encoding="utf-8") as fh:
            fh.write(r["new"])
        n += 1
    print("dry-run siblings written: %d .lgcnew files" % n)


def clean_siblings():
    n = 0
    for r in rows:
        p = r["real"] + ".lgcnew"
        if os.path.exists(p):
            os.remove(p)
            n += 1
    return n


def apply_all():
    # the five refusals + the per-file changed-on-disk re-check
    if not approval_ok():
        print("REFUSE: approval line not filled (CONFIRMED) in register.")
        return 2
    band = in_fire_band()
    if band:
        print("REFUSE: inside scheduled-pipeline fire band %s (-8/+20 min)." % band)
        return 2
    if obsidian_running():
        print("REFUSE: editor process '%s' is running."
              % os.environ.get("LGC_EDITOR_PROCESS", "Obsidian"))
        return 2
    # the approved register must describe THIS derivation: the fresh
    # structural seed is compared against the register's file/rep table, so
    # --apply can never execute a state the approval never reviewed
    reg_rows = set()
    try:
        for ln in open(register, encoding="utf-8"):
            m = re.match(r"^\| (.+) \| (\d+) \|$", ln.rstrip("\n"))
            if m and m.group(1) != "File":
                reg_rows.add((m.group(1), int(m.group(2))))
    except OSError:
        pass
    live_rows = set((r["rel"], len(r["reps"])) for r in rows)
    if reg_rows != live_rows:
        print("REFUSE: corpus moved since the approved register "
              "(%d approved rows vs %d live) — re-run dry-run and re-approve."
              % (len(reg_rows), len(live_rows)))
        return 2
    dirty = tree_dirty(vault_real)
    if dirty:
        print("REFUSE: target tree dirty beyond .lgcnew siblings:")
        for l in dirty[:10]:
            print("   ", l)
        return 2
    if all_errs:
        print("REFUSE: invariant failures present (incl. any I-RSE "
              "resolution drift).")
        return 2
    for r in rows:
        cur = open(r["real"], encoding="utf-8", errors="replace").read()
        if cur != r["orig"]:
            print("REFUSE: %s changed on disk since seed derivation — "
                  "re-run dry-run." % r["rel"])
            return 2
    # temp + os.replace with write-once pre-image sidecar (migration-0006 block)
    for r in rows:
        d = os.path.dirname(r["real"]) or "."
        sidecar = r["real"] + ".pre-lgc"
        if not os.path.exists(sidecar):
            sfd, stmp = tempfile.mkstemp(dir=d, prefix=".pre-lgc.", suffix=".tmp")
            try:
                with os.fdopen(sfd, "wb") as sfh:
                    sfh.write(r["orig"].encode("utf-8"))
                os.replace(stmp, sidecar)
            except Exception:
                if os.path.exists(stmp):
                    os.unlink(stmp)
                raise
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".lgc.", suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(r["new"])
        try:
            os.chmod(tmp, os.stat(r["real"]).st_mode)
        except OSError:
            pass
        os.replace(tmp, r["real"])
    n = clean_siblings()
    # per-batch git commit when the root is a repo
    committed = False
    try:
        probe = subprocess.run(["git", "-C", vault_real, "rev-parse",
                                "--is-inside-work-tree"],
                               capture_output=True, text=True)
        if probe.returncode == 0 and probe.stdout.strip() == "true":
            subprocess.run(["git", "-C", vault_real, "add", "-A"],
                           capture_output=True, text=True)
            cm = subprocess.run(
                ["git", "-C", vault_real, "commit", "-m",
                 "link-grammar-convert: %d files / %d replacements (%s)"
                 % (len(rows), sum(len(r["reps"]) for r in rows), today)],
                capture_output=True, text=True)
            committed = cm.returncode == 0
    except OSError:
        pass
    print("APPLIED: %d files, %d replacements; cleaned %d siblings; "
          "git commit: %s"
          % (len(rows), sum(len(r["reps"]) for r in rows), n,
             "yes" if committed else "no (not a repo or nothing staged)"))
    rec("link-grammar-applied", files=len(rows),
        replacements=sum(len(r["reps"]) for r in rows), committed=committed)
    return 0


# ---------- main ----------
rc = 0
if apply_mode:
    rc = apply_all()
else:
    print("dry-run: %d files, %d replacements, %d judgment rows, "
          "%d invariant-failing files (scope: vault view at %s; memory/rules/spoke corpora exempt)"
          % (len(rows), sum(len(r["reps"]) for r in rows),
             len({(j["target"], j["reason"]) for j in judgment}),
             len(all_errs), vault_root))
    rec("link-grammar-dry-run", files=len(rows),
        replacements=sum(len(r["reps"]) for r in rows),
        judgment_rows=len({(j["target"], j["reason"]) for j in judgment}),
        invariant_failures=len(all_errs))
    seen = set()
    for j in judgment:
        key = (j["target"], j["reason"])
        if key in seen:
            continue
        seen.add(key)
        rec("link-grammar-ambiguous", target=j["target"], reason=j["reason"],
            file=j["file"])
    if write_register():
        write_siblings()

with open(out_lines, "w", encoding="utf-8") as fh:
    for r in findings:
        fh.write(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n")
sys.exit(rc)
PYEOF
rc=$?

# Route findings through the shared emitter (FINDINGS_OUTPUT-or-stdout).
while IFS= read -r _line; do
  [ -n "$_line" ] && emit_event "$_line"
done < "$OUT_LINES"
rm -f "$OUT_LINES"

exit $rc
