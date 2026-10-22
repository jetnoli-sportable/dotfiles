#!/usr/bin/env python3
"""Render a dossier Markdown page (<name>.md) to <name>.html.

    uv run -q --with markdown --with pygments python build-page.py <dossier-dir> <page-name>

Reads <dossier-dir>/<page-name>.md and writes <dossier-dir>/<page-name>.html. The
.md is the source: edit it, re-run this, republish the HTML to its URL.
Frontmatter keys: title, eyebrow, updated. Each `## ` heading becomes a section and
a nav-rail entry. Fenced code is highlighted by Pygments when it is installed.
The shared core (frontmatter, sections, nav rail, template) is mdpage.py; this file adds
review-guide's own conventions.

Plain-Markdown conventions the page styles (see SKILL.md stage 7):
  **L1-03** medium, confirmed   finding id, severity and verdict chips
  **Risk: low.** ...            risk badge callout
  **Recommendation:** ...       callout (accent), when it starts a paragraph
  **Conclusion.** ...           callout (neutral), when it starts a paragraph
  **1. title** under a "### Where to look" heading   a ranked card with a severity stripe
"""
import pathlib
import re
import sys

import mdpage

SEVERITIES = ("high", "medium", "low")

# same id grammar as apply_edits.py IDS / "finding chips"; keep the two in sync
_IDS = r"(?:#\d+ · )?(?:L\d[\d.]*|C)-\d+(?:(?:, | to )(?:L\d[\d.]*|C)-\d+)*"
FINDING = re.compile(rf"<strong>({_IDS})</strong>(?: (high|medium|low)\b(?:, (confirmed|plausible)\b)?)?")
TITLE_VERDICT = re.compile(r"\b(Confirmed|Plausible), (high|medium|low)\b")
RISK = re.compile(r"<p><strong>Risk: ([^<]+?)\.?</strong>")
SPOT_START = re.compile(r"<p><strong>(\d+)\.\s(.*?)</strong>", re.S)
SPOTS_HEADING = re.compile(r"<h3[^>]*>Where to look[^<]*</h3>\n")
BLOCK_END = re.compile(r"<h[23][ >]|</section>")


def chips(sev, verdict=None):
    out = f'<span class="chip sev-{sev}">{sev}</span>'
    if verdict:
        out += f' <span class="chip v-{verdict.lower()}">{verdict.lower()}</span>'
    return out


def top_severity(text):
    return next((s for s in SEVERITIES if re.search(rf"\b{s}\b", text, re.I)), None)


def finding_chips(body):
    return FINDING.sub(lambda m: f'<span class="fid">{m[1]}</span>' + (f" {chips(m[2], m[3])}" if m[2] else ""), body)


def callouts(body):
    body = RISK.sub(lambda m: f'<p class="callout risk sev-{top_severity(m[1]) or "low"}">'
                              f'<span class="badge">Risk: {m[1]}</span>', body)
    body = body.replace("<p><strong>Recommendation:</strong>",
                        '<p class="callout rec"><strong>Recommendation:</strong>')
    body = body.replace("<p><strong>Conclusion.</strong>",
                        '<p class="callout concl"><strong>Conclusion.</strong>')
    # a recommendation mid-paragraph keeps its place but still stands out
    return body.replace("<strong>Recommendation:</strong>", '<strong class="lead">Recommendation:</strong>')


def spot_cards(body):
    """Wrap each `**N. title**` block under a "Where to look" h3 in a card."""
    head = SPOTS_HEADING.search(body)
    if not head:
        return body
    start = head.end()
    end_m = BLOCK_END.search(body, start)
    end = end_m.start() if end_m else len(body)
    segment = body[start:end]
    starts = [m.start() for m in SPOT_START.finditer(segment)]
    if not starts:
        return body
    cards = [segment[:starts[0]]]
    for i, s in enumerate(starts):
        block = segment[s:starts[i + 1] if i + 1 < len(starts) else len(segment)]
        m = SPOT_START.match(block)
        # the title's own verdict, then the highest chip inside, then any severity word
        verdict = TITLE_VERDICT.search(m[2])
        sev = (verdict[2] if verdict else None) or max(
            re.findall(r'class="chip sev-(high|medium|low)"', block),
            key=SEVERITIES[::-1].index, default=None) or top_severity(m[2]) or "none"
        title = TITLE_VERDICT.sub(lambda t: chips(t[2], t[1]), m[2])
        cards.append(f'<div class="spot sev-{sev}">\n<p class="spot-title"><span class="rank">{m[1]}</span>'
                     f'<strong>{title}</strong>{block[m.end():]}</div>\n')
    return body[:start] + "".join(cards) + body[end:]


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: build-page.py <dossier-dir> <page-name>   (renders <page-name>.md)")
    count = mdpage.build(pathlib.Path(sys.argv[1]), sys.argv[2].removesuffix(".md"),
                         generator="the review-guide skill's <code>build-page.py</code>",
                         rail_key="review-guide:rail",
                         # chips first: spot_cards reads them to rank a card whose title names no severity
                         transform=lambda body: spot_cards(callouts(finding_chips(body))))
    print(f"{sys.argv[2].removesuffix('.md')}.html: {count} sections")


if __name__ == "__main__":
    main()
