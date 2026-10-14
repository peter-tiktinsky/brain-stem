#!/bin/bash
# hooks/lib/handoff-recognizer.sh — the one session-heading recognizer for plan handoffs.
#
# A plan's handoff.md is an append-only, newest-first record: one entry per session,
# each opened by an H2 session heading. Every tool that splits a handoff into entries
# reads the same heading grammar, the one governance/file-type-contracts/
# handoff.md.json :: section_schema enumerates. This lib is that grammar's single
# home. Each consumer sources it and compiles or greps these values; none of them
# carries a pattern literal of its own.
#
# Sourceable; sets variables only, exports them, and sets no shell options. Bash 3.2
# clean. The Python consumers read the patterns from the environment
# (os.environ[...]), so the values ride the environment, never a piped stdin.
#
# PYTHON FLAVOUR (re module; each consumer keeps its own compile flags):
#   HANDOFF_SESSION_HEADING_PY  a session heading: "## Session <N>", "## Session S<N>",
#                               "## Session: <x>", "## Alignment Session <N>", a bare
#                               "## S<N>" or a date-prefixed "## <YYYY-MM-DD>", at H2
#                               to H4, anchored at the heading-text start (compiled
#                               with re.IGNORECASE).
#   HANDOFF_SESSION_NUM_PY      the session ordinal inside a heading's text; it takes
#                               S-prefixed and colon forms and never reads a
#                               YYYY-MM-DD date as the ordinal (re.IGNORECASE).
#   HANDOFF_DATE_PY             the YYYY-MM-DD date inside a heading's text (no flags).
#   HANDOFF_ENTRY_HEADER_PY     the one-line identity header a stamped entry carries
#                               directly under its heading:
#                                 <!-- session: {"plan":"<NNN>","n":<N>,"at":"<ISO>","kind":"<token>"} -->
#                               The chronicle writers drop matching lines from an
#                               entry's body before they harvest its summary.
#
# ERE FLAVOUR (grep -iE):
#   HANDOFF_SESSION_HEADING_ERE the H2 session-heading shape the write-time deny
#                               in hooks/pre-write-guard.sh accepts, and the entry
#                               boundary hooks/lib/launch-prompt-length.sh splits on.
#
# RESOLUTION: consumers look for this file under ${CLAUDE_HOME:-$HOME/.claude}/hooks/lib
# first, then in the repo's hooks/lib, the same order they use for paths.sh. When it
# is unreadable, the arm fails open with a stderr note, and each capability
# exits 2 naming this file.

HANDOFF_SESSION_HEADING_PY='^(#{2,4})\s+((?:alignment\s+)?session\s*(?::|s?[0-9])|s[0-9]+\b|[0-9]{4}-[0-9]{2}-[0-9]{2}\b).*$'
HANDOFF_SESSION_NUM_PY='(?:\bsession\s*:?\s*|^)S?([0-9]+)(?![0-9])(?!-[0-9]{2}-[0-9]{2})'
HANDOFF_DATE_PY='([0-9]{4}-[0-9]{2}-[0-9]{2})'
HANDOFF_ENTRY_HEADER_PY='^\s*<!--\s*session:\s*\{.*\}\s*-->\s*$'
HANDOFF_SESSION_HEADING_ERE='^##[[:space:]]+((Alignment[[:space:]]+)?Session[[:space:]]*(:|S?[0-9])|S[0-9]|[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])'

export HANDOFF_SESSION_HEADING_PY HANDOFF_SESSION_NUM_PY HANDOFF_DATE_PY \
  HANDOFF_ENTRY_HEADER_PY HANDOFF_SESSION_HEADING_ERE
