---
title: Section B (slim) — Who You Are (extraction prompt)
type: extraction-prompt
status: ready
section: B
extraction_mode: transcript
---

# Section B (slim) — extraction prompt

Literal extraction prompt invoked by `section-b-slim.sh` on Section B's
transcript. The engine substitutes the single `<<<{transcript}>>>` block at
runtime and submits the result to the extraction model. Output is strict JSON
in the nested user-manifest slice shape (NOT dotted U.* paths) so the slim
writer can deep-merge it directly.

Tier-2 scope: this pass populates ONLY `identity.role`, `identity.organization`,
and the three `behavioral` prose blocks. No archetype inference, no projects,
no people, no cadence/audience — those are Tier-3 (out of scope).

---

## Prompt

```
You are distilling a verbal onboarding answer into a few tight, durable config
fields. The user spoke or typed freely — often at length — about who they are
and how they want Claude to work with them. Your job is to CONSOLIDATE that
into concise, ready-to-use prose. These fields are written verbatim into the
user's global CLAUDE.md, which is hard-capped at 60 lines, so brevity is not
optional.

TRANSCRIPT:
<<<{transcript}>>>

PRODUCE strict JSON, no commentary, no markdown fences:

{
  "identity": {
    "role": "<short role phrase, e.g. 'Senior partner, management consulting'>",
    "organization": "<org name, or null if independent / unstated>"
  },
  "behavioral": {
    "communication_style": "<distilled preferences, or null>",
    "working_patterns": "<distilled preferences, or null>",
    "tooling_domain": "<distilled context, or null>"
  },
  "notes": "<one short string flagging anything ambiguous, or null>"
}

RULES

1. CONSOLIDATE, DON'T TRANSCRIBE. The transcript may ramble, repeat, or wander.
   Compress each prose field to AT MOST 4 short lines (newline-separated bullet
   fragments or 1-2 sentences). Keep the user's own terminology and emphasis;
   drop filler, hedges, and restatements. If they listed five communication
   preferences, capture the load-bearing ones tightly — do not pad.

2. MATCH THE TEMPLATE VOICE. Write the prose as instructions TO Claude, in the
   imperative ("Be direct; skip preamble." / "Plan before executing; surface
   assumptions."), mirroring how the CLAUDE.md template's example lines read.
   Do not write "The user wants..." — write the directive itself.

3. JUSTIFIED POPULATE. Fill a field only from explicit evidence or near-explicit
   inference. If the transcript says nothing usable about a field, set it to
   null — do not invent preferences. role is the one near-required field; if the
   transcript names no role at all, set role to null and flag it in notes.

4. ORGANIZATION. "I run my own thing / freelance / solo" => organization: null.
   A named firm/company/team => that name. Do not guess an org from the role.

5. NO LEAKAGE ACROSS FIELDS. communication_style = how to talk; working_patterns
   = how to collaborate / sequence work; tooling_domain = languages, frameworks,
   field of work. Keep each to its own field.

6. PLAIN STRINGS. Every value is a JSON string or null. No nested objects, no
   arrays. Newlines inside a string are allowed (use "\n").
```

---

## Notes for the engine (not model-facing)

- **Single substitution site:** `<<<{transcript}>>>`. The prompt card the user
  saw lives at `onboarding/prompt-cards/section-b-slim.txt` (not substituted —
  the questions are restated implicitly by the transcript content).
- **Output sink:** model output is wrapped by `section-b-slim.sh` into
  `user-fragment-B.json` (`{section_id, populated, ...}`, atomic tmp+rename).
- **No confidence/source_span/follow_up machinery.** Tier-2 trusts the
  consolidation and surfaces ambiguity only via the optional `notes` string and
  the downstream review/edit screen.
