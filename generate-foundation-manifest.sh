#!/bin/bash
# generate-foundation-manifest.sh
#
# Walks SOURCE_REPO emitting a deterministic JSON manifest of every file
# install.sh ships to $CLAUDE_HOME, with installed-relative paths, sha256,
# octal mode, and byte size. Ships at foundation-repo `governance/`; install.sh
# ships the artifact via Step 8.5 selective copy to
# $CLAUDE_HOME/governance/foundation-manifest.json (lives alongside
# foundation-master.json + overlay-master.json).
#
# Consumers:
#   - install.sh G2 — foreign-content detector (compares installed-tree
#     hashes vs baseline; refuses on drift unless --force-install +
#     --backup-verified)
#   - uninstall.sh — sha256 fingerprint match before rm (preserves
#     user-edited foundation files; emits review summary)
#
# Schema (uninstall G2 + install G2 both consume):
#   {
#     "version": "v2.0.0-rc1",
#     "generated_at": "<ISO8601 UTC>",
#     "generator_sha256": "<sha256 of this script>",
#     "files": [
#       {"path": "<installed-relative path>",
#        "sha256": "<64 hex>",
#        "mode": "<4-digit octal>",
#        "size": <bytes>}
#       , …
#     ]
#   }
#
# Determinism: output is byte-identical across runs modulo `generated_at`.
# `find` output is LC_ALL=C-sorted; `files` array is `jq sort_by(.path)`;
# top-level keys are jq -S sorted. R-23 bash 3.2 compat throughout.
#
# Path translation (mirrors install.sh):
#   identity throughout. hooks/lib/*.{sh,json,sql} is the SOLE lib surface
#   (no top-level lib/ → hooks/lib/ translation); claude-mem is an
#   optional adopter-installed marketplace plugin (no plugins/ ship
#   surface). Every walked directory uses identity (source path == installed path).
#
# Walked source paths (mirrors install.sh ship surface):
#   hooks/{*.sh,*.md,MANIFEST.txt}        (top-level only; no recursion)
#   hooks/config/*.json
#   hooks/lib/*.{sh,json,sql}             (identity; install.sh Step 3.5)
#   skills/{12 named brain-stem dirs}/**  (recursive; install.sh Step 5 roster)
#   schemas/{10 named}.json + README.md   (install.sh Step 9 selective list)
#   orchestrator/**                       (recursive)
#   installer/**                          (recursive)
#   governance/ SELECTIVE                 (Step 8.5 ship surface: foundation-master.json
#                                          + overlay-master.json + log-subtype-registry.json
#                                          + file-type-contracts/ ONLY; the 7 pillar *-rules.json
#                                          + doc-dependencies.json + _index.json stay repo-only)
#   vault-init/**                         (recursive; install.sh Step 8.7)
#   templates/* (top-level glob)          (install.sh Step 10)
#   templates/launchd/*.tmpl
#   templates/settings-fragments/*.json
#
# Excluded (runtime state, source-only artifacts, distribution-tooling):
#   hooks/state/**          (session state; install.sh creates empty dir)
#   tests/**                (test harness, not shipped)
#   tools/**                (release-time tools: build-foundation-master.sh +
#                            generate-foundation-manifest.sh siblings; not installed)
#   onboarding/ + plugins/  (DROPPED; onboarding dissolved into skills/onboarder/;
#                            claude-mem unbundled)
#   walk-hygiene cruft       (.DS_Store, __pycache__/, *.pyc — pruned by find_shipped)
#   orchestrator/state/**    (runtime state; absent-by-construction, pruned by find_shipped)
#   .git/**, .github/**, docs/**, lima/**, docker/**, research/**, _doc-overhaul/**
#   .gitignore, .image-digest, .self-verify/**
#   install.sh, uninstall.sh, generate-foundation-manifest.sh
#   governance/foundation-manifest.json (chicken-and-egg: this file is the output)
#
# Usage:
#   generate-foundation-manifest.sh [-o <output_path>] [--version <ver>]
#
# Default output: stdout
# Default version: v2.0.0-rc1
# Default SOURCE_REPO: directory containing this script

set -u

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
SOURCE_REPO="${SOURCE_REPO:-$SCRIPT_DIR}"
VERSION="v1.0.0"
OUTPUT=""
EMIT_PAIRS=0   # --emit-pairs: print raw src_rel<TAB>installed_rel pairs + exit (parity test)

usage() {
  cat <<EOF
generate-foundation-manifest.sh

Usage: $0 [-o <output_path>] [--version <ver>]

Environment:
  SOURCE_REPO   foundation-repo top (default: dir containing this script)

Options:
  -o <path>     write JSON to <path> (default: stdout)
  --version <ver>  pin top-level version field (default: v1.0.0)
  -h | --help   this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) OUTPUT="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --emit-pairs) EMIT_PAIRS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ ! -d "$SOURCE_REPO/hooks" ] || [ ! -d "$SOURCE_REPO/skills" ] || [ ! -d "$SOURCE_REPO/schemas" ]; then
  printf 'generate-foundation-manifest FAIL: SOURCE_REPO does not look like foundation-repo: %s\n' "$SOURCE_REPO" >&2
  exit 10
fi

for bin in jq shasum stat awk find sort; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    printf 'generate-foundation-manifest FAIL: missing prereq binary: %s\n' "$bin" >&2
    exit 10
  fi
done

generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
generator_sha256="$(shasum -a 256 "$SCRIPT_PATH" | awk '{print $1}')"

# --- walk-hygiene exclusion ------------------------------------------------
# The recursive `find ... -type f` walks below traverse the disk, NOT git, so
# disk-walk cruft (.DS_Store, __pycache__/*.pyc) and runtime state (state/*)
# would otherwise enter the fingerprint baseline. find_shipped prunes the same
# exclusion set install.sh's Step 8.8 ship-prune strips, keeping the manifest
# absent-by-construction (state/ absent; ship-list parity).
# Block (exclude), never ship-and-hope. bash 3.2 (R-23) — predicate-pruned find.
find_shipped() {
  LC_ALL=C find "$1" \
    -type d \( -name '__pycache__' -o -name 'state' \) -prune -o \
    -type f ! -name '.DS_Store' ! -name '*.pyc' -print 2>/dev/null
}

# --- emit (src_relative\tinstalled_relative) pairs for every shipped file ---
# Ordering does not matter: final files[] gets jq sort_by(.path).
emit_pairs() {
  local f base d skill s vdir vname rel installed

  # hooks/ top-level files (no recursion)
  for f in "$SOURCE_REPO/hooks"/*.sh "$SOURCE_REPO/hooks"/*.md "$SOURCE_REPO/hooks/MANIFEST.txt"; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    printf 'hooks/%s\thooks/%s\n' "$base" "$base"
  done

  # hooks/config/*.json
  for f in "$SOURCE_REPO/hooks/config"/*.json; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    printf 'hooks/config/%s\thooks/config/%s\n' "$base" "$base"
  done

  # hooks/lib/*.{sh,json,sql} (identity; hooks/lib/ is the SOLE lib surface —
  # NO top-level lib/ translation. install.sh Step 3 ships hooks/lib/*.{sh,json,sql}
  # directly). The *.sql wildcard captures manifest-migrate.sql when the
  # writer-manifest substrate is present.
  for f in "$SOURCE_REPO/hooks/lib"/*.sh "$SOURCE_REPO/hooks/lib"/*.json "$SOURCE_REPO/hooks/lib"/*.sql; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    printf 'hooks/lib/%s\thooks/lib/%s\n' "$base" "$base"
  done

  # skills/{brain-stem roster}/** (recursive within named dirs). Mirrors install.sh
  # Step 5: NOT in the roster — morning-brief (R-22), adopt + infer-vault-structure
  # (R-09), architect. The onboarder skill carries its absorbed producers.
  for skill in librarian backlog-hygiene backlog-triage backlog-research onboarder govern doc-amender writer-reconciler meeting-note-ingestor mem-promote new-plan session-checkpoint; do
    d="$SOURCE_REPO/skills/$skill"
    [ -d "$d" ] || continue
    find_shipped "$d" | LC_ALL=C sort | while IFS= read -r f; do
      rel="${f#$SOURCE_REPO/}"
      printf '%s\t%s\n' "$rel" "$rel"
    done
  done

  # schemas — named .json + README.md (mirrors install.sh Step 9 list).
  # Dropped vault-schema + gate-config + gate-config-schema
  # (dissolved into pillar shards / retired).
  # Dropped vault-overlay-schema; added 6 schemas
  # (overlay-master, governance-action-log, vault-writers-rules, processing-rules,
  # plans-rules, writer-manifest).
  # Dropped 4 per-pillar schemas (doc-dependencies-schema,
  # vault-writers-rules-schema, processing-rules-schema, plans-rules-schema) —
  # per-pillar schemas stay foundation-repo authoring-side as reference; the
  # bundle-slot schema in foundation-master-schema.json is the validation layer.
  # Symmetric to the pillar JSON repo-only pattern.
  for s in plans-schema plan-manifest-schema librarian-manifest-schema user-manifest-schema orchestration-schema drift-allowlist-schema overlay-master-schema governance-action-log-schema writer-manifest-schema; do
    f="$SOURCE_REPO/schemas/$s.json"
    [ -f "$f" ] || continue
    printf 'schemas/%s.json\tschemas/%s.json\n' "$s" "$s"
  done
  if [ -f "$SOURCE_REPO/schemas/README.md" ]; then
    printf 'schemas/README.md\tschemas/README.md\n'
  fi

  # onboarding/ walk DROPPED. The top-level onboarding/
  # tree is dissolved into skills/onboarder/ — its producers are enumerated by the
  # skills/ walk above (skill=onboarder). There is no top-level onboarding/ ship
  # surface to walk.

  # orchestrator/** (recursive)
  d="$SOURCE_REPO/orchestrator"
  if [ -d "$d" ]; then
    find_shipped "$d" | LC_ALL=C sort | while IFS= read -r f; do
      rel="${f#$SOURCE_REPO/}"
      printf '%s\t%s\n' "$rel" "$rel"
    done
  fi

  # installer/** (recursive)
  d="$SOURCE_REPO/installer"
  if [ -d "$d" ]; then
    find_shipped "$d" | LC_ALL=C sort | while IFS= read -r f; do
      rel="${f#$SOURCE_REPO/}"
      printf '%s\t%s\n' "$rel" "$rel"
    done
  fi

  # governance/ — SELECTIVE walk mirroring install.sh Step 8.5 ship surface.
  # The 7 pillar *-rules.json + doc-dependencies.json + _index.json
  # stay repo-only (composed into foundation-master.json at release).
  # EXCLUDED from the walk (mirror install Step 8.5 strikes):
  #   - foundation-manifest.json (chicken-and-egg: this script generates it)
  #   - governance-action-log.jsonl (bootstrap-CREATED at Step 1.6, NOT copied;
  #     runtime-empty file, not a fingerprinted ship artifact)
  #   - librarian-capabilities/ + onboarding-reference/ (R-20)
  d="$SOURCE_REPO/governance"
  if [ -d "$d" ]; then
    # Top-level files that ship via Step 8.5 selective copy
    for base in foundation-master.json overlay-master.json log-subtype-registry.json; do
      [ -f "$d/$base" ] || continue
      printf 'governance/%s\tgovernance/%s\n' "$base" "$base"
    done
    # Recursive subdirs that ship per Step 8.5: file-type-contracts/ ONLY.
    for subdir in file-type-contracts; do
      if [ -d "$d/$subdir" ]; then
        find_shipped "$d/$subdir" | LC_ALL=C sort | while IFS= read -r f; do
          rel="${f#$SOURCE_REPO/}"
          printf '%s\t%s\n' "$rel" "$rel"
        done
      fi
    done
  fi

  # vault-init/** (recursive; install.sh Step 8.7)
  # Foundation-canonical adopter-vault seed tree mirroring the target adopter
  # vault tree exactly. Includes System Governance/ + Vault Writers/
  # + Logs/Archive/ + Meetings/ subdir scaffolds. The per-plan backlog satellite
  # is retired (backlog + archive now live as librarian-emitted files at
  # ${PLANS_DIR:-$HOME/.claude-plans}/_backlog.md + _archive.md under Plans Pillar governance).
  # cp -R wholesale matches install.sh Step 8.7 ship posture; sha256-protected baselines.
  d="$SOURCE_REPO/vault-init"
  if [ -d "$d" ]; then
    find_shipped "$d" | LC_ALL=C sort | while IFS= read -r f; do
      rel="${f#$SOURCE_REPO/}"
      printf '%s\t%s\n' "$rel" "$rel"
    done
  fi

  # templates/ — ALL top-level files (glob, not a named list). install.sh
  # Step 10 ships a named loop; this glob covers it exactly
  # (templates/ top-level == install's 17-item list) and auto-covers
  # future templates so the fingerprint baseline can't silently drift again
  # (a named-subset list previously omitted shipped templates → uninstall
  # residue). Subdirs (launchd/, settings-fragments/) handled by loops below;
  # `[ -f ]` skips them. A generator↔install parity test will
  # catch any future divergence in either direction.
  for f in "$SOURCE_REPO/templates"/*; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    printf 'templates/%s\ttemplates/%s\n' "$base" "$base"
  done

  # templates/launchd/*.tmpl
  for f in "$SOURCE_REPO/templates/launchd"/*.tmpl; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    printf 'templates/launchd/%s\ttemplates/launchd/%s\n' "$base" "$base"
  done

  # templates/settings-fragments/*.json
  for f in "$SOURCE_REPO/templates/settings-fragments"/*.json; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    printf 'templates/settings-fragments/%s\ttemplates/settings-fragments/%s\n' "$base" "$base"
  done

  # plugins/claude-mem walk DROPPED. claude-mem is NOT
  # bundled — it is an optional adopter-installed marketplace plugin. install.sh
  # Step 11 is dropped; there is no plugins/ ship surface to walk.
}

# --- emit one JSON record per file (src→{path,sha256,mode,size}) ---
emit_records() {
  local src_rel installed_rel src sha mode_full mode size mode_len
  while IFS=$'\t' read -r src_rel installed_rel; do
    [ -z "$src_rel" ] && continue
    src="$SOURCE_REPO/$src_rel"
    [ -f "$src" ] || continue
    sha="$(shasum -a 256 "$src" 2>/dev/null | awk '{print $1}')"
    mode_full="$(stat -f '%Op' "$src" 2>/dev/null)"
    mode_len=${#mode_full}
    if [ "$mode_len" -ge 4 ]; then
      mode="${mode_full:$((mode_len-4)):4}"
    else
      mode="$mode_full"
    fi
    size="$(stat -f '%z' "$src" 2>/dev/null)"
    if [ -z "$sha" ] || [ -z "$mode" ] || [ -z "$size" ]; then
      printf 'generate-foundation-manifest WARN: stat/sha failure on %s; skipping\n' "$src" >&2
      continue
    fi
    jq -n -c \
      --arg path "$installed_rel" \
      --arg sha256 "$sha" \
      --arg mode "$mode" \
      --argjson size "$size" \
      '{path: $path, sha256: $sha256, mode: $mode, size: $size}'
  done
}

# --- parity hook: expose raw src→installed pairs for the parity test ---
if [ "$EMIT_PAIRS" = 1 ]; then
  emit_pairs
  exit 0
fi

# --- build files[] array, sorted by path ---
records="$(emit_pairs | emit_records)"
if [ -z "$records" ]; then
  printf 'generate-foundation-manifest FAIL: no shipped files discovered under %s\n' "$SOURCE_REPO" >&2
  exit 11
fi

files_json="$(printf '%s\n' "$records" | jq -s 'sort_by(.path)')"

# --- compose final JSON with sorted top-level keys ---
out_json="$(jq -n -S \
  --arg version "$VERSION" \
  --arg generated_at "$generated_at" \
  --arg generator_sha256 "$generator_sha256" \
  --argjson files "$files_json" \
  '{version: $version, generated_at: $generated_at, generator_sha256: $generator_sha256, files: $files}')"

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$out_json" > "$OUTPUT" || {
    printf 'generate-foundation-manifest FAIL: write failed: %s\n' "$OUTPUT" >&2
    exit 11
  }
else
  printf '%s\n' "$out_json"
fi

exit 0
