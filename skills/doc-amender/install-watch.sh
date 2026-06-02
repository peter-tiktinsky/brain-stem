#!/usr/bin/env bash
# skills/doc-amender/install-watch.sh — launchd WatchPaths registration wrapper
# for doc-amender.
#
# The plist template ships at templates/launchd/doc-amender.plist.tmpl.
#
# Composes WATCH_PATHS_ROOT env (default $CLAUDE_STATE_ROOT/vault-staging — the
# single canonical ephemeral staging root; override via
# --staging-root) and invokes installer/render-launchd.sh to render the
# doc-amender plist + (production mode) launchctl-bootstrap the doc-amender
# launchd job. doc-amender fire mechanism = launchd WatchPaths (event-driven on
# packet-land; NOT cron interval) per the operator-locked 2026-05-19 decision.
#
# bash 3.2 compatible. Watch-path-only fire mechanism.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# Resolve render-launchd.sh + the template in the installed layout (under
# $CLAUDE_HOME) with a repo-root fallback for tests.
_IW_CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
if [ -r "$_IW_CLAUDE_HOME/installer/render-launchd.sh" ]; then
  RENDER_LAUNCHD="$_IW_CLAUDE_HOME/installer/render-launchd.sh"
  TEMPLATE_PATH="$_IW_CLAUDE_HOME/templates/launchd/doc-amender.plist.tmpl"
else
  REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
  RENDER_LAUNCHD="$REPO_ROOT/installer/render-launchd.sh"
  TEMPLATE_PATH="$REPO_ROOT/templates/launchd/doc-amender.plist.tmpl"
fi

DEFAULT_STAGING_ROOT="${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/vault-staging"

DRY_RUN=0
STAGING_DIR=""
STAGING_ROOT=""

usage() {
  cat <<EOF
install-watch.sh — doc-amender launchd WatchPaths registration.

Usage:
  install-watch.sh [--dry-run] [--staging-dir PATH] [--staging-root PATH]

Composes WATCH_PATHS_ROOT env (default $DEFAULT_STAGING_ROOT) and invokes
installer/render-launchd.sh to render the doc-amender plist + (production
mode) launchctl bootstrap. Watch-path-only fire mechanism (event-driven on
packet-land; no interval-based config).

Flags:
  --dry-run                Render plist to stdout; no write, no bootstrap.
                           Composable with --staging-dir.
  --staging-dir PATH       Stage rendered plist under PATH instead of
                           ~/Library/LaunchAgents/. Skips launchctl bootstrap.
                           Used by tests + onboarder pre-bootstrap flow.
  --staging-root PATH      Override default WatchPaths target. Default is
                           \$CLAUDE_STATE_ROOT/vault-staging.

Default behavior (no flags): production install. Composes WATCH_PATHS_ROOT,
renders plist via render-launchd.sh doc-amender, atomic-installs to
~/Library/LaunchAgents/<Label>.plist, launchctl bootstraps.

Env:
  WATCH_PATHS_ROOT         Exported for the plist template. If --staging-root
                           provided, overrides this. If neither set, defaults to
                           $DEFAULT_STAGING_ROOT.

Exit codes:
  0   success
  2   bad invocation / missing prereq / template missing
  4   render-launchd.sh propagated failure
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)              DRY_RUN=1; shift ;;
    --staging-dir)          STAGING_DIR="$2"; shift 2 ;;
    --staging-dir=*)        STAGING_DIR="${1#--staging-dir=}"; shift ;;
    --staging-root)         STAGING_ROOT="$2"; shift 2 ;;
    --staging-root=*)       STAGING_ROOT="${1#--staging-root=}"; shift ;;
    -h|--help)              usage; exit 0 ;;
    *) printf 'install-watch.sh: unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# --- resolve WATCH_PATHS_ROOT ------------------------------------------------
#
# Precedence: --staging-root argv > $STAGING_ROOT env > $WATCH_PATHS_ROOT env
# > built-in default ($CLAUDE_STATE_ROOT/vault-staging).

if [ -z "$STAGING_ROOT" ]; then
  STAGING_ROOT="${WATCH_PATHS_ROOT:-}"
fi
if [ -z "$STAGING_ROOT" ]; then
  STAGING_ROOT="$DEFAULT_STAGING_ROOT"
fi

# Defensive: warn (non-fatal) if STAGING_ROOT path does not yet exist. The plist
# will still install; launchd creates the WatchPaths watcher lazily on first
# stat success. We DO NOT mkdir here — bootstrapping is install-time scaffolding.
if [ ! -d "$STAGING_ROOT" ]; then
  printf 'install-watch.sh: WARN — staging root does not yet exist: %s\n' "$STAGING_ROOT" >&2
  printf 'install-watch.sh: WARN — plist will install but WatchPaths will be inert until staging root materializes\n' >&2
fi

export WATCH_PATHS_ROOT="$STAGING_ROOT"

# --- template + render-launchd presence checks -------------------------------

if [ ! -r "$TEMPLATE_PATH" ]; then
  printf 'install-watch.sh: doc-amender plist template not readable: %s\n' "$TEMPLATE_PATH" >&2
  exit 2
fi

if [ ! -x "$RENDER_LAUNCHD" ] && [ ! -r "$RENDER_LAUNCHD" ]; then
  printf 'install-watch.sh: render-launchd.sh missing at %s\n' "$RENDER_LAUNCHD" >&2
  exit 2
fi

# --- compose render-launchd args ---------------------------------------------

render_args=""
if [ "$DRY_RUN" = "1" ]; then
  render_args="$render_args --dry-run"
fi
if [ -n "$STAGING_DIR" ]; then
  render_args="$render_args --staging-dir $STAGING_DIR"
fi

printf 'install-watch.sh: invoking render-launchd.sh doc-amender (WATCH_PATHS_ROOT=%s)\n' "$WATCH_PATHS_ROOT" >&2
# shellcheck disable=SC2086
if ! bash "$RENDER_LAUNCHD" $render_args doc-amender; then
  rc=$?
  printf 'install-watch.sh: render-launchd.sh failed rc=%s\n' "$rc" >&2
  exit 4
fi

exit 0
