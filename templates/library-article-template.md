---
type: reference
tags: ["#library/<topic>"]
updated: <YYYY-MM-DD>
routing: <activation-condition one-liner — "Read when ..."; the first source for index Description columns>
sources:
  - <_raw/source-original-1.md>
  - <_raw/source-original-2.md>
originating_plan: <plan-slug that promoted this article>
description: <one-line — what this article is; the index subtitle>
created: <YYYY-MM-DD>
id: <stable-slug — immutable readable id derived from <topic>/<article>>
schema_version: <cohort version — integer>
revalidation_interval_days: <optional — 45 for fast tool-docs, 270 for stable concepts; omit to take the 90-day fallback>
---

# <Concept Name>

<!--
SHAPE CONTRACT — governance/file-type-contracts/library-article.md.json (C-FTC-LIB-ART)
+ governance/frontmatter-rules.json#types.reference (the registered type).

This template is the SCAFFOLD the librarian instantiates at promotion — the live
article is written by skills/librarian/capabilities/library-scrub.sh, not by hand.

Frontmatter (type: reference, tier strict): REQUIRED type / tags / updated /
routing / sources / originating_plan / description / created / id / schema_version
(the last four are the universal typed cohort). OPTIONAL revalidation_interval_days
/ supersedes / depends_on / contradicts. size_limits is NOT a frontmatter field —
length is governed by C-FTC-LIB-ART and enforced by the librarian library-index scan
(over-threshold finding at the 400-line soft budget / 800 hard), never at write time.

Body shape (C-FM-ART):
  - H1 = the concept name (one concept per file). The single top-level heading.
  - A leading in-document section index is FORBIDDEN.
  - An in-doc table of contents is permitted ONLY above the ~400-line soft budget
    and is NEVER auto-generated.
  - The body is Claude-synthesized at promotion and scrubbed of all plan/project-
    specific detail (task IDs, plan slugs, engagement names, decision dates). It is
    regenerated content, not hand-maintained prose.
  - Per-article changelogs are killed — the single global _library/log.md is the
    change record.
  - Bare [[name]] sibling wikilinks at the FOOT of the body (backlink-graph value;
    basename uniqueness backs the bare form).
-->

<Claude-synthesized body. Universal knowledge, one concept, scrubbed of all
plan/project-specific detail. No leading section index.>

[[<sibling-article-one>]]
[[<sibling-article-two>]]
