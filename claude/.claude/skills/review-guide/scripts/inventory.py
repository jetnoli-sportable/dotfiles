#!/usr/bin/env python3
"""inventory.py — bucket every changed line of a diff and set hot flags.

Usage: inventory.py REPO BASE HEAD [--words N] [--generated GLOB ...]

Uses only git against the given SHAs (never gh). Prints JSON on stdout.
Buckets, first match wins: rename-only, generated, tests, agent-instructions,
docs, logic. "lines" is added + removed; binary files count 0.
"""
import argparse, json, re, subprocess, sys

LOCKFILES = {"package-lock.json", "yarn.lock", "pnpm-lock.yaml", "poetry.lock",
             "uv.lock", "Cargo.lock", "go.sum", "Gemfile.lock", "composer.lock"}
# Built outputs of docgen; applied when the head tree has docs/HUB.html.
DOCGEN_GENERATED = ["docs/**/*.html", "docs/INDEX.md", "docs/HUB.html"]
TEST_RE = re.compile(r"(^|/)(tests?|__tests__|testing|automated_testing)/|_test\.\w+$|\.(test|spec)\.\w+$|(^|/)(test_[^/]*|conftest)\.py$")
AGENT_RE = re.compile(r"(^|/)(SKILL|AGENTS|CLAUDE)\.md$|(^|/)prompts?/|\.prompt(\.md)?$")
DOC_EXT = (".md", ".txt", ".rst", ".adoc")
BANNER_RE = re.compile(r"do not edit|code generated", re.I)
PATH_HOT = [("migrations", re.compile(r"(^|/)migrations?/")),
            ("auth", re.compile(r"(^|/)auth[^/]*(/|\.\w+$)", re.I)),
            ("terraform", re.compile(r"\.tf$")),
            ("ci", re.compile(r"(^|/)\.github/workflows/"))]
LINE_HOT = [("locking", re.compile(r"\bflock\b|\b[Mm]utex\b|\bsync\.(RW)?Mutex\b|\.Lock\(\)")),
            ("destructive", re.compile(r"\brm\s+-\w*[rf]\w*\b|\bDROP\s+(TABLE|DATABASE|SCHEMA)\b|\bTRUNCATE\b|git\s+reset\s+--hard", re.I))]
PLAN_RE = re.compile(r"(^|/)docs/plans/[^/]+\.md$")
BUCKETS = ["rename-only", "generated", "tests", "agent-instructions", "docs", "logic"]


def git(repo, *args, stdin=None, check=True):
    r = subprocess.run(["git", "-C", repo, "-c", "core.quotepath=false", *args],
                       input=stdin, capture_output=True, text=True, errors="replace")
    if r.returncode:
        if not check:
            return None
        sys.exit("git %s failed: %s" % (" ".join(args), r.stderr.strip()))
    return r.stdout


def glob_re(g):  # ** crosses dirs, * and ? do not
    out, i = "", 0
    while i < len(g):
        if g.startswith("**/", i): out += "(?:.*/)?"; i += 3
        elif g.startswith("**", i): out += ".*"; i += 2
        elif g[i] == "*": out += "[^/]*"; i += 1
        elif g[i] == "?": out += "[^/]"; i += 1
        else: out += re.escape(g[i]); i += 1
    return re.compile("^" + out + "$")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("repo"); ap.add_argument("base"); ap.add_argument("head")
    ap.add_argument("--words", type=int, default=0, help="PR body word count")
    ap.add_argument("--generated", action="append", default=[], help="repo-local generated glob")
    a = ap.parse_args()
    repo, base, head = a.repo, a.base, a.head

    gen_globs = list(a.generated)
    if git(repo, "ls-tree", head, "docs/HUB.html").strip():
        gen_globs += DOCGEN_GENERATED
    gen_res = [glob_re(g) for g in gen_globs]

    # name-status -z: "R100\0old\0new\0" / "M\0path\0"
    tok = git(repo, "diff", "--name-status", "-M", "-z", base, head).split("\0")
    entries, i = [], 0
    while i < len(tok) and tok[i]:
        st = tok[i]
        if st[0] in "RC":
            entries.append((st, tok[i + 1], tok[i + 2])); i += 3
        else:
            entries.append((st, None, tok[i + 1])); i += 2
    # numstat -z: "a\tr\tpath\0" or "a\tr\t\0old\0new\0"
    ntok = git(repo, "diff", "--numstat", "-M", "-z", base, head).split("\0")
    counts, i = {}, 0
    while i < len(ntok) and ntok[i]:
        add, rem, path = ntok[i].split("\t", 2)
        if path == "":
            path = ntok[i + 2]; i += 3
        else:
            i += 1
        counts[path] = (0, 0) if add == "-" else (int(add), int(rem))

    attr = {}
    live = [p for st, _, p in entries if st[0] != "D"]
    if live:
        out = git(repo, "check-attr", "--source=" + head, "-z", "--stdin",
                  "linguist-generated", stdin="\0".join(live) + "\0").split("\0")
        for j in range(0, len(out) - 2, 3):
            attr[out[j]] = out[j + 2]

    # added lines per file (for hot flags): -U0 diff, track +++ headers
    added, cur = {}, None
    for line in git(repo, "diff", "-U0", "-M", "--no-color", base, head).splitlines():
        if line.startswith("+++ "):
            cur = line[6:].split("\t")[0] if line.startswith("+++ b/") else None
        elif line.startswith("+") and cur:
            added.setdefault(cur, []).append(line[1:])

    def banner(p):
        out = git(repo, "show", "%s:%s" % (head, p), check=False)
        return out is not None and any(BANNER_RE.search(l) for l in out.splitlines()[:5])

    files, plan_lines = [], 0
    for st, old, p in entries:
        ad, rm = counts.get(p, (0, 0))
        name = p.rsplit("/", 1)[-1]
        if st == "R100":
            b = "rename-only"
        elif attr.get(p) in ("set", "true") or name in LOCKFILES \
                or any(r.match(p) for r in gen_res) or (st[0] != "D" and banner(p)):
            b = "generated"
        elif TEST_RE.search(p):
            b = "tests"
        elif AGENT_RE.search(p):
            b = "agent-instructions"
        elif name.endswith(DOC_EXT):
            b = "docs"
        else:
            b = "logic"
        if b == "rename-only":
            ad = rm = 0
        hot = set()
        if b not in ("rename-only", "generated", "docs"):
            hot |= {n for n, r in PATH_HOT if r.search(p)}
        if b == "logic":  # line patterns: code only, so prose/fixtures never flag
            for l in added.get(p, []):
                hot |= {n for n, r in LINE_HOT if r.search(l)}
        if st[0] == "A" and PLAN_RE.search(p):
            plan_lines += ad
        files.append({"path": p, "old_path": old if st[0] == "R" else None,
                      "bucket": b, "added": ad, "removed": rm, "hot": sorted(hot)})

    totals = {b: {"files": 0, "added": 0, "removed": 0, "lines": 0} for b in BUCKETS}
    for f in files:
        t = totals[f["bucket"]]
        t["files"] += 1; t["added"] += f["added"]; t["removed"] += f["removed"]
        t["lines"] += f["added"] + f["removed"]
    logic = totals["logic"]["lines"]
    expl = a.words + plan_lines
    json.dump({"base": base, "head": head, "files": files, "totals": totals,
               "hot": sorted({h for f in files for h in f["hot"]}),
               "proportion": {"words": a.words, "plan_lines": plan_lines,
                              "explanation": expl, "logic_lines": logic,
                              "ratio": round(expl / logic, 3) if logic else None}},
              sys.stdout, indent=1)
    print()


main()
