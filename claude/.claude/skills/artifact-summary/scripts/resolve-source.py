#!/usr/bin/env python3
"""resolve-source.py — pick the cheapest accurate thing to read for a page.

Usage: resolve-source.py <claude.ai link | local .html/.md path>

Prints one JSON object:
  {"via": "local" | "dossier" | "artifact",
   "read": <path to read, or the link for the Artifact tool>,
   "html": <rendered .html path, when there is one>,
   "entry": <the INDEX.toml entry's title/job/role, when one matched>,
   "note": <why this source was picked>}

A dossier page's Markdown source (<stem>.md beside <stem>.html) is preferred,
unless its INDEX.toml entry names a `source` other than md2html: those pages are
built by a generator that pulls in data the .md does not hold (the ladder's
status cells come from task files), so the rendered HTML is the complete one.
"""
import json
import re
import sys
import tomllib
from pathlib import Path

DOSSIERS = Path.home() / "code" / "tasks" / "dossiers"
LINK = re.compile(r"claude\.ai/(?:code/)?artifact/([A-Za-z0-9_-]+)")


def index_entries():
    for index in sorted(DOSSIERS.glob("*/INDEX.toml")):
        try:
            data = tomllib.loads(index.read_text())
        except (OSError, tomllib.TOMLDecodeError):
            continue
        for entry in data.get("doc", []):
            yield entry


def entry_summary(entry):
    return {k: entry[k] for k in ("title", "job", "role", "area") if k in entry}


def generated_elsewhere(entry):
    # plain `tools/md2html.py` renders the .md as-is; `ladder_md2html.py` and the
    # like add data from elsewhere
    source = entry.get("source", "")
    return bool(source) and not re.search(r"(?<![\w])md2html\.py", source)


def best_local(html, entry):
    md = html.with_suffix(".md")
    if html.suffix == ".md":
        return html, "the Markdown source itself"
    if entry and generated_elsewhere(entry):
        return html, f"built by {entry['source']}; the .md lacks the generated parts"
    if md.exists():
        return md, "the Markdown source beside the HTML"
    return html, "no Markdown source beside it; read the HTML"


def entry_for_file(path):
    try:
        rel = str(path.resolve().relative_to(DOSSIERS.resolve()))
    except ValueError:
        return None
    rel_html = str(Path(rel).with_suffix(".html"))
    for entry in index_entries():
        if entry.get("file") in (rel, rel_html):
            return entry
    return None


def main(arg):
    match = LINK.search(arg)
    if match:
        artifact_id = match.group(1)
        for entry in index_entries():
            url = entry.get("url", "")
            if url.rstrip("/").endswith("/" + artifact_id) and entry.get("file"):
                html = DOSSIERS / entry["file"]
                if html.exists():
                    read, note = best_local(html, entry)
                    return {"via": "dossier", "read": str(read), "html": str(html),
                            "entry": entry_summary(entry), "note": note}
        return {"via": "artifact", "read": arg,
                "note": "not listed in any dossier INDEX.toml; use the Artifact tool's read"}

    path = Path(arg).expanduser()
    if not path.exists():
        return {"via": "none", "read": arg, "note": "neither a claude.ai link nor an existing path"}
    entry = entry_for_file(path)
    read, note = best_local(path, entry)
    out = {"via": "local", "read": str(read), "note": note}
    if path.suffix == ".html":
        out["html"] = str(path)
    if entry:
        out["entry"] = entry_summary(entry)
        if entry.get("url"):
            out["entry"]["url"] = entry["url"]
    return out


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        sys.exit(2)
    print(json.dumps(main(sys.argv[1]), indent=2))
