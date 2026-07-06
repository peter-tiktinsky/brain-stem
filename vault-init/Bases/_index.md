---
type: index
description: "Starter Obsidian Bases views — native, no-plugin navigation driven by the typed frontmatter cohort."
created: 2026-07-02
updated: 2026-07-02
tags: ["#scope/reference"]
id: index-bases
schema_version: 1
---

# Bases

Starter Obsidian Bases (`.base`) views that turn the universal typed frontmatter cohort into native, no-plugin navigation. Bases reads frontmatter only, so these views light up the moment your notes carry `type` / `status` / `updated` / `description`. Open a `.base` file in Obsidian 1.9.10+ (Bases core plugin) to render it, then duplicate and adapt for your own dimensions.

## Contents

<!-- contents-enum:start -->
| Base | Keys on | View |
|------|---------|------|
| `all-durable-by-type.base` | type / updated / description | table, grouped by type, newest-first |
| `status-board.base` | status / type / updated | cards, grouped by status (the kanban surface) |
| `recent-with-summaries.base` | description / updated | cards, description as the subtitle |
<!-- contents-enum:end -->
