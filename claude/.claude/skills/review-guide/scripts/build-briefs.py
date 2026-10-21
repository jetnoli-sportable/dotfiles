#!/usr/bin/env python3
"""build-briefs.py — write a run's briefs/ from references/briefs.md.

Usage: python3 build-briefs.py <run-dir>

Reads <run>/target.json, <run>/inventory.json and <run>/context.md, and writes:
  briefs/common.md         run context + inventory + skim list + Shared rules
                           (+ the Stack note for a stack), word for word
  briefs/L1.md             one PR or branch;  briefs/L1-<pr>.md per PR in a stack
  briefs/L2.md … L5.md     the lens sections
  briefs/coordinator.md    coordinator part 1 (quick pass)
  briefs/coordinator-2.md  coordinator part 2 (verify), sent when the lenses finish;
                           the orchestrator fills <paths> in its message
Sections are copied verbatim with placeholders filled; nothing is paraphrased.
"""
import json
import os
import re
import sys

SKILL = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))


def section(src, title):
    m = re.search(r"^## " + re.escape(title) + r"[^\n]*\n.*?(?=^## |\Z)", src, re.S | re.M)
    if not m:
        sys.exit(f"build-briefs.py: no '## {title}' section in references/briefs.md")
    return re.sub(r"\n-{3,}\s*$", "\n", m.group(0).rstrip()) + "\n"


def fill(text, **values):
    for key, value in values.items():
        text = text.replace(f"<{key}>", str(value))
    return text


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    run = os.path.abspath(sys.argv[1])
    with open(os.path.join(SKILL, "references", "briefs.md")) as fh:
        src = fh.read()
    with open(os.path.join(run, "target.json")) as fh:
        t = json.load(fh)
    with open(os.path.join(run, "inventory.json")) as fh:
        inv = json.load(fh)
    with open(os.path.join(run, "context.md")) as fh:
        ctx = fh.read().strip()
    stack = t["kind"] == "stack"
    wt, base, head = t["worktree"], t["base"], t["head"]

    rows = ["| file | bucket | +/- | hot |", "|---|---|---|---|"]
    rows += [f"| `{f['path']}` | {f['bucket']} | +{f['added']}/-{f['removed']} | {', '.join(f['hot'])} |"
             for f in inv["files"]]
    read = [f["path"] for f in inv["files"] if f["bucket"] in ("logic", "agent-instructions")]
    skim = [f["path"] for f in inv["files"] if f["bucket"] in ("generated", "rename-only")]
    code = lambda paths: ", ".join(f"`{p}`" for p in paths) or "none"
    common = f"""# Common brief

Run directory: `{run}`
Worktree (read only here): `{wt}` at head `{head}`. Base `{base}`.
Diff: `git -C {wt} diff {base} {head}`; changed ranges of a file:
`git -C {wt} diff -U0 {base} {head} -- <file>`.

{ctx}

## Inventory

Proportion: {json.dumps(inv['proportion'])}. Hot flags: {', '.join(inv['hot']) or 'none'}.

{chr(10).join(rows)}

**Read:** {code(read)}.
**Skim list (don't read):** {code(skim)}.

"""
    common += fill(section(src, "Shared rules"), run=run)
    if stack:
        listing = "\n".join(f"- PR {p['number']} (`{p['head_ref']}`): `{p['base']}..{p['head']}`, worktree `{p['worktree']}`"
                            for p in t["prs"])
        common += "\n" + fill(section(src, "Stack note"), stack=listing, base=base, head=head, worktree=wt)

    out = os.path.join(run, "briefs")
    os.makedirs(out, exist_ok=True)
    written = {"common.md": common}
    l1 = section(src, "L1 Risk")
    if stack:
        for p in t["prs"]:
            n = p["number"]
            written[f"L1-{n}.md"] = fill(l1, report=f"lens-L1-{n}.json", pr=n, base=p["base"], head=p["head"],
                                         worktree=p["worktree"], run=run)
    else:
        pr = t["prs"][0]["number"] if t["prs"] else t.get("branch", "")
        written["L1.md"] = fill(l1, report="lens-L1.json", pr=pr, base=base, head=head, worktree=wt, run=run)
    for n, title in (("L2", "L2 Design"), ("L3", "L3 Intent"), ("L4", "L4 Tests"), ("L5", "L5 Reuse")):
        written[f"{n}.md"] = fill(section(src, title), run=run, worktree=wt, base=base, head=head)
    written["coordinator.md"] = fill(section(src, "Coordinator, part 1: quick pass"), run=run)
    written["coordinator-2.md"] = fill(section(src, "Coordinator, part 2: verify and reconcile"), run=run)
    for name, text in written.items():
        with open(os.path.join(out, name), "w") as fh:
            fh.write(text)
    print(f"{out}: {', '.join(sorted(written))}")


if __name__ == "__main__":
    main()
