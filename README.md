# brain-stem

A personalization layer for [Claude Code](https://www.anthropic.com/claude-code) — Anthropic's command-line agent that runs Claude in your terminal.

brain-stem helps Claude Code remember who you are and where your notes live. You answer interview questions once (typed or spoken). The system writes a single configuration file that describes your role, your folder of notes, and your preferences. Skills and runtime guards read that file at runtime, so your customizations don't have to be hand-edited per machine.

> macOS only. Single-user. Apache-2.0.

---

## Plain-language vocabulary

A few terms used throughout this README. If any are familiar, skim past.

- **Claude Code** — Anthropic's CLI for Claude. You type `claude` in a terminal; you get a chat with the model that can run shell commands, edit files, and call tools. It reads `~/.claude/` for configuration.
- **Vault** — your folder of markdown notes. The system uses [Obsidian](https://obsidian.md)'s vault concept: a directory of `.md` files. You don't need Obsidian itself; any editor works.
- **Manifest** — a single JSON file at `~/.claude/user-manifest.json` that holds your name, your vault path, your role, your preferences. Skills read from it at invocation to personalize behavior. Think "config, but generated for you, and structured."
- **Foundation pillars** — eight JSON files under `governance/` that describe what the system considers a valid vault state (frontmatter shape, tag taxonomy, naming, mandatory files, doc dependencies, file-type contracts, vault writers, plans). They ship composed into `governance/foundation-master.json` and are read by hooks at write time.
- **Overlay** — per-adopter customization at `~/.claude/governance/overlay-master.json` that extends the foundation pillars without modifying them.
- **Hook** — a shell command Claude Code runs at lifecycle events (before a write, on session start, etc). The system ships a default-on hook set that blocks dangerous writes and surfaces context.
- **Skill** — a slash command you type in Claude Code (e.g. `/onboard`, `/librarian`). Each is a directory under `~/.claude/skills/` with a `SKILL.md` body Claude reads at invocation.
- **Frontmatter** — the YAML block at the top of a markdown file (`---` to `---`) that carries structured metadata (`type`, `tags`, etc).

---

## Install

```bash
git clone https://github.com/peter-tiktinsky/brain-stem.git
cd brain-stem
bash install.sh
```

`install.sh` runs in dry-run mode first and prints the action plan it would apply (the install root is `CLAUDE_HOME`, default `$HOME/.claude`); re-run it with `--apply` to perform the install.

Then start a Claude Code session and run `/onboard` to generate your configuration.

## Documentation

Full documentation is published at <https://peter-tiktinsky.github.io/brain-stem/>.

## License

Apache-2.0. See [LICENSE](LICENSE).
