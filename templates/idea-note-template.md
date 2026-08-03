---
title: {{TITLE}}
type: idea
status: new
created: {{DATE}}
updated: {{DATE}}
project: {{PROJECT}}
disposition:
tags: []
---

# {{TITLE}}

<!-- Pre-plan idea note. Cheap capture; the body below is the extended form and
     grows in place as the idea moves new → triaged → briefed. On graduation,
     /backlog-research (or /new-plan --promote) migrates this body into the new
     plan's 00-ideation-brief.md and tombstones this note. Lives at
     ~/.claude-plans/_inbox/<slug>.md; rendered into _backlog.md by
     librarian:backlog-index. No NN- prefix — the prefix is assigned at
     graduation. status ∈ {new, triaged, briefed}; disposition ∈
     {FIX NOW, ABSORB, STANDALONE, DEFERRED} (set during triage).

     project: the owning-spoke key (registry-resolved; stamped mechanically at
     capture). The disposition's TARGET and terminal RESOLUTION are recorded later
     as machine-joinable frontmatter, not authored empty at capture:
       promoted_to:  NN-<slug>                          # a graduated idea's landing plan
       absorbed_into: NN-<slug>[/SS-<subslug>][ :: T-N] # an ABSORB's owning plan/sub-plan/task
       resolution:   promoted | absorbed | resolved | dropped   # terminal; stamped by the
       resolved_at:  YYYY-MM-DD                          # backlog-index closure loop when the
                                                         # target plan reaches a terminal status
     A target key must resolve against the plan roster (an existing NN-<slug> or
     NN-<slug>/SS-<subslug> dir); an artifact pointer is not a valid target. -->

## Idea

(What is it? One or two sentences.)

## Why / rationale

(What problem or opportunity does it address? Why might it matter?)

## Notes

(Anything else — prior art, dependencies, open questions. Append freely as the idea matures.)
