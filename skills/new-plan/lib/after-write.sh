#!/bin/bash
# after-write.sh — the tool-event derivations a plan-manifest write would have fired,
# for the scaffolder commands that write a manifest from a script.
#
# Source it — never execute it:
#   source "<skill>/lib/after-write.sh"
#   plan_after_write <manifest-abs-path>
#
# WHY. A script writer bypasses every derivation that fires only on a tool event: the
# binder, situating card and tasks.md re-derive after a manifest write, and the manifest
# verify. plan_after_write runs those two hooks for the manifest it is given, so a
# command that writes a manifest leaves the derived surfaces in step with it:
#   - <claude-home>/hooks/post-manifest-binder-refresh.sh <manifest>
#   - <claude-home>/hooks/post-tool-use-manifest.sh, fed a PostToolUse payload on stdin
# The claude home is ${CLAUDE_HOME:-$HOME/.claude}: a sibling component is executed
# through the install root, never through the running file's own tree.
#
# THE PLANS ROOT. The caller sets the shell variable PLANS_ROOT to the resolved plans
# root; plan_after_write assigns and exports PLANS_ROOT and PLANS_DIR at that root for
# the two hooks, so an ambient value (another directory, or none) never reaches them.
# The hook output is discarded.
#
# FAIL OPEN. A missing hook prints a NOTE on stderr, and so does a hook that exits
# non-zero (naming its exit code). The function always returns 0: a derivation never
# fails the command that called it.
#
# Bash 3.2 clean (R-23). Data reaches python3 through argv, never a piped stdin.

plan_after_write() {
  local manifest="${1:-}" ch="${CLAUDE_HOME:-$HOME/.claude}" hook payload rc
  local root="${PLANS_ROOT:-${PLANS_DIR:-$HOME/.claude-plans}}"
  (
    set +e
    export PLANS_ROOT="$root"
    export PLANS_DIR="$root"
    hook="$ch/hooks/post-manifest-binder-refresh.sh"
    if [ -f "$hook" ]; then
      if bash "$hook" "$manifest" </dev/null >/dev/null 2>&1; then
        :
      else
        rc=$?
        printf 'NOTE: binder refresh exited %s (%s)\n' "$rc" "$hook" >&2
      fi
    else
      printf 'NOTE: binder refresh skipped (%s is missing)\n' "$hook" >&2
    fi
    hook="$ch/hooks/post-tool-use-manifest.sh"
    if [ -f "$hook" ]; then
      payload="$(python3 -c 'import json, sys; print(json.dumps({"tool_name": "Write", "tool_input": {"file_path": sys.argv[1]}}))' "$manifest")"
      if printf '%s\n' "$payload" | bash "$hook" >/dev/null 2>&1; then
        :
      else
        rc=$?
        printf 'NOTE: manifest-verify exited %s (%s)\n' "$rc" "$hook" >&2
      fi
    else
      printf 'NOTE: manifest-verify skipped (%s is missing)\n' "$hook" >&2
    fi
  )
  return 0
}
