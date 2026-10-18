#!/usr/bin/env python3
"""decision-page.py — turn a decision-page JSON spec into one self-contained HTML page.

Usage:
    decision-page.py --spec <dossier>/<slug>.json [--out page.html] [--no-open]

Validates the spec, collecting every problem before exiting 2, then fills
templates/page.html with the spec JSON, the shared kit's CSS and JS, a title and a
meta description. Output is deterministic. Prints the output path and the spec hash.

Exit codes: 0 ok, 2 bad input (usage, unreadable spec, invalid JSON, invalid spec),
1 the template or kit could not be found.
"""

import argparse
import hashlib
import html
import json
import os
import re
import sys
from pathlib import Path

ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
ID_RULE = ID_RE.pattern[1:-1]  # the pattern without its anchors, for messages
STAGE_STATES = ("done", "current", "upcoming", "later")
SKILL_DIR = Path(os.path.realpath(__file__)).parent.parent  # resolves the stow symlink to the repo copy
TEMPLATE = SKILL_DIR / "templates" / "page.html"
KIT_CSS = SKILL_DIR / "kit" / "kit.css"
KIT_JS = SKILL_DIR / "kit" / "kit.js"
PAGEKIT = SKILL_DIR / "kit" / "pagekit.py"  # helpers shared with review-page.py

sys.dont_write_bytecode = True  # keep __pycache__ out of the stowed kit dir
sys.path.insert(0, str(PAGEKIT.parent))
try:
    from pagekit import open_browser, script_safe, unopenable_reason
except ImportError:
    sys.stderr.write('decision-page.py: missing %s; run: stow --no-folding -t "$HOME" claude\n' % PAGEKIT)
    sys.exit(1)


def die(msg: str, code: int = 2):
    print("decision-page.py: " + msg, file=sys.stderr)
    sys.exit(code)


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def bad_id(v) -> bool:
    return not (isinstance(v, str) and ID_RE.match(v))


def blank(v) -> bool:
    return not (isinstance(v, str) and v.strip())


def validate(spec) -> list:
    """Return every problem found, as messages naming the offending item."""
    probs = []
    if not isinstance(spec, dict):
        return ["the spec must be a JSON object"]

    if bad_id(spec.get("slug")):
        probs.append('slug %r must match %s' % (spec.get("slug"), ID_RULE))
    r = spec.get("round")
    if isinstance(r, bool) or not isinstance(r, int) or r < 1:
        probs.append("round %r must be an integer of at least 1" % (r,))

    for f in ("title", "lede"):
        if f in spec and not isinstance(spec[f], str):
            probs.append("%s must be a string" % f)
    st = spec.get("stats")
    if st is not None and not (isinstance(st, list) and all(isinstance(x, str) for x in st)):
        probs.append("stats must be a list of strings")

    ctx = spec.get("context")
    if ctx is not None:
        stages = ctx.get("stages") if isinstance(ctx, dict) else None
        if not isinstance(stages, list):
            probs.append("context.stages must be a list")
        else:
            for k, s in enumerate(stages):
                st = s.get("state") if isinstance(s, dict) else None
                if st not in STAGE_STATES:
                    probs.append("context.stages[%d]: state %r must be one of %s" % (k, st, ", ".join(STAGE_STATES)))
            if sum(1 for s in stages if isinstance(s, dict) and s.get("state") == "current") > 1:
                probs.append("context.stages: more than one stage is current")

    seen = set()

    def check_id(kind, v, where):
        if bad_id(v):
            probs.append('%s %s: id %r must match %s' % (kind, where, v, ID_RULE))
        elif v in seen:
            probs.append('%s "%s": duplicate id' % (kind, v))
        else:
            seen.add(v)

    items = spec.get("items")
    if not isinstance(items, list):
        probs.append("items must be a list")
        items = []
    decided = spec.get("decided", [])
    if not isinstance(decided, list):
        probs.append("decided must be a list")
        decided = []

    for k, d in enumerate(decided):
        if not isinstance(d, dict):
            probs.append("decided[%d] must be an object" % k)
            continue
        check_id("decided", d.get("id"), "[%d]" % k)
        name = 'decided "%s"' % d.get("id")
        for f in ("decision", "date"):
            if blank(d.get(f)):
                probs.append("%s: missing %s" % (name, f))
        if "options" in d:
            probs.append("%s: a decided entry has no options" % name)

    for k, i in enumerate(items):
        if not isinstance(i, dict):
            probs.append("items[%d] must be an object" % k)
            continue
        check_id("item", i.get("id"), "[%d]" % k)
        name = 'item "%s"' % i.get("id")
        for f in ("question", "why_it_matters", "recommendation"):
            if blank(i.get(f)):
                probs.append("%s: missing %s" % (name, f))
        tag = i.get("tag")
        if tag is not None and not (isinstance(tag, dict) and isinstance(tag.get("label"), str) and isinstance(tag.get("tone", ""), str)):
            probs.append("%s: tag must be an object with a string label and tone" % name)
        arts = i.get("artifacts")
        if arts is not None and not (isinstance(arts, list) and all(isinstance(x, dict) for x in arts)):
            probs.append("%s: artifacts must be a list of objects" % name)
        opts = i.get("options")
        if not isinstance(opts, list) or not opts:
            probs.append("%s: needs a list of options" % name)
            continue
        oseen = set()
        for m, o in enumerate(opts):
            if not isinstance(o, dict):
                probs.append("%s: options[%d] must be an object" % (name, m))
                continue
            v = o.get("v")
            if bad_id(v):
                probs.append('%s: option id %r must match %s' % (name, v, ID_RULE))
            elif v in oseen:
                probs.append('%s: duplicate option id "%s"' % (name, v))
            else:
                oseen.add(v)
            if blank(o.get("name")):
                probs.append('%s: option "%s" is missing name' % (name, v))
        recs = [o for o in opts if isinstance(o, dict) and o.get("rec")]
        if len(recs) != 1:
            probs.append("%s: needs exactly one rec option, found %d" % (name, len(recs)))
        if "defer" not in oseen:
            probs.append('%s: needs a "defer" option' % name)
        if any(o.get("v") == "defer" for o in recs):
            probs.append('%s: the "defer" option can not be the rec option' % name)
    return probs


SUSPECT_RE = re.compile(r"<script|\son[a-z]+\s*=", re.I)


def suspect_fields(v, path="") -> list:
    """JSON paths of string values that look like live script (a <script tag or an
    inline on...= handler). Most fields are inserted as HTML, so quoted untrusted
    text must be escaped; this only warns."""
    if isinstance(v, str):
        return [path or "$"] if SUSPECT_RE.search(v) else []
    kids = enumerate(v) if isinstance(v, list) else v.items() if isinstance(v, dict) else ()
    return [p for k, x in kids for p in suspect_fields(x, "%s[%d]" % (path, k) if isinstance(k, int) else "%s.%s" % (path, k) if path else k)]


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def canonical(spec) -> str:
    return json.dumps(spec, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def render(spec) -> tuple:
    """Return (page html, 8-hex spec hash)."""
    canon = canonical(spec)
    spec_hash = hashlib.sha256(canon.encode("utf-8")).hexdigest()[:8]
    n = len(spec["items"])
    parts = {
        "TITLE": html.escape(spec.get("title") or spec["slug"]),
        "DESCRIPTION": html.escape("Decision page, round %d: %d open item%s to answer." % (spec["round"], n, "" if n == 1 else "s")),
        "SPEC_HASH": spec_hash,
        "KIT_CSS": KIT_CSS.read_text(encoding="utf-8"),
        "KIT_JS": KIT_JS.read_text(encoding="utf-8"),
        "SPEC_JSON": script_safe(canon),
    }
    # One pass, so a placeholder-shaped string inside the spec or kit is never substituted.
    page = re.sub(r"\{\{([A-Z_]+)\}\}", lambda m: parts.get(m.group(1), m.group(0)),
                  TEMPLATE.read_text(encoding="utf-8"))
    return page, spec_hash


# ---------------------------------------------------------------------------
# Opening
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(prog="decision-page.py", description="Generate a decision page from a JSON spec.")
    ap.add_argument("--spec", required=True, help="path to the spec JSON")
    ap.add_argument("--out", help="output HTML path (default: the spec path with .html)")
    ap.add_argument("--no-open", action="store_true", help="write the page but do not open a browser")
    args = ap.parse_args()

    try:
        with open(args.spec, encoding="utf-8") as f:
            spec = json.load(f)
    except OSError as e:
        die("can't read %s: %s" % (args.spec, e.strerror))
    except ValueError as e:
        die("%s is not valid JSON: %s" % (args.spec, e))

    probs = validate(spec)
    if probs:
        for p in probs:
            print("decision-page.py: " + p, file=sys.stderr)
        sys.exit(2)

    for path in suspect_fields(spec):
        print("decision-page.py: warning: %s contains <script or an inline on...= handler; escape quoted untrusted text (references/spec-and-answers.md)" % path, file=sys.stderr)

    for p in (TEMPLATE, KIT_CSS, KIT_JS):
        if not p.is_file():
            die('missing %s; run: stow --no-folding -t "$HOME" claude' % p, 1)

    out = os.path.abspath(args.out or os.path.splitext(args.spec)[0] + ".html")
    page, spec_hash = render(spec)
    with open(out, "w", encoding="utf-8") as f:
        f.write(page)

    print("wrote: %s" % out)
    print("spec_hash: %s" % spec_hash)
    reason = None if args.no_open else unopenable_reason(out)
    if args.no_open:
        print("not opened: --no-open")
    elif reason:
        print("not opened: %s is %s. Open it from a non-hidden path under $HOME." % (out, reason))
    else:
        open_browser(Path(out).as_uri(), "decision-page.py: no browser opener found; open manually: %s" % Path(out).as_uri())
        print("opened: %s" % out)


if __name__ == "__main__":
    main()
