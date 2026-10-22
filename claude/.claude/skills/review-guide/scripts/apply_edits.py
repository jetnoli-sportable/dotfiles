#!/usr/bin/env python3
"""apply_edits.py — apply a clarity sweep's accepted edits to a page source.

Usage: python3 apply_edits.py <page.md> <clarity.json> [--skip K-03,K-07] [--dry-run]

<clarity.json> is the clarity agent's report: {"edits": [{"id", "old", "new", ...}]}.
Edits apply in order; each is applied or refused, never half-applied:
  refused: old not found     the text isn't in the page (or an earlier edit changed it)
  refused: old not unique    old occurs more than once; it must name one place
  refused: protected         old sits in frontmatter, a fenced code block, a <figure>, or a heading
  refused: drops <token>     new loses a code span, number or finding id that old had
  refused: breaks <form>     a renderer form (risk badge, callout, spot, finding chips) would change
Skipped ids (--skip) are listed as skipped. Before writing, the original page is
copied next to <clarity.json> as <page-name>.pre-clarity.md. Exit 0 whenever it ran.
"""
import argparse
import json
import pathlib
import re
import shutil

IDS = r"(?:L\d[\d.]*|C)-\d+"  # same id grammar as build-page.py _IDS; keep the two in sync
TOKENS = re.compile(rf"`[^`\n]+`|{IDS}|\d[\d,.]*\d|\d")
FORMS = {
    "risk badge": re.compile(r"^\*\*Risk: ", re.M),
    "recommendation callout": re.compile(r"^\*\*Recommendation:\*\*", re.M),
    "conclusion callout": re.compile(r"^\*\*Conclusion\.\*\*", re.M),
    "ranked spot": re.compile(r"^\*\*\d+\. ", re.M),
    "finding chips": re.compile(rf"\*\*(?:#\d+ · )?{IDS}(?:(?:, | to ){IDS})*\*\* (?:high|medium|low)\b"),
}


def protected_lines(lines):
    out, fence, figure = set(), False, False
    if lines and lines[0] == "---":
        end = lines.index("---", 1)
        out.update(range(end + 1))
    for i, line in enumerate(lines):
        if line.startswith("```"):
            fence = not fence
            out.add(i)
        elif "<figure" in line:
            figure = True
        if fence or figure or line.startswith("#"):
            out.add(i)
        if "</figure>" in line:
            figure = False
    return out


def check(text, edit):
    old, new = edit["old"], edit["new"]
    count = text.count(old)
    if count == 0:
        return "old not found"
    if count > 1:
        return "old not unique"
    lines = text.split("\n")
    first = text[:text.index(old)].count("\n")
    if protected_lines(lines) & set(range(first, first + old.count("\n") + 1)):
        return "protected"
    lost = [t for t in TOKENS.findall(old) if t not in new]
    if lost:
        return f"drops {lost[0]}"
    after = text.replace(old, new, 1)
    for name, form in FORMS.items():
        if len(form.findall(text)) != len(form.findall(after)):
            return f"breaks {name}"
    return None


def main():
    ap = argparse.ArgumentParser(description="Apply a clarity sweep's accepted edits to a page source.")
    ap.add_argument("page", type=pathlib.Path)
    ap.add_argument("report", type=pathlib.Path, help="clarity.json")
    ap.add_argument("--skip", default="", help="comma-separated edit ids to leave out, e.g. K-03,K-07")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    page, report, dry = a.page, a.report, a.dry_run
    skip = set(a.skip.split(",")) - {""}
    edits = json.loads(report.read_text())["edits"]
    original = text = page.read_text()
    applied = 0
    for e in edits:
        if e["id"] in skip:
            print(f"{e['id']}: skipped")
            continue
        why = check(text, e)
        if why:
            print(f"{e['id']}: refused: {why}")
            continue
        text = text.replace(e["old"], e["new"], 1)
        applied += 1
        print(f"{e['id']}: applied")
    print(f"{applied} applied, {len(edits) - applied} not")
    if applied and not dry:
        shutil.copyfile(page, report.parent / f"{page.stem}.pre-clarity.md")
        page.write_text(text)
    elif dry and text != original:
        print("dry run: page not written")


if __name__ == "__main__":
    main()
