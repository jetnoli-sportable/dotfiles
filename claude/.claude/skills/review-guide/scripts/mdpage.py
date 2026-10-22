"""mdpage.py: the dossier Markdown-to-page core that review-guide's and pragmatic-review's
build-page.py share. Each generator imports it from this folder, found through its own
realpath so the stow symlinks resolve; the page shell is templates/page.template.html.

A generator supplies its own conventions as two hooks:
  prepare(text, stash) -> text   Markdown in, Markdown out, before conversion. stash(html)
                                 returns a placeholder paragraph that becomes that HTML.
  transform(body) -> body        HTML in, HTML out, after the sections are wrapped.
"""
import html
import pathlib
import re

import markdown

TEMPLATE = pathlib.Path(__file__).resolve().parent.parent / "templates" / "page.template.html"
SLOT = re.compile(r"<p>mdpage-slot-(\d+)</p>")


def split_frontmatter(text):
    meta = {}
    if text.startswith("---\n"):
        end = text.index("\n---\n", 4)
        for line in text[4:end].splitlines():
            key, _, value = line.partition(":")
            meta[key.strip()] = value.strip()
        text = text[end + 5:]
    return meta, text


def build(dossier, name, *, generator, rail_key, prepare=None, transform=None, head="", script=""):
    """Render <dossier>/<name>.md to <dossier>/<name>.html; return the section count."""
    src = dossier / f"{name}.md"
    if not src.is_file():
        raise SystemExit(f"build-page.py: source not found: {src}")
    meta, text = split_frontmatter(src.read_text())
    slots = []

    def stash(fragment):
        slots.append(fragment)
        return f"\n\nmdpage-slot-{len(slots) - 1}\n\n"

    if prepare:
        text = prepare(text, stash)
    md = markdown.Markdown(extensions=["tables", "fenced_code", "codehilite", "toc"],
                           extension_configs={"toc": {"toc_depth": "2-2"},
                                              "codehilite": {"css_class": "hl", "guess_lang": False}})
    body = SLOT.sub(lambda m: slots[int(m[1])], md.convert(text))
    # each h2 opens a new <section> so the nav rail can scroll to it
    body = re.sub(r'<h2 id="([^"]+)">', r'</section>\n<section id="\1">\n<h2>', body)
    body = body.replace("<table>", '<div class="tw"><table>').replace("</table>", "</table></div>")
    if transform:
        body = transform(body)
    nav = ['    <li><a href="#top">Overview</a></li>'] + [
        f'    <li><a href="#{t["id"]}">{html.escape(t["name"])}</a></li>' for t in md.toc_tokens]
    page = TEMPLATE.read_text()
    for key, value in {
        "__TITLE__": html.escape(meta.get("title", name)),
        "__EYEBROW__": html.escape(meta.get("eyebrow", "")),
        "__UPDATED__": html.escape(meta.get("updated", "")),
        "__SOURCE__": f"{name}.md",
        "__GENERATOR__": generator,
        "__RAIL_KEY__": rail_key,
        "__HEAD__": head,
        "__SCRIPT__": script,
        "__NAV__": "\n".join(nav),
        "__BODY__": body,
    }.items():
        page = page.replace(key, value)
    (dossier / f"{name}.html").write_text(page)
    return len(md.toc_tokens)
