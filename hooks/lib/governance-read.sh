#!/usr/bin/env bash
# usage: governance-read.sh <path> <jq-filter>
#
# rc 0, value on stdout  -- the key is present.
# rc 0, empty stdout     -- the key is absent (// empty semantics unchanged).
# rc 3, one stderr line  -- the source is unreadable or unparseable (jq's own
#                            rc distinguishes an absent path from a corrupt
#                            one; the caller keeps its own -f test for the
#                            allowed absent-file legs, so this rc 3 is only
#                            reached on a path the caller believed was there).
set -u

path="${1:-}"
filter="${2:-}"

if [[ -z "$path" || -z "$filter" ]]; then
  echo "governance-read: usage: governance-read.sh <path> <jq-filter>" >&2
  exit 2
fi

out=$(jq -c "$filter" "$path" 2>/dev/null)
rc=$?

if [[ "$rc" -ne 0 ]]; then
  echo "governance-read: ${path}: unreadable or unparseable (jq rc ${rc})" >&2
  exit 3
fi

printf '%s' "$out"
