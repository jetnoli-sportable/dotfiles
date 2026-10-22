#!/usr/bin/env python3
"""apply_edits.py — apply a clarity sweep's accepted edits to a page source.

Usage: python3 apply_edits.py <page.md> <clarity.json> [--skip K-03,K-07] [--dry-run]

<clarity.json> is the clarity agent's report: {"edits": [{"id", "old", "new", ...}]}.
Edits apply in order; each is applied or refused, never half-applied:
  refused: already applied   new is in the page and covers every occurrence of old (a re-run)
  refused: old not found     the text isn't in the page (or an earlier edit changed it)
  refused: old not unique    old occurs more than once; it must name one place
  refused: protected         old sits in frontmatter, a fenced code block, a <figure>, or a heading,
                             or covers only part of an inline code span
  refused: changes code spans  new has a different number of unpaired backticks from old
                             (adding a whole `span` is fine; a lone backtick is not)
  refused: drops <token>     new has fewer of a code span, number or finding id than old had
  refused: breaks structure  new adds or removes a fence, heading or figure line
  refused: breaks <form>     a renderer form (risk badge, callout, spot, finding chips) would change
Skipped ids (--skip) are listed as skipped. Before the first write, the original page
is copied next to <clarity.json> as <page-name>.pre-clarity.<head>.md, <head> being the
first 7 characters of target.json's "head" in the same directory (no target.json:
<page-name>.pre-clarity.md). A re-run at the same head keeps that copy; a new head gets
its own. Exit 0 whenever it ran.
"""
import argparse
import json
from collections import Counter
import pathlib
import re
import shutil

IDS = r"(?:L\d[\d.]*|C)-\d+"  # same id grammar as build-page.py _IDS; keep the two in sync
INLINE_CODE = re.compile(r"`[^`\n]+`")
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


def structure(text):
    """The lines that shape the rendered page: fences, headings, figure tags."""
    return [ln for ln in text.split("\n") if ln.startswith(("```", "#")) or "<figure" in ln or "</figure>" in ln]


def stray_backticks(text):
    """Backticks not part of a complete inline code span."""
    return text.count("`") - 2 * len(INLINE_CODE.findall(text))


def already_applied(text, old, new):
    # an expanding edit (new contains old) still finds old once after it ran
    if old not in new or new not in text:
        return False
    spans = [(m.start(), m.end()) for m in re.finditer(re.escape(new), text)]
    return all(any(s <= m.start() and m.end() <= e for s, e in spans)
               for m in re.finditer(re.escape(old), text))


def check(text, edit):
    old, new = edit["old"], edit["new"]
    if already_applied(text, old, new):
        return "already applied"
    count = text.count(old)
    if count == 0:
        return "old not found"
    if count > 1:
        return "old not unique"
    lines = text.split("\n")
    start = text.index(old)
    end = start + len(old)
    first = text[:start].count("\n")
    if protected_lines(lines) & set(range(first, first + old.count("\n") + 1)):
        return "protected"
    # an inline code span is only touched whole, so an edit can't rename code
    for span in INLINE_CODE.finditer(text):
        if span.start() < end and start < span.end() and not (start <= span.start() and span.end() <= end):
            return "protected"
    after = text.replace(old, new, 1)
    if structure(text) != structure(after):
        return "breaks structure"
    # adding a whole code span is fine; a lone backtick would open one that swallows the line
    if stray_backticks(old) != stray_backticks(new):
        return "changes code spans"
    lost = Counter(TOKENS.findall(old)) - Counter(TOKENS.findall(new))
    if lost:
        return f"drops {next(iter(lost))}"
    for name, form in FORMS.items():
        if len(form.findall(text)) != len(form.findall(after)):
            return f"breaks {name}"
    return None


def backup_path(page, report):
    # keyed by the reviewed head, so a re-run after new commits backs up the re-synthesised page
    try:
        head = json.loads((report.parent / "target.json").read_text())["head"][:7]
    except (OSError, ValueError, KeyError, TypeError):
        head = ""
    return report.parent / f"{page.stem}.pre-clarity{'.' + head if head else ''}.md"


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
        backup = backup_path(page, report)
        if not backup.exists():  # a re-run at the same commit keeps the first run's original
            shutil.copyfile(page, backup)
        page.write_text(text)
    elif dry and text != original:
        print("dry run: page not written")


if __name__ == "__main__":
    main()
