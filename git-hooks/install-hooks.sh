#!/bin/bash
# install-hooks.sh — symlink git-hooks into target git repos
#
# Hook bodies live in foundation-repo work tree; this installer creates symlinks
# for foundation-repo .git/hooks/pre-commit + the cross-sub-plan invalidation
# post-commit.
#
# The .git/hooks/pre-commit slot symlinks pre-commit-harness-validated.sh
# DIRECTLY (the R-46-cousin flip-to-complete gate). Single .git/hooks/pre-commit
# slot per git's convention; the harness gate runs standalone (it passes
# through cleanly when no flip-to-complete manifest change is staged).
#
# Usage: install-hooks.sh [--foundation-only|--plans-only|--both] [--dry-run]
#
# Default --both installs in foundation-repo + plans-repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FOUNDATION_REPO="${FOUNDATION_REPO_OVERRIDE:-$HOME/Code/brain-stem}"
PLANS_REPO="${PLANS_ROOT_OVERRIDE:-$HOME/.claude-plans}"

DRY_RUN=0
TARGET="both"

while (( $# > 0 )); do
  case "$1" in
    --foundation-only) TARGET="foundation"; shift ;;
    --plans-only)      TARGET="plans"; shift ;;
    --both)            TARGET="both"; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 3 ;;
  esac
done

install_pre_commit() {
  local repo="$1"
  local hook_dir="$repo/.git/hooks"
  local target="$hook_dir/pre-commit"
  if [[ ! -d "$hook_dir" ]]; then
    echo "skip: $repo/.git/hooks does not exist (not a git repo or worktree)" >&2
    return 0
  fi

  if [[ -e "$target" && ! -L "$target" ]]; then
    echo "WARN: $target exists and is NOT a symlink. Refusing to overwrite. Move it manually first." >&2
    return 1
  fi

  if (( DRY_RUN == 1 )); then
    echo "[dry-run] ln -sf $SCRIPT_DIR/pre-commit-harness-validated.sh $target"
    return 0
  fi

  ln -sf "$SCRIPT_DIR/pre-commit-harness-validated.sh" "$target"
  echo "installed: $target -> $SCRIPT_DIR/pre-commit-harness-validated.sh"
}

install_post_commit() {
  local repo="$1"
  local hook_dir="$repo/.git/hooks"
  local target="$hook_dir/post-commit"
  if [[ ! -d "$hook_dir" ]]; then
    echo "skip: $repo/.git/hooks does not exist" >&2
    return 0
  fi
  if [[ -e "$target" && ! -L "$target" ]]; then
    echo "WARN: $target exists and is NOT a symlink. Refusing to overwrite." >&2
    return 1
  fi
  if (( DRY_RUN == 1 )); then
    echo "[dry-run] ln -sf $SCRIPT_DIR/post-commit-harness-invalidate.sh $target"
    return 0
  fi
  ln -sf "$SCRIPT_DIR/post-commit-harness-invalidate.sh" "$target"
  echo "installed: $target -> $SCRIPT_DIR/post-commit-harness-invalidate.sh"
}

case "$TARGET" in
  foundation|both)
    install_pre_commit "$FOUNDATION_REPO"
    install_post_commit "$FOUNDATION_REPO"
    ;;
esac
case "$TARGET" in
  plans|both)
    install_pre_commit "$PLANS_REPO"
    # Plans-repo doesn't need post-commit (it doesn't carry foundation source)
    ;;
esac
