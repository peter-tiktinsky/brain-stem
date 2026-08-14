#!/bin/bash
# uninstall.sh — brain-stem foundation uninstaller
#
# sha256 fingerprint match against $CLAUDE_HOME/foundation-manifest.json
# baseline (shipped at install.sh Step 13.5). Per-file
# walk inside foundation directories: match → rm; mismatch → preserve + record in
# user_edited_foundation[]; not-in-baseline → preserve. --force-rm-edited overrides
# preservation. --force-remove permits uninstall when manifest is absent (falls
# back to basename-allowlist rm for the foundation directories).
#
# Scope:
#   - CLAUDE_HOME-first resolution from G1-pre symmetric (R-55 invariant)
#   - Provenance-log-driven CLAUDE_HOME confirmation: read header line
#     `CLAUDE_HOME: <path>` from most-recent $CLAUDE_HOME/logs/install-*.log
#     (G10 consume) and assert equality with env-supplied $CLAUDE_HOME
#   - foundation-manifest.json read + parse + per-file fingerprint table
#   - .pre-uninstall-<ts>/ backup via cp -R (round-trip integrity)
#   - launchctl bootout gui/$UID com.brain-stem.* (LAUNCHCTL_BIN env
#     override for MOCK_LAUNCHCTL=1 hermetic tests; defense-in-depth G6)
#   - G6 namespace gate: refuse to bootout labels outside com.brain-stem.*
#     prefix; secondary guard catches impersonation labels (prefix as substring
#     but not at position 1)
#   - Per-file fingerprint walk inside foundation_known_entries directories:
#       baseline match → rm; baseline mismatch → preserve + log to stderr +
#       record in provenance user_edited_foundation[]; not-in-baseline → preserve
#   - Root-level foundation files (settings.json, settings.local.json,
#     foundation-manifest.json) — not tracked in manifest; rm by basename
#     (settings.json reverse-merge deferred)
#   - Preserve logs/ (uninstall provenance lands here) + hooks/state/ (session
#     state preserved naturally by per-file walk — files not in baseline) +
#     everything not in foundation set
#   - Provenance log header at $CLAUDE_HOME/logs/uninstall-*.log on completion,
#     including user_edited_foundation_count + per-file listing
#
# DEFERRED to future releases:
#   - 10s/plist timeout wrapper around launchctl bootout
#   - settings.json baseline jq-reverse unmerge (G7-symmetric)
#   - --selective <hooks|skills|plists|schemas|onboarding|lib|orchestrator|
#     templates|plugins|installer> / --full / --dry-run / --keep-backup flag
#     matrix (ships with --force-rm-edited + --force-remove only)
#   - Negative-test rehearsal under a runner-shell in a Docker image
#   - Provenance-log freshness validation
#
# Exit codes:
#   0   success
#   10  prereq missing (CLAUDE_HOME unset/empty per G1-pre symmetric;
#                       required binary absent; provenance log missing;
#                       CLAUDE_HOME mismatch with provenance log header;
#                       foundation-manifest.json missing without --force-remove;
#                       foundation-manifest.json parse/extract failure)
#   11  permission/write failure (backup mkdir, backup cp, or provenance write)
#   56  G6 fired (label outside com.brain-stem.* prefix encountered
#                 during bootout discovery; foundation rm NOT performed;
#                 backup retained for forensic review)
#
# Flags:
#   --force-rm-edited   rm user-edited foundation files even on fingerprint
#                       mismatch (warns per file). Default off; preservation is
#                       the load-bearing safety property.
#   --force-remove      permit uninstall when foundation-manifest.json absent
#                       (falls back to basename-allowlist rm of foundation
#                       directories). Default off; manifest-missing is exit 10.
#
# R-23 bash 3.2 compat. R-37 single-deliverable. R-55 zero $HOME/.claude
# resolution paths in script body (literal $HOME/.claude appears only in
# the G1-pre user-facing error text, symmetric with install.sh).

set -u

# --- diagnostics ---
diag() { printf 'uninstall FAIL: %s\n' "$1" >&2; }
info() { printf 'uninstall: %s\n' "$1"; }
warn() { printf 'uninstall WARN: %s\n' "$1" >&2; }

# --- argv parse (fingerprint flags; in-memory only; pre-G1-pre) ---
FORCE_RM_EDITED=0
FORCE_REMOVE=0
for arg in "$@"; do
  case "$arg" in
    --force-rm-edited) FORCE_RM_EDITED=1 ;;
    --force-remove)    FORCE_REMOVE=1 ;;
  esac
done

# --- G1-pre symmetric: CLAUDE_HOME unset/empty preflight (no FS writes) ---
# Mirrors install.sh G1-pre. Acceptance: headless exit fast; zero filesystem mutation.
if [ -z "${CLAUDE_HOME:-}" ]; then
  diag "CLAUDE_HOME not set. Export CLAUDE_HOME=\$HOME/.claude or a custom path before running uninstall.sh. Never rely on \$HOME/.claude implicit default — hard-fail is required for uninstaller safety."
  exit 10
fi

# --- LAUNCHCTL_BIN env override (MOCK_LAUNCHCTL primitive consumption) ---
# Default: real launchctl on PATH. Tests inject mock via LAUNCHCTL_BIN=/path/to/mock-launchctl.
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-launchctl}"

# --- prereq binary check ---
if ! command -v "$LAUNCHCTL_BIN" >/dev/null 2>&1; then
  diag "missing prereq binary: $LAUNCHCTL_BIN (LAUNCHCTL_BIN env var)"
  exit 10
fi
for bin in plutil awk jq python3 shasum find; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    diag "missing prereq binary: $bin"
    exit 10
  fi
done

if [ ! -d "$CLAUDE_HOME" ]; then
  diag "CLAUDE_HOME does not exist: $CLAUDE_HOME"
  exit 10
fi

# --- discover most-recent install provenance log (G10 consume) ---
# Symmetric with install.sh emit format. The install-*.log
# basenames are space-free, but $log_dir is derived
# from $CLAUDE_HOME, which may itself contain a space (/Users/Foo Bar/.claude).
# The old `for f in $(ls -1t "$log_dir"/install-*.log)` used an UNQUOTED command
# substitution, so the space inside the $CLAUDE_HOME-derived path word-split and
# $provenance_log resolved to a pre-space token — the run then exited 10 at the
# missing-header check before the :141 read ever ran. Use a no-word-split glob +
# mtime selection that PRESERVES the prior newest-first (`ls -1t`) semantics.
log_dir="$CLAUDE_HOME/logs"
if [ ! -d "$log_dir" ]; then
  diag "no logs/ directory at $CLAUDE_HOME (no foundation install detected)"
  exit 10
fi

provenance_log=""
newest=""
for f in "$log_dir"/install-*.log; do
  [ -e "$f" ] || continue
  if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then
    newest="$f"
  fi
done
provenance_log="$newest"

if [ -z "$provenance_log" ]; then
  diag "no install-*.log provenance under $CLAUDE_HOME/logs/ (no foundation install detected)"
  exit 10
fi

info "provenance: $provenance_log"

# --- read CLAUDE_HOME from provenance header (R-55 discipline) ---
# install.sh writes line `CLAUDE_HOME: <path>` (printf 'CLAUDE_HOME: %s\n',
# single space — see install.sh writer). The
# old `awk '/^CLAUDE_HOME:/ {print $2}'` word-split on whitespace and captured
# only $2, truncating a space-bearing path (/Users/Foo Bar/.claude -> /Users/Foo)
# so the != check below spuriously failed and a valid target was refused (exit
# 10). Read everything after the exact 'CLAUDE_HOME: ' prefix (matches the
# install-side writer's single-space format byte-for-byte; feedback_spec_code_alignment).
# Sanity-check vs env-supplied $CLAUDE_HOME — mismatch indicates corrupt log
# or wrong target (refuse rather than guess).
provenance_claude_home=""
provenance_claude_home="$(awk '/^CLAUDE_HOME: /{sub(/^CLAUDE_HOME: /,""); print; exit}' "$provenance_log" 2>/dev/null)"

if [ -z "$provenance_claude_home" ]; then
  diag "provenance log missing CLAUDE_HOME header line: $provenance_log"
  exit 10
fi

if [ "$provenance_claude_home" != "$CLAUDE_HOME" ]; then
  diag "provenance CLAUDE_HOME=$provenance_claude_home does not match env CLAUDE_HOME=$CLAUDE_HOME — refusing uninstall (corrupt log or wrong target)"
  exit 10
fi

# --- foundation-known basename allowlist (mirror of install.sh) ---
# Source: install.sh foundation_known_entries. Symmetric with G1-main heuristic.
# foundation-manifest.json lives at $CLAUDE_HOME/governance/foundation-manifest.json;
# it's swept by the governance/ entry in this allowlist (not a root basename).
foundation_known_entries="hooks skills schemas orchestrator templates Library installer logs governance vault-init settings.json settings.local.json"

info "CLAUDE_HOME=$CLAUDE_HOME"
info "LAUNCHCTL_BIN=$LAUNCHCTL_BIN"

# --- foundation-manifest.json read + per-file fingerprint baseline ---
# Reads $CLAUDE_HOME/governance/foundation-manifest.json (baseline shipped
# at install Step 8.5). Extracts
# {path, sha256} pairs to a tmp tab-separated file for path-keyed awk lookup
# (bash 3.2 lacks associative arrays).
#
# Default: missing manifest → exit 10 (refuse uninstall; safety property).
#
# --force-remove ("baseline-fallback +
# preserve-bias"): the pre-fix behaviour set fingerprint_check_skipped=1 and the
# directory walk degenerated to `rm -rf "$entry"` on the ENTIRE foundation dir
# (basename-allowlist mode) — destroying hooks/state/ session/checkpoint state,
# not-in-baseline user content (the "not in baseline → preserve" branch), and
# the engine's .foundation-new/.foundation-local sidecars. That is exactly what
# the normal fingerprint walk preserves. The fix KEEPS the per-file while-read
# walk in --force-remove mode and resolves a baseline for files[] MEMBERSHIP
# classification ONLY (foundation-file vs user-content):
#   * PREFER governance/foundation-manifest.json (the normal baseline).
#   * When it is absent (the force-remove trigger), FALL BACK to the frozen
#     governance/.installed-baseline-manifest.json (a byte-identical copy of the
#     shipped manifest; same files[] schema).
# In force-membership-only mode the per-file lookup_baseline_sha COMPARISON (the
# modified-vs-unmodified content check) is meaningless — we have already decided
# to remove — so it is SKIPPED, but files[] membership is NOT: paths IN baseline
# files[] are rm -f'd, paths NOT in files[] (user content) are preserved per the
# "not in baseline → preserve" branch.
#
# PRESERVE-BIAS DEGRADE: when NO baseline resolves at all (BOTH the live manifest
# AND the frozen .installed-baseline-manifest.json absent), --force-remove
# preserves everything it cannot positively classify as foundation — it never
# destroys user content for lack of a baseline (force-remove exists to recover
# from an incomplete install, not to nuke live state). It removes only what it
# can positively identify as foundation by top-level-dir fingerprint
# (foundation_known_entries directory bodies, sans the never-remove set), and
# never rm -rf's a whole foundation dir.
manifest_path="$CLAUDE_HOME/governance/foundation-manifest.json"
baseline_manifest_path="$CLAUDE_HOME/governance/.installed-baseline-manifest.json"
fingerprint_check_skipped=0
# FRM force-remove resolution flags (mutually exclusive once set):
#   force_membership_only=1 → manifest absent + --force-remove + a baseline
#       (primary or fallback) resolved → membership classification, sha
#       comparison skipped.
#   force_preserve_bias=1   → manifest absent + --force-remove + NO baseline at
#       all → top-level-dir-fingerprint removal, preserve everything else.
force_membership_only=0
force_preserve_bias=0
manifest_records_tmp=""
user_edited_paths_log=""
manifest_record_count=0
baseline_source="none"

# Shared loader: parse + extract {path, sha256} files[] rows from $1 into the
# manifest_records_tmp scratch file. Returns 0 on success, non-zero on
# parse/extraction failure. Allocates the scratch tmp + registers the EXIT trap
# on first use.
load_baseline_records() {
  local src="$1"
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$src" 2>/dev/null; then
    diag "baseline manifest parse failure at $src"
    return 1
  fi
  manifest_records_tmp="$(mktemp -t uninstall-manifest.XXXXXX 2>/dev/null)" || {
    diag "manifest tmp allocation failed"
    exit 11
  }
 # single EXIT trap cleans up every mktemp'd scratch file on every
  # exit path (G6 abort exit 56, parse/extraction-fail exit 10, future early
  # exits) — subsumes the manual rm -f at the happy-path tail and the
  # provenance-write-fail branch. Vars default to "" so the trap is safe before
  # user_edited_paths_log is allocated (canonical idiom; cf. render-launchd.sh).
  trap 'rm -f "$manifest_records_tmp" "$user_edited_paths_log" 2>/dev/null' EXIT
  if ! jq -r '.files[] | "\(.path)\t\(.sha256)"' "$src" > "$manifest_records_tmp" 2>/dev/null; then
    diag "baseline manifest files[] extraction failed at $src"
    return 1
  fi
  manifest_record_count="$(wc -l <"$manifest_records_tmp" | tr -d ' ')"
  return 0
}

if [ -f "$manifest_path" ]; then
  # Normal path: live foundation manifest present → full per-file sha fingerprint
  # walk (membership + content comparison). force-remove flags stay 0.
  load_baseline_records "$manifest_path" || exit 10
  baseline_source="foundation-manifest.json"
  info "fingerprint baseline loaded: $manifest_record_count records"
else
  if [ "$FORCE_REMOVE" = "1" ]; then
 # live manifest absent + --force-remove → resolve a baseline for
    # files[] MEMBERSHIP only, preferring the frozen .installed-baseline-manifest.json
 #. fingerprint_check_skipped stays 1 for the provenance line, but the
    # directory walk no longer rm -rf's — it runs the per-file walk in
    # membership-only mode (or preserve-bias if no baseline resolves at all).
    fingerprint_check_skipped=1
    if [ -f "$baseline_manifest_path" ] && load_baseline_records "$baseline_manifest_path"; then
      force_membership_only=1
      baseline_source=".installed-baseline-manifest.json"
      warn "governance/foundation-manifest.json absent at $manifest_path — --force-remove set; resolved files[] MEMBERSHIP from the frozen $baseline_manifest_path (sha comparison skipped, membership preserved)"
      info "force-remove membership baseline loaded: $manifest_record_count records"
    else
      # Belt-and-suspenders: if the fallback existed but failed to parse,
      # load_baseline_records already diag'd; in either case (absent or
      # unparseable) degrade to preserve-bias rather than refuse — force-remove
      # exists to recover an incomplete install.
      manifest_records_tmp=""
      force_preserve_bias=1
      baseline_source="preserve-bias (no baseline)"
      warn "governance/foundation-manifest.json AND $baseline_manifest_path both absent/unresolvable — --force-remove set; PRESERVE-BIAS degrade: removing only top-level-dir-fingerprinted foundation files, preserving all unclassifiable content (no rm -rf, no user-content destruction for lack of a baseline)"
    fi
  else
    diag "governance/foundation-manifest.json missing at $manifest_path — refusing uninstall (use --force-remove to fall back to baseline-membership/preserve-bias removal)"
    exit 10
  fi
fi

# Helper: lookup baseline sha256 by relative-to-CLAUDE_HOME path.
# Empty stdout → not in baseline.
lookup_baseline_sha() {
  local rel="$1"
  [ -z "$manifest_records_tmp" ] && return 0
  awk -F'\t' -v p="$rel" '$1 == p {print $2; exit}' "$manifest_records_tmp"
}

# Helper: is $1 (relative-to-CLAUDE_HOME path) a member of baseline
# files[]? Returns 0 (true) when the path resolves in the loaded baseline,
# 1 (false) otherwise. Used by the force-membership-only walk to decide
# foundation-file (rm) vs user-content (preserve) WITHOUT a sha comparison.
is_baseline_member() {
  local rel="$1" hit
  [ -z "$manifest_records_tmp" ] && return 1
  hit="$(awk -F'\t' -v p="$rel" '$1 == p {print "1"; exit}' "$manifest_records_tmp")"
  [ -n "$hit" ]
}

# Helper: reachable-historical-sha resolver for the
# uninstall per-file walk. legacy_historical_shas <rel> → prints the per-file sha256
# for that path from EVERY shipped $CLAUDE_HOME/governance/baselines/foundation-manifest-v*.json
# (one per line). Mirrors install.sh:legacy_historical_shas but reads the IN-HOME
# archive (shipped by Option A) — uninstall.sh carries no source-repo
# dependency at all, so the archive's single in-home location
# ($CLAUDE_HOME/governance/baselines/) is the only source. The walk uses this to
# disambiguate a stale-but-pristine prior-release
# file (sha matches a historical baseline → known-unmodified under-delivery → rm) from
# a genuine adopter edit (sha matches NEITHER current baseline NOR any historical →
# preserve). DEGRADES GRACEFULLY: governance/baselines/ absent (a legacy home without the archive) →
# the dir test fails → returns empty → today's behavior (no crash). Checks ALL archived
# manifests (sorted glob), not just the highest — a multi-baseline home matches whichever
# release the on-disk bytes came from. bash 3.2: no associative arrays; one sha per line
# for the `for hist in $(legacy_historical_shas ...)` IFS-safe consumer.
legacy_historical_shas() {
  local rel="$1"
  [ -d "$CLAUDE_HOME/governance/baselines" ] || return 0
  REL="$rel" BLDIR="$CLAUDE_HOME/governance/baselines" python3 -c '
import glob, json, os
rel = os.environ["REL"]
for path in sorted(glob.glob(os.path.join(os.environ["BLDIR"], "foundation-manifest-v*.json"))):
    try:
        m = json.load(open(path))
    except Exception:
        continue
    for f in m.get("files", []):
        if f.get("path") == rel:
            s = f.get("sha256", "")
            if s:
                print(s)
            break
' 2>/dev/null
}

# Helper: hard-coded never-remove set honored on EVERY removal path
# (normal walk preserves these structurally via not-in-baseline; force-remove
# membership/preserve-bias modes must honor them explicitly so a baselined or
# fingerprinted match cannot reach runtime/session state or an engine sidecar).
# Returns 0 (true / must-preserve) for:
# * hooks/state/** — session/checkpoint runtime state (invariant;
#     feedback_test_isolation_for_hooks_state + the checkpoint contract)
#   * logs/** — uninstall provenance destination (also top-level preserved)
#   * **/.foundation-new and **/.foundation-local sidecars (upgrade-engine
#     deferred-merge state the user has not yet reconciled)
is_never_remove() {
  local rel="$1" base="${1##*/}"
  case "$rel" in
    hooks/state/*|hooks/state|logs/*|logs) return 0 ;;
  esac
  case "$base" in
    *.foundation-new|*.foundation-local) return 0 ;;
  esac
  return 1
}

# --- backup: .pre-uninstall-<ts>/ via cp -R ---
ts="$(date -u +%Y%m%d-%H%M%S)"
backup_dir="$CLAUDE_HOME/.pre-uninstall-$ts"

info "creating backup: $backup_dir"
mkdir -p "$backup_dir" || { diag "backup mkdir failed: $backup_dir"; exit 11; }

# Copy each top-level entry except prior backup dirs (avoid recursion).
# Bash 3.2 + macOS cp -R: literal `cp -R src dst/` per-entry.
#
# Exclusions:
#   * .git      — a throwaway restore clone never needs the source repo's .git
#                 history; cloning it would re-retain every credential ever
#                 committed (and inflate the backup).
#   * projects/ — Claude Code runtime session transcripts. RESOLUTION of the
#                 validation correction: the
# off-machine half is already closed
#                 by the .gitignore (projects/ in $CLAUDE_HOME/.gitignore) + the backup filter (projects/
#                 reset out of every backup commit); the only residual is the
#                 retained LOCAL clone. Because transcripts are recoverable
#                 runtime state (not foundation config worth restoring) and can
#                 carry pasted credentials we cannot structurally redact, we
#                 EXCLUDE projects/ from the clone entirely rather than retain it
#                 unredacted. This is the chosen path (excluded, not warn-only).
backup_count=0
for entry in "$CLAUDE_HOME"/* "$CLAUDE_HOME"/.[!.]*; do
  [ -e "$entry" ] || continue
  base="${entry##*/}"
  case "$base" in
    .pre-uninstall-*) continue ;;
    .git)             continue ;;
    projects)         continue ;;
  esac
  if cp -R "$entry" "$backup_dir/" 2>/dev/null; then
    backup_count=$((backup_count + 1))
  else
    warn "backup cp failed for $entry"
  fi
done

info "backup complete: $backup_count entries → $backup_dir"

# --- redact secret values in the .pre-uninstall-* clone ---
# Local-disk half. The cp -R loop above
# duplicates settings.local.json verbatim into the RETAINED $backup_dir; that
# file can hold provider tokens in permissions.allow[] (a legacy adopter carried 2 live
# PythonAnywhere tokens). Post-process the BACKUP COPY ONLY: replace any
# permissions.allow[] entry value matching the token catalog with <REDACTED>,
# preserving the allowlist STRUCTURE (keys + array shape) so a restore round-trip
# still resolves. The LIVE $CLAUDE_HOME/settings.local.json is NEVER touched
# (restore fidelity preserved). python3 is a hard dep (checked above at :102);
# the path is passed via argv (feedback_python_heredoc_argv). Non-JSON / parse
# failure is non-fatal: warn + leave the structure intact (never abort uninstall).
#
# Token catalog: kept in lockstep with backup.sh's SECRET_TOKEN_CATALOG
# (skills/librarian/capabilities/backup.sh) — single source of
# truth for the SHAPES (intra-dependency design). Expressed here as a Python
# re alternation of the SAME shapes.
backup_settings="$backup_dir/settings.local.json"
if [ -f "$backup_settings" ]; then
  python3 - "$backup_settings" <<'PYREDACT'
import json, re, sys

path = sys.argv[1]

# Token catalog (single source of truth for SHAPES — keep in lockstep with
# skills/librarian/capabilities/backup.sh :: SECRET_TOKEN_CATALOG).
#   sk-ant-                               Anthropic API key
#   ghp_ / github_pat_                    GitHub PAT (classic / fine-grained)
#   AKIA[0-9A-Z]{16}                      AWS access key id
#   -----BEGIN [A-Z ]*PRIVATE KEY-----    PEM private-key header
#   xox[baprs]-                           Slack token
#   Authorization: (Token|Bearer) <val>   bearer/token auth header
TOKEN_RE = re.compile(
    r"sk-ant-"
    r"|ghp_"
    r"|github_pat_"
    r"|AKIA[0-9A-Z]{16}"
    r"|-----BEGIN [A-Z ]*PRIVATE KEY-----"
    r"|xox[baprs]-"
    r"|Authorization:\s*(?:Token|Bearer)\s+\S+"
)

try:
    with open(path) as fh:
        data = json.load(fh)
except Exception as exc:                       # non-JSON / parse failure
    sys.stderr.write(
        "uninstall WARN: backup-copy settings.local.json not redactable "
        "(%s); structure left intact: %s\n" % (type(exc).__name__, path)
    )
    sys.exit(0)                                # non-fatal: do NOT abort uninstall

redacted = 0
try:
    allow = data["permissions"]["allow"]
except (KeyError, TypeError):
    allow = None

if isinstance(allow, list):
    for i, entry in enumerate(allow):
        if isinstance(entry, str) and TOKEN_RE.search(entry):
            allow[i] = "<REDACTED>"            # value masked; array shape kept
            redacted += 1

if redacted:
    try:
        with open(path, "w") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
    except Exception as exc:
        sys.stderr.write(
            "uninstall WARN: backup-copy redaction write failed "
            "(%s); leaving prior copy: %s\n" % (type(exc).__name__, path)
        )
        sys.exit(0)
    sys.stderr.write(
        "uninstall: redacted %d secret value(s) in backup copy of "
        "settings.local.json\n" % redacted
    )
PYREDACT
fi

# --- launchctl bootout gui/$UID com.brain-stem.* (G6-gated) ---
PREFIX="com.brain-stem"
uid="$(id -u)"
domain="gui/$uid"

g6_violation=0
boot_count=0

# Primary G6: filter launchctl list output by prefix at awk; non-matching
# labels never reach the bootout call.
labels=""
labels="$("$LAUNCHCTL_BIN" list 2>/dev/null | awk -v p="$PREFIX." 'NR > 1 && $3 != "" && index($3, p) == 1 {print $3}')" || true

# Secondary G6 (impersonation defense): scan for labels containing the prefix
# substring but NOT at position 1 (e.g., `evil.com.brain-stem.fake`).
# This catches impersonation that the primary index==1 filter excludes.
foreign=""
foreign="$("$LAUNCHCTL_BIN" list 2>/dev/null | awk -v p="$PREFIX" 'NR > 1 && $3 != "" && index($3, p) > 0 && index($3, p) != 1 {print $3}')" || true
if [ -n "$foreign" ]; then
  diag "G6 fired: foreign label(s) contain '$PREFIX' substring outside namespace (position 1):"
  printf '%s\n' "$foreign" >&2
  g6_violation=1
fi

if [ "$g6_violation" = "1" ]; then
  diag "uninstall aborted on G6 violation; foundation file removal NOT performed (backup retained at $backup_dir for forensic review)"
  exit 56
fi

# --- bootout each foundation label (rc-tolerant; warn on failure) ---
if [ -n "$labels" ]; then
  while IFS= read -r label; do
    [ -z "$label" ] && continue
    # Defense-in-depth: re-check prefix at iteration time.
    case "$label" in
      "$PREFIX".*) ;;
      *)
        warn "G6 defense: label '$label' slipped past awk filter; refusing bootout"
        continue
        ;;
    esac
    if "$LAUNCHCTL_BIN" bootout "$domain/$label" 2>/dev/null; then
      info "bootout $label"
      boot_count=$((boot_count + 1))
    else
      rc=$?
      warn "bootout failed for $label (rc=$rc); continuing iteration"
    fi
  done <<EOF
$labels
EOF
fi

info "bootout complete: $boot_count labels"

# --- rm foundation plists at $HOME/Library/LaunchAgents/ ---
# uninstall.sh historically operated only on $CLAUDE_HOME contents; rendered
# plists at $HOME/Library/LaunchAgents/<Label>.plist (written by render-launchd
# production mode) were outside the removal scope. Stale plists auto-load on
# reboot, re-bootstrapping the foundation label under launchd despite uninstall
# completion (wrapper script under $CLAUDE_HOME is gone — fire produces stderr
# noise but no destructive action; UX-confusing).
#
# Symmetric with G6 awk-filter: only com.brain-stem.*.plist files are
# removed; foreign plists in the same directory are preserved. Glob iteration
# uses [ -e ] guard for the empty-glob case (Bash 3.2 compat).
LA_DIR="${HOME:-/}/Library/LaunchAgents"
plist_rm_count=0
if [ -d "$LA_DIR" ]; then
  for plist in "$LA_DIR"/com.brain-stem.*.plist; do
    [ -e "$plist" ] || continue
    if rm -f "$plist" 2>/dev/null; then
      info "rm $(basename "$plist") from $LA_DIR"
      plist_rm_count=$((plist_rm_count+1))
    else
      warn "rm failed: $plist"
    fi
  done
fi
info "plist cleanup: $plist_rm_count foundation plist(s) removed from $LA_DIR"

# --- rm foundation files at $CLAUDE_HOME root with per-file fingerprint walk ---
# Top-level dispatch:
#   - logs/                    → preserve entirely (uninstall provenance lands here)
#   - non-foundation entries   → preserve (basename not in foundation_known_entries)
#   - foundation root files    → rm by basename (manifest does NOT track
#                                 settings.json / settings.local.json;
#                                 reverse-merge is deferred)
#   - governance/foundation-manifest.json → SPECIAL CASE rm during per-file
#                                 walk (chicken-and-egg: the manifest
#                                 doesn't track its own sha256; lives under
#                                 governance/)
#   - foundation directories   → per-file walk:
#         baseline match    → rm
#         baseline mismatch → preserve + log + record (or rm if --force-rm-edited)
#         not in baseline   → preserve (user content under foundation dir;
#                              hooks/state/ session files land here)
#       After per-file walk, prune empty subdirs bottom-up via find -depth -delete.
#
# When fingerprint_check_skipped=1 (manifest absent + --force-remove), per-file
# walk degenerates to rm-rf the foundation directories — basename allowlist
# fallback for graceful recovery from incomplete-install state.
removed_count=0
preserved_count=0
user_edited_foundation_count=0
# provenance counter for stale-but-pristine prior-release
# files removed by the historical-sha disambiguation branch — distinct from removed_count
# (current-baseline matches) and user_edited_foundation_count (genuine adopter edits), so
# the operator sees an under-delivered home was reconciled rather than silently treated
# as current or misclassified as user-edited.
stale_pristine_removed_count=0
user_edited_paths_log="$(mktemp -t uninstall-edited.XXXXXX 2>/dev/null)" || {
  diag "user-edited tmp allocation failed"
  exit 11
}

# Capture the rules/README.md seed baseline sha BEFORE the foundation walk
# removes templates/ (the seed template is templates/claude-home-rules-readme-template.md;
# it is processed/removed inside the loop below). Compared against the on-disk README after
# the walk to decide remove-if-unmodified vs preserve-if-user-edited.
rules_seed_template="$CLAUDE_HOME/templates/claude-home-rules-readme-template.md"
rules_seed_sha=""
[ -f "$rules_seed_template" ] && rules_seed_sha="$(shasum -a 256 "$rules_seed_template" 2>/dev/null | awk '{print $1}')"

for entry in "$CLAUDE_HOME"/* "$CLAUDE_HOME"/.[!.]*; do
  [ -e "$entry" ] || continue
  base="${entry##*/}"
  case "$base" in
    .pre-uninstall-*) continue ;;
  esac

  found=0
  for known in $foundation_known_entries; do
    if [ "$base" = "$known" ]; then
      found=1
      break
    fi
  done

  if [ "$found" = "0" ]; then
    info "preserved (non-foundation): $entry"
    preserved_count=$((preserved_count + 1))
    continue
  fi

  if [ "$base" = "logs" ]; then
    info "preserving logs/ (uninstall provenance destination)"
    preserved_count=$((preserved_count + 1))
    continue
  fi

  if [ -d "$entry" ]; then
 # Foundation directory — per-file walk.
 # The pre-fix `rm -rf "$entry"` fallback for fingerprint_check_skipped=1 is
    # GONE. --force-remove now runs the SAME per-file while-read walk; the only
    # difference from the normal path is the per-file disposition:
    #   * normal (force_membership_only=0, force_preserve_bias=0): full sha
    #     fingerprint — baseline match → rm; mismatch → preserve/record (or rm
    #     with --force-rm-edited); not-in-baseline → preserve.
    #   * force_membership_only=1: files[] MEMBERSHIP only — member → rm; non-
    #     member → preserve (user content). sha COMPARISON skipped.
    #   * force_preserve_bias=1: NO baseline — preserve-bias. Remove only what is
    #     positively foundation by top-level-dir fingerprint (the whole foundation
    #     directory body, sans the never-remove set); preserve nothing else can
    #     classify. No rm -rf reaches a whole dir; the never-remove set + sidecars
    #     are always preserved.
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      rel="${f#$CLAUDE_HOME/}"

 # FRM never-remove set: hooks/state/ session/checkpoint runtime state,
      # logs/, and .foundation-new/.foundation-local sidecars are preserved on
      # EVERY removal path — a baselined or fingerprinted match must never reach
      # them (the invariant --force-remove was never meant to override).
      if is_never_remove "$rel"; then
        info "preserved (never-remove set): $rel"
        preserved_count=$((preserved_count + 1))
        continue
      fi

      # governance/foundation-manifest.json is NOT in baseline
      # (chicken-and-egg — the manifest doesn't track its own sha256). Special-
      # case: rm without baseline check; analogous to root-file basename rm
 #
      # governance/governance-action-log.jsonl
      # is FOUNDATION-GENERATED runtime audit-state — bootstrap-CREATED empty at
      # install Step 1.6 (bootstrap-not-copy),
      # NOT a copied/baselined ship-list member, so the "not in baseline -> preserve"
      # branch would wrongly keep it (uninstall residue). It is foundation runtime
      # state, not user content (uninstall removes what install
      # laid down + foundation runtime state) -> rm without baseline check, like the
      # foundation-manifest.json carve-out above.
 #
 # The upgrade engine writes two MORE governance
      # runtime-state sidecars at install (install.sh:590-591) that are likewise
      # NOT in files[] — governance/.installed-state.json (the version stamp) and
      # governance/.installed-baseline-manifest.json (the frozen previous-release
      # floor). Same class as governance-action-log.jsonl: foundation-generated,
      # not user content. Without this carve-out they survive uninstall (the
      # `find -type f` walk reaches dotfiles) -> governance/ never prunes empty ->
      # a governance uninstall-residue. rm without baseline check.
 #
 # The release ceremony mints
      # governance/baselines/foundation-manifest-v<version>.json, and
      # generate-foundation-manifest.sh SELF-EXCLUDES the current-version archive
      # from files[] (a manifest cannot record its own sha256 — circular). But
      # install.sh's fresh-lane `cp -R governance/baselines/.` ships the WHOLE dir,
      # so the current-version archive lands in the home as a NON-files[]
      # foundation-owned file. Same class as the .installed-* sidecars: a
      # foundation-shipped runtime floor, not user content. Without this carve-out
      # the find-walk preserves it -> governance/ never prunes empty -> an uninstall
      # RESIDUE:governance. governance/baselines/ is wholly foundation-owned; rm any
      # frozen archive by glob (the files[]-listed prior archives are also swept here
      # idempotently; the README is a files[] member removed by the normal path).
      _bl_archive=0
      case "$rel" in
        governance/baselines/foundation-manifest-v*.json) _bl_archive=1 ;;
      esac
      # governance/anchored-spoke-registry.json is the seed-once adopter spoke registry:
      # seed-if-absent at install, USER-PRESERVE-by-omission on --apply (NOT in files[], so
      # an upgrade never resets it). Not being a files[] member, the per-file walk cannot
      # classify it — remove it here on a full uninstall (same foundation-seeded, non-files[]
      # class as the sidecars above) or governance/ never prunes empty (a governance uninstall-residue).
      if [ "$rel" = "governance/foundation-manifest.json" ] || \
         [ "$rel" = "governance/governance-action-log.jsonl" ] || \
         [ "$rel" = "governance/.installed-state.json" ] || \
         [ "$rel" = "governance/.installed-baseline-manifest.json" ] || \
         [ "$rel" = "governance/anchored-spoke-registry.json" ] || \
         [ "$_bl_archive" = "1" ]; then
        if rm -f "$f" 2>/dev/null; then
          removed_count=$((removed_count + 1))
        else
          warn "rm failed: $f"
        fi
        continue
      fi

 # FRM force_preserve_bias: NO baseline resolved at all. Without a
      # baseline, a file inside a foundation directory body CANNOT be positively
      # classified as a foundation file vs user content at the file level — so it
      # is UNCLASSIFIABLE and PRESERVED. force-remove exists to recover from an
      # incomplete install, NOT to nuke live state; it never destroys user content
      # for lack of a baseline. The positively-foundation surface that IS removed
      # under preserve-bias is the coarse, name-deterministic set the install owns
      # unambiguously and that cannot collide with user content: the governance/
      # foundation-manifest.json + governance-action-log.jsonl carve-outs handled
      # above, and the root-level foundation config files settings.json /
      # settings.local.json handled by the basename rm below. Everything inside a
      # foundation directory body is preserved. The never-remove set is already
      # honored above.
      if [ "$force_preserve_bias" = "1" ]; then
        info "preserved (preserve-bias: unclassifiable without a baseline): $rel"
        preserved_count=$((preserved_count + 1))
        continue
      fi

 # FRM force_membership_only: baseline resolved (frozen
      # .installed-baseline-manifest.json fallback). Classify by files[]
      # MEMBERSHIP only — skip the sha COMPARISON (meaningless once we have
      # decided to remove): member → rm; non-member → preserve user content.
      if [ "$force_membership_only" = "1" ]; then
        if is_baseline_member "$rel"; then
          if rm -f "$f" 2>/dev/null; then
            removed_count=$((removed_count + 1))
          else
            warn "rm failed: $f"
          fi
        else
          info "preserved (force-remove: not in baseline files[]): $rel"
          preserved_count=$((preserved_count + 1))
        fi
        continue
      fi

      sha_baseline="$(lookup_baseline_sha "$rel")"
      if [ -n "$sha_baseline" ]; then
        sha_actual="$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')"
        if [ "$sha_actual" = "$sha_baseline" ]; then
          if rm -f "$f" 2>/dev/null; then
            removed_count=$((removed_count + 1))
          else
            warn "rm failed: $f"
          fi
        else
 # sha_actual != current-version baseline.
          # Before falling to the "user-edited foundation file preserved" branch, FIRST
          # consult the reachable historical-sha set: an on-disk sha that matches ANY
          # archived prior-release baseline is a KNOWN UNMODIFIED prior-release file (a
 # stale-pristine under-delivered file — — NOT an adopter edit), so it
          # is rm -f'd (same disposition as the current-baseline match above) and the home
          # uninstalls cleanly. Only a sha matching NEITHER current baseline NOR any
          # historical sha is a genuine adopter edit → existing preserve/force-rm-edited
          # path UNCHANGED. legacy_historical_shas degrades to empty (no match) when
          # governance/baselines/ is absent (legacy home without the archive), so the walk keeps today's
          # behavior. bash 3.2: IFS-safe per-line read via for-in over command substitution.
          hist_matched=0
          hist_version=""
          for hist_sha in $(legacy_historical_shas "$rel"); do
            if [ "$sha_actual" = "$hist_sha" ]; then hist_matched=1; break; fi
          done
          if [ "$hist_matched" = "1" ]; then
            # Name the matched archive version for operator visibility (best-effort grep
            # over the in-home archives; the rm proceeds regardless of the version probe).
            hist_version="$(grep -l "$sha_actual" "$CLAUDE_HOME/governance/baselines"/foundation-manifest-v*.json 2>/dev/null | head -1 | sed -E 's#.*/foundation-manifest-(v[^/]*)\.json$#\1#')"
            [ -n "$hist_version" ] || hist_version="(archived prior release)"
            warn "removed stale-pristine prior-release foundation file (matches historical sha $hist_version): $rel"
            if rm -f "$f" 2>/dev/null; then
              stale_pristine_removed_count=$((stale_pristine_removed_count + 1))
            else
              warn "rm failed: $f"
            fi
          elif [ "$FORCE_RM_EDITED" = "1" ]; then
            warn "user-edited foundation file removed (--force-rm-edited): $rel"
            if rm -f "$f" 2>/dev/null; then
              removed_count=$((removed_count + 1))
            else
              warn "rm failed: $f"
            fi
          else
            warn "user-edited foundation file preserved: $rel (rm with --force-rm-edited if intentional)"
            printf '%s\n' "$rel" >> "$user_edited_paths_log"
            user_edited_foundation_count=$((user_edited_foundation_count + 1))
            preserved_count=$((preserved_count + 1))
          fi
        fi
      else
        info "preserved (not in baseline): $rel"
        preserved_count=$((preserved_count + 1))
      fi
    done <<EOF
$(find "$entry" -type f 2>/dev/null)
EOF
    # Prune empty subdirs bottom-up; -depth so leaves go first.
    find "$entry" -depth -type d -empty -exec rmdir {} \; 2>/dev/null || true
  else
    # Foundation root file (settings.json / settings.local.json). Manifest
    # doesn't track these. rm by basename.
    # foundation-manifest.json lives under governance/
    # (handled via special-case in governance/ per-file walk above).
    if rm -rf "$entry" 2>/dev/null; then
      info "removed $entry"
      removed_count=$((removed_count + 1))
    else
      warn "rm failed for $entry"
    fi
  fi
done

# --- rules/README.md seed-baseline removal ----------
# rules/README.md is INSTALL-SEEDED from templates/claude-home-rules-readme-template.md
# (install.sh Step 11.7) -> it is a
# FOUNDATION artifact. But `rules` is intentionally NOT in foundation_known_entries, because
# rules/ also hosts USER-authored .claude/rules/*.md (the documented Anthropic scale-beyond
# primitive) -> the whole rules/ dir is preserved as non-foundation, so the foundation-seeded
# README would survive uninstall (residue). sha256 rm-or-preserve
# posture: remove rules/README.md ONLY if its sha matches the shipped seed baseline (the
# template = the unmodified foundation seed); preserve a user-MODIFIED README (or any user rule
# files). Then prune rules/ if it becomes empty. No new unconditional rm of a user-content path.
rules_readme="$CLAUDE_HOME/rules/README.md"
if [ -f "$rules_readme" ]; then
  rules_readme_sha="$(shasum -a 256 "$rules_readme" 2>/dev/null | awk '{print $1}')"
  if [ -n "$rules_seed_sha" ] && [ "$rules_readme_sha" = "$rules_seed_sha" ]; then
    if rm -f "$rules_readme" 2>/dev/null; then
      info "removed foundation-seeded rules/README.md (sha matches the install seed baseline)"
      removed_count=$((removed_count + 1))
    else
      warn "rm failed: $rules_readme"
    fi
  elif [ "$FORCE_RM_EDITED" = "1" ]; then
    if rm -f "$rules_readme" 2>/dev/null; then
      warn "user-edited rules/README.md removed (--force-rm-edited)"
      removed_count=$((removed_count + 1))
    else
      warn "rm failed: $rules_readme"
    fi
  else
    warn "user-edited rules/README.md preserved: rules/README.md (sha differs from the install seed baseline; rm with --force-rm-edited if intentional)"
    printf '%s\n' "rules/README.md" >> "$user_edited_paths_log"
    user_edited_foundation_count=$((user_edited_foundation_count + 1))
    preserved_count=$((preserved_count + 1))
  fi
  # Prune rules/ if it is now empty (no user rule files remain).
  rmdir "$CLAUDE_HOME/rules" 2>/dev/null || true
fi

info "rm complete: removed=$removed_count stale_pristine_removed=$stale_pristine_removed_count preserved=$preserved_count user_edited=$user_edited_foundation_count"

# --- provenance log header (G10 emit; symmetric with install.sh) ---
log_path="$CLAUDE_HOME/logs/uninstall-$(date -u +%Y%m%d-%H%M%S)-$$.log"
if [ "$fingerprint_check_skipped" = "1" ]; then
  fingerprint_check_skipped_str="true"
else
  fingerprint_check_skipped_str="false"
fi
{
  printf 'uninstall.sh provenance\n'
  printf 'timestamp: %s\n'                       "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'CLAUDE_HOME: %s\n'                     "$CLAUDE_HOME"
  printf 'consumed_install_log: %s\n'            "$provenance_log"
  printf 'backup_dir: %s\n'                      "$backup_dir"
  printf 'backup_entry_count: %d\n'              "$backup_count"
  printf 'bootout_count: %d\n'                   "$boot_count"
  printf 'plist_rm_count: %d\n'                  "$plist_rm_count"
  printf 'plist_rm_dir: %s\n'                    "$LA_DIR"
  printf 'removed_count: %d\n'                   "$removed_count"
  printf 'stale_pristine_removed_count: %d\n'    "$stale_pristine_removed_count"
  printf 'preserved_count: %d\n'                 "$preserved_count"
  printf 'user_edited_foundation_count: %d\n'    "$user_edited_foundation_count"
  printf 'fingerprint_check_skipped: %s\n'       "$fingerprint_check_skipped_str"
  printf 'manifest_record_count: %d\n'           "$manifest_record_count"
  printf 'force_rm_edited: %d\n'                 "$FORCE_RM_EDITED"
  printf 'force_remove: %d\n'                    "$FORCE_REMOVE"
  printf 'launchctl_bin: %s\n'                   "$LAUNCHCTL_BIN"
  printf 'uninstall.sh sha256: %s\n'             "$(shasum -a 256 "$0" 2>/dev/null | awk '{print $1}')"
  if [ -s "$user_edited_paths_log" ]; then
    printf 'user_edited_foundation:\n'
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      printf '  - %s\n' "$p"
    done < "$user_edited_paths_log"
  fi
  printf 'slice_scope: G1-pre symmetric + provenance-log-driven CLAUDE_HOME confirm + foundation-manifest.json read + .pre-uninstall-<ts>/ backup + launchctl bootout (LAUNCHCTL_BIN-overridable, G6-gated, com.brain-stem.* only) + foundation plist rm at $HOME/Library/LaunchAgents/ (G6-symmetric prefix filter) + per-file fingerprint walk inside foundation directories + basename rm for foundation root files + logs/ + non-foundation top-level preservation + --force-rm-edited / --force-remove\n'
  printf 'deferred: 10s/plist timeout wrapper around launchctl bootout; settings.json baseline jq-reverse unmerge (G7-symmetric); --selective/--full/--dry-run/--keep-backup flag matrix; runner-shell negative rehearsal; provenance-log freshness validation\n'
} > "$log_path" || { diag "uninstall provenance log write failed"; exit 11; }

# --- cleanup tmp files: handled by the single EXIT trap ---

info "uninstall complete. next-steps:"
info "  - restore round-trip: cp -R $backup_dir/. \$CLAUDE_HOME/"
info "  - prune backup when satisfied: rm -rf $backup_dir"
info "provenance: $log_path"

exit 0
