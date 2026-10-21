#!/usr/bin/env python3
"""cite_check.py — confirm every finding's excerpt exists near its cited line.

Usage: python3 cite_check.py <target.json> <input.json>

<input.json> is a lens report (lens-L<n>.json) or verified.json: an object with
`findings` (plus optional `checked_clean`, `rulings`, which pass through).
Output goes next to the input, original untouched: lens-L1.json ->
lens-L1.cited.json. Each finding gains `cite`:
  ok       excerpt found on the cited line
  moved    excerpt found 1-3 lines away; `line` is corrected, `cited_line` keeps the original
  missing  excerpt not within 3 lines (fix the finding or drop it)
Exit 0 whenever the check ran; the verdicts are in the output.

target.json (written by the orchestrator; this script only uses git against
pinned SHAs, never gh):
  {"kind": "branch"|"pr"|"stack", "repo": "owner/name", "repo_path": "<abs path>",
   "cli": "gh"|"pgh", "base": "<sha: merge-base of base ref and head>", "head": "<sha>",
   "worktree": "<abs path: detached checkout at head>", "branch": "<head branch>",
   "prs": [{"number": 541, "head_ref": "...", "base": "<sha>", "head": "<sha>",
            "worktree": "<abs path>"}, ...]}
base/head at top level are the range ends. A finding's `pr` is a PR number, or
head_ref (the branch name) for a branch target.

Commit choice: an L1 finding uses its own PR's base/head (falling back to the
range ends if `pr` matches no entry); every other lens uses the range ends.
`side` ("head" default, or "base") picks which. file == "context.md" is read
from the directory holding target.json, not from git.
"""
import json
import os
import subprocess
import sys

TOLERANCE = 3


def commit_for(target, f):
    ends = target
    if f.get("lens") == "L1":
        for p in target.get("prs", []):
            if str(f.get("pr")) in (str(p.get("number")), str(p.get("head_ref"))):
                ends = p
                break
    return ends["base"] if f.get("side", "head") == "base" else ends["head"]


def first_line(excerpt):
    # Ruling: a multi-line excerpt is matched on its first non-empty line.
    for ln in excerpt.splitlines():
        if ln.strip():
            return ln.strip()
    return ""


def load_lines(target, tdir, commit, path, cache):
    key = (commit, path)
    if key not in cache:
        if path == "context.md":
            try:
                with open(os.path.join(tdir, path), encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError:
                text = None
        else:
            r = subprocess.run(["git", "-C", target["repo_path"], "show", f"{commit}:{path}"],
                               capture_output=True)
            text = r.stdout.decode("utf-8", "replace") if r.returncode == 0 else None
        cache[key] = None if text is None else text.splitlines()
    return cache[key]


def check(target, tdir, f, cache):
    lines = load_lines(target, tdir, commit_for(target, f), f["file"], cache)
    needle = first_line(f.get("excerpt", ""))
    cited = int(f["line"])
    if lines is None or not needle:
        return "missing", cited
    # Substring match on the trimmed line, nearest candidate wins.
    for d in range(TOLERANCE + 1):
        for ln in ((cited,) if d == 0 else (cited - d, cited + d)):
            if 1 <= ln <= len(lines) and needle in lines[ln - 1].strip():
                return ("ok" if d == 0 else "moved"), ln
    return "missing", cited


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    tpath, ipath = sys.argv[1:]
    with open(tpath) as fh:
        target = json.load(fh)
    with open(ipath) as fh:
        report = json.load(fh)
    tdir = os.path.dirname(os.path.abspath(tpath))
    cache = {}
    for f in report["findings"]:
        cite, line = check(target, tdir, f, cache)
        if cite == "moved":
            f["cited_line"] = f["line"]
        f["cite"], f["line"] = cite, line
    out = os.path.splitext(ipath)[0] + ".cited.json"
    with open(out, "w") as fh:
        json.dump(report, fh, indent=2)
        fh.write("\n")
    counts = {k: sum(f["cite"] == k for f in report["findings"]) for k in ("ok", "moved", "missing")}
    print(f"{out}: {counts}")


if __name__ == "__main__":
    main()
