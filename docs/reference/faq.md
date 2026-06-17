# FAQ

> **Audience:** anyone weighing whether to install brain-stem, or running into a question while using it. Answers are short and link to the page that covers each topic in full. No prior background is assumed.

## Before installing

### What do I need first?
A Mac, [Claude Code](https://www.anthropic.com/claude-code) installed, and `git` to download the project. The installer itself hard-requires `jq` (plus a few standard macOS helpers — `python3`, `plutil`, `sqlite3`, `shasum`) and refuses to proceed if any of those are missing. → [Getting started → Before you begin](../getting-started/index.md#before-you-begin)

### Does it work on Windows or Linux?
No. brain-stem targets a single person's Mac. It is not built for other operating systems or shared servers.

### Do I need Obsidian?
No. Your vault is just a folder of plain-text files that any editor can open. [Obsidian](https://obsidian.md) is the intended, free way to browse it, but it is optional.

### Is it free? What's the license?
Yes — it is open source under Apache-2.0. → [LICENSE](https://github.com/peter-tiktinsky/brain-stem/blob/main/LICENSE)

## Installing safely

### Will installing overwrite my existing `~/.claude`?
Not silently, and not by accident. Running `bash install.sh` on its own writes **zero files** — it only prints a preview. Writing requires the explicit `--apply` flag. And if `~/.claude` already contains files brain-stem did not put there, the installer **stops and refuses** rather than clobber them; proceeding takes explicit acknowledgement flags *and* a backup directory it copies the old files into first. → [Installing into a folder that already has files](../getting-started/index.md#installing-into-a-folder-that-already-has-files)

### I edited a shipped file, then a new version came out. Will my edit be lost?
No. On an upgrade, each file you edited is updated to the new version with **your** copy preserved alongside it as `<file>.foundation-local`. Your change is never silently overwritten. → [Version migrations](../getting-started/migrations.md)

### Can I uninstall cleanly later?
Yes. `bash ~/.claude/uninstall.sh` backs everything up first, then removes only the untouched files it originally installed — anything you edited, and your vault, are left alone. → [Uninstalling](../getting-started/uninstall.md)

## Privacy and trust

### Does it phone home or send my data anywhere?
No. brain-stem's own code performs **no network egress** — no telemetry, no analytics, no "phone home." The only logs it writes are local files on your machine. → [Security → Scope of trust](https://github.com/peter-tiktinsky/brain-stem/blob/main/SECURITY.md#scope-of-trust)

### Is my vault sent to Anthropic to train models?
brain-stem transmits nothing. Separately, how your *conversations with the assistant* are handled is governed by Anthropic's own data policy for [Claude Code](https://www.anthropic.com/claude-code), which you can review and configure there — that is the same for any Claude Code user, with or without brain-stem.

### How do I report a security issue?
Privately, through GitHub's private vulnerability reporting. → [SECURITY.md](https://github.com/peter-tiktinsky/brain-stem/blob/main/SECURITY.md#reporting-a-vulnerability)

## Using it

### Do I have to use the plans and backlog features?
No. brain-stem is **advisory by default** — it teaches and reminds far more than it blocks. Plans is the one capability you adopt as a *methodology* if you run formal multi-step projects; everything else you simply receive. → [Why brain-stem](../getting-started/why-brain-stem.md)

### What's the difference between "memory" and the "context library"?
**Memory** is the small curated set of notes the assistant reads back at the *start of every session* — who you are, what matters. The **context library** is where framed reference material and per-project state live, pulled in *when a piece of work needs it*. One is always-on identity; the other is on-demand context. → [Context and memory](../architecture/context-and-memory.md)

### Is claude-mem required?
No. [claude-mem](https://github.com/thedotmack/claude-mem) is an optional plugin that auto-captures session observations; brain-stem works fully without it and only *recommends* it during onboarding. → [Memory management](../architecture/memory-management.md)

### Can I change the rules without forking the project?
Yes — that is the whole point of the **overlay**. You register new folders, file types, tags, or writers with `/govern register`, and your additions extend the shipped foundation without modifying it, so you keep your customizations across upgrades. → [Command reference](commands.md)

## Where else to look

- **[Getting started](../getting-started/index.md)** — install, upgrade, and the safety guards in full.
- **[Glossary](glossary.md)** — every term in one place.
- **[Command reference](commands.md)** — every command brain-stem adds.
