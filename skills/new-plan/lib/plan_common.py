# plan_common.py — the pure renderer helpers the plan writers share.
#
# new-plan.sh, lib/graduate-plan.sh and lib/promote-from-inbox.sh each run their work in a python3
# heredoc. They import these four helpers from here instead of carrying a copy each:
#
#   cohort_base(pdir)         the id base of a plan directory's frontmatter cohort
#   q(value)                  a free-text value as a YAML double-quoted scalar
#   fm_quote_titles(text)     quote the title:/description: lines of a leading frontmatter block
#   render(text, **kw)        replace {{key}} placeholders with the keyword values
#
# Each script's python call puts its own lib directory in PLAN_COMMON_DIR and sets
# PYTHONDONTWRITEBYTECODE=1 (an install tree gains no __pycache__), then does
#   sys.path.insert(0, os.environ["PLAN_COMMON_DIR"]); from plan_common import ...
# The module is imported, never executed. tmpl() stays inline in each script (it closes over that
# script's own template directory and abort), and promote-from-inbox.sh keeps its one-argument
# render (it closes over the note's title, date, plan directory, slug and cohort base).
import json
import os
import re


def cohort_base(pdir):
    """Mint-time id base for the plans-schema frontmatter cohort, mirroring
    librarian:tasks-render's _cohort_id grammar: 'plans-' + the slugified path
    parts under the .claude-plans marker (basename fallback). The per-file id
    is this base + '-<suffix>' (spec/tasks/handoff/ideation-brief), so a mint
    and a later renderer upsert derive the SAME id for the same file."""
    ap = os.path.abspath(pdir.rstrip("/"))
    marker = os.sep + ".claude-plans" + os.sep
    rel = ap.split(marker, 1)[1] if marker in ap else os.path.basename(ap)
    parts = [re.sub(r"[^a-z0-9]+", "-", p.lower()).strip("-") for p in rel.split(os.sep)]
    return "plans-" + "-".join([p for p in parts if p])


def q(value):
    """A frontmatter free-text value as a YAML double-quoted scalar (a JSON string is one);
    non-ASCII such as an em dash stays literal."""
    return json.dumps(value, ensure_ascii=False)


def fm_quote_titles(text):
    """Quote the title:/description: lines of the leading frontmatter block as YAML
    double-quoted scalars unless the value already is a JSON-decodable double-quoted
    string; body lines (e.g. `# <title> — Spec`) are untouched."""
    if not text.startswith("---\n"):
        return text
    lines = text.split("\n")
    end = None
    for i, line in enumerate(lines[1:], start=1):
        if line == "---":
            end = i
            break
    if end is None:
        return text
    out = []
    for line in lines[1:end]:
        m = re.match(r"^(title|description): (.*)$", line)
        if m:
            raw = m.group(2).strip()
            try:
                quoted = isinstance(json.loads(raw), str) if raw.startswith('"') else False
            except ValueError:
                quoted = False
            if not quoted:
                line = "%s: %s" % (m.group(1), q(raw))
        out.append(line)
    return "---\n" + "\n".join(out + lines[end:])


def render(text, **kw):
    for k, v in kw.items():
        text = text.replace("{{%s}}" % k, v)
    return text
