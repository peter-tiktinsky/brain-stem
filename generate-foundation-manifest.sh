#!/bin/bash
# generate-foundation-manifest.sh — T-5 (baseline slice)
# Walks SOURCE_REPO emitting a deterministic JSON manifest of every file
# install.sh ships to $CLAUDE_HOME, with installed-relative paths, sha256,
# octal mode (derived from the git INDEX, not the worktree disk bit —
# T-2; so manifest.mode == shipped.mode by construction), and byte
# size. Ships at foundation-repo `governance/`; install.sh
# ships the artifact via Step 8.5 selective copy to
# $CLAUDE_HOME/governance/foundation-manifest.json (T-3 MOVE — was loose at
# root pre-; relocated to live alongside foundation-master.json + overlay-master.json
# per operator tidy-folder principle).
# Consumers (T-5 enables; T-1 + T-2 follow-up consume):
#   - install.sh G2 — foreign-content detector (compares installed-tree
#     hashes vs baseline; refuses on drift unless --force-install +
#     --backup-verified)
#   - uninstall.sh — sha256 fingerprint match before rm (preserves
#     user-edited foundation files; emits review summary)
# Schema (canonical shape; uninstall G2 + install G2 both consume):
#     "version": "v2.0.0-rc1",
#     "generated_at": "<ISO8601 UTC>",
#     "generator_sha256": "<sha256 of this script>",
#     "files": [
#       {"path": "<installed-relative path>",
#        "sha256": "<64 hex>",
#        "mode": "<4-digit octal>",
#        "size": <bytes>}
# Determinism: output is byte-identical across runs modulo `generated_at`.
# `find` output is LC_ALL=C-sorted; `files` array is `jq sort_by(.path)`;
# top-level keys are jq -S sorted. R-23 bash 3.2 compat throughout.
# Path translation (mirrors install.sh):
#   identity throughout. hooks/lib/*.{sh,json,sql} is the SOLE lib surface
#   (— no top-level lib/ → hooks/lib/ translation); claude-mem is an
#   optional adopter-installed marketplace plugin (— no plugins/ ship
#   surface). Every walked directory uses identity (source path == installed path).
# Walked source paths (mirrors install.sh ship surface):
#   hooks/{*.sh,*.md,MANIFEST.txt}        (top-level only; no recursion)
#   hooks/config/*.json
#   hooks/lib/*.{sh,json,sql}             (identity; install.sh Step 3.5)
#   skills/{12 named brain-stem dirs}/**  (recursive; install.sh Step 5 roster)
#   schemas/{12 named}.json + README.md   (install.sh Step 9 selective list;
#                                          review-queue-schema -> 12, not 10/9)
#   orchestrator/**                       (recursive)
#   installer/**                          (recursive)
#   governance/ SELECTIVE                 (Step 8.5 ship surface: foundation-master.json
#                                          + overlay-master.json + log-subtype-registry.json
#                                          + file-type-contracts/ + baselines/foundation-manifest-v*.json
#                                          + baselines/README.md ONLY; the 7 pillar *-rules.json
#                                          + doc-dependencies.json + _index.json stay repo-only)
#   vault-init/**                         (recursive; install.sh Step 8.7;
#                                          renamed from v2 vault-scaffolding/ per Session 7)
#   templates/* (top-level glob)          (install.sh Step 10)
#   templates/launchd/*.tmpl
#   templates/settings-fragments/*.json
# Excluded (runtime state, source-only artifacts, distribution-tooling):
#   hooks/state/**          (session state; install.sh creates empty dir)
#   tests/**                (test harness, not shipped)
#   tools/**                (release-time tools: build-foundation-master.sh +
#                            generate-foundation-manifest.sh siblings; not installed)
#   onboarding/ + plugins/  (DROPPED; onboarding dissolved into skills/onboarder/
#                            per; claude-mem unbundled per)
#   walk-hygiene cruft       (.DS_Store, __pycache__/, *.pyc — pruned by find_shipped)
#   orchestrator/state/**    (runtime state; absent-by-construction, pruned by find_shipped)
#   .git/**, .github/**, docs/**, lima/**, docker/**, research/**, _doc-overhaul/**
#   .gitignore, .image-digest, .self-verify/**
#   install.sh, uninstall.sh, generate-foundation-manifest.sh
#   governance/foundation-manifest.json (chicken-and-egg: this file is the output;
# Usage:
#   generate-foundation-manifest.sh [-o <output_path>] [--version <ver>]
# Default output: stdout
# Default version: derived from the committed governance/foundation-manifest.json
#   ::version when --version is absent (v0.0.0 on true bootstrap); T-18.
# Default SOURCE_REPO: directory containing this script

set -u

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
SOURCE_REPO="${SOURCE_REPO:-$SCRIPT_DIR}"
# VERSION default DERIVES from the committed manifest when --version is ABSENT (T-18:
# version-derive-from-SoT). The pre-existing literal default (v1.0.0) under-counted the v1.0.2
# release, reddening vp-1 + vp-5 on every no-arg regen. We resolve the default LATER (after argv
# parsing) so an explicit --version still wins (the release-ceremony bump path is unchanged). The
# empty sentinel here distinguishes "caller passed --version" from "use the committed manifest".
VERSION=""
OUTPUT=""
EMIT_PAIRS=0   # --emit-pairs: print raw src_rel<TAB>installed_rel pairs + exit (T-1 parity test)

usage() {
  cat <<EOF
generate-foundation-manifest.sh — T-5

Usage: $0 [-o <output_path>] [--version <ver>]

Environment:
  SOURCE_REPO   foundation-repo top (default: dir containing this script)

Options:
  -o <path>     write JSON to <path> (default: stdout)
  --version <ver>  pin top-level version field
                   (default: derived from committed governance/foundation-manifest.json)
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

# --- VERSION derive (T-18) -----------------------------------------
# When --version is ABSENT, derive VERSION from the committed manifest's .version
# (the release SoT) instead of a stale literal, so a no-arg regen PRESERVES the
# current version and never silently downgrades (e.g. v1.0.2 -> v1.0.0). The
# explicit --version path above still wins, so the release-ceremony bump is
# unchanged. Falls back to v0.0.0 only when no committed manifest exists yet
# (true bootstrap). jq is a hard prereq (asserted below).
COMMITTED_MANIFEST="$SOURCE_REPO/governance/foundation-manifest.json"
if [ -z "$VERSION" ]; then
  if [ -f "$COMMITTED_MANIFEST" ] && command -v jq >/dev/null 2>&1; then
    VERSION="$(jq -r '.version // "v0.0.0"' "$COMMITTED_MANIFEST" 2>/dev/null)"
    [ -n "$VERSION" ] && [ "$VERSION" != "null" ] || VERSION="v0.0.0"
  else
    VERSION="v0.0.0"
  fi
fi

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

# The shipped foundation-master.json is commit-time-pinned + byte-reproducible
# (build-foundation-master.sh); the manifest used a wall-clock `date -u`, so
# two manifest builds of an identical tree produced byte-divergent generated_at —
# a reproducibility ASYMMETRY with the master it fingerprints. SOURCE_DATE_EPOCH
# (reproducible-builds standard) overrides; otherwise the foundation-repo HEAD
# commit time (its content version). Falls back to a deterministic 1970 sentinel
# for a non-git source tree so the output stays reproducible regardless.
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
  _gen_epoch="$SOURCE_DATE_EPOCH"
else
  _gen_epoch="$(git -C "$SOURCE_REPO" log -1 --format=%ct 2>/dev/null || true)"
fi
if [ -n "$_gen_epoch" ]; then
  generated_at="$(date -u -r "$_gen_epoch" "+%Y-%m-%dT%H:%M:%SZ")"
else
  generated_at="1970-01-01T00:00:00Z"
fi
generator_sha256="$(shasum -a 256 "$SCRIPT_PATH" | awk '{print $1}')"

# --- walk-hygiene exclusion (brain-stem) ------------------------
# The recursive `find ... -type f` walks below traverse the disk, NOT git, so
# disk-walk cruft (.DS_Store, __pycache__/*.pyc) and runtime state (state/*)
# would otherwise enter the fingerprint baseline. find_shipped prunes the same
# exclusion set install.sh's Step 8.8 ship-prune strips, keeping the manifest
# absent-by-construction (canonical/state/ absent;.8 parity).
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

  # hooks/lib/*.{sh,json,sql} (identity;: hooks/lib/ is the SOLE lib surface —
  # NO top-level lib/ translation. install.sh Step 3 ships hooks/lib/*.{sh,json,sql}
  # directly). The *.sql wildcard captures manifest-migrate.sql when the C5
  # writer-manifest substrate is present.
  for f in "$SOURCE_REPO/hooks/lib"/*.sh "$SOURCE_REPO/hooks/lib"/*.json "$SOURCE_REPO/hooks/lib"/*.sql; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    printf 'hooks/lib/%s\thooks/lib/%s\n' "$base" "$base"
  done

  # skills/{brain-stem roster}/** (recursive within named dirs). Mirrors install.sh
  # Step 5: REMOVED morning-brief (R-22), adopt + infer-vault-structure (R-09),
  # architect. The onboarder skill carries its absorbed producers.
  for skill in librarian backlog-hygiene backlog-triage backlog-research onboarder govern doc-amender writer-reconciler meeting-note-ingestor mem-promote new-plan session-checkpoint; do
    d="$SOURCE_REPO/skills/$skill"
    [ -d "$d" ] || continue
    find_shipped "$d" | LC_ALL=C sort | while IFS= read -r f; do
      rel="${f#$SOURCE_REPO/}"
      printf '%s\t%s\n' "$rel" "$rel"
    done
  done

  # schemas — named .json + README.md (mirrors install.sh Step 9 list).
  # (dissolved per T-4 pillar shard / T-6 retirement scope).
  # (overlay-master, governance-action-log, vault-writers-rules, processing-rules,
  # plans-rules, writer-manifest) per-.
  # vault-writers-rules-schema, processing-rules-schema, plans-rules-schema) —
  # per-pillar schemas stay foundation-repo authoring-side as reference; bundle-slot
  # schema in foundation-master-schema.json is the canonical validation layer per
  # operator decision. Symmetric to T-2 pillar JSON repo-only pattern.
  # they are RESOLVED AT RUNTIME by shipped consumers (memory-staleness,
  # memory-globalize, rules-hygiene, hooks/lib/review-queue) at
  # $CLAUDE_HOME/schemas/... but were never shipped → schema-driven validation
  # was DEAD in production. This list MUST stay byte-mirror with install.sh
  # Step 9 (the reconciliation AC asserts every live-resolved schema is shipped).
  for s in plans-schema plan-manifest-schema librarian-manifest-schema user-manifest-schema orchestration-schema drift-allowlist-schema overlay-master-schema governance-action-log-schema writer-manifest-schema memory-schema rules-schema review-queue-schema; do
    f="$SOURCE_REPO/schemas/$s.json"
    [ -f "$f" ] || continue
    printf 'schemas/%s.json\tschemas/%s.json\n' "$s" "$s"
  done
  if [ -f "$SOURCE_REPO/schemas/README.md" ]; then
    printf 'schemas/README.md\tschemas/README.md\n'
  fi

  # onboarding/ walk DROPPED (brain-stem). The top-level onboarding/
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

  # governance/ — SELECTIVE walk mirroring install.sh Step 8.5 ship surface
  # (brain-stem). The 7 pillar *-rules.json + doc-dependencies.json + _index.json
  # stay repo-only (composed into foundation-master.json at release).
  # EXCLUDED from the walk (mirror install Step 8.5 strikes):
  #   - foundation-manifest.json (chicken-and-egg: this script generates it)
  #   - governance-action-log.jsonl (bootstrap-CREATED at Step 1.6, NOT copied;
  #     runtime-empty file, not a fingerprinted ship artifact)
  #   - librarian-capabilities/ ((a)) + onboarding-reference/ (R-20)
  d="$SOURCE_REPO/governance"
  if [ -d "$d" ]; then
    # Top-level files that ship via Step 8.5 selective copy
    for base in foundation-master.json overlay-master.json log-subtype-registry.json anchored-spoke-registry.json; do
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
    # governance/baselines/ — the shipped historical-manifest archive (T-1 /
    # can resolve the reachable historical-sha set from $CLAUDE_HOME/governance/baselines/
    # for stale-pristine-vs-edited disambiguation (-8). Members: every frozen
    # per-release manifest archive (foundation-manifest-v*.json) + README.md (self-
    # describing archive, shipped for symmetry with the other governance/ README ships;
    # the historical-sha glob in install.sh/uninstall.sh matches only foundation-manifest-v*.json,
    # so the README is never mistaken for a baseline). Append-only across releases: an
    # already-archived manifest is byte-identical (its sha never changes) so the per-file
    # ship is a clean no-op / take-new. NOT a find_shipped recursion (the dir is flat).
    if [ -d "$d/baselines" ]; then
      for f in "$d/baselines"/foundation-manifest-v*.json; do
        [ -f "$f" ] || continue
        # SELF-REFERENCE EXCLUSION (T-5): skip the archive that matches the
        # version being generated. The v<VERSION> archive is a byte-identical frozen copy
        # of THIS manifest, minted by the release-cut `cp -f` step AFTER this regen. If it
        # were listed here it would have to contain its own sha256 (circular — a file cannot
        # fingerprint itself), and a parity re-gen would never stabilize (208->209->...). The
        # archive ships starting the NEXT release. At v1.1.1 the manifest lists v1.0.2 +
        # v1.1.0 (the historical floor) and NOT v1.1.1 — clean append-only.
        if [ "${f##*/}" = "foundation-manifest-${VERSION}.json" ]; then
          continue
        fi
        rel="${f#$SOURCE_REPO/}"
        printf '%s\t%s\n' "$rel" "$rel"
      done
      if [ -f "$d/baselines/README.md" ]; then
        printf 'governance/baselines/README.md\tgovernance/baselines/README.md\n'
      fi
    fi
  fi

  # vault-init/** (recursive; T-1e NEW; install.sh Step 8.7)
  # Foundation-canonical adopter-vault seed tree mirroring the target adopter
  # vault tree EXACTLY per. Includes System Governance/ + Vault Writers/
  # + Logs/Archive/ + Meetings/ subdir scaffolds. System Backlog carryover RETIRED
  # 2026-05-22 per graduation (backlog + archive now live as librarian-emitted
  # files at ~/.claude-plans/_backlog.md + _archive.md under Plans Pillar governance).
  # cp -R wholesale matches install.sh Step 8.7 ship posture; sha256-protected baselines.
  d="$SOURCE_REPO/vault-init"
  if [ -d "$d" ]; then
    find_shipped "$d" | LC_ALL=C sort | while IFS= read -r f; do
      rel="${f#$SOURCE_REPO/}"
      printf '%s\t%s\n' "$rel" "$rel"
    done
  fi

  # templates/ — ALL top-level files (glob, not a named list). install.sh
  # Step 10 ships a named loop; this glob covers it EXACTLY (T-2
  # verified: templates/ top-level == install's 17-item list) and auto-covers
  # future templates so the fingerprint baseline can't silently drift again
  # (the named-11 list previously omitted 6 shipped templates → uninstall
  # residue). Subdirs (launchd/, settings-fragments/) handled by loops below;
  # `[ -f ]` skips them. A generator↔install parity test (T-1) will
  # catch any future divergence in either direction.
  # PATH-TRANSLATION (T-1, validation correction
  # whose installed path differs from its source path. install.sh Step 11.8
  # DIRECT-SEEDS it to $CLAUDE_HOME/.gitignore (never $CLAUDE_HOME/templates/),
  # so the manifest must baseline the TRANSLATED installed path `.gitignore`.
  # The SOURCE repo-root .gitignore remains EXCLUDED (header): the templates
  # glob is scoped to $SOURCE_REPO/templates/ and never walks the repo-root
  # .gitignore, so this translation does NOT widen/defeat that exclude.
  for f in "$SOURCE_REPO/templates"/*; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    if [ "$base" = "claude-home.gitignore" ]; then
      printf 'templates/%s\t.gitignore\n' "$base"
    else
      printf 'templates/%s\ttemplates/%s\n' "$base" "$base"
    fi
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

  # plugins/claude-mem walk DROPPED (brain-stem). claude-mem is NOT
  # bundled — it is an optional adopter-installed marketplace plugin. install.sh
  # Step 11 is dropped; there is no plugins/ ship surface to walk.
}

# --- git-INDEX mode resolver (T-2) ----------------------------------
# The recorded `.mode` MUST be the git-INDEX mode of the SOURCE file, never the
# worktree `stat` bit. A staged-uncommitted ` M` mode flip (e.g. a hook chmod'd
# 0755 on disk while the index still ships 100644) makes every worktree-reading
# tool GREEN while a 100644 hook ships DEAD — the index-mode blocker mechanism. Git
# records exactly two blob modes: 100755 (exec) -> 0755, 100644 -> 0644. We read
# `git ls-files -s -- <src_rel>` (the index) and map. Fallback to the worktree
# `stat` bit ONLY for a genuinely-untracked source (true bootstrap / a temp tree
# that was never `git add`ed) so the generator still runs there; tracked files
# are always index-truth, so manifest.mode == shipped.mode by construction.
index_mode() {
  # $1 = src_rel (repo-relative source path). Echoes a 4-digit octal mode.
  local src_rel="$1" full
  full="$(git -C "$SOURCE_REPO" ls-files -s -- "$src_rel" 2>/dev/null | awk 'NR==1{print $1}')"
  case "$full" in
    100755|120000|160000) printf '0755' ;;   # exec blob / symlink / gitlink -> 0755
    100644) printf '0644' ;;                  # non-exec blob -> 0644
    *) ;;                                     # untracked: caller falls back to stat
  esac
}

# --- emit one JSON record per file (src→{path,sha256,mode,size}) ---
emit_records() {
  local src_rel installed_rel src sha mode mode_full mode_len size
  while IFS=$'\t' read -r src_rel installed_rel; do
    [ -z "$src_rel" ] && continue
    src="$SOURCE_REPO/$src_rel"
    [ -f "$src" ] || continue
    sha="$(shasum -a 256 "$src" 2>/dev/null | awk '{print $1}')"
    # Mode = git-INDEX mode of the SOURCE file, not the worktree bit.
    mode="$(index_mode "$src_rel")"
    if [ -z "$mode" ]; then
      # Untracked source (bootstrap / temp tree): fall back to the worktree stat.
      mode_full="$(stat -f '%Op' "$src" 2>/dev/null)"
      mode_len=${#mode_full}
      if [ "$mode_len" -ge 4 ]; then
        mode="${mode_full:$((mode_len-4)):4}"
      else
        mode="$mode_full"
      fi
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

# --- T-1 parity hook: expose raw src→installed pairs for the parity test ---
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
