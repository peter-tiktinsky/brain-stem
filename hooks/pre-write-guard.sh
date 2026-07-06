#!/bin/bash
# Hook: PreToolUse (Edit|Write) — Guards and reminders for specific file patterns.
# Manifest edits:     BLOCKED (must use /librarian to regenerate)
# Plan file writes:   R-40 frontmatter-type advisory on canonical plan artifacts
# Skill file edits:   4-step change protocol checklist
# ENFORCEMENT-MAP rules implemented here (see ~/.claude-plans/ENFORCEMENT-MAP.md):
#   R-01  dead plans path DENY                        — line 26+
#   R-03  System Governance.md size guard             — line 39+ (SG_MAX_LINES hardcoded 400; dev-vault hub only)
#   R-04  vault-root allowlist                        — line ~532
#   R-54  doc-dependency cascade                      — line ~495
#   R-09  RETIRED (G3) — vault Logs/ no longer ships; the Logs/ autogovern tier
#         and the post-write-verify.sh autogovern branch were removed. Tombstoned
#         at governance/mandatory-files-rules.json :: _retired_tombstones.
#   R-23  cron wrapper bash 3.2 compatibility         — line 39+
#   R-24  claude-mem SessionEnd protection            — line 78+
#   R-27  plan naming + status enforcement            — line 123+
#   R-32  type: allowlist (Tier 2 DENY)               — line 675+
#   R-33  folder placement advisory (Tier 1)          — line 705+
# Rules implemented elsewhere:
#   R-29/R-30/R-31  backlog row size + sentinel pattern  — ~/.claude/skills/backlog-hygiene/SKILL.md
#   R-34  self-healing boundary                          — documentary
#   R-35  stage-gated promotion framework               — documentary
#   R-36  Stop-hook touched-file drift scan            — ~/.claude/hooks/stop-drift-scan.sh
#   R-37  schema-addition lockstep commit rule         — documentary (enforced by git atomicity); NO hook branch exists. T-3 audit (2026-05-21) confirmed: the "R-37 atomic lockstep DENY" referenced in the tasks.md T-3 description is a misframing — there is no enforcement code to retrofit. Documentary-only across pre-write-guard.sh.
#   R-38  blockquote summary advisory                  — ~/.claude/hooks/post-write-verify.sh (combined R-38+R-39 block)
#   R-39  provides: presence advisory                  — ~/.claude/hooks/post-write-verify.sh (same block)
set -euo pipefail

source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/paths.sh"
source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/registry.sh"

#: paths.sh leaves VAULT_ROOT empty on a manifest-less fresh
# adopter (paths.sh:17-19 missing-vault graceful-degrade contract). The
# VAULT_CONFIGURED boolean is materialized ONCE at the producer (paths.sh,
# T-5) and READ here — so the vault-write detection gates below do
# NOT collapse `"$VAULT_ROOT/"*` to `/*` (which matches every absolute path
# → bogus "new top-level vault folder 'Users/'" advisory + spurious /govern
# register on a first non-vault write). When VAULT_CONFIGURED=1 every gate
# behaves byte-for-byte as before. Fallback default keeps this hook safe under
# set -u if ever sourced against an older paths.sh that lacks the export.
VAULT_CONFIGURED="${VAULT_CONFIGURED:-0}"

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# No file path → nothing to guard
[[ -z "$FILE_PATH" ]] && exit 0

# ===: WORK_CONFIGURED-gated spoke-scoped remap prelude =======
# When an agent launched from ~/work/<spoke>/ writes a deliverable, the physical
# path is $WORK_HOME/<spoke>/<rest> but the GOVERNED surface is the vault-view
# Work/<spoke>/<rest> (the vault surfaces ~/work as Work/ via a build-time
# symlink). This prelude rewrites the in-engine FILE_PATH from the physical
# work-home form to the vault-view form so every downstream consumer — the
# doc-dependency cascade (1169), Branch #1 Class A (1241), and the 3-tier
# R-32/R-33/R-47 schema enforcement (1466) — governs the write as Work/<spoke>/…
# It MUST precede those consumers; it is inserted before the G1 gate (CORRECTED
# from a later draft window because :1169 runs first).
# Three-way gate — ALL must hold to remap (else byte-identical pass-through):
#   1. WORK_CONFIGURED=1            (vault + Work/ view + WORK_HOME all present)
#   2. FILE_PATH under $WORK_HOME/  (a work-home physical write)
#   3. first segment is a REGISTERED spoke (FIX #6 — anchored-spoke-registry.json
#      via spoke-resolve.sh; an unregistered subdir like ~/work/scratch is a
#      no-op so net-new spokes stay frictionless until /govern register).
# Canonicalization uses `pwd -P` on the parent dir (resolve symlinks/.. to the
# real path) with a STRING-PREFIX fallback (FIX #5b) when the parent does not
# yet exist (first write into a brand-new registered subdir). Fail-OPEN: any
# error leaves FILE_PATH untouched — a normal vault-direct / non-work write is
# never broken by this block.
if [[ "${WORK_CONFIGURED:-0}" == "1" ]] && [[ "$FILE_PATH" == "$WORK_HOME/"* ]]; then
  WR_REL="${FILE_PATH#$WORK_HOME/}"
  WR_SEG="${WR_REL%%/*}"
  # Only remap a path that actually descends into a segment ($WORK_HOME/<seg>/…),
  # never a bare file directly under $WORK_HOME (no spoke to key on).
  if [[ -n "$WR_SEG" ]] && [[ "$WR_REL" == */* ]]; then
    # FIX #6 — registered-spoke check. Reuse spoke-resolve.sh. A registered
    # depth-1 spoke resolves $WORK_HOME/<seg> to a key DISTINCT from the key
    # that $WORK_HOME itself resolves to (the home catch-all): the depth-1
    # cwd_anchor wins by longest-match only when it is registered. Subshell +
    # `|| true` keep set -e/-u/-o pipefail from aborting the hook on any
    # resolver hiccup (fail-OPEN to no-remap).
    WR_SPOKE_LIB="${_HOOK_DIR_EARLY:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd 2>/dev/null || true)}"
    WR_RESOLVE=""
    for _wr_cand in \
      "${SPOKE_RESOLVE_LIB:-}" \
      "$WR_SPOKE_LIB/../skills/new-plan/lib/spoke-resolve.sh" \
      "$WR_SPOKE_LIB/lib/spoke-resolve.sh" \
      "${CLAUDE_HOME:-$HOME/.claude}/skills/new-plan/lib/spoke-resolve.sh"; do
      [[ -n "$_wr_cand" ]] && [[ -f "$_wr_cand" ]] && { WR_RESOLVE="$_wr_cand"; break; }
    done
    WR_REGISTERED=0
    if [[ -n "$WR_RESOLVE" ]]; then
      WR_SEG_KEY="$(set +e; source "$WR_RESOLVE" 2>/dev/null; spoke_resolve_from_cwd "$WORK_HOME/$WR_SEG" 2>/dev/null || true)"
      WR_HOME_KEY="$(set +e; source "$WR_RESOLVE" 2>/dev/null; spoke_resolve_from_cwd "$WORK_HOME" 2>/dev/null || true)"
      if [[ -n "$WR_SEG_KEY" ]] && [[ "$WR_SEG_KEY" != "$WR_HOME_KEY" ]]; then
        WR_REGISTERED=1
      fi
    fi
    if [[ "$WR_REGISTERED" == "1" ]] && [[ "$VAULT_CONFIGURED" == "1" ]]; then
      # Canonicalize via pwd -P on the parent dir; string-prefix fallback (FIX
      # #5b) when the parent does not yet exist (first write into a new subdir).
      WR_FILE_BASE="${FILE_PATH##*/}"
      WR_PARENT="${FILE_PATH%/*}"
      WR_REAL_PARENT=""
      if [[ -d "$WR_PARENT" ]]; then
        WR_REAL_PARENT="$(cd "$WR_PARENT" 2>/dev/null && pwd -P 2>/dev/null || true)"
      fi
      WR_REAL_WORKHOME="$(cd "$WORK_HOME" 2>/dev/null && pwd -P 2>/dev/null || true)"
      [[ -z "$WR_REAL_WORKHOME" ]] && WR_REAL_WORKHOME="$WORK_HOME"
      if [[ -n "$WR_REAL_PARENT" ]] && [[ "$WR_REAL_PARENT" == "$WR_REAL_WORKHOME/"* ]]; then
        # Real-parent path (symlinks/.. resolved) is under the real work-home.
        WR_VIEW_REL="${WR_REAL_PARENT#$WR_REAL_WORKHOME/}/$WR_FILE_BASE"
      else
        # Parent dir absent (or pwd -P failed) → string-prefix fallback.
        WR_VIEW_REL="$WR_REL"
      fi
      if [[ -n "$WR_VIEW_REL" ]]; then
        FILE_PATH="$VAULT_ROOT/Work/$WR_VIEW_REL"
      fi
    fi
  fi
fi
# === end remap prelude ======================================

# === G1: live-mutation gate ============================================
# Plan-agnostic manifest-driven gate. Reads each active plan's
# `live_mutation_scope` block from its manifest.json; evaluates detection
# signals (cwd_pattern / plan_id_pattern / plan_mode_env_var / opt-in
# transcript_regex); honors exempt_paths, basename-match-env nonce
# overrides, sentinel overrides, and per-plan bypass env vars.
# Plans declare scope in their own manifest; they do not edit hook
# code (R-55). This gate reads each plan's declared live-mutation
# scope and enforces it.
# Helper path overridable via $G1_HELPER for fixture testing.
G1_HELPER="${G1_HELPER:-$HOME/.claude/hooks/lib/live-guard.sh}"
G1_CRASH_DIR="${HOOKS_STATE_OVERRIDE:-$HOOKS_STATE}"
mkdir -p "$G1_CRASH_DIR" 2>/dev/null || true

G1_OUTPUT=""
G1_EXIT=0
if [[ -x "$G1_HELPER" ]]; then
  set +e
  G1_OUTPUT=$(FILE_PATH="$FILE_PATH" TOOL_NAME="$TOOL_NAME" HOOKS_STATE="$HOOKS_STATE" CLAUDE_HOME="$CLAUDE_HOME" "$G1_HELPER" 2>>"$G1_CRASH_DIR/live-guard-crashes.log")
  G1_EXIT=$?
  set -e
  if [[ "$G1_EXIT" -ne 0 ]]; then
    printf '%s live-guard.sh exit=%s; failed open\n' "$(date -u +%FT%TZ)" "$G1_EXIT" >> "$G1_CRASH_DIR/live-guard-crashes.log" 2>/dev/null || true
  fi
fi

if [[ "$G1_EXIT" -eq 0 && -n "$G1_OUTPUT" ]]; then
  printf '%s\n' "$G1_OUTPUT"
  exit 0
fi
# === end G1 ================================================================

# === R-52 write-time DENY (T-5, — per-entry shape) ==
# Narrow gate: fires ONLY when $FILE_PATH = overlay-master.json AND the
# pending-state overlay would shadow a foundation entry without per-entry
# `_override_reason`. The SINGLE call site that fires foundation-overlay-load.sh
# WITHOUT --force-override — every other hook-side read passes the flag
# (hook reads are not overlay writes per).
# Per: per-write `--force-override` bypass at the /govern register
# layer; here, R52_FORCE_OVERRIDE=1 env var bypasses for direct-Edit/Write
# flows (e.g. test substrate). No persistent disable.
# Helper path resolution duplicates the pattern (foundation-repo +
# post-install layouts) because this branch fires BEFORE in hook flow.
T5_OVERLAY_TARGET="${OVERLAY_MASTER_PATH:-${CLAUDE_HOME:-$HOME/.claude}/governance/overlay-master.json}"
if [[ "$FILE_PATH" == "$T5_OVERLAY_TARGET" ]] && [[ "${R52_FORCE_OVERRIDE:-0}" != "1" ]]; then
  T5_HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd 2>/dev/null || true)
  T5_HELPER="${FOUNDATION_OVERLAY_LOAD:-}"
  if [[ -z "$T5_HELPER" ]]; then
    if [[ -x "$T5_HOOK_DIR/lib/foundation-overlay-load.sh" ]]; then
      T5_HELPER="$T5_HOOK_DIR/lib/foundation-overlay-load.sh"
    elif [[ -x "$T5_HOOK_DIR/../lib/foundation-overlay-load.sh" ]]; then
      T5_HELPER="$T5_HOOK_DIR/../lib/foundation-overlay-load.sh"
    fi
  fi
  T5_FOUNDATION="${FOUNDATION_MASTER_PATH:-${CLAUDE_HOME:-$HOME/.claude}/governance/foundation-master.json}"
  if [[ -n "$T5_HELPER" ]] && [[ -x "$T5_HELPER" ]] && [[ -f "$T5_FOUNDATION" ]]; then
    # Materialize pending-state overlay content. Write = tool_input.content
    # in full; Edit = current file with old_string→new_string applied via
    # python (handles multi-line strings safely).
    T5_PENDING_CONTENT=""
    if [[ "$TOOL_NAME" == "Write" ]]; then
      T5_PENDING_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
    elif [[ "$TOOL_NAME" == "Edit" ]] && [[ -f "$FILE_PATH" ]]; then
      T5_OLD=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')
      T5_NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
      T5_PENDING_CONTENT=$(python3 - "$FILE_PATH" "$T5_OLD" "$T5_NEW" <<'PY' || true
import sys
fp, old_s, new_s = sys.argv[1], sys.argv[2], sys.argv[3]
with open(fp) as f:
    content = f.read()
sys.stdout.write(content.replace(old_s, new_s, 1))
PY
)
    fi
    # Only invoke helper if we produced a JSON-parseable pending state.
    if [[ -n "$T5_PENDING_CONTENT" ]] && echo "$T5_PENDING_CONTENT" | jq empty >/dev/null 2>&1; then
      T5_TEMPDIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'r52-deny')
      T5_PENDING_PATH="$T5_TEMPDIR/overlay-pending.json"
      printf '%s' "$T5_PENDING_CONTENT" > "$T5_PENDING_PATH"
      T5_HELPER_STDERR=$("$T5_HELPER" \
        --foundation-path "$T5_FOUNDATION" \
        --overlay-path "$T5_PENDING_PATH" \
        --query '.schema_version // ""' \
        2>&1 >/dev/null) || T5_HELPER_RC=$?
      T5_HELPER_RC="${T5_HELPER_RC:-0}"
      rm -rf "$T5_TEMPDIR" 2>/dev/null || true
      if [[ "$T5_HELPER_RC" == "1" ]]; then
        # R-52 collision detected. Surface helper stderr verbatim plus
        # canonical-shape resolution guidance.
        T5_DENY_MSG="R-52 write-time DENY (T-5): the pending overlay at $(basename "$FILE_PATH") would shadow foundation entries without per-entry _override_reason. Helper output:"$'\n'"${T5_HELPER_STDERR}"$'\n'"Resolve by adding _override_reason: \"<text>\" inline on each shadowing entry. To bypass for a single write, re-invoke with R52_FORCE_OVERRIDE=1 (per-write only; no persistent disable)."
        format_output_deny "PreToolUse" "$T5_DENY_MSG"
        exit 0
      fi
    fi
  fi
fi
# === end R-52 write-time DENY ============================================

# --- BLOCK: Writes to the dead plans path (migrated 2026-04-13) ---
# The path ~/.claude/plans/ is now a permanent placeholder
# containing only README.md. Claude Code's harness recreates the folder
# intermittently and that's accepted as cosmetic. ANY Edit|Write to that
# folder is still denied with one exception: README.md itself, which is the
# coexistence marker. Stale-reference bugs still fail loudly here.
if [[ -n "$PLANS_DIR_DEAD" && "$FILE_PATH" == "$PLANS_DIR_DEAD/README.md" ]]; then
  : # allow (placeholder marker — coexistence README)
elif [[ -n "$PLANS_DIR_DEAD" && ( "$FILE_PATH" == "$PLANS_DIR_DEAD/"* || "$FILE_PATH" == "$PLANS_DIR_DEAD" ) ]]; then
  format_output_deny "PreToolUse" "Dead path ~/.claude/plans/ — migrated to ~/.claude-plans/ on 2026-04-13. This folder is a permanent placeholder; only its README.md may be written. Update your reference to use \$PLANS_DIR (from ~/.claude/hooks/lib/paths.sh) or the new absolute path ~/.claude-plans/. See the migration handoff in your installation docs for context."
  exit 0
fi

# === Cron wrapper bash 3.2 compatibility check (R-23) ===================
# macOS /bin/bash is 3.2 — launchd cron wrappers MUST be bash 3.2-compatible.
# Scope: ONLY files under orchestrator/cron-wrappers/*.sh. Other shells are
# free to assume bash 4+.
if [[ "$FILE_PATH" == *"/orchestrator/cron-wrappers/"*".sh" ]]; then
  CW_CONTENT=""
  if [[ "$TOOL_NAME" == "Write" ]]; then
    CW_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
  elif [[ "$TOOL_NAME" == "Edit" ]]; then
    CW_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
  fi
  if [[ -n "$CW_CONTENT" ]]; then
    CW_OFFENDER=""
    if echo "$CW_CONTENT" | grep -qE '^[[:space:]]*declare[[:space:]]+-A\b'; then
      CW_OFFENDER="declare -A (associative arrays, bash 4+)"
    elif echo "$CW_CONTENT" | grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*,,\}|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^\}'; then
      CW_OFFENDER='${var,,} / ${var^^} case expansion (bash 4+)'
    elif echo "$CW_CONTENT" | grep -qE '^[[:space:]]*(readarray|mapfile)\b'; then
      CW_OFFENDER="readarray / mapfile (bash 4+)"
    elif echo "$CW_CONTENT" | grep -qE '\{[0-9]+\.\.[0-9]+\.\.[0-9]+\}'; then
      CW_OFFENDER="brace-expansion step syntax {a..b..n} (bash 4+)"
    elif echo "$CW_CONTENT" | grep -qE '(^|[^&])&>>'; then
      CW_OFFENDER="&>> append redirect (bash 4+)"
    fi
    if [[ -n "$CW_OFFENDER" ]]; then
      CW_REASON="Cron wrapper bash 3.2 compatibility (R-23): offending construct — ${CW_OFFENDER}. macOS /bin/bash is 3.2; launchd cron wrappers MUST be bash 3.2-compatible or they will silently fail in cron context. Substitute a 3.2 alternative: parallel indexed arrays instead of declare -A; tr/awk for case conversion; while-read loops instead of readarray; explicit lists instead of step brace expansion; '>>file 2>&1' instead of '&>>file'."
      format_output_deny "PreToolUse" "$CW_REASON"
      exit 0
    fi
  fi
fi
# === end cron wrapper bash3 check ========================================

# === first-party memory-consolidation SessionEnd protection (R-24) =======
# Protects the first-party memory-consolidation hook wiring. (framing
# rewrite: claude-mem is OPTIONAL/adopter-installed per — NOT "required
# infrastructure"; the R-24 rule survives, only the framing string changed.)
# Block any settings.json Write/Edit that removes the memory-consolidation-
# check.sh / claude-mem SessionEnd hook. Escape hatch: CLAUDE_MEM_DISABLE_OK=1
if [[ "$FILE_PATH" == "${CLAUDE_HOME:-$HOME/.claude}/settings.json" ]]; then
  CM_CONTENT=""
  if [[ "$TOOL_NAME" == "Write" ]]; then
    CM_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
  elif [[ "$TOOL_NAME" == "Edit" ]] && [[ -f "$FILE_PATH" ]]; then
    CM_OLD=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')
    CM_NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
    CM_RALL=$(echo "$INPUT" | jq -r '.tool_input.replace_all // false')
    CM_CONTENT=$(python3 - "$FILE_PATH" "$CM_OLD" "$CM_NEW" "$CM_RALL" <<'PYEOF' 2>/dev/null || cat "$FILE_PATH"
import sys
with open(sys.argv[1]) as f:
    c = f.read()
old, new = sys.argv[2], sys.argv[3]
if sys.argv[4] == "true":
    c = c.replace(old, new)
else:
    c = c.replace(old, new, 1)
sys.stdout.write(c)
PYEOF
)
  fi
  if [[ -n "$CM_CONTENT" ]]; then
    if ! echo "$CM_CONTENT" | grep -qE 'memory-consolidation-check\.sh|claude-mem'; then
      if [[ "${CLAUDE_MEM_DISABLE_OK:-0}" != "1" ]]; then
        CM_REASON="memory-consolidation protection (R-24): this settings.json write removes the first-party memory-consolidation hook (memory-consolidation-check.sh SessionEnd wiring; the regex also matches the legacy claude-mem entry). This is a first-party memory-consolidation hook, not required external infrastructure (claude-mem is optional/adopter-installed). To override intentionally, set CLAUDE_MEM_DISABLE_OK=1 in the environment for this write."
        format_output_deny "PreToolUse" "$CM_REASON"
        exit 0
      else
        { mkdir -p "${CLAUDE_STATE_ROOT}/audit" 2>/dev/null && echo "$(date -Iseconds) | pre-write-guard | CLAUDE_MEM_DISABLE_OK override | $FILE_PATH" >> "${CLAUDE_STATE_ROOT}/audit/hook-audit.log"; } 2>/dev/null || true
      fi
    fi
  fi
fi
# === end claude-mem protection ===========================================

# === Branch #4: plans-tree-librarian-generated (T-7;..) ====
# Enforces librarian-only
# writes to the 3 plans-tree root files (_index.md / _backlog.md / _archive.md).
# Detection: path-glob match against $HOME/.claude-plans/_{index,backlog,archive}.md.
# Caller-detection: env-var stamp CLAUDE_LIBRARIAN_WRITE=1 (per).
# Action: DENY when env unset; advisory directs caller to the librarian skill.
# Positioned BEFORE R-27 because the librarian-generated registry files are
# NOT plans (they don't carry NN- prefix or status markers); R-27 would
# false-positive on them otherwise. On env-var=1 we short-circuit (exit 0)
# since the librarian's mechanical writes don't benefit from downstream
# enforcement (vault/3-tier/doc-dep checks no-op on ~/.claude-plans/ paths).
# Rationale: plans-rules.json.root_files.writers_allowed: ["librarian"] —
# direct hand-edits drift the index out of sync with manifest reality.
B4_PT_PARENT="${PLANS_DIR:-$HOME/.claude-plans}"
if [[ "$(dirname "$FILE_PATH")" == "$B4_PT_PARENT" ]]; then
  case "$(basename "$FILE_PATH")" in
    _index.md|_backlog.md|_archive.md)
      if [[ "${CLAUDE_LIBRARIAN_WRITE:-0}" != "1" ]]; then
        B4_REASON="Plans-tree librarian-generated file write blocked (Branch #4 /-). _index.md, _backlog.md, and _archive.md are generated by the librarian. Use the librarian skills (plan-index / backlog-index / plan-archive) to update; direct writes to these 3 files are denied unless the caller exports CLAUDE_LIBRARIAN_WRITE=1 before writing."
        format_output_deny "PreToolUse" "$B4_REASON"
        exit 0
      fi
      # env-var=1: librarian-driven mechanical write. Short-circuit remaining
      # checks (R-27 would deny on missing NN- prefix / status marker; 3-tier
      # vault check no-ops on non-vault paths).
      exit 0
      ;;
  esac
fi
# === end Branch #4 ====================================================

# === Plan naming + status enforcement (R-27) ===========================
# Promotes feedback_plan_naming_conventions.md from memory-only to procedural
# enforcement. Scoped NARROWLY to plan-root files — sub-tasks, handoffs, test
# artifacts, and orchestrator exhaust are explicitly NOT enforced (they inherit
# status from the parent plan via the stale-detect scope fix in the same session).
# Enforced files:
#   ~/.claude-plans/*.md                        (flat root plans)
#   ~/.claude-plans/*/spec.md
#   ~/.claude-plans/*/00-ideation-brief.md
#   ~/.claude-plans/*/README.md                 (folder-style plans' index doc)
#   ~/.claude-plans/*/manifest.json             (top-level status field)
# Whitelisted (vault-wide registries, not plans):
#   ~/.claude-plans/ENFORCEMENT-MAP.md
#   ~/.claude-plans/_index.md
# Detection: reconstruct post-write content; require one of
#   (a) **Status:** <value> header bullet
#   (b) YAML frontmatter status: <value>
#   (c) manifest.json top-level "status" field (manifest writes only)
# Escape hatch: PLAN_STATUS_OK=1 env var (logged to hook-audit.log)
# bash 3.2 clean: no associative arrays, no ${var,,}, no readarray, no &>>
# R-27 plan-root classification — sourced from canonical helper to eliminate
# the demonstrated hook ↔ librarian drift surface. (2026-04-19/20).
# classify_plan_path returns is_plan|is_manifest|top_segment.
source "${CLAUDE_HOME:-$HOME/.claude}/hooks/lib/plan-path.sh"
PS_INFO=$(classify_plan_path "$FILE_PATH")
PS_IS_PLAN="${PS_INFO%%|*}"
PS_REST="${PS_INFO#*|}"
PS_IS_MANIFEST="${PS_REST%%|*}"
PS_TOP_SEGMENT="${PS_REST#*|}"

# Prefix check (R-27): when a plan-root file
# is in scope, verify its top-level segment starts with NN-. Prefix check runs
# BEFORE the status check — both must pass.
if [[ "$PS_IS_PLAN" == "1" ]]; then
  PS_PREFIX_OK=0
  if [[ "$PS_TOP_SEGMENT" =~ ^[0-9]+- ]]; then
    PS_PREFIX_OK=1
  fi
  if [[ "$PS_PREFIX_OK" == "0" ]]; then
    if [[ "${PLAN_STATUS_OK:-0}" == "1" ]]; then
      { mkdir -p "${CLAUDE_STATE_ROOT}/audit" 2>/dev/null && echo "$(date -Iseconds) | pre-write-guard | PLAN_STATUS_OK override (prefix) | $FILE_PATH" >> "${CLAUDE_STATE_ROOT}/audit/hook-audit.log"; } 2>/dev/null || true
    else
      PS_PREFIX_REASON="Plan naming convention (R-27, feedback_plan_naming_conventions.md): this plan-root path is missing the required NN- numeric prefix. Top segment: '${PS_TOP_SEGMENT}'. New plan files and directories at ~/.claude-plans/ must start with a numeric prefix matching the next-available integer (run 'ls ~/.claude-plans/ | grep -oE \"^[0-9]+\" | sort -n | tail -1' and add 1). Use descriptive slug, not auto-generated. Escape hatch: export PLAN_STATUS_OK=1 (logged to hook-audit.log)."
      format_output_deny "PreToolUse" "$PS_PREFIX_REASON"
      exit 0
    fi
  fi
fi

if [[ "$PS_IS_PLAN" == "1" ]]; then
  PS_CONTENT=""
  if [[ "$TOOL_NAME" == "Write" ]]; then
    PS_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
  elif [[ "$TOOL_NAME" == "Edit" ]] && [[ -f "$FILE_PATH" ]]; then
    PS_OLD=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')
    PS_NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
    PS_RALL=$(echo "$INPUT" | jq -r '.tool_input.replace_all // false')
    PS_CONTENT=$(python3 - "$FILE_PATH" "$PS_OLD" "$PS_NEW" "$PS_RALL" <<'PYEOF' 2>/dev/null || cat "$FILE_PATH"
import sys
with open(sys.argv[1]) as f:
    c = f.read()
old, new = sys.argv[2], sys.argv[3]
if sys.argv[4] == "true":
    c = c.replace(old, new)
else:
    c = c.replace(old, new, 1)
sys.stdout.write(c)
PYEOF
)
  fi

  if [[ -n "$PS_CONTENT" ]]; then
    PS_HAS_STATUS=0
    if [[ "$PS_IS_MANIFEST" == "1" ]]; then
      # JSON top-level "status" field, non-empty
      PS_JSON_STATUS=$(echo "$PS_CONTENT" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin)
  v=d.get("status","") if isinstance(d,dict) else ""
  print(v if v else "")
except Exception:
  print("")' 2>/dev/null)
      if [[ -n "$PS_JSON_STATUS" ]]; then
        PS_HAS_STATUS=1
      fi
    else
      # Markdown: **Status:** header bullet OR YAML status: field
      if echo "$PS_CONTENT" | grep -qE '^\*\*Status:\*\*[[:space:]]*\S+'; then
        PS_HAS_STATUS=1
      elif echo "$PS_CONTENT" | awk '/^---[[:space:]]*$/{n++; next} n==1{print} n>=2{exit}' | grep -qE '^status:[[:space:]]*\S+'; then
        PS_HAS_STATUS=1
      fi
    fi

    if [[ "$PS_HAS_STATUS" == "0" ]]; then
      if [[ "${PLAN_STATUS_OK:-0}" == "1" ]]; then
        { mkdir -p "${CLAUDE_STATE_ROOT}/audit" 2>/dev/null && echo "$(date -Iseconds) | pre-write-guard | PLAN_STATUS_OK override | $FILE_PATH" >> "${CLAUDE_STATE_ROOT}/audit/hook-audit.log"; } 2>/dev/null || true
      else
        PS_REASON="Plan naming convention (R-27, feedback_plan_naming_conventions.md): this plan file is missing a status marker. Required: one of (a) **Status:** header bullet with value (e.g., **Status:** briefed), (b) YAML frontmatter status: field, or (c) manifest.json top-level status field (for manifest writes). Scope: flat root plans + spec.md + 00-ideation-brief.md + README.md + manifest.json. Sub-task files, handoff.md, and orchestrator artifacts are explicitly NOT required to carry status (they inherit from the parent plan). Escape hatch: export PLAN_STATUS_OK=1 (logged to hook-audit.log)."
        format_output_deny "PreToolUse" "$PS_REASON"
        exit 0
      fi
    fi
  fi
fi
# === end plan status enforcement =========================================

# === R-27 depth-3 sub-plan-root status assertion ====
# §Consequences (a)/(b)/(c): R-27's enforcement extends to depth-3
# sub-plan roots. Depth-3 sub-plan spec.md/manifest.json are governed PEERS
# carrying their OWN canonical status (vocabulary), NOT status-derived
# shadows of the master. A sub-plan can be `paused` independently of its master.
# This block is the-owned hook substance complementing the depth-3 globs
# authored in governance/naming-rules.json :: R-27.enforcement_scope
# ({plans_root}/*/*/spec.md + {plans_root}/*/*/manifest.json). It asserts,
# directly (without depending on the classify_plan_path helper being
# depth-3-aware): (a) parent dir matches {plans_root}/NN-{master}/NN-{sub}/;
# (b) target is spec.md or manifest.json; (c) for manifest.json, status: is
# present + its value is in the 8-state enum.
# Status-acceptance mirrors R-27 (a)/(b)/(c). DENY at write-time on a missing
# or out-of-vocabulary status; escape hatch PLAN_STATUS_OK=1.
PLANS_ROOT_FOR_R27="${PLANS_DIR:-$HOME/.claude-plans}"
if [[ "${PLAN_STATUS_OK:-0}" != "1" ]] && [[ "$FILE_PATH" == "$PLANS_ROOT_FOR_R27"/*/*/spec.md || "$FILE_PATH" == "$PLANS_ROOT_FOR_R27"/*/*/manifest.json ]]; then
  # Confirm the depth-3 shape: NN-{master}/NN-{sub}/{spec.md|manifest.json}
  R27D3_SUB_DIR="$(basename "$(dirname "$FILE_PATH")")"
  R27D3_MASTER_DIR="$(basename "$(dirname "$(dirname "$FILE_PATH")")")"
  if [[ "$R27D3_SUB_DIR" =~ ^[0-9]+- ]] && [[ "$R27D3_MASTER_DIR" =~ ^[0-9]+- ]]; then
    # Reconstruct post-write content for status detection.
    R27D3_CONTENT=""
    case "$TOOL_NAME" in
      Write)
        R27D3_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
        ;;
      Edit)
        if [[ -f "$FILE_PATH" ]]; then
          R27D3_CONTENT=$(cat "$FILE_PATH" 2>/dev/null)
        fi
        R27D3_NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
        R27D3_CONTENT="$R27D3_CONTENT
$R27D3_NEW"
        ;;
    esac

    # canonical 8-state enum (+ superseded terminal).
    R27D3_ENUM="researching planned in-progress paused completed verified closed archived superseded"
    R27D3_STATUS_OK=0
    R27D3_STATUS_VAL=""

    if [[ "$FILE_PATH" == *manifest.json ]]; then
      # (c) manifest.json: status: field present + value in the enum.
      R27D3_STATUS_VAL=$(printf '%s' "$R27D3_CONTENT" | jq -r '.status // empty' 2>/dev/null)
      if [[ -n "$R27D3_STATUS_VAL" ]]; then
        for _s in $R27D3_ENUM; do
          [[ "$R27D3_STATUS_VAL" == "$_s" ]] && R27D3_STATUS_OK=1 && break
        done
      fi
    else
      # spec.md: accept (a) **Status:** header bullet OR (b) YAML status: frontmatter.
      if printf '%s' "$R27D3_CONTENT" | grep -qE '^\s*[-*]?\s*\*\*Status:\*\*\s*\S'; then
        R27D3_STATUS_OK=1
      elif printf '%s' "$R27D3_CONTENT" | grep -qE '^status:\s*\S'; then
        R27D3_STATUS_OK=1
      fi
    fi

    if [[ "$R27D3_STATUS_OK" != "1" ]]; then
      if [[ "$FILE_PATH" == *manifest.json ]]; then
        R27D3_REASON="Plan naming convention (R-27 depth-3): this depth-3 sub-plan manifest at ${R27D3_MASTER_DIR}/${R27D3_SUB_DIR}/ must carry a top-level status: field whose value is in the canonical 8-state vocabulary (researching|planned|in-progress|paused|completed|verified|closed|archived; superseded terminal). Found: '${R27D3_STATUS_VAL:-<none>}'. A sub-plan is a first-class governed peer carrying its OWN canonical status, not a status-derived shadow of its master. Escape hatch: export PLAN_STATUS_OK=1 (logged)."
      else
        R27D3_REASON="Plan naming convention (R-27 depth-3): this depth-3 sub-plan spec.md at ${R27D3_MASTER_DIR}/${R27D3_SUB_DIR}/ is missing a status marker. Required: one of (a) **Status:** header bullet with a single lifecycle token, or (b) YAML frontmatter status: field. A sub-plan carries its OWN canonical status (first-class peer). Escape hatch: export PLAN_STATUS_OK=1 (logged)."
      fi
      format_output_deny "PreToolUse" "$R27D3_REASON"
      exit 0
    fi
  fi
fi
# === end R-27 depth-3 sub-plan-root status assertion =====================

# === System Governance.md size guard (SG_MAX_LINES) ====================
# Block any Write/Edit on System Governance.md whose result exceeds the
# navigational-index threshold. Force extraction-first discipline.
# SG_MAX_LINES is hardcoded to 400 — the foundation no longer ships a
# System Governance.md.json contract to derive the cap from. This guard is
# retained for the dev-vault hub only.
VA_PATH="$HOME/Documents/Obsidian Vault/System Governance.md"
SG_MAX_LINES=400

if [[ "$FILE_PATH" == "$VA_PATH" ]]; then
  va_new_lines=0
  case "$TOOL_NAME" in
    Write)
      VA_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
      va_new_lines=$(printf '%s' "$VA_CONTENT" | wc -l | tr -d ' ')
      # wc -l counts newlines; add 1 if content doesn't end in newline
      if [[ -n "$VA_CONTENT" ]] && [[ "${VA_CONTENT: -1}" != $'\n' ]]; then
        va_new_lines=$((va_new_lines + 1))
      fi
      ;;
    Edit)
      if [[ -f "$VA_PATH" ]]; then
        VA_OLD=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')
        VA_NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
        VA_REPLACE_ALL=$(echo "$INPUT" | jq -r '.tool_input.replace_all // false')
        va_tmp=$(mktemp)
        # Python literal substitution (no regex pitfalls)
        VA_OLD_B64=$(printf '%s' "$VA_OLD" | base64)
        VA_NEW_B64=$(printf '%s' "$VA_NEW" | base64)
        python3 -c "
import sys, base64
path = sys.argv[1]
old = base64.b64decode(sys.argv[2]).decode('utf-8')
new = base64.b64decode(sys.argv[3]).decode('utf-8')
replace_all = sys.argv[4] == 'true'
with open(path, 'r') as f:
    content = f.read()
if replace_all:
    content = content.replace(old, new)
else:
    content = content.replace(old, new, 1)
with open(sys.argv[5], 'w') as f:
    f.write(content)
" "$VA_PATH" "$VA_OLD_B64" "$VA_NEW_B64" "$VA_REPLACE_ALL" "$va_tmp" 2>/dev/null || true
        if [[ -s "$va_tmp" ]]; then
          va_new_lines=$(wc -l < "$va_tmp" | tr -d ' ')
        fi
        rm -f "$va_tmp"
      fi
      ;;
  esac

  if [[ "$va_new_lines" -gt "$SG_MAX_LINES" ]]; then
    REASON="System Governance.md would become ${va_new_lines} lines, exceeding the navigational-index threshold (${SG_MAX_LINES}). It is a navigational hub; long content belongs in separate topic notes. To proceed: (1) identify a self-contained section to extract, (2) move it to its own note, (3) replace the section in the hub with a stub redirect, (4) retry the write."
    format_output_deny "PreToolUse" "$REASON"
    exit 0
  fi
fi
# === end VA.md size guard ===============================================

# --- BLOCK: Direct edits to librarian-manifest.json ---
if [[ "$FILE_PATH" == *"librarian-manifest.json"* ]]; then
  format_output_deny "PreToolUse" "Direct edits to librarian-manifest.json are prohibited. The manifest must be regenerated through /librarian to maintain holistic consistency (backend_sync.in_sync flags go stale on manual edits). Use /librarian with the appropriate capability instead."
  exit 0
fi

# === manifest status-transition SUBSTANCE branch ==
# Write-time substance-verifying guard. Matcher Edit|Write + if: on
# **/manifest.json (plan-tree manifests). Verifies FACTS, not the label string:
#   - a status -> closed flip requires status==verified (the load-bearing
#     closed-requires-verified guard, §Decision; layer (a)) AND
#     the close-conditional artifacts present (the plan quartet);
#   - a status -> verified flip requires a fresh harness_validated[]
#     verdict-pass entry (the stamper's home is the S2/
#     dogfood-harness, NOT this hook — this branch only GUARDS the transition).
# Cross-file invariants (R-61/R-62/R-63) live in the librarian reconciler
# ((b)), NEVER in this blocking write-time path.
# Rollout (§Decision): launch as `ask`, promote to `deny` once FP-rate
# is low. v1.0.0 default = ask; MANIFEST_SUBSTANCE_ROLLOUT env overrides for
# test/CI (`deny` to exercise the strict path). Escape hatch:
# MANIFEST_SUBSTANCE_OK=1 (logged).
PLANS_ROOT_FOR_MS="${PLANS_DIR:-$HOME/.claude-plans}"
if [[ "${MANIFEST_SUBSTANCE_OK:-0}" != "1" ]] && \
   [[ "$FILE_PATH" == "$PLANS_ROOT_FOR_MS"/*/manifest.json || "$FILE_PATH" == "$PLANS_ROOT_FOR_MS"/*/*/manifest.json ]]; then
  MS_ROLLOUT="${MANIFEST_SUBSTANCE_ROLLOUT:-ask}"   # ask (v1.0.0 default) | deny

  # Reconstruct the post-write manifest content.
  MS_CONTENT=""
  case "$TOOL_NAME" in
    Write)
      MS_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
      ;;
    Edit)
      if [[ -f "$FILE_PATH" ]]; then
        MS_OLD=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')
        MS_NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
        MS_REPLACE_ALL=$(echo "$INPUT" | jq -r '.tool_input.replace_all // false')
        MS_OLD_B64=$(printf '%s' "$MS_OLD" | base64)
        MS_NEW_B64=$(printf '%s' "$MS_NEW" | base64)
        MS_CONTENT=$(python3 -c "
import sys, base64
with open(sys.argv[1]) as f: c = f.read()
old = base64.b64decode(sys.argv[2]).decode('utf-8')
new = base64.b64decode(sys.argv[3]).decode('utf-8')
print(c.replace(old, new) if sys.argv[4]=='true' else c.replace(old, new, 1), end='')
" "$FILE_PATH" "$MS_OLD_B64" "$MS_NEW_B64" "$MS_REPLACE_ALL" 2>/dev/null)
      fi
      ;;
  esac

  if [[ -n "$MS_CONTENT" ]]; then
    MS_NEW_STATUS=$(printf '%s' "$MS_CONTENT" | jq -r '.status // empty' 2>/dev/null)
    MS_OLD_STATUS=""
    [[ -f "$FILE_PATH" ]] && MS_OLD_STATUS=$(jq -r '.status // empty' "$FILE_PATH" 2>/dev/null)

    MS_VIOLATION=""

    # Guard 1: status -> closed requires status==verified + the close-conditional
    # quartet present. ("done" is unforgeable;.)
    if [[ "$MS_NEW_STATUS" == "closed" && "$MS_OLD_STATUS" != "closed" ]]; then
      if [[ "$MS_OLD_STATUS" != "verified" ]]; then
        MS_VIOLATION="closed-requires-verified: a status flip to 'closed' requires the current status to be 'verified' (found '${MS_OLD_STATUS:-<unset>}'). 'verified' is machine-stamped by the dogfood-harness verdict-pass; you cannot skip it. (§Decision; layer (a).)"
      else
        MS_PLAN_DIR="$(dirname "$FILE_PATH")"
        for _q in spec.md tasks.md manifest.json; do
          if [[ ! -f "$MS_PLAN_DIR/$_q" ]]; then
            MS_VIOLATION="closed requires the close-conditional artifacts present — missing ${_q} in ${MS_PLAN_DIR}. (subplan_rules.metadata_flow.required_artifacts verified->closed.)"
            break
          fi
        done
      fi
    fi

    # Guard 2: status -> verified requires a fresh harness_validated[] verdict-pass.
    if [[ -z "$MS_VIOLATION" && "$MS_NEW_STATUS" == "verified" && "$MS_OLD_STATUS" != "verified" ]]; then
      MS_FRESH_PASS=$(printf '%s' "$MS_CONTENT" | jq -r '[.harness_validated[]? | select(.verdict=="pass" and .harness_freshness=="fresh")] | length' 2>/dev/null)
      if [[ -z "$MS_FRESH_PASS" || "$MS_FRESH_PASS" -lt 1 ]]; then
        MS_VIOLATION="verified-requires-fresh-verdict: a status flip to 'verified' requires a fresh harness_validated[] verdict-pass entry (verdict=='pass', harness_freshness=='fresh'). 'verified' is reachable ONLY through an actual validation pass. The stamper is the dogfood-harness, not a hand-edit."
      fi
    fi

    if [[ -n "$MS_VIOLATION" ]]; then
      MS_MSG="[(a) manifest-substance guard] ${MS_VIOLATION} Escape hatch: export MANIFEST_SUBSTANCE_OK=1 (logged)."
      if [[ "$MS_ROLLOUT" == "deny" ]]; then
        format_output_deny "PreToolUse" "$MS_MSG"
        exit 0
      else
        # v1.0.0 rollout default: ask (advisory, allow + surface). Promote to
        # deny once FP-rate is low (§Decision rollout idiom).
        format_output_allow "PreToolUse" "$MS_MSG (advisory at v1.0.0; rollout=ask)"
      fi
    fi
  fi
fi
# === end (a) manifest status-transition substance branch ===========


# === HCM-3 handoff.md section_schema write-time DENY (sub 04 / T-3) ==
# Stops the per-spoke handoff-chronicle degrading to an all-fallback projection: a
# NEW session ENTRY appended to a plan-tree handoff.md must use a heading shape the
# chronicle recognizer actually parses (skills/librarian/capabilities/
# plan-handoff-index.sh + hooks/handoff-chronicle-append.sh SESSION_HEADING_RE),
# which is exactly the shape governance/file-type-contracts/handoff.md.json ::
# section_schema enumerates. The ERE below expresses the SAME accepted shapes as
# that contract section_schema; it is hardcoded here so enforcement agrees with the
# fixed recognizer NOW (the single foundation-master.json rebuild that composes the
# contract for other consumers is R1-DEFERRED per sub 04).
# SCOPE (false-positive floor, per the R-27 advisory-first precedent): fires ONLY
# on a NEWLY-ADDED H2 heading that STARTS with the canonical `Session` /
# `Alignment Session` entry keyword but does NOT conform. Narrative H2s that merely
# MENTION a session ("## Next session prompt", "## Critical info for Session <N>",
# "## Files modified this session") do not START with the keyword and are never
# flagged; the container "## Sessions" (plural) has no word-boundary after
# "Session" and is never flagged. ONLY the NEW content (Edit new_string / Write
# content) is inspected — legacy/conforming appends are NEVER retro-scanned.
# Matching is case-insensitive (grep -qiE) so it agrees with the recognizer's
# re.IGNORECASE — a lowercase malformed "## session recap" is caught too.
# Escape hatch: HANDOFF_SECTION_SCHEMA_OK=1 allows the append AND logs the override
# to hook-audit.log (like R-27); the block still runs under the escape hatch so the
# bypass is auditable (do NOT re-add an OK!=1 clause to the guard — that made the
# audit-log branch dead code).
if [[ "$FILE_PATH" == *"/.claude-plans/"*"/handoff.md" ]]; then
  HS_NEW=""
  if [[ "$TOOL_NAME" == "Write" ]]; then
    HS_NEW=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
  elif [[ "$TOOL_NAME" == "Edit" ]]; then
    HS_NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
  fi
  if [[ -n "$HS_NEW" ]]; then
    # session-entry-INTENT: an H2 whose text STARTS with (Alignment )?Session as a
    # whole word. CONFORM: the accepted session-heading shapes (== contract
    # section_schema). A line that is INTENT but not CONFORM is a malformed entry.
    HS_INTENT='^##[[:space:]]+(Alignment[[:space:]]+)?Session([^A-Za-z0-9]|$)'
    HS_SCHEMA='^##[[:space:]]+((Alignment[[:space:]]+)?Session[[:space:]]*(:|S?[0-9])|S[0-9]|[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])'
    HS_OFFENDER=""
    while IFS= read -r _hl; do
      if printf '%s\n' "$_hl" | grep -qiE "$HS_INTENT"; then
        if ! printf '%s\n' "$_hl" | grep -qiE "$HS_SCHEMA"; then
          HS_OFFENDER="$_hl"
          break
        fi
      fi
    done <<< "$HS_NEW"
    if [[ -n "$HS_OFFENDER" ]]; then
      if [[ "${HANDOFF_SECTION_SCHEMA_OK:-0}" == "1" ]]; then
        { mkdir -p "${CLAUDE_STATE_ROOT}/audit" 2>/dev/null && echo "$(date -Iseconds) | pre-write-guard | HANDOFF_SECTION_SCHEMA_OK override | $FILE_PATH" >> "${CLAUDE_STATE_ROOT}/audit/hook-audit.log"; } 2>/dev/null || true
      else
        HS_REASON="handoff.md section_schema: the new session heading '${HS_OFFENDER}' does not conform to the chronicle recognizer's session-heading shape (governance/file-type-contracts/handoff.md.json :: section_schema). A non-conforming heading is DROPPED from the per-spoke handoff-chronicle (degrading it to an all-fallback projection). Use one of: '## Session <N> — <title>', '## Session S<N> — <title>', '## Session <YYYY-MM-DD> — <title>', '## Alignment Session <N> — <title>', or a date-prefixed '## <YYYY-MM-DD> — <title>'. Escape hatch: export HANDOFF_SECTION_SCHEMA_OK=1 (logged to hook-audit.log)."
        format_output_deny "PreToolUse" "$HS_REASON"
        exit 0
      fi
    fi
  fi
fi
# === end HCM-3 handoff.md section_schema DENY =============================

# === Plan-artifact frontmatter advisory (R-40) ============================
# R-40 plan-frontmatter type advisory
# Tier 1 advisory per R-35 stage-gated promotion framework.
# Canonical filename-to-type map (mirrors plans-schema.json _filename_map):
#   spec.md              → type: spec
#   tasks.md             → type: tasks
#   handoff.md           → type: handoff
#   00-ideation-brief.md → type: ideation-brief
#   manifest.json        → type: manifest (JSON, not frontmatter — skipped here)
# Scope: only emit R-40 advisory for the 4 canonical Markdown filenames.
# Other .md under ~/.claude-plans/ (research notes, session logs, etc.) pass
# silently through this block.
# R-15 (PLAN→BACKLOG reminder) RETIRED 2026-05-22 per T-15 Tier B:
# vault-root System Backlog.md retired from foundation ship; backlog
# lifecycle now librarian-owned at ~/.claude-plans/_backlog.md per
# governance/plans-rules.json :: root_files (writers_allowed=[librarian];
# generated_by=librarian:backlog-index). Branch #4 (~line 243) enforces
# librarian-only writes to _backlog.md/_archive.md/_index.md.
# Never blocks. Always exit 0 with permissionDecision: allow.
if [[ "$FILE_PATH" == *"/.claude-plans/"*".md" ]]; then
  R40_ADVISORY=""
  PL_CONTENT=""
  PL_BASE=$(basename "$FILE_PATH")
  PL_EXPECTED_TYPE=""
  case "$PL_BASE" in
    spec.md) PL_EXPECTED_TYPE="spec" ;;
    tasks.md) PL_EXPECTED_TYPE="tasks" ;;
    handoff.md) PL_EXPECTED_TYPE="handoff" ;;
    00-ideation-brief.md) PL_EXPECTED_TYPE="ideation-brief" ;;
  esac

  if [[ -n "$PL_EXPECTED_TYPE" ]]; then
    PL_CONTENT=""
    if [[ "$TOOL_NAME" == "Write" ]]; then
      PL_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
    elif [[ "$TOOL_NAME" == "Edit" ]] && [[ -f "$FILE_PATH" ]]; then
      PL_OLD=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')
      PL_NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
      PL_RALL=$(echo "$INPUT" | jq -r '.tool_input.replace_all // false')
      PL_CONTENT=$(python3 - "$FILE_PATH" "$PL_OLD" "$PL_NEW" "$PL_RALL" <<'PYEOF' 2>/dev/null || cat "$FILE_PATH"
import sys
with open(sys.argv[1]) as f:
    c = f.read()
old, new = sys.argv[2], sys.argv[3]
if sys.argv[4] == "true":
    c = c.replace(old, new)
else:
    c = c.replace(old, new, 1)
sys.stdout.write(c)
PYEOF
)
    fi

    if [[ -n "$PL_CONTENT" ]]; then
      # Extract type: from YAML frontmatter (first --- block). Tolerate empty
      # matches (pipefail would otherwise kill the script when the file has
      # no frontmatter or no type: line).
      PL_ACTUAL_TYPE=$(printf '%s\n' "$PL_CONTENT" | awk '/^---[[:space:]]*$/{n++; next} n==1{print} n>=2{exit}' 2>/dev/null | grep -E '^type:[[:space:]]*' 2>/dev/null | head -1 | sed -E 's/^type:[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'\''//; s/'\''$//' 2>/dev/null || true)

      if [[ -z "$PL_ACTUAL_TYPE" ]]; then
        R40_ADVISORY="[R-40 PLAN FRONTMATTER] ${PL_BASE} is missing a canonical type: field in YAML frontmatter. Expected: type: ${PL_EXPECTED_TYPE} (per ~/.claude/schemas/plans-schema.json). Advisory only — this write is allowed. Canonical frontmatter stub: ---/title: ...(name)/type: ${PL_EXPECTED_TYPE}/status: planned|active|complete|draft/created: YYYY-MM-DD/updated: YYYY-MM-DD/---"
      elif [[ "$PL_ACTUAL_TYPE" != "$PL_EXPECTED_TYPE" ]]; then
        R40_ADVISORY="[R-40 PLAN FRONTMATTER] ${PL_BASE} has non-canonical type: '${PL_ACTUAL_TYPE}' in YAML frontmatter. Expected: type: ${PL_EXPECTED_TYPE} (per ~/.claude/schemas/plans-schema.json filename-to-type map). Advisory only — this write is allowed. 5 canonical plan-artifact types: spec, tasks, handoff, ideation-brief, manifest."
      fi

      # --- T-3: spec.md status-line single-enum advisory ----------
      # The **Status:** marker on a spec should resolve to ONE token from
      # lifecycle.status_enum — not a prose paragraph ('s spec encoded
      # ~8 decisions in its status line). Advisory-FIRST per
      # feedback_no_calendar_gates: NEVER deny (a block would retro-fire on the
      # ~80 legacy plans); emit a nudge + an audit-trail line so the
      # advisory->block promotion gate has a false-positive-rate baseline.
      if [[ "$PL_EXPECTED_TYPE" == "spec" ]]; then
        SE_STATUS_VAL=$(printf '%s\n' "$PL_CONTENT" | grep -m1 -E '^\*\*Status:\*\*' | sed -E 's/^\*\*Status:\*\*[[:space:]]*//; s/[[:space:]]*$//')
        if [[ -n "$SE_STATUS_VAL" ]]; then
          # : resolve lifecycle.status_enum from the SHIPPED foundation-master.json
          # bundle slot (.plans.lifecycle.status_enum) via ${CLAUDE_HOME:-$HOME/.claude}.
          # No repo-only-FOUNDATION_REPO-first resolution; the bundle
          # carries the slot adopter-side. $PLANS_RULES_PATH test-override accepted
          # (reads .plans.lifecycle.status_enum then .lifecycle.status_enum so a raw
          # plans-rules.json fixture still resolves). Hardcoded fallback = 8-state.
          SE_ENUM=""
          if [[ -n "${PLANS_RULES_PATH:-}" && -f "${PLANS_RULES_PATH}" ]]; then
            SE_ENUM=$(jq -r '(.plans.lifecycle.status_enum // .lifecycle.status_enum)[]?' "${PLANS_RULES_PATH}" 2>/dev/null || true)
          fi
          if [[ -z "$SE_ENUM" ]]; then
            SE_FOUNDATION="${FOUNDATION_MASTER_PATH:-${CLAUDE_HOME:-$HOME/.claude}/governance/foundation-master.json}"
            [[ -f "$SE_FOUNDATION" ]] && SE_ENUM=$(jq -r '.plans.lifecycle.status_enum[]?' "$SE_FOUNDATION" 2>/dev/null || true)
          fi
          [[ -z "$SE_ENUM" ]] && SE_ENUM=$'researching\nplanned\nin-progress\npaused\ncompleted\nverified\nclosed\nsuperseded\narchived'
          SE_MATCH=0
          while IFS= read -r _tok; do
            [[ -z "$_tok" ]] && continue
            if [[ "$SE_STATUS_VAL" == "$_tok" ]]; then SE_MATCH=1; break; fi
          done <<< "$SE_ENUM"
          if [[ "$SE_MATCH" == "0" ]]; then
            SE_ENUM_CSV=$(printf '%s' "$SE_ENUM" | tr '\n' ',' | sed 's/,$//; s/,/, /g')
            SE_ADVISORY="[R-27 SPEC STATUS ENUM] spec.md **Status:** must be a single lifecycle token, not prose. Found: '${SE_STATUS_VAL}'. Expected one of: ${SE_ENUM_CSV} (governance/plans-rules.json :: lifecycle.status_enum). Move narrative/decisions into decisions/ADR-NN-<slug>.md or the Solution Approach amendment register; keep the status line a single token. Advisory only — this write is allowed; promotion to BLOCK is gated on adoption data (must not retro-deny legacy plans)."
            if [[ -n "$R40_ADVISORY" ]]; then
              R40_ADVISORY="${R40_ADVISORY}\n\n${SE_ADVISORY}"
            else
              R40_ADVISORY="$SE_ADVISORY"
            fi
            # Audit trail for the advisory->block promotion gate (FPR baseline).
            # HOOKS_STATE_OVERRIDE honored for test isolation (mirrors G1; per
            # feedback_test_isolation_for_hooks_state).
            SE_STATE_DIR="${HOOKS_STATE_OVERRIDE:-${HOOKS_STATE:-}}"
            if [[ -n "$SE_STATE_DIR" ]]; then
              SE_AUDIT_FILE="$SE_STATE_DIR/plan-status-enum-advisory-history.jsonl"
              mkdir -p "$SE_STATE_DIR" 2>/dev/null || true
              SE_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
              SE_LINE=$(python3 - "$SE_TS" "$TOOL_NAME" "$FILE_PATH" "$SE_STATUS_VAL" <<'PYEOF' 2>/dev/null || true
import json, sys
ts, tool, path, val = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
sys.stdout.write(json.dumps({"ts": ts, "tool": tool, "file": path, "status_value": val}))
PYEOF
)
              [[ -n "$SE_LINE" ]] && printf '%s\n' "$SE_LINE" >> "$SE_AUDIT_FILE" 2>/dev/null || true
            fi
          fi
        fi
      fi
      # --- end T-3 spec status-enum advisory ----------------------
    fi
  fi

  # R-15 PLAN→BACKLOG reminder RETIRED 2026-05-22 per T-15 Tier B.
  # See block header comment for rationale. Only R-40 advisory remains here.

  if [[ -z "$R40_ADVISORY" ]]; then
    # No advisory — pass through allow.: format_output_allow with empty
    # ctx (adds empty additionalContext; decision/permissionDecision unchanged).
    format_output_allow "PreToolUse" ""
  else
    format_output_allow "PreToolUse" "$R40_ADVISORY"
  fi
  exit 0
fi
# === end R-40 plan-artifact frontmatter advisory ==========================

# --- REMINDER: Skill change protocol + Branch #1 Class D ---
# Runtime skills only (${CLAUDE_HOME:-$HOME/.claude}/skills/<skill>/SKILL.md and
# the foundation-repo authoring location ${FOUNDATION_REPO:-$HOME/Code/brain-stem}/
# skills/<skill>/SKILL.md). Vault paths
# (Skills/*.md design docs and
# .claude/skills/*.md spec mirrors) are not runtime — the skill-change
# checklist is not relevant to them.
# Branch #1 Class D: when the
# SKILL.md ## Output Contract section declares vault writes AND no
# writer-reference file in Vault Writers/ has writer_skill: <slug>, append
# a soft-mandate propose-and-validate fragment suggesting
# `/govern register --kind writer`. Two-layer enforcement (Class D suggests
# at creation time; Branch #3 validates the resulting writer-reference frontmatter).
if [[ "$FILE_PATH" == "${CLAUDE_HOME:-$HOME/.claude}/skills/"*"/SKILL.md" ]] || \
   [[ "$FILE_PATH" == "${FOUNDATION_REPO:-$HOME/Code/brain-stem}/skills/"*"/SKILL.md" ]]; then
  SKILL_CTX="[SKILL CHANGE PROTOCOL] After this edit, complete the mandatory post-change checklist: (1) Save/update memory for the change (2) Update all affected documentation — specs, CLAUDE.md, MEMORY.md (3) Grep for downstream effects — other skills, hooks, settings that reference this (4) Verify ID emission if applicable. This is a blocking step — do not move to the next task until all four are done."

  # --- Class D detection ---
  CLASS_D_CONTENT=""
  if [[ "$TOOL_NAME" == "Write" ]]; then
    CLASS_D_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
  elif [[ "$TOOL_NAME" == "Edit" ]] && [[ -f "$FILE_PATH" ]]; then
    CLASS_D_CONTENT=$(cat "$FILE_PATH" 2>/dev/null || echo "")
  fi
  if [[ -n "$CLASS_D_CONTENT" ]]; then
    # Locate ## Output Contract H2 section; capture body until next H2 or EOF.
    CLASS_D_OUTPUT_CONTRACT=$(printf '%s\n' "$CLASS_D_CONTENT" | awk '/^## Output Contract[[:space:]]*$/{found=1; next} /^## /{if(found){exit}} found{print}')
    if [[ -n "$CLASS_D_OUTPUT_CONTRACT" ]]; then
      # Detect vault-scoped write declarations: paths containing $VAULT_ROOT,
      # ~/Documents/Obsidian Vault, or "Obsidian Vault/" prefix in any write
      # context (write paths, examples, etc.).
      if printf '%s\n' "$CLASS_D_OUTPUT_CONTRACT" | grep -qE '\$VAULT_ROOT/|~/Documents/Obsidian Vault/|Obsidian Vault/'; then
        # Extract skill slug from `name:` frontmatter.
        CLASS_D_SLUG=$(printf '%s\n' "$CLASS_D_CONTENT" | awk '/^---[[:space:]]*$/{n++; next} n==1{print} n>=2{exit}' | grep -E '^name:' | head -1 | sed -E 's/^name:[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'\''//; s/'\''$//' || true)
        if [[ -n "$CLASS_D_SLUG" ]]; then
          # Sweep Vault Writers/*.md frontmatter for writer_skill: <slug> matches.
          CLASS_D_REGISTERED=0
          CLASS_D_VW_DIR="$VAULT_ROOT/Vault Writers"
          if [[ -d "$CLASS_D_VW_DIR" ]]; then
            if grep -qsE "^writer_skill:[[:space:]]*[\"']?${CLASS_D_SLUG}[\"']?[[:space:]]*$" "$CLASS_D_VW_DIR"/*.md 2>/dev/null; then
              CLASS_D_REGISTERED=1
            fi
          fi
          if [[ "$CLASS_D_REGISTERED" -eq 0 ]]; then
            SKILL_CTX="${SKILL_CTX}

[Propose-and-Validate — Branch #1 Class D /] This SKILL.md declares vault writes in its ## Output Contract section but no writer-reference file in Vault Writers/ has writer_skill: '${CLASS_D_SLUG}'. Suggested: run \`/govern register --kind writer --writer-skill ${CLASS_D_SLUG}\` so this skill surfaces in the writer catalog + overlap matrix. Soft-mandate; frictionless skip available — dismiss to proceed unregistered (logged as governance-parity-audit drift)."
          fi
        fi
      fi
    fi
  fi

  format_output_allow "PreToolUse" "$SKILL_CTX"
  exit 0
fi

# --- ADVISORY: MEMORY.md cap rule (T-4 R-59) ---
# Enforces the Anthropic-documented load contract for MEMORY.md: first 200
# lines OR first 25KB loaded at session start; entries past the cap silently
# drop. Per-line >200 chars = drift signal. Advisory only at MVP per
# -default ADVISORY ([[feedback_no_calendar_gates]] volume-driven
# gate; promotion to BLOCK gated on 30d adoption data).
# Schema source: governance/mandatory-files-rules.json#mandates._memory_md_cap.
if [[ "$FILE_PATH" == *"/.claude/projects/"*"/memory/MEMORY.md" ]] && \
   [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]]; then
  MEM_CONTENT=""
  if [[ "$TOOL_NAME" == "Write" ]]; then
    MEM_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
  elif [[ "$TOOL_NAME" == "Edit" ]] && [[ -f "$FILE_PATH" ]]; then
    MEM_OLD=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')
    MEM_NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
    MEM_RALL=$(echo "$INPUT" | jq -r '.tool_input.replace_all // false')
    MEM_CONTENT=$(python3 - "$FILE_PATH" "$MEM_OLD" "$MEM_NEW" "$MEM_RALL" <<'PYEOF' 2>/dev/null || cat "$FILE_PATH"
import sys
with open(sys.argv[1]) as f:
    c = f.read()
old, new = sys.argv[2], sys.argv[3]
if sys.argv[4] == "true":
    c = c.replace(old, new)
else:
    c = c.replace(old, new, 1)
sys.stdout.write(c)
PYEOF
)
  fi
  if [[ -n "$MEM_CONTENT" ]]; then
    MEM_LINES=$(printf '%s\n' "$MEM_CONTENT" | wc -l | tr -d ' ')
    MEM_BYTES=$(printf '%s' "$MEM_CONTENT" | wc -c | tr -d ' ')
    MEM_LONG_LINES=$(printf '%s\n' "$MEM_CONTENT" | awk 'length > 200 {c++} END{print c+0}')
    # : R-59 byte cap from the SHIPPED foundation-master.json slot
    # (.mandatory_files.mandates._memory_md_cap.thresholds.max_bytes) via
    # ${CLAUDE_HOME:-$HOME/.claude} — single-source on adopters. Hardcoded 25600
    # is the fallback only when the slot is absent (harmless: slot value == pillar).
    MEM_BYTE_CAP=25600
    MEM_R59_FOUNDATION="${FOUNDATION_MASTER_PATH:-${CLAUDE_HOME:-$HOME/.claude}/governance/foundation-master.json}"
    if [[ -f "$MEM_R59_FOUNDATION" ]]; then
      MEM_R59_SLOT=$(jq -r '.mandatory_files.mandates._memory_md_cap.thresholds.max_bytes // empty' "$MEM_R59_FOUNDATION" 2>/dev/null || true)
      case "$MEM_R59_SLOT" in
        ''|*[!0-9]*) : ;;  # absent / non-numeric → keep 25600 fallback
        *) MEM_BYTE_CAP="$MEM_R59_SLOT" ;;
      esac
    fi
    MEM_BREACHES=""
    if [[ "$MEM_LINES" -gt 200 ]]; then
      MEM_BREACHES="${MEM_BREACHES}\n- ${MEM_LINES} lines exceeds 200-line cap"
    fi
    if [[ "$MEM_BYTES" -gt "$MEM_BYTE_CAP" ]]; then
      MEM_BREACHES="${MEM_BREACHES}\n- ${MEM_BYTES} bytes exceeds 25KB cap"
    fi
    if [[ "$MEM_LONG_LINES" -gt 0 ]]; then
      MEM_BREACHES="${MEM_BREACHES}\n- ${MEM_LONG_LINES} line(s) exceed 200-char limit"
    fi
    # --- G1 (ordinal_position_check): per-entry below-fold
    # placement sub-check. A vault-pointer-shaped line whose START sits past
    # line 200 OR past MEM_BYTE_CAP (the byte cap governs per) loads
    # invisibly — the harness truncates the index at the fold and the pointer
    # never reaches the model. This is NOT the wc -c total aggregate above; it
    # is a NEW single-pass awk accumulation walking MEM_CONTENT line-by-line,
    # tracking cumulative line count AND byte offset at each line's start
    # (mirrors the MEM_LONG_LINES awk above; bash-3.2-clean — no readarray/
    # mapfile per R-23). The detection predicate is a two-signal AND-gate
    # (the false-positive killer, co-designed with): a line is pointer-shaped
    # iff (a) it is NOT a Markdown-link entry (does not match
    # ^[[:space:]]*[-*][[:space:]]*\[), AND (b) it starts with a bare absolute/
    # tilde path token after an optional list marker
    # (^[[:space:]]*([-*][[:space:]]*)?(~|/Users/|/home/)), AND (c) it contains a
    # word-bounded imperative read verb (Read|Consult|Load|See). Clause (a)
    # excludes every standard "- [filename](memory/..) — ... ~/.." index entry,
    # so the guard does not false-positive on the 10+ live list-link entries that
    # mention ~/ or /Users inside their description text.
    MEM_G1_LINE=$(printf '%s\n' "$MEM_CONTENT" | awk -v cap="$MEM_BYTE_CAP" '
      {
        # byte offset at the START of this line (sum of prior lines + their newlines)
        if (NR > 200 || off > cap) {
          # (a) NOT a Markdown-link entry
          if ($0 !~ /^[ \t]*[-*][ \t]*\[/) {
            # (b) bare absolute/tilde path token after an optional list marker
            if ($0 ~ /^[ \t]*([-*][ \t]*)?(~|\/Users\/|\/home\/)/) {
              # (c) word-bounded imperative read verb
              if ($0 ~ /(^|[^A-Za-z])(Read|Consult|Load|See)([^A-Za-z]|$)/) {
                print NR; exit
              }
            }
          }
        }
        off += length($0) + 1
      }')
    if [[ -n "$MEM_G1_LINE" ]]; then
      MEM_BREACHES="${MEM_BREACHES}\n- a vault-pointer entry starts at line ${MEM_G1_LINE}, past the 200-line/${MEM_BYTE_CAP}-byte fold [POINTER PLACEMENT ADVISORY — G1/R-59]: it loads invisibly — move it above the fold (the TOP of its section)"
    fi
    if [[ -n "$MEM_BREACHES" ]]; then
      format_output_allow "PreToolUse" "[MEMORY.md CAP ADVISORY — R-59] Write to ${FILE_PATH#$HOME/} exceeds Anthropic-documented load contract thresholds:${MEM_BREACHES}\n\nThe harness loads only the first 200 lines OR first 25KB (whichever first) of MEMORY.md at session start (documented at code.claude.com/docs/en/memory). Entries past the cap silently drop from context — the bottom of your index never reaches the model. Remediation: (1) move detail to per-topic files under memory/ and reference via [[wikilinks]] from the index, (2) trim verbose index entries to the ≤200-char one-line-per-entry discipline, (3) keep vault-pointer entries at the TOP of their section so they load above the fold. Per [[feedback_manifests_as_read_replicas]] MEMORY.md is a read-replica/index, not load-bearing curated content. Advisory only — write proceeds; promotion to BLOCK gated on 30-day adoption data."
      exit 0
    fi
  fi
fi

# --- WARNING: Memory file overlap detection + schema validation ---
# Index dir is the memory file's OWN dir (the line-below guard confirms
# FILE_PATH is a .../projects/<slug>/memory/*.md path). Keying-agnostic: works
# for per-project memory dirs and's symlinked shared dir alike.
# T-3: replaces a hardcoded $HOME-slug that only resolved on the symlinked setup.
if [[ "$FILE_PATH" == *"/.claude/projects/"*"/memory/"*".md" ]] && \
   [[ "$(basename "$FILE_PATH")" != "MEMORY.md" ]]; then
  MEMORY_DIR="$(dirname "$FILE_PATH")"

  OVERLAP_MSG=""
  SCHEMA_MSG=""

  # -- Overlap check (all operations) --
  MEMORY_INDEX="$MEMORY_DIR/MEMORY.md"
  NEW_BASE="$(basename "$FILE_PATH" .md)"
  if [[ -f "$MEMORY_INDEX" ]]; then
    KEYWORDS=$(echo "$NEW_BASE" | tr '_' '\n' | grep -v -E '^(user|feedback|project|reference)$' | tr '\n' '|')
    KEYWORDS="${KEYWORDS%|}"
    if [[ -n "$KEYWORDS" ]]; then
      MATCHES=$(grep -iE "$KEYWORDS" "$MEMORY_INDEX" | grep '^\- \[' || true)
      if [[ -n "$MATCHES" ]]; then
        OVERLAP_MSG="[MEMORY OVERLAP CHECK] Writing to memory file: ${NEW_BASE}.md\n\nPotential overlaps with existing memories:\n${MATCHES}\n\nBefore creating a new file, verify this isn't a duplicate. Consider UPDATE (merge into existing) instead of ADD (new file). See librarian memory-hygiene consolidation logic: ADD/UPDATE/DELETE/NOOP."
      fi
    fi
  fi

  # -- Schema validation (Write + Edit operations) --
  # R-45 extends memory-schema coverage from Write-only to Edit ops by
  # reconstructing the post-Edit frontmatter via the python literal-replace
  # pattern (mirrors R-27/R-40 Edit handling). Advisory-first — failed
  # schema still ALLOWs the write, but emits an appended line to the audit
  # trail at $HOOKS_STATE/memory-schema-advisory-history.jsonl so promotion
  # from advisory→blocking has a FPR baseline.
  CONTENT=""
  if [[ "$TOOL_NAME" == "Write" ]]; then
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
  elif [[ "$TOOL_NAME" == "Edit" ]] && [[ -f "$FILE_PATH" ]]; then
    MS_OLD=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')
    MS_NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
    MS_RALL=$(echo "$INPUT" | jq -r '.tool_input.replace_all // false')
    CONTENT=$(python3 - "$FILE_PATH" "$MS_OLD" "$MS_NEW" "$MS_RALL" <<'PYEOF' 2>/dev/null || cat "$FILE_PATH"
import sys
with open(sys.argv[1]) as f:
    c = f.read()
old, new = sys.argv[2], sys.argv[3]
if sys.argv[4] == "true":
    c = c.replace(old, new)
else:
    c = c.replace(old, new, 1)
sys.stdout.write(c)
PYEOF
)
  fi

  if [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]]; then
    if [[ -n "$CONTENT" ]]; then
      # Extract frontmatter (between first pair of --- delimiters)
      FRONTMATTER=$(echo "$CONTENT" | awk '/^---$/{n++; next} n==1{print} n>=2{exit}')
      MISSING=""

      # Check required fields (|| true to prevent pipefail exit on missing fields)
      FM_NAME=$(echo "$FRONTMATTER" | grep -E '^name:' | head -1 | sed 's/^name:[[:space:]]*//' || true)
      FM_DESC=$(echo "$FRONTMATTER" | grep -E '^description:' | head -1 | sed 's/^description:[[:space:]]*//' || true)
      FM_TYPE=$(echo "$FRONTMATTER" | grep -E '^type:' | head -1 | sed 's/^type:[[:space:]]*//' || true)
      # / memory-schema 2.0.0: last_validated is the REQUIRED decay
      # field; last_verified is a legacy READ-ALIAS only (accepted, never required).
      FM_VALIDATED=$(echo "$FRONTMATTER" | grep -E '^last_validated:' | head -1 | sed 's/^last_validated:[[:space:]]*//' || true)
      FM_VERIFIED=$(echo "$FRONTMATTER" | grep -E '^last_verified:' | head -1 | sed 's/^last_verified:[[:space:]]*//' || true)

      [[ -z "$FM_NAME" ]] && MISSING="${MISSING}\n- name: missing (required)"
      [[ -z "$FM_DESC" ]] && MISSING="${MISSING}\n- description: missing (required)"

      # / TRIAD: type validates against the retrieval-axis triad
      # (semantic|episodic|procedural), NOT the filename-prefix provenance set.
      if [[ -z "$FM_TYPE" ]]; then
        MISSING="${MISSING}\n- type: missing (required — use semantic|episodic|procedural)"
      elif ! echo "$FM_TYPE" | grep -qE '^(semantic|episodic|procedural)$'; then
        MISSING="${MISSING}\n- type: invalid value '${FM_TYPE}' (must be semantic|episodic|procedural per triad)"
      fi

      TODAY=$(date +%Y-%m-%d)
      # : require last_validated (last_verified satisfies it as a read-alias
      # during adopter migration). Advisory-only — flags when absent; the actual
      # auto-stamp is hooks/memory-auto-stamp.sh (schema consumer #2).
      FM_VALIDATED_EFFECTIVE="${FM_VALIDATED:-$FM_VERIFIED}"
      if [[ -z "$FM_VALIDATED_EFFECTIVE" ]]; then
        MISSING="${MISSING}\n- last_validated: missing (required — set to today's date: ${TODAY})"
      elif ! echo "$FM_VALIDATED_EFFECTIVE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
        MISSING="${MISSING}\n- last_validated: invalid format '${FM_VALIDATED_EFFECTIVE}' (must be YYYY-MM-DD)"
      fi

      if [[ -n "$MISSING" ]]; then
        SCHEMA_MSG="[MEMORY SCHEMA CHECK] File: $(basename "$FILE_PATH")\nMissing or invalid fields:${MISSING}\n\nMemory file schema (memory-schema.json 2.0.0): name, description, type (semantic|episodic|procedural), tags, created, updated, last_validated"

        # R-45 audit trail — append a JSONL line per advisory hit so the
        # promotion gate has a baseline for FPR computation. Never block.
        MS_AUDIT_FILE="$HOOKS_STATE/memory-schema-advisory-history.jsonl"
        mkdir -p "$HOOKS_STATE" 2>/dev/null || true
        MS_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        MS_AUDIT_LINE=$(python3 - "$MS_TS" "$TOOL_NAME" "$FILE_PATH" "$MISSING" <<'PYEOF' 2>/dev/null || true
import json, sys
ts, tool, path, missing = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
# Strip leading "\n- " separators so the log entry is easier to query.
fields = [m.lstrip("- ").strip() for m in missing.split("\\n") if m.strip()]
sys.stdout.write(json.dumps({
    "ts": ts,
    "tool": tool,
    "file": path,
    "missing_fields": fields,
}))
PYEOF
)
        if [[ -n "$MS_AUDIT_LINE" ]]; then
          printf '%s\n' "$MS_AUDIT_LINE" >> "$MS_AUDIT_FILE" 2>/dev/null || true
        fi
      fi
    fi
  fi

  # -- Emit combined warning if either check produced output --
  if [[ -n "$OVERLAP_MSG" ]] || [[ -n "$SCHEMA_MSG" ]]; then
    COMBINED=""
    [[ -n "$OVERLAP_MSG" ]] && COMBINED="$OVERLAP_MSG"
    if [[ -n "$SCHEMA_MSG" ]]; then
      [[ -n "$COMBINED" ]] && COMBINED="${COMBINED}\n\n"
      COMBINED="${COMBINED}${SCHEMA_MSG}"
    fi
    format_output_allow "PreToolUse" "$COMBINED"
    exit 0
  fi
fi

# T-3 (2026-05-14) — foundation-master.json bundle-at-load
# Single governance read source per hook invocation. Replaces direct reads of:
#   - schemas/vault-schema.json    (DISSOLVED T-4 — types absorbed into pillars)
#   - schemas/gate-config.json     (DISSOLVED T-3 — r32/r47 slices absorbed)
#   - hooks/config/doc-dependencies.json   (canonical now governance/doc-dependencies.json)
#   - governance/{frontmatter,tagging,mandatory-files}-rules.json (pillar JSONs)
# Bundle built by tools/build-foundation-master.sh at foundation-repo release
# time + shipped to ~/.claude/governance/foundation-master.json by install.sh
# (T-8). $FOUNDATION_MASTER_PATH override mirrors $GATE_CONFIG_PATH
# test-isolation contract. Missing bundle → fail-OPEN (same posture as the
# legacy SCHEMA_FILE/GATE_CONFIG missing-file behavior). AC: one file read
# per hook invocation; subsequent slicing via jq <<<"$BUNDLE_JSON".
FOUNDATION_MASTER="${FOUNDATION_MASTER_PATH:-${CLAUDE_HOME:-$HOME/.claude}/governance/foundation-master.json}"
BUNDLE_JSON=""
if [[ -f "$FOUNDATION_MASTER" ]]; then
  BUNDLE_JSON=$(cat "$FOUNDATION_MASTER")
fi

# === Derived shell-var slices (jq on in-memory bundle) =======================
# Variable names preserved (GATE_R32_* / GATE_R47_*) for minimal diff vs the
# pre--T-3 pattern; semantics identical, source flipped to bundle.
GATE_R32_ACCEPTED_TYPES=""
GATE_R32_TYPE_ALIASES=""
GATE_R32_EXEMPT_PATHS=""
GATE_R47_TAG_DIMENSIONS=""
GATE_R47_EXEMPT_PATHS=""
GATE_R47_PREFIX_LIST=""
GATE_R47_PREFIX_REGEX=""
if [[ -n "$BUNDLE_JSON" ]]; then
  # R-32 accepted_types = union of canonical types (.frontmatter.types | keys)
  # + aliases (.frontmatter.r32_type_aliases | keys). Mirrors the
  # gate-config.r32.accepted_types union without duplicating
  # the canonical list. T-6 part-2: migrated from top-level `.types` +
  # `.r32_type_aliases` (legacy denorm slots) to pillar-nested form.
  GATE_R32_ACCEPTED_TYPES=$(jq -r '(.frontmatter.types // {} | keys[]), (.frontmatter.r32_type_aliases // {} | keys[])' <<<"$BUNDLE_JSON" 2>/dev/null | LC_ALL=C sort -u)
  GATE_R32_TYPE_ALIASES=$(jq -r '.frontmatter.r32_type_aliases // {} | to_entries[]? | "\(.key)\t\(.value)"' <<<"$BUNDLE_JSON" 2>/dev/null)
  GATE_R32_EXEMPT_PATHS=$(jq -r '.r32_exempt_paths[]?' <<<"$BUNDLE_JSON" 2>/dev/null)
  GATE_R47_TAG_DIMENSIONS=$(jq -r '.tagging.taxonomy.dimension_prefixes[]?' <<<"$BUNDLE_JSON" 2>/dev/null)
  GATE_R47_EXEMPT_PATHS=$(jq -r '.r47_exempt_paths_composed[]?' <<<"$BUNDLE_JSON" 2>/dev/null)
  # Display + regex strings derived from tag_dimensions (single-source: same
  # prefix grammar drives R-47 advisory AND R-32 Tier 2 tag-conformance DENY).
  GATE_R47_PREFIX_LIST=$(echo "$GATE_R47_TAG_DIMENSIONS" | awk 'NF{printf "#%s/, ", $0}' | sed 's/, $//')
  GATE_R47_PREFIX_REGEX=$(echo "$GATE_R47_TAG_DIMENSIONS" | awk 'NF{printf "%s|", $0}' | sed 's/|$//')
fi

# T-3 retrofit: foundation+overlay union view at TOP LEVEL.
# +-T-1/T-2 confined the helper invocation to the 3-tier vault
# block. T-3 lifts the load here so Branch #1/#2 below can
# consume the same union view without a separate helper round-trip — single
# invocation per hook fire instead of N. Per spec risk row (helper ~50ms
# per call): one call per fire is acceptable; existing in-block load below
# is replaced by a no-op pass-through using $UNION_JSON.
# Helper invoked with --force-override: hook READ for enforcement, not
# overlay WRITE. R-52 write-time DENY is the SINGLE branch WITHOUT
# --force-override (added in T-5 at a narrow file-path scope).
# Helper path resolution mirrors the in-block pattern: $FOUNDATION_OVERLAY_LOAD
# env override for test isolation, else $_HOOK_DIR/../lib/foundation-overlay-load.sh.
# Fall-back to UNION_JSON="$BUNDLE_JSON" if helper unavailable or fails
# (preserves pre-retrofit foundation-only semantics).
_HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd 2>/dev/null || true)
# Helper path resolution: support BOTH foundation-repo layout (lib/ sibling
# of hooks/) AND post-install layout (lib/*.sh shipped INTO hooks/lib/ per
# install.sh Step 3 cp at). Env override takes precedence for test
# isolation. T-3 catches the latent path bug surfaced by Branch
# #1/#2/#3 needing the helper at hook-top time.
_FOUNDATION_OVERLAY_LOAD="${FOUNDATION_OVERLAY_LOAD:-}"
if [[ -z "$_FOUNDATION_OVERLAY_LOAD" ]]; then
  if [[ -x "$_HOOK_DIR/lib/foundation-overlay-load.sh" ]]; then
    _FOUNDATION_OVERLAY_LOAD="$_HOOK_DIR/lib/foundation-overlay-load.sh"
  elif [[ -x "$_HOOK_DIR/../lib/foundation-overlay-load.sh" ]]; then
    _FOUNDATION_OVERLAY_LOAD="$_HOOK_DIR/../lib/foundation-overlay-load.sh"
  fi
fi
UNION_JSON=""
if [[ -n "$_FOUNDATION_OVERLAY_LOAD" ]] && [[ -x "$_FOUNDATION_OVERLAY_LOAD" ]] && [[ -f "$FOUNDATION_MASTER" ]]; then
  UNION_JSON=$("$_FOUNDATION_OVERLAY_LOAD" \
    --foundation-path "$FOUNDATION_MASTER" \
    --overlay-path "${OVERLAY_MASTER_PATH:-${CLAUDE_HOME:-$HOME/.claude}/governance/overlay-master.json}" \
    --force-override 2>/dev/null || true)
fi
if [[ -z "$UNION_JSON" ]]; then
  UNION_JSON="$BUNDLE_JSON"
fi

# DOC-DEPENDENCY REGISTRY CHECK — reads
# from foundation-master.json#doc_dependencies instead of legacy
# ~/.claude/hooks/doc-dependencies.json)
#   - primary / mirror touches → cascade-review reminder
#   - directory-write-constraint violation → deliverable-type soft-warn
# Never denies — librarian session-close Step 2c is the blocking backstop.
# DOC_DEP_CTX is merged into the Tier 1/3 emit below, OR emitted standalone
# at the tail of the hook if no other block fires.
DOC_DEP_CTX=""

if [[ "$VAULT_CONFIGURED" == "1" ]] && [[ -n "$BUNDLE_JSON" ]]; then
  #: VAULT_CONFIGURED gate — the DD_REL derivation below uses
  # "${FILE_PATH#$VAULT_ROOT/}" whose partial self-guard at the next line does
  # NOT fully protect an empty VAULT_ROOT; skip the doc-dependency match block
  # entirely when no vault is configured.
  # Build candidate match keys: vault-relative path + ~-abbreviated absolute path.
  DD_REL="${FILE_PATH#$VAULT_ROOT/}"
  [[ "$DD_REL" == "$FILE_PATH" ]] && DD_REL=""  # non-vault → empty
  if [[ "$FILE_PATH" == "$HOME"/* ]]; then
    DD_HOMEKEY="~/${FILE_PATH#$HOME/}"           # ~/.claude/hooks/... form
  else
    DD_HOMEKEY="$FILE_PATH"
  fi

  # --- Primary / mirror / primary_dir match across BOTH key forms ---
  DEP_MATCH=$(jq -r --arg rel "$DD_REL" --arg abs "$DD_HOMEKEY" '
    .doc_dependencies.entries[]?
    | . as $e
    | select(
        (($rel != "") and (
          (($e.primary // "") == $rel) or
          ((($e.mirrors // []) | map(.file) | index($rel)) != null) or
          ((($e.primary_dir // "") != "") and ($rel | startswith($e.primary_dir)))
        )) or
        (($e.primary // "") == $abs) or
        ((($e.mirrors // []) | map(.file) | index($abs)) != null)
      )
    | "  - \($e.id) [\($e.kind)]: " + (
        if (($e.mirrors // []) | length) > 0 then
          "review mirrors → " + (($e.mirrors // []) | map(.file + " §" + (.section // "(whole)")) | join(", "))
        else
          "canonical source — no mirrors to review"
        end
      )
  ' <<<"$BUNDLE_JSON" 2>/dev/null || true)
  if [[ -n "$DEP_MATCH" ]]; then
    DOC_DEP_CTX="[DOC-DEPENDENCY CASCADE] This write touches a registered documentation dependency:\n${DEP_MATCH}\n\nReview the mirrors in this same session, OR file a waiver via the canonical writer:\n  source ~/.claude/hooks/cascade-waiver.sh && cascade_waiver_write <entry_id> \"<reason>\"\n(Do NOT write cascade-waivers.json directly — drifted shapes have accumulated across 24 sessions. T-1 audit 2026-04-20.)\nLibrarian session-close Step 2c will block otherwise."
  fi
fi

# BRANCHES
# Inserted between doc-dep registry and 3-TIER VAULT SCHEMA per matcher-split
# discipline. Each branch is self-scoped and exits independently when
# its detection class fires. Branches in order: #1 A/B/C (vault propose-and-
# validate) → #2 (historical-data-warning) → #3 (vault-writers-writer-
# reference-only). Branch #4 lives upstream (after R-27); Branch #1 Class D
# lives integrated in the SKILL CHANGE PROTOCOL block above; the DQP block
# + Branch #5 hard-constraints live in pre-asq-guard.sh (AskUserQuestion
# matcher).

# === Branch #1 Classes A/B/C: vault propose-and-validate (T-4) ===
# PAUSE-AND-PROPOSE on:
#   Class A — new top-level folder
#   Class B — new vault-root file
#   Class C — new file-type in existing folder (also catches subfolder
#             semantic divergence per lazy-detection)
# Soft-mandate per [[feedback_soft_mandate_pattern]]; frictionless skip via
# user dismissal. Class D handled at SKILL CHANGE PROTOCOL block above
# (skill-file glob scope).
B1_OVERLAY="${OVERLAY_MASTER_PATH:-${CLAUDE_HOME:-$HOME/.claude}/governance/overlay-master.json}"
B1_FRAGMENT=""

if [[ "$VAULT_CONFIGURED" == "1" ]] && [[ "$FILE_PATH" == "$VAULT_ROOT/"* ]] && [[ "$FILE_PATH" == *.md ]]; then
  B1_REL="${FILE_PATH#$VAULT_ROOT/}"
  B1_TOP=$(echo "$B1_REL" | cut -d'/' -f1)
  B1_DEPTH=$(echo "$B1_REL" | tr -cd '/' | wc -c | tr -d ' ')

  # Class B: vault-root file at depth 0 (no slash separator).
  if [[ "$B1_DEPTH" == "0" ]]; then
    # Foundation-shipped mandatory vault-root files. CLAUDE.md is the only
    # mandatory file per T-13.
    # (System Backlog.md retired from foundation ship per T-15 Tier B
    # 2026-05-22 — backlog lifecycle now librarian-owned at
    # ~/.claude-plans/_backlog.md per governance/plans-rules.json.)
    case "$B1_REL" in
      CLAUDE.md)
        : # known vault-root file; no propose-and-validate
        ;;
      *)
        B1_FRAGMENT="[Propose-and-Validate — Branch #1 Class B /] You are creating a new vault-root file: '${B1_REL}'. The only mandatory vault-root file is CLAUDE.md. New vault-root files register a new semantic extension. Suggested: run \`/govern register --kind file-type --name <type-slug> --contract <path>\` to register a contract for this file, OR dismiss to proceed (logged in governance-action-log as \`unregistered: true\`, proposed_by: hook-class-b; surfaces via librarian governance-parity-audit). Soft-mandate; frictionless skip available."
        ;;
    esac
  fi

  # Class A: new top-level folder (depth ≥ 1).
  if [[ -z "$B1_FRAGMENT" ]] && [[ "$B1_DEPTH" -ge "1" ]]; then
    # Foundation system folders.
    # FIX #1: Work is a foundation system folder (the vault-view
    # of ~/work surfaced by build-brain-vault.sh). A remapped governed Work
    # write (Work/<spoke>/…) must NOT fire the Class A "new top-level folder"
    # advisory — Work/ is a known surface, and spoke registration is handled by
    # /govern register --kind project, not the generic folder-register prompt.
    B1_FOUNDATION_FOLDERS=$'Archive\nPlans\nSkills\nVault Writers\nWork'
    # T-3: augment with foundation+overlay path_routing keys via union
    # view. Single jq pass over UNION_JSON captures BOTH the foundation-side
    # top-level `.path_routing` (legacy denorm slot; retires in T-6) AND the
    # pillar-nested `.frontmatter.path_routing` (overlay-extended path).
    # Replaces the prior 3-source manual union (BUNDLE jq + direct overlay
    # file read) with one helper-mediated read; overlay R-52 enforcement runs
    # through the helper.
    # FIX #2: read the REGISTERED top-level segments from the
    # path_routing RULES, not the metadata KEYS. The pillar-nested shape is
    # `.frontmatter.path_routing.rules[].pattern` (e.g. "Clients/**" → top-level
    # "Clients"); the prior `keys[]?` read metadata keys (`rules`, `_description`,
    # `_rule_shape_contract`) and never the real registered tops — a defect that
    # let a registered cluster STILL fire the Class A advisory. The legacy
    # foundation-side top-level `.path_routing` denorm slot still resolves via
    # its own keys (unchanged; no behavior change against today's empty rules:[]).
    B1_KNOWN_ROUTING=""
    if [[ -n "${UNION_JSON:-}" ]]; then
      B1_KNOWN_ROUTING=$(jq -r '
        (.path_routing // {} | keys[]?),
        (.frontmatter.path_routing.rules // [] | .[]?.pattern // empty | split("/")[0])
      ' <<<"$UNION_JSON" 2>/dev/null || true)
    fi
    B1_KNOWN_TOPS=$(printf '%s\n%s\n' "$B1_FOUNDATION_FOLDERS" "$B1_KNOWN_ROUTING" | LC_ALL=C sort -u)
    if ! printf '%s\n' "$B1_KNOWN_TOPS" | grep -Fxq "$B1_TOP"; then
      B1_FRAGMENT="[Propose-and-Validate — Branch #1 Class A /] You are writing to a new top-level vault folder: '${B1_TOP}/'. Foundation system folders (Vault Writers, Plans, Skills, Archive, Work) + your registered overlay path_routing entries don't include this. Suggested: run \`/govern register --kind folder --target '${B1_TOP}/'\` to register naming/tagging/doc-deps + type-mapping for this cluster, OR dismiss to proceed (logged in governance-action-log as \`unregistered: true\`, proposed_by: hook-class-a; surfaces via librarian governance-parity-audit). Soft-mandate; frictionless skip available."
    fi
  fi

  # Class C: new file-type in existing (known) folder. Only runs on Write
  # ops (Edit ops are mutations of existing files where type: already exists
  # in foundation/overlay or was previously registered).
  if [[ -z "$B1_FRAGMENT" ]] && [[ "$TOOL_NAME" == "Write" ]]; then
    B1_C_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
    if [[ -n "$B1_C_CONTENT" ]]; then
      B1_C_TYPE=$(printf '%s\n' "$B1_C_CONTENT" | awk '/^---[[:space:]]*$/{n++; next} n==1{print} n>=2{exit}' | grep -E '^type:' | head -1 | sed -E 's/^type:[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'\''//; s/'\''$//' || true)
      # T-3: single union-view read covers pillar-nested `.frontmatter.types`
      # (overlay-extended) plus alias keys. T-6 part-2: dropped top-level
      # `.types` + `.r32_type_aliases` reads (legacy denorm slots retired);
      # aliases now read from pillar-nested `.frontmatter.r32_type_aliases`.
      if [[ -n "$B1_C_TYPE" ]] && [[ -n "${UNION_JSON:-}" ]]; then
        B1_KNOWN_TYPES=$(jq -r '
          (.frontmatter.types // {} | keys[]?),
          (.frontmatter.r32_type_aliases // {} | keys[]?)
        ' <<<"$UNION_JSON" 2>/dev/null | LC_ALL=C sort -u)
        if [[ -n "$B1_KNOWN_TYPES" ]] && ! printf '%s\n' "$B1_KNOWN_TYPES" | grep -Fxq "$B1_C_TYPE"; then
          B1_FRAGMENT="[Propose-and-Validate — Branch #1 Class C /] You are creating a file with type: '${B1_C_TYPE}' not in foundation-master.frontmatter.types or overlay-master.frontmatter.types. This declares a new semantic extension. Suggested: run \`/govern register --kind file-type --name ${B1_C_TYPE} --contract <path>\` to author the type contract (frontmatter required/optional + body shape + path_routing if subfolder semantic divergence), OR dismiss to proceed (logged as \`unregistered: true\`, proposed_by: hook-class-c). Soft-mandate; frictionless skip available."
        fi
      fi
    fi
  fi

  if [[ -n "$B1_FRAGMENT" ]]; then
    format_output_allow "PreToolUse" "$B1_FRAGMENT"
    exit 0
  fi
fi
# === end Branch #1 A/B/C =========================================

# === Branch #2: historical-data-warning (T-5;..) ========
# WARNING (not deny) on
# Edit|Write to vault paths whose basename matches a configured date-regex
# pattern AND parsed date is in the past. Detection composes from:
#   - pillar 6: file-type-contracts/<type>.md.json :: historical_data_warning_pattern
#   - pillar 7: vault-writers-rules.json :: historical_data_warning_default
# TZ-aware today: overlay-master.system.timezone (default America/New_York
# per + [[feedback_timezone_edt]]). Future-dated files pass silently
# per.
if [[ "$VAULT_CONFIGURED" == "1" ]] && [[ "$FILE_PATH" == "$VAULT_ROOT/"* ]] && [[ "$FILE_PATH" == *.md ]]; then
  B2_BASENAME=$(basename "$FILE_PATH" .md)
  # T-3: TZ + pillar 7 universal read via union view (replaces direct
  # overlay file read at-and direct vault-writers-rules.json file
  # read at-). Foundation pillar 7 is composed into the bundle at
  # `.vault_writers`; overlay can extend via `.vault_writers.*` per per-leaf
  # merge strategy (T-7). TZ default chain: union .system.timezone → empty
  # → hardcoded "America/New_York" per [[feedback_timezone_edt]] +.
  B2_TZ="America/New_York"
  if [[ -n "${UNION_JSON:-}" ]]; then
    B2_TZ_UNION=$(jq -r '.system.timezone // empty' <<<"$UNION_JSON" 2>/dev/null || true)
    [[ -n "$B2_TZ_UNION" ]] && B2_TZ="$B2_TZ_UNION"
  fi
  B2_TODAY=$(TZ="$B2_TZ" date +%F 2>/dev/null || date +%F)

  # Pillar 7 universal default (slim field per) sourced from
  # union view at .vault_writers.historical_data_warning_default. Foundation-
  # composed pillar always present unless bundle invalid; overlay-extended
  # value (via /govern register --kind writer or equivalent) wins on collision
  # after R-52 helper check.
  B2_UNIVERSAL=""
  if [[ -n "${UNION_JSON:-}" ]]; then
    B2_UNIVERSAL=$(jq -r '.vault_writers.historical_data_warning_default // empty' <<<"$UNION_JSON" 2>/dev/null || true)
  fi

  # Pillar 6 per-type pattern: derive from frontmatter type, look up in
  # file-type-contracts/<type>.md.json. Falls through to universal if no
  # per-type override.
  B2_PATTERN=""
  B2_CONTENT=""
  if [[ "$TOOL_NAME" == "Write" ]]; then
    B2_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
  elif [[ "$TOOL_NAME" == "Edit" ]] && [[ -f "$FILE_PATH" ]]; then
    B2_CONTENT=$(cat "$FILE_PATH" 2>/dev/null || echo "")
  fi
  if [[ -n "$B2_CONTENT" ]]; then
    B2_TYPE=$(printf '%s\n' "$B2_CONTENT" | awk '/^---[[:space:]]*$/{n++; next} n==1{print} n>=2{exit}' | grep -E '^type:' | head -1 | sed -E 's/^type:[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'\''//; s/'\''$//' || true)
    if [[ -n "$B2_TYPE" ]]; then
      B2_CONTRACT="${CLAUDE_HOME:-$HOME/.claude}/governance/file-type-contracts/${B2_TYPE}.md.json"
      if [[ -f "$B2_CONTRACT" ]]; then
        B2_PATTERN=$(jq -r '.historical_data_warning_pattern // empty' "$B2_CONTRACT" 2>/dev/null || true)
      fi
    fi
  fi
  [[ -z "$B2_PATTERN" ]] && B2_PATTERN="$B2_UNIVERSAL"

  if [[ -n "$B2_PATTERN" ]]; then
    if printf '%s\n' "$B2_BASENAME" | grep -qE "$B2_PATTERN"; then
      # Extract leading YYYY-MM-DD date portion if present.
      B2_PARSED_DATE=$(printf '%s\n' "$B2_BASENAME" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
      if [[ -n "$B2_PARSED_DATE" ]] && [[ "$B2_PARSED_DATE" < "$B2_TODAY" ]]; then
        B2_CTX="[Historical Data Warning] This file's basename indicates a past date (${B2_PARSED_DATE} < ${B2_TODAY} in ${B2_TZ}). Are you intentionally modifying historical content? If you're capturing a correction or addendum, consider creating a new dated file referencing the original instead. (Advisory only — write proceeds.) Source pattern: $([ -n "$B2_TYPE" ] && echo "file-type-contracts/${B2_TYPE}.md.json :: historical_data_warning_pattern" || echo "vault-writers-rules.json :: historical_data_warning_default")."
        format_output_allow "PreToolUse" "$B2_CTX"
        exit 0
      fi
    fi
  fi
fi
# === end Branch #2 ================================================

# === Branch #3: vault-writers-writer-reference-only (T-6) ===
# Validates
# Vault Writers/<writer>.md frontmatter against governance/file-type-
# contracts/vault-writer.md.json (pillar 6 SHAPE) + governance/vault-
# writers-rules.json (pillar 7 operational enums). DENY on schema violation.
# Excludes librarian-managed derived artifacts (_index.md / _overlap-matrix.md).
B3_VW_PREFIX="$VAULT_ROOT/Vault Writers/"
if [[ "$VAULT_CONFIGURED" == "1" ]] && [[ "$FILE_PATH" == "$B3_VW_PREFIX"* ]] && [[ "$FILE_PATH" == *.md ]]; then
  B3_BASE=$(basename "$FILE_PATH")
  case "$B3_BASE" in
    _index.md|_overlap-matrix.md)
      : # librarian-owned per vault-writer.md.json :: excluded_paths
      ;;
    *)
      B3_CONTRACT="${CLAUDE_HOME:-$HOME/.claude}/governance/file-type-contracts/vault-writer.md.json"
      # T-3 audit: prior code at this site set B3_RULES to vault-writers-
      # rules.json but never consumed it. Branch #3 validation reads exclusively
      # from B3_CONTRACT (the file-type-contract pillar 6 file); the pillar 7
      # vault_writers content is consumed by Branch #2 above. Dead-var assignment
      # removed; if a future check needs pillar 7 here, read $UNION_JSON.vault_writers.
      if [[ -f "$B3_CONTRACT" ]]; then
        B3_CONTENT=""
        if [[ "$TOOL_NAME" == "Write" ]]; then
          B3_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
        elif [[ "$TOOL_NAME" == "Edit" ]] && [[ -f "$FILE_PATH" ]]; then
          B3_CONTENT=$(cat "$FILE_PATH" 2>/dev/null || echo "")
        fi
        if [[ -n "$B3_CONTENT" ]]; then
          B3_FM=$(printf '%s\n' "$B3_CONTENT" | awk '/^---[[:space:]]*$/{n++; next} n==1{print} n>=2{exit}')
          if [[ -n "$B3_FM" ]]; then
            B3_PROBLEMS=""

            # Required fields per vault-writer.md.json :: frontmatter_required.
            B3_REQUIRED=$(jq -r '.frontmatter_required[]?' "$B3_CONTRACT" 2>/dev/null || true)
            B3_MISSING=""
            while IFS= read -r b3_field; do
              [[ -z "$b3_field" ]] && continue
              if ! printf '%s\n' "$B3_FM" | grep -qE "^${b3_field}:"; then
                B3_MISSING="${B3_MISSING}${b3_field}, "
              fi
            done <<< "$B3_REQUIRED"
            B3_MISSING="${B3_MISSING%, }"
            [[ -n "$B3_MISSING" ]] && B3_PROBLEMS="${B3_PROBLEMS}Missing required: [${B3_MISSING}]. "

            # type enum (must be vault-writer).
            B3_TYPE=$(printf '%s\n' "$B3_FM" | grep -E '^type:' | head -1 | sed -E 's/^type:[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'\''//; s/'\''$//' || true)
            if [[ -n "$B3_TYPE" ]] && [[ "$B3_TYPE" != "vault-writer" ]]; then
              B3_PROBLEMS="${B3_PROBLEMS}type: '${B3_TYPE}' must be 'vault-writer'. "
            fi

            # writer_kind enum.
            B3_KIND=$(printf '%s\n' "$B3_FM" | grep -E '^writer_kind:' | head -1 | sed -E 's/^writer_kind:[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'\''//; s/'\''$//' || true)
            B3_KIND_ENUM=$(jq -r '.frontmatter_enums.writer_kind[]?' "$B3_CONTRACT" 2>/dev/null || true)
            if [[ -n "$B3_KIND" ]] && [[ -n "$B3_KIND_ENUM" ]] && ! printf '%s\n' "$B3_KIND_ENUM" | grep -Fxq "$B3_KIND"; then
              B3_KIND_LIST=$(printf '%s\n' "$B3_KIND_ENUM" | tr '\n' ',' | sed 's/,$//; s/,/, /g')
              B3_PROBLEMS="${B3_PROBLEMS}writer_kind: '${B3_KIND}' not in enum [${B3_KIND_LIST}]. "
            fi

            # status enum.
            B3_STATUS=$(printf '%s\n' "$B3_FM" | grep -E '^status:' | head -1 | sed -E 's/^status:[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'\''//; s/'\''$//' || true)
            B3_STATUS_ENUM=$(jq -r '.frontmatter_enums.status[]?' "$B3_CONTRACT" 2>/dev/null || true)
            if [[ -n "$B3_STATUS" ]] && [[ -n "$B3_STATUS_ENUM" ]] && ! printf '%s\n' "$B3_STATUS_ENUM" | grep -Fxq "$B3_STATUS"; then
              B3_STATUS_LIST=$(printf '%s\n' "$B3_STATUS_ENUM" | tr '\n' ',' | sed 's/,$//; s/,/, /g')
              B3_PROBLEMS="${B3_PROBLEMS}status: '${B3_STATUS}' not in enum [${B3_STATUS_LIST}]. "
            fi

            # Conditional required by writer_kind.
            if [[ -n "$B3_KIND" ]]; then
              B3_COND_REQUIRED=$(jq -r --arg kind "$B3_KIND" '.frontmatter_conditional_by_writer_kind[$kind].required[]?' "$B3_CONTRACT" 2>/dev/null || true)
              B3_COND_MISSING=""
              while IFS= read -r b3_cf; do
                [[ -z "$b3_cf" ]] && continue
                if ! printf '%s\n' "$B3_FM" | grep -qE "^${b3_cf}:"; then
                  B3_COND_MISSING="${B3_COND_MISSING}${b3_cf}, "
                fi
              done <<< "$B3_COND_REQUIRED"
              B3_COND_MISSING="${B3_COND_MISSING%, }"
              [[ -n "$B3_COND_MISSING" ]] && B3_PROBLEMS="${B3_PROBLEMS}Missing for writer_kind=${B3_KIND}: [${B3_COND_MISSING}]. "
            fi

            if [[ -n "$B3_PROBLEMS" ]]; then
              B3_REASON="Vault Writers/ schema violation (Branch #3 /). ${B3_PROBLEMS}Files in Vault Writers/ must be writer reference files conforming to governance/file-type-contracts/vault-writer.md.json. Use \`/govern register --kind writer\` to author new writers, or update frontmatter to match the schema. Excluded paths (_index.md, _overlap-matrix.md) are librarian-managed."
              format_output_deny "PreToolUse" "$B3_REASON"
              exit 0
            fi
          fi
        fi
      fi
      ;;
  esac
fi
# === end Branch #3 ================================================

# 3-TIER VAULT SCHEMA ENFORCEMENT
# Only triggers for files under ~/Documents/Obsidian Vault/
# Tier 1: Auto-fix guidance (additionalContext)
# Tier 2: Block with explanation (DENY)
# Tier 3: Allow with mandatory follow-up warning
# Bundle (foundation-master.json) is the SOLE governance read source per
# T-3 (2026-05-14); R-37 reconciliation entry 5 closed.

if [[ "$VAULT_CONFIGURED" == "1" ]] && [[ "$FILE_PATH" == "$VAULT_ROOT/"* ]] && [[ "$FILE_PATH" == *.md ]]; then

  REL_PATH="${FILE_PATH#$VAULT_ROOT/}"

  # Skip operational files (manifests, coordination, CLAUDE.md, etc.)
  # R-32 exempt_paths sourced from gate-config.json::r32.exempt_paths (T-6).
  R32_EXEMPT=0
  while IFS= read -r _exempt_pattern; do
    [[ -z "$_exempt_pattern" ]] && continue
    if [[ "$REL_PATH" == $_exempt_pattern ]]; then
      R32_EXEMPT=1
      break
    fi
  done <<< "$GATE_R32_EXEMPT_PATHS"

  if [[ $R32_EXEMPT -eq 0 ]] && [[ -n "$BUNDLE_JSON" ]]; then

    # --- Reconstruct file content for frontmatter analysis ---
    CONTENT=""
    if [[ "$TOOL_NAME" == "Write" ]]; then
      CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
    elif [[ "$TOOL_NAME" == "Edit" ]]; then
      # For Edit ops, read existing file and apply the edit to get resulting content
      if [[ -f "$FILE_PATH" ]]; then
        OLD_STR=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')
        NEW_STR=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
        if [[ -n "$OLD_STR" ]]; then
          # Use python for reliable string replacement
          CONTENT=$(python3 -c "
import sys, json
with open(sys.argv[1], 'r') as f:
    content = f.read()
old = json.loads(sys.stdin.read())
content = content.replace(old['old'], old['new'], 1)
print(content, end='')
" "$FILE_PATH" <<< "$(jq -n --arg old "$OLD_STR" --arg new "$NEW_STR" '{old: $old, new: $new}')" 2>/dev/null || true)
        fi
        # If replacement failed or no old_string, fall back to existing file
        if [[ -z "$CONTENT" ]] && [[ -f "$FILE_PATH" ]]; then
          CONTENT=$(cat "$FILE_PATH")
        fi
      fi
    fi

    if [[ -n "$CONTENT" ]]; then
      # Extract frontmatter between --- delimiters
      FRONTMATTER=$(echo "$CONTENT" | awk '/^---$/{c++;next} c==1{print} c>=2{exit}')

      if [[ -n "$FRONTMATTER" ]]; then
        TIER1_MSGS=""
        TIER2_MSGS=""
        TIER3_MSGS=""
        TODAY=$(date +%Y-%m-%d)

        # --- Helper: extract a frontmatter field value ---
        fm_val() {
          echo "$FRONTMATTER" | grep -E "^${1}:" | head -1 | sed "s/^${1}:[[:space:]]*//" || true
        }

        # --- Helper: check if a frontmatter field key exists (handles list-style fields) ---
        fm_has() {
          echo "$FRONTMATTER" | grep -qE "^${1}:" && return 0 || return 1
        }

        # --- Determine file type from frontmatter or path ---
        FM_TYPE=$(fm_val "type")
        SCHEMA_KEY=""

        # Map type → schema key (R-32, gate-config.json::r32, T-6).
        # Aliases override (5 entries: skill-spec, overview, updates, file-index,
        # tier-2 → canonical schema keys per gate-config.json::r32.type_aliases).
        # Other accepted_types map to themselves; unknown types yield empty
        # SCHEMA_KEY and fall through to path inference below.
        if [[ -n "$FM_TYPE" ]]; then
          _alias_target=$(echo "$GATE_R32_TYPE_ALIASES" | awk -F'\t' -v t="$FM_TYPE" '$1 == t {print $2; exit}')
          if [[ -n "$_alias_target" ]]; then
            SCHEMA_KEY="$_alias_target"
          elif echo "$GATE_R32_ACCEPTED_TYPES" | grep -Fxq "$FM_TYPE"; then
            SCHEMA_KEY="$FM_TYPE"
          fi
        fi

        # Path-inference fallback intentionally not declared here — operator-private
        # folder conventions (Daily/, People/, Engagements/) are adopter-specific and
        # land via overlay-master.frontmatter.path_routing.rules[] at /adopt time,
        # not as hardcoded foundation defaults.

        # T-3 retrofit: foundation+overlay union view for R-32 type-DENY.
        # T-3 lifted helper invocation to top-level (single-load per
        # hook fire); this block now derives R-32-specific accepted-types
        # from the already-loaded $UNION_JSON. Fall-back to foundation-only
        # allowlist if UNION_JSON degenerated to BUNDLE_JSON (helper missing).
        R32_UNION_ACCEPTED_TYPES=""
        if [[ -n "$UNION_JSON" ]]; then
          # T-6 part-2: alias keys now read from pillar-nested
          # `.frontmatter.r32_type_aliases` (was top-level `.r32_type_aliases`).
          R32_UNION_ACCEPTED_TYPES=$(jq -r \
            '(.frontmatter.types // {} | keys[]?), (.frontmatter.r32_type_aliases // {} | keys[]?)' \
            <<<"$UNION_JSON" 2>/dev/null \
            | grep -v '^_description$' \
            | LC_ALL=C sort -u)
        fi
        # Fall-back: union derivation empty → foundation-only allowlist
        # (bug stays present; matches pre-behavior).
        if [[ -z "$R32_UNION_ACCEPTED_TYPES" ]]; then
          R32_UNION_ACCEPTED_TYPES="$GATE_R32_ACCEPTED_TYPES"
        fi

        # T-1 retrofit: foundation+overlay union view for R-32 TAXONOMY
        # tag-prefix DENY (Tier 2 at the tag-conformance check below). Mirrors
        # the R-32 TYPE-allowlist single-load + variable-hold pattern.
        # Derives R32_TAXONOMY_UNION_PREFIXES from union .tagging.taxonomy.
        # dimension_prefixes; composes regex + list mirroring the foundation-
        # only derivation at-. Fall-back to foundation-only regex
        # if UNION_JSON empty (preserves pre-retrofit behavior).
        # Closes Surprise #3 (scope packet): packet 06 reproduction
        # targets this branch but retargeted to R-32 TYPE-allowlist.
        R32_TAXONOMY_UNION_PREFIXES=""
        R32_TAXONOMY_UNION_LIST=""
        R32_TAXONOMY_UNION_REGEX=""
        if [[ -n "$UNION_JSON" ]]; then
          R32_TAXONOMY_UNION_PREFIXES=$(jq -r '.tagging.taxonomy.dimension_prefixes[]?' <<<"$UNION_JSON" 2>/dev/null)
          if [[ -n "$R32_TAXONOMY_UNION_PREFIXES" ]]; then
            R32_TAXONOMY_UNION_LIST=$(echo "$R32_TAXONOMY_UNION_PREFIXES" | awk 'NF{printf "#%s/, ", $0}' | sed 's/, $//')
            R32_TAXONOMY_UNION_REGEX=$(echo "$R32_TAXONOMY_UNION_PREFIXES" | awk 'NF{printf "%s|", $0}' | sed 's/|$//')
          fi
        fi
        # Fall-back: helper unavailable → foundation-only regex/list
        if [[ -z "$R32_TAXONOMY_UNION_REGEX" ]]; then
          R32_TAXONOMY_UNION_REGEX="$GATE_R47_PREFIX_REGEX"
          R32_TAXONOMY_UNION_LIST="$GATE_R47_PREFIX_LIST"
        fi

        # T-2 retrofit: foundation+overlay union view for R-47 advisory
        # (Tier 1 tag-presence soft-warn below). Mechanical mirror of the
        # T-1 pattern at this same scope. Derives union-side variants of the
        # GATE_R47_EXEMPT_PATHS (consumer: exemption walk at the R-47 branch)
        # and GATE_R47_PREFIX_LIST (consumer: advisory message string only;
        # union REGEX already produced as R32_TAXONOMY_UNION_REGEX above and
        # is reused by R-47 advisory wording via R32_TAXONOMY_UNION_LIST).
        # Fall-back to foundation-only vars if UNION_JSON empty.
        R47_UNION_EXEMPT_PATHS=""
        if [[ -n "$UNION_JSON" ]]; then
          R47_UNION_EXEMPT_PATHS=$(jq -r '.r47_exempt_paths_composed[]?' <<<"$UNION_JSON" 2>/dev/null)
        fi
        if [[ -z "$R47_UNION_EXEMPT_PATHS" ]]; then
          R47_UNION_EXEMPT_PATHS="$GATE_R47_EXEMPT_PATHS"
        fi

        # R-32 RETIRED TYPES — Tier 2 DENY with specific replacement guidance
        # Pre-fix, hooks/config/gate-config.json
        # silently listed `engagement` + `project` in r32.accepted_types — drift
        # from governance/frontmatter-rules.json#retired_types canonical state.
        # Bundle correctly excludes retired types from R-32 allowlist; this
        # check emits a specific deny message with replacement guidance from
        # frontmatter-rules.json#retired_types[<type>].replacement, BEFORE the
        # generic UNKNOWN TYPE check below (avoids misleading "add to types"
        # error for types that are explicitly retired).
        # T-3: reads from UNION_JSON (foundation+overlay union) so an
        # adopter overlay can declare additional retired types via /govern
        # register. Foundation-only fallback preserved if helper unavailable.
        FM_TYPE_RETIRED="false"
        if [[ -n "$FM_TYPE" ]] && [[ -n "$UNION_JSON" ]]; then
          RETIRED_REPLACEMENT=$(jq -r --arg t "$FM_TYPE" '.frontmatter.retired_types[$t].replacement // empty' <<<"$UNION_JSON" 2>/dev/null)
          if [[ -n "$RETIRED_REPLACEMENT" ]]; then
            TIER2_MSGS="${TIER2_MSGS}[R-32 RETIRED TYPE] type: '${FM_TYPE}' is retired per governance/frontmatter-rules.json#retired_types. Replacement guidance: ${RETIRED_REPLACEMENT}\n"
            FM_TYPE_RETIRED="true"
          fi
        fi

        # R-32 — TYPE ALLOWLIST (Tier 2 DENY)
        # Promoted from Tier 1 warning to Tier 2 blocking.
        # Allowlist sourced from
        # foundation-master.json#types | keys UNION
        # foundation-master.json#r32_type_aliases | keys (since
        # T-3, 2026-05-14). The accepted set is the live data-driven union. Adding a type touches
        # the R-37 coupled-surface set (governance/frontmatter-rules.json#types
        # + pre-write-guard.sh + post-write-verify.sh + vault CLAUDE.md);
        # foundation-master.json regenerates via tools/build-foundation-master.sh.
        # Empty bundle → DENY skipped (fail-OPEN, same posture as missing bundle).
        # FM_TYPE_RETIRED guard avoids double-DENY when retired-type message
        # already fired above (better UX: user sees the retired-specific deny).
        # T-3: reads R32_UNION_ACCEPTED_TYPES (foundation+overlay union)
        # via lib/foundation-overlay-load.sh so /govern register-time type
        # extensions land in the allowlist. Closes union-read enforcement
        # gap for this branch; generalizes to other branches.
        if [[ -n "$FM_TYPE" ]] && [[ -n "$R32_UNION_ACCEPTED_TYPES" ]] && [[ "$FM_TYPE_RETIRED" != "true" ]]; then
          if ! echo "$R32_UNION_ACCEPTED_TYPES" | grep -Fxq "$FM_TYPE"; then
            TIER2_MSGS="${TIER2_MSGS}[R-32 UNKNOWN TYPE] type: '${FM_TYPE}' is not in the canonical type allowlist. To add a new type: (1) update governance/frontmatter-rules.json#types with required fields, (2) add case entry in pre-write-guard.sh, (3) add to post-write-verify.sh type_map, (4) document in vault CLAUDE.md, (5) rebuild bundle via tools/build-foundation-master.sh — bundle as R-37 lockstep commit.\n"
          fi
        fi

        # TIER 1 — Auto-fix guidance (additionalContext, always ALLOW)

        # Check for missing 'updated' field — gated on schema's required list
        # for the target type (source of truth). Types whose schema does not
        # declare 'updated' (log, inbox-archive, daily-archive, weekly-summary,
        # daily-note, engagement, project, briefing, archive) are exempted.
        # If SCHEMA_KEY is empty (unknown type + no path match) the advisory
        # is skipped — R-32 DENY + required-field check already catch the
        # upstream cases.
        if ! fm_has "updated"; then
          UPDATED_IN_SCHEMA=""
          if [[ -n "$SCHEMA_KEY" ]]; then
            UPDATED_IN_SCHEMA=$(jq -r --arg key "$SCHEMA_KEY" '.frontmatter.types[$key].required // [] | .[] | select(. == "updated")' <<<"$BUNDLE_JSON" 2>/dev/null)
          fi
          if [[ -n "$UPDATED_IN_SCHEMA" ]]; then
            TIER1_MSGS="${TIER1_MSGS}Vault write needs 'updated: ${TODAY}' in frontmatter. Add it before writing.\n"
          fi
        fi

        # --- R-33: Folder placement advisory (Tier 1, never blocks) ---
        # T-2 (2026-05-21): data-driven via UNION_JSON. Reads expected_path
        # patterns from $UNION_JSON.frontmatter.types[$FM_TYPE].expected_path
        # (foundation seed + adopter overlay). Types without expected_path
        # (14 of 21 in foundation seed: briefing, context, index, navigation,
        # reference, strategic, planning, archive, personal-initiative, prd,
        # archetype-template, historical-brief, ideation-brief, packet) skip
        # the advisory — placement varies by engagement and scope. Behavior
        # mirrors prior hardcoded case statement on the 7 seeded types
        # (daily-note, people, log, weekly-summary, daily-archive,
        # inbox-archive, meeting-note). Adopters extend by declaring
        # additional types with expected_path via overlay-master.json.
        # SCHEMA_KEY gate intentionally dropped: SCHEMA_KEY is foundation-only
        # (built from GATE_R32_ACCEPTED_TYPES at, BUNDLE_JSON-sourced),
        # so an overlay-only type would have empty SCHEMA_KEY and never fire
        # R-33 even when it carries expected_path via union. The union-side
        # presence of expected_path itself is the sufficient signal — types
        # without it fall through harmlessly via the empty-R33_PATTERNS check.
        if [[ -n "$FM_TYPE" ]] && [[ -n "${UNION_JSON:-}" ]]; then
          R33_PATTERNS=$(jq -r --arg key "$FM_TYPE" '.frontmatter.types[$key].expected_path // [] | .[]? | "\(.pattern)\t\(.label)"' <<<"$UNION_JSON" 2>/dev/null)
          if [[ -n "$R33_PATTERNS" ]]; then
            R33_MATCHED=0
            R33_LABELS=""
            while IFS=$'\t' read -r r33_pat r33_label; do
              [[ -z "$r33_pat" ]] && continue
              # Bash glob match — unquoted RHS for pattern expansion.
              if [[ "$REL_PATH" == $r33_pat ]]; then
                R33_MATCHED=1
                break
              fi
              if [[ -n "$R33_LABELS" ]]; then
                R33_LABELS="$R33_LABELS or $r33_label"
              else
                R33_LABELS="$r33_label"
              fi
            done <<<"$R33_PATTERNS"
            if [[ "$R33_MATCHED" = "0" ]] && [[ -n "$R33_LABELS" ]]; then
              TIER1_MSGS="${TIER1_MSGS}[R-33 FOLDER PLACEMENT] File type '${FM_TYPE}' is typically placed under '${R33_LABELS}'. Current path: '${REL_PATH}'. If this is intentional (engagement-specific exception, cross-reference, etc.), ignore this advisory. Otherwise, move before writing.\n"
            fi
          fi
        fi

        # Extract tags for Tier 2 validation — handles both YAML forms:
        #   block:  tags:\n  - foo\n  - bar
        #   inline: tags: [foo, bar]
        # Post-validation fix 2026-04-21: inline form was previously treated as
        # empty, causing R-47 false positives on files using `tags: [log/...]`.
        TAGS_BLOCK=$(echo "$FRONTMATTER" | awk '/^tags:[[:space:]]*$/{found=1;next} found && /^  - /{print; next} found{exit}')
        TAGS_INLINE_CONTENT=""
        if echo "$FRONTMATTER" | grep -qE '^tags:[[:space:]]*\['; then
          TAGS_INLINE_CONTENT=$(echo "$FRONTMATTER" | grep -E '^tags:[[:space:]]*\[' | head -1 | sed -E 's/^tags:[[:space:]]*\[[[:space:]]*//; s/[[:space:]]*\].*//')
        fi
        TAGS_RAW="${TAGS_INLINE_CONTENT}${TAGS_BLOCK}"

        # --- R-47: Tag-presence advisory (Tier 1, never blocks) ---
        # Complement to R-32 tag-prefix DENY: soft-warn when non-exempt vault
        # write has missing or empty tags. Graph-view diagnostic per
        # feedback_tags_as_validity_diagnostic — orphan files surface as
        # enforcement alerts. Observation gate 2026-05-19.
        # POSITIVE-LIST SEMANTICS (T-3, 2026-04-22):
        # Exempt paths are enumerated explicitly below. Future top-level folder
        # additions MUST either (a) add a path pattern here or (b) rely on
        # schema-level `tags` required-field enforcement (R-32) — see CLAUDE.md
        # §Tagging Taxonomy opt-in notes. Unenumerated paths DEFAULT to the
        # advisory, surfacing orphans as drift findings.
        # R-47 exempt_paths sourced from gate-config.json::r47.exempt_paths (T-6).
        # Positive-list semantics (T-3, 2026-04-22): unenumerated
        # paths default to advisory. Patterns are vault-relative globs.
        # T-2: consumes union-derived R47_UNION_EXEMPT_PATHS so adopter
        # /govern register additions land in the exempt-path set; advisory
        # wording sources R32_TAXONOMY_UNION_LIST (union prefix list emitted
        # by the T-1 block above) for consistent overlay-aware text.
        R47_EXEMPT=0
        while IFS= read -r _r47_pattern; do
          [[ -z "$_r47_pattern" ]] && continue
          if [[ "$REL_PATH" == $_r47_pattern ]]; then
            R47_EXEMPT=1
            break
          fi
        done <<< "$R47_UNION_EXEMPT_PATHS"
        if [[ $R47_EXEMPT -eq 0 ]] && [[ -n "$FRONTMATTER" ]] && [[ -z "$TAGS_RAW" ]]; then
          R47_KIND="missing"
          if echo "$FRONTMATTER" | grep -q '^tags:'; then
            R47_KIND="empty"
          fi
          TIER1_MSGS="${TIER1_MSGS}[R-47 TAG PRESENCE] File at '${REL_PATH}' has ${R47_KIND} tags. Add tags per the taxonomy in CLAUDE.md §Tagging Taxonomy (${R32_TAXONOMY_UNION_LIST}). Tags are load-bearing for graph-view health and cross-folder retrieval. Advisory only — not blocking.\n"
        fi

        # --- R-48: Wikilink write-time advisory (Tier 1, never blocks) ---
        # Sub-plan 05 T-2 (2026-04-21). Vault-scoped (already gated by
        # outer REL_PATH checks). Scans CONTENT for [[target]] and [[target|alias]]
        # patterns; emits advisory when target doesn't resolve to a file in the
        # vault. Complements T-6 wikilink-repair.sh (post-hoc capability)
        # with write-time feedback. Observation gate 2026-05-19.
        if [[ -n "$CONTENT" ]]; then
          R48_TMP=$(mktemp -t r48content.XXXXXX)
          printf '%s' "$CONTENT" > "$R48_TMP"
          R48_BROKEN=$(python3 - "$VAULT_ROOT" "$R48_TMP" "${PLANS_DIR:-}" <<'PYEOF' 2>/dev/null || true
import sys, os, re

vault_root = sys.argv[1]
# R-48 resolution: the library + binder surfaces (_library/, _projects/)
# live under the plans root and are reached from the vault only via the Plans/
# symlink. os.walk(vault_root) uses the Python default followlinks=False, so it
# does NOT descend the Plans/-symlinked tree (verified empirically). Rather than
# enable followlinks=True vault-wide — which would chase EVERY symlink (the
# _projects/<spoke>/research/<plan-slug>/ dir-symlink farm points back into the
# plans tree; os.walk has no symlink-loop protection and would hang on a user
# vault) — index the two REAL surface homes DIRECTLY with followlinks=False. This
# makes library articles + binder files resolvable to the wikilink-existence check
# without unleashing the symlink-loop hazard. (Resolution (b).)
plans_dir = sys.argv[3] if len(sys.argv) > 3 else ""
extra_roots = []
if plans_dir:
    for sub in ("_library", "_projects"):
        p = os.path.join(plans_dir, sub)
        if os.path.isdir(p):
            extra_roots.append(p)
with open(sys.argv[2]) as f:
    content = f.read()

# Strip fenced code blocks and inline code spans before scanning. Wikilinks
# documented in code (remediation packets, audit reports) are examples, not
# real links — they were the dominant R-48 false-positive class.
content = re.sub(r'```[\s\S]*?```', '', content)
content = re.sub(r'~~~[\s\S]*?~~~', '', content)
content = re.sub(r'``[^`\n]+``', '', content)
content = re.sub(r'`[^`\n]+`', '', content)

# Extract [[target]] or [[target|alias]] — skip embedded images/transclusions ![[...]]
pattern = re.compile(r'(?<!\!)\[\[([^\]|#]+?)(?:\|[^\]]*)?(?:#[^\]]*)?\]\]')
targets = set()
for m in pattern.finditer(content):
    t = m.group(1).strip()
    if t and not t.startswith('http'):
        targets.add(t)

if not targets:
    sys.exit(0)

# Build a lightweight index of vault basenames (case-insensitive) and full rel paths.
# Walk vault_root with the Python default followlinks=False (Plans/ symlink NOT
# descended), then additionally index the real _library/_projects homes directly
# (also followlinks=False) so library/binder wikilink targets resolve.
existing_basenames = set()
existing_paths = set()
def _index(walk_root, rel_base):
    for dirpath, dirnames, filenames in os.walk(walk_root):
        dirnames[:] = [d for d in dirnames if not d.startswith('.') and d not in ('_test',)]
        for fn in filenames:
            if fn.endswith('.md'):
                existing_basenames.add(fn[:-3].lower())
                existing_basenames.add(fn.lower())
            rel = os.path.relpath(os.path.join(dirpath, fn), rel_base)
            existing_paths.add(rel.lower())
            if rel.endswith('.md'):
                existing_paths.add(rel[:-3].lower())
_index(vault_root, vault_root)
for r in extra_roots:
    # rel paths are computed against the surface home's PARENT so wikilink forms
    # like [[_library/topic/article]] resolve against the indexed rel path.
    _index(r, os.path.dirname(r))

broken = []
for t in sorted(targets):
    tn = t.lower()
    # Try direct match: basename, basename.md, rel path, rel path.md
    if tn in existing_basenames:
        continue
    if tn in existing_paths:
        continue
    # Strip any trailing slashes
    tn_stripped = tn.rstrip('/')
    if tn_stripped in existing_basenames or tn_stripped in existing_paths:
        continue
    broken.append(t)

if broken:
    print(",".join(broken[:5]))  # cap at 5 for advisory brevity
PYEOF
)
          rm -f "$R48_TMP" 2>/dev/null || true
          if [[ -n "$R48_BROKEN" ]]; then
            TIER1_MSGS="${TIER1_MSGS}[R-48 BROKEN WIKILINK] File at '${REL_PATH}' contains wikilink(s) to non-existent target(s): ${R48_BROKEN}. Advisory only — not blocking. Run /librarian (wikilink-repair capability) or create the target file if intended.\n"
          fi
        fi

        # TIER 2 — Block with explanation (DENY)

        # Check required fields from schema
        if [[ -n "$SCHEMA_KEY" ]]; then
          REQUIRED_FIELDS=$(jq -r --arg key "$SCHEMA_KEY" '.frontmatter.types[$key].required // [] | .[]' <<<"$BUNDLE_JSON" 2>/dev/null)
          if [[ -n "$REQUIRED_FIELDS" ]]; then
            MISSING_FIELDS=""
            COHORT_SOFT_MISSING=""
            while IFS= read -r field; do
              if ! fm_has "$field"; then
                # Soft-tier cohort fields WARN at Tier 1, never hard-block (R-64 / T-5).
                # 'updated' keeps its pre-existing silent Tier-1 carve-out; the four new
                # cohort fields (created/description/id/schema_version) join it in the
                # non-block set and surface a single Tier-1 advisory below.
                case "$field" in
                  updated) : ;;
                  created|description|id|schema_version)
                    COHORT_SOFT_MISSING="${COHORT_SOFT_MISSING}${field}, " ;;
                  *)
                    MISSING_FIELDS="${MISSING_FIELDS}${field}, " ;;
                esac
              fi
            done <<< "$REQUIRED_FIELDS"
            MISSING_FIELDS="${MISSING_FIELDS%, }"
            if [[ -n "$MISSING_FIELDS" ]]; then
              TIER2_MSGS="${TIER2_MSGS}Missing required fields [${MISSING_FIELDS}] for file type '${SCHEMA_KEY}'.\n"
            fi
            COHORT_SOFT_MISSING="${COHORT_SOFT_MISSING%, }"
            if [[ -n "$COHORT_SOFT_MISSING" ]]; then
              TIER1_MSGS="${TIER1_MSGS}[R-64 COHORT FIELD] File type '${SCHEMA_KEY}' is missing soft-tier cohort field(s): ${COHORT_SOFT_MISSING}. These WARN but do not block — forward-governance auto-stamp and the frontmatter-enforce --fix backfill populate created/description/id/schema_version; add them manually or run the fixer. Advisory only — not blocking.\n"
            fi
          fi

          # Check conditional_required fields (R-37 lockstep with schema #types.index + governance/file-type-contracts/_index.md.json).
          # Schema shape: .[$key].conditional_required = { "<field>": { "condition": "path_depth >= N", ... } }
          # Currently only one condition kind supported: "path_depth >= N" — REL_PATH segment count.
          # Extensible: future condition kinds register here without schema-shape changes.
          CONDITIONAL_FIELDS=$(jq -r --arg key "$SCHEMA_KEY" '.frontmatter.types[$key].conditional_required // {} | to_entries[] | "\(.key)|\(.value.condition // "")"' <<<"$BUNDLE_JSON" 2>/dev/null)
          if [[ -n "$CONDITIONAL_FIELDS" ]]; then
            COND_PATH_DEPTH=$(echo "$REL_PATH" | tr -cd '/' | wc -c | tr -d ' ')
            COND_MISSING=""
            while IFS='|' read -r cf_field cf_cond; do
              [[ -z "$cf_field" ]] && continue
              cf_condition_met=false
              if [[ "$cf_cond" =~ ^path_depth[[:space:]]+\>=[[:space:]]+([0-9]+)$ ]]; then
                cf_threshold="${BASH_REMATCH[1]}"
                if [[ "$COND_PATH_DEPTH" -ge "$cf_threshold" ]]; then
                  cf_condition_met=true
                fi
              fi
              if [[ "$cf_condition_met" == "true" ]] && ! fm_has "$cf_field"; then
                COND_MISSING="${COND_MISSING}${cf_field} (${cf_cond}), "
              fi
            done <<< "$CONDITIONAL_FIELDS"
            COND_MISSING="${COND_MISSING%, }"
            if [[ -n "$COND_MISSING" ]]; then
              TIER2_MSGS="${TIER2_MSGS}Missing conditional_required fields [${COND_MISSING}] for file type '${SCHEMA_KEY}' at path '${REL_PATH}'.\n"
            fi
          fi
        fi

        # --- R-64 property-type format-regex validation (Tier 1 advisory) -------
        # Read the value-type declarations from the bundle (.frontmatter.property_types,
        # minted T-2) and validate any PRESENT cohort value against its declared type
        # (date/list/id-slug/int). WARN-only — never DENY (the value is present, only
        # mis-typed); this is the enforceable value-typing layer (the seeded
        # .obsidian/types.json is UX-only). Absent property_types (a pre-R1 master that
        # has not yet re-composed the pillar) → PROP_TYPES is empty and the loop body
        # never runs (graceful no-op). Mirrors the R-40 Tier-1 advisory emitter shape.
        PROP_TYPES=$(jq -r '.frontmatter.property_types // {} | to_entries[]? | select((.key|startswith("_"))|not) | "\(.key)\t\(.value)"' <<<"$BUNDLE_JSON" 2>/dev/null)
        if [[ -n "$PROP_TYPES" ]]; then
          while IFS=$'\t' read -r pt_field pt_type; do
            [[ -z "$pt_field" ]] && continue
            fm_has "$pt_field" || continue
            pt_val=$(fm_val "$pt_field")
            pt_val="${pt_val%\"}"; pt_val="${pt_val#\"}"
            pt_val="${pt_val%\'}"; pt_val="${pt_val#\'}"
            pt_bad=""
            case "$pt_type" in
              date)
                if [[ -n "$pt_val" ]] && ! [[ "$pt_val" =~ ^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]([T\ ][0-9].*)?$ ]]; then
                  pt_bad="expected a date (YYYY-MM-DD)"; fi ;;
              int)
                if [[ -n "$pt_val" ]] && ! [[ "$pt_val" =~ ^[0-9]+$ ]]; then
                  pt_bad="expected an integer"; fi ;;
              slug-string)
                if [[ -n "$pt_val" ]] && ! [[ "$pt_val" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
                  pt_bad="expected a slug (lowercase, dash-separated)"; fi ;;
              list)
                # inline non-empty value must be a [..] sequence; empty inline = a
                # block-style YAML list (valid) — fm_val returns empty for block lists.
                if [[ -n "$pt_val" ]] && [[ "${pt_val:0:1}" != "[" ]]; then
                  pt_bad="expected a list (YAML sequence)"; fi ;;
            esac
            if [[ -n "$pt_bad" ]]; then
              TIER1_MSGS="${TIER1_MSGS}[R-64 PROPERTY TYPE] Field '${pt_field}: ${pt_val}' — ${pt_bad} (property_types: ${pt_type}). Advisory only — not blocking.\n"
            fi
          done <<< "$PROP_TYPES"
        fi

        # Check tags conform to taxonomy prefixes (hard block if clearly wrong).
        # Prefix grammar single-sourced from gate-config.json::r47.tag_dimensions
        # per gate-config _tag_dimensions_note (T-6, 2026-05-08): same array
        # drives R-47 advisory above AND this Tier 2 R-32 tag-conformance DENY.
        # Empty config → DENY skipped (fail-OPEN, matches R-32 type-allowlist).
        # T-1: consumes union-derived R32_TAXONOMY_UNION_REGEX (foundation
        # + overlay deep-merge) so adopter /govern register --kind tag-extension
        # registrations land in the allowlist. Closes union-read enforcement
        # gap (Surprise #3) for this branch.
        if [[ -n "$TAGS_RAW" ]] && [[ -n "$R32_TAXONOMY_UNION_REGEX" ]]; then
          INVENTED_TAGS=$(echo "$TAGS_RAW" | sed 's/^  - //' | sed 's/^"//' | sed 's/"$//' | grep -E '^#' | grep -v -E "^#(${R32_TAXONOMY_UNION_REGEX})/" || true)
          if [[ -n "$INVENTED_TAGS" ]]; then
            TIER2_MSGS="${TIER2_MSGS}Tags not matching taxonomy prefixes (${R32_TAXONOMY_UNION_LIST}): $(echo "$INVENTED_TAGS" | tr '\n' ', ' | sed 's/, $//').\n"
          fi
        fi

        # Check wikilink fields reference existing files (limit to <10 fields for perf)
        WIKILINK_FIELDS="owner engagement attendees projects previous_instance"
        WIKILINK_CHECK_COUNT=0
        BAD_LINKS=""
        for wfield in $WIKILINK_FIELDS; do
          [[ $WIKILINK_CHECK_COUNT -ge 10 ]] && break
          WVAL=$(fm_val "$wfield")
          if [[ -n "$WVAL" ]]; then
            # Extract wikilinks: [[path]] or [[path|alias]]
            LINKS=$(echo "$WVAL" | grep -oE '\[\[[^]]+\]\]' || true)
            if [[ -n "$LINKS" ]]; then
              while IFS= read -r link; do
                [[ $WIKILINK_CHECK_COUNT -ge 10 ]] && break
                # Strip [[ ]] and optional |alias
                LINK_PATH=$(echo "$link" | sed 's/^\[\[//' | sed 's/\]\]$//' | sed 's/|.*//')
                # Check if file exists (try as-is under vault root, and with .md)
                if [[ ! -f "$VAULT_ROOT/$LINK_PATH" ]] && [[ ! -f "$VAULT_ROOT/${LINK_PATH}.md" ]]; then
                  BAD_LINKS="${BAD_LINKS}${wfield}: ${link}, "
                fi
                WIKILINK_CHECK_COUNT=$((WIKILINK_CHECK_COUNT + 1))
              done <<< "$LINKS"
            fi
          fi
        done
        BAD_LINKS="${BAD_LINKS%, }"
        if [[ -n "$BAD_LINKS" ]]; then
          TIER2_MSGS="${TIER2_MSGS}Wikilink fields referencing non-existent files: ${BAD_LINKS}.\n"
        fi

        # --- Emit Tier 2 DENY if any blocking issues ---
        if [[ -n "$TIER2_MSGS" ]]; then
          DENY_REASON="Write blocked — vault schema enforcement:\n${TIER2_MSGS}Add the missing fields/fix the issues and retry."
          # Audit log for Phase 3 monitoring
          { mkdir -p "${CLAUDE_STATE_ROOT}/audit" 2>/dev/null && echo "$(date -Iseconds) | pre-write-guard | DENY | ${FILE_PATH} | ${TIER2_MSGS}" >> "${CLAUDE_STATE_ROOT}/audit/hook-audit.log"; } 2>/dev/null || true
          format_output_deny "PreToolUse" "$DENY_REASON"
          exit 0
        fi

        # TIER 3 — Allow with mandatory follow-up warning

        # Check if creating a file in a new vault-root directory
        ROOT_DIR=$(echo "$REL_PATH" | cut -d'/' -f1)
        IS_KNOWN=false
        # Read known_roots from bundle (naming.R-04); fall back to hardcoded foundation-8.
        _KNOWN_ROOTS=$(jq -r '.naming.rules[]? | select(.id == "R-04") | .known_roots[]?' <<<"$BUNDLE_JSON" 2>/dev/null || true)
        if [[ -z "$_KNOWN_ROOTS" ]]; then
          _KNOWN_ROOTS="Archive
Daily
Inbox
Plans
Skills"
        fi
        while IFS= read -r _d; do
          [[ -z "$_d" ]] && continue
          if [[ "$ROOT_DIR" == "$_d" ]]; then
            IS_KNOWN=true
            break
          fi
        done <<< "$_KNOWN_ROOTS"

        if [[ "$IS_KNOWN" == "false" ]] && [[ "$ROOT_DIR" != "CLAUDE.md" ]]; then
          TIER3_MSGS="${TIER3_MSGS}[NEW DIRECTORY] File is being written to '${ROOT_DIR}/' which is not a documented vault-root directory. After this write, run \`/govern register --kind folder --target '${ROOT_DIR}/'\` to register this new directory, or move the file to an existing directory.\n"
        fi

        # --- Emit combined Tier 1 + Tier 3 + engagement reminder guidance if any ---
        COMBINED_CTX=""
        [[ -n "$TIER1_MSGS" ]] && COMBINED_CTX="[VAULT SCHEMA - AUTO-FIX NEEDED]\n${TIER1_MSGS}"
        if [[ -n "$TIER3_MSGS" ]]; then
          [[ -n "$COMBINED_CTX" ]] && COMBINED_CTX="${COMBINED_CTX}\n"
          COMBINED_CTX="${COMBINED_CTX}[VAULT SCHEMA - FOLLOW-UP REQUIRED]\n${TIER3_MSGS}"
        fi
        # Append doc-dependency cascade reminder if applicable
        if [[ -n "$DOC_DEP_CTX" ]]; then
          [[ -n "$COMBINED_CTX" ]] && COMBINED_CTX="${COMBINED_CTX}\n\n"
          COMBINED_CTX="${COMBINED_CTX}${DOC_DEP_CTX}"
          DOC_DEP_CTX=""  # consumed
        fi

        if [[ -n "$COMBINED_CTX" ]]; then
          format_output_allow "PreToolUse" "$COMBINED_CTX"
          exit 0
        fi
      fi
    fi
  fi
fi

# --- WARNING: Multi-session file overlap detection ---
# (T-7): the registry is the machine-local coordination registry
# REGISTRY_FILE ($COORD_DIR/session-registry.json), exported by the lib/registry.sh
# source at :33 — NOT the in-vault $VAULT_ROOT/Logs/.coordination
# path (written by no producer → the -f gate below was always false → this advisory
# was dead). track-vault-write.sh stores tool_input.file_path ABSOLUTE into
# touched_files (no relativization), so the query must compare the ABSOLUTE path
# ($FILE_PATH), not the relative one — querying $REL_PATH against ABSOLUTE list
# entries never matched even after the repoint.
REGISTRY="$REGISTRY_FILE"

if [[ -f "$REGISTRY" ]] && [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
  REL_PATH="${FILE_PATH#$VAULT_ROOT/}"
  # Only check vault files (if stripping didn't change the path, it's outside the vault)
  if [[ "$REL_PATH" != "$FILE_PATH" ]]; then
    PEER=$(jq -r --arg sid "$CLAUDE_SESSION_ID" --arg fp "$FILE_PATH" '
      .sessions // {} | to_entries[]
      | select(.key != $sid)
      | select(.value.touched_files // [] | index($fp))
      | .key
    ' "$REGISTRY" 2>/dev/null | head -1)

    if [[ -n "$PEER" ]]; then
      format_output_allow "PreToolUse" "[MULTI-SESSION OVERLAP] File ${REL_PATH} was already modified by peer session ${PEER}. Coordinate before making conflicting changes."
      exit 0
    fi
  fi
fi

# --- Terminal fall-through: emit unconsumed DOC_DEP_CTX ---
# If no earlier block consumed DOC_DEP_CTX (e.g. non-vault write, or vault
# write that skipped the 3-tier block), surface the reminder here so the
# doc-dependency cascade warning never silently drops.
if [[ -n "${DOC_DEP_CTX:-}" ]]; then
  format_output_allow "PreToolUse" "$DOC_DEP_CTX"
  exit 0
fi

exit 0
