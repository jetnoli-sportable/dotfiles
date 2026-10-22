#!/usr/bin/env python3
"""html-text.py — a page's readable text, with its headings kept as Markdown.

Usage: html-text.py <page.html>

Drops <head>, <script>, <style>, <svg> and <template>; turns h1-h6 into
`#` headings, list items into `- ` lines, and table rows into `|`-joined lines,
so a summary can name the heading each point came from. Stdlib only.
"""
import re
import sys
from html.parser import HTMLParser

SKIP = {"head", "script", "style", "svg", "template", "noscript"}
BLOCK = {"p", "div", "section", "article", "header", "footer", "main", "aside",
         "blockquote", "pre", "table", "thead", "tbody", "ul", "ol", "dl",
         "dt", "dd", "details", "summary", "figure", "figcaption", "nav"}


class Text(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out = []
        self.skip = 0

    def tag(self, s):
        self.out.append(s)

    def handle_starttag(self, tag, attrs):
        if tag in SKIP:
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
        if tag in SKIP:
            self.skip = max(0, self.skip - 1)
        elif self.skip:
            return
        elif tag in ("td", "th"):
            self.tag(" | ")
        elif re.fullmatch(r"h[1-6]", tag) or tag in BLOCK:
            self.tag("\n")

    def handle_data(self, data):
        if not self.skip:
            self.out.append(re.sub(r"\s+", " ", data))


def main(path):
    parser = Text()
    with open(path, encoding="utf-8", errors="replace") as f:
        parser.feed(f.read())
    text = "".join(parser.out)
    text = re.sub(r"[ \t]+\n", "\n", text)
    text = re.sub(r"\n[ \t]+", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    print(text.strip())


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: html-text.py <page.html>", file=sys.stderr)
        sys.exit(2)
    main(sys.argv[1])
