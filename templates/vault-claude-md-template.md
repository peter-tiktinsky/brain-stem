# CLAUDE.md — {{IDENTITY_NAME}}'s Obsidian Vault

<!-- This file gives Claude an at-a-glance view of the vault's folder
     structure. brain-stem seeded it at install (substituting identity fields
     from user-manifest.json) and will never overwrite it on re-run.

     All governance (frontmatter / tagging / naming / mandatory files /
     plans-tree discipline / vault-specific behaviors like historical-data-
     warning / propose-and-validate-on-new-folders / writer-references-in-Vault-Writers)
     is enforced by brain-stem hooks at write-time — this file does NOT carry
     rules.

     Hard cap 80 lines. Claude self-maintains the structure tree when
     user adds new top-level folders (via propose-and-validate flow). -->

## Vault Structure

<!-- Compact tree; foundation-shipped folders marked [F]. User-defined
     cluster names seeded from user-manifest.json at install time. -->

```
{{VAULT_ROOT}}/
├── CLAUDE.md                          [this file]
├── System Governance/           [F]  → narrative spokes for 6 governance pillars
├── Plans/                        [F]  → symlink to {{PLANS_HOME}}
├── Vault Writers/                [F]  → writer-references for vault-writing systems
├── Meetings/                     [F]  → date-prefixed meeting notes
├── Skills/                       [F]  → symlink to {{CLAUDE_HOME}}/skills/
├── {{VAULT_TOP_LEVEL_FOLDER}}/        → user-defined cluster (e.g., client work)
├── <USER_CLUSTER_2>/                  → user-defined
└── <USER_CLUSTER_N>/                  → user-defined; ask before adding new ones
```

## Vault-Specific Rules

<!-- Optional. brain-stem-foundational rules are hook-enforced; this section is
     for VAULT-SPECIFIC overrides or additions the adopter wants. Leave
     empty if you have no vault-specific behavioral preferences. -->

- <USER: 0-N vault-specific rules>
