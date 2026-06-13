---
type: index
parent_folder: <library>
tags: ["#library/<topic>"]
updated: <YYYY-MM-DD>
---

# <topic>

*[Folder context paragraph: 2-4 sentences describing what lives here, what doesn't, why the folder exists. Pedagogical.]*

<!--
SHAPE CONTRACT — governance/file-type-contracts/_index.md.json (C-IDX, type: index).

This template is the SCAFFOLD the librarian instantiates — the live topic _index.md
is written by skills/librarian/capabilities/library-index.sh, not by hand. The same
contract governs the library-root _index.md.

Frontmatter (type: index): REQUIRED type (const index) / tags (non-empty, item
pattern ^#<dim>/<value>$) / updated (ISO date). CONDITIONAL parent_folder
(REQUIRED at path depth >= 2; auto-populated from the dirname relative to the
vault root). OPTIONAL description / provides.

Body (C-IDX body_structure):
  - H1 matches the folder name (case-insensitive substring of the parent basename).
  - A REQUIRED 2-4-sentence folder-context paragraph between the H1 and the table.
    Bootstrap emits the placeholder above for adopter fill-in; on re-derive the
    librarian survivorship-preserves hand-authored prose OUTSIDE the sentinel
    markers (incl. this paragraph) and NEVER overwrites it.
  - The generated table lives INSIDE the sentinel region below. Only content
    between the markers is regenerated; prose outside is preserved.
  - Columns in order: | File | Lines | Type | Description |.
      File        — Obsidian wikilink, .md-suffixed form [[<article>.md]] matching
                    the shipped _index.md.json File-column value_pattern
                    ^\[\[[^\[\]]+\.md\]\]$ (C-IDX binding reconciliation). The
                    library-index generator emits this form; basename uniqueness
                    backs the cross-ref.
      Lines       — wc -l, ^~?[0-9]+$ (leading ~ when approximated).
      Type        — frontmatter type: value (frontmatter-rules.json#types key).
      Description — prose one-liner <=200 chars; routing: first, then description:
                    / H1 / first non-frontmatter paragraph.
  - Light-content fallback: when the folder carries fewer than 3 child .md files of
    distinct types, a prose "Current Contents" section REPLACES the table.
-->

<!-- contents-enum:start -->
| File | Lines | Type | Description |
|---|---|---|---|
| [[<article>.md]] | <~lines> | reference | <routing one-liner / description / H1> |
<!-- contents-enum:end -->
