#!/usr/bin/env python3
"""html-text.py — a page's readable text, with its headings kept as Markdown.

Usage: html-text.py <page.html>

Drops <head>, <script>, <style>, <svg> and <template>; turns h1-h6 into
`#` headings, list items into `- ` lines, and table rows into `|`-joined lines,
so a summary can name the heading each point came from. Stdlib only.

A page that renders in the browser keeps its body in a script block:
`<script type="text/markdown">` (the dossier page template) or
`<script type="application/json" id="src">` holding a JSON string. Those
bodies are printed as they are, since they are already Markdown. Any other
page whose text comes out nearly empty gets a warning on stderr, because the
content is probably in a script the converter can't read (the decision-page
and review-page kits keep theirs in `<script id="spec" type="application/json">`).
"""
import json
import re
import sys
from html.parser import HTMLParser

SKIP = {"head", "script", "style", "svg", "template", "noscript"}
BLOCK = {"p", "div", "section", "article", "header", "footer", "main", "aside",
         "blockquote", "pre", "table", "thead", "tbody", "ul", "ol", "dl",
         "dt", "dd", "details", "summary", "figure", "figcaption", "nav"}
# below this share of the input, or with no heading at all, the text is suspect
LOW_TEXT_RATIO = 0.02


def source_kind(attrs):
    attrs = dict(attrs)
    kind = (attrs.get("type") or "").lower()
    if kind == "text/markdown":
        return "markdown"
    if kind == "application/json" and attrs.get("id") == "src":
        return "json"
    return None


class Text(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out = []
        self.skip = 0
        self.source = None  # "markdown" | "json" while inside a page-source script
        self.raw = []

    def tag(self, s):
        self.out.append(s)

    def handle_starttag(self, tag, attrs):
        if tag == "script" and not self.skip and source_kind(attrs):
            self.source = source_kind(attrs)
            self.raw = []
        elif tag in SKIP:
            self.skip += 1
        elif self.skip:
            return
        elif re.fullmatch(r"h[1-6]", tag):
            self.tag("\n\n" + "#" * int(tag[1]) + " ")
        elif tag == "li":
            self.tag("\n- ")
        elif tag == "tr":
            self.tag("\n| ")
        elif tag in ("td", "th"):
            pass
        elif tag == "br":
            self.tag("\n")
        elif tag in BLOCK:
            self.tag("\n\n")

    def handle_endtag(self, tag):
        if tag == "script" and self.source:
            self.tag("\n\n" + self.source_text() + "\n\n")
            self.source = None
        elif tag in SKIP:
            self.skip = max(0, self.skip - 1)
        elif self.skip:
            return
        elif tag in ("td", "th"):
            self.tag(" | ")
        elif re.fullmatch(r"h[1-6]", tag) or tag in BLOCK:
            self.tag("\n")

    def handle_data(self, data):
        if self.source:
            self.raw.append(data)
        elif not self.skip:
            self.out.append(re.sub(r"\s+", " ", data))

    def source_text(self):
        body = "".join(self.raw).strip()
        if self.source == "json":
            try:
                body = json.loads(body)
            except ValueError:
                return ""
            if not isinstance(body, str):
                return ""
        # the source keeps its own line breaks; tag the lines so the cleanup
        # below leaves code indentation alone
        return "\n".join("\0" + line for line in body.splitlines())


def main(path):
    parser = Text()
    with open(path, encoding="utf-8", errors="replace") as f:
        html = f.read()
    parser.feed(html)
    text = "".join(parser.out)
    text = re.sub(r"[ \t]+\n", "\n", text)
    text = re.sub(r"\n[ \t]+", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    text = text.replace("\0", "").strip()
    print(text)
    has_heading = re.search(r"^#{1,6} ", text, re.M)
    if not has_heading or len(text) < LOW_TEXT_RATIO * len(html):
        hint = ""
        if re.search(r"<script[^>]*application/json", html, re.I):
            hint = " It has a JSON <script> block; the content is likely there."
        print(f"html-text.py: warning: only {len(text)} characters of text from "
              f"{len(html)} bytes of HTML{'' if has_heading else ' and no headings'}; "
              f"the page probably renders in the browser.{hint}", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: html-text.py <page.html>", file=sys.stderr)
        sys.exit(2)
    main(sys.argv[1])
