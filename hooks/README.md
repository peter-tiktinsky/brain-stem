# hooks/

Claude Code hooks shipped by brain-stem. Default-on hooks are wired into `templates/settings.json`; one is a conditional fragment the installer merges based on a manifest opt-in flag; one is opt-in advanced.

## Sibling-resolution contract (ratified)

Two different resolution questions run through this tree, and they have two different
answers. The contract:

1. **Executing or delegating to a SIBLING COMPONENT — resolve via
   `${CLAUDE_HOME:-$HOME/.claude}`.** When a shipped component locates another shipped
   component to *run* it (a librarian capability, a reconciler, a cron wrapper's target,
   `spoke-resolve.sh`), the anchor is the live install root. Rationale: the live install is
   the execution root; resolving siblings off a file's own location would let a
   half-applied or copied-out tree silently mix component versions — one component from the
   copy, its collaborator from wherever the copy happens to sit. A half-applied install
   must never mix versions.
2. **Sourcing a LIB into a hook's own process — self-anchor via `$SCRIPT_DIR` is the
   portability lock.** What a file loads *into itself* (`hooks/lib/*.sh`) resolves
   relative to the file, so a hook keeps working from whatever tree it was loaded from.
   `post-tool-use-manifest.sh`'s dual form (self-anchor first, `CLAUDE_HOME` fallback) is
   sanctioned lib-sourcing under this clause.

The two clauses compose: `hooks/lib/detached-spawn-env.sh` pins `CLAUDE_HOME` at the
detached-spawn boundary to the tree the spawning hook was loaded from, which keeps clause 1
pointing at the right install even across launchd/cron re-entry. The write-target
coherence guard (a capability whose resolved write target and resolved registry disagree
about which tree they belong to must refuse loudly) is the enforcement arm of clause 1.

## What hooks are

Claude Code is a CLI harness wrapping a Claude model. Hooks are user-supplied shell commands the harness invokes at specific lifecycle events. Each hook receives a JSON event payload on stdin and may emit JSON on stdout to feed context back into the conversation, allow or deny a tool call, or block a stop.

The events this hook set wires:

- **PreToolUse** — fires before a tool runs. Returns allow/deny.
- **PostToolUse** — fires after a tool finishes.
- **UserPromptSubmit** — fires every time the user submits a prompt.
- **SessionStart** — fires once per session boot. The `source` field distinguishes startup / resume / compact.
- **Stop** — fires when the model would otherwise stop. Exit code 2 forces continuation.
- **PreCompact** — fires immediately before context compaction. Last chance to snapshot.
- **SessionEnd** — fires when the session terminates. Cleanup only; output is ignored.
- **statusLine** — runs continuously to render the bottom-of-terminal status line.

## Default-on

Always installed. Wired into `templates/settings.json`.

| Event | Hook | Purpose |
|---|---|---|
| PreToolUse[Edit\|Write] | `pre-write-guard.sh` | Write-time policy gate. See [`pre-write-guard.sh`](pre-write-guard.sh). |
| PreToolUse[AskUserQuestion] | `pre-asq-guard.sh` | Decision-Quality + Hard-Constraints composer. |
| PostToolUse[Edit\|Write] | `track-vault-write.sh` | Multi-session registry update on vault writes. |
| PostToolUse[Edit\|Write] | `post-write-verify.sh` | Frontmatter schema validation + post-write advisories. |
| PostToolUse[Edit\|Write] | `memory-auto-stamp.sh` | Auto-stamp `updated` + `last_validated` on memory writes. |
| PostToolUse[Edit\|Write] | `memory-globalize-auto.sh` | Fully-auto `scope: global` memory → `~/.claude/rules/` promotion. No-op unless `MEMORY_GLOBALIZE_MODE` = `auto` (default `propose` = no silent writes). |
| UserPromptSubmit | `prompt-context.sh` | Context-pressure mandates (R-26) + multi-session overlap + memory-review re-firing band. |
| SessionStart | `session-register.sh` | Multi-session coordination registry entry. |
| SessionStart | `cron-health-banner.sh` | 24-hour-cached cron-health summary. |
| SessionStart | `memory-seed.sh` | Lazy `MEMORY.md` seed. |
| SessionStart | `memory-review-banner.sh` | Memory-review pending-count banner (`/librarian review`). |
| Stop | `stop-checkpoint-check.sh` | Block stop on stale checkpoint at high context-pressure (R-26). |
| PreCompact[auto\|manual] | `pre-compact-checkpoint.sh` | Pre-compact session-state snapshot. |
| SessionEnd | `session-deregister.sh` | Multi-session coordination cleanup. |
| statusLine | `worker-statusline.sh` | Statusline rendering. |

Plus supporting scripts spawned conditionally: `memory-consolidation-check.sh` + `memory-consolidation-run.sh` (the first-party memory-consolidation hygiene pass), `auto-commit-surfaces.sh`, `reconcile-sessions.sh`, `tasks-md-autosync.sh`.

## Conditional fragments (1)

Off by default. The installer reads `manifest.behavioral.hook_preferences` and merges the matching fragment from `templates/settings-fragments/` only if you opted in. One fragment ships:

| Fragment | Manifest flag | When you'd enable it |
|---|---|---|
| `multi-session.json` | `hooks.multi_session.enabled` | You expect concurrent Claude Code sessions on the same vault. |

The first-party **memory-consolidation** hook is now **default-on** — `memory-consolidation-check.sh` is wired into the default `templates/settings.json` SessionEnd, so it needs no fragment. (This is NOT claude-mem; claude-mem is an optional adopter-installed plugin that self-wires via its own marketplace hooks.) `tasks-md-autosync.sh` is likewise default-wired into `templates/settings.json`. Neither ships a settings fragment.

The installer never strips entries from the default `templates/settings.json`; fragments are additive only. To turn off a default-on hook, edit your own `~/.claude/settings.json` post-install.

## Opt-in advanced (1)

`session-start-canary.sh` is **not** wired into the default `templates/settings.json`. It's a tripwire pattern: detect unexpected resurrection of a path you're trying to keep dead (e.g., a deprecated plans directory after a rename). Useful only when you have a known dead path to monitor; never useful on a greenfield install. Add it to your SessionStart array manually if you need it; declare the path via `manifest.paths.tripwire_paths[]`.

## State and config

- `$CLAUDE_STATE_ROOT/hooks-state/` — the runtime-state home (`hook-audit.log`, `tripwire.log`, the review queue, etc.), resolved via `lib/paths.sh` on the XDG ephemeral state tier (NOT `$CLAUDE_HOME`). The legacy `$CLAUDE_HOME/hooks/state/` dir is retired — no longer created on install (migration 0008 removes it if empty), kept only as a read-only migration/back-compat fallback for upgraders whose dir may still hold unmigrated files.
- `hooks/drift-allowlist.json` — hand-editable `provides:` overlap allowlist (`provides_overlap[]` for deliberate co-canonical pairs); read by the librarian frontmatter-coverage-audit. Created lazily; optional.

Documentation-cascade dependencies are no longer a hand-edited `hooks/config/` file — they live in `governance/doc-dependencies.json`, composed into `foundation-master.json#doc_dependencies` and read from that bundle by `pre-write-guard.sh`.

## Manifest-driven posture

Every hook reads identity / paths / preferences from `~/.claude/user-manifest.json` via `lib/paths.sh`, with env-var overrides for testing. Resolution order is env → manifest field → install-convention default. Each hook exits 0 on missing manifest (graceful degrade), so the system never blocks on a missing or malformed config.

Hook portability: hooks resolve `$CLAUDE_HOME` via `lib/paths.sh` (or `$SCRIPT_DIR`-relative lib sourcing) — there is no hardcoded `$HOME/.claude` install-path literal in a hook body. The install-verify gate fails on any such residue in `hooks/`.

## See also

- [`pre-write-guard.sh`](pre-write-guard.sh) — its header comment enumerates the rules the write-time gate implements, and where the ones implemented elsewhere live.
- [`lib/paths.sh`](lib/paths.sh) — the path-resolution helper every hook sources.
