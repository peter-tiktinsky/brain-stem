---
name: onboard
description: Voice-optional Tier-2 onboarding. A short two-part interview captures identity + behavioral prose, then the slim producer chain writes user-manifest.json, your ~/.claude/CLAUDE.md, and a fresh Obsidian "brain" vault (tree + CLAUDE.md), and records soft-mandate external setup (claude-mem / GitHub). Runs in a few minutes.
disable-model-invocation: true
argument-hint: "[--resume] [--extraction-stub <path>] [--typed-only] [--skip-external-setup] [--dry-run] [--vault-root <path>] [--plans-home <path>] [--skills-dir <path>] [--force]"
---

# Onboarder (Tier-2)

The user-facing entry for `/onboard`. It captures the minimum the rest of the
system reads at runtime — identity, vault location, and a little behavioral
prose — and produces a working, oriented Obsidian-backed setup.

The orchestrator is `skills/onboarder/onboard.sh`. It chains the six slim
producers in `scripts/`; it does **not** run any personalization beyond the
minimum-viable Tier-2 flow (no archetype inference, no seed-content intake, no
infer-vault, no opt-out surfaces).

## What runs when you type `/onboard`

Two short interview steps, then four deterministic build steps:

| Step | Script | What happens |
|---|---|---|
| A | `scripts/section-a-slim.sh` | Confirm pre-filled discovery: name, email, timezone, brain-vault location. No recording. |
| B′ | `scripts/section-b-slim.sh` | Voice-optional (or `--typed-only`) free-form answer about who you are and how you work → a slim LLM extraction consolidates it into `identity.role` / `identity.organization` + three behavioral prose blocks. |
| 1 | `scripts/bootstrap-user-manifest.sh` | Deep-merge the A + B′ fragments, inject system fields, validate against `user-manifest-schema.json` (2.0.0), atomic-write `user-manifest.json`. |
| 2 | `scripts/author-claude-home.sh` | Render `$CLAUDE_HOME/CLAUDE.md` from the manifest (About-Me line + behavioral prose injected). |
| 3 | `scripts/build-brain-vault.sh` | Build a fresh "brain" vault: `vault-init/` tree (Vault Writers/), Plans/Skills symlinks, `<vault>/CLAUDE.md`. Prints the Obsidian-open confirm beat. |
| 4 | `scripts/external-setup-gate.sh` | Soft-mandate gate over claude-mem / GitHub: strong recommendation + honest rationale + frictionless skip. Records dispositions; never blocks. For claude-mem it also prints the recommended context settings — in `~/.claude-mem/settings.json` (or the plugin's Context Settings modal at `http://localhost:37777`) set `CLAUDE_MEM_CONTEXT_OBSERVATIONS=0`, `CLAUDE_MEM_CONTEXT_SESSION_COUNT=0` and every `CLAUDE_MEM_CONTEXT_SHOW_*` flag to `false` (`CLAUDE_MEM_CONTEXT_SHOW_LAST_SUMMARY`, `CLAUDE_MEM_CONTEXT_SHOW_LAST_MESSAGE`, `CLAUDE_MEM_CONTEXT_SHOW_READ_TOKENS`, `CLAUDE_MEM_CONTEXT_SHOW_WORK_TOKENS`, `CLAUDE_MEM_CONTEXT_SHOW_SAVINGS_AMOUNT`, `CLAUDE_MEM_CONTEXT_SHOW_SAVINGS_PERCENT`, `CLAUDE_MEM_CONTEXT_SHOW_TERMINAL_OUTPUT`), because hook output is capped at 10,000 characters and, once there is real history, the index the plugin injects at session start runs well past it, so the harness spills it to a `hook-*-additionalContext.txt` file and the model gets only a boilerplate preview; the trap is shrinking it to just under 10,000 characters, which stops the spill and delivers the whole payload in full — go to zero or leave the defaults. Capture (the plugin's PostToolUse / Stop / SessionEnd hooks) and brain-stem's own SessionEnd memory hook are untouched; recall stays available through the plugin's MCP search tools and its mem-search skill. |

## Invocation

| Command | Behavior |
|---|---|
| `/onboard` | Full Tier-2 chain. If `user-manifest.system.onboarding_complete == true`, no-op (exit 0); re-run with `--force` to re-onboard. Step B′ pauses at the LLM-extraction handoff (exit 5); the driver runs the extraction model on the staged prompt, then re-invokes with `--resume --extraction-stub <path>`. |
| `/onboard --extraction-stub <path>` | Supply the Step-B′ extraction output directly; the whole chain runs in one shot (used by harnesses / non-interactive flows). |
| `/onboard --typed-only` | Skip the voice probe; type the Step B′ answer. |
| `/onboard --skip-external-setup` | Skip Step 4 (the external-setup gate). |
| `/onboard --dry-run` | Walk the chain emitting per-step would-run handoffs; zero filesystem writes. |
| `/onboard --force` | Re-onboard past the `onboarding_complete` sentinel (idempotent chain re-runs). |
| `/onboard --vault-root <p>` / `--plans-home <p>` / `--skills-dir <p>` | Override the vault / plans / skills locations (forwarded to the brain-vault build). |

`disable-model-invocation: true` keeps `/onboard` discoverable but model-silent —
the model never auto-fires it; only the user types `/onboard`. `SessionStart`
surfaces a resume banner (via `hooks/session-start.sh`) whenever
`$CLAUDE_HOME/user-manifest.json` is missing or `.system.onboarding_complete` is
not `true`. There is **no** per-section `phases_completed[]` state — a Tier-2
manifest carries only the `onboarding_complete` boolean, and the chain is
idempotent, so a re-onboard re-runs from the top rather than jumping to a section.

## Two-pass Step B′ (extraction handoff)

Step B′ is the only LLM-in-the-loop step. Pass 1 captures the transcript via the
shipped typed rung (`scripts/fallback/typed-textarea.sh`; voice is a future
add-on) **or** the driver stages the transcript directly (see the driver-staging
contract below) — the script does **not** capture when both capture bins are
absent. It then renders the extraction prompt to
`$CLAUDE_HOME/onboarding/extraction-prompt-B-slim.txt` and exits 5. The
caller runs the extraction model on that prompt, writes the model's nested-JSON
output to a file, and re-invokes with `--resume --extraction-stub <that-file>`.
Pass 2 validates the extraction (top-level keys ∈ `{identity, behavioral,
notes}`), wraps it into `user-fragment-B.json`, and the chain continues.

### Driver-staging contract (no interactive capture available)

When no capture bin is executable (the GA clean-install state) and no transcript
is staged, Pass 1's `capture_transcript` returns **5** with an actionable
handoff rather than failing cryptically. To complete Step B′ a driver:

1. Stages the user's free-form Section-B answer as plain text at
   `$CLAUDE_HOME/onboarding/transcripts/section-b-slim.txt` (`$TRANSCRIPT_PATH`).
2. Either re-invokes `--resume` (the script renders the extraction prompt from
   the staged transcript, then exits 5 again for the model to extract), **or**
   runs the extraction model out-of-band and re-invokes one-shot with
   `--extraction-stub <model-output.json>` (capture and render are skipped; the
   stub alone drives Pass 2).

The driver-staging channel may also be fed in-process via the
`STDIN_TRANSCRIPT_OVERRIDE` env knob (its contents are written to
`$TRANSCRIPT_PATH` when no transcript is staged yet) — load-bearing only on the
non-stub path.

## Section-A identity injection (non-TTY driver seam)

Section A discovers identity by reading the host (global git → repo git →
`$GIT_AUTHOR_*` → `gh api user` → `id -F`, all read-only). Under a non-TTY
driver it auto-accepts discovery rather than consuming piped bytes as menu/field
input. A driver injects or overrides identity via the sanctioned **`SLIM_A_*`**
env seam — these win over every host probe:

| Env var | Sets |
|---|---|
| `SLIM_A_NAME` | identity name |
| `SLIM_A_EMAIL` | identity email |
| `SLIM_A_TZ` | timezone |
| `SLIM_A_VAULT` | brain-vault root (`none` defers the location to the build step) |

## Output Contract

### Files written

| Path | Schema type | Cardinality | Lifecycle |
|---|---|---|---|
| `$CLAUDE_HOME/user-manifest.json` | `user-manifest-schema.json` (Draft-07, 2.0.0) instance | Single | Atomic tmp+rename; `--force` overwrites a differing target. |
| `$CLAUDE_HOME/CLAUDE.md` | Rendered prose (not a schema instance) | Single | No-clobber without `--force`; staged `.new` + diff on conflict. |
| `<vault>/CLAUDE.md` | Rendered prose | Single | No-clobber without `--force` (preserve user edits). |
| `<vault>/` brain tree | `vault-init/` seed | Tree | `cp -n` idempotent overlay; never clobbers existing files. |
| `$CLAUDE_HOME/onboarding/external-setup-state.json` | `{ "<tool>": {status, ts} }` | Single | Atomic; idempotent re-run preserves prior dispositions. |
| `$CLAUDE_HOME/onboarding/user-fragment-{A,B}.json` | Section fragments | One each | Intermediate inputs to the manifest writer. |

### Pre-write validation

The manifest writer validates the merged instance against
`user-manifest-schema.json` (python3 `jsonschema` → `ajv` → `jq` structural
fallback). The two CLAUDE.md authors assert zero `{{[A-Z_]+}}` residue before
writing. The vault build refuses to scaffold into a non-empty **foreign**
directory without `--force`.

### Failure mode — block-and-log

Every producer is block-and-log: any merge / validate / render / IO failure
exits non-zero and the live target is never partially written (atomic
tmp+rename throughout). The external-setup gate is the sole soft path — it
never blocks the flow regardless of probe results.

## See also

- [`scripts/bootstrap-user-manifest.sh`](scripts/bootstrap-user-manifest.sh) — the slim Tier-2 manifest writer.
- [`hooks/session-start.sh`](../../hooks/session-start.sh) — the `onboarding_complete` resume-banner hook.
