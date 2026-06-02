{{provenance_frontmatter}}
title: {{candidate.label}}
type: prd
status: active
created: {{generated_at_date}}
audience: {{audience}}
tags:
{{tags_yaml_list}}
---

# {{candidate.label}}

> _PRD scaffolded from seeded content. Edit the body inline; the
> provenance frontmatter is preserved on regeneration unless
> `last_user_edit` is updated to a fresh ISO-8601 timestamp._

## Summary

{{candidate.metadata.summary}}

## Why this exists

{{candidate.metadata.rationale}}

## Scope

_Replace this block with explicit in-scope + out-of-scope lists. The
seeding pass cannot infer scope from the source items alone — that
requires your judgment._

**In scope:**
- _to fill_

**Out of scope:**
- _to fill_

## Success criteria

_Replace with measurable outcomes. The seeding pass surfaces what was
discussed in the source items but cannot translate "discussed" into
"shipped" — that's your call._

## Open questions

_Carry forward any unresolved questions from the seeded sources here.
The Context.md sibling carries the *resolved* background; this section
carries what's still decision-pending._

## Source items (provenance)

The following items in your seeded content map to this PRD:

{{source_items_bullet_list}}

_See `Context.md` for full source-item summaries. This list is the
provenance index; do not edit unless you are intentionally re-routing._
