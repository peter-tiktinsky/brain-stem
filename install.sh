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
#     DECOMMISSIONED for the upgrade path (refused → exit 23 when
#.installed-state.json is present).
#   - --upgrade / --migrate-major flags — upgrade entrypoint posture
#. --upgrade is an OPTIONAL
#     assertion that an installed version exists (fails fast on a fresh home);
#     action stays gated by --apply (auto-detect, Option C). --migrate-major
#     is the explicit ack required to cross a major boundary on the --apply
#     lane, paired with the I-UNDERSTAND-OVERWRITE-RISK sentinel (sentinel reuse).
#     Downgrade (target<installed) is refused (exit 23, no --force override).
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
# 23 upgrade-path refuse:
#       (a) downgrade — target < installed (forward-only, no down-migrations,
#           NO --force override); (b) --force-all supplied when
#           .installed-state.json is present (--force-all is decommissioned for
#           the upgrade path); (c) a major-version bump on the --apply lane
#           WITHOUT --migrate-major + the I-UNDERSTAND-OVERWRITE-RISK sentinel.
#   30  schema parse failure (post-install)
#   40  settings.json merge conflict requires human resolution (jq error)
#   51  G1-main fired ($HOME/.claude equality + non-foundation content,
#       missing --force-install or I-UNDERSTAND-OVERWRITE-RISK sentinel).
#   52  G2 fired (foreign-content sha256 drift in foundation files,
#       missing --force-install or I-UNDERSTAND-OVERWRITE-RISK sentinel).
# fires on the --apply lane ONLY. On the dry-run lane G2 drift
#       is NON-fatal — a legacy/drifted home's OLD foundation bytes are the
#       expected pre-engine version-delta preview (rc 0, write-free, the
#       required override surfaces under required_overrides[]), NOT a refuse.
#   53  G3 fired (backup proof-of-life: --backup-dir absent when
#       destructive op pending; or supplied --backup-dir not writable
#       or round-trip-broken)
#   54  G4 fired (vault-symlink reachable under $CLAUDE_HOME; no override)
#   55  G5 fired ($PLANS_HOME contains NN-*/ plans without
#       --retrofit-existing)
# 56 under-delivery refuse: one or more
#       managed files[] members did not converge to the shipped content
#       after the delivery walk — the home is half-delivered. Refusing to
#       stamp: NO .installed-state.json written, baseline NOT advanced
# (forward-progress — the un-stamped home re-runs to eventual
#       convergence). NOT 54 (54 is G4 vault-symlink); 56 is the free code.
#   57  G7 fired (settings.json merge would silently delete keys)
#   58  G8 fired (UID 0; no override)
#   59  G9 RESERVED — dry-run default is the posture (not refuse-gate);
#       --apply required to leave dry-run. 59 is allocated per spec but
#       cannot fire under current implementation (any dry-run violation
#       would be a code-tampering condition).
#
# R-23 bash 3.2 compat. R-37 single-deliverable. R-55 zero $HOME/.claude
# resolution paths in script body (literal $HOME/.claude appears only in
# the G1-pre user-facing error text and the G1-main
# string-equality comparison). G4 resolves $HOME/Documents/
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

# --- vercmp: bash-3.2-safe semver comparator ---
# vercmp <a> <b> -> prints one of: equal | a>b | a<b  (on stdout).
# Strips a leading 'v' from each operand, then compares major.minor.patch
# NUMERICALLY. CORRECTION (versioning-legacy-adopt advisory): each segment is
# coerced through base-10 via $((10#$seg)) — matching the octal-guard idiom at
# hooks/spec-context-inject.sh:84 — so a zero-padded segment like 08/09 never
# trips "value too great for base" under set -euo pipefail. Missing segments
# (e.g. "v1.0" or the v0.0.0 legacy-adopt floor) default to 0. Non-numeric
# residue (pre-release suffix etc.) is stripped to its leading digits so the
# comparator stays total. NO subshell-fork per segment (3.2-safe, fast).
vercmp() {
  local a="${1#v}" b="${2#v}" i aseg bseg an bn
  for i in 1 2 3; do
    aseg="$(printf '%s' "$a" | cut -d. -f"$i")"
    bseg="$(printf '%s' "$b" | cut -d. -f"$i")"
    # keep only the leading run of digits; empty -> 0
    aseg="${aseg%%[!0-9]*}"; bseg="${bseg%%[!0-9]*}"
    [ -n "$aseg" ] || aseg=0
    [ -n "$bseg" ] || bseg=0
    # base-10 coercion (octal-guard) so 08/09 cannot crash arithmetic
    an=$((10#$aseg)); bn=$((10#$bseg))
    if [ "$an" -gt "$bn" ]; then printf 'a>b'; return 0; fi
    if [ "$an" -lt "$bn" ]; then printf 'a<b'; return 0; fi
  done
  printf 'equal'
  return 0
}

# --- argv parse (in-memory only; no FS; pre-G1-pre to keep 100ms bound) ---
FORCE_INSTALL=0
FORCE_ALL=0
NO_PRESERVE_CONFIG=0
APPLY_MODE=0
BACKUP_DIR=""
RETROFIT_EXISTING=0
# --- sentinel-via-argv arm ---
# A non-interactive driver (CI, the upgrade orchestrator, `</dev/null` smoke
# tests) cannot supply the I-UNDERSTAND-OVERWRITE-RISK ceremony token over a
# piped-stdin-only path. Accept the SAME token as an argv flag AND as the bare
# token, so the G1-main / G2 reads can short-circuit through the unchanged
# literal-equality check instead of blocking on a stdin read. SENTINEL_ARG=0
# (default OFF) reproduces today's piped-stdin behavior byte-for-byte. The flag
# still requires --force-install (the short-circuit lives inside the existing
# FORCE_INSTALL guard at each read site).
SENTINEL_ARG=0
# --- upgrade entrypoint posture ---
# UPGRADE_MODE (--upgrade): an OPTIONAL assertion, not a required incantation.
#   Detection of the upgrade case is automatic (.installed-state.json present +
# target>installed); --action is gated by --apply (Option C synthesis,
# "detection automatic, action still gated by --apply"). --upgrade adds the
#   assertion "fail if this is actually a fresh install" (resolved behavior:
#   `install.sh --upgrade --apply` asserts an installed version exists).
# MIGRATE_MAJOR (--migrate-major): the explicit ack required to cross a major
#   version boundary on the --apply lane (a major bump refuses silent
#   auto-upgrade and routes through the EXISTING I-UNDERSTAND-OVERWRITE-RISK
#   sentinel ceremony — reuse the existing sentinel, don't reinvent).
UPGRADE_MODE=0
MIGRATE_MAJOR=0
# OPT-IN frontmatter cohort auto-fixer under --upgrade.
# Default OFF (never auto-forced); when set on an --apply upgrade, runs the shipped
# frontmatter-enforce.sh --fix backfill AFTER the managed files land (new hooks).
FRONTMATTER_FIX=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)                APPLY_MODE=1 ;;
    --force-install)        FORCE_INSTALL=1 ;;
    --force-all)            FORCE_ALL=1 ;;
    --no-preserve-config)   NO_PRESERVE_CONFIG=1 ;;
    --backup-dir)           shift; BACKUP_DIR="${1:-}" ;;
    --backup-dir=*)         BACKUP_DIR="${1#--backup-dir=}" ;;
    --retrofit-existing)    RETROFIT_EXISTING=1 ;;
    --upgrade)              UPGRADE_MODE=1 ;;
    --frontmatter-fix)      FRONTMATTER_FIX=1 ;;
    --migrate-major)        MIGRATE_MAJOR=1 ;;
    --i-understand-overwrite-risk) SENTINEL_ARG=1 ;;
    I-UNDERSTAND-OVERWRITE-RISK)   SENTINEL_ARG=1 ;;
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
# also set to 1 up-front when the argv sentinel arm is supplied
# WITH --force-install (the non-interactive ceremony), so both reads short-circuit
# through the unchanged literal-equality posture without a stdin read.
sentinel_verified=0
if [ "$SENTINEL_ARG" = "1" ] && [ "$FORCE_INSTALL" = "1" ]; then
  sentinel_verified=1
fi

# --- defer-in-dry-run accumulator ---
# The refuse-gates G1-main (exit 51) and G3 (exit 53) historically fail-fast on
# the FIRST unmet requirement, so a populated-home adopter must re-run install
# once per gate to discover the full override set. In dry-run (APPLY_MODE != 1)
# these gates instead RECORD their unmet requirement here and CONTINUE; the G9
# action-plan JSON then emits required_overrides[] so the adopter sees the WHOLE
# set (--force-install + sentinel AND --backup-dir) in ONE pass (compiler-style
# aggregate-all-failures). The --apply lane keeps the hard `exit NN` fail-fast at
# the mutation boundary VERBATIM (fail-open posture preserved).
# Newline-delimited accumulator (bash 3.2-safe; emitted as a JSON array via jq
# split at the dry-run object).
required_overrides=""
note_required_override() { # note_required_override <requirement-string>
  if [ -z "$required_overrides" ]; then
    required_overrides="$1"
  else
    required_overrides="$required_overrides
$1"
  fi
}

# NON-WAIVABLE blocking findings. The genuine must-stop safety gates (G4 vault-
# clobber, CLAUDE_HOME write-target) keep their --apply hard exits, but the dry-run
# surfaces them in a SEPARATE channel so the one-pass action plan shows EVERY
# blocker — not just the waivable required_overrides[]. Kept distinct from
# required_overrides[] precisely because a blocking finding has NO override flag;
# folding it in would falsely imply waivability. Same accumulator shape; emitted as
# a JSON array (blocking_findings[]) on the dry-run object.
blocking_findings=""
note_blocking_finding() { # note_blocking_finding <finding-string>
  if [ -z "$blocking_findings" ]; then
    blocking_findings="$1"
  else
    blocking_findings="$blocking_findings
$1"
  fi
}

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
  # Surface the --apply prerequisite in the one-pass preview so the adopter sees it
  # alongside every other blocker (not serially on the first --apply).
  note_blocking_finding "export CLAUDE_HOME (G1-pre: CLAUDE_HOME is unset; the dry-run previews against the \$HOME/.claude default, but --apply HARD-FAILS exit 10 until CLAUDE_HOME is exported explicitly)"
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
  for entry in "$PLANS_HOME"/[0-9][0-9]*-*/; do
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
  if [ "$RETROFIT_EXISTING" = "1" ]; then
    warn "G5: --retrofit-existing supplied with $g5_existing_count pre-existing plan(s); v2.1 retrofit logic NOT YET IMPLEMENTED — flag is a waiver stub. Proceeding under explicit user waiver; install does not modify \$PLANS_HOME."
  elif [ "$APPLY_MODE" != "1" ]; then
    # The dry-run AGGREGATES — record the waivable override and CONTINUE so the
    # one-pass action plan surfaces every blocker (mirrors the G1-main/G2/G3
    # posture); --apply keeps the hard exit 55 at the mutation boundary below.
    note_required_override "--retrofit-existing (G5: \$PLANS_HOME contains $g5_existing_count existing NN-*/ plan(s); the flag waives — v2.1 retrofit logic deferred). \$PLANS_HOME=$PLANS_HOME"
  else
    diag "G5 fired: \$PLANS_HOME contains $g5_existing_count existing NN-*/ plan(s); pass --retrofit-existing to acknowledge (v2.1 retrofit logic deferred — flag currently waives only). \$PLANS_HOME=$PLANS_HOME"
    printf '%s\n' "$g5_existing_plans" | while IFS= read -r p; do
      [ -z "$p" ] || printf '  %s\n' "$p" >&2
    done
    exit 55
  fi
fi

# --- G1-main: $HOME/.claude equality gate ---
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
 # dry-run defers (records the unmet override + continues so the
      # action-plan can aggregate it); --apply still hard fail-fasts exit 51 here.
      if [ "$APPLY_MODE" != "1" ]; then
        note_required_override "--force-install + I-UNDERSTAND-OVERWRITE-RISK sentinel (G1-main: \$CLAUDE_HOME equals \$HOME/.claude AND target contains non-foundation content)"
      else
        diag "G1-main fired: \$CLAUDE_HOME equals \$HOME/.claude AND target contains non-foundation content. Pass --force-install AND --i-understand-overwrite-risk (or type the I-UNDERSTAND-OVERWRITE-RISK sentinel) to proceed (Vault-clobber protection)."
        exit 51
      fi
 # argv sentinel arm (sentinel_verified pre-set to 1 above) short-
    # circuits the stdin read entirely — no prompt, no blocking read, same posture.
    elif [ "$sentinel_verified" = "1" ]; then
      info "G1-main sentinel verified via --i-understand-overwrite-risk argv arm; proceeding under --force-install"
    elif [ "$APPLY_MODE" != "1" ]; then
      # --force-install passed but no sentinel yet: dry-run records the remaining
      # sentinel requirement instead of prompting/blocking on a stdin read.
      note_required_override "I-UNDERSTAND-OVERWRITE-RISK sentinel (G1-main: pass --i-understand-overwrite-risk with --force-install)"
    else
      printf 'install: type I-UNDERSTAND-OVERWRITE-RISK to confirm (or pass --i-understand-overwrite-risk): ' >&2
      sentinel=""
      if ! IFS= read -r sentinel; then
        diag "G1-main fired: sentinel not provided (stdin EOF). Pass --i-understand-overwrite-risk or pipe the I-UNDERSTAND-OVERWRITE-RISK token. Aborting."
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
  if [ "$APPLY_MODE" != "1" ]; then
    # The dry-run surfaces G4 in the NON-WAIVABLE blocking_findings[] channel and
    # CONTINUES (one-pass preview); --apply keeps the unconditional exit 54. G4 is
    # genuinely non-waivable (vault-clobber, no override) → blocking_findings[], NOT
    # required_overrides[] (which would falsely imply a waiver flag exists).
    note_blocking_finding "G4 vault-clobber: \$CLAUDE_HOME contains $g4_violation_count symlink(s) reaching ~/Documents/Obsidian Vault/ — NO override; --apply refuses unconditionally (exit 54). Point \$CLAUDE_HOME at a path that does not symlink into the vault before --apply."
  else
    diag "G4 fired: \$CLAUDE_HOME contains $g4_violation_count symlink(s) reaching ~/Documents/Obsidian Vault/. Vault-clobber protection — refuse unconditionally (no --force override)."
    printf '%s\n' "$g4_violations" | while IFS= read -r v; do
      [ -z "$v" ] || printf '  %s\n' "$v" >&2
    done
    exit 54
  fi
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
# manifest relocated from $SOURCE_REPO root to
# $SOURCE_REPO/governance/ per operator tidy-folder principle (live next to
# foundation-master.json + overlay-master.json).
#
# LEGACY_ADOPT must be known BEFORE the
# G2 fire block so the G2 message labels OLD-vs-edited correctly. The FULL legacy
# classification (with baseline-count reporting) is at the block
# below (post version-detect), but its decision signal — `.installed-state.json
# absent AND a foundation marker present` — is computable here from $CLAUDE_HOME
# alone, which is fully resolved by this point (G1-pre default at :271-280). We
# pre-classify the SAME predicate here so the G2 diag can reframe a legacy home's
# drifted OLD foundation bytes as an expected pre-engine version-delta rather than
# "foreign content (you edited)". INSTALLED_STATE_PATH/FOUNDATION_MARKER are
# (re)defined canonically below at :590/:657 — the assignments here are the early
# echo, deliberately the same paths, and MUST NOT change UPGRADE_PRESENT or the
# version-detect ordering (those stay at :686/:574).
INSTALLED_STATE_PATH="$CLAUDE_HOME/governance/.installed-state.json"
FOUNDATION_MARKER="$CLAUDE_HOME/governance/foundation-master.json"
LEGACY_ADOPT=0
if [ ! -f "$INSTALLED_STATE_PATH" ] && [ -f "$FOUNDATION_MARKER" ]; then
  LEGACY_ADOPT=1
fi

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
 # the G2 message must NOT call a legacy adopter's drifted
  # OLD foundation bytes "foreign content (you edited)". A LEGACY_ADOPT=1 home
  # (foundation marker present, no .installed-state.json stamp) carries pre-engine
  # v1.0.2 bytes that are EXPECTED to differ from the shipped manifest — the
  # drift is a version-delta the upgrade will reconcile, not a tamper. A
  # genuinely-tampered home (stamped, or no marker) keeps the foreign-content
  # framing — the reframe is scoped to LEGACY_ADOPT=1 only (no false reassurance
  # on a real tamper).
  if [ "$LEGACY_ADOPT" = "1" ]; then
    diag "G2: $g2_violation_count managed foundation file(s) on disk differ from the shipped version (expected legacy/pre-engine version-delta — these are OLD foundation bytes the upgrade will replace, NOT foreign content you authored):"
  else
    diag "G2 fired: foreign content (sha256 drift) detected in $g2_violation_count foundation file(s):"
  fi
  printf '%s\n' "$g2_violations" | while IFS= read -r p; do
    [ -z "$p" ] || printf '  %s\n' "$p" >&2
  done
  if [ "$FORCE_INSTALL" != "1" ]; then
 # G2 is non-fatal in DRY-RUN ONLY.
    # On the dry-run lane (APPLY_MODE!=1) the drift is RECORDED into the existing
    # required_overrides accumulator and the run CONTINUES to the G9 dry-run JSON
    # emit — so a legacy/drifted adopter gets an honest write-free preview (rc 0)
    # in ONE pass instead of rc=52 with zero JSON. On the --apply lane the EXISTING
    # hard refuse (exit 52) and the interactive read path below are preserved
 # byte-for-byte —: a tampered home cannot slip an apply without the
 # --force-install + sentinel ceremony. Mirrors the G1-main
    # defer-in-dry-run posture (note_required_override / required_overrides[]).
    if [ "$APPLY_MODE" != "1" ]; then
      if [ "$LEGACY_ADOPT" = "1" ]; then
        note_required_override "--force-install + I-UNDERSTAND-OVERWRITE-RISK sentinel (G2: $g2_violation_count managed file(s) carry legacy/pre-engine OLD bytes the upgrade will replace — supply the sentinel to take-new on --apply)"
      else
        note_required_override "--force-install + I-UNDERSTAND-OVERWRITE-RISK sentinel (G2: $g2_violation_count foundation file(s) show foreign-content sha256 drift)"
      fi
    else
      diag "Pass --force-install AND type I-UNDERSTAND-OVERWRITE-RISK sentinel to proceed (cp -n preserves your edits; Vault-clobber protection)."
      exit 52
    fi
  elif [ "$sentinel_verified" = "1" ]; then
 # sentinel_verified is also set by the --i-understand-overwrite-risk
    # argv arm (with --force-install) at the top of the script, so a non-interactive
    # driver short-circuits this G2 read just as the single-ceremony G1-main reuse does.
    info "G2: sentinel reused from G1-main / --i-understand-overwrite-risk argv arm; proceeding under --force-install"
  else
    printf 'install: type I-UNDERSTAND-OVERWRITE-RISK to confirm G2 override (or pass --i-understand-overwrite-risk): ' >&2
    sentinel=""
    if ! IFS= read -r sentinel; then
      diag "G2 fired: sentinel not provided (stdin EOF). Pass --i-understand-overwrite-risk or pipe the I-UNDERSTAND-OVERWRITE-RISK token. Aborting."
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

# --- Version detection (read side) ---
# Runs at entrypoint, BEFORE state-classification. Reads the installed-state
# stamp (write side lives post-Step-13.5 below) and the shipped manifest
# version, and compares them via vercmp. This stage only DETECTS + COMPARES; it does
# NOT fork the run on the result — the upgrade entrypoint posture (refuse on
# downgrade/major, dry-run-vs-apply gate) is its surface. These
# variables are the substrate every later upgrade-engine task consumes.
#
#   INSTALLED_VERSION — foundation_version from
#     $CLAUDE_HOME/governance/.installed-state.json. Absent ⇒ "(none)" ⇒ this
#     is a fresh install or a pre-upgrade-engine (legacy-adopt) install — NEVER
# an error (a missing stamp is the expected first-run / a legacy adopter case).
#   TARGET_VERSION   — .version from $SOURCE_REPO/governance/foundation-manifest.json
#     (the shipped manifest; already carries "v1.0.2").
#   VERSION_DELTA    — vercmp outcome: equal | target>installed | target<installed
#     | target>installed-fresh-or-legacy (no stamp to compare against).
INSTALLED_STATE_PATH="$CLAUDE_HOME/governance/.installed-state.json"
INSTALLED_BASELINE_MANIFEST_PATH="$CLAUDE_HOME/governance/.installed-baseline-manifest.json"
INSTALLED_VERSION="(none)"
# PRIOR_MIGRATIONS_APPLIED — the high-water log already on disk (newline-
# separated migration ids), read here so the Step 13.7 stamp can PRESERVE it
# and the runner can skip already-applied ids. Absent on a
# fresh/legacy-adopt home ⇒ empty ⇒ the runner runs the full chain from 0001.
PRIOR_MIGRATIONS_APPLIED=""
if [ -f "$INSTALLED_STATE_PATH" ]; then
  iv="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('foundation_version',''))" "$INSTALLED_STATE_PATH" 2>/dev/null || true)"
  [ -n "$iv" ] && INSTALLED_VERSION="$iv"
  PRIOR_MIGRATIONS_APPLIED="$(python3 -c "import json,sys
try:
    d=json.load(open(sys.argv[1]))
    for m in d.get('migrations_applied',[]):
        print(m)
except Exception:
    pass" "$INSTALLED_STATE_PATH" 2>/dev/null || true)"
fi
TARGET_VERSION=""
if [ -f "$SOURCE_REPO/governance/foundation-manifest.json" ]; then
  TARGET_VERSION="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('version',''))" "$SOURCE_REPO/governance/foundation-manifest.json" 2>/dev/null || true)"
fi
if [ "$INSTALLED_VERSION" = "(none)" ]; then
  # No stamp on disk ⇒ fresh-or-legacy-adopt; never an error. A target>floor
  # delta is implied (everything is newer than an absent installed version),
 # but the legacy-adopt floor reconstruction is its surface.
  VERSION_DELTA="target>installed-fresh-or-legacy"
elif [ -z "$TARGET_VERSION" ]; then
  VERSION_DELTA="unknown-target"
else
  case "$(vercmp "$TARGET_VERSION" "$INSTALLED_VERSION")" in
    'equal') VERSION_DELTA="equal" ;;
    'a>b')   VERSION_DELTA="target>installed" ;;
    'a<b')   VERSION_DELTA="target<installed" ;;
    *)       VERSION_DELTA="unknown-target" ;;
  esac
fi
info "version detection: installed=$INSTALLED_VERSION target=${TARGET_VERSION:-(unknown)} delta=$VERSION_DELTA"

# --- legacy-adopt detection + governance/baselines/ floor-match ---
# The legacy-adopt case: v0.0.0 bootstrap-from-empty.
#
# a legacy adopter force-installed an OLDER brain-stem that predates the upgrade engine, so
# her home has NO .installed-state.json stamp BUT carries a foundation marker
# (governance/foundation-master.json). That is NOT a fresh install — it is a
# legacy-adopt: she must INHERIT the engine + the fixes without a clean
# reinstall. Detection: .installed-state.json absent AND a foundation marker
# present ⇒ LEGACY_ADOPT=1.
#
# BLOCKING CORRECTION (version-detection + per-file-disposition): governance/
# baselines/ ships with at least the v1.0.2 manifest (minted at release-cut; see
# the release-ceremony step in the upgrade-engine ADR). The sha256-floor-match
# (pick the highest archived baseline whose file set her disk satisfies) is a v2
# OPTIMIZATION that requires >=2 archived baselines; with a single archived
# baseline it cannot establish a real floor, so the SOLE operative legacy-adopt
# path TODAY is v0.0.0 + the full idempotent migration chain from 0001 (the
# Flyway bootstrap-from-empty property — every migration tolerates the oldest/
# empty precondition per the authoring contract). INSTALLED_VERSION stays
# "(none)" so the Step-13.6 runner normalizes the floor to v0.0.0 and runs the
# full chain WITHOUT min_from-skipping (FLOOR_IS_REAL=0).
#
# LEGACY_ADOPT_BASELINES_DIR — the shipped historical-manifest archive. Its
# per-file shas are the "reachable historical sha" set the legacy-adopt take-new
# disposition (the upgrade_foundation_file() routine below) consults to decide
# whether to snapshot an on-disk file to .foundation-local.
FOUNDATION_MARKER="$CLAUDE_HOME/governance/foundation-master.json"
LEGACY_ADOPT=0
LEGACY_ADOPT_BASELINES_DIR="$SOURCE_REPO/governance/baselines"
if [ ! -f "$INSTALLED_STATE_PATH" ] && [ -f "$FOUNDATION_MARKER" ]; then
  LEGACY_ADOPT=1
  # Floor-match (sha256-matching the adopter's on-disk files against the archived
  # per-release baselines to reconstruct a real installed floor) is a v2 feature
  # whose matching LOGIC is NOT YET IMPLEMENTED. baselines/ accrues one frozen
  # manifest per release-cut as the historical record floor-match v2 will consume;
  # the count is NOT a graduation trigger — the v0.0.0 full-chain path holds at ANY
  # baseline count until the v2 logic ships. Report the count for operator visibility.
  baseline_count=0
  if [ -d "$LEGACY_ADOPT_BASELINES_DIR" ]; then
    for _bl in "$LEGACY_ADOPT_BASELINES_DIR"/foundation-manifest-v*.json; do
      [ -e "$_bl" ] && baseline_count=$((baseline_count + 1))
    done
  fi
  info "state: legacy-adopt detected (foundation marker present, no .installed-state.json stamp); floor reconstructed as v0.0.0 + full migration chain from 0001 (floor-match is a v2 feature, not yet implemented; $baseline_count archived baseline(s) on record). The fixes land via FOUNDATION-REPLACE take-new."
fi

# --- upgrade entrypoint posture ---
# Forks the run on the version-detect result (version-detect only DETECTS+COMPARES; this
# is the posture over the existing pipeline — exactly as --apply is a posture over
# the G9 dry-run). Runs after version-detect, before state-classification, so
# every refuse here is a pre-flight decision the action-plan/apply both honor.
#
# UPGRADE_PRESENT — an .installed-state.json stamp is on disk ⇒ this is an
#   upgrade lane (not fresh, not legacy-adopt). The decommission of --force-all
# and the --upgrade assertion key off this.
UPGRADE_PRESENT=0
[ -f "$INSTALLED_STATE_PATH" ] && UPGRADE_PRESENT=1

# (1) --upgrade assertion: `--upgrade` is an optional assertion that an
#     installed version exists; it fails fast if the home is actually fresh
#     (no stamp). Action stays gated by --apply (Option C); --upgrade alone in
#     dry-run still emits the action-plan. Exit 10 (prereq family: the asserted
#     precondition — an installed version to upgrade FROM — is missing).
if [ "$UPGRADE_MODE" = "1" ] && [ "$UPGRADE_PRESENT" != "1" ]; then
  diag "--upgrade asserts an installed version exists, but no \$CLAUDE_HOME/governance/.installed-state.json stamp is present (this is a fresh or legacy-adopt install). Re-run WITHOUT --upgrade for a fresh install."
  exit 10
fi

# (2) --force-all decommissioned for the upgrade path: --force-all is the
#     blunt cp -f clobber that bypasses the per-file disposition + USER-PRESERVE
#     boundary; it survives ONLY for fresh-install/force-reinstall and is
#     explicitly REFUSED when .installed-state.json is present. No override.
#     Exit 23 (the upgrade-path refuse family; downgrade shares it below — both
#     are "this is not a legitimate upgrade action" refusals with no force lane).
# the decommission now ALSO fires on the
#     legacy-adopt lane (LEGACY_ADOPT=1, classified at the FOUNDATION_MARKER check
# above). Before the legacy lane silently ACCEPTED --force-all and
#     set cp_clobber=-f (the de-facto undocumented no-snapshot clobber path — the
# only blunt-clobber escape on the rescue lane). The per-file engine
#     now delivers the legacy subtree correctly via upgrade_foundation_file()'s
#     take-new (+ .foundation-local snapshot of genuine adopter edits), so there is
#     no remaining need for a force-all escape on a legacy adopt. Refuse when
#     FORCE_ALL=1 AND (UPGRADE_PRESENT=1 OR LEGACY_ADOPT=1); a fresh install /
#     force-reinstall (neither stamped nor a foundation-marker-present legacy home)
#     KEEPS the existing --force-all → cp_clobber=-f posture (1373-1374).
if [ "$FORCE_ALL" = "1" ] && { [ "$UPGRADE_PRESENT" = "1" ] || [ "$LEGACY_ADOPT" = "1" ]; }; then
  if [ "$LEGACY_ADOPT" = "1" ] && [ "$UPGRADE_PRESENT" != "1" ]; then
    diag "--force-all is decommissioned for the legacy-adopt lane (a foundation home with no \$CLAUDE_HOME/governance/.installed-state.json stamp but a governance/foundation-master.json marker present). The per-file delivery engine now lands every managed file via the sha256 disposition take-new (+ .foundation-local snapshot of genuine adopter edits) — there is no blunt-clobber escape needed on the legacy rescue lane. Drop --force-all and re-run."
  else
    diag "--force-all is decommissioned for the upgrade path (refused when \$CLAUDE_HOME/governance/.installed-state.json is present). The upgrade walk uses the per-file sha256 disposition + the USER-PRESERVE boundary; there is no blunt-clobber escape on an upgrade. Drop --force-all and re-run."
  fi
  exit 23
fi

# (3) downgrade refuse: target < installed ⇒ refuse, exit 23, NO --force
#     override (down-migrations do not exist; is forward-only). Only fires on
#     a real installed stamp (the fresh-or-legacy delta is never a downgrade).
if [ "$VERSION_DELTA" = "target<installed" ]; then
  diag "downgrade refused: target=$TARGET_VERSION < installed=$INSTALLED_VERSION. The upgrade engine is forward-only (no down-migrations); there is no --force override for a downgrade. Install the newer source or leave the installed version in place."
  exit 23
fi

# (4) major-bump refuse on --apply alone: target.major > installed.major
#     refuses a silent auto-upgrade. The --apply lane requires --migrate-major
#     AND the I-UNDERSTAND-OVERWRITE-RISK sentinel ceremony (sentinel_verified
#     is set by the --i-understand-overwrite-risk argv arm +
#     --force-install). Dry-run (APPLY_MODE!=1) records the required
#     ack and CONTINUES to the action-plan (defer-in-dry-run posture); the
#     --apply lane hard fail-fasts here. Exit 23 (upgrade-path refuse family).
#     Major comparison uses the same octal-guarded base-10 coercion as vercmp.
if [ "$UPGRADE_PRESENT" = "1" ] && [ "$INSTALLED_VERSION" != "(none)" ] && [ -n "$TARGET_VERSION" ]; then
  t_major="${TARGET_VERSION#v}"; t_major="${t_major%%.*}"; t_major="${t_major%%[!0-9]*}"
  i_major="${INSTALLED_VERSION#v}"; i_major="${i_major%%.*}"; i_major="${i_major%%[!0-9]*}"
  [ -n "$t_major" ] || t_major=0
  [ -n "$i_major" ] || i_major=0
  if [ "$((10#$t_major))" -gt "$((10#$i_major))" ]; then
    if [ "$MIGRATE_MAJOR" = "1" ] && [ "$sentinel_verified" = "1" ]; then
      info "major-version bump ($INSTALLED_VERSION -> $TARGET_VERSION) acked via --migrate-major + I-UNDERSTAND-OVERWRITE-RISK sentinel (ceremony); proceeding"
    elif [ "$APPLY_MODE" = "1" ]; then
      diag "major-version bump refused: target.major ($TARGET_VERSION) > installed.major ($INSTALLED_VERSION). A silent auto-upgrade across a major boundary is refused. Pass --migrate-major AND the I-UNDERSTAND-OVERWRITE-RISK sentinel (--i-understand-overwrite-risk with --force-install) to proceed."
      exit 23
    else
      # dry-run: aggregate the requirement into the action-plan (defer-in-dry-run posture).
      note_required_override "--migrate-major + I-UNDERSTAND-OVERWRITE-RISK sentinel (major-version bump: target.major $TARGET_VERSION > installed.major $INSTALLED_VERSION)"
      info "major-version bump ($INSTALLED_VERSION -> $TARGET_VERSION) detected; dry-run records the --migrate-major + sentinel ack requirement (action-plan aggregates it)"
    fi
  fi
fi

# --- State classification (write-sequence + installer exit codes) ---
# Walks $CLAUDE_HOME entries and classifies state once after G2 close + before
# G3 gate. Reuses foundation_known_entries set already declared above for
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

# refine a foundation-bearing classification to legacy-adopt when
# the entrypoint detected LEGACY_ADOPT (foundation marker present, no
# .installed-state.json stamp). This is the new state_classification VALUE the
# design calls for — it surfaces in the dry-run JSON + provenance so a
# legacy adopter (a legacy adopter) is never mis-classified as a plain fresh install. It is
# applied ONLY over foundation-bearing states (foundation-only/mixed); it never
# overrides user-only (which must still refuse without --force-install) or fresh
# (no marker ⇒ no legacy-adopt by definition).
if [ "$LEGACY_ADOPT" = "1" ] \
   && { [ "$state_classification" = "foundation-only" ] || [ "$state_classification" = "mixed" ]; }; then
  state_classification="legacy-adopt"
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
g3_settings_backup_path=""
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
 # G3: the writability round-trip above is
  # necessary-not-sufficient — a flag named --backup-dir must produce a RESTORABLE
  # artifact (principle of least astonishment; dpkg/rpm take a real conffile backup
  # before overwrite). When a destructive op is pending (a pre-existing
  # settings.json that Step 12's `mv -f` will overwrite), copy the REAL pre-merge
  # settings.json into $BACKUP_DIR/settings.json.pre-install-<ts> BEFORE that mv,
  # exiting 53 if the copy fails. Gated on APPLY_MODE=1 so the dry-run lane stays
 # provably write-free (invariant); a fresh install (no pre-existing
  # settings.json → g3_destructive_op_pending=0) writes NO copy. Timestamp format +
  # cp idiom reuse uninstall.sh's .pre-uninstall-<ts> backup. This is the narrow
  # settings.json-only honest-backup fix for the non-upgrade/fresh-install
  # destructive-mv path; the FULL pre-mutation snapshot is the upgrade engine's concern.
  # The deferred v2.1 whole-tree rsync is NOT pulled in.
  if [ "$APPLY_MODE" = "1" ] && [ "$g3_destructive_op_pending" = "1" ]; then
    g3_backup_ts="$(date -u +%Y%m%d-%H%M%S)"
    g3_settings_backup_path="$BACKUP_DIR/settings.json.pre-install-$g3_backup_ts"
    if ! cp "$CLAUDE_HOME/settings.json" "$g3_settings_backup_path" 2>/dev/null; then
      diag "G3 fired: settings.json backup copy failed: $CLAUDE_HOME/settings.json -> $g3_settings_backup_path. No backup -> no install."
      g3_settings_backup_path=""
      exit 53
    fi
    info "G3: settings.json backed up to $g3_settings_backup_path"
  fi
elif [ "$g3_destructive_op_pending" = "1" ]; then
 # dry-run defers (records the missing --backup-dir override + continues
  # so the action-plan can aggregate it alongside the G1-main sentinel requirement in
  # ONE pass); --apply still hard fail-fasts exit 53 at the mutation boundary.
  if [ "$APPLY_MODE" != "1" ]; then
    note_required_override "--backup-dir <path> (G3: \$CLAUDE_HOME/settings.json pre-exists; a destructive Step-12 mv is pending and requires a backup)"
    g3_skip_reason="destructive op pending but --backup-dir not supplied (deferred in dry-run; recorded in required_overrides)"
  else
    diag "G3 fired: \$CLAUDE_HOME/settings.json pre-exists (destructive op pending); --backup-dir <path> required for proof-of-life. No backup → no install."
    exit 53
  fi
else
  g3_skip_reason="no destructive op pending (no pre-existing settings.json) and --backup-dir not supplied"
fi

# =============================================================================
# convergence-not-version no-op semantics
# (no-op upgrade emits file_dispositions:[] +
#   migrations_to_run:[]) + line 34 (equal outcome) ·
#   /tmp/wfv/wfv-full.json::upgrade_validations[idempotency-rollback]
#   (provable-no-op = converged home, NOT equal version) +
#   consolidated.blocking_corrections[6] (upgrade-arch/idempotency).
#
# THE BLOCKING CORRECTION (rewrite the provable-no-op acceptance): the no-op
# condition is an already-CONVERGED home, NOT an equal version. The two no-op
# claims are DISTINCT and gated on DIFFERENT signals:
#
#   (1) migration no-op  -> migrations_to_run == []  is VERSION-DELTA-gated:
#       it is [] exactly when the half-open range (INSTALLED_VERSION,
#       TARGET_VERSION] selects nothing (every equal/empty-range upgrade). This
#       is the correct, version-keyed gate (selection).
#
#   (2) convergence no-op -> file_dispositions == []  is STATE-gated, NOT
# version-gated. The hook reconciler, the FOUNDATION-REPLACE
# disposition walk, and the gitignore-backfill/git-init are
#       convergence steps that run REGARDLESS of from/to version. file_dispositions
#       is [] ONLY when the on-disk state already matches the target. A
#       v1.0.2->v1.0.2 re-apply on a home that is MISSING a foundation hook (the
# exact regression) MUST take an action (the reconciler
#       appends the hook) and therefore file_dispositions is NOT [] — equal
#       version does NOT imply no-op. Repairing drift at equal version IS the
# fix landing.
#
# This block COMPUTES both signals WRITE-FREE (read-only against the already-
# built home — managed files, settings.json, the migrations dir, and the
# .installed-state.json/.installed-baseline-manifest.json stamps are all on disk
# at dry-run time). It populates two newline-joined accumulators threaded into
# the G9 dry-run JSON below as `migrations_to_run` and `file_dispositions`. The
# arrays are EMPTY iff converged / empty-range — the provable no-op. The
# disposition-class + reason/added_hooks ENRICHMENT and the changelog_slice are
# its layer ON TOP of these arrays; the convergence engine owns the convergence
# COMPUTATION + the two distinct empty-gates + the acceptance harness.
#
# Invariant: zero $CLAUDE_HOME writes — pure reads + a single
# self-cleaning $TMPDIR scratch for the reconciler before/after diff.

# legacy_historical_shas is DEFINED here (above the G9 dry-run preview) so the
# preview classifier can consult the SAME reachable-historical-sha set the apply
# walk's take-new state uses — the definition must precede its first use in the
# preview block below. Depends only on LEGACY_ADOPT_BASELINES_DIR + python3.
# reachable-historical-sha resolver for the legacy-adopt lane.
# legacy_historical_shas <manifest-rel-path> → prints the per-file sha256 for
# that path from EVERY shipped governance/baselines/foundation-manifest-v*.json
# (one per line). This is the "any reachable historical sha" set the legacy-adopt
# take-new disposition consults: an on-disk file that matches ANY reachable
# historical sha is a known unmodified prior release ⇒ no .foundation-local
# snapshot needed (take-new is clean). A mismatch against ALL of them ⇒ adopter-
# modified ⇒ snapshot to .foundation-local before take-new. With a single shipped
# baseline today this set is the v1.0.2 per-file shas; >=2 baselines is the v2
# floor-match precondition.
legacy_historical_shas() {
  local rel="$1"
  [ -d "$LEGACY_ADOPT_BASELINES_DIR" ] || return 0
  REL="$rel" BLDIR="$LEGACY_ADOPT_BASELINES_DIR" python3 -c '
import glob, json, os, sys
rel = os.environ["REL"]
for path in sorted(glob.glob(os.path.join(os.environ["BLDIR"], "foundation-manifest-v*.json"))):
    try:
        m = json.load(open(path))
    except Exception:
        continue
    for f in m.get("files", []):
        if f.get("path") == rel:
            s = f.get("sha256", "")
            if s:
                print(s)
            break
' 2>/dev/null
}


upgrade_migrations_to_run=""   # newline-joined selected migration ids (version-delta-gated)
upgrade_file_disp_preview=""   # newline-joined "<path>\t<would-disposition>" (state-gated)
# admit LEGACY_ADOPT=1 so a stamp-less
# legacy adopter's dry-run computes real cp -R subtree dispositions instead of [].
# Pre-fix the whole preview was gated UPGRADE_PRESENT=1 (false for every legacy
# adopter), so the documented `install.sh | jq .` preview emitted file_dispositions:[]
# + mode:'install'. The disposition walk below already enumerates from the SHIPPED
# $SOURCE_REPO files[] (never a disk-walk) with `IFS=<tab> read -r` for
# space-bearing paths, and degrades a no-baseline (legacy) would-mutate to
# `replace` take-new — never silently to `sidecar` (legacy take-new). The
# migration-select sub-block (1) normalizes a "(none)" floor to v0.0.0, so legacy
# runs the full chain. WRITE-FREE: pure reads + self-cleaning $TMPDIR.
if [ "$UPGRADE_PRESENT" = "1" ] || [ "$LEGACY_ADOPT" = "1" ]; then
  # --- (1) migration no-op: select {id NOT IN high-water log AND applies_at <=
  #     TARGET_VERSION}, READ-ONLY (the runner's set-difference selection predicate
  #     — run-migrations.sh header contract; floor is diagnostic-only — without
  #     executing any migration). Self-contained header read so this stays inside
  #     the "install.sh" deliverable (no dependency on sourcing the runner).
  #     Enumerate the candidate SET from the SHIPPED TARGET manifest
  #     (foundation-manifest.json files[], installer/migrations/ prefix) — the SAME
  #     enumeration source-of-truth the Step 8.2 apply lane copies to
  #     $CLAUDE_HOME/migrations, so preview and apply share ONE literal source-of-truth.
  #     The applies_at header is still read from the file on disk; only the SET is
  #     manifest-driven. A loud WARN (stderr — dry-run stdout stays clean JSON) fires when
  #     the on-disk NNNN glob holds a file outside the manifest set (hand-modified clone).
  #     Reading the PRE-copy $CLAUDE_HOME/migrations instead reported migrations_to_run:[]
  #     for every adopter (the release's new migrations are not on disk until AFTER this
  #     preview runs), so preview != apply for a corpus-mutating release. High-water dedup
  #     still consults $PRIOR_MIGRATIONS_APPLIED (below), the already-applied set.
  if [ -n "$TARGET_VERSION" ] && [ -d "$SOURCE_REPO/installer/migrations" ]; then
    _mig_floor="$INSTALLED_VERSION"
    [ "$_mig_floor" = "(none)" ] && _mig_floor="v0.0.0"
    # The candidate SET is the shipped-manifest installer/migrations members (same SoT as
    # the Step 8.2 apply lane); headers are still read from the file on disk below.
    _mig_manifest_set="$(SHIPPED_MANIFEST="$SOURCE_REPO/governance/foundation-manifest.json" python3 -c '
import json, os, sys
try:
    m = json.load(open(os.environ["SHIPPED_MANIFEST"]))
except Exception:
    sys.exit(0)
for f in m.get("files", []):
    p = f.get("path", "")
    if p.startswith("installer/migrations/") and p.endswith(".sh"):
        b = p.rsplit("/", 1)[-1]
        if b[:4].isdigit():
            print(b)
' 2>/dev/null)"
    # stray-glob WARN (stderr; dry-run stdout stays clean JSON): an on-disk NNNN-*.sh not
    # in the manifest set is a hand-modified-clone stray, excluded from the preview.
    for _migf in "$SOURCE_REPO/installer/migrations"/[0-9][0-9][0-9][0-9]-*.sh; do
      [ -e "$_migf" ] || continue
      _mb="${_migf##*/}"
      printf '%s\n' "$_mig_manifest_set" | grep -qxF "$_mb" || \
        warn "G9 preview: on-disk migration $_mb is absent from the shipped manifest set — excluded from the preview (retired surface or hand-added clone drift)"
    done
    for _mb in $_mig_manifest_set; do
      _migf="$SOURCE_REPO/installer/migrations/$_mb"
      [ -f "$_migf" ] || continue
      # read the leading-comment `# migration:` and `# applies_at:` headers only
      _mig_id=""; _mig_aa=""
      while IFS= read -r _hl; do
        case "$_hl" in
          \#*) ;;
          '') continue ;;
          *) break ;;
        esac
        case "$_hl" in
          "# migration:"*) _mig_id="${_hl#*: }"; _mig_id="${_mig_id%%[[:space:]]*}" ;;
          "# applies_at:"*) _mig_aa="${_hl#*: }"; _mig_aa="${_mig_aa%%[[:space:]]*}" ;;
        esac
      done < "$_migf"
      [ -n "$_mig_id" ] || _mig_id="$(basename "$_migf" .sh)"
      [ -n "$_mig_aa" ] || continue   # no applies_at => unplaceable => not selected
      # selection (mirrors the runner set-difference): applies_at <= target AND the id is
      # NOT already applied (the high-water skip below). The strictly-above-floor clause is
      # DIAGNOSTIC only, NOT a selection filter — so a bitten adopter (stamp advanced past
      # applies_at) sees the same heal set the runner will run. ($_mig_floor stays computed
      # for the legacy (none)->v0.0.0 normalization; it no longer gates selection.)
      [ "$(vercmp "$_mig_aa" "$TARGET_VERSION")" = "a>b" ] && continue
      # high-water skip (already applied => not in the to-run set)
      if [ -n "$PRIOR_MIGRATIONS_APPLIED" ] && printf '%s\n' "$PRIOR_MIGRATIONS_APPLIED" | grep -qxF "$_mig_id"; then
        continue
      fi
      if [ -z "$upgrade_migrations_to_run" ]; then
        upgrade_migrations_to_run="$_mig_id"
      else
        upgrade_migrations_to_run="$upgrade_migrations_to_run
$_mig_id"
      fi
    done
  fi

  # --- (2a) FOUNDATION-REPLACE convergence: a managed files[] path whose on-disk
  #     sha256 differs from the NEW-upstream sha256 (the source manifest) would be
  #     replaced. Equal sha on every managed file => this source contributes [].
 #
 # The would-replace is a THREE-STATE disposition mirroring the apply-path
  #     gear (install.sh upgrade_foundation_file State 2/State 3): when a frozen
  #     baseline manifest (.installed-baseline-manifest.json) resolves a per-file
  #     baseline sha, the dry-run distinguishes the two FOUNDATION-REPLACE outcomes
 # the schema names (file_dispositions[] +
 # lines 100-101):
  #       - on-disk == baseline (adopter UNMODIFIED) => `replace` (clean take-new).
  #       - on-disk != baseline (adopter EDITED owned code) => `sidecar` (take-new
  #         BUT snapshot her bytes to <path>.foundation-local, dpkg .dpkg-old). This
  #         is the `3way-merge|conflict→sidecar` FOUNDATION-REPLACE branch the
  #         the apply path records as `replace+foundation-local`.
  #     When NO frozen baseline resolves the path (fresh / legacy-adopt with no
  #     archived floor), it cannot prove unmodified-ness, so it degrades to the
  #     legacy take-new default (`replace`) — never silently to `sidecar`. Baseline
  #     read is WRITE-FREE (read of the on-disk .installed-baseline-manifest.json).
  _src_manifest="$SOURCE_REPO/governance/foundation-manifest.json"
  _base_manifest="$INSTALLED_BASELINE_MANIFEST_PATH"
  _have_base=0
  [ -f "$_base_manifest" ] && _have_base=1
  if [ -f "$_src_manifest" ]; then
    while IFS="$(printf '\t')" read -r _rel _newsha; do
      [ -n "$_rel" ] || continue
      _ondisk="$CLAUDE_HOME/$_rel"
      # Outstanding <path>.foundation-new sidecar → walk-mirror SKIP, evaluated per
      # managed file at the TOP of the pass — BEFORE both the sha-mismatch gate below
      # AND the absent-dest new-ship branch. A parked sidecar means a PRIOR merge
      # deferred to the user; the apply walk SKIPs the file (sidecar-skip-deferred) at
      # the top of its own per-file pass — ahead of its absent→new-ship,
      # on-disk==baseline→replace and on-disk!=baseline→sidecar states — and does NOT
      # re-take-new until the user resolves it. Consulting it here (not nested inside
      # the sha-mismatch gate) keeps the preview from promising a no-op ([] on
      # converged bytes) or a delivery (new-ship on an absent dest) the apply will
      # actually defer. Lane-scoped to the stamped-upgrade lane (UPGRADE_PRESENT=1) —
      # the dry-run mirror of the walk's envelope condition; the legacy take-new lane
      # never sidecar-skips, so the preview must not show one there. The dedicated-gear
      # rels (.gitignore + overlay-master) route to their own merge gears, never
      # through the take-new/sidecar path, and never park a sidecar → excluded here.
      if [ "$UPGRADE_PRESENT" = "1" ] \
         && [ "$_rel" != ".gitignore" ] \
         && [ "$_rel" != "governance/overlay-master.json" ] \
         && [ -e "$_ondisk.foundation-new" ]; then
        upgrade_file_disp_preview="${upgrade_file_disp_preview}${_rel}	sidecar-skip-deferred
"
        continue
      fi
      if [ -f "$_ondisk" ]; then
        _disksha="$(shasum -a 256 "$_ondisk" 2>/dev/null | awk '{print $1}')"
        if [ -n "$_disksha" ] && [ "$_disksha" != "$_newsha" ]; then
          # Step 11.8: the installed .gitignore is a THREE-WAY-MERGE surface, NOT a
          # replace/sidecar one — --apply appends the managed block behind the
          # `# brain-stem: managed secret-exclusions` sentinel (preserving the adopter's own
          # ignore rules) or no-ops when the sentinel is already present; it NEVER take-news /
          # sidecars .gitignore. Sha-compare to the pinned pristine-template sha is the wrong
          # convergence signal for it (it diverges by design for any adopter with own rules, or
          # whenever the template changed across versions and the idempotent guard no-ops the
          # re-append). Model the apply path instead, mirroring the Step 13.6 delivery-gate
          # three-way-merge EXEMPT_KIND:
          #   - sentinel present => the managed block is already merged => a re-apply is the
          #     Step 11.8 idempotent no-op => CONVERGED (emit no disposition, exempt).
          #   - sentinel absent  => --apply WOULD append the managed block => surface the
          #     actionable, non-destructive `three-way-merge` disposition (what the apply path
          #     records at Step 11.8), NOT a replace/sidecar clobber.
          if [ "$_rel" = ".gitignore" ]; then
            if grep -qF '# brain-stem: managed secret-exclusions' "$_ondisk" 2>/dev/null; then
              continue
            fi
            upgrade_file_disp_preview="${upgrade_file_disp_preview}${_rel}	three-way-merge
"
            continue
          fi
          # governance/overlay-master.json is a THREE-WAY-MERGE surface too — the apply
          # walk routes it through upgrade_overlay_master (OVERLAY-WINS jq merge →
          # skeleton-merge), NEVER the generic take-new/sidecar branch (that would clobber
          # the adopter's /govern registrations). On-disk != shipped skeleton means the
          # registrations diverge from the new skeleton; --apply MERGES them (registrations
          # preserved, new foundation pillars added). Preview the INTENDED gear
          # (skeleton-merge); a runtime merge failure downgrades to skeleton-merge-skip (the
          # enrichment reason notes it). Mirrors the .gitignore carve-out shape — the
          # ratified inline-elif idiom.
          if [ "$_rel" = "governance/overlay-master.json" ]; then
            upgrade_file_disp_preview="${upgrade_file_disp_preview}${_rel}	skeleton-merge
"
            continue
          fi
          # would-mutate. Three-state disambiguation via the frozen baseline.
          # (The outstanding-.foundation-new sidecar SKIP is consulted at the top of
          # this loop, ahead of the sha-mismatch gate and the absent-dest branch, so it
          # is not re-checked here.)
          _disp="replace"
          if [ "$_have_base" = "1" ]; then
            _basesha="$(BMS="$_base_manifest" REL="$_rel" python3 -c '
import json, os, sys
try:
    m = json.load(open(os.environ["BMS"]))
except Exception:
    sys.exit(3)
rel = os.environ["REL"]
for f in m.get("files", []):
    if f.get("path") == rel:
        print(f.get("sha256", "")); sys.exit(0)
sys.exit(2)
' 2>/dev/null)"
            # baseline resolved AND on-disk != baseline => adopter EDITED => sidecar.
            if [ -n "$_basesha" ] && [ "$_disksha" != "$_basesha" ]; then
              _disp="sidecar"
              # before previewing sidecar, consult the SAME legacy_historical_shas
              # resolver the apply walk's take-new state uses. An on-disk file matching
              # ANY reachable historical release sha is a KNOWN prior-release build (not
              # an adopter edit) → the walk clean-`replace`s with NO .foundation-local
              # sidecar (the misarchive fix, landed walk-side only). Mirror it so the
              # preview does not over-warn sidecar where the apply will clean-replace.
              for _s3_hist in $(legacy_historical_shas "$_rel"); do
                if [ -n "$_disksha" ] && [ "$_disksha" = "$_s3_hist" ]; then
                  _disp="replace"
                  break
                fi
              done
            fi
          fi
          upgrade_file_disp_preview="${upgrade_file_disp_preview}${_rel}	${_disp}
"
        fi
      else
        # a managed file absent on disk would be NEW-SHIP'd => not converged.
        upgrade_file_disp_preview="${upgrade_file_disp_preview}${_rel}	new-ship
"
      fi
    done <<EOF
$(jq -r '.files[] | "\(.path)\t\(.sha256)"' "$_src_manifest" 2>/dev/null)
EOF
  fi

 # --- (2b) hook-reconciler convergence: the EXACT
  #     missing-hook regression. Re-run the SHIPPED reconciler jq transform
  #     against a SCRATCH copy of the live settings.json (never the live file)
  #     and diff: if the transform would change settings.json (a foundation hook
  #     tuple is absent and would be appended), the home is NOT converged. This
  #     fires at EQUAL version — that is the convergence-not-version semantics.
  _live_settings="$CLAUDE_HOME/settings.json"
  _required_hooks_decl="$CLAUDE_HOME/templates/settings-required-hooks.json"
  if [ -f "$_live_settings" ] && [ -f "$_required_hooks_decl" ]; then
    _rec_after="$(mktemp 2>/dev/null || echo "")"
    if [ -n "$_rec_after" ]; then
      if jq \
        --slurpfile decl "$_required_hooks_decl" \
        '
        ($decl[0] | if type == "object" then .required_hooks else . end) as $tuples
        | reduce $tuples[] as $t (
            .;
            ($t.event)   as $ev
            | ($t.matcher)  as $mt
            | ($t.command)  as $cmd
            | ({"type":"command","command":$cmd}
                + (if ($t.timeout != null) then {"timeout":$t.timeout} else {} end)) as $hookobj
            # statusLine is structurally distinct — it lives at top-level
            # .statusLine.command, not under .hooks[$ev] — so re-land the foundation
            # command when .statusLine is absent or its .command diverges (parity with
            # the apply reconcile below; previews a shadowed statusLine reconcile).
            | if $ev == "statusLine"
              then
                ( if (.statusLine.command // "") == $cmd then .
                  else .statusLine = ({"type":"command","command":$cmd}) end )
            elif ([ (.hooks[$ev] // [])[]?.hooks[]?.command // "" ]
                   | any(. == $cmd))
              then .
              else
                .hooks[$ev] = (
                  (.hooks[$ev] // []) as $buckets
                  | ( [ $buckets | to_entries[]
                        | select((.value.matcher // null) == $mt) | .key ] | first ) as $idx
                  | if $idx == null then
                      $buckets + [
                        ( (if $mt != null then {"matcher":$mt} else {} end)
                          + {"hooks":[$hookobj]} )
                      ]
                    else
                      ( $buckets
                        | .[$idx].hooks = ((.[$idx].hooks // []) + [$hookobj]) )
                    end
                )
              end
          )
        ' "$_live_settings" > "$_rec_after" 2>/dev/null; then
        # canonical-form diff: reconciler is ADDS-only, so any difference is a
        # would-append (a missing foundation hook tuple). Compare jq-canonical.
        if ! jq -S . "$_live_settings" 2>/dev/null | diff -q - <(jq -S . "$_rec_after" 2>/dev/null) >/dev/null 2>&1; then
          upgrade_file_disp_preview="${upgrade_file_disp_preview}settings.json	reconcile-hooks
"
        fi
      fi
      rm -f "$_rec_after" 2>/dev/null || true
    fi
  fi

 # --- (2c) USER-PRESERVE visibility (copied-once-then-adopter-owned set):
 # the schema (line 215) requires the upgrade
  #     diff to surface the USER-PRESERVE class explicitly —
  #       {path:"MEMORY.md", class:"USER-PRESERVE", disposition:"untouched"}
  #     — so an operator SEES that her copied-once surfaces are structurally NOT
 # written (anything not in files[] is unmanaged + never touched; the
  #     apply walk records `user-preserve-skip`). These are informational, no-
  #     action entries.
 #
  #     CONVERGED no-op invariant (lines 228-232): file_dispositions
  #     is [] ONLY when the home already matches the target. An informational
  #     `untouched` entry must NOT itself make a fully-converged home non-empty, so
  #     the USER-PRESERVE entries are appended ONLY WHEN >=1 actionable disposition
  #     (replace/sidecar/new-ship/reconcile-hooks/skeleton-merge*/sidecar-skip-deferred)
  #     is already present — i.e. an actual upgrade is being previewed. WRITE-FREE: only tests
 # on-disk presence of the copied-once surfaces. Emitted in order.
  if [ -n "$upgrade_file_disp_preview" ]; then
    # governance/anchored-spoke-registry.json is SEED-ONCE / USER-PRESERVE-by-omission
    # (dropped from foundation-manifest.json files[]; delivered seed-if-absent at Step 8.5)
    # — surface it in the same informational class as the other copied-once surfaces.
    for _up_rel in MEMORY.md rules/README.md governance/anchored-spoke-registry.json; do
      if [ -f "$CLAUDE_HOME/$_up_rel" ]; then
        upgrade_file_disp_preview="${upgrade_file_disp_preview}${_up_rel}	untouched
"
      fi
    done
  fi
fi

# =============================================================================
# upgrade-diff dry-run preview enrichment (UX)
# (lines 147-176, upgrade diff/preview JSON + UX
#   contract). LAYERED on the G9 dry-run action-plan JSON below + on the
#   convergence arrays computed above. WRITE-FREE: pure reads of
# CHANGELOG.md + the already-detected version vars (invariant).
#
# This block adds, for an install WITH .installed-state.json (the UPGRADE lane), the
# upgrade-diff body ON TOP of the upgrade-posture scaffold:
# - from_version / to_version: the SoT aliases of the installed/
#     target stamps (the existing installed_version/target_version fields are
#     retained verbatim — the landed contract — and from_version/
#     to_version are added as the schema names).
#   - version_delta_class       : the SEMANTIC delta (major|minor|patch|none|
#     unknown). NOTE: the existing `version_delta` field stays the RAW delta
#     ("target>installed"|"equal"|...) — the landed contract the
#     entrypoint/no-op harnesses assert against — so the semantic delta lands
#     in a DISTINCT field to avoid re-typing a frozen field.
#   - changelog_slice[]         : the CHANGELOG.md per-version headers in the
#     half-open range (installed, target], newest-first (the slice an operator
#     reads BEFORE --apply). Sliced from the Keep-a-Changelog `## [vX.Y.Z]`
#     section headers between `## [<installed>]` and `## [<target>]`.
#   - file_dispositions[]       : ENRICHED so each entry carries class + a human
# reason (and added_hooks for the reconcile-hooks entry) — the enrichment
#     is done inside the jq object below, mapping the disposition tokens
#     (replace|new-ship|reconcile-hooks) to {class, reason, added_hooks}.
#   - backup_required           : true on the upgrade lane (an upgrade --apply
#     with >=1 mutating action requires --backup-dir).
#   - requires_ack              : the major-bump ack string when target.major >
#     installed.major, else null (and --apply alone refuses — the major-bump gate enforces).
#
# This block runs ONLY in the dry-run lane gate below (it is read by the jq emit);
# it computes write-free and contributes nothing on the apply lane.
upgrade_changelog_slice=""   # newline-joined "## [vX.Y.Z]" headers in (installed,target]
upgrade_version_delta_class="" # major|minor|patch|none|unknown
upgrade_requires_ack=""      # major-bump ack string, "" when not a major bump
if [ "$UPGRADE_PRESENT" = "1" ]; then
  # --- (A) semantic version-delta class (major|minor|patch|none|unknown) -------
  # Reuse the octal-guarded base-10 coercion (matches vercmp / the major gate)
  # so an 08/09 segment cannot crash under set -euo pipefail.
  if [ "$INSTALLED_VERSION" != "(none)" ] && [ -n "$TARGET_VERSION" ]; then
    _iv="${INSTALLED_VERSION#v}"; _tv="${TARGET_VERSION#v}"
    _i_maj="${_iv%%.*}"; _i_rest="${_iv#*.}"; _i_min="${_i_rest%%.*}"; _i_pat="${_i_rest#*.}"; _i_pat="${_i_pat%%[!0-9]*}"
    _t_maj="${_tv%%.*}"; _t_rest="${_tv#*.}"; _t_min="${_t_rest%%.*}"; _t_pat="${_t_rest#*.}"; _t_pat="${_t_pat%%[!0-9]*}"
    _i_maj="${_i_maj%%[!0-9]*}"; _i_min="${_i_min%%[!0-9]*}"
    _t_maj="${_t_maj%%[!0-9]*}"; _t_min="${_t_min%%[!0-9]*}"
    [ -n "$_i_maj" ] || _i_maj=0; [ -n "$_i_min" ] || _i_min=0; [ -n "$_i_pat" ] || _i_pat=0
    [ -n "$_t_maj" ] || _t_maj=0; [ -n "$_t_min" ] || _t_min=0; [ -n "$_t_pat" ] || _t_pat=0
    if   [ "$((10#$_t_maj))" -ne "$((10#$_i_maj))" ]; then upgrade_version_delta_class="major"
    elif [ "$((10#$_t_min))" -ne "$((10#$_i_min))" ]; then upgrade_version_delta_class="minor"
    elif [ "$((10#$_t_pat))" -ne "$((10#$_i_pat))" ]; then upgrade_version_delta_class="patch"
    else upgrade_version_delta_class="none"
    fi
    # --- (B) major-bump requires_ack -------------------------------------
    # When target.major > installed.major, the preview MUST surface the
    # ack string and --apply alone refuses (the major-bump gate enforces the refuse).
    if [ "$((10#$_t_maj))" -gt "$((10#$_i_maj))" ]; then
      upgrade_requires_ack="--migrate-major + I-UNDERSTAND-OVERWRITE-RISK"
    fi
  else
    upgrade_version_delta_class="unknown"
  fi

  # --- (C) CHANGELOG slice over (installed, target] ----------------------------
  # The repo maintains CHANGELOG.md with Keep-a-Changelog per-version sections in
  # DESCENDING order (`## [vX.Y.Z]`). Slice the section HEADERS in the half-open
  # range (installed, target]: a header whose version is STRICTLY > installed AND
  # <= target. Newest-first (CHANGELOG order). Write-free read; absent CHANGELOG
  # => empty slice (the field is present-but-[]). Range-gated like migrations.
  _changelog="$SOURCE_REPO/CHANGELOG.md"
  if [ -f "$_changelog" ] && [ -n "$TARGET_VERSION" ]; then
    _cl_floor="$INSTALLED_VERSION"
    [ "$_cl_floor" = "(none)" ] && _cl_floor="v0.0.0"
    while IFS= read -r _cll; do
      case "$_cll" in
        "## ["*"]"*)
          _clv="${_cll#*[}"; _clv="${_clv%%]*}"
          # tolerate a leading 'v' or none; vercmp strips it.
          case "$_clv" in
            v[0-9]*|[0-9]*) ;;
            *) continue ;;   # not a version header (e.g. "## [Unreleased]")
          esac
          [ "$(vercmp "$_clv" "$_cl_floor")" = "a>b" ] || continue
          [ "$(vercmp "$_clv" "$TARGET_VERSION")" = "a>b" ] && continue
          if [ -z "$upgrade_changelog_slice" ]; then
            upgrade_changelog_slice="$_cll"
          else
            upgrade_changelog_slice="$upgrade_changelog_slice
$_cll"
          fi
          ;;
      esac
    done < "$_changelog"
  fi
fi

# --- G9: dry-run as default ---
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
 # DJ: every variable that carries user/path input is
  # passed through jq --arg so jq JSON-escapes it — a $CLAUDE_HOME / $SOURCE_REPO /
  # $BACKUP_DIR / $PLANS_HOME / state-root path containing ", \, or a control char
  # can no longer emit invalid JSON and break the documented `install.sh | jq` (G9)
  # consumer contract. Numeric flags (claude_home_defaulted, force_*, etc.) are
  # 0/1 integers and are interpolated as JSON numbers; the static action-plan
  # structure (steps/ops/rationale strings — no user input) is a jq literal.
 # DJ: "G7" is REMOVED from guards_passed — G7 is the
  # settings.json silent-key-deletion gate that runs only at Step 12 (~:1102),
  # AFTER this dry-run exit 0, so it was a false attestation. Every guard now in
  # guards_passed has a fire-site BEFORE this emit: G8 (176), G1-pre (185),
  # G5 (236), G1-main (270), G4 (318), G2 (375), G3 (601). G7 remains a
  # PLANNED action under actions[].step 12.
 # posture discriminator: an install WITH a .installed-state.json
  # stamp and a target>installed delta is the UPGRADE lane — its dry-run is the
  # upgrade-diff preview. The upgrade posture emits the `mode` posture + the upgrade argv
  # flags; the rich diff body (from_version/to_version, version_delta_class,
  # changelog_slice[], enriched file_dispositions[], backup_required, requires_ack)
 # is layered onto this SAME jq-safe object by (the compute block
  # just above this G9 gate). The semantic delta lands in version_delta_class;
  # the existing `version_delta` field stays the RAW delta (landed contract).
 # (convergence-not-version no-op semantics): the
  # write-free convergence-compute block above populated `migrations_to_run` and
  # `file_dispositions` (empty iff converged / empty-range). The two no-op claims
  # are DISTINCT: migrations_to_run==[] is VERSION-DELTA-gated (empty (installed,
  # target] range); file_dispositions==[] is STATE-CONVERGENCE-gated — it is []
  # ONLY when the on-disk state matches the target, so an equal-version re-apply
  # on a home MISSING a hook still emits a NON-empty file_dispositions (the
 # reconcile-hooks repair — the fix landing at equal version).
  # This block ENRICHES each file_dispositions entry (class/reason/added_hooks) and
  # adds changelog_slice on top of these arrays; the convergence engine owns the arrays + gating.
  dry_run_mode="install"
  if [ "$UPGRADE_PRESENT" = "1" ] && [ "$VERSION_DELTA" = "target>installed" ]; then
    dry_run_mode="upgrade"
  fi
 # a LEGACY_ADOPT home with a real version-delta
  # is the legacy-delivery preview — label it mode:'upgrade' (not 'install' with []).
  # Legacy carries no stamp so VERSION_DELTA reads "target>installed-fresh-or-legacy"
  # (the no-stamp delta at the version-detect block, :617); treat that as an upgrade
  # preview ONLY when a real target version exists AND the legacy disposition walk
  # actually found stale managed files to deliver (a fresh/empty legacy home with
  # nothing to replace stays mode:'install').
  if [ "$LEGACY_ADOPT" = "1" ] && [ -n "$TARGET_VERSION" ] \
     && [ "$VERSION_DELTA" = "target>installed-fresh-or-legacy" ] \
     && [ -n "$upgrade_file_disp_preview" ]; then
    dry_run_mode="upgrade"
  fi
  jq -n \
    --arg claude_home "$CLAUDE_HOME" \
    --arg source_repo "$SOURCE_REPO" \
    --arg state_classification "$state_classification" \
    --arg backup_dir "${BACKUP_DIR:-}" \
    --arg vault_writer_state_root "$VAULT_WRITER_STATE_ROOT" \
    --arg claude_state_root "$CLAUDE_STATE_ROOT" \
    --arg plans_home "$PLANS_HOME" \
    --arg required_overrides "$required_overrides" \
    --arg blocking_findings "$blocking_findings" \
    --arg mode "$dry_run_mode" \
    --arg installed_version "$INSTALLED_VERSION" \
    --arg target_version "${TARGET_VERSION:-}" \
    --arg version_delta "$VERSION_DELTA" \
    --arg version_delta_class "$upgrade_version_delta_class" \
    --arg changelog_slice "$upgrade_changelog_slice" \
    --arg requires_ack "$upgrade_requires_ack" \
    --arg migrations_to_run "$upgrade_migrations_to_run" \
    --arg file_dispositions "$upgrade_file_disp_preview" \
    --argjson claude_home_defaulted "$claude_home_defaulted" \
    --argjson force_install "$FORCE_INSTALL" \
    --argjson force_all "$FORCE_ALL" \
    --argjson no_preserve_config "$NO_PRESERVE_CONFIG" \
    --argjson retrofit_existing "$RETROFIT_EXISTING" \
    --argjson upgrade_mode "$UPGRADE_MODE" \
    --argjson migrate_major "$MIGRATE_MAJOR" \
    '{
  "version": "1",
  "mode": $mode,
  "installed_version": $installed_version,
  "target_version": $target_version,
  "from_version": $installed_version,
  "to_version": $target_version,
  "version_delta": $version_delta,
  "version_delta_class": (if $version_delta_class == "" then null else $version_delta_class end),
  "requires_ack": (if $requires_ack == "" then null else $requires_ack end),
  "backup_required": ($mode == "upgrade"),
  "changelog_slice": (if ($changelog_slice | rtrimstr("\n")) == "" then [] else ($changelog_slice | rtrimstr("\n") | split("\n")) end),
  "claude_home": $claude_home,
  "claude_home_defaulted": $claude_home_defaulted,
  "source_repo": $source_repo,
  "state_classification": $state_classification,
  "flags": {
    "force_install": $force_install,
    "force_all": $force_all,
    "no_preserve_config": $no_preserve_config,
    "retrofit_existing": $retrofit_existing,
    "upgrade_mode": $upgrade_mode,
    "migrate_major": $migrate_major,
    "backup_dir": $backup_dir
  },
  "required_overrides": (if $required_overrides == "" then [] else ($required_overrides | split("\n")) end),
  "blocking_findings": (if $blocking_findings == "" then [] else ($blocking_findings | split("\n")) end),
  "migrations_to_run": (if ($migrations_to_run | rtrimstr("\n")) == "" then [] else ($migrations_to_run | rtrimstr("\n") | split("\n")) end),
  "file_dispositions": (if ($file_dispositions | rtrimstr("\n")) == "" then [] else ($file_dispositions | rtrimstr("\n") | split("\n") | map(split("\t") | (.[0]) as $p | (.[1]) as $d
    | (if   $d == "reconcile-hooks"     then {"class":"THREE-WAY-MERGE", "reason":"missing foundation hook tuple(s) appended (reconciler)", "added_hooks":["see settings-required-hooks.json"]}
       elif $d == "skeleton-merge"      then {"class":"THREE-WAY-MERGE", "reason":"overlay-wins skeleton-merge (adopter registrations preserved, new foundation pillars added); INTENDED gear — a runtime merge failure downgrades to skeleton-merge-skip"}
       elif $d == "skeleton-merge-skip" then {"class":"THREE-WAY-MERGE", "reason":"skeleton-merge skipped (merge failed; adopter overlay untouched)"}
       elif $d == "sidecar-skip-deferred" then {"class":"THREE-WAY-MERGE", "reason":"outstanding <path>.foundation-new sidecar (prior unresolved merge) — apply SKIPs, deferred to user; nothing taken-new until the merge is resolved"}
       elif $d == "three-way-merge"     then {"class":"THREE-WAY-MERGE", "reason":"installed .gitignore managed-block append (Step 11.8 sentinel; adopter ignore rules preserved, never take-new/sidecar)"}
       elif $d == "new-ship"            then {"class":"FOUNDATION-REPLACE", "reason":"absent on disk; staged into place (NEW-SHIP)"}
       elif $d == "replace"             then {"class":"FOUNDATION-REPLACE", "reason":"on-disk == baseline (adopter unmodified); take-new (upstream fix lands)"}
       elif $d == "sidecar"             then {"class":"FOUNDATION-REPLACE", "reason":"on-disk != baseline (adopter edited owned code); take-new + snapshot her bytes to <path>.foundation-local (conflict→sidecar)"}
       elif $d == "untouched"           then {"class":"USER-PRESERVE", "reason":"copied-once-then-adopter-owned (not in files[]); structurally never written"}
       else {"class":"FOUNDATION-REPLACE", "reason":$d} end)
    | {"path": $p, "class": .class, "disposition": $d, "reason": .reason} + (if has("added_hooks") then {"added_hooks": .added_hooks} else {} end))) end),
  "guards_passed": ["G1-pre", "G1-main", "G2", "G3", "G4", "G5", "G8"],
  "actions": [
    {"step": 1, "op": "mkdir", "target": ($claude_home + "/{hooks,hooks/lib,hooks/config,skills,schemas,orchestrator,templates,templates/launchd,templates/settings-fragments,Library/LaunchAgents.staging,installer,logs,governance,governance/file-type-contracts,vault-init}"), "rationale": "create target tree: NO plugins/, NO onboarding/ (dissolved into skills/onboarder/), NO governance/{librarian-capabilities,onboarding-reference}/ (R-20)"},
    {"step": 1.5, "op": "mkdir", "target": ($vault_writer_state_root + "/{,daily-processing,raw,staging} + " + $claude_state_root + "/{,vault-staging,vault-staging/_archive,.coordination,sessions}"), "rationale": "two-root state-tier scaffold: durable second-brain root + ephemeral Claude-runtime root incl .coordination/ + sessions/. NO ~/.claude/state back-compat symlink (fresh lineage)"},
    {"step": 1.6, "op": "sqlite-bootstrap+touch", "target": ($vault_writer_state_root + "/manifest.sqlite + " + $claude_home + "/governance/governance-action-log.jsonl"), "source": ($source_repo + "/hooks/lib/manifest-record.sh init (graceful-degrade if absent)"), "rationale": "manifest.sqlite re-rooted to the state-tier path. governance-action-log.jsonl bootstrap-CREATED under $CLAUDE_HOME/governance/ (bootstrap-not-copy)"},
    {"step": 1.7, "op": "DROPPED", "rationale": "meeting-processor-state migration struck (hardcoded live author-vault path; fresh-install no-op; brain-stem ships no meeting-processor)"},
    {"step": 1.8, "op": "mkdir", "target": $plans_home, "rationale": "create the plan-tree home (default ~/.claude-plans, OUTSIDE ~/.claude/ to clear the sensitive-file gate). plans_root is never interview-customized, so install creates it ahead of /onboard — /new-plan then works pre-onboard; onboarding only adds the vault Plans/ symlink into it"},
    {"step": 2, "op": "cp", "target": ($claude_home + "/hooks/"), "source": ($source_repo + "/hooks/{*.sh,*.md,MANIFEST.txt}"), "rationale": "ship hook entry-points + MANIFEST"},
    {"step": 3, "op": "cp", "target": ($claude_home + "/hooks/lib/"), "source": ($source_repo + "/hooks/lib/{*.sh,*.json,*.sql}"), "rationale": "ship hook libs (hooks/lib/ is the SOLE lib surface; no lib/→hooks/lib/ translation)"},
    {"step": 4, "op": "cp", "target": ($claude_home + "/hooks/config/"), "source": ($source_repo + "/hooks/config/"), "rationale": "ship hook config JSON (graceful-skip if absent)"},
    {"step": 5, "op": "cp", "target": ($claude_home + "/skills/"), "source": ($source_repo + "/skills/{brain-stem roster}/"), "rationale": "ship brain-stem foundation skill subtrees: librarian, backlog-{hygiene,triage,research}, onboarder (+absorbed producers), govern, doc-amender, writer-reconciler, mem-promote, new-plan (R-11), session-checkpoint"},
    {"step": 6, "op": "DISSOLVED", "rationale": "top-level onboarding/ dissolved into skills/onboarder/; producers ride Step 5 cp -R"},
    {"step": 7, "op": "cp", "target": ($claude_home + "/orchestrator/"), "source": ($source_repo + "/orchestrator/"), "rationale": "ship orchestrator subtree (--plan route retained; dispatch.sh keeps --job|--cron|--batch|--plan)"},
    {"step": 8, "op": "cp", "target": ($claude_home + "/installer/"), "source": ($source_repo + "/installer/"), "rationale": "ship installer subtree (LABEL_PREFIX com.brain-stem preserved transitively via render-launchd.sh)"},
    {"step": 8.5, "op": "cp-selective", "target": ($claude_home + "/governance/"), "source": ($source_repo + "/governance/ (named)"), "rationale": "selective copy: foundation-master + overlay-master + foundation-manifest + log-subtype-registry + file-type-contracts/ (registry-complete set). governance-action-log.jsonl is bootstrap-created at Step 1.6 (not copied). NOT shipped: librarian-capabilities/, onboarding-reference/ (R-20). 7 pillar JSONs + _index.json stay repo-only"},
    {"step": 8.7, "op": "cp", "target": ($claude_home + "/vault-init/"), "source": ($source_repo + "/vault-init/"), "rationale": "ship vault-init/ seed tree. The per-plan satellite is retired (not in the ship surface). Welcome.md absent. sha256-protected via governance/foundation-manifest.json"},
    {"step": 9, "op": "cp", "target": ($claude_home + "/schemas/"), "source": ($source_repo + "/schemas/{named}.json"), "rationale": "ship the named adopter schemas (the Step 9 loop is ground-truth) + README. memory-schema, rules-schema, and review-queue-schema are resolved at runtime by installed consumers ($CLAUDE_HOME/schemas/...) so they ship; only foundation-master-schema stays authoring-side"},
    {"step": 10, "op": "cp", "target": ($claude_home + "/templates/"), "source": ($source_repo + "/templates/{settings,2 CLAUDE.md,MEMORY,rules-readme,plan/capture templates,handoff}+{launchd,settings-fragments}/"), "rationale": "ship templates + launchd tmpl + settings-fragments. The 2 CLAUDE.md templates ship sha256-protected; onboarder author-claude-home.sh consumes — NOT install-seeded"},
    {"step": 11, "op": "DROPPED", "rationale": "claude-mem NOT bundled (adopter-installed via marketplace); plugins/ + false README gone"},
    {"step": 11.5, "op": "DROPPED", "rationale": "global CLAUDE.md pre-seed struck; skills/onboarder/scripts/author-claude-home.sh is the authoritative writer"},
    {"step": 12, "op": "jq-merge", "target": ($claude_home + "/settings.json"), "source": ($claude_home + "/templates/settings.json"), "rationale": "atomic deep-merge with G7 silent-key-deletion gate (template * user → user wins on conflict); the reconciler at Step 12.5 re-lands any foundation hook the array-win merge dropped"},
    {"step": 12.5, "op": "jq-reconcile", "target": ($claude_home + "/settings.json"), "source": ($claude_home + "/templates/settings-required-hooks.json"), "rationale": "data-driven settings-required-hooks reconciler (closes the install-time hook-reconciliation gap). Single loop over the declared {event,matcher,command,timeout?} tuples; per-COMMAND idempotent detect-absence-and-append into the matcher-resolved bucket (new bucket only when none matches; no duplicate Edit|Write PostToolUse bucket); carries template timeouts verbatim. ADDS-only POS1 survivorship; runs after the G7-gated mv so it cannot trip G7. Retires the former bespoke Step 12.5 (spec-context-inject) + Step 12.6 (pre-asq-guard) hand-patches into one source of truth."},
    {"step": 13, "op": "validate", "target": ($claude_home + "/schemas/*.json"), "rationale": "post-install schema parse validation"},
    {"step": 13.5, "op": "validate", "target": ($claude_home + "/governance/foundation-manifest.json"), "rationale": "parse-validate baseline post-Step-8.5-copy (load-bearing for G2 + uninstall fingerprint match); lives at governance/"},
    {"step": 15, "op": "log", "target": ($claude_home + "/logs/install-*.log"), "rationale": "G10 provenance log header emit"}
  ],
  "deferred": ["G6-install-side-explicit-sentinel", "20-conflict-manifest-v2.1", "22-rsync-backup-v2.1", "60-grep-audit-consumer-v2.1"]
}'
  exit 0
fi

#   - 14-asset write-sequence

# cp clobber posture: default --force-all=0 → cp -n (no clobber, preserves
# user-edited foundation files; G2 baseline-mismatch covers drift detection).
# --force-all=1 → cp -f (overwrite foundation-known files unconditionally).
# claude-mem at Step 11 has its own clobber posture per --no-preserve-config.
cp_clobber="-n"
[ "$FORCE_ALL" = "1" ] && cp_clobber="-f"

# =============================================================================
# backup + atomic per-file apply + apply-journal reverse-restore
# (100% net-new transaction boundary)
# (Backup, atomic apply, rollback).
#
# RE-LABEL: the rollback ENGINE here is
# 100% NET-NEW code. skills/librarian/capabilities/backup.sh is NOT the rollback
# engine — it is a git add/commit/push wrapper (zero restore/journal/snapshot
# logic). G3 (the backup proof-of-life above, ~:840) is NOT the rollback engine
# either — it is proof-of-life ONLY (it snapshots zero real files; its scope is
# the writable-dir precondition + the narrow settings.json honest-backup).
# G3 contributes ONLY the writable-dir precondition to this transaction.
# Everything below — the step-0 pre-mutation snapshot, the apply-journal, the
# per-file atomic stage→validate→mv, and the reverse-journal cp-restore — is the
# net-new engine.
#
# This is the rollback ENVELOPE: an upgrade --apply with >=1 mutating action is
# all-or-nothing at file granularity. On ANY mid-apply failure (a staged-
# validation failure, a migration non-zero exit, an mv failure) every already-
# applied file is restored from the backup snapshot in REVERSE journal order,
# pre-state=absent creations (incl .foundation-local/.foundation-new sidecars)
# are rm'd, .installed-state.json (incl migrations_applied[]) is restored
# WHOLESALE to its pre-invocation value, foundation_version is NOT bumped, and
# the run exits non-zero.
# =============================================================================

# UPGRADE_ENVELOPE_ON — the transaction boundary fires ONLY on the real upgrade
# lane: --apply over a stamped install (UPGRADE_PRESENT=1). A fresh install
# or a legacy-adopt (no .installed-state.json) keeps the pre-existing posture
# (cp -n / take-new) with NO journal/snapshot envelope — there is no installed
# state to roll back TO, and --backup-dir is not mandatory there.
UPGRADE_ENVELOPE_ON=0
if [ "$APPLY_MODE" = "1" ] && [ "$UPGRADE_PRESENT" = "1" ]; then
  UPGRADE_ENVELOPE_ON=1
fi

# --backup-dir is MANDATORY whenever the run is an upgrade with >=1 mutating
# action. An upgrade --apply is, by construction, a run with
# mutating actions (the disposition walk + the reconciler + migrations), so
# the mandatory gate fires for the whole upgrade lane. Exit 53 (the G3 backup
# refuse family) — there is no --force override for "upgrade without a backup".
if [ "$UPGRADE_ENVELOPE_ON" = "1" ] && [ -z "$BACKUP_DIR" ]; then
  diag "G3 fired: an upgrade --apply mutates managed files (the per-file disposition walk + the hook reconciler + migrations) and REQUIRES --backup-dir <path> as the rollback snapshot root. No backup → no upgrade. Re-run with --backup-dir <path>."
  exit 53
fi

# The apply-journal: one $UPGRADE_JOURNAL file under $BACKUP_DIR/<ts>/ holding one
# TSV record per mutated file:  <abs-target>\t<disposition>\t<backup-rel-path>\t<pre-state>
#   pre-state = "present"  → the target existed before apply; restore = cp from snapshot
#   pre-state = "absent"   → the target was CREATED during apply (incl sidecars);
#                            restore = rm (NOT cp — there is no snapshot to restore from)
# backup-rel-path = the snapshot's path RELATIVE to $UPGRADE_SNAPSHOT_DIR (only
#   meaningful for pre-state=present; "-" for pre-state=absent creations).
# The FIRST journal entry is $CLAUDE_HOME/governance/.installed-state.json,
# snapshotted whole, so a rollback restores migrations_applied[] WHOLESALE.
UPGRADE_SNAPSHOT_ROOT=""
UPGRADE_SNAPSHOT_DIR=""
UPGRADE_JOURNAL=""
UPGRADE_ROLLED_BACK=0
if [ "$UPGRADE_ENVELOPE_ON" = "1" ]; then
  upgrade_ts="$(date -u +%Y%m%d-%H%M%S)"
  UPGRADE_SNAPSHOT_ROOT="$BACKUP_DIR/$upgrade_ts"
  UPGRADE_SNAPSHOT_DIR="$UPGRADE_SNAPSHOT_ROOT/snapshot"
  UPGRADE_JOURNAL="$UPGRADE_SNAPSHOT_ROOT/journal"
  if ! mkdir -p "$UPGRADE_SNAPSHOT_DIR" 2>/dev/null; then
    diag "could not create the upgrade snapshot dir under $UPGRADE_SNAPSHOT_ROOT (no backup root → no upgrade)."
    exit 53
  fi
  : > "$UPGRADE_JOURNAL" || { diag "could not initialize the apply-journal at $UPGRADE_JOURNAL"; exit 53; }
  info "upgrade transaction envelope active (snapshot=$UPGRADE_SNAPSHOT_DIR; journal=$UPGRADE_JOURNAL)"

  # .installed-state.json is the FIRST journal entry, snapshotted WHOLE.
  # On rollback it is restored wholesale so migrations_applied[] returns to its
  # pre-invocation value (roll-forward then re-runs the full range).
  if [ -f "$INSTALLED_STATE_PATH" ]; then
    mkdir -p "$UPGRADE_SNAPSHOT_DIR/governance" 2>/dev/null || true
    if cp -f "$INSTALLED_STATE_PATH" "$UPGRADE_SNAPSHOT_DIR/governance/.installed-state.json" 2>/dev/null; then
      printf '%s\t%s\t%s\t%s\n' "$INSTALLED_STATE_PATH" "installed-state-snapshot" "governance/.installed-state.json" "present" >> "$UPGRADE_JOURNAL"
    else
      diag "could not snapshot .installed-state.json (the first journal entry) — refusing to proceed without a rollback base."
      exit 53
    fi
  fi
fi

# journal_record <abs-target> <disposition> <pre-state> [snapshot-rel-path]
# Appends one apply-journal entry. For pre-state=present the caller MUST have
# already snapshotted the file into $UPGRADE_SNAPSHOT_DIR/<snapshot-rel-path>.
# No-op when the envelope is off (fresh/legacy/dry-run).
journal_record() {
  [ "$UPGRADE_ENVELOPE_ON" = "1" ] || return 0
  local target="$1" disp="$2" prestate="$3" relpath="${4:--}"
  printf '%s\t%s\t%s\t%s\n' "$target" "$disp" "$relpath" "$prestate" >> "$UPGRADE_JOURNAL"
}

# upgrade_snapshot_present <abs-target> <snapshot-rel-path>
# Snapshot a pre-existing target into the backup dir (pre-state=present). Returns
# non-zero if the copy fails so the caller can fail the apply (and roll back).
upgrade_snapshot_present() {
  local target="$1" relpath="$2" dest="$UPGRADE_SNAPSHOT_DIR/$2"
  mkdir -p "$(dirname "$dest")" 2>/dev/null || return 1
  cp -f "$target" "$dest" 2>/dev/null
}

# validate_staged <staged-path> <type-name>
# stage-validation: JSON via python3 json.load,.sh via bash -n,.sqlite via
# sqlite3 PRAGMA integrity_check (when sqlite3 is present). The VALIDATOR CLASS is
# chosen from <type-name> (the TARGET's name) because the staged file's name ends
# in .upgrade.$$, not in its real extension; the CONTENT validated is the staged
# file. Anything else is accepted as-is (no validator class). Returns non-zero on
# a validation failure so the atomic apply fails BEFORE the mv (the half-write
# never reaches disk).
validate_staged() {
  local f="$1" typename="${2:-$1}"
  case "$typename" in
    *.json)
      python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" >/dev/null 2>&1 || return 1 ;;
    *.sh)
      bash -n "$f" >/dev/null 2>&1 || return 1 ;;
    *.sqlite|*.db)
      if command -v sqlite3 >/dev/null 2>&1; then
        [ "$(sqlite3 "$f" 'PRAGMA integrity_check;' 2>/dev/null)" = "ok" ] || return 1
      fi ;;
  esac
  return 0
}

# atomic_apply <abs-source> <abs-target> <disposition>
# atomic per-file apply for a SINGLE file: snapshot the pre-existing target
# (journaled present) OR record an absent-creation, stage the new content to a
# same-dir temp, VALIDATE it, then mv -f (atomic rename). On a staging/validation
# failure, trigger the reverse-journal rollback and exit non-zero. The relpath in
# the snapshot mirrors the target's path under $CLAUDE_HOME so a restore is a
# straight cp back. Returns 0 on success.
atomic_apply() {
  local src="$1" target="$2" disp="$3" rel staged prestate
  rel="${target#"$CLAUDE_HOME"/}"
  staged="$target.upgrade.$$"
  if [ -e "$target" ]; then
    prestate="present"
    if ! upgrade_snapshot_present "$target" "$rel"; then
      diag "failed to snapshot $target before apply — rolling back."
      rollback_restore "snapshot-failed:$target"
    fi
  else
    prestate="absent"
  fi
  # Stage (same dir → mv is a rename, atomic within the filesystem).
  if ! cp -f "$src" "$staged" 2>/dev/null; then
    rm -f "$staged" 2>/dev/null || true
    diag "failed to stage $src → $staged — rolling back."
    rollback_restore "stage-failed:$target"
  fi
  if ! validate_staged "$staged" "$target"; then
    rm -f "$staged" 2>/dev/null || true
    diag "staged-content validation failed for $target ($staged) — rolling back."
    rollback_restore "validate-failed:$target"
  fi
  sync 2>/dev/null || true
  if ! mv -f "$staged" "$target" 2>/dev/null; then
    rm -f "$staged" 2>/dev/null || true
    diag "atomic mv failed for $target — rolling back."
    rollback_restore "mv-failed:$target"
  fi
  journal_record "$target" "$disp" "$prestate" "$( [ "$prestate" = "present" ] && printf '%s' "$rel" || printf '%s' '-' )"
  return 0
}

# rollback_restore <reason>
# reverse-journal restore. Reads the apply-journal in REVERSE order; for each
# entry: pre-state=present → cp the snapshot back over the target; pre-state=absent
# → rm the created file (incl .foundation-local/.foundation-new sidecars). The
# .installed-state.json first-entry is restored wholesale (so migrations_applied[]
# returns to its pre-invocation value). foundation_version is NOT bumped (this
# function exits before Step 13.7). Exits non-zero — the upgrade is all-or-nothing.
rollback_restore() {
  local reason="${1:-unknown}"
  UPGRADE_ROLLED_BACK=1
  warn "ROLLBACK ($reason): restoring every already-applied file in reverse journal order; foundation_version will NOT bump."
  if [ -n "$UPGRADE_JOURNAL" ] && [ -f "$UPGRADE_JOURNAL" ]; then
    # Reverse the journal (last-applied first) and restore each entry.
    local rev; rev="$(mktemp 2>/dev/null || printf '%s' "$UPGRADE_JOURNAL.rev")"
    # bash-3.2-safe reverse: tail -r (BSD) || sed reverse fallback.
    tail -r "$UPGRADE_JOURNAL" > "$rev" 2>/dev/null || sed '1!G;h;$!d' "$UPGRADE_JOURNAL" > "$rev" 2>/dev/null
    local jt jd jr jp
    while IFS="$(printf '\t')" read -r jt jd jr jp; do
      [ -n "$jt" ] || continue
      if [ "$jp" = "present" ]; then
        if [ -n "$jr" ] && [ "$jr" != "-" ] && [ -f "$UPGRADE_SNAPSHOT_DIR/$jr" ]; then
          mkdir -p "$(dirname "$jt")" 2>/dev/null || true
          cp -f "$UPGRADE_SNAPSHOT_DIR/$jr" "$jt" 2>/dev/null \
            && info "rollback: restored $jt from snapshot" \
            || warn "rollback: FAILED to restore $jt from snapshot $jr"
        fi
      else
        # pre-state=absent → the file was created this run; remove it.
        if [ -e "$jt" ]; then
          rm -f "$jt" 2>/dev/null \
            && info "rollback: removed created file $jt" \
            || warn "rollback: FAILED to remove created file $jt"
        fi
      fi
    done < "$rev"
    rm -f "$rev" 2>/dev/null || true
  fi
  diag "upgrade rolled back (reason: $reason). foundation_version unchanged; migrations_applied[] restored to its pre-invocation value. Resume by re-running install --apply after fixing the cause."
  exit 60
}

# --- per-file FOUNDATION-REPLACE disposition (sha256 three-state) ---
# (FOUNDATION-REPLACE) + (USER-PRESERVE) +
# design-install-mechanics.md § (upgrade_foundation_file steps 1-3).
#
# Replaces the existence-only `cp -n` skip with a per-file three-state compare
# against the FROZEN baseline (.installed-baseline-manifest.json, the previous
# release's sha256 set written by the Step 13.7 baseline freeze). This is the line that lands
# the legacy adopter's fixes that `cp -n` silently skipped.
#
# UPGRADE-PATH GATE: the disposition fires ONLY when a frozen baseline manifest
# is present on disk (an upgrade over a stamped install). On a fresh install
# OR a legacy-adopt with no resolvable baseline, UPGRADE_BASELINE_PRESENT=0 and
# every call degrades to the verbatim `cp $cp_clobber` posture (design §:
# "Until an adopter has a snapshot ... degrade to the current cp -n + G2-detect
# posture (safe, never destructive)"). The legacy-adopt absent-baseline take-new
# default is its surface, not the disposition routine's.
#
# USER-PRESERVE structural untouchability: the routine writes a file ONLY
# when its manifest-relative path is a member of foundation-manifest.json::files[].
# A path NOT in files[] is unmanaged and is never written — no flag, no
# --force-all escape on the upgrade path.
UPGRADE_BASELINE_PRESENT=0
BASELINE_MANIFEST_SNAPSHOT=""
UPGRADE_FILE_DISPOSITIONS=""   # newline-joined "<path>\t<disposition>" diff records
if [ "$APPLY_MODE" = "1" ] && [ -f "$INSTALLED_BASELINE_MANIFEST_PATH" ] \
   && [ -f "$SOURCE_REPO/governance/foundation-manifest.json" ]; then
  # Freeze a copy of the on-disk baseline BEFORE any copy can overwrite it
  # (Step 13.7 re-writes .installed-baseline-manifest.json post-apply; the
  # disposition base is the PREVIOUS release's manifest read here at copy time).
  BASELINE_MANIFEST_SNAPSHOT="$(mktemp 2>/dev/null || echo "")"
  if [ -n "$BASELINE_MANIFEST_SNAPSHOT" ] && cp -f "$INSTALLED_BASELINE_MANIFEST_PATH" "$BASELINE_MANIFEST_SNAPSHOT" 2>/dev/null; then
    UPGRADE_BASELINE_PRESENT=1
    info "upgrade disposition active (frozen baseline present; per-file sha256 three-state replaces cp -n for managed-set files)"
  else
    BASELINE_MANIFEST_SNAPSHOT=""
  fi
fi

# upgrade_foundation_file <abs-source> <abs-dest>
# Three-state disposition for ONE managed-set file (path ∈ files[]). On the true
# fresh / no-marker path it is a transparent `cp $cp_clobber` shim; on the
# legacy-adopt path it defaults to FOUNDATION-REPLACE take-new.
# Is <rel> a member of the SHIPPED manifest files[] — the upgrade target's managed
# set? Used by upgrade_foundation_file to tell a NEWLY-ENROLLED foundation file
# (present in the shipped manifest, absent from the adopter's frozen prior-release
# baseline — a path that transitioned from un-manifested to manifest-managed across
# the release) apart from genuinely-unmanaged user content. A shipped-manifest member
# is foundation and MUST converge; only a path in NEITHER manifest is USER-PRESERVE.
in_shipped_manifest() {
  REL="$1" SM="$SOURCE_REPO/governance/foundation-manifest.json" python3 -c '
import json, os, sys
try:
    m = json.load(open(os.environ["SM"]))
except Exception:
    sys.exit(1)
rel = os.environ["REL"]
sys.exit(0 if any(f.get("path") == rel for f in m.get("files", [])) else 1)
' 2>/dev/null
}

upgrade_foundation_file() {
  local src="$1" dest="$2" rel sha_disk sha_base lookup_rc
  # rel = manifest-relative path (== files[].path; verified 1:1, no lib/ xlate).
  rel="${src#"$SOURCE_REPO"/}"

 # No frozen baseline on disk (a fresh install OR a legacy-adopt — the legacy adopter's case).
  if [ "$UPGRADE_BASELINE_PRESENT" != "1" ]; then
 # — legacy-adopt FOUNDATION-REPLACE take-new (absent-baseline is NOT
 # 'equal'/no-op): a legacy adopter has an OLDER foundation on disk with no installed-
 # baseline to prove unmodified-ness. The fixes MUST land, so a managed-set
    # file DEFAULTS to take-new (NOT the cp -n skip that silently drops the fix).
    # The on-disk bytes are snapshotted to <dest>.foundation-local ONLY when they
    # differ from BOTH the new upstream AND every reachable historical sha — i.e.
    # the file is neither already-the-new-content nor a known prior release, so it
    # is an adopter edit worth preserving (dpkg .dpkg-old). This fires only on an
    # --apply against a detected legacy-adopt home; fresh installs and dry-runs
    # keep the verbatim cp -n degrade.
    if [ "${LEGACY_ADOPT:-0}" = "1" ] && [ "${APPLY_MODE:-0}" = "1" ] && [ -e "$dest" ]; then
      local sha_new hist matched
      sha_disk="$(shasum -a 256 "$dest" 2>/dev/null | awk '{print $1}')"
      sha_new="$(shasum -a 256 "$src" 2>/dev/null | awk '{print $1}')"
      if [ -n "$sha_disk" ] && [ "$sha_disk" = "$sha_new" ]; then
        # On-disk already IS the new upstream content → take-new is a no-op write.
        cp -f "$src" "$dest" 2>/dev/null || true
        UPGRADE_FILE_DISPOSITIONS="${UPGRADE_FILE_DISPOSITIONS}${rel}	legacy-adopt-replace
"
        return 0
      fi
      matched=0
      for hist in $(legacy_historical_shas "$rel"); do
        if [ "$sha_disk" = "$hist" ]; then matched=1; break; fi
      done
      if [ "$matched" = "1" ]; then
        # On-disk matches a known prior-release sha → unmodified legacy file →
        # take-new with NO sidecar (clean inherit of the upstream fix).
        cp -f "$src" "$dest" 2>/dev/null || true
        UPGRADE_FILE_DISPOSITIONS="${UPGRADE_FILE_DISPOSITIONS}${rel}	legacy-adopt-replace
"
      else
        # On-disk differs from new AND every reachable historical sha → adopter
        # edit → snapshot to .foundation-local, then take-new (the fix still lands).
        cp -f "$dest" "$dest.foundation-local" 2>/dev/null || true
        cp -f "$src" "$dest" 2>/dev/null || true
        UPGRADE_FILE_DISPOSITIONS="${UPGRADE_FILE_DISPOSITIONS}${rel}	legacy-adopt-replace+foundation-local
"
      fi
      return 0
    fi
    # True fresh install (no marker), legacy dest-absent, or dry-run → verbatim
    # legacy posture. Never destructive. For a legacy-adopt dest-absent file this
    # is a NEW-SHIP (cp -n writes the absent file), exactly as the design wants.
    cp $cp_clobber "$src" "$dest" 2>/dev/null || true
    return 0
  fi

 # USER-PRESERVE: refuse to write anything not in the managed-set files[].
  # The frozen baseline's files[] IS the boundary (chezmoi managed-vs-unmanaged).
  sha_base="$(BMS="$BASELINE_MANIFEST_SNAPSHOT" REL="$rel" python3 -c '
import json, os, sys
try:
    m = json.load(open(os.environ["BMS"]))
except Exception:
    sys.exit(3)
rel = os.environ["REL"]
for f in m.get("files", []):
    if f.get("path") == rel:
        print(f.get("sha256", ""))
        sys.exit(0)
sys.exit(2)
' 2>/dev/null)"
  lookup_rc=$?
  if [ "$lookup_rc" -eq 2 ]; then
    # rel is absent from the adopter's frozen prior-release baseline files[]. Two sub-cases:
    #  (a) NEWLY-ENROLLED managed foundation file — present in the SHIPPED
    #      manifest but not the prior baseline (a path that transitioned from
    #      un-manifested to manifest-managed across the release, e.g. the
    #      memory/rules/review-queue schemas enrolled into files[] in v1.1.2). It IS
    #      foundation and MUST converge on the upgrade, not be skipped. Treat it as a
    #      baseline-less managed file (sha_base="") and fall through to the State-1/3
    #      disposition — new-ship when absent; historical-consult + take-new; genuine
    #      adopter edit → .foundation-local sidecar. This is the SAME non-destructive
    #      logic the legacy lane uses, so an adopter edit is never clobbered.
    #  (b) genuinely unmanaged — present in NEITHER manifest → USER-PRESERVE, never
    #      write. The managed-vs-unmanaged boundary stays absolute: a path the adopter
    #      owns (in no foundation manifest) is structurally untouchable.
    if in_shipped_manifest "$rel"; then
      sha_base=""; lookup_rc=0
    else
      UPGRADE_FILE_DISPOSITIONS="${UPGRADE_FILE_DISPOSITIONS}${rel}	user-preserve-skip
"
      return 0
    fi
  fi
  if [ "$lookup_rc" -ne 0 ]; then
    # Baseline unreadable mid-walk → fail safe to legacy posture, never clobber.
    cp $cp_clobber "$src" "$dest" 2>/dev/null || true
    return 0
  fi

 # — outstanding .foundation-new sidecar SKIP. A
  # <dest>.foundation-new sidecar parked beside a managed file means a PRIOR
  # apply could not auto-resolve the merge and deferred it to the user. Until the
  # user resolves it (and removes the .foundation-new), this file's disposition is
  # deferred-to-user: a subsequent apply SKIPS it (does NOT re-merge / re-take-new).
  # The 3-way base stays pinned to the frozen .installed-baseline-manifest.json
  # (Step 13.7 does NOT advance the per-file base while a sidecar is outstanding —
  # the baseline is re-frozen only on a clean apply with no sidecar left), so a
  # second-apply-after-conflict is a provable no-op for this path. Distinct from
  # the State-3 .foundation-local dpkg-old archive (take-new already landed; no
  # pending action).
  if [ "${UPGRADE_ENVELOPE_ON:-0}" = "1" ] && [ -e "$dest.foundation-new" ]; then
    info "$rel has an outstanding .foundation-new sidecar (prior unresolved merge) — SKIP (disposition deferred-to-user; 3-way base stays pinned)."
    UPGRADE_FILE_DISPOSITIONS="${UPGRADE_FILE_DISPOSITIONS}${rel}	sidecar-skip-deferred
"
    return 0
  fi

  # State 1: dest absent → NEW-SHIP (mv/cp into place).
  if [ ! -e "$dest" ]; then
    if [ "${UPGRADE_ENVELOPE_ON:-0}" = "1" ]; then
      atomic_apply "$src" "$dest" "new-ship"
    else
      cp -f "$src" "$dest" 2>/dev/null || true
    fi
    UPGRADE_FILE_DISPOSITIONS="${UPGRADE_FILE_DISPOSITIONS}${rel}	new-ship
"
    return 0
  fi

  sha_disk="$(shasum -a 256 "$dest" 2>/dev/null | awk '{print $1}')"

  # State 2: on-disk == baseline → adopter UNMODIFIED → take-new (force-replace).
  # This is the cp -n no-update fix: existence alone no longer blocks the update.
  if [ -n "$sha_base" ] && [ "$sha_disk" = "$sha_base" ]; then
    if [ "${UPGRADE_ENVELOPE_ON:-0}" = "1" ]; then
      atomic_apply "$src" "$dest" "replace"
    else
      cp -f "$src" "$dest" 2>/dev/null || true
    fi
    UPGRADE_FILE_DISPOSITIONS="${UPGRADE_FILE_DISPOSITIONS}${rel}	replace
"
    return 0
  fi

  # State 3: on-disk != baseline AND FOUNDATION-REPLACE-class → adopter edited
  # owned code → DEFAULT take-new (upstream fix wins) BUT snapshot her bytes to
  # <dest>.foundation-local (dpkg .dpkg-old) + surface in the diff. Foundation
  # code is not a customization surface; the fix lands, her bytes are never lost.
  # The .foundation-local sidecar is a CREATED file (pre-state=absent) so it
  # is journaled and rm'd on rollback; the take-new itself is the atomic apply.
 #
 # BEFORE sidecarring, consult the SAME
  # legacy_historical_shas resolver the legacy branch uses (1691-1696). An adopter
  # who already ran broken v1.1.0 is stamped + baseline-frozen to v1.1.0 over stale
  # v1.0.2 bytes; on v1.1.1 every one of the 18 files hits THIS State-3 branch
  # (sha_disk v1.0.2 != sha_base v1.1.0) and WITHOUT this consult is MISARCHIVED as
  # .foundation-local (the misarchive). If sha_disk matches ANY reachable
  # historical sha, the on-disk bytes are a KNOWN prior release (not an adopter
  # edit) → take-new with NO sidecar (clean inherit of the upstream fix), exactly
  # as the legacy branch does. Only when sha_disk matches NEITHER sha_base NOR any
  # reachable historical sha is it a genuine adopter edit → sidecar then take-new.
  local s3_hist s3_matched=0
  for s3_hist in $(legacy_historical_shas "$rel"); do
    if [ -n "$sha_disk" ] && [ "$sha_disk" = "$s3_hist" ]; then s3_matched=1; break; fi
  done
  if [ "$s3_matched" = "1" ]; then
    # On-disk matches a known prior-release sha → unmodified foundation bytes from
    # an earlier release (e.g. an already-broken-v1.1.0 home whose subtree files
    # are still pristine v1.0.2) → take-new with NO .foundation-local sidecar.
    if [ "${UPGRADE_ENVELOPE_ON:-0}" = "1" ]; then
      atomic_apply "$src" "$dest" "replace"
    else
      cp -f "$src" "$dest" 2>/dev/null || true
    fi
    UPGRADE_FILE_DISPOSITIONS="${UPGRADE_FILE_DISPOSITIONS}${rel}	replace
"
    return 0
  fi
  if [ "${UPGRADE_ENVELOPE_ON:-0}" = "1" ]; then
    if cp -f "$dest" "$dest.foundation-local" 2>/dev/null; then
      journal_record "$dest.foundation-local" "foundation-local-sidecar" "absent" "-"
    fi
    atomic_apply "$src" "$dest" "replace+foundation-local"
  else
    cp -f "$dest" "$dest.foundation-local" 2>/dev/null || true
    cp -f "$src" "$dest" 2>/dev/null || true
  fi
  UPGRADE_FILE_DISPOSITIONS="${UPGRADE_FILE_DISPOSITIONS}${rel}	replace+foundation-local
"
  return 0
}

# — decompose a recursive cp -R subtree into per-file
# stage→validate→mv ENUMERATED FROM manifest files[]. A `cp -R` of a whole
# subtree cannot honor file-rename atomicity (it is N un-journaled writes), so on
# the upgrade envelope lane we DROP cp -R from the upgrade path: we walk the
# files[] entries whose manifest-relative path falls under <rel-prefix> and route
# each through upgrade_foundation_file() (per-file three-state disposition +
# atomic_apply + journal). On a fresh / legacy-adopt / non-envelope run this is a
# transparent shim back to the caller's existing `cp -R $cp_clobber` posture.
#
# apply_subtree_managed <abs-source-dir> <rel-prefix>
#   <abs-source-dir> — the $SOURCE_REPO subtree root (e.g. $SOURCE_REPO/skills)
#   <rel-prefix>     — the manifest-relative prefix to select (e.g. "skills/")
apply_subtree_managed() {
  local srcdir="$1" prefix="$2" rel src dest
  [ -d "$srcdir" ] || return 0
  # Enumerate the managed-set members under <prefix> from the UNION of the adopter's
  # FROZEN prior-release baseline manifest AND the SHIPPED manifest. upgrade_foundation_file
  # bounds USER-PRESERVE per-file (its baseline lookup + in_shipped_manifest), so the
  # ENUMERATION's job is to name every member we may need to deliver — which MUST
  # include files[] members NEWLY ENROLLED in this release (present in the shipped
  # manifest but absent from the older adopter's frozen baseline).
  #
  # Enumerating from the baseline ALONE missed any newly-enrolled member on a
  # version-SKIP envelope upgrade (e.g. v1.1.1 -> v1.1.3, where
  # governance/baselines/foundation-manifest-v1.1.2.json is a NEW files[] member the
  # v1.1.1 adopter never had). That member was never enumerated -> never delivered ->
  # the delivery-verification gate (which checks the SHIPPED files[]) then found it
  # absent -> exit 56. The legacy lane already enumerates from the shipped manifest;
  # this aligns the envelope lane with it. Baseline-only members removed in this release have no
  # $SOURCE_REPO/$rel source -> the `[ -f "$src" ]` guard skips them (no over-
  # delivery); upgrade_foundation_file no-ops any member not in the shipped manifest
  # (case (b) user-preserve-skip).
  #
  # Read line-by-line (NOT `for rel in $(...)`): managed paths carry spaces
  # (e.g. vault-init/Vault Writers/*). Word-splitting on
  # IFS would shatter those into nonexistent tokens and silently skip them — the
  # exact cp -n silent-skip regression this engine exists to kill. The `< <(...)`
  # process substitution keeps the loop in the CURRENT shell so per-file global
  # state (UPGRADE_FILE_DISPOSITIONS) accrues (a pipe would subshell it away).
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    src="$SOURCE_REPO/$rel"
    dest="$CLAUDE_HOME/$rel"
    [ -f "$src" ] || continue
    mkdir -p "$(dirname "$dest")" 2>/dev/null || true
    upgrade_foundation_file "$src" "$dest"
  done < <(BMS="$BASELINE_MANIFEST_SNAPSHOT" SM="$SOURCE_REPO/governance/foundation-manifest.json" PREFIX="$prefix" python3 -c '
import json, os, sys
prefix = os.environ["PREFIX"]
paths = set()
for key in ("BMS", "SM"):
    path = os.environ.get(key, "")
    if not path:
        continue
    try:
        m = json.load(open(path))
    except Exception:
        continue
    for f in m.get("files", []):
        p = f.get("path", "")
        if p.startswith(prefix):
            paths.add(p)
for p in sorted(paths):
    print(p)
' 2>/dev/null)
}

# — legacy-lane subtree delivery.
# The STAMPED envelope walk (apply_subtree_managed, above) enumerates from the
# FROZEN baseline snapshot (BASELINE_MANIFEST_SNAPSHOT), which is EMPTY on the
# legacy lane (a legacy adopter has no .installed-baseline-manifest.json →
# UPGRADE_BASELINE_PRESENT=0 → the snapshot is "" → that walk would ship zero
# files). So the legacy lane gets its OWN per-file walk that enumerates from the
# SHIPPED $SOURCE_REPO/governance/foundation-manifest.json files[] instead.
#
# This is the KEYSTONE fix: the six cp -R subtree steps degrade to raw
# `cp -R -n` on the legacy lane (UPGRADE_ENVELOPE_ON=0), and `cp -n` SILENTLY
# SKIPS every pre-existing file — so v1.1.x fixes never reach the 18 managed
# subtree files on a legacy adopter's disk. Routing each subtree step through
# this per-file walk fires upgrade_foundation_file()'s legacy take-new branch
# (above, the UPGRADE_BASELINE_PRESENT!=1 / LEGACY_ADOPT path) per file, which
# DELIVERS.
#
# (enumerate-from-manifest, NOT disk-walk): we enumerate the SHIPPED
# files[] filtered by <rel-prefix>, NOT the source subtree on disk. A disk-walk
# would over-deliver NON-files[] repo-authoring files — e.g. the 7 governance
# pillar JSONs + governance/_index.json that Step 8.5 DELIBERATELY does not ship
# — a new over-delivery defect. files[]-membership IS the USER-PRESERVE boundary
# on the legacy lane: only files[] paths under the prefix are walked, and the
# legacy branch of upgrade_foundation_file returns before the
# UPGRADE_BASELINE_PRESENT=1 membership block, so enumeration-from-files[] is the
# structural filter (a non-files[] path under a foundation subtree is never
# written by this walk).
#
# (space-bearing paths): iterate with `while IFS= read -r rel` over a
# `< <(...)` PROCESS SUBSTITUTION (current shell, so UPGRADE_FILE_DISPOSITIONS
# accrues) — NOT `for rel in $(...)`. managed paths carry spaces (e.g.
# vault-init/Vault Writers/_index.md); word-splitting on
# IFS would shatter them into nonexistent tokens and silently skip them — the
# exact cp -n silent-skip class this fix kills (mirrors apply_subtree_managed's
# comment + memory feedback_awk_no_multiline_dash_v).
#
# apply_subtree_legacy <abs-source-dir> <rel-prefix>
#   <abs-source-dir> — the $SOURCE_REPO subtree root (e.g. $SOURCE_REPO/skills)
#   <rel-prefix>     — the manifest-relative prefix to select (e.g. "skills/")
apply_subtree_legacy() {
  local srcdir="$1" prefix="$2" rel src dest
  [ -d "$srcdir" ] || return 0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    src="$SOURCE_REPO/$rel"
    dest="$CLAUDE_HOME/$rel"
    [ -f "$src" ] || continue
    mkdir -p "$(dirname "$dest")" 2>/dev/null || true
    upgrade_foundation_file "$src" "$dest"
  done < <(SHIPPED_MANIFEST="$SOURCE_REPO/governance/foundation-manifest.json" PREFIX="$prefix" python3 -c '
import json, os, sys
try:
    m = json.load(open(os.environ["SHIPPED_MANIFEST"]))
except Exception:
    sys.exit(0)
prefix = os.environ["PREFIX"]
for f in m.get("files", []):
    p = f.get("path", "")
    if p.startswith(prefix):
        print(p)
' 2>/dev/null)
}

# --- THREE-WAY-MERGE gear — overlay-master.json skeleton-merge ---
# (THREE-WAY-MERGE reconcile, overlay-master.json):
# "Never cp -f clobber (that destroys her registered tag-dimensions/folder-rules).
#  Merge foundation skeleton changes INTO her overlay: jq deep-merge with
#  OVERLAY-WINS semantics (foundation-skeleton * adopter-overlay), identical
#  arg-order discipline to settings.json so her registrations win on every
#  conflict, new foundation pillars/keys land as additions."
#
# overlay-master.json is the adopter's Layer-3 governance overlay — mutated by
# /govern register (hooks/lib/overlay-master-mutate.sh). It is NOT a
# FOUNDATION-REPLACE take-new surface (that would clobber her registrations) and
# NOT in the upgrade_foundation_file() walk. It gets its own MERGE gear here.
#
# OVERLAY-WINS arg order: `jq -s '.[0] * .[1]' <foundation-skeleton> <adopter-overlay>`
# — in `a * b`, b wins on scalar conflicts and objects merge recursively, so
# adopter-overlay (b) wins (her /govern-registered dimensions/folder-rules survive)
# while NEW foundation skeleton pillars/keys absent from her overlay land as
# additions. This is the EXACT survivorship contract as the Step-12 settings.json
# merge (template * user → user wins), applied to governance.
#
# UPGRADE-PATH GATE: mirrors upgrade_foundation_file() — the overlay-wins merge
# fires only when a frozen baseline is present (UPGRADE_BASELINE_PRESENT=1, an
# upgrade over a stamped install). On a fresh install OR a legacy-adopt with
# no baseline, it degrades to the verbatim `cp $cp_clobber` posture (the
# pre-existing cp -n preserves first-write adopter mutations; never
# destructive). Atomic stage→mv (stage to a same-dir temp, validate JSON, mv -f).
#
# upgrade_overlay_master <abs-source-skeleton> <abs-dest-overlay>
upgrade_overlay_master() {
  local src="$1" dest="$2" tmp rel
  rel="${src#"$SOURCE_REPO"/}"

  # Fresh / no-baseline / dest-absent → verbatim legacy posture (cp -n preserves
 # adopter mutations after first write per). Never destructive, never merges
  # against a base that does not exist.
  if [ "$UPGRADE_BASELINE_PRESENT" != "1" ] || [ ! -f "$dest" ] || [ ! -f "$src" ]; then
    cp $cp_clobber "$src" "$dest" 2>/dev/null || true
    return 0
  fi

  # OVERLAY-WINS deep merge: foundation-skeleton (.[0]) * adopter-overlay (.[1])
  # → adopter wins on conflict, new foundation pillars/keys land as additions.
  tmp="$dest.overlay-merge.$$"
  if jq -s '.[0] * .[1]' "$src" "$dest" > "$tmp" 2>/dev/null \
     && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$dest" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; }
    UPGRADE_FILE_DISPOSITIONS="${UPGRADE_FILE_DISPOSITIONS}${rel}	skeleton-merge
"
  else
    # Merge failed (malformed overlay/skeleton) → never clobber her registrations;
    # leave the adopter overlay untouched and surface the skip.
    rm -f "$tmp" 2>/dev/null || true
    UPGRADE_FILE_DISPOSITIONS="${UPGRADE_FILE_DISPOSITIONS}${rel}	skeleton-merge-skip
"
  fi
  return 0
}

# Step 1: mkdir -p target tree (brain-stem install layout)
# DROPPED dirs: plugins/ (claude-mem not bundled),
# onboarding/ (dissolved into skills/onboarder/),
# governance/librarian-capabilities/, governance/onboarding-reference/ (R-20).
target_dirs="hooks hooks/lib hooks/config skills schemas orchestrator templates templates/launchd templates/settings-fragments Library/LaunchAgents.staging installer migrations logs governance governance/file-type-contracts vault-init"
for d in $target_dirs; do
  mkdir -p "$CLAUDE_HOME/$d" || { diag "mkdir failed: $CLAUDE_HOME/$d"; exit 11; }
done

# Step 1.8: the plan-tree home (~/.claude-plans by default), OUTSIDE $CLAUDE_HOME so
# the plan tree stays clear of the /.claude/ sensitive-file gate. Created here at
# apply-time (plans_root is never interview-customized; G5 already inspected this
# path) so /new-plan works before /onboard; onboarding's build-brain-vault.sh later
# adds the vault Plans/ symlink into it (its own mkdir -p is then idempotent).
mkdir -p "$PLANS_HOME" || { diag "plans-home mkdir failed: $PLANS_HOME"; exit 11; }

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
#            (per-session checkpoint dirs consumed by registry.sh / paths.sh)
#            + logs/ (+ logs/archive/) + manifests/ + hooks-state/ — the
#            cron/orchestrator run-logs, the retention archive bucket, the
#            librarian-manifest home, and the hooks-runtime state on the XDG
#            state tier (audit/ + runtime/ are created on-demand by their
#            writers). A fresh install provisions these so the paths.sh
#            defaults resolve to real dirs.
state_tier_dirs="$VAULT_WRITER_STATE_ROOT $VAULT_WRITER_STATE_ROOT/daily-processing $VAULT_WRITER_STATE_ROOT/raw $VAULT_WRITER_STATE_ROOT/staging $CLAUDE_STATE_ROOT $CLAUDE_STATE_ROOT/vault-staging $CLAUDE_STATE_ROOT/vault-staging/_archive $CLAUDE_STATE_ROOT/.coordination $CLAUDE_STATE_ROOT/sessions $CLAUDE_STATE_ROOT/logs $CLAUDE_STATE_ROOT/logs/archive $CLAUDE_STATE_ROOT/manifests $CLAUDE_STATE_ROOT/hooks-state"
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
  warn "manifest-record.sh not present at $manifest_record_lib (writer-manifest substrate not landed); skipping manifest.sqlite bootstrap (governance-action-log init still fires)"
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
# upgrade_foundation_file() replaces bare cp $cp_clobber — on the upgrade
# path it force-replaces an UNMODIFIED hook (cp -n no longer skips it) + snapshots
# an adopter-edited one to .foundation-local; on fresh it is a cp $cp_clobber shim.
for f in "$SOURCE_REPO/hooks"/*.sh "$SOURCE_REPO/hooks"/*.md "$SOURCE_REPO/hooks/MANIFEST.txt"; do
  [ -e "$f" ] || continue
  upgrade_foundation_file "$f" "$CLAUDE_HOME/hooks/${f##*/}"
done

# Step 3 / 3.5: hooks/lib/ → hooks/lib/  (top-level lib/ does NOT exist in
# brain-stem — hooks/lib/ is the SOLE lib/ surface; no lib/→hooks/lib/ translation).
# Ships *.sh + *.json + *.sql from the source hooks/lib/ (paths.sh, registry.sh,
# the govern read/write libs, merge-strategy-registry.json, lockf.sh, the
# writer-manifest bodies, + manifest-migrate.sql companion if present).
for f in "$SOURCE_REPO/hooks/lib"/*.sh "$SOURCE_REPO/hooks/lib"/*.json "$SOURCE_REPO/hooks/lib"/*.sql; do
  [ -e "$f" ] || continue
  upgrade_foundation_file "$f" "$CLAUDE_HOME/hooks/lib/${f##*/}"   # foundation-replace disposition
done

# Step 3.5: SUBSUMED into Step 3. brain-stem has a single
# hooks/lib/ surface, so Step 3 above ships the full hooks/lib/ tree in one pass
# (no separate Step 3.5 copy needed).

# Step 4: hooks/config/*.json → $CLAUDE_HOME/hooks/config/
for f in "$SOURCE_REPO/hooks/config"/*.json; do
  [ -e "$f" ] || continue
  upgrade_foundation_file "$f" "$CLAUDE_HOME/hooks/config/${f##*/}"   # foundation-replace disposition
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
# tolerates absent skills (some land in later sub-plans); warn + continue.
# on the upgrade envelope lane the recursive cp -R is
# DROPPED in favor of the per-file files[]-enumerated atomic walk (the whole
# skills/ subtree decomposes to per-file stage→validate→mv + journal).
if [ "$UPGRADE_ENVELOPE_ON" = "1" ]; then
  apply_subtree_managed "$SOURCE_REPO/skills" "skills/"
elif [ "$LEGACY_ADOPT" = "1" ] && [ "$APPLY_MODE" = "1" ]; then
 # legacy lane routes through the per-file files[] walk so
  # pre-existing skills/* land (raw cp -R -n silently skips them).
  apply_subtree_legacy "$SOURCE_REPO/skills" "skills/"
else
  for skill in librarian backlog-hygiene backlog-triage backlog-research onboarder govern doc-amender writer-reconciler mem-promote new-plan session-checkpoint; do
    src="$SOURCE_REPO/skills/$skill"
    if [ ! -d "$src" ]; then
      warn "skill not present in foundation-repo source: $skill (deferred to its sub-plan)"
      continue
    fi
    cp -R $cp_clobber "$src" "$CLAUDE_HOME/skills/" 2>/dev/null || true
  done
fi

# Restore the executable bit on the bare-path-invoked hooks and the librarian
# capabilities. The foundation manifest records mode but no gate asserts a REQUIRED
# mode, and a per-file/directory copy does not reliably preserve the executable bit
# across platforms. settings.json invokes hooks by BARE PATH (a non-exec hook hard-
# fails rc=126) and session-close gates each capability on `[ -x ]` (a non-exec cap
# silently skips). hooks/lib + hooks/config are sourced/data and excluded by the non-
# recursive */*.sh glob. Mirrors the migrations/*.sh chmod parity below.
for _xdir in "$CLAUDE_HOME/hooks" "$CLAUDE_HOME/skills/librarian/capabilities" "$CLAUDE_HOME/skills/govern/lib/project-workspace"; do
  [ -d "$_xdir" ] && chmod +x "$_xdir"/*.sh 2>/dev/null || true
done

# Step 6: DISSOLVED. The top-level
# onboarding/ tree is gone — the onboarder dissolved into a
# self-contained skills/onboarder/ skill. Its producers ride Step 5's
# cp -R skills/onboarder/ (the absorbed producer scripts live inside the skill
# tree). There is no top-level onboarding/ to prune. No-op step.

# Step 7: orchestrator/ → $CLAUDE_HOME/orchestrator/
# cp -R dropped from the upgrade path → per-file files[] walk.
if [ -d "$SOURCE_REPO/orchestrator" ]; then
  if [ "$UPGRADE_ENVELOPE_ON" = "1" ]; then
    apply_subtree_managed "$SOURCE_REPO/orchestrator" "orchestrator/"
  elif [ "$LEGACY_ADOPT" = "1" ] && [ "$APPLY_MODE" = "1" ]; then
 # legacy lane → per-file files[] walk (cp -R -n skips).
    apply_subtree_legacy "$SOURCE_REPO/orchestrator" "orchestrator/"
  else
    cp -R $cp_clobber "$SOURCE_REPO/orchestrator"/. "$CLAUDE_HOME/orchestrator/" 2>/dev/null || true
  fi
fi

# Step 8: installer/ → $CLAUDE_HOME/installer/
# Preserves render-launchd.sh + bootout-launchd.sh with their G6 LABEL_PREFIX
# default (com.brain-stem); install.sh does NOT override this default.
# cp -R dropped from the upgrade path → per-file files[] walk.
if [ -d "$SOURCE_REPO/installer" ]; then
  if [ "$UPGRADE_ENVELOPE_ON" = "1" ]; then
    apply_subtree_managed "$SOURCE_REPO/installer" "installer/"
  elif [ "$LEGACY_ADOPT" = "1" ] && [ "$APPLY_MODE" = "1" ]; then
 # legacy lane → per-file files[] walk (cp -R -n skips).
    apply_subtree_legacy "$SOURCE_REPO/installer" "installer/"
  else
    cp -R $cp_clobber "$SOURCE_REPO/installer"/. "$CLAUDE_HOME/installer/" 2>/dev/null || true
  fi
fi

# Step 8.2: installer/migrations/ → $CLAUDE_HOME/migrations/
# The forward-only migration runner + NNNN-slug.sh files ship FLAT into
# $CLAUDE_HOME/migrations/ ("shipped to
# $CLAUDE_HOME/migrations/ so the adopter has the runner locally for audit").
# These are FOUNDATION-REPLACE managed files (in foundation-manifest.json::files[]);
# the bare cp here is the ship — the post-Step-13.5 runner invocation below runs
# the SHIPPED copy. The Step 8 installer/. copy above also lands a nested
# installer/migrations/ copy (harmless audit duplicate); the FLAT migrations/ is
# the runtime path.
# on the envelope lane the FLAT runtime copy is derived
# per-file (atomic stage→validate→mv + journal) from the managed installer/migrations/
# files[] entries — the runner + demonstrators reach $CLAUDE_HOME/migrations/ with
# the same transaction guarantee, not a recursive cp -R.
if [ -d "$SOURCE_REPO/installer/migrations" ]; then
  if [ "$UPGRADE_ENVELOPE_ON" = "1" ]; then
    # Enumerate the flat copy-set from the SHIPPED TARGET manifest
    # (foundation-manifest.json files[], installer/migrations/ prefix) — the SAME
    # source-of-truth as the legacy elif below and the G9 preview. Enumerating from
    # the frozen PREVIOUS-release baseline snapshot never listed the target release's
    # NEW migrations, so they were never copied to the flat runtime dir the runner
    # executes (the delivery gap). NOT the baseline-union walk one screen up (:2153):
    # for the flat runtime dir the union is wrong — a migration dropped from the
    # shipped manifest is a retired surface and must not be re-delivered. atomic_apply
    # (stage->validate->mv + journal) + the chmod +x parity below are retained.
    _mig_delivered="|"
    for mrel in $(SHIPPED_MANIFEST="$SOURCE_REPO/governance/foundation-manifest.json" python3 -c '
import json, os, sys
try:
    m = json.load(open(os.environ["SHIPPED_MANIFEST"]))
except Exception:
    sys.exit(0)
for f in m.get("files", []):
    p = f.get("path", "")
    if p.startswith("installer/migrations/"):
        print(p)
' 2>/dev/null); do
      msrc="$SOURCE_REPO/$mrel"
      mdest="$CLAUDE_HOME/migrations/${mrel##*/}"
      [ -f "$msrc" ] || continue
      atomic_apply "$msrc" "$mdest" "migration-flat-ship"
      _mig_delivered="${_mig_delivered}${mrel##*/}|"
    done
    chmod +x "$CLAUDE_HOME/migrations"/*.sh 2>/dev/null || true
    # Disk-glob parity WARN (tolerates a hand-modified clone; never dies): an on-disk
    # NNNN-*.sh under $SOURCE_REPO/installer/migrations that the shipped manifest does
    # NOT list is a stray (retired or hand-added) and is NOT delivered — surface it
    # loudly rather than silently dropping it.
    for _dmf in "$SOURCE_REPO/installer/migrations"/[0-9][0-9][0-9][0-9]-*.sh; do
      [ -e "$_dmf" ] || continue
      _dmb="${_dmf##*/}"
      case "$_mig_delivered" in
        *"|$_dmb|"*) ;;
        *) warn "Step 8.2 envelope: on-disk migration $_dmb is absent from the shipped manifest set — NOT delivered (retired surface or hand-added clone drift)" ;;
      esac
    done
  elif [ "$LEGACY_ADOPT" = "1" ] && [ "$APPLY_MODE" = "1" ]; then
 # legacy lane → per-file files[] walk. Migrations ship
    # FLAT ($CLAUDE_HOME/migrations/<basename>), so this mirrors the ENVELOPE
    # flat-ship loop above (NOT the generic apply_subtree_legacy, which would land
    # the nested installer/migrations/ path) — but enumerates from the SHIPPED
 # foundation-manifest.json (BASELINE_MANIFEST_SNAPSHOT is empty on the
 # legacy lane) with IFS= read -r and drives upgrade_foundation_file
    # (its legacy take-new branch delivers + decides the .foundation-local snapshot
    # via legacy_historical_shas on the manifest-relative key). chmod +x parity is
    # kept after the walk (criterion: chmod +x $CLAUDE_HOME/migrations/*.sh).
    while IFS= read -r mrel; do
      [ -n "$mrel" ] || continue
      msrc="$SOURCE_REPO/$mrel"
      mdest="$CLAUDE_HOME/migrations/${mrel##*/}"
      [ -f "$msrc" ] || continue
      mkdir -p "$(dirname "$mdest")" 2>/dev/null || true
      upgrade_foundation_file "$msrc" "$mdest"
    done < <(SHIPPED_MANIFEST="$SOURCE_REPO/governance/foundation-manifest.json" python3 -c '
import json, os, sys
try:
    m = json.load(open(os.environ["SHIPPED_MANIFEST"]))
except Exception:
    sys.exit(0)
for f in m.get("files", []):
    p = f.get("path", "")
    if p.startswith("installer/migrations/"):
        print(p)
' 2>/dev/null)
    chmod +x "$CLAUDE_HOME/migrations"/*.sh 2>/dev/null || true
  else
    cp -R $cp_clobber "$SOURCE_REPO/installer/migrations"/. "$CLAUDE_HOME/migrations/" 2>/dev/null || true
    chmod +x "$CLAUDE_HOME/migrations"/*.sh 2>/dev/null || true
  fi
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
  upgrade_foundation_file "$SOURCE_REPO/governance/foundation-master.json" "$CLAUDE_HOME/governance/foundation-master.json"   # foundation-replace disposition
  # Adopter overlay skeleton (mutation target for /govern register)
 # overlay-master.json is a THREE-WAY-MERGE surface, NOT a plain
  # FOUNDATION-REPLACE take-new surface — routing it through upgrade_foundation_file
  # would clobber adopter registrations. The overlay-wins skeleton-merge
  # (foundation-skeleton * adopter-overlay → her /govern-registered dimensions win,
  # new foundation pillars land as additions) fires on the upgrade path; fresh /
  # legacy-adopt degrades to the verbatim cp $cp_clobber posture inside the routine.
  upgrade_overlay_master "$SOURCE_REPO/governance/overlay-master.json" "$CLAUDE_HOME/governance/overlay-master.json"
  # Foundation-manifest sha256 baseline (consumed by G2 foreign-content detector
  # + uninstall.sh fingerprint match; produced by generate-foundation-manifest.sh)
  upgrade_foundation_file "$SOURCE_REPO/governance/foundation-manifest.json" "$CLAUDE_HOME/governance/foundation-manifest.json"   # foundation-replace disposition
  # R-05 system-utility canonicality registry
  upgrade_foundation_file "$SOURCE_REPO/governance/log-subtype-registry.json" "$CLAUDE_HOME/governance/log-subtype-registry.json"   # foundation-replace disposition
  # Anchored-spoke registry (R-ARCH-13/14): cwd→spoke-key map read at plan-creation
  # time by new-plan.sh / promote-from-inbox.sh. It is the adopter's SOURCE OF TRUTH
  # for registered spokes, authored wholesale by new-plan / promote (never appended-to),
  # so it is SEED-ONCE / USER-PRESERVE-by-omission: NOT in foundation-manifest.json
  # files[] and NOT routed through upgrade_foundation_file (which would sidecar a
  # populated registry to .foundation-local and reset it to the shipped 2-entry
  # skeleton, dropping the adopter's real work-spokes). Fresh/absent install seeds the
  # shipped skeleton; a populated install is left byte-identical (adopter spokes
  # survive --apply). The shipped skeleton stays adopter-neutral (home + brain-stem).
  if [ ! -e "$CLAUDE_HOME/governance/anchored-spoke-registry.json" ]; then
    cp -f "$SOURCE_REPO/governance/anchored-spoke-registry.json" "$CLAUDE_HOME/governance/anchored-spoke-registry.json" 2>/dev/null || true
  fi
  # NOTE: governance-action-log.jsonl is NOT copied here — it is bootstrap-CREATED
  # at Step 1.6 under $CLAUDE_HOME/governance/ (finding: bootstrap-not-copy).
  # File-type contracts subdir (k8s paramKind shape) — every governance/file-type-contracts/*.json member.
 # cp -R dropped from the upgrade path → per-file files[] walk.
  if [ -d "$SOURCE_REPO/governance/file-type-contracts" ]; then
    mkdir -p "$CLAUDE_HOME/governance/file-type-contracts"
    if [ "$UPGRADE_ENVELOPE_ON" = "1" ]; then
      apply_subtree_managed "$SOURCE_REPO/governance/file-type-contracts" "governance/file-type-contracts/"
    elif [ "$LEGACY_ADOPT" = "1" ] && [ "$APPLY_MODE" = "1" ]; then
 # legacy lane → per-file files[] walk (cp -R -n skips).
      apply_subtree_legacy "$SOURCE_REPO/governance/file-type-contracts" "governance/file-type-contracts/"
    else
      cp -R $cp_clobber "$SOURCE_REPO/governance/file-type-contracts"/. "$CLAUDE_HOME/governance/file-type-contracts/" 2>/dev/null || true
    fi
  fi
 # Historical-manifest archive (Option A): ship
  # governance/baselines/ INTO the home so uninstall.sh — which carries NO
  # $SOURCE_REPO and resolves all baselines from $CLAUDE_HOME/governance/ — can
  # reach the per-release historical-sha set for stale-pristine-vs-edited
 # disambiguation. Members: the frozen foundation-manifest-v*.json
  # archives + README.md, now in foundation-manifest.json::files[] (generator
  # extension). Shipped through the PER-FILE engine (upgrade_foundation_file via
  # the files[]-enumerated walk), NOT a raw cp -R -n: a cp -R -n would re-introduce
  # the silent-skip on the very archive this fix depends on (a legacy adopter's
  # pre-existing stale archive would never receive the newly-shipped v1.1.0 member).
  # The archive is append-only; an already-present archived manifest is byte-identical
  # (its sha never changes) so the per-file disposition is a clean take-new / no-op.
  if [ -d "$SOURCE_REPO/governance/baselines" ]; then
    mkdir -p "$CLAUDE_HOME/governance/baselines"
    if [ "$UPGRADE_ENVELOPE_ON" = "1" ]; then
      apply_subtree_managed "$SOURCE_REPO/governance/baselines" "governance/baselines/"
    elif [ "$LEGACY_ADOPT" = "1" ] && [ "$APPLY_MODE" = "1" ]; then
      # Legacy lane → per-file files[] walk (cp -R -n would skip pre-existing archives).
      apply_subtree_legacy "$SOURCE_REPO/governance/baselines" "governance/baselines/"
    else
      cp -R $cp_clobber "$SOURCE_REPO/governance/baselines"/. "$CLAUDE_HOME/governance/baselines/" 2>/dev/null || true
    fi
  fi
  # NOT shipped: librarian-capabilities/ + onboarding-reference/ (R-20).
fi

# Step 8.7: vault-init/ → $CLAUDE_HOME/vault-init/
# Recursive cp -R; deploys the foundation-canonical adopter-vault seed tree
# mirroring the target adopter vault tree exactly. Foundation authors
# edit vault-init/ in target shape; install/adopt copies wholesale; what you
# see in vault-init/ is what the adopter gets. cp_clobber posture matches the
# rest of the foundation-known tree (cp -n default; --force-all → cp -f).
# sha256-protected via governance/foundation-manifest.json. The subdir scaffold
# (Vault Writers/) ships with its seed content (an _index.md) so the adopter
# starts with a populated writers surface, not an empty placeholder. Authoring
# contract for what may live under vault-init/ at docs/vault-init-authoring.md.
# The per-plan backlog satellite is retired: the backlog now lives as the
# librarian-emitted ${PLANS_DIR:-$HOME/.claude-plans}/_backlog.md under Plans
# Pillar governance (writers_allowed: ["librarian"] per
# governance/plans-rules.json :: root_files); archival is the plan-index
# display-only view (no _archive.md file ships or is generated).
# cp -R dropped from the upgrade path → per-file files[] walk.
if [ -d "$SOURCE_REPO/vault-init" ]; then
  if [ "$UPGRADE_ENVELOPE_ON" = "1" ]; then
    apply_subtree_managed "$SOURCE_REPO/vault-init" "vault-init/"
  elif [ "$LEGACY_ADOPT" = "1" ] && [ "$APPLY_MODE" = "1" ]; then
 # legacy lane → per-file files[] walk. Carries the 11
    # space-bearing paths (vault-init/Vault Writers/_index.md, vault-init/System
    # Governance/*) intact via the helper's IFS= read -r (cp -R -n skips them).
    apply_subtree_legacy "$SOURCE_REPO/vault-init" "vault-init/"
  else
    cp -R $cp_clobber "$SOURCE_REPO/vault-init"/. "$CLAUDE_HOME/vault-init/" 2>/dev/null || true
  fi
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

# Step 8.9: MANIFEST-DRIVEN mode restore over the WHOLE 0755 set. The narrow
# `chmod +x hooks/*.sh + capabilities/*.sh` glob above repairs only ~50 of the ~104
# manifest-0755 files — the ~50 out-of-glob 0755 files (orchestrator/*, hooks/lib/*,
# skills/govern/*, doc-amender/*, installer/*, onboarder scripts) are delivered with
# whatever mode the cp -R / per-file walk happened to carry. When a SOURCE file's exec
# bit is stripped (a staged-uncommitted 100644, a platform that drops the bit on copy),
# the file is delivered 0644 on a rc=0 install and install even tells the adopter to run
# the now non-exec binary by bare path. The fix: make mode a DELIVERED PROPERTY read
# from the manifest .mode — not a narrow blanket +x that papers over the symptom and
# fails no gate. The manifest is the SoT (.mode derives from the git INDEX, so
# manifest.mode == shipped index mode == intended delivered mode). The source manifest is
# always present at $SOURCE_REPO/governance/foundation-manifest.json (the shipped copy
# under $CLAUDE_HOME is landed by Step 8.5; either resolves). Migrations also ship FLAT
# to $CLAUDE_HOME/migrations/ and keep their dedicated chmod above; this walk covers the
# nested $CLAUDE_HOME/installer/migrations/ copy by its manifest path.
_mode_manifest="$CLAUDE_HOME/governance/foundation-manifest.json"
[ -f "$_mode_manifest" ] || _mode_manifest="$SOURCE_REPO/governance/foundation-manifest.json"
if [ -f "$_mode_manifest" ] && command -v python3 >/dev/null 2>&1; then
  MM="$_mode_manifest" python3 -c '
import json, os, sys
try:
    m = json.load(open(os.environ["MM"]))
except Exception:
    sys.exit(0)
for f in m.get("files", []):
    mode = f.get("mode", "")
    path = f.get("path", "")
    if mode and path:
        # tab-delimited <mode>\t<path> so a space-bearing path survives the read.
        sys.stdout.write(mode + "\t" + path + "\n")
' 2>/dev/null | while IFS="$(printf '\t')" read -r _mmode _mpath; do
    [ -n "$_mpath" ] || continue
    _dest="$CLAUDE_HOME/$_mpath"
    [ -e "$_dest" ] || continue
    chmod "$_mmode" "$_dest" 2>/dev/null || true
  done
fi

# Step 9: schemas/ — selective named-list. Ships the 12 adopter schemas + README:
# plans, plan-manifest, librarian-manifest, user-manifest, orchestration,
# drift-allowlist, overlay-master, governance-action-log, writer-manifest, and
# the memory, rules, and review-queue schemas.
#
# memory-schema, rules-schema, and review-queue-schema ship because installed
# consumers resolve them at runtime under $CLAUDE_HOME/schemas/ — the memory-
# staleness, memory-globalize, rules-hygiene, and review-queue helpers each gate
# on the schema file being present. Shipped, the schema-driven path is live;
# unshipped, every consumer silently fell back to its hardcoded default and the
# conformance gates were never enforced.
#
# Only foundation-master-schema stays foundation-repo authoring-side: it is the
# canonical runtime validation layer the composed bundle is built from (pillars
# compose into the bundle at release time; the bundle ships, the pillars don't).
for schema in plans-schema plan-manifest-schema librarian-manifest-schema user-manifest-schema orchestration-schema drift-allowlist-schema overlay-master-schema governance-action-log-schema writer-manifest-schema memory-schema rules-schema review-queue-schema file-type-contract-schema; do
  src="$SOURCE_REPO/schemas/$schema.json"
  if [ ! -f "$src" ]; then
    diag "schema missing in source: $schema.json"
    exit 11
  fi
  upgrade_foundation_file "$src" "$CLAUDE_HOME/schemas/${src##*/}"   # foundation-replace disposition
done
# Schemas/README.md ships alongside (operator docs)
[ -f "$SOURCE_REPO/schemas/README.md" ] && \
  upgrade_foundation_file "$SOURCE_REPO/schemas/README.md" "$CLAUDE_HOME/schemas/README.md"   # foundation-replace disposition

# Step 10: templates/ — settings.json + skeletons + README + CLAUDE.md templates
# + plan/capture templates + launchd/*.tmpl + settings-fragments/.
# The 2 CLAUDE.md templates (vault-claude-md + claude-home-claude-md) are
# staged here sha256-protected; the
# onboarder author-claude-home.sh consumes them (NOT install-time seeded).
# librarian-manifest-skeleton.json + README.md remain in the loop for forward
# compatibility (skipped via [ -e ] || continue when not yet landed; ownership
# escalated per CSE-templates-band-ownership).
# templates/settings.json IS in files[] and is force-replaced here as
# INERT SOURCE DATA via the FOUNDATION-REPLACE disposition — never the live merge
# target. The live $CLAUDE_HOME/settings.json is jq-merged at Step 12 (the
# MIGRATE-STATE surface), a distinct path the templates walk never touches.
for tmpl in settings.json settings-required-hooks.json librarian-manifest-skeleton.json README.md vault-claude-md-template.md claude-home-claude-md-template.md MEMORY.md.template claude-home-rules-readme-template.md ideation-brief-template.md idea-note-template.md research-index-template.md decision-log-template.md handoff-chronicle-template.md library-article-template.md topic-index-template.md; do
  src="$SOURCE_REPO/templates/$tmpl"
  [ -e "$src" ] || continue
  upgrade_foundation_file "$src" "$CLAUDE_HOME/templates/${src##*/}"   # foundation-replace disposition
done
for f in "$SOURCE_REPO/templates/launchd"/*.tmpl; do
  [ -e "$f" ] || continue
  upgrade_foundation_file "$f" "$CLAUDE_HOME/templates/launchd/${f##*/}"   # foundation-replace disposition
done
for f in "$SOURCE_REPO/templates/settings-fragments"/*.json; do
  [ -e "$f" ] || continue
  upgrade_foundation_file "$f" "$CLAUDE_HOME/templates/settings-fragments/${f##*/}"   # foundation-replace disposition
done

# The per-file disposition reads of the frozen baseline are complete (all
# per-file managed-set cp loops above ran before Step 13.7 re-stamps the baseline).
# Release the snapshot temp. Recursive cp -R subtrees (Steps 5/7/8/8.5-contracts/
# 8.7) are LEFT as cp $cp_clobber — their per-file decomposition over
# files[] is its surface (cp -R dropped from the upgrade path there).
[ -n "$BASELINE_MANIFEST_SNAPSHOT" ] && rm -f "$BASELINE_MANIFEST_SNAPSHOT" 2>/dev/null || true

# Surface the per-file disposition diff (snapshot her version
# to <file>.foundation-local AND surface it in the diff", dpkg .dpkg-old). The
# disposition records collected during the copy loops above are now emitted to the
# operator (info() — dpkg prints config-preservation to its install output) AND
# carried into the Step-14 provenance log for the audit trail. apply-time surface,
# distinct from the G9 dry-run-PREVIEW. Only fires on the upgrade
# path (frozen baseline present); fresh/legacy-adopt leaves UPGRADE_FILE_DISPOSITIONS
# empty and this block is a no-op.
if [ "$UPGRADE_BASELINE_PRESENT" = "1" ] && [ -n "$UPGRADE_FILE_DISPOSITIONS" ]; then
  info "upgrade file dispositions (per-file FOUNDATION-REPLACE three-state diff):"
  printf '%s' "$UPGRADE_FILE_DISPOSITIONS" | while IFS=$'\t' read -r disp_path disp_kind; do
    [ -z "$disp_path" ] && continue
    case "$disp_kind" in
      replace+foundation-local)
        info "  - $disp_path: take-new (upstream fix landed); prior bytes snapshotted to $disp_path.foundation-local" ;;
      replace)       info "  - $disp_path: take-new (unmodified on-disk; upstream fix landed)" ;;
      new-ship)      info "  - $disp_path: new-ship (absent on disk; staged into place)" ;;
      user-preserve-skip) info "  - $disp_path: user-preserve-skip (not in managed-set files[]; untouched)" ;;
      skeleton-merge) info "  - $disp_path: skeleton-merge (overlay-wins THREE-WAY-MERGE; adopter registrations preserved, new foundation pillars added)" ;;
      skeleton-merge-skip) info "  - $disp_path: skeleton-merge-skip (merge failed; adopter overlay left untouched)" ;;
      *)             info "  - $disp_path: $disp_kind" ;;
    esac
  done
fi

# Step 11: DROPPED (brain-stem). claude-mem is NOT bundled — it is
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
#
# (THREE-WAY-MERGE class — live-CLAUDE.md prose-merge REMOVED from the
# engine walk): the install-side engine performs NO `git merge-file` (prose 3-way
# merge) against any LIVE $CLAUDE_HOME/CLAUDE.md or vault CLAUDE.md. Those live
# files have NO files[] path and are OUT of the engine's files[]-driven
# upgrade_foundation_file() walk; the global ~/.claude/CLAUDE.md is authored by
# skills/onboarder/scripts/author-claude-home.sh, the sole writer.
# The two CLAUDE.md *TEMPLATES* under templates/ are handled as ordinary
# FOUNDATION-REPLACE files by the Step-10 upgrade_foundation_file() loop
# (unmodified → replace; modified → .foundation-local sidecar), NOT prose-merged.
# `git merge-file --diff3 on-disk installed-baseline-template new-upstream-template`
# remains the DOCUMENTED technique for a FUTURE onboarder/author-claude-home.sh
# live-CLAUDE.md re-author path ONLY (a separate ADR/cluster) — never the install
# engine. (wfv blocking correction [install-mechanics CLAUDE.md]:
# putting the live CLAUDE.md in the files[] walk would either no-op — path not in
# the walk — or clobber an onboarder-owned file.)

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
rules_caveat_sentinel="<!-- brain-stem: #21858-caveat -->"

if [ ! -f "$template_rules_readme" ]; then
  warn "claude-home-rules-readme-template.md not present at $template_rules_readme — skipping rules/README.md seed"
elif [ -f "$rules_readme_target" ]; then
  # No-clobber: an existing README is preserved. On an upgrade, deliver the
  # user-scope `paths:`-glob "Known limitation" caveat (now in the template body)
  # to pre-existing adopters by APPENDING it behind a sentinel — only when absent
  # (grep -qF guard → idempotent), leaving the adopter's own edits untouched.
  if grep -qF "$rules_caveat_sentinel" "$rules_readme_target"; then
    info "rules/README.md exists at $rules_readme_target — preserving (no clobber); #21858 caveat already present (no re-append)"
  else
    {
      printf '\n%s\n' "$rules_caveat_sentinel"
      printf '## Known limitation — user-scope `paths:` globs are silently ignored\n\n'
      printf 'In **user-scope** `~/.claude/rules/` (this directory), a `paths:` glob is **silently ignored**: a glob-scoped rule placed here does not lazy-load on matching files — it is simply not picked up by the glob, with no warning. This is a known upstream limitation, tracked in GitHub issues `#21858` and `#25562`.\n\n'
      printf 'Practical consequence and the reliable alternative:\n\n'
      printf -- '- A user-scope rule that **must** fire should be **unscoped** (omit the `paths:` key) so it loads always-on at session start.\n'
      printf -- '- Glob-scoped (`paths:`) rules load reliably only in **project-scope** `.claude/rules/` (inside a repo). Put domain-specific, file-matched rules there.\n'
      printf -- '- Until the upstream behavior changes, treat a `paths:` key in user-scope as documentation of intent rather than an active loader.\n'
    } >> "$rules_readme_target" || {
      diag "rules/README.md caveat append failed: $rules_readme_target"
      exit 11
    }
    info "rules/README.md exists at $rules_readme_target — preserving (no clobber); appended #21858 caveat block (adopter content preserved)"
  fi
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

# Step 11.7a: the generic rules/ entries (R-ARCH-RULES).
# The generic, cwd-parameterized, always-on entries seeded into
# $CLAUDE_HOME/rules/ are enumerated by the `# Entry N —` markers below (each
# marker heads one `seed_rules_entry` call), the source of truth for which
# entries ship — add or remove an entry there and this header stays true.
# All are UNSCOPED (no `paths:` key) so they load every session — the #21858
# user-scope `paths:`-glob limitation makes glob-scoping unreliable here.
# These are installed by install.sh (R-ARCH-5 reconcile: install.sh runs outside
# the Edit-blocking sensitive-file gate), on BOTH paths in this same Step 11.7
# section: fresh = mkdir + atomic-mv; existing-adopter = no-clobber preserve.
# Generic-only: NO per-project entries are ever written.
rules_dir="$CLAUDE_HOME/rules"   # (already set above; restated for locality)
seed_rules_entry() {
  # $1 = entry filename (under rules/), $2 = entry body (already rendered)
  local fname="$1" body="$2" target="$rules_dir/$1" tmp
  if [ -f "$target" ]; then
    info "rules/$fname exists at $target — preserving (no clobber)"
    return 0
  fi
  if ! mkdir -p "$rules_dir"; then
    diag "rules/$fname seed: mkdir failed: $rules_dir"
    exit 11
  fi
  tmp="$target.tmp.$$"
  if ! printf '%s' "$body" > "$tmp"; then
    diag "rules/$fname seed: write failed: $tmp"
    rm -f "$tmp"
    exit 11
  fi
  if ! mv -f "$tmp" "$target"; then
    diag "rules/$fname seed: atomic mv failed: $target"
    rm -f "$tmp"
    exit 11
  fi
  info "rules/$fname seeded at $target"
}

# Entry 1 — binder pointer (R-ARCH-RULES #1). Cwd-parameterized: resolves the
# CURRENT spoke's _projects/<spoke>/ binder surface. Generic — never names a
# specific spoke; the launch directory selects the spoke at read time. The binder is
# 100% machine-derived: the sole cover is the force-ingested situating card (eager,
# automatic). Not re-dumped here.
read -r -d '' rules_binder_pointer <<'RULE_BINDER' || true
# Project binder — the situating card is the sole, eager, machine-derived cover

When working inside a registered project spoke, the spoke's binder has ONE cover
surface, the force-ingested situating card:

  The situating card (`~/.claude-plans/_projects/<spoke>/_situating.md`) is
  AUTO-FORCE-INGESTED at session start — you already have the machine-derived
  orientation (the spoke's plan roster, aggregate status, active focus, and a
  latest-handoff pointer per in-progress plan) WITHOUT reading anything. It is
  generated from the plans' manifests, so it is always current. The binder is 100%
  machine-derived — there is no hand-curated cover page.

`<spoke>` is the current launch-directory's registered spoke key (`home` for the
home anchor). The card gives you eager orientation automatically. For deeper binder
surfaces, follow the card's pointers (research-index, decision-log,
handoff-chronicle) on demand rather than loading every binder index up front. If no
binder exists for the current spoke yet, run `librarian plan-research-index` (and
the binder capabilities) to generate it. This entry is generic and cwd-parameterized
— it never names a specific project.
RULE_BINDER
seed_rules_entry "00-project-binder-pointer.md" "$rules_binder_pointer"

# Entry 2 — pre-research library-check fallback (R-ARCH-RULES #2). The portable
# DEGRADED layer that backs the pre-research hook (hooks/pre-research-check.sh):
# it operates when that hook is unavailable, so library coverage is surfaced even
# pre-hook. Generic + always-on; advisory-only (mirrors the hook's never-block
# posture).
read -r -d '' rules_library_check <<'RULE_LIBCHECK' || true
# Before researching — check the library first

Before starting a research-class task (investigating, surveying, gathering
sources, building up knowledge on a topic), check whether the cross-project
library already covers it, so the work is not duplicated:

  Read `~/.claude-plans/_library/_index.md` (the topic roster + staleness) and
  scan it for the topic. If a matching topic exists, open its
  `~/.claude-plans/_library/<topic>/_index.md` and the relevant article BEFORE
  researching fresh. If coverage is stale, choose: validate / use-as-is /
  research-fresh.

This is the portable degraded layer behind the `pre-research-check`
UserPromptSubmit hook: when that hook is installed it injects a compressed
coverage signal automatically at detected research intent; when it is absent (or
the library has no coverage) this always-on rule keeps the library-first check in
view. Advisory only — it never blocks. If `_library/` does not exist yet, there is
nothing to check; proceed.
RULE_LIBCHECK
seed_rules_entry "10-pre-research-library-check.md" "$rules_library_check"

# Entry 3 — work-project registration on-ramp. The always-on, unscoped, create-only
# rule that names the /govern register --kind project path before any write into a new
# ~/work project (surfaced in the vault as Work/<spoke>/). Generic — never names a
# specific spoke. Advisory only (never blocks).
read -r -d '' rules_work_project_register <<'RULE_WORKPROJ' || true
# Starting a new ~/work project — register it first

When you begin a new project under `~/work/` (a Work spoke surfaced in the vault
as `Work/<spoke>/`), register it BEFORE the first file write so its identity,
on-disk shape, and write-time governance are in place:

  Run `/govern register --kind project` from the new project's launch directory
  (`~/work/<spoke>/`, exactly one level under `~/work/`). Pick the shape:

  - `--layout flat` (default) — a single-project workspace: scaffolds the flat
    MVP (CLAUDE.md, README.md, updates.md, deliverables/, reference/).
  - `--layout master --first-sub <name>` — a master that organizes sub-projects:
    scaffolds a master top (CLAUDE.md, README.md, updates.md — NO top-level
    deliverables/reference) plus one sub-project under it (each sub owns its own
    README + deliverables/ + reference/).

Registration records the spoke in the anchored-spoke registry (the identity
source of truth), scaffolds the shape, and emits the `Work/<spoke>/**` routing
rule so write-time governance fires for the spoke. Run it before `mkdir`/first
write — it is a proactive on-ramp, not a gate. This entry is generic and always-on;
it never names a specific project and never blocks.
RULE_WORKPROJ
seed_rules_entry "20-work-project-register.md" "$rules_work_project_register"

# Entry 4 — bounded cross-cutting-spoke on-ramp (R-ARCH-RULES #4). Steers
# cross-cutting personal-system work AWAY from $HOME: never launch from the home
# directory; create a dedicated bounded dir (e.g. ~/system) and register it as a
# spoke, the same way a code-tree or ~/work project is registered. Sibling to the
# work-project on-ramp (20-work-project-register.md) and the cwd==$HOME SessionStart
# warning (session-start-home-launch-warn.sh) — cross-referenced for discoverability.
# Generic — never names a specific dir. Advisory only (never blocks).
read -r -d '' rules_bounded_spoke <<'RULE_BOUNDEDSPOKE' || true
# Cross-cutting personal-system work — give it a bounded spoke, never $HOME

Some work belongs to no single project — cross-cutting personal-system tasks
(tuning your own config, notes that span projects, one-off scripts). The tempting
shortcut is to launch Claude Code from your home directory. Do NOT: launching from
`$HOME` puts your ENTIRE home tree in the agent's file-operation scope, collapses
the project `.claude/` onto the global `~/.claude`, and routes the session into the
anchorless `home` catch-all identity. (A SessionStart advisory warns whenever a
session is launched from `$HOME`.)

Instead, give cross-cutting work a bounded home of its own:

  1. Create a dedicated, bounded directory for it — e.g. `~/system` (any single
     bounded dir works; this rule never mandates a specific name).
  2. Register it as a spoke, exactly the way you register a code-tree or a `~/work`
     project (see the work-project registration on-ramp): add a spoke entry in the
     anchored-spoke registry and drop a one-line identity `CLAUDE.md` in the dir so
     its purpose is self-describing.
  3. Launch Claude Code FROM that directory — never from `$HOME`.

The bounded dir keeps the agent's file-operation scope small, keeps project and
global config distinct, and routes the session to an owned spoke instead of the
catch-all. This entry is generic and always-on; it never names a specific directory
and never blocks.
RULE_BOUNDEDSPOKE
seed_rules_entry "25-bounded-spoke-for-cross-cutting-work.md" "$rules_bounded_spoke"

# Entry 5 — durable-artifact routing convention. The always-on counterpart of the
# closed plans-root namespace (plans-rules.json :: root_namespace + the pre-write-guard
# root-allowlist arm + the librarian placement-validate plans-scope rule): the guard can
# only deny a misplaced write — this rule tells the session where the artifact BELONGS.
# Five routing clauses (funnel-first / flat work-spoke reference/ / world-vs-system
# discriminator / scratchpad-is-transit / library-universal-only). Generic — never names
# a specific plan or spoke. Advisory only (never blocks).
read -r -d '' rules_durable_routing <<'RULE_DURABLEROUTING' || true
# Durable artifact routing — every research output lands in its owning context

Durable session outputs (research registers, design memos, audit ledgers, syntheses)
never land at the plans-tree root or in hand-invented ad-hoc directories: the plans root
is a CLOSED namespace (governance pillar `plans-rules.json :: root_namespace`), enforced
write-time by the pre-write-guard root-allowlist arm and swept by the librarian
placement-validate plans-scope rule. Route durable artifacts by these five clauses:

1. Research produced OUTSIDE any plan's scope: mint the owning plan FIRST through the
   funnel — `promote-from-inbox.sh --capture <slug>` (write the idea note now), then
   `promote-from-inbox.sh <slug>` (graduate to the `NN-<slug>/` plan when ready) — then
   land the artifact in that plan's `_research/` and declare it in
   `manifest.research_artifacts[]`.
2. Research produced in a WORK-SPOKE session lands FLAT in the spoke's existing
   `reference/` (single-level `.md` — the work-index indexer is single-level/.md-only
   by design; nesting makes artifacts index-invisible).
3. Discriminator: about the WORLD (engagement/domain knowledge) → the vault; about the
   SYSTEM or the work itself → the owning plan's `_research/`.
4. The session scratchpad is TRANSIT, never home: the sanctioned move is `mv` into
   `<plan>/_research/` at graduation. Declaration DERIVES at session close (the
   session-close capability populates `research_artifacts[]` via plan-research-declare)
   — never maintain a second, hand-kept declaration surface.
5. `_library/` stays UNIVERSAL-ONLY — cross-project doctrine that applies everywhere;
   project-specific research belongs to its owning plan, never the library.

Phase-2 hardening options are RECORDED, not scheduled — data-gated on accumulated
placement-validate findings: a PreToolUse-on-Bash command screen for plans-root writes,
and a machine-wide displacement scanner. Neither is built until sweep findings
demonstrate the need.
RULE_DURABLEROUTING
seed_rules_entry "30-durable-artifact-routing.md" "$rules_durable_routing"

# Step 11.7b: pre-existing legacy episode_*.md migration (upgrade-lane only, idempotent).
# Existing installs accumulated per-session episode_<sid>-<ts>.md docs in each project's flat
# memory dir. The orphan-adder globs the FLAT memory dir and would keep indexing every legacy
# episode_*.md, competing with the single episodic-chronicle pointer line. Supersede-don't-delete:
# move them into a memory/episodic-legacy/ subdir (out of the flat *.md glob the orphan-adder
# walks; the glob is non-recursive). Files are preserved under legacy/, not deleted; the
# consolidation sweep then strips the now-dead episode_* index entries.
# IDEMPOTENT: a second run finds no flat episode_*.md (already moved) -> no-op. FRESH INSTALL:
# gated on UPGRADE_PRESENT -> a fresh install never enters this branch. Scope: every per-project
# memory dir under $CLAUDE_HOME/projects/*/memory plus a flat autoMemoryDirectory when set.
# LEGACY_EPISODE_ROOT overrides the projects base for isolated testing.
migrate_legacy_episodes() {
  local mem_dir moved base legacy_dir f
  moved=0
  for mem_dir in "$@"; do
    [ -d "$mem_dir" ] || continue
    legacy_dir="$mem_dir/episodic-legacy"
    for f in "$mem_dir"/episode_*.md; do
      [ -e "$f" ] || continue           # glob-no-match guard (nullglob-safe)
      base="$(basename "$f")"
      if ! mkdir -p "$legacy_dir"; then
        warn "legacy-episode migration: mkdir failed: $legacy_dir — skipping $base"
        continue
      fi
      if mv -f "$f" "$legacy_dir/$base"; then
        moved=$((moved + 1))
      else
        warn "legacy-episode migration: mv failed: $base"
      fi
    done
  done
  printf '%s' "$moved"
}

if [ "${UPGRADE_PRESENT:-0}" = "1" ]; then
  episode_mig_root="${LEGACY_EPISODE_ROOT:-$CLAUDE_HOME/projects}"
  episode_mig_dirs=""
  if [ -d "$episode_mig_root" ]; then
    for _proj in "$episode_mig_root"/*/; do
      [ -d "$_proj" ] || continue           # glob-no-match guard
      [ -d "${_proj}memory" ] && episode_mig_dirs="$episode_mig_dirs ${_proj}memory"
    done
    if [ -z "$episode_mig_dirs" ]; then
      episode_mig_dirs="$episode_mig_root"
    fi
  fi
  if command -v jq >/dev/null 2>&1 && [ -r "$CLAUDE_HOME/settings.json" ]; then
    _flat_mem="$(jq -r '.autoMemoryDirectory // empty' "$CLAUDE_HOME/settings.json" 2>/dev/null)"
    case "$_flat_mem" in "~/"*) _flat_mem="$HOME/${_flat_mem#\~/}" ;; esac
    [ -n "$_flat_mem" ] && [ -d "$_flat_mem" ] && episode_mig_dirs="$episode_mig_dirs $_flat_mem"
  fi
  # shellcheck disable=SC2086
  episode_mig_moved="$(migrate_legacy_episodes $episode_mig_dirs)"
  if [ "${episode_mig_moved:-0}" -gt 0 ]; then
    info "legacy episode_*.md migration: moved $episode_mig_moved file(s) to memory/episodic-legacy/ (supersede-don't-delete; out of the orphan-adder flat glob)"
  else
    info "legacy episode_*.md migration: no flat episode_*.md found (fresh upgrade or already migrated) — no-op"
  fi
fi

# Step 11.7c: project:-field identity migration (R-ARCH-PID). UPGRADE-LANE ONLY +
# idempotent. A legacy adopter plan manifest can carry a human display name in the
# `project:` field with NO `title:`. This migration is TITLE-RESCUE-ONLY: it copies
# that display name into a new `title:` field and NEVER writes `project:` — a value
# that is already a registered spoke key, or a genuinely unattributable legacy value,
# is left untouched. The corrected writers (new-plan.sh, promote-from-inbox.sh) stamp
# correct semantics for fresh plans, so a fresh install never needs this; only
# existing adopters with legacy manifests do.
# IDEMPOTENT: once the display name is rescued, a second run rewrites nothing.
# Malformed manifests are skipped with a diagnostic, never half-written. The plans
# tree is git-tracked, so the migration is diff-reviewable and reversible. The
# migration's residue assertion FAILS if any `project:` value was mutated (never happens).
# Resolves the migration script. tools/ is NOT part of the installed $CLAUDE_HOME
# surface (a repo-transparency artifact, not a foundation-manifest files[] member),
# so the $CLAUDE_HOME/tools/ candidate only resolves if a prior install staged it;
# the load-bearing resolution is the $SOURCE_REPO/tools/ fallback. FOUNDATION_REPO is
# passed only as a spoke-resolve.sh library-location hint — NOT a cwd spoke anchor.
if [ "${UPGRADE_PRESENT:-0}" = "1" ]; then
  pid_migrate_script=""
  for _cand in "$CLAUDE_HOME/tools/migrate-project-identity.sh" \
               "$SOURCE_REPO/tools/migrate-project-identity.sh"; do
    [ -f "$_cand" ] && { pid_migrate_script="$_cand"; break; }
  done

  # Anchor guard (defense-in-depth). The pre-fix migration resolved a spoke from its
  # cwd anchor and re-stamped the corpus; an upgrade whose SOURCE anchor fell through
  # to the `home` catch-all (an unregistered project dir) WHILE the plan tree held real
  # non-home spoke stamps was the shape that corrupted a live tree. The fixed migration
  # is title-rescue-only and never re-stamps, so this is ADVISORY (a loud WARN),
  # escalating to a skip only under BRAIN_STEM_MIGRATE_STRICT=1; BRAIN_STEM_MIGRATE_ANCHOR_OK=1
  # silences it (explicit operator override). Deterministic: registry-membership
  # resolution of the source anchor + an at-risk-corpus check (NOT a transcript/mtime
  # heuristic). Fires only in the incident shape, so a normal upgrade stays quiet.
  # Fail-safe: any resolution error leaves the (safe) migration to proceed.
  pid_block_migrate=0
  if [ -n "$pid_migrate_script" ] && [ -d "$PLANS_HOME" ] \
     && [ "${BRAIN_STEM_MIGRATE_ANCHOR_OK:-0}" != "1" ]; then
    _pid_srlib=""
    for _c in "$CLAUDE_HOME/skills/new-plan/lib/spoke-resolve.sh" \
              "$SOURCE_REPO/skills/new-plan/lib/spoke-resolve.sh"; do
      [ -f "$_c" ] && { _pid_srlib="$_c"; break; }
    done
    if [ -n "$_pid_srlib" ]; then
      _pid_anchor="${SOURCE_REPO:-$PWD}"
      _pid_resolved="$( . "$_pid_srlib" 2>/dev/null; spoke_resolve_from_cwd "$_pid_anchor" 2>/dev/null )"
      _pid_anchor_c="$( cd "$_pid_anchor" 2>/dev/null && pwd -P 2>/dev/null || printf '%s' "$_pid_anchor" )"
      _pid_home_c="$( cd "$HOME" 2>/dev/null && pwd -P 2>/dev/null || printf '%s' "$HOME" )"
      if [ "$_pid_resolved" = "home" ] && [ "$_pid_anchor_c" != "$_pid_home_c" ]; then
        _pid_atrisk="$(
          . "$_pid_srlib" 2>/dev/null
          _reg="$(spoke_registry_path 2>/dev/null)"
          [ -f "$_reg" ] || exit 0
          python3 - "$_reg" "$PLANS_HOME" <<'PYG' 2>/dev/null
import json, os, sys
try:
    keys = {s.get("spoke_key", "") for s in json.load(open(sys.argv[1])).get("spokes", [])} - {"home", ""}
except Exception:
    sys.exit(0)
for dp, _, fn in os.walk(sys.argv[2]):
    if "manifest.json" in fn:
        try:
            if json.load(open(os.path.join(dp, "manifest.json"))).get("project") in keys:
                sys.stdout.write("1"); break
        except Exception:
            pass
PYG
        )"
        if [ "$_pid_atrisk" = "1" ]; then
          if [ "${BRAIN_STEM_MIGRATE_STRICT:-0}" = "1" ]; then
            pid_block_migrate=1
            warn "project:-field migration REFUSED (BRAIN_STEM_MIGRATE_STRICT): source anchor '$_pid_anchor' is unregistered (resolves to the 'home' fallback) and the plan tree carries non-home spoke stamps — strict mode blocks an unregistered-anchor upgrade (the migration is title-rescue-only; set BRAIN_STEM_MIGRATE_ANCHOR_OK=1 to allow)"
          else
            warn "project:-field migration: source anchor '$_pid_anchor' is unregistered (resolves to the 'home' fallback) and the plan tree carries non-home spoke stamps — the migration is TITLE-RESCUE-ONLY and will NOT re-stamp project: (set BRAIN_STEM_MIGRATE_STRICT=1 to block, BRAIN_STEM_MIGRATE_ANCHOR_OK=1 to silence)"
          fi
        fi
      fi
    fi
  fi

  if [ "$pid_block_migrate" = "0" ] && [ -n "$pid_migrate_script" ] && [ -d "$PLANS_HOME" ]; then
    if FOUNDATION_REPO="$CLAUDE_HOME" PLANS_ROOT="$PLANS_HOME" \
         bash "$pid_migrate_script" --plans-root "$PLANS_HOME" >/dev/null 2>"$CLAUDE_HOME/.pid-migrate.log"; then
      info "project:-field identity migration: applied (title-rescue-only; idempotent)"
    else
      # Non-fatal: on a residue/collision failure we warn and leave the tree as-is
      # (git-reversible). The migration's residue assertion catches any project: mutation.
      warn "project:-field identity migration: did not complete cleanly — see $CLAUDE_HOME/.pid-migrate.log (plans tree is git-reversible)"
    fi
    rm -f "$CLAUDE_HOME/.pid-migrate.log"
  elif [ "$pid_block_migrate" = "1" ]; then
    : # refused above under strict mode; the plan tree is left untouched
  else
    info "project:-field identity migration: script or plans tree absent — no-op"
  fi
fi

# Step 11.8: $CLAUDE_HOME/.gitignore secret-exclusion seed.
# Deny-list-at-the-VCS-
# boundary: keep the secret-bearing surfaces (settings.local.json, projects/,
# .pre-uninstall-*) out of the git index so the backup wrapper can never
# exfiltrate them to a remote. Runs AFTER the Step-10 ship loops and BEFORE the
# git-init (secure-bootstrap order: write .gitignore -> git init -> first add).
#
# SHIP-PATH DISAMBIGUATION (validation
# correction): Step 10's named-list loop (above) does NOT carry
# claude-home.gitignore — we DIRECT-SEED $CLAUDE_HOME/.gitignore from
# $SOURCE_REPO/templates/claude-home.gitignore and NEVER stage it into
# $CLAUDE_HOME/templates/. This is Option A of the two options (direct seed,
# not named-list+translate-copy). The generator path-translation map
# (generate-foundation-manifest.sh) mirrors this exactly:
# templates/claude-home.gitignore -> installed .gitignore, source repo-root
# .gitignore stays excluded.
#
# MERGE-SAFE / IDEMPOTENT: absent -> cp; present -> append the brain-stem block
# behind a `# brain-stem: managed secret-exclusions` sentinel ONLY when that
# sentinel is absent (grep -qF guard). NEVER foundation-replaces the installed
# .gitignore (THREE-WAY-MERGE class) so an adopter's own ignore rules survive.
gitignore_template="$SOURCE_REPO/templates/claude-home.gitignore"
gitignore_target="$CLAUDE_HOME/.gitignore"
gitignore_sentinel="# brain-stem: managed secret-exclusions"
# .gitignore is a sha-pinned foundation-manifest.json files[] member, but this
# three-way append leaves an adopter's merged .gitignore at a DIFFERENT on-disk sha.
# Each delivery branch records a `three-way-merge` disposition so the delivery-
# verification gate (Step 13.6) exempts it the same data-driven way it exempts
# overlay-master.json — otherwise a pre-existing non-sentinel .gitignore never
# converges, the home never stamps, and the sentinel makes the re-run idempotent:
# an infinite re-run loop. Disposition key MUST equal the installed .gitignore's
# foundation-manifest.json::files[].path (the generator maps
# templates/claude-home.gitignore -> .gitignore).
gitignore_rel=".gitignore"

if [ ! -f "$gitignore_template" ]; then
  warn "templates/claude-home.gitignore not present at $gitignore_template — skipping \$CLAUDE_HOME/.gitignore secret-exclusion seed"
elif [ ! -f "$gitignore_target" ]; then
  # Absent: direct cp of the managed block.
  gitignore_tmp="$gitignore_target.tmp.$$"
  if ! cp "$gitignore_template" "$gitignore_tmp"; then
    diag ".gitignore seed: cp failed: $gitignore_template → $gitignore_tmp"
    rm -f "$gitignore_tmp"
    exit 11
  fi
  if ! mv -f "$gitignore_tmp" "$gitignore_target"; then
    diag ".gitignore seed: atomic mv failed: $gitignore_target"
    rm -f "$gitignore_tmp"
    exit 11
  fi
  info "\$CLAUDE_HOME/.gitignore seeded with brain-stem managed secret-exclusions ($gitignore_target)"
  UPGRADE_FILE_DISPOSITIONS="${UPGRADE_FILE_DISPOSITIONS}${gitignore_rel}	three-way-merge
"
elif grep -qF "$gitignore_sentinel" "$gitignore_target"; then
  # Present + sentinel already there: idempotent no-op (survivorship preserved).
  info "\$CLAUDE_HOME/.gitignore already carries the brain-stem managed secret-exclusions sentinel — preserving (no re-append)"
  UPGRADE_FILE_DISPOSITIONS="${UPGRADE_FILE_DISPOSITIONS}${gitignore_rel}	three-way-merge
"
else
  # Present + sentinel absent: append the managed block, leaving the adopter's
  # own ignore rules untouched (merge-safe). Blank-line separator for clarity.
  {
    printf '\n'
    cat "$gitignore_template"
  } >> "$gitignore_target" || {
    diag ".gitignore seed: append failed: $gitignore_target"
    exit 11
  }
  info "\$CLAUDE_HOME/.gitignore: appended brain-stem managed secret-exclusions block (adopter rules preserved)"
  UPGRADE_FILE_DISPOSITIONS="${UPGRADE_FILE_DISPOSITIONS}${gitignore_rel}	three-way-merge
"
fi

# Step 11.9: git-init the brain-stem-owned $CLAUDE_HOME (the
# root cause — the first backup of a fresh adopter is a
# no-op because no default target is a git repo, so backup.sh:101-104 hits the
# "not a git repo, skipped" branch on $CLAUDE_HOME).
#
# SANCTIONED PATH (remediation):
# auto-`git init` of ~/.claude INSIDE backup.sh is explicitly REJECTED
# (surprise-mutation + immediate push failure). Install-time, opt-in, default-
# target-ONLY init is the sanctioned alternative — $CLAUDE_HOME is the one tree
# brain-stem owns. We init the dir but add NO remote and make NO commit (no
# surprise push); the first real commit is the adopter's first backup.sh run.
#
# ORDERING (secure repo bootstrap, validated above): the .gitignore
# seed at Step 11.8 lands BEFORE this init, so the first `git add -A .` (the
# adopter's first backup) never indexes settings.local.json / projects/ /
# .pre-uninstall-*. Reversing the order leaks on commit 1.
#
# SCOPE: $CLAUDE_HOME ONLY. $VAULT_ROOT and $PLANS_DIR are adopter-owned trees —
# silently git-initing them would be the surprise-mutation the policy rejects; those get
# an actionable warning at backup time instead.
#
# IDEMPOTENT: `[ -d "$CLAUDE_HOME/.git" ] ||` guards the init, so a re-run never
# re-inits or errors. The runtime .git dir is absent-by-construction (no manifest
# baseline), mirroring the orchestrator/state/ precedent.
if [ -d "$CLAUDE_HOME/.git" ]; then
  info "\$CLAUDE_HOME already a git repo (.git present) — skipping git-init (idempotent guard)"
elif ! command -v git >/dev/null 2>&1; then
  warn "git not found on PATH — skipping \$CLAUDE_HOME git-init; backup.sh will emit an actionable non-repo warning until \$CLAUDE_HOME is a repo"
elif git -C "$CLAUDE_HOME" init -q >/dev/null 2>&1; then
  # init-only: no `git remote add`, no `git commit`. The first commit is the
  # adopter's first backup.sh run (which the ignore already protects).
  info "\$CLAUDE_HOME git-inited (no remote, no commit) — first backup.sh run now produces a real commit ($CLAUDE_HOME)"
else
  warn "git init of \$CLAUDE_HOME failed — backup.sh will emit an actionable non-repo warning until \$CLAUDE_HOME is a repo"
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

# Step 12.5: data-driven settings-required-hooks reconciler (
# UP). Generalizes the two former bespoke append blocks (the old Step
# 12.5 spec-context-inject UserPromptSubmit patch + Step 12.6 AskUserQuestion
# PreToolUse patch) into ONE loop over templates/settings-required-hooks.json.
#
# Root cause (1b): the Step 12 jq merge `template * user_settings`
# lets the adopter's hook ARRAY win on array conflict, so a NEW foundation hook in
# that array (the whole PostToolUse 5-command chain, the PreToolUse Edit|Write
# pre-write-guard.sh wire, etc.) is silently dropped on re-install. The hand-patched
# Steps 12.5/12.6 only re-landed two specific commands each; every other foundation
# hook had no equivalent and silently vanished.
#
# Fix: templates/settings-required-hooks.json declares every foundation-required
# hook as a {event, matcher, command, timeout?} tuple (a FOUNDATION-REPLACE managed
# artifact in foundation-manifest.json::files[], shipped to $CLAUDE_HOME at Step 10).
# This single reconciler iterates that declaration and, per tuple:
#   (a) detect-by-command-substring — present anywhere under .hooks[event] => no-op
#       (per-COMMAND idempotency; a partially-present chain backfills only the
#       missing commands);
#   (b) absent => locate the bucket whose .matcher == tuple.matcher and append the
#       command there (the 12.5-shape append) — creating a new matcher bucket ONLY
#       when none matches (the 12.6-shape new-bucket). null matcher (UserPromptSubmit/
#       SessionStart/Stop/SessionEnd/InstructionsLoaded) matches the bucket that has
#       no .matcher key — never produces a DUPLICATE Edit|Write PostToolUse bucket;
#   (c) carry the template's timeout verbatim (timeout:3/5 on memory-auto-stamp/
#       memory-globalize-auto/tasks-md-autosync are emitted into the appended tuple).
#
# POS1 survivorship: ADDS-only — never removes or reorders the adopter's own hooks.
# Runs AFTER the Step 12 G7-gated atomic mv (above), so its additive mutations
# cannot trip G7 (G7 fires only on a DROPPED before-path; an add introduces a new
# after-path, never deletes a before-path).
required_hooks_decl="$CLAUDE_HOME/templates/settings-required-hooks.json"
if [ -f "$target_settings" ] && [ -f "$required_hooks_decl" ]; then
  tmp_settings_125="$CLAUDE_HOME/.settings.json.tmp.125.$$"
  # Single jq pass: reduce over the declared tuples, appending each absent command
  # into its matcher-resolved bucket. Idempotent by per-COMMAND substring presence.
  if ! jq \
    --slurpfile decl "$required_hooks_decl" \
    '
    # Resolve the declaration array under either the {required_hooks:[...]} wrapper
    # or a bare top-level array (tolerant of both shapes).
    ($decl[0] | if type == "object" then .required_hooks else . end) as $tuples
    | reduce $tuples[] as $t (
        .;
        ($t.event)   as $ev
        | ($t.matcher)  as $mt      # may be null (matcher-less event buckets)
        | ($t.command)  as $cmd
        | ({"type":"command","command":$cmd}
            + (if ($t.timeout != null) then {"timeout":$t.timeout} else {} end)) as $hookobj
        # statusLine is structurally distinct — it lives at top-level
        # .statusLine.command, NOT under .hooks[$ev]. The .hooks tuple loop below
        # cannot recover a SHADOWED statusLine (a user who wins the .statusLine object
        # wholesale leaves the foundation worker-statusline.sh unrecoverable). Re-land
        # the foundation command when .statusLine is ABSENT or its .command DIVERGES;
        # adds-only on absence, corrective on divergence.
        | if $ev == "statusLine"
          then
            ( if (.statusLine.command // "") == $cmd then .
              else .statusLine = ({"type":"command","command":$cmd}) end )
        # (a) already present anywhere under this event? -> per-COMMAND no-op.
        elif ([ (.hooks[$ev] // [])[]?.hooks[]?.command // "" ]
               | any(. == $cmd))
          then .
          else
            # (b) append into the bucket whose .matcher == tuple.matcher
            #     (null matcher == a bucket with no .matcher key); create the
            #     bucket ONLY when none matches.
            .hooks[$ev] = (
              (.hooks[$ev] // []) as $buckets
              | ( [ $buckets | to_entries[]
                    | select((.value.matcher // null) == $mt) | .key ] | first ) as $idx
              | if $idx == null then
                  # no matching bucket -> 12.6-shape new matcher bucket
                  $buckets + [
                    ( (if $mt != null then {"matcher":$mt} else {} end)
                      + {"hooks":[$hookobj]} )
                  ]
                else
                  # matching bucket -> 12.5-shape append into its hooks array
                  ( $buckets
                    | .[$idx].hooks = ((.[$idx].hooks // []) + [$hookobj]) )
                end
            )
          end
      )
    ' "$target_settings" > "$tmp_settings_125" 2>/dev/null; then
    diag "jq settings-required-hooks reconciler failed (Step 12.5); manual resolution required"
    rm -f "$tmp_settings_125"
    exit 40
  fi
  sync 2>/dev/null || true
  mv -f "$tmp_settings_125" "$target_settings" || { diag "atomic mv failed: $target_settings (Step 12.5)"; rm -f "$tmp_settings_125"; exit 11; }
fi

# Step 13: schema parse validation (post-install)
for schema in "$CLAUDE_HOME/schemas"/*.json; do
  [ -e "$schema" ] || continue
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$schema" 2>/dev/null; then
    diag "schema parse failure: $schema"
    exit 30
  fi
done

# Step 13.6: jsonschema validation of foundation-shipped configs. Graceful skip when
# python3 jsonschema is unavailable on the adopter machine — preserves the
# error_action: ignore posture (fresh adopters degrade silently at runtime when
# validation tooling absent). Adopters with jsonschema installed (pip3 install
# jsonschema) get fail-loud-at-install behavior on malformed configs via exit 30.
#
# The prior loop validated two HARDCODED configs at
# $CLAUDE_HOME/hooks/config/{doc-dependencies,drift-allowlist}.json — a path NO
# product tree ever populates (hooks/config/ ships only .gitkeep). doc-dependencies.json
# is a repo-only pillar that composes into foundation-master.json (not shipped to the
# adopter), and its companion schema was dropped from the ship surface; drift-allowlist.json
# has no source file at all. So BOTH `[ -f ]` guards always short-circuited → the only
# install-time jsonschema loop was a fully dead branch. Replaced with a manifest-driven
# walk: validate exactly the configs that are ACTUALLY SHIPPED (present in the shipped
# foundation-manifest) against schemas that are ACTUALLY SHIPPED, resolving each config at
# its REAL installed path. The config<->schema pairing is convention-based (<name>.json
# validated by <name>-schema.json when both landed); a config with no shipped companion
# schema is parse-validated only (Step 13) and skipped here. Today no shipped config has a
# shipped companion schema, so this is a correct no-op that lights up the instant a real
# config+schema pair ships — not a dead branch masquerading as coverage.
if python3 -c "import jsonschema" 2>/dev/null; then
  s136_manifest="$CLAUDE_HOME/governance/foundation-manifest.json"
  if [ -f "$s136_manifest" ] && command -v jq >/dev/null 2>&1; then
    # Every shipped *.json under a config-bearing tree (governance/, hooks/config/)
    # whose <name>-schema.json companion is ALSO shipped. Resolve from the manifest
    # path-set (the adopter's ground truth), not a hardcoded list.
    s136_shipped="$(jq -r '.files[].path' "$s136_manifest" 2>/dev/null)"
    printf '%s\n' "$s136_shipped" \
      | grep -E '^(governance|hooks/config)/[A-Za-z0-9._-]+\.json$' \
      | grep -vE '/[A-Za-z0-9._-]*-schema\.json$' \
      | grep -vE '/(foundation-manifest|foundation-master|overlay-master)\.json$' \
      | while IFS= read -r cfg_rel; do
          [ -z "$cfg_rel" ] && continue
          cfg_base="${cfg_rel##*/}"
          sch_rel="schemas/${cfg_base%.json}-schema.json"
          # Both the config AND its companion schema must be shipped (in-manifest AND
          # on disk) for a schema-conformance gate; otherwise skip (parse-only).
          printf '%s\n' "$s136_shipped" | grep -qxF "$sch_rel" || continue
          cfg_path="$CLAUDE_HOME/$cfg_rel"
          sch_path="$CLAUDE_HOME/$sch_rel"
          [ -f "$cfg_path" ] || continue
          [ -f "$sch_path" ] || continue
          if ! python3 -c "import json,sys; from jsonschema.validators import Draft202012Validator; Draft202012Validator(json.load(open(sys.argv[1]))).validate(json.load(open(sys.argv[2])))" "$sch_path" "$cfg_path"; then
            diag "config schema validation failed: $cfg_path against $sch_path"
            exit 30
          fi
        done
    # `while` runs in a subshell (pipe); propagate an inner exit 30 to the installer.
    s136_rc=$?
    [ "$s136_rc" -eq 30 ] && exit 30
  else
    warn "Step 13.6: foundation-manifest or jq unavailable; manifest-driven config-vs-schema validation skipped. Configs were JSON-syntax-validated by Step 13."
  fi
else
  warn "python3 jsonschema module not available; install-time config-vs-schema validation skipped (pip3 install jsonschema to enable). Configs were JSON-syntax-validated by Step 13."
fi

# PyYAML prereq (mirrors the jsonschema prereq+warn above). The two `govern`
# frontmatter-rendering modes — /govern register --kind writer and --kind
# doc-amender-prompt — render YAML frontmatter via python3's yaml module
# (yaml.safe_dump) and hard-fail (return 3) when it is absent. macOS system
# python ships no PyYAML, so a bare adopter would otherwise hit a terse
# unexplained failure the first time they register a writer / doc-amender
# prompt, with no install-time signal that a prerequisite was missing. Probe it
# here and, on absence, warn-and-continue (graceful degrade — never abort the
# install) naming both gated modes + the exact `pip3 install pyyaml` remediation.
if python3 -c "import yaml" 2>/dev/null; then
  :
else
  warn "python3 pyyaml module not available; the two frontmatter-rendering govern modes (/govern register --kind writer and /govern register --kind doc-amender-prompt) will fail to render frontmatter (return 3) until it is installed (pip3 install pyyaml to enable)."
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
# governance/foundation-manifest.json SELF-EXCLUDES from its own files[] (a manifest
# cannot record its own sha256 — circular), so it is in NEITHER the adopter's frozen
# prior-release baseline NOR the shipped files[]; upgrade_foundation_file classifies it
# user-preserve-skip and the plain cp -n below SILENTLY SKIPS it on an upgrade (dest
# pre-exists). The live manifest then stays frozen at the prior-release seed while every
# managed file converges to the shipped release — mis-stamping .installed-state.json::manifest_sha256
# and making uninstall.sh misclassify every upgraded-but-pristine file as user-edited.
# The manifest is foundation-runtime, never user content, so a take-new clobber on the
# upgrade/legacy lane is correct. Force-copy whenever the dest pre-exists on a non-fresh
# apply lane; fresh installs (dest absent) are unaffected (cp -n == cp -f there).
manifest_cp="$cp_clobber"
if [ "$APPLY_MODE" = "1" ] && { [ "$UPGRADE_ENVELOPE_ON" = "1" ] || [ "${LEGACY_ADOPT:-0}" = "1" ]; }; then
  manifest_cp="-f"
fi
if [ -f "$manifest_src" ]; then
  cp $manifest_cp "$manifest_src" "$manifest_dst" 2>/dev/null || true
  if [ -f "$manifest_dst" ]; then
    if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$manifest_dst" 2>/dev/null; then
      diag "governance/foundation-manifest.json parse failure post-copy: $manifest_dst"
      exit 30
    fi
  fi
else
  warn "governance/foundation-manifest.json not present at SOURCE_REPO (baseline absent; G2 + fingerprint match unavailable until generated)"
fi

# Step 13.6: forward-only idempotent migrations runner
# Runs AFTER Step 13.5 validated the freshly-copied
# manifest. Iterates the SHIPPED $CLAUDE_HOME/migrations/NNNN-slug.sh files in
# numeric prefix order; selects those NOT already in the high-water log whose
# `applies_at` <= TARGET_VERSION (set-difference selection — the floor is
# diagnostic-only, so bitten installs self-heal; run-migrations.sh header contract)
# (PRIOR_MIGRATIONS_APPLIED, read at entrypoint); honors min_from (SKIP-WARN when
# min_from > a REAL sha-matched floor); runs the rest converge-if-needed; emits
# each successfully-applied id on stdout.
#
# FLOOR_IS_REAL: a stamped install (INSTALLED_VERSION != "(none)") is a real
# sha-matched floor, so a migration whose min_from is ABOVE the floor is
# SKIP-WARNed. A fresh/legacy-adopt home (no stamp ⇒ "(none)") is the v0.0.0
# unknown-floor lane: the runner normalizes the floor to v0.0.0, runs the full
# chain from 0001, and NEVER min_from-skips (every migration is authored to
# tolerate the oldest/empty precondition per the authoring contract).
#
# The high-water log is the COMBINED set (PRIOR_MIGRATIONS_APPLIED + the ids the
# runner emits this invocation), folded into the Step 13.7 stamp below.
# CRITICAL (advisory): foundation_version is bumped to
# TARGET_VERSION only on overall-apply-success. A migration exiting non-zero
# halts here (exit 41) BEFORE the Step 13.7 stamp — so the on-disk
# foundation_version stays at the pre-invocation value (the partial high-water
# mark for resume; roll-forward re-runs the unapplied tail because each step is
# idempotent). Forward-only; no down-migration. The full pre-mutation snapshot +
# reverse-journal restore is its envelope, NOT the migration runner's; the runner
# owns the chain + the don't-bump-on-failure contract.
RAN_MIGRATIONS=""
if [ -f "$CLAUDE_HOME/migrations/run-migrations.sh" ] && [ -n "$TARGET_VERSION" ]; then
  if [ "$INSTALLED_VERSION" = "(none)" ]; then mig_floor_is_real=0; else mig_floor_is_real=1; fi

 # whole-file sqlite pre-snapshot INSIDE the rollback
  # envelope. The sqlite DDL migrations run inside a single BEGIN/COMMIT (the
  # demonstrator's own transaction); the upgrade envelope owns the whole-file .sqlite(+wal/shm)
  # pre-snapshot so a migration-chain failure restores the db WHOLESALE (no
  # per-row reverse). Each db file is journaled (pre-state=present → cp-restore on
  # rollback; pre-state=absent → rm on rollback) BEFORE the runner mutates it.
  if [ "$UPGRADE_ENVELOPE_ON" = "1" ]; then
    for dbf in "$CLAUDE_HOME/governance/manifest.sqlite" \
               "$CLAUDE_HOME/governance/manifest.sqlite-wal" \
               "$CLAUDE_HOME/governance/manifest.sqlite-shm"; do
      dbrel="${dbf#"$CLAUDE_HOME"/}"
      if [ -f "$dbf" ]; then
        if upgrade_snapshot_present "$dbf" "$dbrel"; then
          journal_record "$dbf" "sqlite-presnapshot" "present" "$dbrel"
        else
          diag "failed to pre-snapshot the sqlite db $dbf before migrations — rolling back."
          rollback_restore "sqlite-presnapshot-failed:$dbf"
        fi
      fi
    done
  fi

  mig_out="$CLAUDE_HOME/migrations/.run-$$.ids"
  if MIGRATIONS_DIR="$CLAUDE_HOME/migrations" \
     INSTALLED_VERSION="$INSTALLED_VERSION" \
     TARGET_VERSION="$TARGET_VERSION" \
     APPLIED_IDS="$PRIOR_MIGRATIONS_APPLIED" \
     FLOOR_IS_REAL="$mig_floor_is_real" \
     CLAUDE_HOME="$CLAUDE_HOME" \
       bash "$CLAUDE_HOME/migrations/run-migrations.sh" > "$mig_out"; then
    RAN_MIGRATIONS="$(cat "$mig_out" 2>/dev/null || true)"
    rm -f "$mig_out" 2>/dev/null || true
    [ -n "$RAN_MIGRATIONS" ] && info "migrations applied this run: $(printf '%s' "$RAN_MIGRATIONS" | tr '\n' ' ')"
  else
    rm -f "$mig_out" 2>/dev/null || true
 # on the envelope lane a migration failure rolls back the whole
    # transaction (restores every applied file + the sqlite db wholesale +
    # .installed-state.json wholesale). Off the envelope (fresh/legacy) keep the
    # runner's bare exit 41 contract.
    if [ "$UPGRADE_ENVELOPE_ON" = "1" ]; then
      diag "migration runner exited non-zero (a migration failed) — rolling back the upgrade transaction."
      rollback_restore "migration-failed"
    fi
    diag "migration runner exited non-zero (a migration failed) — foundation_version NOT bumped; resume by re-running install --apply after fixing the cause"
    exit 41
  fi
fi

# Step 13.7: installed-state stamp + frozen baseline manifest
# (write side). Runs AFTER Step 13.5 validated the
# freshly-copied manifest, on overall-apply-success. This is the version-
# awareness substrate the engine reads at entrypoint (the read side above).
#
#   $CLAUDE_HOME/governance/.installed-state.json — machine-readable record:
#     foundation_version (verbatim from the shipped manifest .version),
#     installed_at, source_install_sha256, manifest_sha256,
# migrations_applied[] (high-water log; folds the COMBINED set:
#     PRIOR_MIGRATIONS_APPLIED read at entrypoint + the ids the Step 13.6 runner
#     emitted this invocation — preserving the log across re-applies so a second
#     --apply skips already-applied ids), schema_versions{} (ships {};
#     population is a later-task concern, not an acceptance criterion for this stage).
#   $CLAUDE_HOME/governance/.installed-baseline-manifest.json — a BYTE-IDENTICAL
#     frozen copy of the shipped manifest; the per-file sha256 three-way base
# the disposition engine pins against.
#
# CORRECTION (versioning advisory): the foundation_version bump gate is overall-
# apply-success when the migration range is EMPTY (every current upgrade, incl.
# this slice that ships no runner) — last-migration ordering only constrains
# it once >=1 migration runs. Reaching this line means Steps 1..13.6 ran
# without a non-zero exit ⇒ apply succeeded ⇒ stamp TARGET_VERSION. A mid-chain
# migration failure exits before here, leaving the pre-invocation
# stamp intact (the partial high-water mark).
#
# --- delivery-verification gate ---------
# Layer-2 (fail-closed in-product). Runs IMMEDIATELY
# BEFORE the Step 13.7 stamp + baseline-freeze block below, so a delivery shortfall
# provably prevents BOTH the .installed-state.json stamp AND the
# .installed-baseline-manifest.json freeze (couples to the upgrade posture via delivery_verified).
#
# WHY: — the legacy `cp -R` lane swallowed copy rc with `|| true`, so the
# engine stamped + froze the baseline over an UNDER-DELIVERED home (a false
# success). routes the legacy lane through the per-file walk; this gate
# is the fail-closed assertion that the walk actually CONVERGED every managed file
# it was responsible for delivering.
#
# SCOPE: verify ONLY the SHIPPED governance/foundation-manifest.json
# files[] members — the exact set the install ships (enumerated from the shipped
# manifest, IFS-safe, the same discipline as apply_subtree_legacy). A changed-but-
# never-shipped source file (e.g. schemas/foundation-master-schema.json, in
# $SOURCE_REPO but NOT in files[]) is NOT in this set and never trips the refuse.
#
# DISPOSITION-AWARENESS: the gate compares against the EXPECTED
# post-disposition state, NOT a blanket files[]==shipped. A files[] member is
# EXEMPT from the ==shipped check when ANY of:
#   - it is governance/overlay-master.json (the THREE-WAY-MERGE skeleton-merge
#     surface — on-disk != shipped BY DESIGN; never a take-new target), OR
#   - its disposition kind (read from the UPGRADE_FILE_DISPOSITIONS accumulator the
#     per-file walk produced) is a merge / edited / deferred kind:
#       skeleton-merge / skeleton-merge-skip (overlay-master three-way-merge),
#       replace+foundation-local / legacy-adopt-replace+foundation-local
#         (State-3 adopter-edited file: take-new landed, prior bytes sidecarred),
#       user-preserve-skip (not in the managed set; structurally untouched),
#       sidecar-skip-deferred (outstanding .foundation-new — deferred to user), OR
#   - a <path>.foundation-local sidecar exists on disk (belt-and-suspenders for the
#     edited-surface case even if the accumulator record is absent).
# Only the take-new dispositions (replace / legacy-adopt-replace / new-ship) and
# any files[] member with NO disposition record on the delivering lane are held to
# sha256(on-disk) == sha256(shipped).
#
# LANE: fires on the DELIVERING lane only — the stamped envelope walk
# (UPGRADE_ENVELOPE_ON=1) OR the legacy lane (LEGACY_ADOPT=1 with
# APPLY_MODE=1). A fresh install / dry-run never reaches this assertion (no
# per-file delivery happened) and is unaffected.
#
# SINGLE SOURCE: the shortfall set is computed ONCE here; the operator-
# actionable exit-56 diag below consumes the SAME set (no second verification
# walk).
delivery_verified=1
if [ -f "$manifest_dst" ] && [ -n "$TARGET_VERSION" ] \
   && { [ "$UPGRADE_ENVELOPE_ON" = "1" ] || { [ "$LEGACY_ADOPT" = "1" ] && [ "$APPLY_MODE" = "1" ]; }; }; then
  # delivery_shortfall = newline-joined "<rel>\t<expected-sha>\t<ondisk-sha>" for
  # every non-exempt files[] ship-member whose on-disk content != shipped content.
  delivery_shortfall="$(
    SHIPPED_MANIFEST="$manifest_src" \
    DISPOSITIONS="$UPGRADE_FILE_DISPOSITIONS" \
    SRC_REPO="$SOURCE_REPO" \
    CLAUDE_HOME="$CLAUDE_HOME" \
    python3 -c '
import hashlib, json, os, sys

src_repo = os.environ["SRC_REPO"]
claude_home = os.environ["CLAUDE_HOME"]

# Dispositions the per-file walk recorded: rel -> kind (TSV "<rel>\t<kind>").
disp = {}
for line in os.environ.get("DISPOSITIONS", "").splitlines():
    if "\t" not in line:
        continue
    rel, kind = line.split("\t", 1)
    rel = rel.strip()
    if rel:
        disp[rel] = kind.strip()

# Kinds EXEMPT from the ==shipped check (merge / edited / deferred surfaces).
EXEMPT_KINDS = {
    "skeleton-merge", "skeleton-merge-skip",
    "replace+foundation-local", "legacy-adopt-replace+foundation-local",
    "user-preserve-skip", "sidecar-skip-deferred",
    # The installed .gitignore is a THREE-WAY-MERGE sentinel-append surface (Step
    # 11.8) — on-disk != pinned template sha BY DESIGN for any adopter with pre-
    # existing ignore rules. Data-driven exemption (same shape as the overlay-
    # master.json hardcode above); self-extends to future merge-delivered files.
    "three-way-merge",
}

def sha256(p):
    h = hashlib.sha256()
    try:
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
    except OSError:
        return None
    return h.hexdigest()

try:
    m = json.load(open(os.environ["SHIPPED_MANIFEST"]))
except Exception:
    # Shipped manifest unreadable here would have failed Step 13.5 already; treat
    # as no shortfall (do not block on a manifest the install just validated).
    sys.exit(0)

for f in m.get("files", []):
    rel = f.get("path", "")
    if not rel:
        continue
 # overlay-master.json is the three-way-merge surface — never ==shipped.
    if rel == "governance/overlay-master.json":
        continue
    kind = disp.get(rel)
    if kind in EXEMPT_KINDS:
        continue
    dest = os.path.join(claude_home, rel)
    # Belt-and-suspenders: an edited-surface sidecar exempts even absent a record.
    if os.path.exists(dest + ".foundation-local"):
        continue
    src = os.path.join(src_repo, rel)
    sha_shipped = f.get("sha256", "") or (sha256(src) or "")
    sha_disk = sha256(dest)
    if sha_disk is None:
        sha_disk = "(absent)"
    if sha_disk != sha_shipped:
        print("%s\t%s\t%s" % (rel, sha_shipped, sha_disk))
' 2>/dev/null
  )"
  if [ -n "$delivery_shortfall" ]; then
    delivery_verified=0
 # operator-actionable refuse. Mirror the G2
    # violation-list printf-to-stderr pattern (install.sh g2 block). SINGLE SOURCE:
    # iterate the SAME $delivery_shortfall set computed above (no second scan).
    shortfall_count="$(printf '%s\n' "$delivery_shortfall" | grep -c . 2>/dev/null || printf '0')"
    diag "delivery shortfall: $shortfall_count managed file(s) did not converge to the shipped content (the per-file delivery walk left them stale). Refusing to stamp this home (no .installed-state.json written, baseline NOT advanced) — exit 56."
    printf '%s\n' "$delivery_shortfall" | while IFS=$'\t' read -r sf_path sf_exp sf_disk; do
      [ -z "$sf_path" ] && continue
      sf_exp_p="$(printf '%s' "$sf_exp" | cut -c1-12)"
      if [ "$sf_disk" = "(absent)" ]; then
        sf_disk_p="(absent)"
      else
        sf_disk_p="$(printf '%s' "$sf_disk" | cut -c1-12)"
      fi
      printf '  %s (expected sha %s, on-disk %s)\n' "$sf_path" "$sf_exp_p" "$sf_disk_p" >&2
    done
    diag "remediation: re-run \`install.sh --apply\` — the home is left UN-STAMPED and re-classifies as legacy/upgrade, so the next run re-attempts delivery of these files and converges (forward-progress). No manual fix is required for a recoverable under-delivery."
    exit 56
  fi
fi
# --- end delivery-verification gate ------------------------------
if [ -f "$manifest_dst" ] && [ -n "$TARGET_VERSION" ]; then
 # the 3-way base stays PINNED to the prior frozen
  # .installed-baseline-manifest.json while ANY .foundation-new sidecar is
  # outstanding (an unresolved deferred-to-user merge). Advancing the base before
  # the merge lands would make a second-apply-after-conflict NON-idempotent (the
  # new on-disk would become the base and the parked .foundation-new could never
  # reconcile). Only re-freeze the base on a CLEAN apply with no sidecar left.
  baseline_pin=0
  if [ "$UPGRADE_ENVELOPE_ON" = "1" ]; then
    if LC_ALL=C find "$CLAUDE_HOME" -name '*.foundation-new' -type f -print 2>/dev/null | grep -q .; then
      baseline_pin=1
      warn "an outstanding .foundation-new sidecar is present — the 3-way base stays PINNED to the prior .installed-baseline-manifest.json (not advanced) until the merge lands with no sidecar outstanding."
    fi
  fi
 # do NOT advance/freeze the baseline unless the
  # the delivery verification PASSED. The gate above exit-56 short-circuits
  # before reaching this line on a shortfall (the PRIMARY guard); the
  # delivery_verified condition here is the belt-and-suspenders so even a refactor
 # that reorders the gate cannot freeze an unverified baseline. WHY: freezing .installed-baseline-manifest.json to the v1.1.x shipped
  # shas over an under-delivered (still-stale v1.0.2) home creates the State-3 trap —
  # the NEXT apply sees sha_disk(v1.0.2) != sha_base(v1.1.x) and misarchives every
  # pristine file as a .foundation-local "adopter edit". Gating the freeze on
  # delivery_verified prevents creating that trap. The existing baseline_pin
  # outstanding-sidecar guard is PRESERVED unchanged (a separate, correct pin).
  if [ "$baseline_pin" != "1" ] && [ "$delivery_verified" = "1" ]; then
    # Byte-identical frozen copy of the SHIPPED manifest (the three-way base).
    cp -f "$manifest_src" "$INSTALLED_BASELINE_MANIFEST_PATH" 2>/dev/null \
      || { diag "failed to write frozen baseline manifest at $INSTALLED_BASELINE_MANIFEST_PATH"; exit 30; }
  fi
  state_installed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  state_install_sha="$(shasum -a 256 "$0" 2>/dev/null | awk '{print $1}')"
  state_manifest_sha="$(shasum -a 256 "$manifest_dst" 2>/dev/null | awk '{print $1}')"
  if ! FV="$TARGET_VERSION" IA="$state_installed_at" SS="$state_install_sha" MS="$state_manifest_sha" \
      PRIOR_MIG="$PRIOR_MIGRATIONS_APPLIED" RAN_MIG="$RAN_MIGRATIONS" \
      python3 -c '
import json, os, sys
# COMBINED high-water log: prior on-disk ids + the ids the Step 13.6 runner
# applied this invocation, de-duplicated preserving first-seen order.
applied = []
for src in (os.environ.get("PRIOR_MIG", ""), os.environ.get("RAN_MIG", "")):
    for line in src.splitlines():
        mid = line.strip()
        if mid and mid not in applied:
            applied.append(mid)
rec = {
    "foundation_version": os.environ["FV"],
    "installed_at": os.environ["IA"],
    "source_install_sha256": os.environ["SS"],
    "manifest_sha256": os.environ["MS"],
    "migrations_applied": applied,
    "schema_versions": {},
}
with open(sys.argv[1], "w") as f:
    json.dump(rec, f, indent=2)
    f.write("\n")
' "$INSTALLED_STATE_PATH" 2>/dev/null; then
    diag "failed to write installed-state stamp at $INSTALLED_STATE_PATH"
    exit 30
  fi
  if [ -n "${RAN_MIGRATIONS:-}" ]; then
    info "installed-state stamped: foundation_version=$TARGET_VERSION (migrations applied this run: $(printf '%s' "$RAN_MIGRATIONS" | tr '\n' ' '); baseline frozen)"
  else
    info "installed-state stamped: foundation_version=$TARGET_VERSION (migrations applied this run: none; baseline frozen)"
  fi
else
  warn "installed-state stamp skipped (manifest absent post-copy or shipped manifest carries no .version)"
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
 # per-file FOUNDATION-REPLACE disposition diff ("surface it in the diff").
  # Empty on fresh/legacy-adopt (no frozen baseline) where the disposition degrades
  # to the cp $cp_clobber legacy posture.
  printf 'upgrade_baseline_present: %s\n' "$UPGRADE_BASELINE_PRESENT"
  if [ "$UPGRADE_BASELINE_PRESENT" = "1" ] && [ -n "$UPGRADE_FILE_DISPOSITIONS" ]; then
    printf 'upgrade_file_dispositions:\n'
    printf '%s' "$UPGRADE_FILE_DISPOSITIONS" | while IFS=$'\t' read -r disp_path disp_kind; do
      [ -z "$disp_path" ] || printf '  - %s: %s\n' "$disp_path" "$disp_kind"
    done
  fi
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
  printf 'g3_settings_backup: %s\n' "${g3_settings_backup_path:-(none)}"
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

# OPT-IN frontmatter cohort backfill. Reached only on a
# completed --apply (so the NEW frontmatter-enforce.sh is in place). Runs ONLY when
# the adopter explicitly passed --frontmatter-fix — never auto-forced. Non-fatal: a
# backfill hiccup never fails an already-successful install.
if [ "$FRONTMATTER_FIX" = "1" ]; then
  _fm_fixer="$CLAUDE_HOME/skills/librarian/capabilities/frontmatter-enforce.sh"
  if [ -f "$_fm_fixer" ]; then
    info "opt-in frontmatter cohort backfill (--frontmatter-fix): running the shipped auto-fixer over the vault…"
    bash "$_fm_fixer" --fix --full || diag "frontmatter cohort backfill returned non-zero (non-fatal; install already complete)"
  fi
fi

info "install complete. next-steps:"
# The next-steps must reference ONLY shipped runnables. The minimum-viable foundation
# ships render-launchd.sh (a SINGLE-job renderer: `render-launchd.sh <job>`, job in
# {writer-reconciler, doc-amender}); the multi-job render-all-launchd.sh iterator was
# NEVER authored into the ship surface, so instructing the adopter to run it handed out
# a command that cannot run on a clean install. The for-each-job loop over the shipped
# single-job renderer is the resolution.
info "  - render plists for ALL declared jobs (post-onboarding) — loop the shipped single-job renderer:"
info "    for job in writer-reconciler doc-amender; do \$CLAUDE_HOME/installer/render-launchd.sh --staging-dir \$CLAUDE_HOME/Library/LaunchAgents.staging \"\$job\"; done"
info "  - render a single job manually:"
info "    \$CLAUDE_HOME/installer/render-launchd.sh --staging-dir \$CLAUDE_HOME/Library/LaunchAgents.staging <job-id>"
info "  - load the lanes NOW (real launchctl bootstrap): the SessionStart hook (session-start-launchd-bootstrap.sh) does this automatically in your next Aqua session; this is the manual fallback for a headless / non-session install — the production (no --staging-dir) render bootstraps each label:"
info "    for job in writer-reconciler doc-amender; do \$CLAUDE_HOME/installer/render-launchd.sh \"\$job\"; done"
info "  - OPT-IN frontmatter cohort backfill (migrate existing notes to the typed cohort): dry-run preview then apply:"
info "    \$CLAUDE_HOME/skills/librarian/capabilities/frontmatter-enforce.sh --full --dry-run   # preview proposed created/id/schema_version/description"
info "    \$CLAUDE_HOME/skills/librarian/capabilities/frontmatter-enforce.sh --fix --full        # apply the backfill (or re-run install.sh --upgrade --apply --frontmatter-fix)"
info "  - claude-mem bundle: deferred"
info "  - G6 install-side explicit label sentinel: deferred (transitively preserved via cp -R installer/; render-launchd.sh enforces at runtime)"
info "  - top-level exit codes 20/22/60: deferred to v2.1 (conflict-manifest, rsync-backup, grep-audit consumer)"
info "provenance: $log_path"

exit 0
