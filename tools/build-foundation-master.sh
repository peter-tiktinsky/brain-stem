#!/bin/bash
# build-foundation-master.sh — composes foundation governance pillars into
# governance/foundation-master.json at foundation-repo RELEASE time.
# brain-stem (ABSORB-govern). Release-time tool — NOT in the adopter
# ship-list (.1:296 'release-time NOT installed'). Adopters never build;
# install.sh ships the composed artifact as immutable shipped state per
# feedback_ship_bundle_dont_build_on_consumer.
# CLEAN-ROOM v2 pillar shape (in-transit modifications vs the
# @— flagged as a closure-discovery):
#   - Rename (-> brain-stem) throughout.
#   - R-47 exempt-paths read RE-POINTED to the clean-room register location:
#     tagging-rules.json#_rules[id=R-47].r47_exempt_paths (NOT the legacy
#     .rules[id=R-47].r47_exempt_paths). The clean-room tagging pillar
#     homes R-47 in the `_rules[]` register and its own r47_exempt_paths_provenance
#     mandates this composition at. The 8-slot bundle shape, the
#     r32/r47 top-level runtime-contract slots, and the consumer read-paths
#     (governance/_index.json cross_cutting rules-index lines 502-508;
#     hooks/pre-write-guard.sh :1046/:1048/:1568) are unchanged.
#   - gate-config.json is absent in the clean-room (dropped); the r32/r47
#     gate-config absorption guards already default gracefully ({}, [], 25).
# Inputs (read-only):
#   governance/frontmatter-rules.json       (; carries types + tier_compliance)
#   governance/tagging-rules.json           (canonical taxonomy; R-47 in _rules)
#   governance/naming-rules.json
#   governance/mandatory-files-rules.json
#   governance/doc-dependencies.json
#   governance/file-type-contracts/*.json   (k8s paramKind contracts)
#   governance/_index.json
#   governance/vault-writers-rules.json     (pillar 7)
#   governance/plans-rules.json             (pillar 8)
#   schemas/gate-config.json                (optional; absent in the clean-room)
# Output (single artifact):
#   governance/foundation-master.json
# Deterministic discipline:
#   - All composition uses `jq -S` (sorted keys; canonical JSON serialization).
#   - bundle_version = sha256(canonical-serialized bundle WITHOUT _meta). Same
#     inputs -> same bundle_version. _meta carries built_at + source mtimes but
#     does NOT participate in the version hash.
#   - r47_exempt_paths_composed: deduped + sorted (sort -u) union.
#   - File ordering: jq -S enforces deterministic top-level key order.
# Validation:
#   - jq syntax check on every input
#   - jsonschema check on output against schemas/foundation-master-schema.json
#     (skipped with warning if python3 + jsonschema unavailable)
# Exit codes:
#   0  success
#   1  generic error
#   2  missing required input file
#   3  jq syntax error in input
#   4  schema validation failure on output
#   5  required tool missing (jq, shasum, date)

set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
SOURCE_REPO="${SOURCE_REPO:-$(cd "$SCRIPT_DIR/.." && pwd)}"

OUTPUT="$SOURCE_REPO/governance/foundation-master.json"
SCHEMA="$SOURCE_REPO/schemas/foundation-master-schema.json"

# --- 1. Required tools -------------------------------------------------------
for bin in jq shasum date; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "build-foundation-master: required tool missing: $bin" >&2
    exit 5
  fi
done

# --- 2. Required inputs ------------------------------------------------------
FRONTMATTER="$SOURCE_REPO/governance/frontmatter-rules.json"
TAGGING="$SOURCE_REPO/governance/tagging-rules.json"
NAMING="$SOURCE_REPO/governance/naming-rules.json"
MANDATORY="$SOURCE_REPO/governance/mandatory-files-rules.json"
DOC_DEPS="$SOURCE_REPO/governance/doc-dependencies.json"
INDEX="$SOURCE_REPO/governance/_index.json"
FILE_TYPE_CONTRACTS_DIR="$SOURCE_REPO/governance/file-type-contracts"
VAULT_WRITERS="$SOURCE_REPO/governance/vault-writers-rules.json"
PLANS="$SOURCE_REPO/governance/plans-rules.json"
GATE_CONFIG="$SOURCE_REPO/schemas/gate-config.json"

for f in "$FRONTMATTER" "$TAGGING" "$NAMING" "$MANDATORY" "$DOC_DEPS" "$INDEX" "$VAULT_WRITERS" "$PLANS"; do
  if [ ! -f "$f" ]; then
    echo "build-foundation-master: missing required input: $f" >&2
    exit 2
  fi
  if ! jq -e . "$f" >/dev/null 2>&1; then
    echo "build-foundation-master: invalid JSON: $f" >&2
    exit 3
  fi
done

# --- 3. Reproducible timestamps (SOURCE_DATE_EPOCH / git commit time) ---------
# Wall-clock `date -u` (built_at) and filesystem mtimes (source_file_mtimes) are
# both non-reproducible, so they are REPLACED by content-deterministic git commit
# times: two builds of identical pillars now produce an identical master sha AND a
# byte-identical file. SOURCE_DATE_EPOCH (reproducible-builds standard) overrides.
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
  BUILD_EPOCH="$SOURCE_DATE_EPOCH"
else
  BUILD_EPOCH="$(git -C "$SOURCE_REPO" log -1 --format=%ct 2>/dev/null || true)"
fi

iso_utc() {
  # epoch-seconds -> ISO8601 UTC; deterministic sentinel when no epoch is available
  # (e.g. a non-git source tree) so the output stays reproducible regardless.
  if [ -n "${1:-}" ]; then date -u -r "$1" "+%Y-%m-%dT%H:%M:%SZ"; else printf '1970-01-01T00:00:00Z'; fi
}

mtime_iso() {
  # last git commit time of the pillar (its content version) — reproducible. Falls
  # back to the build epoch (NOT the filesystem mtime) so determinism holds even
  # for an untracked pillar.
  local f="$1" rel ct
  rel="${f#$SOURCE_REPO/}"
  ct="$(git -C "$SOURCE_REPO" log -1 --format=%ct -- "$rel" 2>/dev/null || true)"
  [ -z "$ct" ] && ct="$BUILD_EPOCH"
  iso_utc "$ct"
}

BUILD_AT="$(iso_utc "$BUILD_EPOCH")"

# --- 4. Compose r47_exempt_paths_composed (deduped sorted union) ------------
# Clean-room v2 canonical declaration: tagging-rules.json#_rules[id=R-47].r47_exempt_paths
# (the rule register; re-pointed off the legacy .rules[] path per the tagging pillar's
# own r47_exempt_paths_provenance — composition contract).
# Interim contributor: gate-config.json#r47.exempt_paths (absent in clean-room).
TAGGING_R47=$(jq -r '._rules[]? | select(.id=="R-47") | .r47_exempt_paths[]?' "$TAGGING")
if [ -f "$GATE_CONFIG" ] && jq -e . "$GATE_CONFIG" >/dev/null 2>&1; then
  GATE_R47=$(jq -r '.r47.exempt_paths[]' "$GATE_CONFIG" 2>/dev/null || true)
else
  GATE_R47=""
fi
R47_COMPOSED_JSON=$(printf '%s\n%s\n' "$TAGGING_R47" "$GATE_R47" | LC_ALL=C sort -u | grep -v '^$' | jq -R -s 'split("\n") | map(select(length > 0))')

# --- 4a. Compose seed_taxonomy_exempt_paths_composed (deduped sorted) -------
# r47_exempt_paths (the tag-PRESENCE list). Composed from the clean-room
# register tagging-rules.json#_rules[id=R-47].seed_taxonomy_exempt_paths so the
# 9 day-one shipped-seed tag-not-in-taxonomy violations are exempted without
# touching seed bytes. Consumed by frontmatter-enforce.sh tag-taxonomy arm.
TAGGING_SEED_TAX=$(jq -r '._rules[]? | select(.id=="R-47") | .seed_taxonomy_exempt_paths[]?' "$TAGGING")
SEED_TAX_COMPOSED_JSON=$(printf '%s\n' "$TAGGING_SEED_TAX" | LC_ALL=C sort -u | grep -v '^$' | jq -R -s 'split("\n") | map(select(length > 0))')

# --- 4b. Absorb gate-config r32/r47 residual slices --------------------------
# In the clean-room gate-config.json is dropped, so these default to {}/[]/25.
# Hooks read .frontmatter.r32_type_aliases (// {}), .r32_exempt_paths ([]?),
# .r47_exempt_paths_composed; .r47_tag_cap retained for shape compatibility.
if [ -f "$GATE_CONFIG" ] && jq -e . "$GATE_CONFIG" >/dev/null 2>&1; then
  R32_TYPE_ALIASES_JSON=$(jq -S '.r32.type_aliases // {}' "$GATE_CONFIG")
  R32_EXEMPT_PATHS_JSON=$(jq -S '.r32.exempt_paths // []' "$GATE_CONFIG")
  R47_TAG_CAP_JSON=$(jq -S '.r47.tag_cap // 25' "$GATE_CONFIG")
else
  R32_TYPE_ALIASES_JSON='{}'
  R32_EXEMPT_PATHS_JSON='[]'
  R47_TAG_CAP_JSON='25'
fi

# --- 5. Compose file-type-contracts (key = filename without extension) ------
FTC_JSON='{}'
if [ -d "$FILE_TYPE_CONTRACTS_DIR" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    name=$(basename "$f" .json)
    contract=$(jq -S '.' "$f")
    FTC_JSON=$(jq -S --arg k "$name" --argjson v "$contract" '. + {($k): $v}' <<<"$FTC_JSON")
  done < <(LC_ALL=C find "$FILE_TYPE_CONTRACTS_DIR" -maxdepth 1 -type f -name '*.json' | LC_ALL=C sort)
fi

# --- 6. Build source_file_mtimes block --------------------------------------
mt_frontmatter=$(mtime_iso "$FRONTMATTER")
mt_tagging=$(mtime_iso "$TAGGING")
mt_naming=$(mtime_iso "$NAMING")
mt_mandatory=$(mtime_iso "$MANDATORY")
mt_doc_deps=$(mtime_iso "$DOC_DEPS")
mt_index=$(mtime_iso "$INDEX")
mt_vault_writers=$(mtime_iso "$VAULT_WRITERS")
mt_plans=$(mtime_iso "$PLANS")

SOURCE_MTIMES_JSON=$(jq -n -S \
  --arg fm "$mt_frontmatter" \
  --arg tg "$mt_tagging" \
  --arg nm "$mt_naming" \
  --arg mf "$mt_mandatory" \
  --arg dd "$mt_doc_deps" \
  --arg ix "$mt_index" \
  --arg vw "$mt_vault_writers" \
  --arg pl "$mt_plans" \
  '{
    "governance/frontmatter-rules.json": $fm,
    "governance/tagging-rules.json": $tg,
    "governance/naming-rules.json": $nm,
    "governance/mandatory-files-rules.json": $mf,
    "governance/doc-dependencies.json": $dd,
    "governance/_index.json": $ix,
    "governance/vault-writers-rules.json": $vw,
    "governance/plans-rules.json": $pl
  }')

# --- 7. Compose the bundle (sans _meta) --------------------------------------
# r32_type_aliases injected INTO the frontmatter pillar (.frontmatter.r32_type_aliases);
# empty {} in the clean-room (gate-config dropped). Hooks read pillar-nested.
FRONTMATTER_JSON=$(jq -S --argjson aliases "$R32_TYPE_ALIASES_JSON" '. + {r32_type_aliases: $aliases}' "$FRONTMATTER")
TAGGING_JSON=$(jq -S '.' "$TAGGING")
NAMING_JSON=$(jq -S '.' "$NAMING")
MANDATORY_JSON=$(jq -S '.' "$MANDATORY")
DOC_DEPS_JSON=$(jq -S '.' "$DOC_DEPS")
INDEX_JSON=$(jq -S '.' "$INDEX")
VAULT_WRITERS_JSON=$(jq -S '.' "$VAULT_WRITERS")
PLANS_JSON=$(jq -S '.' "$PLANS")

BUNDLE_BODY=$(jq -n -S \
  --argjson fm "$FRONTMATTER_JSON" \
  --argjson tg "$TAGGING_JSON" \
  --argjson nm "$NAMING_JSON" \
  --argjson mf "$MANDATORY_JSON" \
  --argjson dd "$DOC_DEPS_JSON" \
  --argjson ix "$INDEX_JSON" \
  --argjson ftc "$FTC_JSON" \
  --argjson vw "$VAULT_WRITERS_JSON" \
  --argjson pl "$PLANS_JSON" \
  --argjson r47 "$R47_COMPOSED_JSON" \
  --argjson seedtax "$SEED_TAX_COMPOSED_JSON" \
  --argjson r32ep "$R32_EXEMPT_PATHS_JSON" \
  --argjson r47cap "$R47_TAG_CAP_JSON" \
  '{
    "schema_version": "1.2.0",
    "_description": "Composed foundation governance bundle. Built deterministically from the 8 authoring pillars + N file-type-contracts by tools/build-foundation-master.sh. Shipped as immutable artifact to adopter ~/.claude/governance/foundation-master.json; adopters never build. Hooks load this bundle once per write-session; per-rule lookups derive from this composed view. r47_exempt_paths_composed is composed from tagging-rules.json#_rules[id=R-47].r47_exempt_paths (the `_rules[]` register location). r32_type_aliases/r32_exempt_paths/r47_tag_cap default to {}/[]/25 (gate-config dropped).",
    "frontmatter": $fm,
    "tagging": $tg,
    "naming": $nm,
    "mandatory_files": $mf,
    "doc_dependencies": $dd,
    "file_type_contracts": $ftc,
    "vault_writers": $vw,
    "plans": $pl,
    "_index": $ix,
    "r47_exempt_paths_composed": $r47,
    "seed_taxonomy_exempt_paths_composed": $seedtax,
    "r32_exempt_paths": $r32ep,
    "r47_tag_cap": $r47cap
  }')

# --- 8. bundle_version = sha256 of canonical body (without _meta) -----------
BUNDLE_VERSION=$(printf '%s' "$BUNDLE_BODY" | shasum -a 256 | awk '{print $1}')

# --- 9. Stamp _meta + assemble final bundle ---------------------------------
META_JSON=$(jq -n -S \
  --arg bv "$BUNDLE_VERSION" \
  --arg ba "$BUILD_AT" \
  --argjson mtimes "$SOURCE_MTIMES_JSON" \
  --argjson src_count 8 \
  '{
    "bundle_version": $bv,
    "built_at": $ba,
    "source_file_mtimes": $mtimes,
    "build_tool": "tools/build-foundation-master.sh",
    "deterministic_serialization": "jq -S sorted-keys canonical JSON; bundle_version excludes _meta block from hash input",
    "source_files_count": $src_count,
    "_provenance": "Composed foundation governance bundle. Same source files (by content) -> same bundle_version. built_at + source_file_mtimes are pinned to git commit time (SOURCE_DATE_EPOCH-honoring), so the shipped master is byte-reproducible: two builds of identical pillars produce an identical file. _meta is still excluded from the bundle_version hash."
  }')

FINAL_BUNDLE=$(jq -S --argjson meta "$META_JSON" '. + {"_meta": $meta}' <<<"$BUNDLE_BODY")

# --- 10. Write atomically ----------------------------------------------------
TMP_OUT="$OUTPUT.tmp.$$"
printf '%s\n' "$FINAL_BUNDLE" > "$TMP_OUT"

# --- 11. Validate output -----------------------------------------------------
if ! jq -e . "$TMP_OUT" >/dev/null 2>&1; then
  echo "build-foundation-master: output is not valid JSON" >&2
  rm -f "$TMP_OUT"
  exit 1
fi

if [ -f "$SCHEMA" ] && command -v python3 >/dev/null 2>&1; then
  if python3 -c "import jsonschema" >/dev/null 2>&1; then
    if ! python3 -c "
import json, sys
import jsonschema
with open('$SCHEMA') as f: schema = json.load(f)
with open('$TMP_OUT') as f: bundle = json.load(f)
try:
    jsonschema.validate(bundle, schema)
    print('schema-validation: PASS')
except jsonschema.ValidationError as e:
    print('schema-validation: FAIL', file=sys.stderr)
    print(f'  path: {list(e.absolute_path)}', file=sys.stderr)
    print(f'  msg: {e.message}', file=sys.stderr)
    sys.exit(4)
"; then
      rm -f "$TMP_OUT"
      exit 4
    fi
  else
    echo "build-foundation-master: jsonschema not installed; skipping schema validation" >&2
  fi
fi

# --- 12. Atomic move ---------------------------------------------------------
mv -f "$TMP_OUT" "$OUTPUT"

echo "build-foundation-master: wrote $OUTPUT"
echo "  bundle_version: $BUNDLE_VERSION"
echo "  built_at:       $BUILD_AT"
echo "  pillars:        8"
echo "  r47_exempt_paths_composed:        $(echo "$R47_COMPOSED_JSON" | jq 'length') entries"
echo "  seed_taxonomy_exempt_paths_composed: $(echo "$SEED_TAX_COMPOSED_JSON" | jq 'length') entries"
echo "  frontmatter.r32_type_aliases:     $(echo "$R32_TYPE_ALIASES_JSON" | jq 'length') entries"
echo "  r32_exempt_paths:                 $(echo "$R32_EXEMPT_PATHS_JSON" | jq 'length') entries"
echo "  r47_tag_cap:                      $(echo "$R47_TAG_CAP_JSON")"
echo "  file_type_contracts:              $(echo "$FTC_JSON" | jq 'length') entries"
echo "  vault_writers:                    present (pillar 7)"
echo "  plans:                            present (pillar 8)"
