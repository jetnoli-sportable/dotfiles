#!/usr/bin/env python3
"""verify-plan.py - tools for a task's verification document (verify.json).

Subcommands:
  check <file>   validate the document; silent and exit 0 when it is sound,
                 otherwise one line per problem and exit 1.
  build <file>   validate, then write the pages (shaping.html, map.html) beside the source;
                 each is one self-contained file, identical on every build.
  record-run <file> <state-dir>
                 replace the document's `run` section from the page's exported store
                 (<state-dir>/steps/<stepId>.json); validates, then writes atomically.

Python 3, standard library only. The contract is in references/spec.md.
"""
import argparse
import html
import importlib.util
import json
import os
import re
import sys

LANES = ("unit", "integration", "e2e", "walkthrough")
ACCESS = ("local", "cloud-read", "cloud-write", "prod", "permission")
STAGES = ("shaping", "map", "run", "results")
ID_RE = re.compile(r"^[A-Za-z0-9_-]+$")
TEST_STATUSES = ("proposed", "planned", "built")
DECISION_STATUSES = ("open", "answered")
OUTCOMES = ("passed", "failed", "skipped", "not-run")


def blank(v):
    return not isinstance(v, str) or not v.strip()


def check_document(doc):
    """Return a list of problem lines. Empty means the document is sound."""
    errs = []
    add = errs.append

    if not isinstance(doc, dict):
        return ["document: top level must be an object"]

    def items(key, sub=None):
        """List of dicts under doc[key] (or doc[key][sub]); reports a wrong shape."""
        v = doc.get(key, [])
        where = key
        if sub is not None:
            if not isinstance(v, dict):
                if key in doc:
                    add(f"{key}: must be an object")
                return []
            v = v.get(sub, [])
            where = f"{key}.{sub}"
        if not isinstance(v, list):
            add(f"{where}: must be a list")
            return []
        out = []
        for i, x in enumerate(v):
            if isinstance(x, dict):
                out.append(x)
            else:
                add(f"{where}[{i}]: must be an object")
        return out

    def str_list(item, field, owner):
        v = item.get(field, [])
        if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
            add(f"{owner}: field '{field}' must be a list of strings")
            return []
        return v

    def collect_ids(entries, kind):
        seen = set()
        for e in entries:
            i = e.get("id")
            if blank(i):
                add(f"{kind}: an entry has no id")
                continue
            if not isinstance(i, str) or not ID_RE.fullmatch(i):
                add(f"{kind} {i!r}: id may use only letters, digits, '_' and '-'")
            if i in seen:
                add(f"{kind} {i}: duplicate id")
            seen.add(i)
        return seen

    if blank(doc.get("task")):
        add("document: field 'task' is required and must not be blank")
    if doc.get("stage") not in STAGES:
        add(f"document: field 'stage' must be one of {', '.join(STAGES)} (got {doc.get('stage')!r})")
    for f in ("title", "summary"):
        if f in doc and not isinstance(doc[f], str):
            add(f"document: field '{f}' must be a string")
    page = doc.get("page", {})
    if not isinstance(page, dict):
        add("page: must be an object")
    elif "tags" in page and not isinstance(page["tags"], list):
        add("page: field 'tags' must be a list")

    lane_entries = items("lanes")
    if "lanes" in doc:
        lane_ids = [e.get("id") for e in lane_entries]
        if sorted(map(str, lane_ids)) != sorted(LANES):
            add(f"lanes: must be exactly {', '.join(LANES)} (got {', '.join(map(str, lane_ids))})")

    reqs = items("requirements")
    parts = items("parts")
    tests = items("tests")
    steps = items("walkthrough", "steps")
    decisions = items("decisions")
    req_ids = collect_ids(reqs, "requirement")
    part_ids = collect_ids(parts, "part")
    test_ids = collect_ids(tests, "test")
    step_ids = collect_ids(steps, "step")
    dec_ids = collect_ids(decisions, "decision")

    wt = doc.get("walkthrough")
    if wt is not None and (not isinstance(wt, dict) or not isinstance(wt.get("revision"), int)
                           or isinstance(wt.get("revision"), bool)):
        add("walkthrough: field 'revision' must be an integer")

    for r in reqs:
        rid = r.get("id", "?")
        for f in ("label", "sentence"):
            if blank(r.get(f)):
                add(f"requirement {rid}: field '{f}' is required and must not be blank")
        if "accepted_gap" in r and not isinstance(r["accepted_gap"], str):
            add(f"requirement {rid}: field 'accepted_gap' must be a string")

    covered = set()
    for t in tests:
        tid = t.get("id", "?")
        if blank(t.get("name")):
            add(f"test {tid}: field 'name' (the plain name) must not be blank")
        if t.get("lane") not in LANES:
            add(f"test {tid}: field 'lane' must be one of {', '.join(LANES)} (got {t.get('lane')!r})")
        if t.get("status") not in TEST_STATUSES:
            add(f"test {tid}: field 'status' must be one of {', '.join(TEST_STATUSES)} (got {t.get('status')!r})")
        for r in str_list(t, "requirements", f"test {tid}"):
            if r not in req_ids:
                add(f"test {tid}: field 'requirements' names unknown requirement {r}")
            covered.add(r)
        for f in ("real_parts", "faked_parts"):
            for p in str_list(t, f, f"test {tid}"):
                if p not in part_ids:
                    add(f"test {tid}: field '{f}' names unknown part {p}")
        d = t.get("decision")
        if d not in (None, "") and d not in dec_ids:
            add(f"test {tid}: field 'decision' names unknown decision {d}")

    for s in steps:
        sid = s.get("id", "?")
        if blank(s.get("title")):
            add(f"step {sid}: field 'title' is required and must not be blank")
        if blank(s.get("command")) and blank(s.get("instruction")):
            add(f"step {sid}: needs a 'command' or a plain 'instruction'")
        for a in str_list(s, "access", f"step {sid}"):
            if a not in ACCESS:
                add(f"step {sid}: field 'access' has {a!r}; allowed values are {', '.join(ACCESS)}")
        if not s.get("access"):
            add(f"step {sid}: field 'access' needs at least one of {', '.join(ACCESS)}")
        for r in str_list(s, "requirements", f"step {sid}"):
            if r not in req_ids:
                add(f"step {sid}: field 'requirements' names unknown requirement {r}")
            covered.add(r)

    open_named = set()
    for d in decisions:
        did = d.get("id", "?")
        if blank(d.get("question")):
            add(f"decision {did}: field 'question' is required and must not be blank")
        if d.get("status") not in DECISION_STATUSES:
            add(f"decision {did}: field 'status' must be one of {', '.join(DECISION_STATUSES)} (got {d.get('status')!r})")
        opts = d.get("options", [])
        opt_ids = set()
        if not isinstance(opts, list) or not all(isinstance(o, dict) for o in opts):
            add(f"decision {did}: field 'options' must be a list of objects")
        else:
            opt_ids = {o.get("id") for o in opts}
        for f in ("recommended", "answer"):
            v = d.get(f)
            if v not in (None, "") and opt_ids and v not in opt_ids:
                add(f"decision {did}: field '{f}' names unknown option {v}")
        if d.get("status") == "answered" and d.get("answer") in (None, ""):
            add(f"decision {did}: status is answered but field 'answer' is empty")
        names = str_list(d, "requirements", f"decision {did}")
        for r in names:
            if r not in req_ids:
                add(f"decision {did}: field 'requirements' names unknown requirement {r}")
        if d.get("status") == "open":
            open_named.update(names)

    for r in reqs:
        rid = r.get("id")
        if rid in covered or rid in open_named or not blank(r.get("accepted_gap")):
            continue
        add(f"requirement {rid}: uncovered - no test, no walkthrough step, no open decision naming it "
            f"and no 'accepted_gap' reason")

    for f in ("checked", "unchecked", "needs"):
        v = doc.get(f, [])
        if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
            add(f"document: field '{f}' must be a list of strings")

    run = doc.get("run")
    if run is not None:
        if not isinstance(run, dict):
            add("run: must be an object")
        else:
            rev = run.get("revision")
            if rev is not None and (not isinstance(rev, int) or isinstance(rev, bool)):
                add("run: field 'revision' must be an integer")
            wt_rev = (wt or {}).get("revision") if isinstance(wt, dict) else None
            if isinstance(rev, int) and isinstance(wt_rev, int) and rev != wt_rev:
                add(f"run: recorded against walkthrough revision {rev} but the walkthrough is now at revision "
                    f"{wt_rev}; re-run the walkthrough and record-run again, or remove the 'run' section")
            rs = run.get("steps", {})
            if not isinstance(rs, dict):
                add("run: field 'steps' must be an object keyed by step id")
            else:
                for sid, entry in rs.items():
                    if sid not in step_ids:
                        add(f"run step {sid}: no such walkthrough step")
                    if not isinstance(entry, dict):
                        add(f"run step {sid}: must be an object")
                        continue
                    if entry.get("outcome") not in OUTCOMES:
                        add(f"run step {sid}: field 'outcome' must be one of {', '.join(OUTCOMES)} "
                            f"(got {entry.get('outcome')!r})")
    return errs


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except OSError as e:
        sys.exit(f"verify-plan.py: cannot read {path}: {e.strerror}")
    except json.JSONDecodeError as e:
        sys.exit(f"verify-plan.py: {path} is not valid JSON: {e}")


def cmd_check(args):
    errs = check_document(load(args.file))
    for line in errs:
        print(line)
    return 1 if errs else 0


SKILL_DIR = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
TEMPLATES = os.path.join(SKILL_DIR, "templates")
# Every page `build` writes (template and output share a name), with its title suffix.
PAGES = ("shaping.html", "map.html")
TITLE_SUFFIX = {"shaping.html": " shaping", "map.html": " proof map"}


def fail(lines, message):
    """Print each error line, then the closing message, to stderr; the command's exit code is 1."""
    for line in lines:
        print(line, file=sys.stderr)
    print(message, file=sys.stderr)
    return 1


def script_safe(text):
    """compare-page's helper, loaded by file path so stow symlinks and the cwd don't matter."""
    path = os.path.join(SKILL_DIR, "..", "compare-page", "kit", "pagekit.py")
    spec = importlib.util.spec_from_file_location("pagekit", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.script_safe(text)


def meta_lines(doc):
    """The page's metadata block body, in the format wb.sh's _wb_page_meta reads."""
    page = doc.get("page") or {}
    out = []
    if page.get("tags"):
        out.append("tags: [%s]" % ", ".join(html.escape(str(t), quote=False) for t in page["tags"]))
    for key in ("retire_when", "url"):
        if page.get(key):
            out.append("%s: %s" % (key, html.escape(" ".join(str(page[key]).split()), quote=False)))
    return "\n".join(out)


def render_page(template_name, doc):
    def read(*parts):
        with open(os.path.join(TEMPLATES, *parts), encoding="utf-8") as fh:
            return fh.read()

    values = {
        "META": meta_lines(doc),
        # A short name with no colon: the page title doubles as the published artifact's name.
        "TITLE": html.escape(
            " ".join(str(doc.get("title") or doc.get("task", "")).split())
            + TITLE_SUFFIX[template_name]
        ),
        "CSS": read("shared.css"),
        "JS": read("shared.js"),
        "DATA": script_safe(json.dumps(doc, sort_keys=True, ensure_ascii=True, separators=(",", ":"))),
    }
    # One pass, so text inside a substituted value is never mistaken for a placeholder.
    return re.sub(r"__VP_(META|TITLE|CSS|JS|DATA)__", lambda m: values[m.group(1)], read(template_name))


def cmd_build(args):
    doc = load(args.file)
    errs = check_document(doc)
    if errs:
        return fail(errs, "verify-plan.py: not building an invalid document")
    outdir = os.path.dirname(os.path.abspath(args.file))
    for name in PAGES:
        with open(os.path.join(outdir, name), "w", encoding="utf-8") as fh:
            fh.write(render_page(name, doc))
    return 0


def unwrap(raw):
    """An exported document is either the document itself or a wrapper that holds it under `data`."""
    if isinstance(raw, dict) and isinstance(raw.get("data"), dict):
        return raw["data"]
    return raw


def cmd_record_run(args):
    doc = load(args.file)
    # The run section is about to be replaced, so a stale one must not block recording.
    errs = check_document({k: v for k, v in doc.items() if k != "run"} if isinstance(doc, dict) else doc)
    if errs:
        return fail(errs, "verify-plan.py: not recording into an invalid document")
    steps_dir = os.path.join(args.state_dir, "steps")
    if not os.path.isdir(steps_dir):
        print(f"verify-plan.py: no steps folder in {args.state_dir}", file=sys.stderr)
        return 1
    known = [s.get("id") for s in (doc.get("walkthrough") or {}).get("steps", [])]
    revision = (doc.get("walkthrough") or {}).get("revision")
    recorded, ignored, problems = {}, 0, []
    for name in sorted(os.listdir(steps_dir)):
        if not name.endswith(".json"):
            continue
        sid = name[:-5]
        try:
            with open(os.path.join(steps_dir, name), encoding="utf-8") as fh:
                entry = unwrap(json.load(fh))
        except (OSError, json.JSONDecodeError) as e:
            problems.append(f"{name}: cannot read as JSON ({e})")
            continue
        if not isinstance(entry, dict):
            problems.append(f"{name}: must hold an object")
        elif str(entry.get("rev")) != str(revision):
            ignored += 1
        elif sid not in known:
            problems.append(f"step {sid}: stored state names a step that is not in the walkthrough")
        else:
            recorded[sid] = {
                "outcome": entry.get("outcome") or "not-run",
                "skip_reason": entry.get("skip_reason") or "",
                "output": entry.get("output") or "",
                "note": entry.get("note") or "",
                "time": entry.get("updatedAt") or "",
            }
    if problems:
        return fail(problems, "verify-plan.py: not recording; the source is unchanged")
    # Steps in the source's order, so the output does not depend on directory listing order.
    new = dict(doc)
    new["run"] = {"revision": revision, "steps": {sid: recorded[sid] for sid in known if sid in recorded}}
    errs = check_document(new)
    if errs:
        return fail(errs, "verify-plan.py: the recorded run is invalid; the source is unchanged")
    text = json.dumps(new, indent=2, ensure_ascii=False) + "\n"
    target = os.path.abspath(args.file)
    tmp = target + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, target)
    print(f"recorded {len(recorded)} step(s); ignored {ignored} document(s) from another walkthrough revision")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="verify-plan.py", description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("check", help="validate a verify.json")
    p.add_argument("file")
    p.set_defaults(func=cmd_check)
    p = sub.add_parser("build", help="validate a verify.json, then write its pages beside it")
    p.add_argument("file")
    p.set_defaults(func=cmd_build)
    p = sub.add_parser("record-run", help="replace the run section from an exported page store")
    p.add_argument("file")
    p.add_argument("state_dir")
    p.set_defaults(func=cmd_record_run)
    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
