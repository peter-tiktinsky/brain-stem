# Security

brain-stem installs into the folder Claude Code reads from and gives an AI assistant write access to a folder of your notes. Both are consequential, so this document states plainly what brain-stem can touch, what it cannot, and how to report a problem. It assumes no prior background; every term is explained the first time it appears.

## Scope of trust

**brain-stem runs entirely on your own machine.** It is a set of shell scripts, JSON rule files, and markdown — no compiled binaries, no server component, no account. Its only background presence is two small launchd jobs (a writer-reconciler and a document-amender) that watch a local staging folder; out of the box neither touches anything beyond your machine — see the third item below. It makes **no automatic network calls**: nothing brain-stem does on its own initiative sends your files, your notes, or any usage data anywhere. There is no telemetry, no analytics, and no "phone home." The logs it writes are **local files** under the standard per-user state directory (`~/.local/state/brain-stem`); they never leave the machine.

The only network activity is something **you** explicitly start, and only ever to a destination **you** control:

- **`/librarian backup`** — a capability you run by hand, never automatically — commits your vault, `~/.claude`, and plans and `git push`es them to the git remote **you** configured. Your data goes to your own remote; never to the maintainer or any third party.
- **Onboarding** checks whether the GitHub CLI (`gh`) is installed and signed in; if it is, it makes read-only calls to **your own** GitHub account — to confirm your sign-in (`gh auth status`) and read your profile (`gh api user`) for pre-filling your name and email. These read your own account; they send nothing about your files or notes.
- **The document-amender job** is the one path by which brain-stem could ever call an AI model without a session open, and it does so only if **you** configure it to. The job is installed and loaded by default, but the shipped writer registry defines no writer for it to act on, so it composes nothing and makes no network call. Only if you add a writer fan-in entry with a prompt-guided amendment strategy and author its prompt asset does the job, when a packet for that writer lands, run the Claude Code command-line tool non-interactively (`claude -p`) to compose the amendment — that packet's content goes to the same Anthropic service, under the same account, that Claude Code itself already uses. The companion writer-reconciler job never calls a model.

What brain-stem reads and writes is bounded to a small set of locations:

| Location | What lives there | brain-stem's access |
|---|---|---|
| `~/.claude` (the install target, `CLAUDE_HOME`) | The foundation: hooks, skills, governance rules, your generated config | Written by the installer; read by hooks at runtime |
| Your **vault** (a folder of `.md` notes, path you choose at onboarding) | Your notes, plus notes the assistant writes for you | Read and written, governed at every write (see below) |
| `~/.local/state/brain-stem` | Disposable working state: run logs, session receipts, internal manifests | Written and read by the runtime |
| `~/.local/share/brain-stem` | Durable data the runtime keeps | Written and read by the runtime |
| `~/.claude-plans` | Your plan tree, if you use plans | Read; **the installer never writes to or removes your plans** |

Anything outside these is out of brain-stem's scope.

## The install and overwrite surface

Installation copies files into `~/.claude`. Two properties bound the risk:

- **Preview-first.** Running `bash install.sh` with no flags writes **zero files** — it prints an action plan naming every file it would create or replace, then exits. You only ever change your machine by re-running with the explicit `--apply` flag, which itself refuses to run unless you name the target directory (`CLAUDE_HOME`) yourself; it will not guess where to write.
- **No silent overwrites.** If `~/.claude` already contains files brain-stem did not put there, the installer **stops and refuses** rather than clobber them. Proceeding requires you to pass explicit acknowledgement flags *and* name a backup directory, into which the installer first copies anything it is about to replace. Files you have edited yourself are never discarded silently: each is updated to the new version with your copy preserved alongside it.

The installer records a **receipt** — a list of every file it laid down, each with a content fingerprint — at `~/.claude/governance/foundation-manifest.json`. That receipt is what lets the system detect later tampering and lets the bundled uninstaller (`uninstall.sh`) remove **only** the untouched files it originally installed, backing everything up first and leaving any file you edited in place.

## The vault-write blast radius

The assistant has write access to your vault, so a malformed or destructive write is the realistic failure mode — not network exfiltration. brain-stem narrows that blast radius structurally:

- **Every write is checked.** A write-time guard inspects each file the assistant saves into the vault and can allow, advise, or deny it against the foundation's rules. The posture is advisory by default — it warns far more often than it blocks — and reserves a hard block for writes that would corrupt the vault's structure.
- **Your edits win.** Survivorship is a design rule: when the assistant and you would collide on a file, your hand edits are preserved, never silently overwritten.
- **Destructive actions are gated.** Removing or overwriting is preview-first or asks for explicit confirmation; the system surfaces what it found before acting on it.

These reduce — they do not eliminate — the inherent risk of giving an assistant write access. Keep your vault under version control or a backup if its contents are valuable, exactly as you would any working directory an automated tool can write to.

## Optional third-party integrations

Onboarding can *recommend* a few optional external tools — for example the [claude-mem](https://github.com/thedotmack/claude-mem) memory plugin, the GitHub CLI (`gh`), or [Obsidian](https://obsidian.md) as a vault viewer. brain-stem never installs them and never sends them your files or notes; it only checks whether each is already present and records your choice. (The one exception, noted above: if `gh` is present and authenticated, onboarding makes read-only calls to your *own* GitHub account — to confirm sign-in and pre-fill your name and email.) If you opt in, each is a separate project with its **own** security and network posture, governed by that project — not by brain-stem. Review them on their own terms before enabling.

## Reporting a vulnerability

If you believe you have found a security issue, please report it **privately** through GitHub's private vulnerability reporting:

> **<https://github.com/peter-tiktinsky/brain-stem/security/advisories/new>**

Please do not open a public issue for a suspected vulnerability until it has been addressed. Include the version (or commit) you are on, what you observed, and the steps to reproduce. This is a single-maintainer personal project — there is no formal SLA — but security reports are taken seriously and acknowledged.

## Supported versions

Security fixes target the **latest released version**. Because the install is preview-first and reversible, the recommended response to any fix is to upgrade in place (`git pull`, preview, `--apply`), as described in [the install & upgrade guide](https://peter-tiktinsky.github.io/brain-stem-docs/installation.html).
