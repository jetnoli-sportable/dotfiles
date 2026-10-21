#!/usr/bin/env python3
"""Render a dossier Markdown page (<name>.md) to <name>.html.

    uv run -q --with markdown python build-page.py <dossier-dir> <page-name>

Reads <dossier-dir>/<page-name>.md and writes <dossier-dir>/<page-name>.html. The
.md is the source: edit it, re-run this, republish the HTML to its URL.
Frontmatter keys: title, eyebrow, updated. Each `## ` heading becomes a section and
a nav-rail entry.
"""
import html
import pathlib
import re
import sys

import markdown

TEMPLATE = pathlib.Path(__file__).resolve().parent.parent / "templates" / "page.template.html"


def split_frontmatter(text):
    meta = {}
    if text.startswith("---\n"):
        end = text.index("\n---\n", 4)
        for line in text[4:end].splitlines():
            key, _, value = line.partition(":")
            meta[key.strip()] = value.strip()
        text = text[end + 5:]
    return meta, text


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: build-page.py <dossier-dir> <page-name>   (renders <page-name>.md)")
    dossier = pathlib.Path(sys.argv[1])
    name = sys.argv[2].removesuffix(".md")
    src = dossier / f"{name}.md"
    if not src.is_file():
        raise SystemExit(f"build-page.py: source not found: {src}")
    meta, text = split_frontmatter(src.read_text())
    md = markdown.Markdown(extensions=["tables", "fenced_code", "toc"],
                           extension_configs={"toc": {"toc_depth": "2-2"}})
    body = md.convert(text)
    # each h2 opens a new <section> so the nav rail can scroll to it
    body = re.sub(r'<h2 id="([^"]+)">', r'</section>\n<section id="\1">\n<h2>', body)
    body = body.replace("<table>", '<div class="tw"><table>').replace("</table>", "</table></div>")
    nav = ['    <li><a href="#top">Overview</a></li>'] + [
        f'    <li><a href="#{t["id"]}">{html.escape(t["name"])}</a></li>' for t in md.toc_tokens]
    page = TEMPLATE.read_text()
    for key, value in {
        "__TITLE__": html.escape(meta.get("title", name)),
        "__EYEBROW__": html.escape(meta.get("eyebrow", "")),
        "__UPDATED__": html.escape(meta.get("updated", "")),
        "__SOURCE__": f"{name}.md",
        "__NAV__": "\n".join(nav),
        "__BODY__": body,
    }.items():
        page = page.replace(key, value)
    (dossier / f"{name}.html").write_text(page)
    print(f"{name}.html: {len(md.toc_tokens)} sections")


if __name__ == "__main__":
    main()
