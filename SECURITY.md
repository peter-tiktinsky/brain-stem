# Security

brain-stem installs into the folder Claude Code reads from and gives an AI assistant write access to a folder of your notes. Both are consequential, so this document states plainly what brain-stem can touch, what it cannot, and how to report a problem. It assumes no prior background; every term is explained the first time it appears.

## Scope of trust

**brain-stem runs entirely on your own machine.** It is a set of shell scripts, JSON rule files, and markdown — no compiled binaries, no server component, no account. It does run background work, in three forms. It can add two small launchd jobs (a writer-reconciler and a document-amender). The installer does not create them: it prints the commands that render their definitions, either into `~/.claude/Library/LaunchAgents.staging`, where a session-start hook loads them, or straight into `~/Library/LaunchAgents`, which loads them at once. They watch a local staging folder, and the reconciler also wakes about once an hour. Short detached jobs also start at the beginning and end of a session (refreshing indexes, consolidating memory, recording that the session ended), and they stop when their work is done. And when you dispatch work with `orchestrator/dispatch.sh` with a delay, it waits in a background process, or, for a delay of four hours or more, writes a one-shot launchd job that fires later. An overnight request only adds the run to a local queue; this release ships nothing that runs that queue. Out of the box none of these sends anything beyond your machine — see the list below. brain-stem makes **no automatic network calls**: nothing it does on its own initiative sends your files, your notes, or any usage data anywhere. There is no telemetry, no analytics, and no "phone home." The logs it writes are **local files** under the standard per-user state directory (`~/.local/state/brain-stem`), except the install and uninstall records, which go under `~/.claude/logs`; none of them leave the machine.

The only network activity, and the only way an AI model is called, is something **you** start or switch on, and only ever to a destination **you** control or a service you already use:

- **`/librarian backup`** — a capability you run by hand, never automatically — commits your vault, `~/.claude`, and plans and `git push`es them to the git remote **you** configured. Your data goes to your own remote; never to the maintainer or any third party.
- **Onboarding** checks whether the GitHub CLI (`gh`) is installed and signed in; if it is, it makes read-only calls to **your own** GitHub account — to confirm your sign-in (`gh auth status`) and read your profile (`gh api user`) for pre-filling your name and email. These read your own account; they send nothing about your files or notes.
- **The document-amender job** is the one path by which brain-stem calls an AI model entirely on its own, with no session open and nothing you start at that moment, and it does so only if **you** configure it to. The job exists only after you run the render command the installer prints, and even then the shipped writer registry defines no writer for it to act on, so it composes nothing and makes no network call. Only if you add a writer fan-in entry with a prompt-guided amendment strategy and author its prompt asset does the job, when a packet for that writer lands, run the Claude Code command-line tool non-interactively (`claude -p`) to compose the amendment — that packet's content goes to the same Anthropic service, under the same account, that Claude Code itself already uses. The companion writer-reconciler job never calls a model.
- **Library promotion** is off until **you** switch it on, with `library-scrub.sh --mode set prompt` or `auto` (stored as `behavioral.hook_preferences.library_promotion` in your user manifest). While it is off, no hook scans your plans or calls a model; the session-start banner shows one notice, once. Once it is on, when a plan you complete has research attached, a Stop hook of your open session starts one detached Claude Code call (`claude --bare -p --model haiku`, bounded by a two-minute watchdog) that sends excerpts of that plan's research files to the same Anthropic service, under the same account, that Claude Code itself already uses, and records whether they hold reusable guidance. Nothing is copied into your library until you answer yes when asked, or unless you chose `auto`; a plan already complete when you switched it on is never offered.
- **The orchestrator** (`orchestrator/dispatch.sh`) runs Claude Code non-interactively (`claude -p`) on a plan or job that **you** dispatch, either immediately or after a delay you give it, which can fall after your session has ended. An overnight request only queues the run, and nothing in this release runs that queue. `dispatch.sh --cron <name>` runs one of the shipped job wrappers by name (the document-amender's or the writer-reconciler's), not a plan or a model prompt of yours. Each plan or job run uses `--permission-mode bypassPermissions`: Claude Code does not stop to ask before it edits files or runs commands in that run, and the run is given your home folder and your vault to work in. Nothing dispatches a job except a command you type (or a schedule you create with it), and `dispatch.sh --cancel <name>` removes a pending one. Dispatch only briefs you would be willing to let run unattended. If you set `ORCHESTRATOR_BRIEF_LINT=1`, `dispatch.sh --job` also sends the job's brief to a model for an advisory quality score before it runs; it is off by default.
- **Note descriptions** can be derived by a model, but only if **you** set `DERIVE_DESC_MODEL=1` in your environment. It is off by default and no shipped hook sets it; when it is on and a note has no usable heading, the first 80 lines of that note are sent to `claude -p --model haiku`, to the same Anthropic service, under the same account, that Claude Code itself already uses.

What brain-stem reads and writes is bounded to the locations below, plus the project folders you register with it:

| Location | What lives there | brain-stem's access |
|---|---|---|
| `~/.claude` (the install target, `CLAUDE_HOME`) | The foundation: hooks, skills, governance rules, your generated config | Written by the installer and the runtime; read by hooks at runtime. Install and uninstall records go to `~/.claude/logs` |
| Your **vault** (a folder of `.md` notes, path you choose at onboarding) | Your notes, plus notes the assistant writes for you | Read and written, governed at every write (see below) |
| `~/.local/state/brain-stem` | Disposable working state: run logs, session receipts, internal manifests | Written and read by the runtime |
| `~/.local/share/brain-stem` | Durable data the runtime keeps | Written and read by the runtime |
| `~/.claude-plans` | Your plan tree, if you use plans | Read, and written by the plan, inbox, backlog and session-close commands you run and by session-close hooks; **the installer never writes to or removes your plans** |
| `~/.claude/Library/LaunchAgents.staging` and `~/Library/LaunchAgents` | The launchd job definitions (`.plist` files) | The two standing jobs' definitions are written by the render commands the installer prints. The staging form writes them to `~/.claude/Library/LaunchAgents.staging`, and the session-start hook loads them from there (it writes no definition). The default form, printed as the fresh install's manual fallback and as the upgrade's re-render step, writes them to `~/Library/LaunchAgents` and loads them at once. `dispatch.sh` also places a one-shot job in `~/Library/LaunchAgents` when you ask for a delay of four hours or more (`dispatch.sh --cancel` removes it). The uninstaller unloads the two standing jobs (labels starting `com.brain-stem.`) |
| Project workspaces you create under `~/work`, and launch directories you register (`/govern register --kind project`) | Your own project folders | Created and registered by that command (the project's folder skeleton, its identity `CLAUDE.md` and its registry entry); read at runtime afterwards |
| The git remote you configure | Your own repository | Pushed to only when you run `/librarian backup` |

Anything outside these is out of brain-stem's scope.

## The install and overwrite surface

Installation copies files into `~/.claude`. Two properties bound the risk:

- **Preview-first.** Running `bash install.sh` with no flags writes **zero files** — it prints an action plan naming every file it would create or replace, then exits. You only ever change your machine by re-running with the explicit `--apply` flag, which itself refuses to run unless you name the target directory (`CLAUDE_HOME`) yourself; it will not guess where to write.
- **No silent overwrites.** If `~/.claude` already contains files brain-stem did not put there, the installer **stops and refuses** rather than clobber them. Proceeding requires you to pass explicit acknowledgement flags *and* name a backup directory, into which the installer first copies anything it is about to replace. Files you have edited yourself are never discarded silently: each is updated to the new version with your copy preserved alongside it as `<file>.foundation-local`. Two shipped files are the exception: `.gitignore` and `governance/overlay-master.json` hold your own additions, so the upgrade merges them, keeping your entries, and never stops on them.

The installer records a **receipt** — a list of every file it laid down, each with a content fingerprint — at `~/.claude/governance/foundation-manifest.json`. That receipt is what lets the system detect later tampering and lets the bundled uninstaller (`uninstall.sh`) remove the files it originally installed, backing everything up first. Inside the foundation folders, a file you edited is left in place. Two files at the top of `~/.claude` are the exception: `settings.json` and `settings.local.json` are removed whether or not you edited them (the installer merged into them, and `settings.local.json` holds your permissions). Your copies are in the pre-uninstall backup; restore them from there.

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
