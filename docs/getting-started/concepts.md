# Core concepts

> **Audience:** anyone who wants the mental model behind brain-stem before — or just after — installing it. Written for someone who has never used Claude Code and has no technical background; every term is explained the first time it appears. This page is a map: it builds each idea in plain language and points you to the full architecture page for the depth.

brain-stem adds six things to Claude Code: a **vault**, a **governance engine**, **memory**, a **context library**, **plans**, and **session** machinery. They fit together simply — the vault is the place, governance keeps the place trustworthy, memory lets the assistant carry knowledge across visits, the context library frames the work with reusable reference and per-project state, plans organize big projects, and the session machinery keeps any single conversation on-track. This page walks them in that order, then names the handful of design principles that run through all of them.

A quick word that recurs below: a **hook** is a small script the Claude Code program runs *automatically* at a set moment — when a session starts, just before a file is saved, when a session ends. You never run a hook yourself; the program fires it for you. Hooks are how brain-stem stays automatic instead of relying on anyone to remember the chores.

---

## 1. The vault — a shared, plain-text notebook

A **vault** is a folder of plain-text notes that *both* you and the assistant write into. You type and edit notes by hand; the assistant creates and updates notes on its own. There is no database and no locked-away format — every note is an ordinary text file you can open in any editor.

The vault is organized into a few standard folders from day one (a reference area explaining the system's own rules, a catalog of automated writers, and a meetings folder), and each folder carries a small **index note** so it is never an unlabeled pile. Because two different authors share one folder, the vault is exactly where things would drift if nothing watched it — which is what the next concept is for.

→ Full detail: **[Vault governance](../architecture/vault-governance.md)**.

---

## 2. The governance engine — a doorman at every write

Because the assistant can write files, something has to decide whether each write is a good idea. That something is the **governance engine**: a rulebook consulted *every single time* a file is about to be created or edited, which returns one of three answers.

The simplest picture is a **doorman standing at the moment of every write**:

- **"Go ahead."** — the write proceeds, nothing is said. (*allow*)
- **"Go ahead, but you forgot something."** — the write proceeds *with* a plain-English reminder attached. (*advise*)
- **"Stop, fix this first."** — the write is blocked and the reason is returned. (*deny*)

The load-bearing idea is that **advise is the workhorse.** Most policy is *taught*, not enforced by blocking — because blocking someone from saving their work over a missing tag would be hostile and would only train people to switch the guard off. The engine reserves hard denial for the few cases where letting the write through would quietly corrupt the structure, such as a note declaring a document type that does not exist.

What the doorman reads is a single **rulebook bundle** that ships with the system, combined with an **overlay** — your own additions, laid on top like a transparent sheet over a master copy. Wherever your sheet has writing, the assistant reads your sheet; everywhere else it reads the shipped master straight through. This lets you extend the system without ever editing the shipped rules, so you can take a future update without losing your customizations. You never hand-edit the overlay; you add to it through a guided command (`/govern register`) that drafts each setting and lets you accept or correct it before it is written.

→ Full detail: **[The governance engine](../architecture/governance-engine.md)**.

---

## 3. Memory — a filing cabinet that stays full between meetings

By default the assistant forgets everything when a session ends. **Memory** is the fix: a small set of plain-text notes kept *on disk*, so they survive the session ending, and read back automatically at the start of the next one. Two analogies carry the whole idea:

- Memory is a **filing cabinet** that stays full between meetings.
- The assistant's live, in-session attention is a **whiteboard** that gets wiped clean at the end of each meeting.

The point of memory is to move what matters off the whiteboard and into the cabinet before it is erased. Memory is deliberately **small and curated**, because a store that keeps *everything* fills with noise and the few facts that matter get drowned. It is split three ways, by the kind of knowledge each holds:

| Kind | What it holds | Example |
|---|---|---|
| **Semantic** | Timeless facts, preferences, and identity | "The user prefers terse, direct answers." |
| **Procedural** | How-to knowledge *plus the reasoning behind it*, including lessons from past mistakes | "Always run the tests after writing code — a silent failure once shipped a broken file." |
| **Episodic** | Dated records of what happened in one specific work session | "On a given day, fixed the seed hook; a marker file was missing." |

Memory also comes in two **scopes**: *project* memory (notes for one job, loaded when you work on that job) and *global* memory (standing preferences that apply to everything you do, loaded every session). Your personal-preferences file — the global `CLAUDE.md` onboarding wrote — is authored once and is **yours alone to hand-edit**; no automated process is ever allowed to write to it.

→ Full detail: **[The memory model](../architecture/memory-model.md)**, with the size-limit mechanics in **[Memory management](../architecture/memory-management.md)**.

---

## 4. The context library — reference and project state

Memory (above) is mostly about *how the assistant should behave* — your preferences, conventions, and the lessons behind them. But the assistant also needs **context**: the durable material that *frames the work itself*. That lives in the **context library**, in two scopes that mirror memory's own:

- a **universal Library** — durable reference articles, written once and reusable by *any* project (you see it in your vault as a `Wiki/` folder);
- a **project binder** — a per-project roll-up of that project's plans: their research, decisions, and a handoff journal, so a project's state is never lost (a `Projects/` folder).

A third area, the **workshop**, is a scratch bench where research happens before it is cleaned up and *promoted* onto the Library shelf. The single distinction that runs through both memory and context — *governing how the assistant acts* versus *framing what the work is* — is the model this whole pair turns on.

→ Full detail: **[Context and memory](../architecture/context-and-memory.md)** (the model) and **[The context library](../architecture/context-library.md)** (the surfaces).

---

## 5. Plans — from a raw idea to a signed-off project

A **plan** is a small folder of plain-text files describing one project: its goal, its task list, and a running diary of progress. Plans live in their own area on disk (separate from your notes vault, though your vault links to it), one folder per project.

Three ideas make plans worth understanding:

- **The control file is the truth.** A plan's status and task list live in a machine-readable control file; the human-readable to-do list is a *generated copy* of it. You mark a task done by changing the control file, and the system re-prints the to-do list to match. Done is recorded where the truth lives, not penciled onto the printout.
- **"Done" is a claim; "verified" is earned.** A plan moves through a fixed sequence of stages. A person can *claim* a plan is complete, but the `verified` stage is stamped only by an actual automated check — never typed in by hand — and a plan cannot be signed off until it is verified. Done is not something you get to declare.
- **Capture is cheap; the system sorts.** You can ask the assistant to jot any idea down, and it drops a lightweight note into a holding area without burning a project number. Numbers are handed out only when an idea graduates into a real plan, so the dozens of ideas you discard never cost anything.

There is also an **orchestrator** — machinery that can run a plan's tasks for you automatically. Its single most important property: it is **human-gated**. It proposes each step and waits for your go-ahead on anything risky; it is not an unattended robot. The framing to keep is the difference between a robot that does the dishes only after you nod, and one that empties your whole kitchen unattended — brain-stem ships the first.

→ Full detail: **[Plans](../architecture/plans.md)**.

---

## 6. Sessions — keeping one conversation on-track

A **session** is one continuous conversation with the assistant, from when you open it to when you close it. Sessions need help for one reason: the assistant has a fixed-size working memory — its **context window** — and when a long session fills it, the program **compacts** the conversation, summarizing the older parts and discarding the verbatim detail to make room. That trimming is lossy by design.

brain-stem keeps a session on-track through that trimming with three pieces:

- **Checkpoints.** The system continuously saves a short, structured snapshot of where you are — which project, which task, what you just did, what to do next. Think of it as **autosave for your train of thought**: a session continuing after a trim, or a fresh one the next morning, can be cold-started from that one file. The fuller the working memory gets, the more firmly the system insists you save your place.
- **Multi-session coordination.** You can have several conversations open at once. They quietly coordinate through a shared list so two sessions never corrupt the same file unnoticed — and you get a warning when another open session has touched a file you are about to edit.
- **Session-close.** When you declare you are done, a single cleanup routine runs a checklist of housekeeping chores in the right order — refreshing indexes, reconciling plans, and writing a short receipt of what it did — so you do not have to remember a dozen steps. The whole routine is advisory: it never blocks you and never leaves a session wedged.

→ Full detail: **[Sessions](../architecture/sessions.md)**.

---

## The design principles running through all of it

The same handful of ideas shows up in every part of brain-stem. Knowing them makes the whole system predictable:

- **Advise before you block.** The system teaches and reminds far more than it forbids, and earns the right to be strict only where a bad write would quietly corrupt your work.
- **Two surfaces for every rule.** The system keeps its rules in two parallel forms: a machine-readable one the assistant *applies* at the moment of a write, and human-readable pages — like the architecture section of this site — a person reads to *understand* the reasoning. One exists so software can act; the other so a person can follow why.
- **Propose, then confirm.** Where the system extends or changes something on your behalf, it drafts the change and lets you accept, edit, or skip — rather than acting silently.
- **Structural, not disciplinary.** Guarantees (an index stays current, a paired document is flagged when its partner changes, your hand-edit always wins over an automated regeneration) are enforced by machinery, not by anyone remembering to be careful.
- **Fail open, surface the problem.** If a piece of the system is itself misconfigured, the default is to let your work continue while surfacing the problem — never to lock you out.
- **Your edits are sacred.** Installing, re-running setup, and uninstalling all treat anything you might have personalized as something to preserve, never a side effect to discard.

---

## Where to go next

- Ready to install? **[Getting started](index.md)** walks the whole path.
- Already set up? Pick the **[Architecture](../architecture/governance-engine.md)** page for whichever concept above you want in full.
