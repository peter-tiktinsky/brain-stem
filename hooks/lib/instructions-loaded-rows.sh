#!/bin/bash
# hooks/lib/instructions-loaded-rows.sh — the one reader of the InstructionsLoaded log.
#
# Source it — do not execute it:
#   source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/instructions-loaded-rows.sh"
#   log="$(ilr_log_path)"
#   ilr_rows "$log" > "$rows_file"; rc=$?    # rc 3: no log at that path
#
# WHY ONE READER. The InstructionsLoaded hook (hooks/instructions-loaded-log.sh) writes the log, and two
# librarian capabilities read it: rules-hygiene.sh --check-load and context-budget-index.sh. A reader that
# resolves the log path and walks the rows on its own drifts from the writer; the writer also keeps one older
# generation once the log reaches its size bound, which a reader that opens only the live file never sees.
# This file owns the path chain and the row walk, so both readers and the writer agree.
#
# ilr_log_path    prints the path of the live log, resolved the way the hook resolves it:
#                   HOOKS_STATE_OVERRIDE, else HOOKS_STATE, else CLAUDE_STATE_ROOT/hooks-state, else
#                   XDG_STATE_HOME/brain-stem/hooks-state, else $HOME/.local/state/brain-stem/hooks-state,
#                 followed by /instructions-loaded.ndjson. The caller sources hooks/lib/paths.sh first, because
#                 that library derives HOOKS_STATE and CLAUDE_STATE_ROOT from the user manifest.
# ilr_rows <log>  prints every line of the log that parses as a JSON object, in file order and stripped of
#                 surrounding whitespace (blank, malformed and non-object lines are skipped). When <log>.1 is a
#                 regular file its object rows print first. It returns 3 and prints nothing when <log> is not a
#                 regular file (a <log>.1 beside it does not change that), and 0 otherwise.
#
# CONTRACT. Read-only: nothing here creates, writes or removes a file. python3 reads the path from argv.

ilr_log_path() {
  printf '%s\n' "${HOOKS_STATE_OVERRIDE:-${HOOKS_STATE:-${CLAUDE_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/brain-stem}/hooks-state}}/instructions-loaded.ndjson"
}

ilr_rows() {
  local log="${1-}"
  [ -n "$log" ] && [ -f "$log" ] || return 3
  # shellcheck disable=SC2016
  python3 - "$log" <<'PY'
import json
import os
import sys

log = sys.argv[1]
out = sys.stdout.buffer
for path in (log + ".1", log):
    if not os.path.isfile(path):
        continue
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        continue
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except Exception:
                continue
            if isinstance(row, dict):
                out.write(line.encode("utf-8") + b"\n")
PY
}
