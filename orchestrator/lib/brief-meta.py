#!/usr/bin/env python3
"""brief-meta.py — brief frontmatter parser.

Parses YAML frontmatter from dispatched briefs and emits machine-readable
output for dispatch.sh pre-flight, job-runner.sh dynamic watched-repos
extension, and verifier.sh post-dispatch artifact + acceptance assertion.

Subcommands:
  check <brief>            — Validate frontmatter (expected_artifacts present,
                              path allowlist+denylist; decision_points shape
                              when present; session_close shape when present).
                              Exit 0 = OK. Exit non-zero with diagnostic on
                              stderr.
  artifacts <brief>        — Emit JSON: [{"path": "...", "optional": bool}, ...]
                              Empty list for research-only briefs.
  watched-extensions <brief>
                           — Emit one dirname per artifact path (de-duped, one
                              per line). Used by job-runner.sh to extend
                              WATCHED_REPOS before pre-snapshot.
  acceptance <brief>       — Emit JSON for the acceptance block.
                              [] when not present.
  decision-points <brief>  — Emit JSON for the decision_points field.
                              [] when not present. Each entry:
                                {id, question, options, chosen?, rationale?}
  session-close <brief>    — Emit JSON for session-continuity
                              fields:
                                {produces_session_close: bool,
                                 predecessor_session: str|null}
                              Defaults: produces_session_close=false,
                              predecessor_session=null.
  scoping <brief>          — Emit JSON for the pre-dispatch
                              scoping protocol fields:
                                {scope_summary: str|null,
                                 team_topology: dict|null,
                                 dispatch_decision: dict|null,
                                 filter_check_failed: bool,
                                 filter_fail_reasons: [str, ...]}
                              All three fields optional (backwards-compatible).
                              filter_check_failed is true when decision is
                              "dispatch-multi" AND any of the 6 refusal filters
                              is "fail". Always exit 0; shape validation lives
                              in `check`.

Path validation:
  ALLOWLIST anchors: ~/.claude/, ~/.claude-plans/, ~/Documents/Obsidian Vault/, ~/Code/
  DENYLIST: /, /tmp/**, /var/**, /etc/**, /usr/**, /private/**, paths containing ..
  Per-artifact 'optional: true' allowed for advisory paths.
"""
import os
import re
import sys
import json

try:
    import yaml
except ImportError:
    print("FATAL: PyYAML not installed. brew install yq or pip3 install pyyaml.",
          file=sys.stderr)
    sys.exit(2)

ALLOWLIST = [
    os.path.expanduser("~/.claude/"),
    os.path.expanduser("~/.claude-plans/"),
    os.path.expanduser("~/Documents/Obsidian Vault/"),
    os.path.expanduser("~/Code/"),
]
DENYLIST_PREFIXES = ["/tmp/", "/var/", "/etc/", "/usr/", "/private/"]
DENYLIST_EXACT = {"/"}


def expand(p):
    return os.path.expanduser(p)


def validate_path(p):
    """Return None if valid, else error string."""
    if not isinstance(p, str) or not p:
        return f"path must be non-empty string: {p!r}"
    parts = p.split("/")
    if ".." in parts:
        return f"path contains '..' segment: {p}"
    if p in DENYLIST_EXACT:
        return f"path on denylist: {p}"
    expanded = expand(p)
    for prefix in DENYLIST_PREFIXES:
        if expanded.startswith(prefix):
            return f"path under denylist prefix '{prefix}': {p}"
    if not any(expanded.startswith(allowed) for allowed in ALLOWLIST):
        anchors = ", ".join(ALLOWLIST)
        return f"path not under any allowlist anchor ({anchors}): {p}"
    return None


def parse_frontmatter(brief_path):
    """Read brief, extract YAML frontmatter, return parsed dict or None."""
    with open(brief_path, "r") as f:
        text = f.read()
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n?", text, re.DOTALL)
    if not m:
        return None
    parsed = yaml.safe_load(m.group(1))
    return parsed if isinstance(parsed, dict) else {}


def normalize_artifacts(raw):
    """Normalize entries to [{path, optional}, ...]; raise ValueError on shape errors."""
    if raw is None:
        raise ValueError("expected_artifacts is null; use [] for research-only briefs")
    if not isinstance(raw, list):
        raise ValueError(f"expected_artifacts must be a list, got {type(raw).__name__}")
    out = []
    for entry in raw:
        if isinstance(entry, str):
            out.append({"path": entry, "optional": False})
        elif isinstance(entry, dict):
            if "path" not in entry:
                raise ValueError(f"object artifact entry missing 'path': {entry!r}")
            out.append({
                "path": entry["path"],
                "optional": bool(entry.get("optional", False)),
            })
        else:
            raise ValueError(f"unsupported artifact entry shape: {entry!r}")
    return out


def normalize_acceptance(raw):
    """Normalize acceptance entries; raise ValueError on shape errors."""
    if raw is None:
        return []
    if not isinstance(raw, list):
        raise ValueError(f"acceptance must be a list, got {type(raw).__name__}")
    out = []
    for entry in raw:
        if not isinstance(entry, dict) or "path" not in entry:
            raise ValueError(f"acceptance entry must be an object with 'path': {entry!r}")
        item = {"path": entry["path"]}
        if "min_lines" in entry:
            item["min_lines"] = int(entry["min_lines"])
        if "must_match" in entry:
            item["must_match"] = str(entry["must_match"])
        out.append(item)
    return out


def normalize_decision_points(raw):
    """Normalize decision_points entries.

    Each entry is an object:
      id:        str (required, non-empty)
      question:  str (required, non-empty)
      options:   list of str (required, len >= 2)
      chosen:    str (optional; populated by dispatched session)
      rationale: str (optional; populated by dispatched session)

    Raises ValueError on shape errors. Returns [] if raw is None.
    """
    if raw is None:
        return []
    if not isinstance(raw, list):
        raise ValueError(f"decision_points must be a list, got {type(raw).__name__}")
    out = []
    for entry in raw:
        if not isinstance(entry, dict):
            raise ValueError(f"decision_points entry must be an object: {entry!r}")
        for required in ("id", "question", "options"):
            if required not in entry:
                raise ValueError(f"decision_points entry missing '{required}': {entry!r}")
        if not isinstance(entry["id"], str) or not entry["id"].strip():
            raise ValueError(f"decision_points entry 'id' must be non-empty string: {entry!r}")
        if not isinstance(entry["question"], str) or not entry["question"].strip():
            raise ValueError(f"decision_points entry 'question' must be non-empty string: {entry!r}")
        if not isinstance(entry["options"], list) or len(entry["options"]) < 2:
            raise ValueError(f"decision_points entry 'options' must be a list of >= 2 items: {entry!r}")
        for opt in entry["options"]:
            if not isinstance(opt, str) or not opt.strip():
                raise ValueError(f"decision_points option must be non-empty string: {opt!r}")
        item = {
            "id": entry["id"],
            "question": entry["question"],
            "options": list(entry["options"]),
        }
        if "chosen" in entry:
            if not isinstance(entry["chosen"], str):
                raise ValueError(f"decision_points 'chosen' must be string: {entry!r}")
            item["chosen"] = entry["chosen"]
        if "rationale" in entry:
            if not isinstance(entry["rationale"], str):
                raise ValueError(f"decision_points 'rationale' must be string: {entry!r}")
            item["rationale"] = entry["rationale"]
        out.append(item)
    return out


def normalize_session_close(fm):
    """Normalize session-continuity fields.

    Top-level keys (not nested under a list):
      produces_session_close: bool (optional; default False)
      predecessor_session:    str  (optional; default None)

    Defaults preserve backward compatibility — existing briefs without these
    fields continue to dispatch unchanged. predecessor_session being optional
    mitigates the parallel-wave bottleneck.

    Raises ValueError on shape errors. Returns dict with both keys.
    """
    produces_raw = fm.get("produces_session_close", False)
    if not isinstance(produces_raw, bool):
        raise ValueError(
            f"produces_session_close must be a bool, got {type(produces_raw).__name__}"
        )
    pred_raw = fm.get("predecessor_session", None)
    if pred_raw is not None:
        if not isinstance(pred_raw, str) or not pred_raw.strip():
            raise ValueError(
                f"predecessor_session must be a non-empty string when present, got {pred_raw!r}"
            )
    return {
        "produces_session_close": produces_raw,
        "predecessor_session": pred_raw if pred_raw is not None else None,
    }


# Canonical refusal-filter keys (in order).
SP04_FILTER_KEYS = (
    "sequential_edges",
    "shared_global_context",
    "token_value_asymmetry",
    "decomposition_ambiguity",
    "depth_signal",
    "verifier_coupling",
)
SP04_TOPOLOGY_PATTERNS = ("single", "flat", "staged")
SP04_SYNTHESIS_PATTERNS = ("single-pass", "two-stage-hierarchical", "cluster-first")
SP04_DECISIONS = ("dispatch-multi", "dispatch-single", "abort-and-rescope")


def normalize_scope_summary(raw):
    """Validate scope_summary string. Returns str or None."""
    if raw is None:
        return None
    if not isinstance(raw, str) or not raw.strip():
        raise ValueError(
            f"scope_summary must be a non-empty string when present, got {type(raw).__name__}"
        )
    return raw.strip()


def normalize_team_topology(raw):
    """Validate team_topology dict. Returns dict or None.

    Required: pattern (one of single|flat|staged).
    If pattern != single:
        N must be int >= 1
        themes must be a non-empty list; each theme has name (str), brief (str),
            expected_artifacts (list of str)
    Optional: synthesis (one of canonical 3), rationale (str).
    """
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise ValueError(f"team_topology must be a mapping, got {type(raw).__name__}")
    if "pattern" not in raw:
        raise ValueError("team_topology missing required 'pattern' field")
    pattern = raw["pattern"]
    if pattern not in SP04_TOPOLOGY_PATTERNS:
        raise ValueError(
            f"team_topology.pattern must be one of {SP04_TOPOLOGY_PATTERNS}, got {pattern!r}"
        )
    out = {"pattern": pattern}
    if pattern != "single":
        if "N" not in raw:
            raise ValueError(f"team_topology.pattern={pattern!r} requires 'N' field")
        n_raw = raw["N"]
        if not isinstance(n_raw, int) or isinstance(n_raw, bool) or n_raw < 1:
            raise ValueError(f"team_topology.N must be positive int, got {n_raw!r}")
        out["N"] = n_raw
        if "themes" not in raw:
            raise ValueError(f"team_topology.pattern={pattern!r} requires 'themes' field")
        themes_raw = raw["themes"]
        if not isinstance(themes_raw, list) or not themes_raw:
            raise ValueError(
                f"team_topology.themes must be non-empty list, got {themes_raw!r}"
            )
        themes_out = []
        for i, t in enumerate(themes_raw):
            if not isinstance(t, dict):
                raise ValueError(f"team_topology.themes[{i}] must be a mapping: {t!r}")
            for required in ("name", "brief"):
                if required not in t:
                    raise ValueError(
                        f"team_topology.themes[{i}] missing '{required}': {t!r}"
                    )
                if not isinstance(t[required], str) or not t[required].strip():
                    raise ValueError(
                        f"team_topology.themes[{i}].{required} must be non-empty string"
                    )
            ea = t.get("expected_artifacts", [])
            if not isinstance(ea, list):
                raise ValueError(
                    f"team_topology.themes[{i}].expected_artifacts must be a list, got {ea!r}"
                )
            for j, p in enumerate(ea):
                if not isinstance(p, str) or not p.strip():
                    raise ValueError(
                        f"team_topology.themes[{i}].expected_artifacts[{j}] must be non-empty string"
                    )
            themes_out.append({
                "name": t["name"],
                "brief": t["brief"],
                "expected_artifacts": list(ea),
            })
        out["themes"] = themes_out
    if "synthesis" in raw:
        if raw["synthesis"] not in SP04_SYNTHESIS_PATTERNS:
            raise ValueError(
                f"team_topology.synthesis must be one of {SP04_SYNTHESIS_PATTERNS}, "
                f"got {raw['synthesis']!r}"
            )
        out["synthesis"] = raw["synthesis"]
    if "rationale" in raw:
        if not isinstance(raw["rationale"], str) or not raw["rationale"].strip():
            raise ValueError("team_topology.rationale must be non-empty string when present")
        out["rationale"] = raw["rationale"].strip()
    return out


def normalize_dispatch_decision(raw):
    """Validate dispatch_decision dict. Returns dict or None.

    Required:
        decision: one of dispatch-multi | dispatch-single | abort-and-rescope
    Required when decision in {dispatch-multi, abort-and-rescope}:
        multi_agent_filters_passed: list of single-key dicts covering all 6
            canonical filter keys; values "pass" | "fail"
    Optional for dispatch-single (single agent skips multi-agent filter discipline).
    Optional: rationale (str).
    """
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise ValueError(
            f"dispatch_decision must be a mapping, got {type(raw).__name__}"
        )
    if "decision" not in raw:
        raise ValueError("dispatch_decision missing required 'decision' field")
    decision = raw["decision"]
    if decision not in SP04_DECISIONS:
        raise ValueError(
            f"dispatch_decision.decision must be one of {SP04_DECISIONS}, got {decision!r}"
        )
    out = {"decision": decision}
    filters_raw = raw.get("multi_agent_filters_passed")
    needs_filters = decision in ("dispatch-multi", "abort-and-rescope")
    if needs_filters and filters_raw is None:
        raise ValueError(
            f"dispatch_decision.multi_agent_filters_passed required when decision={decision!r}"
        )
    if filters_raw is not None:
        # Accept list-of-single-key-objects (spec canonical shape) OR flat dict.
        flat = {}
        if isinstance(filters_raw, list):
            for i, entry in enumerate(filters_raw):
                if not isinstance(entry, dict) or len(entry) != 1:
                    raise ValueError(
                        f"multi_agent_filters_passed[{i}] must be a single-key mapping: {entry!r}"
                    )
                k, v = next(iter(entry.items()))
                if k in flat:
                    raise ValueError(f"multi_agent_filters_passed duplicate key: {k}")
                flat[k] = v
        elif isinstance(filters_raw, dict):
            flat = dict(filters_raw)
        else:
            raise ValueError(
                f"multi_agent_filters_passed must be list or mapping, got {type(filters_raw).__name__}"
            )
        for k in SP04_FILTER_KEYS:
            if k not in flat:
                raise ValueError(
                    f"multi_agent_filters_passed missing required filter '{k}'"
                )
        extra = set(flat) - set(SP04_FILTER_KEYS)
        if extra:
            raise ValueError(
                f"multi_agent_filters_passed has unknown filter key(s): {sorted(extra)}"
            )
        for k in SP04_FILTER_KEYS:
            v = flat[k]
            if v not in ("pass", "fail"):
                raise ValueError(
                    f"multi_agent_filters_passed.{k} must be 'pass' or 'fail', got {v!r}"
                )
        # Preserve canonical order in output.
        out["multi_agent_filters_passed"] = [{k: flat[k]} for k in SP04_FILTER_KEYS]
    if "rationale" in raw:
        if not isinstance(raw["rationale"], str) or not raw["rationale"].strip():
            raise ValueError("dispatch_decision.rationale must be non-empty string when present")
        out["rationale"] = raw["rationale"].strip()
    return out


def compute_filter_check(decision_dict):
    """Cross-validation: decision=dispatch-multi + any filter=fail
    → filter_check_failed=True. Returns (bool, list-of-reasons).
    """
    if decision_dict is None:
        return False, []
    if decision_dict.get("decision") != "dispatch-multi":
        return False, []
    failed = []
    for entry in decision_dict.get("multi_agent_filters_passed", []):
        k, v = next(iter(entry.items()))
        if v == "fail":
            failed.append(k)
    return (len(failed) > 0), failed


SCHEMA_HINT = """\
Required frontmatter shape (mandatory):

  ---
  expected_artifacts:
    - ~/.claude/orchestrator/foo.sh           # plain string = required
    - path: ~/.claude/orchestrator/state/log  # object form
      optional: true                          # advisory; missing OK
  ---

Empty list for research-only briefs (escape hatch):

  ---
  expected_artifacts: []
  ---

Allowlist anchors: ~/.claude/, ~/.claude-plans/, ~/Documents/Obsidian Vault/, ~/Code/
Denylist: /, /tmp/**, /var/**, /etc/**, /usr/**, /private/**, paths containing ..
"""


def cmd_check(brief):
    fm = parse_frontmatter(brief)
    if fm is None:
        sys.stderr.write(
            f"ERROR: brief has no YAML frontmatter\n"
            f"  brief: {brief}\n"
            f"  Frontmatter must begin with '---' fence at line 1.\n\n"
            f"{SCHEMA_HINT}"
        )
        return 3
    if "expected_artifacts" not in fm:
        sys.stderr.write(
            f"ERROR: brief frontmatter missing required 'expected_artifacts:' field\n"
            f"  brief: {brief}\n\n"
            f"{SCHEMA_HINT}"
        )
        return 4
    try:
        artifacts = normalize_artifacts(fm["expected_artifacts"])
    except ValueError as e:
        sys.stderr.write(
            f"ERROR: invalid expected_artifacts shape: {e}\n"
            f"  brief: {brief}\n\n"
            f"{SCHEMA_HINT}"
        )
        return 5
    errors = [validate_path(a["path"]) for a in artifacts]
    errors = [e for e in errors if e]
    if errors:
        sys.stderr.write(
            f"ERROR: expected_artifacts path validation failed (allowlist+denylist):\n"
        )
        for e in errors:
            sys.stderr.write(f"  - {e}\n")
        sys.stderr.write(f"  brief: {brief}\n")
        return 6
    if "acceptance" in fm:
        try:
            normalize_acceptance(fm["acceptance"])
        except ValueError as e:
            sys.stderr.write(
                f"ERROR: invalid acceptance shape: {e}\n"
                f"  brief: {brief}\n"
            )
            return 9
    if "decision_points" in fm:
        try:
            normalize_decision_points(fm["decision_points"])
        except ValueError as e:
            sys.stderr.write(
                f"ERROR: invalid decision_points shape: {e}\n"
                f"  brief: {brief}\n"
            )
            return 10
    if "produces_session_close" in fm or "predecessor_session" in fm:
        try:
            normalize_session_close(fm)
        except ValueError as e:
            sys.stderr.write(
                f"ERROR: invalid session-close shape: {e}\n"
                f"  brief: {brief}\n"
            )
            return 11
    sp04_fields_present = any(
        k in fm for k in ("scope_summary", "team_topology", "dispatch_decision")
    )
    if sp04_fields_present:
        try:
            normalize_scope_summary(fm.get("scope_summary"))
            normalize_team_topology(fm.get("team_topology"))
            normalize_dispatch_decision(fm.get("dispatch_decision"))
        except ValueError as e:
            sys.stderr.write(
                f"ERROR: invalid scoping shape: {e}\n"
                f"  brief: {brief}\n"
            )
            return 12
    return 0


def cmd_artifacts(brief):
    fm = parse_frontmatter(brief) or {}
    try:
        artifacts = normalize_artifacts(fm.get("expected_artifacts", []))
    except ValueError as e:
        sys.stderr.write(f"ERROR: {e}\n")
        return 5
    print(json.dumps(artifacts))
    return 0


def cmd_watched_extensions(brief):
    fm = parse_frontmatter(brief) or {}
    try:
        artifacts = normalize_artifacts(fm.get("expected_artifacts", []))
    except ValueError:
        artifacts = []
    seen = set()
    for a in artifacts:
        d = os.path.dirname(expand(a["path"]))
        if d and d not in seen:
            seen.add(d)
            print(d)
    return 0


def cmd_acceptance(brief):
    fm = parse_frontmatter(brief) or {}
    try:
        items = normalize_acceptance(fm.get("acceptance"))
    except ValueError as e:
        sys.stderr.write(f"ERROR: {e}\n")
        return 9
    print(json.dumps(items))
    return 0


def cmd_decision_points(brief):
    fm = parse_frontmatter(brief) or {}
    try:
        items = normalize_decision_points(fm.get("decision_points"))
    except ValueError as e:
        sys.stderr.write(f"ERROR: {e}\n")
        return 10
    print(json.dumps(items))
    return 0


def cmd_session_close(brief):
    fm = parse_frontmatter(brief) or {}
    try:
        item = normalize_session_close(fm)
    except ValueError as e:
        sys.stderr.write(f"ERROR: {e}\n")
        return 11
    print(json.dumps(item))
    return 0


def cmd_scoping(brief):
    """Emit scoping JSON for dispatch.sh consumption.

    Always exits 0 (shape validation is in `check`). Emits empty {} when no
    scoping fields declared (legacy brief, backwards-compatible).
    """
    fm = parse_frontmatter(brief) or {}
    sp04_present = any(
        k in fm for k in ("scope_summary", "team_topology", "dispatch_decision")
    )
    if not sp04_present:
        print(json.dumps({}))
        return 0
    try:
        scope_summary = normalize_scope_summary(fm.get("scope_summary"))
        team_topology = normalize_team_topology(fm.get("team_topology"))
        dispatch_decision = normalize_dispatch_decision(fm.get("dispatch_decision"))
    except ValueError as e:
        # Shape error — emit minimal object so dispatch.sh can still log;
        # `check` is the gate that returns rc=12 for shape failures.
        print(json.dumps({"_shape_error": str(e)}))
        return 0
    failed, reasons = compute_filter_check(dispatch_decision)
    print(json.dumps({
        "scope_summary": scope_summary,
        "team_topology": team_topology,
        "dispatch_decision": dispatch_decision,
        "filter_check_failed": failed,
        "filter_fail_reasons": reasons,
    }))
    return 0


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    cmd, brief = argv[1], argv[2]
    if not os.path.isfile(brief):
        sys.stderr.write(f"ERROR: brief not found: {brief}\n")
        return 1
    handlers = {
        "check": cmd_check,
        "artifacts": cmd_artifacts,
        "watched-extensions": cmd_watched_extensions,
        "acceptance": cmd_acceptance,
        "decision-points": cmd_decision_points,
        "session-close": cmd_session_close,
        "scoping": cmd_scoping,
    }
    fn = handlers.get(cmd)
    if fn is None:
        sys.stderr.write(f"unknown subcommand: {cmd}\n")
        sys.stderr.write(__doc__)
        return 2
    return fn(brief)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
