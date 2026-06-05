# hooks/

Claude Code hooks shipped by brain-stem. Default-on hooks are wired into `templates/settings.json`; four are conditional fragments the installer merges based on manifest opt-in flags; one is opt-in advanced.

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
| PreToolUse[Edit\|Write] | `pre-write-guard.sh` | Write-time policy gate. See [RULES.md](RULES.md). |
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
| Stop | `stop-drift-scan.sh` | Touched-file drift advisory at session end (R-36). |
| PreCompact[auto\|manual] | `pre-compact-checkpoint.sh` | Pre-compact session-state snapshot. |
| SessionEnd | `session-deregister.sh` | Multi-session coordination cleanup. |
| statusLine | `worker-statusline.sh` | Statusline rendering. |

Plus supporting scripts spawned conditionally: `memory-consolidation-check.sh` + `memory-consolidation-run.sh` (the first-party memory-consolidation hygiene pass), `auto-commit-surfaces.sh`, `reconcile-sessions.sh`, `tasks-md-autosync.sh`.

## Conditional fragments (4)

Off by default. The installer reads `manifest.behavioral.hook_preferences` and merges the matching fragment from `templates/settings-fragments/` only if you opted in.

| Fragment | Manifest flag | When you'd enable it |
|---|---|---|
| `memory-consolidation.json` | `hooks.memory_consolidation.enabled` | You want the **first-party memory-consolidation hook** — brain-stem's own non-LLM hygiene consolidation at SessionEnd. (This is NOT claude-mem; claude-mem is an optional adopter-installed plugin that self-wires via its own marketplace hooks.) |
| `auto-commit.json` | `hooks.auto_commit.enabled` | Your `~/.claude/` and/or vault are git repos. |
| `tasks-md-autosync.json` | `hooks.tasks_autosync.enabled` | You use the plan workflow with `tasks.md` task-status markers. |
| `multi-session.json` | `hooks.multi_session.enabled` | You expect concurrent Claude Code sessions on the same vault. |

The installer never strips entries from the default `templates/settings.json`; fragments are additive only. To turn off a default-on hook, edit your own `~/.claude/settings.json` post-install.

## Opt-in advanced (1)

`session-start-canary.sh` is **not** wired into the default `templates/settings.json`. It's a tripwire pattern: detect unexpected resurrection of a path you're trying to keep dead (e.g., a deprecated plans directory after a rename). Useful only when you have a known dead path to monitor; never useful on a greenfield install. Add it to your SessionStart array manually if you need it; declare the path via `manifest.paths.tripwire_paths[]`.

## State and config

- `hooks/state/` — runtime state (`hook-audit.log`, `tripwire.log`, the review queue, etc.). Created lazily; ships empty.
- `hooks/config/` — hand-editable allowlists:
  - `doc-dependencies.json` — registered documentation cascade primaries and mirrors. Read by `pre-write-guard.sh`.
  - `drift-allowlist.json` — `provides:` overlap exemptions used by the librarian.

## Manifest-driven posture

Every hook reads identity / paths / preferences from `~/.claude/user-manifest.json` via `lib/paths.sh`, with env-var overrides for testing. Resolution order is env → manifest field → install-convention default. Each hook exits 0 on missing manifest (graceful degrade), so the system never blocks on a missing or malformed config.

Hook portability: hooks resolve `$CLAUDE_HOME` via `lib/paths.sh` (or `$SCRIPT_DIR`-relative lib sourcing) — there is no hardcoded `$HOME/.claude` install-path literal in a hook body. The install-verify gate fails on any such residue in `hooks/`.

## See also

- [`RULES.md`](RULES.md) — the active rules `pre-write-guard.sh` enforces, in plain English.
- [`lib/paths.sh`](lib/paths.sh) — the path-resolution helper every hook sources.
