# Design decisions

> **Audience:** anyone who wants the one-screen answer to "why is brain-stem built this way, and what did it *not* do?" — written for a reader with no prior background. This page is the **synthesis**: each row is a load-bearing architectural choice, the reason for it, the alternative it beat, and a link to the full evidence. The detailed case for each lives in that pillar's architecture page; this is the map over all of them.

## Two kinds of "optimal"

Every choice below is anchored to one of two things — never to taste. Holding the difference is what makes the design *non-arbitrary*:

- **Forced by the platform** *(optimal-by-constraint)* — Claude Code behaves a certain way and only one shape works. The auto-loaded memory file is hard-capped with no overflow mechanism, so a single small index plus fetch-on-demand detail is the *only* workable design, not merely a good one.
- **Independently rediscovered** *(optimal-by-convergence)* — separate, unrelated fields arrived at the same structure on their own. The three-way split of memory matches a fifty-year consensus in the study of human memory; "warn before you block" matches what policy engines, linters, and rollout systems each converged on. Independent rediscovery is a stronger signal than any single opinion.

The full version of this framing, including the seven-pillar map, is in **[Why brain-stem](../getting-started/why-brain-stem.md)**.

---

## The decisions

| Decision | What brain-stem chose | Why | What it rejected | Full rationale |
|---|---|---|---|---|
| **Governance posture** | A doorman at every write returning *allow / advise / deny*, advisory by default | Convergent — policy engines, linters, and rollout systems all warn before they block; checking *every* write is the complete-mediation principle | Hard-block-only (brittle, fights the user) or no checks at all (silent corruption) | [Governance engine →](../architecture/governance-engine.md#why-this-design-evidence-alternatives) |
| **Memory shape** | One small auto-loaded index, a three-way split (semantic / episodic / procedural), fetch deeper on demand | Both — the platform cap *forces* a single hot index; the three-way split is the *convergent* memory-science consensus | An unbounded or fully auto-loaded memory (the cap truncates it silently) | [The memory model →](../architecture/memory-model.md#why-this-design-evidence-alternatives) |
| **Vault integrity** | One reconciler as the sole writer of shared destinations, with survivorship (your hand-edits always win) | Convergent — single-writer discipline and content-addressed survivorship are settled patterns for shared, machine-touched stores | A free-for-all where multiple writers race and overwrite each other | [Vault governance →](../architecture/vault-governance.md#why-this-design-evidence-alternatives) |
| **Context framing** | A universal Library, a per-project binder, and an ephemeral Workshop — separate from always-on memory | Keeps on-demand framed context distinct from always-on identity, and regenerates indexes so they cannot rot (the documented "second-brain" failure) | One undifferentiated notes pile that fills up, drifts, and is abandoned | [Context and memory →](../architecture/context-library.md#why-this-design-evidence-alternatives) |
| **Session durability** | Automatic checkpoints and a context-pressure ladder | Constraint — every piece is a forced response to the finite working window that Claude Code lossily summarizes when it fills | Relying on the assistant to "remember" its own state across a long session | [Sessions →](../architecture/sessions.md#why-this-design-evidence-alternatives) |
| **Onboarding** | A one-time guided interview that writes your preferences and builds your vault | It *is* the personalization seam, and the mechanism matches established setup-wizard practice | The same generic install for everyone, or hand-edited config per machine | [Onboarding →](../architecture/onboarding-lifecycle.md#why-this-design-evidence-alternatives) |
| **Packaging** | A preview-first recorded install, a fingerprinted manifest, and a reversible uninstall | Both — it matches package-manager receipt patterns and is structurally stronger, because a write-free preview ships first | A blind install that clobbers your edits, leaves no receipt, and cannot be safely reversed | [Packaging & runtime →](../architecture/packaging-runtime.md#why-this-design-evidence-alternatives) |
| **Plans** | A plan tree where the control file is truth, "verified" is machine-stamped, and the runner is human-gated | Built against the documented failure rates of unsupervised multi-agent execution | Trusting agentic execution to stay in sync, with a forgeable notion of "done" | [Plans →](../architecture/plans.md#why-this-design-evidence-alternatives) |

---

## The load-bearing evidence

The rationale above is grounded in durable, independently checkable sources — the same ones cited in each pillar's evidence section:

- **Memory** — the three-way split traces to Tulving (1972) and Cohen & Squire (1980), carried into AI agents by the CoALA framework ([arXiv:2309.02427](https://arxiv.org/abs/2309.02427)) and MemGPT ([arXiv:2310.08560](https://arxiv.org/abs/2310.08560)).
- **Plans** — the human-gated runner is built against the measured failure rates of unsupervised multi-agent systems (MAST, [arXiv:2503.13657](https://arxiv.org/abs/2503.13657)).
- **Governance** — the every-write doorman implements the complete-mediation principle from Saltzer & Schroeder's protection-of-information design principles.
- **The "good intentions" failure mode** — standing instructions in a preferences file degrade over a handful of sessions (Claude Code issues [#33603](https://github.com/anthropics/claude-code/issues/33603), [#56393](https://github.com/anthropics/claude-code/issues/56393)), which is why brain-stem enforces in hooks rather than relying on the assistant to remember prose.

## Where to go next

- **[Why brain-stem](../getting-started/why-brain-stem.md)** — the long-form case, pillar by pillar.
- **[Architecture](../architecture/governance-engine.md)** — each decision in full, opening with the native→gap→enhancement frame and closing with its own evidence section.
