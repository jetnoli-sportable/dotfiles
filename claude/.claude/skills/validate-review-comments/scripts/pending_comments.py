#!/usr/bin/env python3
"""pending_comments.py — tie each pending review comment to the code it sits on.

Usage: python3 pending_comments.py <target.json> <comments.json>

<comments.json> is the raw `gh api .../pulls/<n>/reviews/<id>/comments` array; for a
stack, the arrays of every PR's pending review joined into one. Each comment's PR is
read from its `pull_request_url`. Pending comments carry no `line`, `side` or
`subject_type`: the line comes from `diff_hunk`, which ends on the commented line.
Parse the last `@@ -a,b +c,d @@` header and count to the end; a last line starting
`-` is on the base side, anything else on the head side (`side` LEFT/RIGHT wins when
the API does send it). A comment with `subject_type: file` or no hunk is file-level.

target.json is review-guide's (stage 1), read for `repo_path`, `base`, `head` and
`prs` [{number, base, head}]; this script only runs git against those SHAs, never gh.

Writes, next to comments.json:
  comments.mapped.json  {"comments": [record, ...], "removed": [id, ...],
                         "files_changed": {pr: [path, ...] | null}}
  state.next.json       the run state; the skill renames it to state.json after publishing
A previous state.json in the same directory turns on re-run mode. Each record:
  id, url, pr, n (stable page number), path, side ("head"|"base"|null), line,
  drafted_line, drafted (the hunk's last line as drafted), cite, ambiguous,
  excerpt_start, excerpt (file lines around `line`; for `gone`, the hunk's last
  lines as drafted), later, changed, updated_at, body
cite:
  ok      the drafted text is on the drafted line
  moved   found elsewhere in the file; `line` is the nearest match, `drafted_line` the
          original, `ambiguous` true when more than one candidate fits
  gone    the text, or the file, is not there on the comment's side
  file    a file-level comment: `line` null, no excerpt
Matching compares whole lines (trailing space ignored): the drafted line together
with the hunk line before it first, then the drafted line alone. The drafted line
number counts as `ok` only when it is among those matches; a lone match on a line
that recurs in the file (no paired match to confirm it) sets `ambiguous`.
later (stack only): one {pr, survives, ambiguous} per later PR, survives meaning the
drafted line, with the hunk line before it when there is one, is still in that PR
head's file; ambiguous when it is there more than once. Head-side line comments only.
changed: always true on a first run; on a re-run, true when the comment is new, its
`updated_at` moved, its file changed between the previously checked head (or base,
for a base-side comment) and now, or its `later` result changed.
files_changed (re-run only, else {}): per PR checked last time, the files that
changed between the previous head and base and the current ones, so a kept verdict
whose evidence lies in another file can be re-judged; null when git could not tell.
Page numbers are never reused: state keeps `next_n`, the next number to hand out.
Exit 0 whenever the check ran.
"""
import json
import os
import re
import subprocess
import sys

HEADER = re.compile(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@")
BEFORE, AFTER = 3, 2  # excerpt lines around the commented line


def pr_of(c):
    return int(c["pull_request_url"].rstrip("/").rsplit("/", 1)[1])


def parse_hunk(hunk, side=None):
    """(side, line, drafted, previous, tail) from the hunk's last header to its end.
    tail is the last few (line, text) pairs on that side, the code as drafted. side,
    when the API sent one, wins over the side the hunk's last line implies."""
    lines = [ln for ln in hunk.split("\n") if not ln.startswith("\\")]
    start = max(i for i, ln in enumerate(lines) if HEADER.match(ln))
    old, new = (int(x) for x in HEADER.match(lines[start]).groups())
    body = lines[start + 1:]
    seen = {"base": [], "head": []}
    for ln in body:
        mark, text = ln[:1], ln[1:]
        if mark != "+":
            seen["base"].append((old, text))
            old += 1
        if mark != "-":
            seen["head"].append((new, text))
            new += 1
    side = side or ("base" if body[-1].startswith("-") else "head")
    line, drafted = seen[side][-1]
    previous = seen[side][-2][1] if len(seen[side]) > 1 else None
    return side, line, drafted, previous, seen[side][-(BEFORE + 1):]


def git(repo, *args):
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True)
    return r.stdout.decode("utf-8", "replace") if r.returncode == 0 else None


def file_lines(repo, sha, path, cache):
    if (sha, path) not in cache:
        text = git(repo, "show", f"{sha}:{path}")
        cache[sha, path] = None if text is None else text.splitlines()
    return cache[sha, path]


def same(a, b):
    return a.rstrip() == b.rstrip()


def matches(lines, drafted, previous):
    """(alone, paired): line numbers holding the drafted text, and those of them
    preceded by the hunk line before it."""
    alone = [i for i, t in enumerate(lines, 1) if same(t, drafted)]
    paired = [i for i in alone if previous is not None and i > 1 and same(lines[i - 2], previous)]
    return alone, paired


def locate(lines, line, drafted, previous):
    """(cite, line, ambiguous) for the drafted text in this file."""
    if lines is None:
        return "gone", line, False
    alone, paired = matches(lines, drafted, previous)
    found = paired or alone
    if not found:
        return "gone", line, False
    if line in found:
        # a lone match on a recurring line (`}`, a blank) is a guess
        return "ok", line, not paired and len(alone) > 1
    return "moved", min(found, key=lambda i: abs(i - line)), len(found) > 1


def pr_ends(target, pr):
    for p in target.get("prs", []):
        if p.get("number") == pr:
            return p
    return target


def changed_files(repo, old, new, cache):
    if (old, new) not in cache:
        out = git(repo, "diff", "--name-only", old, new)
        cache[old, new] = None if out is None else set(out.split())
    return cache[old, new]


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    tpath, cpath = sys.argv[1:]
    with open(tpath) as fh:
        target = json.load(fh)
    with open(cpath) as fh:
        raw = json.load(fh)
    run = os.path.dirname(os.path.abspath(cpath))
    prev = None
    if os.path.exists(os.path.join(run, "state.json")):
        with open(os.path.join(run, "state.json")) as fh:
            prev = json.load(fh)
    repo, cache, diffs = target["repo_path"], {}, {}
    order = [p["number"] for p in target.get("prs", [])]

    records = []
    for c in raw:
        pr = pr_of(c)
        ends = pr_ends(target, pr)
        r = {"id": c["id"], "url": c.get("html_url"), "pr": pr, "path": c["path"],
             "updated_at": c.get("updated_at"), "body": c.get("body", ""), "later": []}
        hunk = c.get("diff_hunk") or ""
        if c.get("subject_type") == "file" or not HEADER.search(hunk):
            r.update(side=None, line=None, drafted_line=None, drafted=None, cite="file",
                     ambiguous=False, excerpt_start=None, excerpt=[])
            records.append(r)
            continue
        side, line, drafted, previous, tail = parse_hunk(
            hunk, {"LEFT": "base", "RIGHT": "head"}.get(c.get("side")))
        lines = file_lines(repo, ends[side], c["path"], cache)
        cite, at, ambiguous = locate(lines, line, drafted, previous)
        if cite == "gone":
            start, excerpt = tail[0][0], [text for _, text in tail]
        else:
            start = max(1, at - BEFORE)
            excerpt = lines[start - 1:at + AFTER]
        r.update(side=side, line=at, drafted_line=line, drafted=drafted, cite=cite,
                 ambiguous=ambiguous, excerpt_start=start, excerpt=excerpt)
        if side == "head" and pr in order:
            for p in target["prs"][order.index(pr) + 1:]:
                later = file_lines(repo, p["head"], c["path"], cache)
                alone, paired = matches(later or [], drafted, previous)
                found = alone if previous is None else paired
                r["later"].append({"pr": p["number"], "survives": bool(found), "ambiguous": len(found) > 1})
        records.append(r)

    old = (prev or {}).get("comments", {})
    old_ends = {"head": (prev or {}).get("heads", {}), "base": (prev or {}).get("bases", {})}
    nxt = (prev or {}).get("next_n", max((v["n"] for v in old.values()), default=0) + 1) - 1
    for r in sorted(records, key=lambda r: (order.index(r["pr"]) if r["pr"] in order else 0,
                                            r["path"], r["line"] or 0, r["id"])):
        was = old.get(str(r["id"]))
        if was:
            r["n"] = was["n"]
        else:
            nxt += 1
            r["n"] = nxt
        if (prev is None or not was or was.get("updated_at") != r["updated_at"]
                or was.get("later", r["later"]) != r["later"]):
            r["changed"] = True
            continue
        side = r["side"] or "head"
        then, now = old_ends[side].get(str(r["pr"])), pr_ends(target, r["pr"])[side]
        files = changed_files(repo, then, now, diffs) if then and then != now else set()
        r["changed"] = files is None or r["path"] in files
    records.sort(key=lambda r: r["n"])
    ids = {str(r["id"]) for r in records}
    removed = sorted(int(i) for i in old if i not in ids)
    prs = sorted({r["pr"] for r in records})
    moved = {}
    for pr in prs:
        if str(pr) not in old_ends["head"]:
            continue
        files = set()
        for side in ("head", "base"):
            then, now = old_ends[side].get(str(pr)), pr_ends(target, pr)[side]
            diff = changed_files(repo, then, now, diffs) if then and then != now else set()
            files = None if files is None or diff is None else files | diff
        moved[str(pr)] = None if files is None else sorted(files)

    with open(os.path.join(run, "comments.mapped.json"), "w") as fh:
        json.dump({"comments": records, "removed": removed, "files_changed": moved}, fh, indent=2)
        fh.write("\n")
    state = {"heads": {str(pr): pr_ends(target, pr)["head"] for pr in prs},
             "bases": {str(pr): pr_ends(target, pr)["base"] for pr in prs},
             "next_n": nxt + 1,
             "comments": {str(r["id"]): {"n": r["n"], "updated_at": r["updated_at"], "path": r["path"],
                                         "pr": r["pr"], "later": r["later"]} for r in records}}
    with open(os.path.join(run, "state.next.json"), "w") as fh:
        json.dump(state, fh, indent=2)
        fh.write("\n")
    counts = {k: sum(r["cite"] == k for r in records) for k in ("ok", "moved", "gone", "file")}
    print(f"{len(records)} comments {counts}, {sum(r['changed'] for r in records)} to check, "
          f"{len(removed)} removed")


if __name__ == "__main__":
    main()
