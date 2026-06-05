#!/bin/bash
# installer/render-launchd.sh — render a launchd plist from a template against
# orchestration.json, plutil-lint, atomically install to a target dir, and
# (production mode only) launchctl-bootstrap the resolved label.
#
# The minimum-viable foundation ships TWO launchd jobs:
#   - writer-reconciler  (WatchPaths primary + relaxed StartInterval backstop)
#   - doc-amender        (WatchPaths only — event-driven LLM lane)
# Connector/non-foundation job cases (architect, digest-run, chat-scrape,
# calendar-sync, meeting-processor, connector-runtime, inbox-processor) are
# DROPPED — the inbox-processor job + its stale `--vault-root`/`--state-file`
# cron-wrapper flags are RETIRED, reconciled to the writer-reconciler's actual
# arg surface (the cron-wrapper at
# installer/cron-wrappers/writer-reconciler-cron.sh).
#
# Usage: render-launchd.sh [--staging-dir <path>] [--dry-run] <job>
#
# Modes (mutually composable):
#   default                Production install. Writes to ~/Library/LaunchAgents/<Label>.plist,
#                          unconditionally `launchctl bootout` then `launchctl bootstrap`.
#   --staging-dir <path>   Staging install. Writes to <path>/<Label>.plist, skips
#                          launchctl bootout + bootstrap entirely (onboarder
#                          initial-job-setup; launchctl bootstrap isolation).
#   --dry-run              Renders + plutil-lints, prints rendered plist to stdout, NO
#                          write/bootstrap. Composable with --staging-dir.
#
# <job> is a template basename (`writer-reconciler` | `doc-amender`); must match
# `^[a-z][a-z0-9-]*$` and have a corresponding `templates/launchd/<job>.plist.tmpl`.
#
# LABEL_PREFIX defaults to `com.brain-stem` (matches namespace isolation —
# labels outside this prefix are refused by uninstall.sh).
#
# Exit codes:
#   0  success
#   2  bad invocation (missing/bad arg, missing template, dependency missing)
#   3  schedule resolution error (env var / orchestration.json read error)
#   4  rendered plist failed plutil -lint or atomic mv failed
#   5  rendered Label extraction failed or Label format invalid
#   6  launchctl bootstrap returned non-zero (production mode only)
#
# Dependencies: jq, plutil, launchctl (production mode only). Template
# substitution is a portable sed render over the fixed, format-validated var set
# (: the hard envsubst/GNU-gettext dependency was dropped — gettext is
# not on stock macOS, so the launchd jobs hard-failed on a clean Mac).
#
# R-23: bash 3.2 compat. R-37 single-deliverable.

set -u

diag() { printf 'render-launchd FAIL: %s\n' "$1" >&2; }
info() { printf 'render-launchd: %s\n' "$1"; }

# --- arg parse ---
staging_dir=""
dry_run=0
job=""

while [ $# -gt 0 ]; do
  case "$1" in
    --staging-dir)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        diag "--staging-dir requires a path argument"
        exit 2
      fi
      staging_dir="$2"
      shift 2
      ;;
    --staging-dir=*)
      staging_dir="${1#--staging-dir=}"
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      diag "unknown flag: $1"
      exit 2
      ;;
    *)
      if [ -n "$job" ]; then
        diag "extra positional arg: $1 (job already set to '$job')"
        exit 2
      fi
      job="$1"
      shift
      ;;
  esac
done

if [ -z "$job" ]; then
  diag "missing <job> arg. Usage: render-launchd.sh [--staging-dir <path>] [--dry-run] <job>"
  exit 2
fi
case "$job" in
  *[!a-z0-9-]*|[!a-z]*|"")
    diag "<job> must match ^[a-z][a-z0-9-]*\$ (got: '$job')"
    exit 2
    ;;
esac

# --- source paths.sh (post-install runtime path) ---
PATHS_SH="${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
if [ ! -r "$PATHS_SH" ]; then
  diag "paths.sh not readable at $PATHS_SH"
  exit 2
fi
# shellcheck source=/dev/null
. "$PATHS_SH"

# --- locate template ---
self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$self_dir/.." && pwd)"
TEMPLATE="$repo_root/templates/launchd/$job.plist.tmpl"
if [ ! -r "$TEMPLATE" ]; then
  diag "template not readable: $TEMPLATE"
  exit 2
fi

# --- dependency check ---
for tool in jq plutil; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    diag "$tool required but not found on PATH"
    exit 2
  fi
done
# launchctl is only required in production mode; defer that check.

# Portable template render: substitute each ${VAR} in the fixed, format-validated
# allowlist with its resolved value. Replaces the dropped envsubst dependency
#. Reads the same ${VAR} tokens envsubst does, so the templates are
# unchanged. The replacement string is escaped for sed (\, the | delimiter, and &)
# so values containing spaces, &, |, or \ render correctly; output is plutil-lint
# gated regardless, so a malformed render is caught before any write.
render_template() {
  # $1 = source template path; $2 = space-separated allowlist of $VAR tokens.
  # Resolved values are read from the (already exported) render-time env vars.
  local _src="$1" _allow="$2" _tok _name _val _sed=""
  for _tok in $_allow; do
    _name="${_tok#\$}"
    _val="${!_name}"
    # Escape \ first, then the | delimiter, then & (sed replacement specials).
    _val="${_val//\\/\\\\}"
    _val="${_val//|/\\|}"
    _val="${_val//&/\\&}"
    _sed="${_sed}s|\${${_name}}|${_val}|g;"
  done
  sed "$_sed" "$_src"
}

# --- compose render-time env vars ---
USER_HOME="$HOME"
# CLAUDE_HOME + CLAUDE_LOG_DIR sourced via paths.sh.
LABEL_PREFIX="${LABEL_PREFIX:-com.brain-stem}"

# TIMEZONE: $TZ env wins, else parse /etc/localtime symlink (no privilege, no
# command-execution overhead, launchd-context-safe). Final fallback EDT.
if [ -n "${TZ:-}" ]; then
  TIMEZONE="$TZ"
else
  TIMEZONE=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
fi
TIMEZONE="${TIMEZONE:-America/New_York}"

# Writer-pipeline render vars (plist shapes).
# WRITER_STAGING_ROOT: the SINGLE canonical EPHEMERAL staging area WatchPaths
# fires on ($CLAUDE_STATE_ROOT/vault-staging =
# ~/.local/state/brain-stem/vault-staging). Reconciles the 3-way
# divergence: this resolves to the SAME ephemeral root the reconciler +
# cron-wrappers + staging-emit.sh default to (was the durable-rooted
# $VAULT_WRITER_STATE_ROOT/staging — distinct tier, wrong target). The durable
# $VAULT_WRITER_STATE_ROOT (~/.local/share/brain-stem/vault-writers) stays
# separate (manifest.sqlite/daily-processing/raw).
WRITER_STAGING_ROOT="${WRITER_STAGING_ROOT:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/vault-staging}"
# WRITER_RECONCILER_BACKSTOP_SEC: the relaxed StartInterval backstop (default
# hourly) covering missed WatchPaths events. The empty-tick is a cheap no-op.
WRITER_RECONCILER_BACKSTOP_SEC="${WRITER_RECONCILER_BACKSTOP_SEC:-3600}"

case "$job" in
  writer-reconciler)
    # WatchPaths primary + relaxed StartInterval backstop.
    # The reconciler is the sole R-34 mechanical destination writer; trigger is
    # the staging root WatchPaths + the hourly backstop. The retired
    # inbox-processor's --vault-root/--state-file flags do NOT apply — the
    # cron-wrapper (installer/cron-wrappers/writer-reconciler-cron.sh) carries
    # the reconciler's actual arg surface.
    case "$WRITER_RECONCILER_BACKSTOP_SEC" in
      *[!0-9]*|"")
        diag "WRITER_RECONCILER_BACKSTOP_SEC must be a positive integer (got: '$WRITER_RECONCILER_BACKSTOP_SEC')"
        exit 3
        ;;
    esac
    allowlist='$USER_HOME $CLAUDE_HOME $CLAUDE_LOG_DIR $TIMEZONE $LABEL_PREFIX $WRITER_STAGING_ROOT $WRITER_RECONCILER_BACKSTOP_SEC'
    ;;
  doc-amender)
    # WatchPaths only (event-driven LLM lane; no StartInterval).
    allowlist='$USER_HOME $CLAUDE_HOME $CLAUDE_LOG_DIR $TIMEZONE $LABEL_PREFIX $WRITER_STAGING_ROOT'
    ;;
  *)
    diag "no render mapping for job '$job' (foundation launchd jobs: writer-reconciler, doc-amender)"
    exit 2
    ;;
esac
export USER_HOME CLAUDE_HOME CLAUDE_LOG_DIR TIMEZONE LABEL_PREFIX
export WRITER_STAGING_ROOT WRITER_RECONCILER_BACKSTOP_SEC

# --- pick target dir ---
if [ -n "$staging_dir" ]; then
  target_dir="$staging_dir"
else
  target_dir="$USER_HOME/Library/LaunchAgents"
fi

# --- render to ephemeral tmp + plutil-lint ---
tmp_dir="${TMPDIR:-/tmp}"
ephemeral_tmp="$tmp_dir/render-launchd.$job.$$.plist"
trap 'rm -f "$ephemeral_tmp"' EXIT

if ! render_template "$TEMPLATE" "$allowlist" > "$ephemeral_tmp" 2>/dev/null; then
  diag "template render failed on $TEMPLATE"
  exit 4
fi

if ! plutil -lint -s "$ephemeral_tmp" >/dev/null 2>&1; then
  diag "plutil -lint rejected rendered plist (template: $TEMPLATE)"
  plutil -lint "$ephemeral_tmp" >&2 || true
  exit 4
fi

# --- extract Label + sanity-check format ---
label=$(plutil -extract Label raw -o - "$ephemeral_tmp" 2>/dev/null)
if [ -z "$label" ]; then
  diag "could not extract Label from rendered plist"
  exit 5
fi
case "$label" in
  *[!A-Za-z0-9.-]*|[!A-Za-z]*|"")
    diag "rendered Label has invalid format: '$label' (must match ^[A-Za-z][A-Za-z0-9.-]*\$)"
    exit 5
    ;;
esac

# --- dry-run: emit rendered plist to stdout, no write, no bootstrap ---
if [ "$dry_run" -eq 1 ]; then
  cat "$ephemeral_tmp"
  info "dry-run: would write to $target_dir/$label.plist (label: $label)" >&2
  exit 0
fi

# --- real install: atomic mv into target dir ---
if ! mkdir -p "$target_dir" 2>/dev/null; then
  diag "cannot mkdir -p $target_dir"
  exit 4
fi

final_plist="$target_dir/$label.plist"
final_tmp="$final_plist.tmp.$$"
trap 'rm -f "$ephemeral_tmp" "$final_tmp"' EXIT

# Move ephemeral into target dir as .tmp first (cross-FS-safe), then rename
# atomically over final_plist (same-FS rename(2) is POSIX-atomic).
if ! mv -f "$ephemeral_tmp" "$final_tmp" 2>/dev/null; then
  diag "could not move ephemeral tmp into target dir: $tmp_dir -> $target_dir"
  exit 4
fi
if ! mv -f "$final_tmp" "$final_plist" 2>/dev/null; then
  diag "atomic mv failed: $final_tmp -> $final_plist"
  exit 4
fi
trap - EXIT

info "rendered $TEMPLATE -> $final_plist (label: $label)"

# --- staging mode: skip launchctl entirely (production-flow rule) ---
if [ -n "$staging_dir" ]; then
  info "staging mode: skipping launchctl bootout + bootstrap"
  exit 0
fi

# --- production mode: bootout (idempotent, swallow rc) + bootstrap (rc gate) ---
if ! command -v launchctl >/dev/null 2>&1; then
  diag "launchctl required for production mode but not found on PATH"
  exit 2
fi

uid=$(id -u)
domain="gui/$uid"

# Unconditional bootout — symmetric with uninstall.sh, simpler invariant.
# Real launchctl returns non-zero if the label is not loaded; swallow bootout
# rc by design; bootstrap rc is the failure gate. kickstart -k is INSUFFICIENT —
# it operates on the in-memory definition, not the on-disk plist.
launchctl bootout "$domain/$label" >/dev/null 2>&1 || true

if ! launchctl bootstrap "$domain" "$final_plist"; then
  diag "launchctl bootstrap $domain $final_plist returned non-zero"
  exit 6
fi

info "launchctl bootstrapped $label under $domain"
exit 0
