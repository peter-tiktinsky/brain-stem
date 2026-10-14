---
title: {{TITLE}}
type: idea
status: new
created: {{DATE}}
updated: {{DATE}}
project: {{PROJECT}}
captured_session:
disposition:
tags: []
---

# {{TITLE}}

<!-- Pre-plan idea note. Cheap capture; the body below is the extended form and
     grows in place as the idea moves new → triaged → briefed. On graduation,
     /backlog-research (or promote-from-inbox.sh <slug>) migrates this body into the new
     plan's 00-ideation-brief.md and tombstones this note. Lives at
     ~/.claude-plans/_inbox/<slug>.md; rendered into _backlog.md by
     librarian:backlog-index. No NN- prefix — the prefix is assigned at
     graduation. status ∈ {new, triaged, briefed}; disposition ∈
     {FIX NOW, ABSORB, STANDALONE, NO-BUILD} (decided at capture; a captured
     note is never FIX NOW).
       release_class: local-release | public-release | post-release | docs   # STANDALONE only, stamped at capture
       size:          day | build       # STANDALONE only, stamped at capture

     captured_session: the id of the session that captured the note (stamped at
     capture; blank when the session id is unset). The session-close drain check
     blocks while a note it captured is undecided.

     distinct_from / distinct_scope: stamped at capture when the note resembles an
     open note and the capture says why it is separate: distinct_from names the open
     note(s) and distinct_scope is the one line stating what this note covers that they
     do not. A pair linked this way is not reported as a near-duplicate.

     project: the owning-spoke key (registry-resolved; stamped mechanically at
     capture). The disposition's TARGET and terminal RESOLUTION are recorded later
     as machine-joinable frontmatter, not authored empty at capture:
       promoted_to:  NN-<slug>                          # a graduated idea's landing plan
       absorbed_into: NN-<slug>[/SS-<subslug>][ :: T-N] # an ABSORB's owning plan/sub-plan/task
                     # (a suffixed target is a YAML double-quoted scalar — write it as
                     #  absorbed_into: "NN-<slug> :: T-N" — so the value survives a YAML re-read)
       resolution:   promoted | absorbed | resolved | dropped   # terminal; stamped by the
                     | superseded | discharged | parked  # backlog-index closure loop (targeted
       resolved_at:  YYYY-MM-DD                          # notes) or inbox-settle (operator
                                                         # judgment); the settlement event moves
                                                         # the note to _inbox/_settled/
       reopen_gate:  <gate id>                           # a NO-BUILD's re-open gate: an id in the
                                                         # plans pillar's inbox.reopen_gates
                                                         # (manual, or a registered command)
       reopened_at / reopened_from_gate                  # stamped when a met gate moves a parked
                                                         # NO-BUILD note back to the flat inbox
     A target key must resolve against the plan roster (an existing NN-<slug> or
     NN-<slug>/SS-<subslug> dir); an artifact pointer is not a valid target. -->

## Idea

(What is it? One or two sentences.)

## Why / rationale

(What problem or opportunity does it address? Why might it matter?)

## Notes

(Anything else — prior art, dependencies, open questions. Append freely as the idea matures.)
