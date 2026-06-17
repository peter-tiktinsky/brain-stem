# claude-mem (optional)

> **Audience:** anyone deciding whether to add the optional **claude-mem** plugin on top of brain-stem, and wanting to know what it buys, what it costs, and how to install it — written for a reader new to Claude Code. Every term is explained the first time it appears. For where claude-mem sits in the memory design, see [The memory model](../architecture/memory-model.md).

brain-stem's memory works **completely on its own.** claude-mem is a separate, optional add-on that widens what the assistant can recall. This page is the honest "should I add it, and how" — nothing here is required.

---

## What it is

A **plugin** is an add-on you install separately to extend Claude Code. [claude-mem](https://github.com/thedotmack/claude-mem) is one: it **automatically captures what happens in your sessions, compresses it, and injects the relevant pieces back into context** at the start of future sessions — plus it keeps a **searchable record** of past sessions the assistant can query on request. It is a third-party project, not part of brain-stem, and is offered as an optional extra during [onboarding](onboarding.md).

## How it fits brain-stem's memory

brain-stem organizes what the assistant can recall into three layers of decreasing convenience. claude-mem is the **middle** layer — strictly additive:

| Layer | What it is | Without claude-mem |
|---|---|---|
| **1 — curated memory** | A small, hand-trusted set of notes loaded automatically at every session start | **Fully functional on its own.** This is the core. |
| **2 — claude-mem** | Auto-captured observations, injected at session start and searchable on demand | Absent — and nothing breaks. The core still loads. |
| **3 — raw transcripts** | The complete word-for-word session history, reached only when you ask | Unaffected. |

The key idea: layer 1 is **curated and trusted**; layer 2 is a **wide net**. Because claude-mem captures *everything*, its contents are not trusted blindly — they are **proposed into** your curated memory through the [`/mem-promote`](../reference/commands.md#mem-promote) command, which gathers candidates, checks for conflicts, and **asks before writing**. claude-mem widens recall; the promotion step keeps the trusted core clean.

## Why you might add it

- **Automatic recall.** You don't have to decide what's worth remembering in the moment — claude-mem captures the session and surfaces the relevant bits next time.
- **Searchable history.** "How did we solve this last time?" becomes answerable without you having curated the answer in advance.

## What it costs

- **It's a separate project.** claude-mem stores its captured data on your machine and has its **own** security, storage, and update posture, governed by that project — not by brain-stem. Review it on its own terms. (brain-stem only *probes* whether it's installed; it never installs it for you or sends it your data.)
- **It widens the net.** More is captured than you would hand-curate, which is exactly why its output is *proposed*, not merged automatically. Curation is still your call, via `/mem-promote`.
- **You can skip it with zero loss of core function.** If you never install it, layer 1 still loads at every session and the system works as designed.

## How to install it

One command:

```bash
npx claude-mem install
```

That is the install path brain-stem's onboarding recommends. You can run it at any time — during the onboarding external-setup step, or later if you decide you want it. If you skip it, your curated memory still works; you lose nothing by waiting.

## Where to go next

- **[The memory model](../architecture/memory-model.md)** — the full three-layer design and the curated core.
- **[Memory management](../architecture/memory-management.md)** — how the auto-loaded index is kept small.
- **[`/mem-promote`](../reference/commands.md#mem-promote)** — promoting captured observations into trusted memory.
