#!/bin/bash
# install.sh — brain-stem foundation installer
#
# Installer guards and behaviors:
#   - CLAUDE_HOME-first resolution (R-55 invariant)
#   - G1-pre 100ms preflight (no FS writes)
#   - G1-main $HOME/.claude equality gate + I-UNDERSTAND-OVERWRITE-RISK
#     sentinel + --force-install flag
#   - G2 foreign-content detector — sha256 drift in foundation files
#     against $SOURCE_REPO/governance/foundation-manifest.json baseline; refuse
#     install on drift unless --force-install + sentinel; sentinel
#     reused from G1-main if both fire in same session.
#   - G3 backup proof-of-life — --backup-dir writability + round-trip
#     test; required when destructive op pending (settings.json pre-
#     exists in $CLAUDE_HOME); validated whenever supplied.
#   - G4 vault-symlink distance check — refuse unconditionally if
#     $CLAUDE_HOME walks contain symlinks resolving under
#     ~/Documents/Obsidian Vault/. Vault-clobber protection; NO override.
#   - G5 plans-dir guard — refuse if $PLANS_HOME contains existing
#     NN-*/ plans without --retrofit-existing (waiver stub; retrofit
#     logic deferred).
#   - G8 UID-0 refuse — exit 58 if id -u == 0; NO override.
#   - G9 dry-run as default — first invocation without --apply emits
#     action-plan JSON to stdout with zero $CLAUDE_HOME writes; --apply
#     required to actually install. Posture, not refuse-gate; gate fires
#     after all pre-flight guards (G1-pre..G8 + state-classify) and
#     before Step 1 mkdir.
#   - State classification (fresh|foundation-only|mixed|user-only)
#     computed once after G2 close, before G3 gate; user-only without
#     --force-install → exit 21; recorded in provenance.
#   - --force-all flag — broader override than --force-install;
#     promotes Steps 2-10 cp -n → cp -f (foundation-known files
#     overwritten unconditionally; user-content under foundation dirs
#     still preserved naturally by walking known-name set, not all files).
#   - --no-preserve-config flag — explicit claude-mem preservation
#     waiver per the claude-mem preservation policy; requires
#     --force-install (exit 11 if missing). Defaults OFF.
#   - G10 provenance-write failure → exit 11 (enforced at the log_path
#     write site).
#   - 14-asset write-sequence
#   - LABEL_PREFIX=com.brain-stem preserved via cp -R installer/ +
#     templates/launchd/ (G6 namespace isolation, transitively)
#   - settings.json atomic jq-merge with G7 silent-key-deletion gate
#   - governance/foundation-manifest.json baseline copy (generator output;
#     consumed by G2 detector + uninstall fingerprint match; lives alongside
#     foundation-master.json)
#
# DEFERRED to future releases:
#   - G6 install-side label sentinel (transitively preserved via cp -R
#     installer/; render-launchd.sh enforces at runtime)
#   - claude-mem preservation policy full implementation (must bundle
#     plugins/claude-mem/v<VERSION>/ first; install.sh
#     tolerates absence with informational log + flag matrix wired)
#   - Top-level exit code 20 (conflict-manifest workflow; rsync
#     backup-before-merge surface)
#   - Top-level exit code 22 (rsync-backup actual failure; surface
#     distinct from G3's prove-the-destination-works check at exit 53)
#   - Top-level exit code 60 (grep-audit hit on installed tree;
#     consumer integration of tools/grep-audit.sh)
#
# Exit codes:
#   0   success (includes G9 dry-run JSON emit)
#   10  prereq missing (CLAUDE_HOME unset/empty per G1-pre; required binary
#                       absent; SOURCE_REPO not a foundation-repo)
#   11  permission/write failure (includes G10 provenance-write failure;
#                       --no-preserve-config without --force-install)
#   21  state=user-only without --force-install ($CLAUDE_HOME contains
#       only non-foundation content; refuses to risk overwriting an
#       unrelated installation)
#   30  schema parse failure (post-install)
#   40  settings.json merge conflict requires human resolution (jq error)
#   51  G1-main fired ($HOME/.claude equality + non-foundation content,
#       missing --force-install or I-UNDERSTAND-OVERWRITE-RISK sentinel)
#   52  G2 fired (foreign-content sha256 drift in foundation files,
#       missing --force-install or I-UNDERSTAND-OVERWRITE-RISK sentinel)
#   53  G3 fired (backup proof-of-life: --backup-dir absent when
#       destructive op pending; or supplied --backup-dir not writable
#       or round-trip-broken)
#   54  G4 fired (vault-symlink reachable under $CLAUDE_HOME; no override)
#   55  G5 fired ($PLANS_HOME contains NN-*/ plans without
#       --retrofit-existing)
#   57  G7 fired (settings.json merge would silently delete keys)
#   58  G8 fired (UID 0; no override)
#   59  G9 RESERVED — dry-run default is the posture (not refuse-gate);
#       --apply required to leave dry-run. 59 is allocated per spec but
#       cannot fire under current implementation (any dry-run violation
#       would be a code-tampering condition).
#
# R-23 bash 3.2 compat. R-37 single-deliverable. R-55 zero $HOME/.claude
# resolution paths in script body (literal $HOME/.claude appears only in
# the AC #1 / G1-pre user-facing error text per spec.md L74 and the G1-main
# string-equality comparison per spec.md L75). G4 resolves $HOME/Documents/
# Obsidian Vault/ as a DETECTION target only — never a write target.

set -u

# --- diagnostics ---
# info() routes to stderr in dry-run mode (APPLY_MODE=0) so the G9 action-plan
# JSON on stdout stays valid for jq parsing. In --apply mode, info() goes to
# stdout per the existing test contract (install-g1 T3.2 stdout grep
# "sentinel verified"; install-g2 T3.2 "G2 sentinel verified"; install-g3-g10
# T1.2 "G3: backup proof-of-life passed").
diag() { printf 'install FAIL: %s\n' "$1" >&2; }
info() {
  if [ "${APPLY_MODE:-0}" = "0" ]; then
    printf 'install: %s\n' "$1" >&2
  else
    printf 'install: %s\n' "$1"
  fi
}
warn() { printf 'install WARN: %s\n' "$1" >&2; }

# --- argv parse (in-memory only; no FS; pre-G1-pre to keep 100ms bound) ---
FORCE_INSTALL=0
FORCE_ALL=0
NO_PRESERVE_CONFIG=0
APPLY_MODE=0
BACKUP_DIR=""
RETROFIT_EXISTING=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)                APPLY_MODE=1 ;;
    --force-install)        FORCE_INSTALL=1 ;;
    --force-all)            FORCE_ALL=1 ;;
    --no-preserve-config)   NO_PRESERVE_CONFIG=1 ;;
    --backup-dir)           shift; BACKUP_DIR="${1:-}" ;;
    --backup-dir=*)         BACKUP_DIR="${1#--backup-dir=}" ;;
    --retrofit-existing)    RETROFIT_EXISTING=1 ;;
    *)                      ;;
  esac
  shift
done

# --- flag mutual-exclusion (claude-mem preservation policy) ---
# --no-preserve-config requires --force-install. Pre-flight refuse — fires
# before any guard / FS work. Exit 11 (permission/write failure family;
# argv-mismatch precondition for the destructive claude-mem path).
if [ "$NO_PRESERVE_CONFIG" = "1" ] && [ "$FORCE_INSTALL" != "1" ]; then
  diag "--no-preserve-config requires --force-install (gating prevents accidental claude-mem config clobber). Pass both flags together."
  exit 11
fi

# --- sentinel-verified flag (G1-main + G2 share single ceremony) ---
# Set to 1 after the first successful I-UNDERSTAND-OVERWRITE-RISK prompt; later
# guards consult it to avoid re-prompting in the same install invocation.
sentinel_verified=0

# --- G8: UID-0 refuse ---
# Fires before any FS work or env evaluation. Unconditional — no --force override.
# Root context broadens blast radius irreversibly (vault-clobber protection).
g8_uid="$(id -u 2>/dev/null || echo unknown)"
if [ "$g8_uid" = "0" ]; then
  diag "G8 fired: install.sh refuses to run as UID 0 (root). Re-run as a non-root user."
  exit 58
fi

# --- G1-pre: CLAUDE_HOME unset/empty preflight ---
# Fires BEFORE binary check / SOURCE_REPO resolve / any mkdir. No FS writes.
# Acceptance: headless exit within 100ms.
#
# Mode-split:
#   --apply lane: the safety hard-fail STILL bites VERBATIM (exit 10) on unset
#     CLAUDE_HOME — the blast-radius containment happens exactly where mutation
#     happens (fail-OPEN preserved; no new fail-CLOSED deny introduced).
#   DRY-RUN lane: the documented adopter command `bash install.sh` (CLAUDE_HOME
#     unset) defaults CLAUDE_HOME="$HOME/.claude" — the install-convention
#     fallback (${CLAUDE_HOME:-$HOME/.claude}) — so the action-plan preview emits
#     write-free (the dry-run branch exits 0 BEFORE the first mkdir,
#     provably write-free). The default is announced to STDERR via info()
#     (stdout stays jq-valid for the G9 action-plan) and recorded in the
#     claude_home_defaulted flag emitted as a G9 field.
# R-37 lockstep: the KEEP-AS-IS hard-fail is narrowed to the --apply lane.
claude_home_defaulted=0
if [ -z "${CLAUDE_HOME:-}" ]; then
  if [ "$APPLY_MODE" = "1" ]; then
    diag "CLAUDE_HOME not set. Export CLAUDE_HOME=\$HOME/.claude or a custom path before running install.sh. Never rely on \$HOME/.claude implicit default — hard-fail is required for installer safety."
    exit 10
  fi
  CLAUDE_HOME="$HOME/.claude"
  claude_home_defaulted=1
  info "CLAUDE_HOME not set; dry-run defaulting to \$HOME/.claude ($CLAUDE_HOME) for the action-plan preview (install-convention fallback). --apply requires CLAUDE_HOME to be set explicitly."
fi

# --- prereq binary check ---
# sqlite3 + shasum are required by lib/manifest-record.sh init
# (manifest.sqlite bootstrap at Step 1.6 below). Both ship by default on
# macOS; failing fast here is clearer than failing inside the bootstrap call.
for bin in jq python3 plutil sqlite3 shasum; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    diag "missing prereq binary: $bin"
    exit 10
  fi
done

# --- resolve foundation-repo source ---
# install.sh lives at top of foundation-repo. SOURCE_REPO env-overridable for
# tests; default = directory containing this script.
script_path="${BASH_SOURCE[0]:-$0}"
script_dir="$(cd "$(dirname "$script_path")" && pwd)"
SOURCE_REPO="${SOURCE_REPO:-$script_dir}"

if [ ! -d "$SOURCE_REPO/hooks" ] || [ ! -d "$SOURCE_REPO/skills" ] || [ ! -d "$SOURCE_REPO/schemas" ]; then
  diag "SOURCE_REPO does not look like a foundation-repo (missing hooks/, skills/, or schemas/): $SOURCE_REPO"
  exit 10
fi

# --- G5: $PLANS_HOME plan-dir guard ---
# Refuse if $PLANS_HOME contains existing NN-*/ plans without
# --retrofit-existing. Foundation ships zero plans; the flag is currently a
# v2.1 waiver stub (no retrofit logic implemented) but the gate is
# load-bearing — without it, an install onto a pre-existing plan-tracking
# tree would be silently underspecified.
PLANS_HOME="${PLANS_HOME:-$HOME/.claude-plans}"
g5_existing_plans=""
g5_existing_count=0
if [ -d "$PLANS_HOME" ]; then
  for entry in "$PLANS_HOME"/[0-9][0-9]-*/; do
    [ -d "$entry" ] || continue
    base="${entry%/}"
    base="${base##*/}"
    if [ -z "$g5_existing_plans" ]; then
      g5_existing_plans="$base"
    else
      g5_existing_plans="$g5_existing_plans
$base"
    fi
    g5_existing_count=$((g5_existing_count + 1))
  done
fi
if [ "$g5_existing_count" -gt 0 ]; then
  if [ "$RETROFIT_EXISTING" != "1" ]; then
    diag "G5 fired: \$PLANS_HOME contains $g5_existing_count existing NN-*/ plan(s); pass --retrofit-existing to acknowledge (v2.1 retrofit logic deferred — flag currently waives only). \$PLANS_HOME=$PLANS_HOME"
    printf '%s\n' "$g5_existing_plans" | while IFS= read -r p; do
      [ -z "$p" ] || printf '  %s\n' "$p" >&2
    done
    exit 55
  fi
  warn "G5: --retrofit-existing supplied with $g5_existing_count pre-existing plan(s); v2.1 retrofit logic NOT YET IMPLEMENTED — flag is a waiver stub. Proceeding under explicit user waiver; install does not modify \$PLANS_HOME."
fi

# --- G1-main: $HOME/.claude equality gate (AC #3; spec.md L75) ---
# Refuse if $CLAUDE_HOME == $HOME/.claude AND target exists with non-foundation
# content, unless --force-install AND I-UNDERSTAND-OVERWRITE-RISK sentinel typed.
# String comparison (not resolution) per R-55 carve-out.
foundation_known_entries="hooks skills schemas onboarding orchestrator templates plugins Library installer logs governance vault-init settings.json settings.local.json CLAUDE.md projects"

g1_main_has_non_foundation_content() {
  local d="$1"
  [ -d "$d" ] || return 1
  local entry base known found
  for entry in "$d"/* "$d"/.[!.]*; do
    [ -e "$entry" ] || continue
    base="${entry##*/}"
    found=0
    for known in $foundation_known_entries; do
      if [ "$base" = "$known" ]; then
        found=1
        break
      fi
    done
    if [ "$found" = "0" ]; then
      return 0
    fi
  done
  return 1
}

if [ "$CLAUDE_HOME" = "$HOME/.claude" ] && [ -d "$CLAUDE_HOME" ]; then
  if g1_main_has_non_foundation_content "$CLAUDE_HOME"; then
    if [ "$FORCE_INSTALL" != "1" ]; then
      diag "G1-main fired: \$CLAUDE_HOME equals \$HOME/.claude AND target contains non-foundation content. Pass --force-install AND type I-UNDERSTAND-OVERWRITE-RISK sentinel to proceed (vault-clobber protection)."
      exit 51
    fi
    printf 'install: type I-UNDERSTAND-OVERWRITE-RISK to confirm: ' >&2
    sentinel=""
    if ! IFS= read -r sentinel; then
      diag "G1-main fired: sentinel not provided (stdin EOF). Aborting."
      exit 51
    fi
    if [ "$sentinel" != "I-UNDERSTAND-OVERWRITE-RISK" ]; then
      diag "G1-main fired: sentinel mismatch. Expected literal 'I-UNDERSTAND-OVERWRITE-RISK'. Aborting."
      exit 51
    fi
    sentinel_verified=1
    info "G1-main sentinel verified; proceeding under --force-install"
  fi
fi

# --- G4: vault-symlink distance check ---
# If ~/Documents/Obsidian Vault/ is reachable via symlink under $CLAUDE_HOME,
# refuse unconditionally. Vault-clobber protection: if the vault is symlinked
# into .claude (e.g. Plans/ → vault/Plans), a bootstrap could clobber the vault.
# NO override. Detection-only path resolution; never a write target.
g4_vault_canonical=""
if [ -d "$HOME/Documents/Obsidian Vault" ]; then
  g4_vault_canonical="$(cd "$HOME/Documents/Obsidian Vault" 2>/dev/null && pwd -P)"
fi
g4_violations=""
g4_violation_count=0
if [ -n "$g4_vault_canonical" ] && [ -d "$CLAUDE_HOME" ]; then
  while IFS= read -r symlink; do
    [ -z "$symlink" ] && continue
    resolved="$(readlink -f "$symlink" 2>/dev/null || true)"
    [ -z "$resolved" ] && continue
    case "$resolved" in
      "$g4_vault_canonical"|"$g4_vault_canonical"/*)
        if [ -z "$g4_violations" ]; then
          g4_violations="$symlink -> $resolved"
        else
          g4_violations="$g4_violations
$symlink -> $resolved"
        fi
        g4_violation_count=$((g4_violation_count + 1))
        ;;
    esac
  done <<EOF
$(find "$CLAUDE_HOME" -type l 2>/dev/null)
EOF
fi
if [ "$g4_violation_count" -gt 0 ]; then
  diag "G4 fired: \$CLAUDE_HOME contains $g4_violation_count symlink(s) reaching ~/Documents/Obsidian Vault/. Vault-clobber protection — refuse unconditionally (no --force override)."
  printf '%s\n' "$g4_violations" | while IFS= read -r v; do
    [ -z "$v" ] || printf '  %s\n' "$v" >&2
  done
  exit 54
fi

info "CLAUDE_HOME=$CLAUDE_HOME"
info "SOURCE_REPO=$SOURCE_REPO"

# --- state-tier env-var resolution (two-root topology) ---
# $VAULT_WRITER_STATE_ROOT default ~/.local/share/brain-stem/vault-writers/
#   Durable second-brain artifacts (manifest.sqlite, raw retention,
#   daily-processing, per-writer history). XDG-compliant; backup-included by
#   Time Machine/restic defaults via ~/.local/share/.
# $CLAUDE_STATE_ROOT default ~/.local/state/brain-stem/
#   Ephemeral Claude-runtime (staging packets, locks, queues). Rebuildable.
# Decision rule: "would this survive a Claude reinstall + harness
#   switch?" YES → $VAULT_WRITER_STATE_ROOT; NO → $CLAUDE_STATE_ROOT.
# Overrides honored when exported pre-invocation; defaults applied when unset.
VAULT_WRITER_STATE_ROOT="${VAULT_WRITER_STATE_ROOT:-$HOME/.local/share/brain-stem/vault-writers}"
CLAUDE_STATE_ROOT="${CLAUDE_STATE_ROOT:-$HOME/.local/state/brain-stem}"
info "VAULT_WRITER_STATE_ROOT=$VAULT_WRITER_STATE_ROOT"
info "CLAUDE_STATE_ROOT=$CLAUDE_STATE_ROOT"

# --- G2: foreign-content detector (installer firewall guard) ---
# Walks $CLAUDE_HOME for files inside foundation-known directories whose
# relative path is tracked by $SOURCE_REPO/governance/foundation-manifest.json
# baseline but whose actual sha256 differs (drift). Files NOT in baseline (user
# content under a foundation directory; hooks/state/ session files; etc.)
# are not violations — cp -n preserves them naturally.
#
# Refuses install on any violation unless --force-install AND
# I-UNDERSTAND-OVERWRITE-RISK sentinel typed (sentinel reused from G1-main if
# both fire in the same session; single ceremony per session).
#
# Skip conditions (G2 is a no-op):
#   - $CLAUDE_HOME does not exist (fresh install, mkdir-p ahead)
#   - $SOURCE_REPO/governance/foundation-manifest.json absent (baseline not
#     yet generated; warns; cannot compare without baseline)
#   - jq extraction failure (warns; degrade-open rather than wedge install)
#
# The manifest lives at $SOURCE_REPO/governance/ next to
# foundation-master.json + overlay-master.json.
g2_violations=""
g2_violation_count=0

g2_detect_foreign_content() {
  local manifest_src="$SOURCE_REPO/governance/foundation-manifest.json"

  if [ ! -f "$manifest_src" ]; then
    info "G2: governance/foundation-manifest.json absent at SOURCE_REPO; foreign-content detection skipped"
    return 0
  fi
  if [ ! -d "$CLAUDE_HOME" ]; then
    return 0
  fi

  local baseline_tmp
  baseline_tmp="$(mktemp -t install-g2-baseline.XXXXXX 2>/dev/null)" || {
    warn "G2: tmp allocation failed; foreign-content detection skipped"
    return 0
  }
  if ! jq -r '.files[] | "\(.path)\t\(.sha256)"' "$manifest_src" > "$baseline_tmp" 2>/dev/null; then
    warn "G2: governance/foundation-manifest.json files[] extraction failed; foreign-content detection skipped"
    rm -f "$baseline_tmp"
    return 0
  fi

  local entry base known found f rel sha_actual sha_baseline
  for entry in "$CLAUDE_HOME"/* "$CLAUDE_HOME"/.[!.]*; do
    [ -e "$entry" ] || continue
    base="${entry##*/}"
    found=0
    for known in $foundation_known_entries; do
      if [ "$base" = "$known" ]; then
        found=1
        break
      fi
    done
    [ "$found" = "0" ] && continue          # non-foundation entry (G1-main domain)
    [ -d "$entry" ] || continue              # only walk directories
    [ "$base" = "logs" ] && continue         # logs/ is append-only provenance

    while IFS= read -r f; do
      [ -z "$f" ] && continue
      rel="${f#$CLAUDE_HOME/}"
      sha_baseline="$(awk -F'\t' -v p="$rel" '$1 == p {print $2; exit}' "$baseline_tmp")"
      [ -z "$sha_baseline" ] && continue   # not in baseline = user content
      sha_actual="$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')"
      if [ "$sha_actual" != "$sha_baseline" ]; then
        if [ -z "$g2_violations" ]; then
          g2_violations="$rel"
        else
          g2_violations="$g2_violations
$rel"
        fi
        g2_violation_count=$((g2_violation_count + 1))
      fi
    done <<EOF
$(find "$entry" -type f 2>/dev/null)
EOF
  done

  rm -f "$baseline_tmp"
}

g2_detect_foreign_content

if [ "$g2_violation_count" -gt 0 ]; then
  diag "G2 fired: foreign content (sha256 drift) detected in $g2_violation_count foundation file(s):"
  printf '%s\n' "$g2_violations" | while IFS= read -r p; do
    [ -z "$p" ] || printf '  %s\n' "$p" >&2
  done
  if [ "$FORCE_INSTALL" != "1" ]; then
    diag "Pass --force-install AND type I-UNDERSTAND-OVERWRITE-RISK sentinel to proceed (cp -n preserves your edits; vault-clobber protection)."
    exit 52
  fi
  if [ "$sentinel_verified" = "1" ]; then
    info "G2: sentinel reused from G1-main; proceeding under --force-install"
  else
    printf 'install: type I-UNDERSTAND-OVERWRITE-RISK to confirm G2 override: ' >&2
    sentinel=""
    if ! IFS= read -r sentinel; then
      diag "G2 fired: sentinel not provided (stdin EOF). Aborting."
      exit 52
    fi
    if [ "$sentinel" != "I-UNDERSTAND-OVERWRITE-RISK" ]; then
      diag "G2 fired: sentinel mismatch. Expected literal 'I-UNDERSTAND-OVERWRITE-RISK'. Aborting."
      exit 52
    fi
    sentinel_verified=1
    info "G2 sentinel verified; proceeding under --force-install"
  fi
fi

# --- State classification (exit code 21) ---
# Walks $CLAUDE_HOME entries and classifies state once after G2 close + before
# G3 gate. Reuses foundation_known_entries set already declared at L172 for
# basename matching.
#   - fresh             — $CLAUDE_HOME does not exist OR exists but is empty
#   - foundation-only   — every top-level entry matches foundation-known set
#   - mixed             — at least one foundation entry + at least one non-
#                          foundation entry (cp -n preserves non-foundation;
#                          proceeds normally)
#   - user-only         — at least one entry, NONE matches foundation-known
#                          (refuse without --force-install → exit 21)
# user-only is a vault-clobber-class protection: $CLAUDE_HOME pointed at
# someone else's installation. G1-main covers the $HOME/.claude case at 51;
# state-classify covers any $CLAUDE_HOME-equal-to-non-foundation-tree at 21.
state_classification="unknown"
if [ ! -d "$CLAUDE_HOME" ]; then
  state_classification="fresh"
else
  # Walk NON-HIDDEN top-level entries only. Foundation has zero top-level
  # dotfiles; hidden entries are typically user config / test artifacts /
  # transient redirects, NOT a separate installation. G1-main retains its
  # broader dotfile walk for the more targeted $HOME/.claude protection (51);
  # state-classify is the looser non-$HOME/.claude protection (21).
  state_has_foundation=0
  state_has_non_foundation=0
  state_has_any=0
  state_non_foundation_list=""
  for entry in "$CLAUDE_HOME"/*; do
    [ -e "$entry" ] || continue
    state_has_any=1
    base="${entry##*/}"
    matched=0
    for known in $foundation_known_entries; do
      if [ "$base" = "$known" ]; then
        matched=1
        break
      fi
    done
    if [ "$matched" = "1" ]; then
      state_has_foundation=1
    else
      state_has_non_foundation=1
      if [ -z "$state_non_foundation_list" ]; then
        state_non_foundation_list="$base"
      else
        state_non_foundation_list="$state_non_foundation_list
$base"
      fi
    fi
  done
  if [ "$state_has_any" = "0" ]; then
    state_classification="fresh"
  elif [ "$state_has_foundation" = "1" ] && [ "$state_has_non_foundation" = "0" ]; then
    state_classification="foundation-only"
  elif [ "$state_has_foundation" = "0" ] && [ "$state_has_non_foundation" = "1" ]; then
    state_classification="user-only"
  else
    state_classification="mixed"
  fi
fi

if [ "$state_classification" = "user-only" ] && [ "$FORCE_INSTALL" != "1" ]; then
  diag "state=user-only fired: \$CLAUDE_HOME contains only non-foundation content; pass --force-install to acknowledge installer is overwriting a non-foundation tree (vault-clobber-class protection — distinct from G1-main \$HOME/.claude equality at 51). Non-foundation entries:"
  printf '%s\n' "$state_non_foundation_list" | while IFS= read -r p; do
    [ -z "$p" ] || printf '  %s\n' "$p" >&2
  done
  exit 21
fi
info "state classification: $state_classification"

# --- G3: backup proof-of-life ---
# Last gate before destructive ops (Step 12 settings.json mv -f). Two trigger
# conditions:
#   (a) --backup-dir supplied → validate writability + round-trip regardless
#       of destructive-op state (catches typos / unwritable paths early).
#   (b) destructive op pending ($CLAUDE_HOME/settings.json pre-exists) AND
#       --backup-dir absent → exit 53 (no backup → no install).
# Fresh install (no settings.json yet) without --backup-dir is a no-op
# (cp -n preserves all other files; mkdir -p is idempotent).
g3_destructive_op_pending=0
if [ -f "$CLAUDE_HOME/settings.json" ]; then
  g3_destructive_op_pending=1
fi
g3_proof_of_life_passed=0
g3_skip_reason=""
if [ -n "$BACKUP_DIR" ]; then
  if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
    diag "G3 fired: --backup-dir not creatable: $BACKUP_DIR"
    exit 53
  fi
  g3_test_file="$BACKUP_DIR/.install-g3-proof-$$"
  if ! ( printf 'g3-roundtrip\n' > "$g3_test_file" ) 2>/dev/null; then
    diag "G3 fired: --backup-dir not writable (round-trip test failed): $BACKUP_DIR"
    rm -f "$g3_test_file" 2>/dev/null
    exit 53
  fi
  if [ ! -f "$g3_test_file" ] || [ "$(cat "$g3_test_file" 2>/dev/null)" != "g3-roundtrip" ]; then
    diag "G3 fired: --backup-dir round-trip readback mismatch: $BACKUP_DIR"
    rm -f "$g3_test_file" 2>/dev/null
    exit 53
  fi
  rm -f "$g3_test_file" 2>/dev/null
  g3_proof_of_life_passed=1
  info "G3: backup proof-of-life passed at $BACKUP_DIR"
elif [ "$g3_destructive_op_pending" = "1" ]; then
  diag "G3 fired: \$CLAUDE_HOME/settings.json pre-exists (destructive op pending); --backup-dir <path> required for proof-of-life. No backup → no install."
  exit 53
else
  g3_skip_reason="no destructive op pending (no pre-existing settings.json) and --backup-dir not supplied"
fi

# --- G9: dry-run as default (S66; spec.md L83) ---
# Posture (not refuse-gate). First invocation without --apply emits action-plan
# JSON to stdout with zero $CLAUDE_HOME writes; --apply required to actually
# install. Position: G9 fires AFTER all pre-flight guards (G1-pre, G8, G1-main,
# G4, G2, state-classify, G3) but BEFORE Step 1 mkdir — the action-plan
# reflects state validated by every guard. NO --force override (G9 is posture,
# not refuse). Exit 0 from dry-run; provenance log NOT written (zero FS
# writes by design).
if [ "$APPLY_MODE" != "1" ]; then
  # JSON action-plan emit. Validity contract: jq parseable. Schema:
  #   {version, claude_home, claude_home_defaulted, source_repo,
  #    state_classification, flags{...}, guards_passed[],
  #    actions[{step, op, target, source, rationale}], deferred[]}
  # claude_home_defaulted: 1 when CLAUDE_HOME was unset and
  # the dry-run defaulted it to $HOME/.claude; 0 when set
  # explicitly. Informational, not a gate.
  cat <<JSON
{
  "version": "1",
  "claude_home": "$CLAUDE_HOME",
  "claude_home_defaulted": $claude_home_defaulted,
  "source_repo": "$SOURCE_REPO",
  "state_classification": "$state_classification",
  "flags": {
    "force_install": $FORCE_INSTALL,
    "force_all": $FORCE_ALL,
    "no_preserve_config": $NO_PRESERVE_CONFIG,
    "retrofit_existing": $RETROFIT_EXISTING,
    "backup_dir": "${BACKUP_DIR:-}"
  },
  "guards_passed": ["G1-pre", "G1-main", "G2", "G3", "G4", "G5", "G7", "G8"],
  "actions": [
    {"step": 1, "op": "mkdir", "target": "$CLAUDE_HOME/{hooks,hooks/lib,hooks/state,hooks/config,skills,schemas,orchestrator,templates,templates/launchd,templates/settings-fragments,Library/LaunchAgents.staging,installer,logs,governance,governance/file-type-contracts,vault-init}", "rationale": "create target tree: NO plugins/, NO onboarding/ (dissolved into skills/onboarder/), NO governance/{librarian-capabilities,onboarding-reference}/ (R-20)"},
    {"step": 1.5, "op": "mkdir", "target": "$VAULT_WRITER_STATE_ROOT/{,daily-processing,raw,staging} + $CLAUDE_STATE_ROOT/{,vault-staging,vault-staging/_archive,.coordination,sessions}", "rationale": "two-root state-tier scaffold: durable second-brain root + ephemeral Claude-runtime root incl .coordination/ + sessions/. NO ~/.claude/state back-compat symlink (fresh lineage)"},
    {"step": 1.6, "op": "sqlite-bootstrap+touch", "target": "$VAULT_WRITER_STATE_ROOT/manifest.sqlite + $CLAUDE_HOME/governance/governance-action-log.jsonl", "source": "$SOURCE_REPO/hooks/lib/manifest-record.sh init (graceful-degrade if absent)", "rationale": "manifest.sqlite re-rooted to the state-tier path. governance-action-log.jsonl bootstrap-CREATED under $CLAUDE_HOME/governance/ (bootstrap-not-copy)"},
    {"step": 1.7, "op": "DROPPED", "rationale": "meeting-processor-state migration struck (hardcoded live author-vault path; fresh-install no-op; brain-stem ships no meeting-processor)"},
    {"step": 2, "op": "cp", "target": "$CLAUDE_HOME/hooks/", "source": "$SOURCE_REPO/hooks/{*.sh,*.md,MANIFEST.txt}", "rationale": "ship hook entry-points + MANIFEST"},
    {"step": 3, "op": "cp", "target": "$CLAUDE_HOME/hooks/lib/", "source": "$SOURCE_REPO/hooks/lib/{*.sh,*.json,*.sql}", "rationale": "ship hook libs (hooks/lib/ is the SOLE lib surface; no lib/→hooks/lib/ translation)"},
    {"step": 4, "op": "cp", "target": "$CLAUDE_HOME/hooks/config/", "source": "$SOURCE_REPO/hooks/config/", "rationale": "ship hook config JSON (graceful-skip if absent)"},
    {"step": 5, "op": "cp", "target": "$CLAUDE_HOME/skills/", "source": "$SOURCE_REPO/skills/{brain-stem roster}/", "rationale": "ship brain-stem foundation skill subtrees: librarian, backlog-{hygiene,triage,research}, onboarder (+absorbed producers), govern, doc-amender, writer-reconciler, meeting-note-ingestor, mem-promote, new-plan (R-11), session-checkpoint"},
    {"step": 6, "op": "DISSOLVED", "rationale": "top-level onboarding/ dissolved into skills/onboarder/; producers ride Step 5 cp -R"},
    {"step": 7, "op": "cp", "target": "$CLAUDE_HOME/orchestrator/", "source": "$SOURCE_REPO/orchestrator/", "rationale": "ship orchestrator subtree (--plan route retained; dispatch.sh keeps --job|--cron|--batch|--plan)"},
    {"step": 8, "op": "cp", "target": "$CLAUDE_HOME/installer/", "source": "$SOURCE_REPO/installer/", "rationale": "ship installer subtree (LABEL_PREFIX com.brain-stem preserved transitively via render-launchd.sh)"},
    {"step": 8.5, "op": "cp-selective", "target": "$CLAUDE_HOME/governance/", "source": "$SOURCE_REPO/governance/ (selective)", "rationale": "selective copy: foundation-master + overlay-master + foundation-manifest + log-subtype-registry + file-type-contracts/ (12). governance-action-log.jsonl is bootstrap-created at Step 1.6 (not copied). NOT shipped: librarian-capabilities/, onboarding-reference/ (R-20). 7 pillar JSONs + _index.json stay repo-only"},
    {"step": 8.7, "op": "cp", "target": "$CLAUDE_HOME/vault-init/", "source": "$SOURCE_REPO/vault-init/", "rationale": "ship vault-init/ seed tree. The per-plan satellite is retired (not in the ship surface). Welcome.md absent. sha256-protected via governance/foundation-manifest.json"},
    {"step": 9, "op": "cp", "target": "$CLAUDE_HOME/schemas/", "source": "$SOURCE_REPO/schemas/{10 adopter}.json", "rationale": "ship the 10 adopter schemas + README. The 7 repo-only schemas (foundation-master, vault-writers-rules, processing-rules, plans-rules, doc-dependencies, memory-schema, rules-schema) stay authoring-side"},
    {"step": 10, "op": "cp", "target": "$CLAUDE_HOME/templates/", "source": "$SOURCE_REPO/templates/{settings,2 CLAUDE.md,MEMORY,rules-readme,plan/capture templates,handoff}+{launchd,settings-fragments}/", "rationale": "ship templates + launchd tmpl + settings-fragments. The 2 CLAUDE.md templates ship sha256-protected; onboarder author-claude-home.sh consumes — NOT install-seeded"},
    {"step": 11, "op": "DROPPED", "rationale": "claude-mem NOT bundled (adopter-installed via marketplace); plugins/ + false README gone"},
    {"step": 11.5, "op": "DROPPED", "rationale": "global CLAUDE.md pre-seed struck; skills/onboarder/scripts/author-claude-home.sh is the authoritative writer"},
    {"step": 12, "op": "jq-merge", "target": "$CLAUDE_HOME/settings.json", "source": "$CLAUDE_HOME/templates/settings.json", "rationale": "atomic deep-merge with G7 silent-key-deletion gate (template adds AskUserQuestion matcher entry; re-install propagation handled at Step 12.6)"},
    {"step": 12.6, "op": "jq-register", "target": "$CLAUDE_HOME/settings.json", "rationale": "idempotent post-merge registration of AskUserQuestion matcher → pre-asq-guard.sh. Step 12.5 precedent for the same problem class: jq deep-merge (template * user) lets user PreToolUse array win on array conflicts; re-installs against an adopter without the matcher would silently drop it. Detects absence + appends; presence is a no-op (idempotent)."},
    {"step": 13, "op": "validate", "target": "$CLAUDE_HOME/schemas/*.json", "rationale": "post-install schema parse validation"},
    {"step": 13.5, "op": "validate", "target": "$CLAUDE_HOME/governance/foundation-manifest.json", "rationale": "parse-validate baseline post-Step-8.5-copy (load-bearing for G2 + uninstall fingerprint match); lives at governance/"},
    {"step": 15, "op": "log", "target": "$CLAUDE_HOME/logs/install-*.log", "rationale": "G10 provenance log header emit"}
  ],
  "deferred": ["G6-install-side-explicit-sentinel", "20-conflict-manifest-v2.1", "22-rsync-backup-v2.1", "60-grep-audit-consumer-v2.1"]
}
JSON
  exit 0
fi

# --- 14-asset write sequence (per spec.md L240-255 audit-2026-04-29) ---

# cp clobber posture (S66): default --force-all=0 → cp -n (no clobber, preserves
# user-edited foundation files; G2 baseline-mismatch covers drift detection).
# --force-all=1 → cp -f (overwrite foundation-known files unconditionally).
# claude-mem at Step 11 has its own clobber posture per --no-preserve-config.
cp_clobber="-n"
[ "$FORCE_ALL" = "1" ] && cp_clobber="-f"

# Step 1: mkdir -p target tree (brain-stem layout)
# Dropped dirs: plugins/ (claude-mem not bundled),
# onboarding/ (dissolved into skills/onboarder/),
# governance/librarian-capabilities/, governance/onboarding-reference/ (R-20).
target_dirs="hooks hooks/lib hooks/state hooks/config skills schemas orchestrator templates templates/launchd templates/settings-fragments Library/LaunchAgents.staging installer logs governance governance/file-type-contracts vault-init"
for d in $target_dirs; do
  mkdir -p "$CLAUDE_HOME/$d" || { diag "mkdir failed: $CLAUDE_HOME/$d"; exit 11; }
done

# Step 1.5: state-tier scaffold (two-root topology)
# Creates the two state roots + subdirectory scaffolds OUTSIDE $CLAUDE_HOME.
# Env vars resolved earlier; defaults honor XDG ~/.local/share/ +
# ~/.local/state/ conventions.
#
# Subdirectories:
#   $VAULT_WRITER_STATE_ROOT/                 durable root
#   $VAULT_WRITER_STATE_ROOT/daily-processing/ empty; reconciler creates
#                                              per-day subdirs at runtime
#   $VAULT_WRITER_STATE_ROOT/raw/             raw retention;
#                                              mandatory for writer_kind ∈
#                                              {agentic-flow, auto-research}
#   $CLAUDE_STATE_ROOT/                       ephemeral root
#   $CLAUDE_STATE_ROOT/vault-staging/         staging area
#   $CLAUDE_STATE_ROOT/vault-staging/_archive/ empty
#
# Idempotent: mkdir -p tolerates existing dirs (re-install safe).
#
# Two-root state scaffold:
#   DURABLE  $VAULT_WRITER_STATE_ROOT (~/.local/share/brain-stem/vault-writers)
#            + daily-processing/ + raw/ + staging/
#   EPHEMERAL $CLAUDE_STATE_ROOT (~/.local/state/brain-stem)
#            + vault-staging/_archive/ + .coordination/ (machine-local
#            multi-session registry + the four lockf locks) + sessions/
#            (per-session checkpoint dirs consumed by registry.sh / paths.sh).
state_tier_dirs="$VAULT_WRITER_STATE_ROOT $VAULT_WRITER_STATE_ROOT/daily-processing $VAULT_WRITER_STATE_ROOT/raw $VAULT_WRITER_STATE_ROOT/staging $CLAUDE_STATE_ROOT $CLAUDE_STATE_ROOT/vault-staging $CLAUDE_STATE_ROOT/vault-staging/_archive $CLAUDE_STATE_ROOT/.coordination $CLAUDE_STATE_ROOT/sessions"
for d in $state_tier_dirs; do
  mkdir -p "$d" || { diag "state-tier mkdir failed: $d"; exit 11; }
done

# No $CLAUDE_HOME/state back-compat symlink. brain-stem is a fresh-lineage
# install — there is no prior ~/.claude/state/ real directory to bridge. The
# two-root scaffold above is the sole state tier; consumers resolve
# $CLAUDE_STATE_ROOT via hooks/lib/paths.sh, never through a ~/.claude/state shim.

# Step 1.6: manifest.sqlite bootstrap
# Bootstraps the writer-manifest SQLite substrate at
# $VAULT_WRITER_STATE_ROOT/manifest.sqlite via lib/manifest-record.sh init
# subcommand. Applies lib/manifest-migrate.sql DDL: single denormalized 12-
# field writes table + WAL journal mode + 4 indexes on ingestion_date /
# destination_path / source_id / writer_id. LangChain SQLRecordManager-
# aligned; status enum {active, superseded} for logical
# supersession; write_bucket enum {create, modify-append, modify-amend}
# partitions audit queries. One-shot at install; idempotent via
# PRAGMA user_version=1 checkpoint inside the lib (re-running is a no-op
# preserving operator-written rows + WAL state).
#
# The manifest-record.sh lib lives at hooks/lib/ (top-level lib/
# does NOT exist in brain-stem). Source from $SOURCE_REPO/hooks/lib/ (the lib +
# its manifest-migrate.sql companion resolve via the lib's own SCRIPT_DIR). The
# writer-manifest SQLite substrate may not be present in every source tree; if
# absent, the bootstrap degrades to a warn (the
# governance-action-log.jsonl init below still fires). The manifest.sqlite root
# is the brain-stem state-tier path ($VAULT_WRITER_STATE_ROOT/manifest.sqlite).
#
# Env-var propagation: VAULT_WRITER_STATE_ROOT passed via inline-prefix (lib
# auto-derives WRITER_MANIFEST_PATH = $VAULT_WRITER_STATE_ROOT/manifest.sqlite
# per pillar 7).
manifest_record_lib="$SOURCE_REPO/hooks/lib/manifest-record.sh"
if [ -r "$manifest_record_lib" ]; then
  if ! VAULT_WRITER_STATE_ROOT="$VAULT_WRITER_STATE_ROOT" \
       bash "$manifest_record_lib" init; then
    diag "manifest.sqlite bootstrap failed via $manifest_record_lib init"
    exit 11
  fi
  info "manifest.sqlite bootstrap applied: $VAULT_WRITER_STATE_ROOT/manifest.sqlite"
else
  warn "manifest-record.sh not present at $manifest_record_lib (C5 writer-manifest substrate not landed); skipping manifest.sqlite bootstrap (governance-action-log init still fires)"
fi

# governance-action-log.jsonl bootstrap: the runtime file is bootstrap-CREATED
# at install Step 1.6 under governance/, NOT copied at Step 8.5. The /govern
# register WRITE path (hooks/lib/overlay-master-mutate.sh
# + skills/govern/process.sh) appends rows here.
gov_action_log="$CLAUDE_HOME/governance/governance-action-log.jsonl"
if [ -e "$gov_action_log" ]; then
  info "governance-action-log.jsonl already present: $gov_action_log (idempotent skip)"
else
  : > "$gov_action_log" || { diag "governance-action-log.jsonl init failed: $gov_action_log"; exit 11; }
  info "governance-action-log.jsonl bootstrapped empty: $gov_action_log"
fi

# Step 1.7: DROPPED. The meeting-processor-state migration is struck — it
# hardcoded a live author-vault path
# (~/Documents/Obsidian Vault/Meetings/.meeting-processor-state.json)
# and is a fresh-install no-op. brain-stem ships no meeting-processor; there
# is nothing to migrate. (No mp_state_* vars; the whole step is removed.)

# Step 2: hooks/*.sh + hooks/*.md + MANIFEST → $CLAUDE_HOME/hooks/
# (cp -n: never clobber; honors user-edited variants)
for f in "$SOURCE_REPO/hooks"/*.sh "$SOURCE_REPO/hooks"/*.md "$SOURCE_REPO/hooks/MANIFEST.txt"; do
  [ -e "$f" ] || continue
  cp $cp_clobber "$f" "$CLAUDE_HOME/hooks/" 2>/dev/null || true
done

# Step 3 / 3.5: hooks/lib/ → hooks/lib/  (top-level lib/ does NOT exist in
# brain-stem — hooks/lib/ is the SOLE lib/ surface; no lib/→hooks/lib/ translation).
# Ships *.sh + *.json + *.sql from the source hooks/lib/ (paths.sh, registry.sh,
# the govern read/write libs, merge-strategy-registry.json, lockf.sh, the
# writer-manifest bodies, + manifest-migrate.sql companion if present).
for f in "$SOURCE_REPO/hooks/lib"/*.sh "$SOURCE_REPO/hooks/lib"/*.json "$SOURCE_REPO/hooks/lib"/*.sql; do
  [ -e "$f" ] || continue
  cp $cp_clobber "$f" "$CLAUDE_HOME/hooks/lib/" 2>/dev/null || true
done

# Step 3.5: SUBSUMED into Step 3. brain-stem has a single
# hooks/lib/ surface, so Step 3 above ships the full hooks/lib/ tree in one pass
# (no separate Step 3.5 copy needed).

# Step 4: hooks/config/*.json → $CLAUDE_HOME/hooks/config/
for f in "$SOURCE_REPO/hooks/config"/*.json; do
  [ -e "$f" ] || continue
  cp $cp_clobber "$f" "$CLAUDE_HOME/hooks/config/" 2>/dev/null || true
done

# Step 5: skills/ → $CLAUDE_HOME/skills/  (brain-stem foundation skill roster)
# brain-stem foundation skill set:
#   - NOT in the loop: morning-brief (R-22), adopt + infer-vault-structure
#     (R-09), architect (non-foundation).
#   - Included: session-checkpoint, the collapsed plan-scaffolder new-plan
#     with --master/--add-subplan modes (R-11), and the
#     onboarder skill with its absorbed producers riding inside skills/onboarder/
#     (top-level onboarding/ dissolved; producers are part of the onboarder
#     skill tree, shipped by this cp -R, NOT a separate Step 6).
# The loop ships every brain-stem foundation skill subtree recursively. It
# tolerates absent skills; warn + continue.
for skill in librarian backlog-hygiene backlog-triage backlog-research onboarder govern doc-amender writer-reconciler meeting-note-ingestor mem-promote new-plan session-checkpoint; do
  src="$SOURCE_REPO/skills/$skill"
  if [ ! -d "$src" ]; then
    warn "skill not present in foundation-repo source: $skill (deferred to its sub-plan)"
    continue
  fi
  cp -R $cp_clobber "$src" "$CLAUDE_HOME/skills/" 2>/dev/null || true
done

# Step 6: DISSOLVED. The top-level
# onboarding/ tree is gone — the onboarder dissolved into a
# self-contained skills/onboarder/ skill. Its producers ride Step 5's
# cp -R skills/onboarder/ (the absorbed producer scripts live inside the skill
# tree). There is no top-level onboarding/ to prune. No-op step.

# Step 7: orchestrator/ → $CLAUDE_HOME/orchestrator/
if [ -d "$SOURCE_REPO/orchestrator" ]; then
  cp -R $cp_clobber "$SOURCE_REPO/orchestrator"/. "$CLAUDE_HOME/orchestrator/" 2>/dev/null || true
fi

# Step 8: installer/ → $CLAUDE_HOME/installer/
# Preserves render-launchd.sh + bootout-launchd.sh with their G6 LABEL_PREFIX
# default (com.brain-stem); install.sh does NOT override this default.
if [ -d "$SOURCE_REPO/installer" ]; then
  cp -R $cp_clobber "$SOURCE_REPO/installer"/. "$CLAUDE_HOME/installer/" 2>/dev/null || true
fi

# Step 8.5: governance/ → $CLAUDE_HOME/governance/
# Ship-surface reduction: selective copy rather than a blanket recursive copy.
# Foundation pillars (the 7 *-rules.json + doc-dependencies.json source files
# in governance/) compose into foundation-master.json at foundation-repo release
# time via tools/build-foundation-master.sh; they are NOT load-bearing for runtime
# consumers under the union-read model. Shipping pillars is a foundation-repo-
# specific authoring concern that adopter vaults should not carry. governance/_index.json
# is foundation-repo author convenience (DO NOT SHIP).
#
# Shipped artifacts:
#  - foundation-master.json — composed governance bundle (single runtime artifact
#    consumed by hooks via the union-read model)
#  - overlay-master.json — adopter Layer-3 overlay skeleton (mutation target for
#    /govern register; cp -n preserves adopter mutations after first write)
#  - log-subtype-registry.json — R-05 system-utility canonicality registry
#  - file-type-contracts/ — k8s paramKind contracts consumed by hooks + librarian
#
# NOT shipped (foundation-repo authoring concern only):
#  - 7 pillar source JSONs: frontmatter-rules, tagging-rules, naming-rules,
#    mandatory-files-rules, doc-dependencies, plans-rules, vault-writers-rules
#  - _index.json — pillar registry + cross-cutting meta-rules (author convenience)
#  - enforcement-map.schema.json.retired-* — retired-artifact markers
#
# foundation-manifest.json lives at $SOURCE_REPO/governance/ and ships here via
# this selective copy (next to foundation-master.json + overlay-master.json).
# Step 13.5 parse-validates post-copy (load-bearing for G2 + uninstall fingerprint).
# governance-action-log.jsonl is bootstrapped at $VAULT_WRITER_STATE_ROOT via
# Step 1.6 (not a governance/ tree concern).
# Selective governance-copy ships exactly the named adopter members; the 7
# pillar source-of-truth JSONs + _index.json stay repo-only (composed into the
# bundle at release via tools/build-foundation-master.sh). Excluded from the
# ship list:
#   - onboarding-reference/  (R-20) — NOT copied.
#   - librarian-capabilities/ — NOT copied.
if [ -d "$SOURCE_REPO/governance" ]; then
  # Bundle (single runtime governance artifact for hooks)
  cp $cp_clobber "$SOURCE_REPO/governance/foundation-master.json" "$CLAUDE_HOME/governance/" 2>/dev/null || true
  # Adopter overlay skeleton (mutation target for /govern register)
  cp $cp_clobber "$SOURCE_REPO/governance/overlay-master.json" "$CLAUDE_HOME/governance/" 2>/dev/null || true
  # Foundation-manifest sha256 baseline (consumed by G2 foreign-content detector
  # + uninstall.sh fingerprint match; produced by generate-foundation-manifest.sh)
  cp $cp_clobber "$SOURCE_REPO/governance/foundation-manifest.json" "$CLAUDE_HOME/governance/" 2>/dev/null || true
  # R-05 system-utility canonicality registry
  cp $cp_clobber "$SOURCE_REPO/governance/log-subtype-registry.json" "$CLAUDE_HOME/governance/" 2>/dev/null || true
  # NOTE: governance-action-log.jsonl is NOT copied here — it is bootstrap-CREATED
  # at Step 1.6 under $CLAUDE_HOME/governance/ (F-2 finding: bootstrap-not-copy).
  # File-type contracts subdir (k8s paramKind shape) — the 12 contract members
  if [ -d "$SOURCE_REPO/governance/file-type-contracts" ]; then
    mkdir -p "$CLAUDE_HOME/governance/file-type-contracts"
    cp -R $cp_clobber "$SOURCE_REPO/governance/file-type-contracts"/. "$CLAUDE_HOME/governance/file-type-contracts/" 2>/dev/null || true
  fi
  # NOT shipped: librarian-capabilities/ + onboarding-reference/ (R-20).
fi

# Step 8.7: vault-init/ → $CLAUDE_HOME/vault-init/
# Recursive cp -R; deploys the foundation-canonical adopter-vault seed tree
# mirroring the target adopter vault tree exactly. Foundation authors
# edit vault-init/ in target shape; install/adopt copies wholesale; what you
# see in vault-init/ is what the adopter gets. cp_clobber posture matches the
# rest of the foundation-known tree (cp -n default; --force-all → cp -f).
# sha256-protected via governance/foundation-manifest.json. Subdir scaffolds
# (System Governance/ + Vault Writers/ + Logs/Archive/ + Meetings/) ship
# as empty dirs with .gitkeep until adopter writes content. Authoring contract
# for what may live under vault-init/ at docs/vault-init-authoring.md.
# The per-plan backlog satellite is retired: backlog +
# archive now live as librarian-emitted files at ${PLANS_DIR:-$HOME/.claude-plans}/_backlog.md
# + _archive.md under Plans Pillar governance (writers_allowed: ["librarian"]
# per governance/plans-rules.json :: root_files).
if [ -d "$SOURCE_REPO/vault-init" ]; then
  cp -R $cp_clobber "$SOURCE_REPO/vault-init"/. "$CLAUDE_HOME/vault-init/" 2>/dev/null || true
fi

# Step 8.8: walk-hygiene prune. The Step 5/7/8/8.5/8.7
# cp -R ship loops walk the disk (not git), so disk-walk cruft (.DS_Store,
# __pycache__/, *.pyc) and runtime state (orchestrator/state/*) can ride the
# wholesale copies into $CLAUDE_HOME. Prune the same exclusion set the generator
# (generate-foundation-manifest.sh) walk excludes, so the installed tree matches
# the fingerprint baseline (state/ absent-by-construction; ship-list parity).
# Block (prune), never ship-and-hope. bash 3.2 (R-23).
LC_ALL=C find "$CLAUDE_HOME" \( -name '.DS_Store' -o -name '*.pyc' \) -type f -print 2>/dev/null | while IFS= read -r junk; do
  rm -f "$junk" 2>/dev/null || true
done
LC_ALL=C find "$CLAUDE_HOME" -type d -name '__pycache__' -print 2>/dev/null | while IFS= read -r pyc; do
  rm -rf "$pyc" 2>/dev/null || true
done
# orchestrator runtime state never enters the ship surface (absent-by-construction).
# Prune EVERY file under orchestrator/state/
# including .gitkeep — the generator (generate-foundation-manifest.sh) prunes the
# whole state/ dir so .gitkeep is NOT in the manifest baseline; keeping it here
# would leave orchestrator/state/.gitkeep surviving install (and then preserved by
# uninstall as not-in-baseline → orchestrator/ never prunes empty → uninstall
# residue). The carve-out is dropped so the installed tree matches
# the absent-by-construction state/ baseline. (Untracked at source: .gitignore
# no longer un-ignores it + git rm --cached.)
LC_ALL=C find "$CLAUDE_HOME/orchestrator/state" -type f -print 2>/dev/null | while IFS= read -r st; do
  rm -f "$st" 2>/dev/null || true
done

# Step 9: schemas/ — selective named-list. vault-schema, gate-config, and
# gate-config-schema are dropped (dissolved into pillar shards / retired).
# vault-overlay-schema.json is retired; companion config hooks/config/vault-overlay.json
# now ships unvalidated until a replacement pillar shard supersedes it.
# Remaining hooks/config/*.json companion schemas (drift-allowlist) consumed by
# Step 13.6 jsonschema validation below. Ships the overlay-master,
# governance-action-log, vault-writers-rules, processing-rules, plans-rules,
# and writer-manifest schemas.
#
# 4 per-pillar schemas are DROPPED from the ship surface —
# doc-dependencies-schema, vault-writers-rules-schema,
# processing-rules-schema, plans-rules-schema. Per-pillar schemas stay
# foundation-repo authoring-side as reference; the bundle-slot schema in
# foundation-master-schema.json is the runtime validation layer (pillars compose
# into the bundle at release time; bundle ships, pillars don't).
for schema in plans-schema plan-manifest-schema librarian-manifest-schema user-manifest-schema orchestration-schema drift-allowlist-schema overlay-master-schema governance-action-log-schema writer-manifest-schema; do
  src="$SOURCE_REPO/schemas/$schema.json"
  if [ ! -f "$src" ]; then
    diag "schema missing in source: $schema.json"
    exit 11
  fi
  cp $cp_clobber "$src" "$CLAUDE_HOME/schemas/" 2>/dev/null || true
done
# Schemas/README.md ships alongside (operator docs)
[ -f "$SOURCE_REPO/schemas/README.md" ] && \
  cp $cp_clobber "$SOURCE_REPO/schemas/README.md" "$CLAUDE_HOME/schemas/" 2>/dev/null || true

# Step 10: templates/ — settings.json + skeletons + README + CLAUDE.md templates
# + plan/capture templates + launchd/*.tmpl + settings-fragments/.
# The 2 CLAUDE.md templates (vault-claude-md + claude-home-claude-md) are
# staged here sha256-protected; the
# onboarder author-claude-home.sh consumes them (NOT install-time seeded).
# librarian-manifest-skeleton.json + README.md remain in the loop for forward
# compatibility (skipped via [ -e ] || continue when not yet landed).
for tmpl in settings.json librarian-manifest-skeleton.json README.md vault-claude-md-template.md claude-home-claude-md-template.md MEMORY.md.template claude-home-rules-readme-template.md updates-template.md prd-template.md context-template.md spec-template.md tasks-template.md handoff-template.md ideation-brief-template.md idea-note-template.md; do
  src="$SOURCE_REPO/templates/$tmpl"
  [ -e "$src" ] || continue
  cp $cp_clobber "$src" "$CLAUDE_HOME/templates/" 2>/dev/null || true
done
for f in "$SOURCE_REPO/templates/launchd"/*.tmpl; do
  [ -e "$f" ] || continue
  cp $cp_clobber "$f" "$CLAUDE_HOME/templates/launchd/" 2>/dev/null || true
done
for f in "$SOURCE_REPO/templates/settings-fragments"/*.json; do
  [ -e "$f" ] || continue
  cp $cp_clobber "$f" "$CLAUDE_HOME/templates/settings-fragments/" 2>/dev/null || true
done

# Step 11: DROPPED. claude-mem is NOT bundled — it is
# an OPTIONAL adopter-installed plugin via the Claude Code plugin marketplace.
# The plugins/claude-mem/v*/ copy + the false plugins/README are gone;
# the plugins/ dir is not created. brain-stem's first-party memory hygiene is the
# memory-consolidation-check.sh SessionEnd hook (NOT claude-mem). No-op step.

# Step 11.5: DROPPED. The global ~/.claude/CLAUDE.md pre-seed is STRUCK —
# skills/onboarder/scripts/author-claude-home.sh is the AUTHORITATIVE writer of
# the global CLAUDE.md (post-onboarding identity-aware compose), NOT a
# placeholder-substituted install-time seed. install.sh does NOT write
# $CLAUDE_HOME/CLAUDE.md. (The 2 CLAUDE.md TEMPLATES still ship at Step 10 — they
# are source files staged into templates/; the onboarder consumes
# them. No template-substitution-into-$CLAUDE_HOME/CLAUDE.md here.)

# (Step 11.5 implementation removed — see the DROP note above. install.sh no
# longer reads templates/claude-home-claude-md-template.md or writes
# $CLAUDE_HOME/CLAUDE.md; author-claude-home.sh is the authoritative writer.)

# Step 11.6: MEMORY.md skeleton — LAZY SessionStart seed
# The skeleton is NO LONGER eager-seeded at install time. The former eager seed
# wrote to "$CLAUDE_HOME | tr '/' '-' | leading-dash-stripped"
# — a slug that both mis-encoded vs the harness (which maps every non-[a-zA-Z0-9]
# to '-' and KEEPS the leading dash) AND keyed off ~/.claude, a dir nobody
# launches sessions from. The skeleton reached no adopter.
#
# Seeding now happens lazily at SessionStart via hooks/memory-seed.sh, which
# writes the type-grouped skeleton into resolve_memory_dir()'s output — the exact
# per-project dir the running harness reads (git-repo-root slug, or the flat
# autoMemoryDirectory when set) — no-clobber. The hook ships in Step 2
# (hooks/*.sh) and the template in Step 11 (MEMORY.md.template); this step only
# verifies both landed so the lazy seed will fire.
template_memory="$CLAUDE_HOME/templates/MEMORY.md.template"
memory_seed_hook="$CLAUDE_HOME/hooks/memory-seed.sh"
if [ ! -f "$template_memory" ]; then
  warn "MEMORY.md.template not present at $template_memory — SessionStart seed will no-op until present"
elif [ ! -x "$memory_seed_hook" ]; then
  warn "memory-seed.sh not executable at $memory_seed_hook — SessionStart MEMORY.md seed disabled"
else
  info "MEMORY.md lazy-seed wired (SessionStart hooks/memory-seed.sh → resolve_memory_dir; no eager install-time seed)"
fi

# Step 11.7: ~/.claude/rules/README.md seed
# Seeds $CLAUDE_HOME/rules/README.md from templates/claude-home-rules-readme-template.md.
# Adopter-facing README explaining the `paths:` frontmatter pattern for the
# documented Anthropic .claude/rules/ scale-beyond primitive (loads beyond the
# MEMORY.md 25KB cap via glob-scoped lazy loading; reference
# code.claude.com/docs/en/memory).
#
# No-clobber: existing README is preserved unconditionally — adopters who
# customize the README don't get clobbered on re-install.
template_rules_readme="$CLAUDE_HOME/templates/claude-home-rules-readme-template.md"
rules_dir="$CLAUDE_HOME/rules"
rules_readme_target="$rules_dir/README.md"

if [ ! -f "$template_rules_readme" ]; then
  warn "claude-home-rules-readme-template.md not present at $template_rules_readme — skipping rules/README.md seed"
elif [ -f "$rules_readme_target" ]; then
  info "rules/README.md exists at $rules_readme_target — preserving (no clobber)"
else
  if ! mkdir -p "$rules_dir"; then
    diag "rules/README.md seed: mkdir failed: $rules_dir"
    exit 11
  fi
  rules_readme_tmp="$rules_readme_target.tmp.$$"
  if ! cp "$template_rules_readme" "$rules_readme_tmp"; then
    diag "rules/README.md seed: cp failed: $template_rules_readme → $rules_readme_tmp"
    rm -f "$rules_readme_tmp"
    exit 11
  fi
  if ! mv -f "$rules_readme_tmp" "$rules_readme_target"; then
    diag "rules/README.md seed: atomic mv failed: $rules_readme_target"
    rm -f "$rules_readme_tmp"
    exit 11
  fi
  info "rules/README.md seeded at $rules_readme_target"
fi

# Step 12: settings.json atomic jq-merge with G7 silent-key-deletion gate
template_settings="$CLAUDE_HOME/templates/settings.json"
target_settings="$CLAUDE_HOME/settings.json"
tmp_settings="$CLAUDE_HOME/.settings.json.tmp.$$"

if [ ! -f "$template_settings" ]; then
  diag "templates/settings.json missing post-copy"
  exit 11
fi

if [ -f "$target_settings" ]; then
  before_paths_file="$CLAUDE_HOME/.settings-before-paths.$$"
  after_paths_file="$CLAUDE_HOME/.settings-after-paths.$$"

  # All structural paths in the existing settings (G7 baseline)
  jq -c '[paths(scalars,arrays)] | sort | unique[]' "$target_settings" \
    > "$before_paths_file" 2>/dev/null || {
      diag "jq read failure on existing settings.json (malformed?); manual resolution required"
      rm -f "$before_paths_file"
      exit 40
    }

  # Deep merge: template provides defaults, user edits win on scalar conflict.
  # In jq `a * b`, b wins on scalar conflicts; objects merge recursively. Arg
  # order: template first, user second → template * user = user wins.
  if ! jq -s '.[0] * .[1]' "$template_settings" "$target_settings" > "$tmp_settings" 2>/dev/null; then
    diag "jq atomic merge failed; manual resolution required"
    rm -f "$tmp_settings" "$before_paths_file"
    exit 40
  fi

  jq -c '[paths(scalars,arrays)] | sort | unique[]' "$tmp_settings" \
    > "$after_paths_file" 2>/dev/null || {
      diag "jq read failure on merged settings.json (post-merge corruption)"
      rm -f "$tmp_settings" "$before_paths_file" "$after_paths_file"
      exit 40
    }

  # G7: every path in BEFORE must be present in AFTER. Missing path = silent deletion.
  missing="$(comm -23 "$before_paths_file" "$after_paths_file" 2>/dev/null || true)"
  rm -f "$before_paths_file" "$after_paths_file"
  if [ -n "$missing" ]; then
    diag "G7 fired: settings.json merge would silently delete the following paths:"
    printf '%s\n' "$missing" >&2
    rm -f "$tmp_settings"
    exit 57
  fi
else
  # Fresh install — copy template verbatim
  cp "$template_settings" "$tmp_settings" || { diag "cp template_settings → tmp failed"; exit 11; }
fi

# Atomic rename (G7 atomicity)
sync 2>/dev/null || true
mv -f "$tmp_settings" "$target_settings" || { diag "atomic mv failed: $target_settings"; rm -f "$tmp_settings"; exit 11; }

# Step 12.5: idempotent spec-context-inject hook registration in UserPromptSubmit
# chain. The template declares this hook, but Step 12 jq merge
# `template * user_settings` lets the user's array win on array conflicts — so
# re-installs against an adopter whose UserPromptSubmit chain lacks the hook
# would silently drop it. Step 12.5 detects absence and appends to the first
# bucket's hooks array (preserving user customizations); presence is a no-op
# (idempotent). Operates on the post-Step-12 result.
if [ -f "$target_settings" ]; then
  has_spec_inject=$(jq -r '
    [.hooks.UserPromptSubmit[]?.hooks[]?.command // ""]
    | map(test("spec-context-inject\\.sh"))
    | any
  ' "$target_settings" 2>/dev/null || echo "error")
  if [ "$has_spec_inject" = "false" ]; then
    tmp_settings_125="$CLAUDE_HOME/.settings.json.tmp.125.$$"
    if ! jq '
      .hooks.UserPromptSubmit |= (
        if . == null or length == 0 then
          [{"hooks":[{"type":"command","command":"~/.claude/hooks/spec-context-inject.sh","timeout":5}]}]
        else
          .[0].hooks += [{"type":"command","command":"~/.claude/hooks/spec-context-inject.sh","timeout":5}]
        end
      )
    ' "$target_settings" > "$tmp_settings_125" 2>/dev/null; then
      diag "jq spec-context-inject registration failed (Step 12.5); manual resolution required"
      rm -f "$tmp_settings_125"
      exit 40
    fi
    sync 2>/dev/null || true
    mv -f "$tmp_settings_125" "$target_settings" || { diag "atomic mv failed: $target_settings (Step 12.5)"; rm -f "$tmp_settings_125"; exit 11; }
  fi
fi

# Step 12.6: idempotent AskUserQuestion matcher registration in PreToolUse chain.
# The template declares this matcher, but Step 12 jq merge
# `template * user_settings` lets the user's PreToolUse array win on array conflicts
# — so re-installs against an adopter whose PreToolUse chain lacks the matcher
# would silently drop it. Step 12.6 detects absence and appends a new matcher
# entry to the PreToolUse array (preserving user customizations); presence is a
# no-op (idempotent). Operates on the post-Step-12.5 result.
#
# Sister-pattern to Step 12.5 (spec-context-inject registration). Same problem
# class: hook declared in template but jq deep-merge cannot reliably add new
# array entries when user has customized the matching parent array.
if [ -f "$target_settings" ]; then
  has_asq_matcher=$(jq -r '
    [.hooks.PreToolUse[]?.hooks[]?.command // ""]
    | map(test("pre-asq-guard\\.sh"))
    | any
  ' "$target_settings" 2>/dev/null || echo "error")
  if [ "$has_asq_matcher" = "false" ]; then
    tmp_settings_126="$CLAUDE_HOME/.settings.json.tmp.126.$$"
    if ! jq '
      .hooks.PreToolUse |= (
        if . == null or length == 0 then
          [{"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"~/.claude/hooks/pre-asq-guard.sh"}]}]
        else
          . + [{"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"~/.claude/hooks/pre-asq-guard.sh"}]}]
        end
      )
    ' "$target_settings" > "$tmp_settings_126" 2>/dev/null; then
      diag "jq pre-asq-guard registration failed (Step 12.6); manual resolution required"
      rm -f "$tmp_settings_126"
      exit 40
    fi
    sync 2>/dev/null || true
    mv -f "$tmp_settings_126" "$target_settings" || { diag "atomic mv failed: $target_settings (Step 12.6)"; rm -f "$tmp_settings_126"; exit 11; }
  fi
fi

# Step 13: schema parse validation (post-install)
for schema in "$CLAUDE_HOME/schemas"/*.json; do
  [ -e "$schema" ] || continue
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$schema" 2>/dev/null; then
    diag "schema parse failure: $schema"
    exit 30
  fi
done

# Step 13.6: jsonschema validation of foundation-shipped configs.
# Validates hooks/config/*.json against the
# 4 companion schemas shipped at Step 9. Graceful skip when python3 jsonschema
# module is unavailable on the adopter machine — preserves the
# error_action: ignore posture (fresh adopters degrade silently at runtime
# when validation tooling absent). Adopters with jsonschema installed
# (pip3 install jsonschema) get fail-loud-at-install behavior on malformed
# configs via exit 30 (pre-allocated for "schema parse failure (post-install)").
if python3 -c "import jsonschema" 2>/dev/null; then
  for pair in \
    "doc-dependencies.json:doc-dependencies-schema.json" \
    "drift-allowlist.json:drift-allowlist-schema.json"; do
    cfg_name="${pair%:*}"
    sch_name="${pair#*:}"
    cfg_path="$CLAUDE_HOME/hooks/config/$cfg_name"
    sch_path="$CLAUDE_HOME/schemas/$sch_name"
    [ -f "$cfg_path" ] || continue
    [ -f "$sch_path" ] || continue
    if ! python3 -c "import json,sys; from jsonschema.validators import Draft202012Validator; Draft202012Validator(json.load(open(sys.argv[1]))).validate(json.load(open(sys.argv[2])))" "$sch_path" "$cfg_path"; then
      diag "config schema validation failed: $cfg_path against $sch_path"
      exit 30
    fi
  done
else
  warn "python3 jsonschema module not available; install-time config-vs-schema validation skipped (pip3 install jsonschema to enable). Configs were JSON-syntax-validated by Step 13."
fi

# Step 13.5: parse-validate foundation-manifest.json baseline
# Generator is at $SOURCE_REPO/generate-foundation-manifest.sh; output is
# committed at $SOURCE_REPO/governance/foundation-manifest.json at release-cut time.
# install.sh ships the static artifact via
# Step 8.5 selective copy (cp -n; never clobber user variant); this step now
# parse-validates the post-copy artifact only — duplicate cp retained as
# defensive recovery path (cp_clobber no-op when Step 8.5 succeeded).
# Consumed by uninstall.sh fingerprint match + G2 foreign-content detector.
# Absence is non-fatal (warns only) so install on a partial-bootstrap
# foundation-repo remains usable.
manifest_src="$SOURCE_REPO/governance/foundation-manifest.json"
manifest_dst="$CLAUDE_HOME/governance/foundation-manifest.json"
if [ -f "$manifest_src" ]; then
  cp $cp_clobber "$manifest_src" "$manifest_dst" 2>/dev/null || true
  if [ -f "$manifest_dst" ]; then
    if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$manifest_dst" 2>/dev/null; then
      diag "governance/foundation-manifest.json parse failure post-copy: $manifest_dst"
      exit 30
    fi
  fi
else
  warn "governance/foundation-manifest.json not present at SOURCE_REPO (baseline absent; G2 + fingerprint match unavailable until generated)"
fi

# Step 14: provenance log header (G10 — write failure exits 11)
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log_path="$CLAUDE_HOME/logs/install-$(date -u +%Y%m%d-%H%M%S)-$$.log"
{
  printf 'install.sh provenance\n'
  printf 'timestamp: %s\n'        "$ts"
  printf 'CLAUDE_HOME: %s\n'      "$CLAUDE_HOME"
  printf 'SOURCE_REPO: %s\n'      "$SOURCE_REPO"
  printf 'apply_mode: %s\n'       "$APPLY_MODE"
  printf 'dry_run: %s\n'          "0"
  printf 'action_plan_emitted: %s\n' "0"
  printf 'force_install: %s\n'    "$FORCE_INSTALL"
  printf 'force_all: %s\n'        "$FORCE_ALL"
  printf 'no_preserve_config: %s\n' "$NO_PRESERVE_CONFIG"
  printf 'state_classification: %s\n' "$state_classification"
  printf 'retrofit_existing: %s\n' "$RETROFIT_EXISTING"
  printf 'sentinel_verified: %s\n' "$sentinel_verified"
  printf 'install.sh sha256: %s\n' "$(shasum -a 256 "$0" 2>/dev/null | awk '{print $1}')"
  if [ -f "$manifest_dst" ]; then
    printf 'foundation_manifest_sha256: %s\n' "$(shasum -a 256 "$manifest_dst" 2>/dev/null | awk '{print $1}')"
  else
    printf 'foundation_manifest_sha256: (absent)\n'
  fi
  printf 'g2_violation_count: %s\n' "$g2_violation_count"
  if [ "$g2_violation_count" -gt 0 ]; then
    printf 'g2_violations:\n'
    printf '%s\n' "$g2_violations" | while IFS= read -r p; do
      [ -z "$p" ] || printf '  - %s\n' "$p"
    done
  fi
  printf 'g3_backup_dir: %s\n' "${BACKUP_DIR:-(absent)}"
  printf 'g3_destructive_op_pending: %s\n' "$g3_destructive_op_pending"
  printf 'g3_proof_of_life_passed: %s\n' "$g3_proof_of_life_passed"
  if [ -n "$g3_skip_reason" ]; then
    printf 'g3_skip_reason: %s\n' "$g3_skip_reason"
  fi
  printf 'g4_vault_canonical: %s\n' "${g4_vault_canonical:-(absent)}"
  printf 'g4_violation_count: %s\n' "$g4_violation_count"
  printf 'g5_plans_home: %s\n' "$PLANS_HOME"
  printf 'g5_existing_count: %s\n' "$g5_existing_count"
  if [ "$g5_existing_count" -gt 0 ]; then
    printf 'g5_existing_plans:\n'
    printf '%s\n' "$g5_existing_plans" | while IFS= read -r p; do
      [ -z "$p" ] || printf '  - %s\n' "$p"
    done
  fi
  printf 'g8_uid: %s\n' "$g8_uid"
  printf 'scope: 14-asset write-sequence + LABEL_PREFIX preservation + settings.json atomic merge + G1-pre + G1-main equality gate + G2 foreign-content detector + I-UNDERSTAND-OVERWRITE-RISK sentinel (single-ceremony G1+G2) + G3 backup proof-of-life + G4 vault-symlink check + G5 plans-dir guard + G8 UID-0 refuse + G9 dry-run-as-default (--apply transitions out) + state classification (fresh|foundation-only|mixed|user-only; user-only refuse at 21) + --force-all flag (cp -n→cp -f for foundation files) + --no-preserve-config flag (gated on --force-install) + G10 provenance-write-failure-as-11 + governance/foundation-manifest.json baseline copy\n'
  printf 'deferred: G6 install-side explicit label sentinel (transitively preserved); claude-mem preservation full implementation; top-level exit codes 20 (conflict-manifest) / 22 (rsync-backup) / 60 (grep-audit consumer)\n'
} > "$log_path" || { diag "G10: provenance log write failed at $log_path"; exit 11; }

info "install complete. next-steps:"
# Post-install plist rendering walks O.jobs[] via for_each_job (sourced
# from onboarding/lib/job-iterator.sh) and invokes render-launchd.sh per declared
# job. Single-job (librarian|architect) callers may still invoke render-launchd.sh
# directly; multi-job callers (post-onboarding, post-connector-wizard) use
# render-all-launchd.sh which iterates via for_each_job over orchestration.json.
info "  - render plists for ALL declared jobs (post-onboarding):"
info "    \$CLAUDE_HOME/installer/render-all-launchd.sh --staging-dir \$CLAUDE_HOME/Library/LaunchAgents.staging"
info "  - render a single job manually:"
info "    \$CLAUDE_HOME/installer/render-launchd.sh --staging-dir \$CLAUDE_HOME/Library/LaunchAgents.staging <job-id>"
info "  - claude-mem bundle: deferred"
info "  - G6 install-side explicit label sentinel: deferred (transitively preserved via cp -R installer/; render-launchd.sh enforces at runtime)"
info "  - top-level exit codes 20/22/60: deferred to v2.1 (conflict-manifest, rsync-backup, grep-audit consumer)"
info "provenance: $log_path"

exit 0
