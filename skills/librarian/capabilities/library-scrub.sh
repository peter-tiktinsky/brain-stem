#!/bin/bash
# library-scrub — Deterministic dual-output promotion scrub: workshop research ->
# a universal _library/<topic>/<article>.md AND a plan-SoT _research/ record,
# with bidirectional cross-reference stamps, in one propose/--apply.
#
# plan-manifest-schema degrade-contract: REFERENCE-ONLY — plan-manifest-schema is only a header/env-var path reference (MANIFEST_SCHEMA_PATH); no Draft202012Validator is constructed, so there is no schema-gate degrade path.
# This capability OWNS the full promotion write-orchestration:
#   PROMO-1  identify finalized candidates from workshop content + manifest
#            research_artifacts[] entries with status: finalized.
#   RAW COPY  copy the immutable original into _library/<topic>/_raw/
#            BEFORE scrubbing (read-not-mutate the source) so the article's
#            REQUIRED `sources:` pointers resolve.
#   PROMO-2  deterministic scrub: extract universally-applicable content and
#            strip plan/project-specific detail (task IDs, plan slugs,
#            engagement names, decision dates) into a candidate article;
#            synthesize the `routing:` activation-condition one-liner.
#   PROMO-3  plan-SoT persist: the full plan-specific version lands in
#            <plan>/_research/ AND is declared in the manifest research_artifacts[].
#   PROMO-4  bidirectional stamp within one --apply: the article gains
#            originating_plan: AND the manifest entry gains library_refs:
#            [<topic>/<article>]. Two SEQUENTIAL individually-atomic
#            temp-file + os.replace writes, NOT a transaction — the inter-write
#            crash window is the accepted contract; the library-index re-derive
#            is the one-sided-edge detector (this capability never builds a
#            transaction layer).
#   PROMO-6  archive: the workshop originals MOVE to workshop/_archive/. The
#            _library/log.md append half is owned by a separate capability and
#            is NOT written here.
#
# NOVEL BET (advisory-first): scrub quality is unproven. The
# propose phase emits NDJSON candidates and writes NOTHING; the propose diff is
# the human backstop where over-/under-strip is visible.
# --apply is the ONLY writing path. This capability never blocks a prompt and
# never escalates to a harder posture on its own — escalation needs
# observed-failure data.
#
# Block-and-log, never write-and-hope: an empty/malformed scrub
# output is never written; it emits a `scrub-blocked` finding and is skipped.
#
# NOTE (transcription): the binding SoT labels this a dual-output scrub;
# that is the same-ID as the distinct frictionless-capture workshop contract in
# the surface-architecture doc. Same-ID drift, not an error.
#
# Flow-maintained artifacts (workshop/_archive/, _library/<topic>/_raw/) carry
# maintainer=flow(F-CAP|F-PROMO) with enforcement-owner=librarian — this
# capability is that enforcement owner.
#
# Output Contract (per CLAUDE.md skill-creation rule):
#   Files written (ONLY in --apply mode; propose mode writes nothing):
#     1. $LIBRARY/<topic>/_raw/<source>            — immutable provenance copy
#                                                    (written once; never edited)
#     2. $LIBRARY/<topic>/<article>.md             — scrubbed universal article
#                                                    (atomic temp+rename) carrying
#                                                    valid type:reference frontmatter
#     3. <plan>/_research/<article>.md             — full plan-SoT record
#     4. <plan>/manifest.json                      — research_artifacts[] entry
#                                                    gains library_refs[] (atomic)
#     5. $LIBRARY/<topic>/<article>.md frontmatter — gains originating_plan:
#                                                    (the PROMO-4 second atomic write)
#     6. workshop original -> $WORKSHOP/_archive/   — PROMO-6 move
#   Schema gated by: schemas/plan-manifest-schema.json (the research_artifacts[]
#     item shape) — the manifest entry is validated as an object BEFORE the
#     library_refs[] stamp write (jsonschema when importable; structural
#     fallback otherwise). The article frontmatter is validated against the
#     registered `reference` type's required-field set
#     (governance/frontmatter-rules.json#types.reference) BEFORE write.
#   Pre-write validation steps:
#     - the scrubbed article body must be non-empty after strip (else block).
#     - the article frontmatter must carry every reference-type required field
#       (read from the registered `reference` type's required[] — the EFFECTIVE
#       registry, which includes the universal typed cohort; see
#       governance/frontmatter-rules.json#types.reference).
#     - the manifest research_artifacts[] entry must validate against the schema.
#     - the workshop home + library home must resolve (workshop-absent ->
#       block-and-log, never crash).
#   Failure mode: BLOCK-AND-LOG. A candidate that fails validation emits a
#     `scrub-blocked` finding and is skipped; no partial write. Never
#     write-and-hope.
#
# NDJSON schema (one line per candidate / event):
#   propose:  { "finding":"library-scrub", "file":"<workshop-source>",
#               "category":"promotion-candidate", "topic":"<topic>",
#               "article":"<article>.md", "plan":"<plan-slug>",
#               "routing":"<activation one-liner>", "raw_sources":"<n>",
#               "scrubbed_terms":"<n>", "valid":true }
#   blocked:  { "finding":"library-scrub", "file":"<workshop-source>",
#               "category":"scrub-blocked", "reason":"...", "valid":false }
#   applied:  { "finding":"library-scrub", "file":"<workshop-source>",
#               "category":"promoted", "topic":"<topic>",
#               "article":"<topic>/<article>.md", "written":"<article path>",
#               "plan_sot":"<_research path>", "archived":"<archive path>" }
#
# Tier: judgment. requires_confirmation: true (propose-then-confirm default;
# --apply is the confirm gate). Cron block: skip-non-interactive.
#
# CLI:
#   library-scrub.sh                      # propose (NDJSON candidates; NO writes)
#   library-scrub.sh --apply              # confirm: write + stamp + archive
#   library-scrub.sh --topic <dir>        # one workshop topic dir (else sweep all)
#   library-scrub.sh --dry-run            # summary counts only; no findings/writes
#   library-scrub.sh --help               # usage
#
# Env overrides:
#   WORKSHOP_DIR   workshop home (default: $CLAUDE_STATE_ROOT/workshop via
#                  paths.sh — NEVER a hardcoded literal).
#   LIBRARY_DIR    library home (default: $PLANS_DIR/_library).
#   PLANS_DIR      plan tree root (test isolation; resolved via paths.sh).
#   MANIFEST_SCHEMA_PATH   (default: $CLAUDE_HOME/schemas/plan-manifest-schema.json
#                          -> $FOUNDATION_REPO/schemas/plan-manifest-schema.json)
#   FRONTMATTER_RULES_PATH (default: $CLAUDE_HOME/governance/frontmatter-rules.json
#                          -> repo governance/frontmatter-rules.json)
#   FINDINGS_OUTPUT        NDJSON sink (default: stdout)
#   FOUNDATION_TEST_MODE   Bypass the non-interactive guard (test/CI runners).
#   CLAUDECODE             Set by an attended Claude Code session; bypasses the
#                          --apply non-interactive guard (CC is the primary
#                          library-curation surface). A bare cron sweep still blocks.
#
# Bash 3.2 clean per R-23. Argv-based Python heredocs per R-24.

set -euo pipefail

CLAUDE_HOME_RES="${CLAUDE_HOME:-$HOME/.claude}"
_REPO_ROOT="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)"
_REPO_LIB="$_REPO_ROOT/hooks/lib"

if [[ -z "${CLAUDE_STATE_ROOT:-}" || -z "${PLANS_DIR:-}" ]]; then
  # shellcheck source=/dev/null
  { [ -r "$CLAUDE_HOME_RES/hooks/lib/paths.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/paths.sh"; } \
    || { [ -r "$_REPO_LIB/paths.sh" ] && source "$_REPO_LIB/paths.sh"; } || true
fi
# shellcheck source=/dev/null
{ [ -r "$CLAUDE_HOME_RES/hooks/lib/findings.sh" ] && source "$CLAUDE_HOME_RES/hooks/lib/findings.sh"; } \
  || { [ -r "$_REPO_LIB/findings.sh" ] && source "$_REPO_LIB/findings.sh"; } || true

APPLY="false"
TOPIC=""
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY="true"; shift ;;
    --topic) TOPIC="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) sed -n '2,111p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "library-scrub: unknown flag '$1'" >&2; exit 2 ;;
  esac
done

# Judgment-tier non-interactive guard (mirrors memory-globalize.sh /
# memory-hygiene.sh). The propose phase is read-only and harmless, but --apply
# writes durable content; the guard keeps an unattended cron sweep from
# auto-promoting. CLAUDECODE (an attended Claude Code session — the primary
# library-curation operation surface) bypasses the guard so --apply reaches its
# write path there; a bare non-TTY cron sweep (CLAUDECODE unset) still blocks.
if [[ "$APPLY" == "true" ]] && [[ -z "${FOUNDATION_TEST_MODE:-}" ]] \
   && [[ -z "${CLAUDECODE:-}" ]] && [[ -z "${TTY:-}" ]] && ! [ -t 0 ]; then
  echo "library-scrub: --apply skipped (non-interactive)" >&2
  exit 0
fi

# --- Resolve the three surface homes -----------------------------------------
# Workshop home: $CLAUDE_STATE_ROOT/workshop/ — NEVER hardcoded.
STATE_ROOT_RES="${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}"
WORKSHOP_RES="${WORKSHOP_DIR:-$STATE_ROOT_RES/workshop}"
PLANS_RES="${PLANS_DIR:-$HOME/.claude-plans}"
LIBRARY_RES="${LIBRARY_DIR:-$PLANS_RES/_library}"

# workshop-absent -> block-and-log, never crash (the workshop scaffold is a
# separate install unit; this capability degrades gracefully when it is absent).
if [[ ! -d "$WORKSHOP_RES" ]]; then
  if command -v emit_finding >/dev/null 2>&1; then
    emit_finding "library-scrub" "$WORKSHOP_RES" \
      "category" "scrub-blocked" \
      "reason" "workshop home absent (not yet scaffolded); nothing to promote" \
      "valid" "false"
  else
    echo "library-scrub: workshop home absent ($WORKSHOP_RES); nothing to promote" >&2
  fi
  exit 0
fi

# Resolve schemas (live install -> foundation repo).
MANIFEST_SCHEMA="${MANIFEST_SCHEMA_PATH:-}"
if [[ -z "$MANIFEST_SCHEMA" ]]; then
  for c in "$CLAUDE_HOME_RES/schemas/plan-manifest-schema.json" \
           "$_REPO_ROOT/schemas/plan-manifest-schema.json"; do
    if [[ -f "$c" ]]; then MANIFEST_SCHEMA="$c"; break; fi
  done
fi
FRONTMATTER_RULES="${FRONTMATTER_RULES_PATH:-}"
if [[ -z "$FRONTMATTER_RULES" ]]; then
  for c in "$CLAUDE_HOME_RES/governance/frontmatter-rules.json" \
           "$_REPO_ROOT/governance/frontmatter-rules.json"; do
    if [[ -f "$c" ]]; then FRONTMATTER_RULES="$c"; break; fi
  done
fi

# Canonical governance read: the reference-type required-field set
# used for pre-write validation is the EFFECTIVE registry, so route the read
# through the R-52 union-load merger (hooks/lib/foundation-overlay-load.sh) —
# never consume foundation-master / frontmatter-rules.json RAW. Resolve the
# SHIPPED bundle, materialize the merged union once (full-union: same top-level
# shape as foundation-master), and pass it to the python3 body, which reads
# .frontmatter.types.reference.required from the merged view so an adopter's
# overlay-master.json amendments to the reference contract are honored. The loose
# pillar FRONTMATTER_RULES (.types.reference.required shape) stays as the
# dev-repo/no-bundle/explicit-path fallback (loud-safe, never broken).
FM_BUNDLE=""
for c in "$CLAUDE_HOME_RES/governance/foundation-master.json" \
         "$_REPO_ROOT/governance/foundation-master.json"; do
  if [[ -f "$c" ]]; then FM_BUNDLE="$c"; break; fi
done
_OVL="${FOUNDATION_OVERLAY_LOAD:-$CLAUDE_HOME_RES/hooks/lib/foundation-overlay-load.sh}"
[[ -x "$_OVL" ]] || _OVL="$_REPO_ROOT/hooks/lib/foundation-overlay-load.sh"
if [[ -x "$_OVL" && -n "$FM_BUNDLE" && -f "$FM_BUNDLE" ]]; then
  _UNION="$(mktemp 2>/dev/null || true)"
  if [[ -n "$_UNION" ]] && bash "$_OVL" --foundation-path "$FM_BUNDLE" \
        --overlay-path "$(dirname "$FM_BUNDLE")/overlay-master.json" --force-override > "$_UNION" 2>/dev/null \
        && [[ -s "$_UNION" ]]; then
    FM_BUNDLE="$_UNION"; trap 'rm -f "$_UNION"' EXIT
  elif [[ -n "$_UNION" ]]; then rm -f "$_UNION"; fi
fi

# PROMO-6 log half: resolve the library-log-append hook — the SOLE
# appender of the _library/log.md change-log entries (composite). The
# scrub CALLS the appender at PROMO-6; the appender OWNS the write, frontmatter
# seeding, R-33 tolerance, and rotation-threshold detection. NEVER append inline
# here (that would make the scrub a second appender, breaking the disjoint-surface split).
LOG_APPENDER="${LIBRARY_LOG_APPENDER:-}"
if [[ -z "$LOG_APPENDER" ]]; then
  for c in "$CLAUDE_HOME_RES/hooks/library-log-append.sh" \
           "$_REPO_ROOT/hooks/library-log-append.sh"; do
    if [[ -f "$c" ]]; then LOG_APPENDER="$c"; break; fi
  done
fi

# Resolve the SHARED description-derivation helper (hooks/lib/derive-description.sh):
# a promoted article's universal-cohort `description:` is derived through the SAME
# one-derivation-contract helper the forward-governance auto-stamp (post-write-verify.sh)
# and the frontmatter-enforce backfill use, so the three cohort-writing paths agree.
# CLAUDE_HOME-first, repo-lib fallback (dev authoring). Absent -> the python body
# degrades to the concept-H1 fallback (never empty).
DERIVE_DESC="${DERIVE_DESCRIPTION_HELPER:-}"
if [[ -z "$DERIVE_DESC" ]]; then
  for c in "$CLAUDE_HOME_RES/hooks/lib/derive-description.sh" \
           "$_REPO_LIB/derive-description.sh"; do
    if [[ -f "$c" ]]; then DERIVE_DESC="$c"; break; fi
  done
fi

python3 - "$WORKSHOP_RES" "$LIBRARY_RES" "$PLANS_RES" "$MANIFEST_SCHEMA" \
          "$FRONTMATTER_RULES" "$APPLY" "$DRY_RUN" "$TOPIC" "$LOG_APPENDER" "$FM_BUNDLE" \
          "$DERIVE_DESC" <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import date, datetime, timezone

workshop_dir = sys.argv[1]
library_dir = sys.argv[2]
plans_dir = sys.argv[3]
manifest_schema_path = sys.argv[4]
frontmatter_rules_path = sys.argv[5]
apply_mode = sys.argv[6] == "true"
dry_run = sys.argv[7] == "true"
topic_filter = sys.argv[8]
log_appender = sys.argv[9] if len(sys.argv) > 9 else ""
fm_bundle_path = sys.argv[10] if len(sys.argv) > 10 else ""
derive_desc_helper = sys.argv[11] if len(sys.argv) > 11 else ""


def append_log_event(action, rel_path, note):
    """PROMO-6 log half: invoke the library-log-append hook (the
    SOLE appender) for one event. The hook OWNS the write/frontmatter/
    rotation; the scrub only CALLS it. Best-effort: a missing/failed appender
    never aborts an otherwise-successful promotion (the log is an audit trail,
    not a promotion precondition)."""
    if not log_appender or not os.path.isfile(log_appender):
        return
    env = dict(os.environ)
    env["LIBRARY_DIR"] = library_dir
    try:
        subprocess.run(["bash", log_appender, action, rel_path, note],
                       env=env, check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass

today = date.today().isoformat()
now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---- universal typed cohort (lockstep w/ types.reference.required[]) ----------
# The reference type's required[] gained description/created/id/schema_version.
# A promoted article is a forward-CREATION path, so this capability STAMPS the
# cohort at construction — the article is born compliant AND passes the REF_REQUIRED
# pre-write validation. The three cohort-writing paths agree by construction:
#   - created = TODAY (forward creation; NOT the T-8 git-backfill "never today"
#     rule, which is for pre-existing files).
#   - id = a deterministic readable slug from <topic>/<article> — immutable by
#     construction (re-promotion regenerates the SAME slug; parity with the
#     forward-governance sed-slug + the backfill slugify).
#   - schema_version = the cohort constant, matching the value the forward-governance
#     auto-stamp writes (hooks/post-write-verify.sh add_if_absent schema_version).
#   - description = derived through the SHARED helper (hooks/lib/derive-description.sh).
COHORT_SCHEMA_VERSION = 1


def cohort_slug(text):
    """Deterministic readable slug (parity with the backfill slugify + the
    forward-governance sed slug: lowercase, non-alnum runs -> single hyphen)."""
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def derive_description(body_text, h1):
    """One-line cohort description via the SHARED helper — one derivation contract
    with forward-governance (post-write-verify.sh) + the backfill (frontmatter-
    enforce.sh). The helper reads a FILE, so compose the article's on-disk body
    (H1 + scrubbed body) into a temp file and call it the way frontmatter-enforce
    does. Falls back to the concept H1 (never empty) when the helper is unavailable
    (sandbox / missing lib)."""
    fallback = (h1 or "").strip()
    if not derive_desc_helper or not os.path.isfile(derive_desc_helper):
        return fallback
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(suffix=".md")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write("# %s\n\n%s\n" % (h1, body_text))
        r = subprocess.run(["bash", derive_desc_helper, tmp],
                           capture_output=True, text=True, timeout=25)
        d = ((r.stdout or "").strip().split("\n") or [""])[0].strip()
        return d or fallback
    except Exception:
        return fallback
    finally:
        if tmp and os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass


def emit(payload):
    out = os.environ.get("FINDINGS_OUTPUT", "")
    line = json.dumps(payload, ensure_ascii=False, separators=(", ", ": "))
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    else:
        sys.stdout.write(line + "\n")


# ---- reference-type required fields (the EFFECTIVE type registry) ------------
# Defensive default mirrors the registered C-FM-ART required set so the
# capability stays correct even if the rules source is unreadable in a sandbox.
# canonical read: the merged union (foundation-master + overlay) is
# materialized by the merger in the shell wrapper and handed in as fm_bundle_path
# (.frontmatter.types.reference shape). Read it FIRST so an adopter's overlay
# amendments to the reference contract are honored; fall back to the loose pillar
# (.types.reference shape) when the bundle/merger is unavailable (dev-repo
# authoring or an explicit FRONTMATTER_RULES_PATH).
REF_REQUIRED = ["type", "tags", "updated", "routing", "sources", "originating_plan",
                "description", "created", "id", "schema_version"]
_ref = None
if fm_bundle_path and os.path.isfile(fm_bundle_path):
    try:
        with open(fm_bundle_path, encoding="utf-8") as fh:
            _fb = json.load(fh)
        _ref = (_fb.get("frontmatter", {}) or {}).get("types", {}).get("reference")
    except (OSError, json.JSONDecodeError):
        _ref = None
if not (_ref and _ref.get("required")) and frontmatter_rules_path \
        and os.path.isfile(frontmatter_rules_path):
    try:
        with open(frontmatter_rules_path, encoding="utf-8") as fh:
            _fr = json.load(fh)
        _ref = _fr.get("types", {}).get("reference")
    except (OSError, json.JSONDecodeError):
        _ref = None
if _ref and _ref.get("required"):
    REF_REQUIRED = list(_ref["required"])


# ---- optional jsonschema gate for the manifest research_artifacts[] item ----
_ra_item_schema = None
if manifest_schema_path and os.path.isfile(manifest_schema_path):
    try:
        with open(manifest_schema_path, encoding="utf-8") as fh:
            _ms = json.load(fh)
        _ra = _ms.get("properties", {}).get("research_artifacts", {})
        _ra_item_schema = _ra.get("items")
    except (OSError, json.JSONDecodeError):
        _ra_item_schema = None

_ra_validator = None
if _ra_item_schema is not None:
    try:
        import jsonschema  # type: ignore
        _ra_validator = jsonschema.Draft7Validator(_ra_item_schema)
    except ImportError:
        _ra_validator = None


def validate_ra_item(item):
    """Validate one research_artifacts[] entry. jsonschema when available;
    structural fallback to the required-key set otherwise."""
    if _ra_validator is not None:
        errs = sorted(_ra_validator.iter_errors(item), key=lambda e: list(e.path))
        if errs:
            return False, "plan-manifest-schema: %s" % errs[0].message
        return True, ""
    for k in ("id", "title", "status", "path"):
        if not item.get(k):
            return False, "structural: research_artifacts item missing '%s'" % k
    if item.get("status") not in ("active", "finalized", "deferred"):
        return False, "structural: status not in active|finalized|deferred"
    return True, ""


# ---- plan-id / topic parsing -------------------------------------------------
# Workshop routing is by directory naming convention ONLY:
#   <topic>/            -> general (no plan-id; library-only output)
#   <topic>-<plan-id>/  -> plan-specific (the -<plan-id> suffix routes the
#                          plan-SoT output to <plan-id>/_research/).
# A plan-id is a plan-tree dir that exists under PLANS_DIR.
def split_topic_plan(dirname):
    """Return (topic, plan_slug-or-None). The plan-id is the longest trailing
    hyphen-delimited suffix that names an existing plan dir under plans_dir."""
    parts = dirname.split("-")
    for cut in range(1, len(parts)):
        candidate = "-".join(parts[cut:])
        if candidate and os.path.isdir(os.path.join(plans_dir, candidate)):
            topic = "-".join(parts[:cut])
            if topic:
                return topic, candidate
    return dirname, None


# ---- deterministic scrub -----------------------------------------------------
# Strip plan/project-specific detail: task IDs, plan slugs,
# engagement names, decision dates. Deterministic, line-oriented. Over-/under-
# strip is VISIBLE in the propose diff before any write — the
# human backstop for the novel bet.
TASK_ID_RE = re.compile(r'\b[TM]-\d+\b|\bSP-?\d+\b|\bADR-\d+\b|\bRA-\d+\b')
PLAN_SLUG_RE = re.compile(r'\bplan\s*\d+\b', re.IGNORECASE)
DATE_RE = re.compile(r'\b\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?Z?)?\b')
# A leading in-document section index / auto-TOC is FORBIDDEN in article bodies
# (body shape) — drop a generated "## Contents" / "## Table of Contents"
# block if the captured source carries one.
TOC_HEADING_RE = re.compile(r'^\s*#{1,6}\s+(contents|table of contents|toc)\s*$',
                            re.IGNORECASE)


def scrub_body(text, plan_slug, engagement_terms):
    """Return (scrubbed_body, n_terms_removed). Deterministic strip."""
    removed = 0
    out_lines = []
    in_toc = False
    for line in text.split("\n"):
        if TOC_HEADING_RE.match(line):
            in_toc = True
            removed += 1
            continue
        if in_toc:
            # a TOC block runs until the next non-list, non-blank heading
            if line.strip() == "" or line.lstrip().startswith(("-", "*", "1.")):
                continue
            in_toc = False
        orig = line
        line, n1 = TASK_ID_RE.subn("", line)
        line, n2 = PLAN_SLUG_RE.subn("", line)
        line, n3 = DATE_RE.subn("", line)
        n4 = 0
        if plan_slug:
            line, n4 = re.subn(re.escape(plan_slug), "", line)
        n5 = 0
        for term in engagement_terms:
            if term:
                line, c = re.subn(re.escape(term), "", line)
                n5 += c
        removed += n1 + n2 + n3 + n4 + n5
        # collapse the whitespace the strip left behind
        if line != orig:
            line = re.sub(r'[ \t]{2,}', " ", line).rstrip()
        out_lines.append(line)
    body = "\n".join(out_lines).strip()
    return body, removed


def synthesize_routing(topic, article_name, body):
    """Synthesize the routing: the per-article activation-condition one-liner.
    Deterministic: 'Read when working on <article-concept> in the <topic>
    domain.' — derived from the topic + article concept name, not a build ref.
    library-index's Description column consumes this as its FIRST derivation source."""
    concept = article_name.replace("-", " ").replace("_", " ").strip()
    topic_h = topic.replace("-", " ").replace("_", " ").strip()
    routing = "Read when working on %s in the %s domain." % (concept, topic_h)
    return routing[:200]


def derive_h1(body, article_name):
    """The article H1 is the concept name (body scaffold)."""
    return article_name.replace("-", " ").replace("_", " ").strip().title()


def build_article(topic, article_name, scrubbed_body, routing, raw_sources,
                  tags, plan_slug, description, created, article_id,
                  schema_version):
    """Compose the article markdown: reference frontmatter -> H1 = concept ->
    synthesized body -> [[name]] bare sibling wikilinks at the foot.
    NO leading in-document section index, NO auto-TOC."""
    h1 = derive_h1(scrubbed_body, article_name)
    fm = []
    fm.append("---")
    fm.append("type: reference")
    fm.append("tags: [%s]" % ", ".join(tags))
    fm.append("updated: %s" % today)
    fm.append("routing: %s" % json.dumps(routing, ensure_ascii=False))
    # sources: pointers to the _raw/ originals this article was synthesized from.
    fm.append("sources:")
    for s in raw_sources:
        fm.append("  - %s" % json.dumps("_raw/" + s, ensure_ascii=False))
    # originating_plan is REQUIRED unconditionally (C-FM-ART). build_article is
    # only ever reached with a resolved promoting plan; the no-plan path is
    # block-and-logged before construction.
    fm.append("originating_plan: %s" % plan_slug)
    # universal typed cohort (required[] gained these four). json.dumps on the
    # description mirrors the routing line's valid-YAML double-quoting idiom.
    fm.append("description: %s" % json.dumps(description, ensure_ascii=False))
    fm.append("created: %s" % created)
    fm.append("id: %s" % article_id)
    fm.append("schema_version: %s" % schema_version)
    fm.append("---")
    # C-FM-ART body scaffold: a SINGLE H1 = the concept name. If the captured
    # source carried its own leading H1, drop it so the synthesized concept H1
    # is the sole top-level heading (no duplicate-H1, no leading section index).
    body_lines = scrubbed_body.split("\n")
    while body_lines and body_lines[0].strip() == "":
        body_lines.pop(0)
    if body_lines and re.match(r'^\s*#\s+', body_lines[0]):
        body_lines.pop(0)
        while body_lines and body_lines[0].strip() == "":
            body_lines.pop(0)
    scrubbed_body = "\n".join(body_lines)
    body = "\n".join(fm) + "\n\n# %s\n\n" % h1 + scrubbed_body + "\n"
    return body, h1


def article_frontmatter_dict(topic, article_name, routing, raw_sources, tags,
                             plan_slug, description, created, article_id,
                             schema_version):
    """The frontmatter as a dict for pre-write required-field validation."""
    fm = {
        "type": "reference",
        "tags": tags,
        "updated": today,
        "routing": routing,
        "sources": ["_raw/" + s for s in raw_sources],
    }
    # originating_plan is REQUIRED unconditionally (C-FM-ART); a missing/empty
    # plan_slug surfaces in the required-field check and block-and-logs.
    fm["originating_plan"] = plan_slug
    # universal typed cohort — stamped so the REF_REQUIRED pre-write check (which
    # now reads these four from the effective registry) passes AND the promoted
    # article is born cohort-compliant.
    fm["description"] = description
    fm["created"] = created
    fm["id"] = article_id
    fm["schema_version"] = schema_version
    return fm


def atomic_write(target, content):
    d = os.path.dirname(target)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(content)
        os.replace(tmp, target)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def stamp_manifest_library_refs(manifest_path, ra_id, ref):
    """PROMO-4 second-class write: the manifest research_artifacts[] entry with
    id==ra_id gains library_refs += [ref]. Individually atomic temp+replace.
    Returns True on stamp, False if the entry/field could not be located."""
    try:
        with open(manifest_path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return False
    ra = data.get("research_artifacts")
    if not isinstance(ra, list):
        return False
    stamped = False
    for entry in ra:
        if isinstance(entry, dict) and entry.get("id") == ra_id:
            refs = entry.get("library_refs")
            if not isinstance(refs, list):
                refs = []
            if ref not in refs:
                refs.append(ref)
            entry["library_refs"] = refs
            stamped = True
            break
    if not stamped:
        return False
    content = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    atomic_write(manifest_path, content)
    return True


def read_finalized_ra(manifest_path):
    """PROMO-1 manifest half: research_artifacts[] entries with status
    finalized, keyed by basename of their path for matching to workshop files."""
    out = {}
    try:
        with open(manifest_path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return out
    for entry in data.get("research_artifacts", []) or []:
        if isinstance(entry, dict) and entry.get("status") == "finalized":
            p = entry.get("path", "")
            if p:
                out[os.path.basename(p)] = entry
    return out


def first_nonempty_line(text):
    for line in text.split("\n"):
        if line.strip():
            return line.strip()
    return ""


counts = {
    "topics": 0, "candidates": 0, "promoted": 0, "blocked": 0,
    "skipped_empty": 0, "skipped_archive": 0,
}

if not os.path.isdir(workshop_dir):
    # already guarded in the shell wrapper, but stay defensive.
    print("library-scrub: workshop dir absent", file=sys.stderr)
    sys.exit(0)

topic_dirs = sorted(
    d for d in os.listdir(workshop_dir)
    if os.path.isdir(os.path.join(workshop_dir, d)) and d != "_archive"
)
if topic_filter:
    topic_dirs = [d for d in topic_dirs if d == topic_filter]

archive_root = os.path.join(workshop_dir, "_archive")

for tdir in topic_dirs:
    counts["topics"] += 1
    tpath = os.path.join(workshop_dir, tdir)
    topic, plan_slug = split_topic_plan(tdir)

    manifest_path = None
    finalized_ra = {}
    if plan_slug:
        manifest_path = os.path.join(plans_dir, plan_slug, "manifest.json")
        if os.path.isfile(manifest_path):
            finalized_ra = read_finalized_ra(manifest_path)

    # engagement-name strip terms: derive deterministically from the plan slug's
    # non-numeric segments (so plan-specific monikers strip out of the article).
    engagement_terms = []
    if plan_slug:
        for seg in plan_slug.split("-"):
            if seg and not seg.isdigit() and len(seg) > 3:
                engagement_terms.append(seg)

    # Each loose .md in the topic dir is a promotion candidate (loose
    # markdown). _raw is provenance, not a candidate source on its own.
    src_files = sorted(
        f for f in os.listdir(tpath)
        if f.endswith(".md") and os.path.isfile(os.path.join(tpath, f))
    )

    for src in src_files:
        src_path = os.path.join(tpath, src)
        article_name = src[:-3]  # drop .md

        # PROMO-1: a plan-specific candidate must be declared finalized in the
        # manifest research_artifacts[] (declaration is the selectivity gate).
        # A topic with no resolvable promoting plan is block-and-logged below
        # (C-FM-ART requires originating_plan unconditionally) — it never
        # promotes on workshop presence alone.
        ra_entry = None
        if plan_slug:
            ra_entry = finalized_ra.get(src)
            if ra_entry is None:
                # not a declared-finalized artifact: skip silently in propose
                # (it stays in the workshop until declared).
                continue

        try:
            with open(src_path, encoding="utf-8") as fh:
                raw_text = fh.read()
        except OSError:
            continue

        # RAW COPY: the immutable original is the _raw/ provenance source.
        raw_sources = [src]

        scrubbed, n_removed = scrub_body(raw_text, plan_slug, engagement_terms)

        # empty-article output -> block-and-log, never write.
        if not scrubbed.strip():
            counts["blocked"] += 1
            counts["skipped_empty"] += 1
            if not dry_run:
                emit({
                    "finding": "library-scrub", "file": src,
                    "category": "scrub-blocked",
                    "reason": "scrub produced an empty article body (over-strip "
                              "or empty source); blocked-and-logged",
                    "valid": False,
                })
            continue

        # C-OUT: no promoting plan resolvable -> block-and-log,
        # never write a plan-less article. C-FM-ART requires originating_plan
        # unconditionally; the SoT defines no plan-less write. A topic whose
        # directory carries no -<plan-id> suffix (or whose suffix names no plan
        # dir under PLANS_DIR) has no resolvable promoting plan, so the article
        # is blocked rather than written without its required back-pointer.
        if not plan_slug:
            counts["blocked"] += 1
            if not dry_run:
                emit({
                    "finding": "library-scrub", "file": src,
                    "category": "scrub-blocked",
                    "reason": "no promoting plan resolvable for topic '%s' "
                              "(C-FM-ART requires originating_plan; the F-PROMO "
                              "chain is plan-bound by construction)" % topic,
                    "valid": False,
                })
            continue

        # default tags: deterministic, R-47-compliant, topic-scoped.
        tags = ["#%s/%s" % (topic, "library")]
        routing = synthesize_routing(topic, article_name, scrubbed)

        # universal typed cohort (forward-CREATION path): stamp created=today, an
        # immutable readable id slug from <topic>/<article>, the cohort schema_version,
        # and a description via the SHARED helper. Computed BEFORE validation so the
        # REF_REQUIRED check (which now includes these four) passes in BOTH propose
        # and --apply, and the promoted article is born compliant.
        cohort_h1 = derive_h1(scrubbed, article_name)
        cohort_description = derive_description(scrubbed, cohort_h1)
        cohort_created = today
        cohort_id = cohort_slug("%s/%s" % (topic, article_name)) or "note"

        # pre-write validation: article frontmatter required-field set.
        # C-FM-ART: originating_plan is REQUIRED unconditionally — the
        # F-PROMO chain is plan-bound by construction (PROMO-3 persists to
        # <plan>/_research/, PROMO-4 stamps that plan's manifest), so EVERY
        # promotion has a promoting plan whose slug is the value. There is no
        # plan-less write. A topic that cannot resolve a promoting plan
        # block-and-logs below (C-OUT), never writes the article
        # without the field.
        art_fm = article_frontmatter_dict(
            topic, article_name, routing, raw_sources, tags, plan_slug,
            cohort_description, cohort_created, cohort_id, COHORT_SCHEMA_VERSION)
        missing = [k for k in REF_REQUIRED if k not in art_fm or art_fm[k] in (None, "", [])]
        if missing:
            counts["blocked"] += 1
            if not dry_run:
                emit({
                    "finding": "library-scrub", "file": src,
                    "category": "scrub-blocked",
                    "reason": "article frontmatter missing required field(s): %s"
                              % ",".join(missing),
                    "valid": False,
                })
            continue

        # pre-write validation: the manifest research_artifacts[] entry shape
        # (only for plan-specific promotions that will stamp library_refs).
        if ra_entry is not None:
            ok, reason = validate_ra_item(ra_entry)
            if not ok:
                counts["blocked"] += 1
                if not dry_run:
                    emit({
                        "finding": "library-scrub", "file": src,
                        "category": "scrub-blocked",
                        "reason": "manifest research_artifacts[] entry invalid: %s"
                                  % reason,
                        "valid": False,
                    })
                continue

        counts["candidates"] += 1
        ref = "%s/%s" % (topic, article_name)  # <topic>/<article> stamp form

        if not apply_mode:
            if not dry_run:
                emit({
                    "finding": "library-scrub", "file": src,
                    "category": "promotion-candidate", "topic": topic,
                    "article": article_name + ".md",
                    "plan": plan_slug or "",
                    "routing": routing,
                    "raw_sources": str(len(raw_sources)),
                    "scrubbed_terms": str(n_removed),
                    "valid": True,
                })
            continue

        # ===================== --apply: the write chain ======================
        topic_root = os.path.join(library_dir, topic)
        raw_root = os.path.join(topic_root, "_raw")
        article_path = os.path.join(topic_root, article_name + ".md")

        # RAW COPY: copy the immutable original into _library/<topic>/_raw/
        # BEFORE scrubbing the article (read-not-mutate the source). Written once.
        os.makedirs(raw_root, exist_ok=True)
        raw_target = os.path.join(raw_root, src)
        if not os.path.exists(raw_target):
            shutil.copy2(src_path, raw_target)

        # PROMO-2: write the scrubbed universal article (atomic).
        article_md, _h1 = build_article(
            topic, article_name, scrubbed, routing, raw_sources, tags, plan_slug,
            cohort_description, cohort_created, cohort_id, COHORT_SCHEMA_VERSION)
        atomic_write(article_path, article_md)

        plan_sot_path = ""
        if plan_slug:
            # PROMO-3: plan-SoT persist — the FULL plan-specific version lands in
            # <plan>/_research/ (the un-scrubbed original is the plan SoT).
            research_dir = os.path.join(plans_dir, plan_slug, "_research")
            plan_sot_path = os.path.join(research_dir, src)
            atomic_write(plan_sot_path, raw_text)

            # PROMO-4: bidirectional stamp — two SEQUENTIAL individually-atomic
            # writes, NOT a transaction (the accepted crash-window contract; the
            # library-index re-derive is the one-sided-edge detector).
            #   (1) the article already carries originating_plan: from build_article
            #       above (its first atomic write).
            #   (2) the manifest entry gains library_refs: [<topic>/<article>].
            if manifest_path and ra_entry is not None:
                stamp_manifest_library_refs(manifest_path, ra_entry.get("id"), ref)

        # PROMO-6: archive — MOVE the workshop original to workshop/_archive/.
        archive_topic = os.path.join(archive_root, tdir)
        os.makedirs(archive_topic, exist_ok=True)
        archive_target = os.path.join(archive_topic, src)
        shutil.move(src_path, archive_target)

        # PROMO-6 log half: record the promotion in _library/log.md via
        # the SOLE appender hook. Event->ACTION mapping (the seam
        # contract): the _raw/ immutable provenance copy is an INGEST; the
        # universal article is a PROMOTE. Both paths are <topic>/<article>.md form
        # so the library-index staleness reader keys the topic from segment 0.
        article_rel = "%s/%s.md" % (topic, article_name)
        raw_rel = "%s/_raw/%s" % (topic, src)
        append_log_event("INGEST", raw_rel,
                         "promoted provenance original (CAP-3)")
        append_log_event("PROMOTE", article_rel,
                         "promoted from %s" % plan_slug)

        counts["promoted"] += 1
        if not dry_run:
            emit({
                "finding": "library-scrub", "file": src,
                "category": "promoted", "topic": topic,
                "article": ref + ".md", "written": article_path,
                "plan_sot": plan_sot_path,
                "archived": archive_target,
            })

if dry_run:
    mode = "apply" if apply_mode else "propose"
    print("library-scrub: dry-run summary (mode=%s, topics=%d)" % (
        mode, counts["topics"]), file=sys.stderr)
    print("  candidates=%d promoted=%d blocked=%d (empty=%d)" % (
        counts["candidates"], counts["promoted"], counts["blocked"],
        counts["skipped_empty"]), file=sys.stderr)
PY

exit 0
