#!/usr/bin/env python3
"""Render a pragmatic-review Markdown file (<name>.md) to <name>.html.

    uv run -q --with markdown --with pygments python build-page.py <dossier-dir> <page-name>

The .md is the source: edit it, re-run this, never edit the HTML. The page shell, nav
rail and frontmatter (title, eyebrow, updated) come from review-guide's mdpage.py and
page template, so both skills' pages look alike. This file adds the review's own
conventions (SKILL.md step 7); anything else renders as plain Markdown:

  > **Input, not decisions…**        a blockquote opening so becomes the input banner
  ## Headlines                       its numbered list becomes ranked cards
  ## Revised order                   an ```order-diagram JSON block becomes the
                                     planned-against-revised diagram; numbered items
                                     saying "moved" or "pulled forward" are highlighted
  ## Verdicts                        the table (Step | Verdict | Trigger or reason |
                                     Flags | Settled | Source) becomes a verdict-count
                                     bar, filter buttons and one card per step
  ## Per-step options                `**Title.** (a) … · (b) … · Defer · Skip.`
                                     paragraphs become option cards, the first option
                                     marked recommended
  ## Steps as extracted              its code block collapses behind a toggle
  *Changes a settled decision:* …    marks a headline or option card
"""
import html
import itertools
import json
import pathlib
import re
import sys

import markdown

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "review-guide" / "scripts"))
import mdpage

VERDICTS = [("now", "Needed now"), ("move", "Move"), ("later", "Needed later"),
            ("notneeded", "Not needed"), ("other", "Other")]
VERDICT_WORDS = {"now": "needed now", "later": "needed later", "move": "move", "notneeded": "not needed"}
SETTLED = re.compile(r"\*Changes a settled decision:\*\s*(.*)$", re.S)
MOVED = re.compile(r"\b(moved|pulled forward)\b", re.I)
FENCE = re.compile(r"^(`{3,}|~{3,})")
BLANK = {"", "—", "-", "none", "no"}


def md_inline(text):
    out = markdown.markdown(text.strip())
    m = re.fullmatch(r"<p>(.*)</p>", out, re.S)
    return m[1] if m else out


def esc(text):
    return html.escape(text, quote=True)


def lead_and_rest(text):
    m = re.match(r"\*\*(.+?)\*\*\s*(.*)", text, re.S)
    return (m[1], m[2]) if m else ("", text)


def flatten(text):
    return " ".join(line.strip() for line in text.splitlines()).strip()


def sections(text):
    """Split Markdown into [(heading line or "", body)] on `## ` lines outside fences."""
    out, head, buf, fence = [], "", [], None
    for line in text.splitlines(keepends=True):
        m = FENCE.match(line)
        if m:
            fence = None if fence and m[1].startswith(fence) else (fence or m[1][:3])
        if not fence and line.startswith("## "):
            out.append((head, "".join(buf)))
            head, buf = line, []
        else:
            buf.append(line)
    out.append((head, "".join(buf)))
    return out


def split_list(body):
    """(text before the first numbered list, its items, text after it)."""
    lines = body.splitlines()
    start = next((i for i, l in enumerate(lines) if re.match(r"\d+\.\s", l)), None)
    if start is None:
        return body, [], ""
    items, end = [], len(lines)
    for i in range(start, len(lines)):
        line = lines[i]
        if re.match(r"\d+\.\s", line):
            items.append([line])
        elif line.strip() == "" or line.startswith((" ", "\t")):
            items[-1].append(line)
        else:
            end = i
            break
    parsed = [(re.match(r"(\d+)\.", it[0])[1], flatten(re.sub(r"^\d+\.\s+", "", "\n".join(it))))
              for it in items]
    return "\n".join(lines[:start]), parsed, "\n".join(lines[end:])


# --- sections -------------------------------------------------------------

def headlines(body, stash):
    before, items, after = split_list(body)
    cards = []
    for num, text in items:
        settled = SETTLED.search(text)
        lead, rest = lead_and_rest(text[: settled.start()].strip() if settled else text)
        chip = ' <span class="chip sev-medium">changes a settled decision</span>' if settled else ""
        note = f'<p class="settled-note">Settled decision it changes: {md_inline(settled[1])}</p>' if settled else ""
        title = f"<strong>{md_inline(lead)}</strong>" if lead else ""
        cards.append(f'<div class="spot {"sev-medium" if settled else "hl"}">\n<p class="spot-title">'
                     f'<span class="rank">{num}</span>{title}{chip}</p>\n'
                     f'<p>{md_inline(rest)}</p>{note}\n</div>\n')
    return before + (stash(f'<div class="spots">\n{"".join(cards)}</div>') if cards else "") + after


def diagram(spec):
    lanes = spec["lanes"]
    nodes = [n for lane in lanes for n in lane["nodes"]]
    width, x0, x1 = 1040, 130, 1030
    cols = max(n["col"] + n.get("span", 1) for n in nodes)
    cw = (x1 - x0) / cols
    tones = spec.get("tags", {})
    parts, boxes, top = [], {}, 36
    for li, lane in enumerate(lanes):
        rows = max((n.get("row", 0) for n in lane["nodes"]), default=0) + 1
        stacked = any("row" in n for n in lane["nodes"])
        # a tag sits above its box, so a tagged lower row needs room for it
        pitch = 74 if any(n.get("row", 0) and n.get("tag") for n in lane["nodes"]) else 58
        lane_h = pitch * rows - 8 if stacked else 58
        parts.append(f'<text class="t-lane" x="0" y="{top + lane_h / 2 + 4:.0f}">{esc(lane["name"])}</text>')
        for n in lane["nodes"]:
            x, w = x0 + n["col"] * cw + 6, n.get("span", 1) * cw - 12
            h, y = (50, top + n["row"] * pitch) if "row" in n else (58, top + (lane_h - 58) / 2)
            boxes[n["id"]] = (x, y, w, h, li, n)
        groups = {}
        for n in lane["nodes"]:
            groups.setdefault(n["col"], []).append(n["id"])
        order = sorted(groups)
        for a, b in itertools.pairwise(order):
            for sid in groups[a]:
                for tid in groups[b]:
                    sx, sy, sw, sh = boxes[sid][:4]
                    tx, ty, _, th = boxes[tid][:4]
                    parts.append(f'<path class="ln" d="M{sx + sw:.0f},{sy + sh / 2:.0f} C{sx + sw + 8:.0f},'
                                 f'{sy + sh / 2:.0f} {tx - 8:.0f},{ty + th / 2:.0f} {tx - 2:.0f},{ty + th / 2:.0f}" '
                                 f'marker-end="url(#ah)"/>')
        bottom = top + lane_h
        top = bottom + 102

    for x, y, w, h, _, n in boxes.values():
        kind = "k-use" if n.get("use") else "k-moved" if n.get("moved") else "k-node"
        parts.append(f'<rect class="{kind}" x="{x:.0f}" y="{y:.0f}" width="{w:.0f}" height="{h:.0f}" rx="5"/>')
        parts.append(f'<text class="t-b" x="{x + 10:.0f}" y="{y + 19:.0f}">{esc(n["label"])}</text>')
        for i, s in enumerate(n.get("sub", [])[: 1 if h < 58 else 2]):
            parts.append(f'<text class="t-s" x="{x + 10:.0f}" y="{y + 35 + i * 13:.0f}">{esc(s)}</text>')
        if n.get("tag"):
            tone = "-ok" if tones.get(n["tag"]) == "ok" else ""
            parts.append(f'<circle class="k-dot{tone}" cx="{x + 4:.0f}" cy="{y - 9:.0f}" r="3.5"/>')
            parts.append(f'<text class="t-tag{tone}" x="{x + 11:.0f}" y="{y - 5:.0f}">{esc(n["tag"])}</text>')

    for mv in spec.get("moves", []):
        missing = [k for k in (mv["from"], mv["to"]) if k not in boxes]
        if missing:
            raise SystemExit(f"build-page.py: order-diagram move names unknown node {missing[0]!r}")
        sx, sy, sw, sh, sl, _ = boxes[mv["from"]]
        tx, ty, tw, th, tl, tn = boxes[mv["to"]]
        down = tl >= sl
        p0 = (sx + sw / 2, sy + sh + 2) if down else (sx + sw / 2, sy - 2)
        if tn.get("row", 0) >= 1:
            p3 = (tx - 3, ty + th / 2)
            p1, p2 = (p0[0], p0[1] + (90 if down else -90)), (p3[0] - 40, p3[1])
        else:
            gap = 20 if tn.get("tag") else 4
            p3 = (tx + tw / 2, ty - gap) if down else (tx + tw / 2, ty + th + 4)
            bend = 50 if down else -50
            p1, p2 = (p0[0], p0[1] + bend), (p3[0], p3[1] - bend)
        parts.append(f'<path class="mv" d="M{p0[0]:.0f},{p0[1]:.0f} C{p1[0]:.0f},{p1[1]:.0f} '
                     f'{p2[0]:.0f},{p2[1]:.0f} {p3[0]:.0f},{p3[1]:.0f}" marker-end="url(#ahm)"/>')
        if mv.get("label"):
            mx = (p0[0] + 3 * p1[0] + 3 * p2[0] + p3[0]) / 8
            my = (p0[1] + 3 * p1[1] + 3 * p2[1] + p3[1]) / 8
            lw = len(mv["label"]) * 6.4 + 12
            parts.append(f'<rect class="k-lbl" x="{mx - lw / 2:.0f}" y="{my - 10:.0f}" width="{lw:.0f}" '
                         f'height="18" rx="9"/>')
            parts.append(f'<text class="t-mv" x="{mx:.0f}" y="{my + 3:.0f}" text-anchor="middle">'
                         f'{esc(mv["label"])}</text>')

    height = bottom + 26
    band = spec.get("band")
    if band:
        bx, by = x0 + band["from"] * cw + 6, bottom + 18
        bw = (band["to"] - band["from"] + 1) * cw - 12
        parts.append(f'<rect class="k-band" x="{bx:.0f}" y="{by:.0f}" width="{bw:.0f}" height="30" rx="5"/>')
        parts.append(f'<text class="t-band" x="{bx + 12:.0f}" y="{by + 19:.0f}">{esc(band["label"])}</text>')
        height = by + 40

    defs = ('<defs><marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
            'orient="auto-start-reverse"><path class="arrowhead" d="M0,0 L10,5 L0,10 z"/></marker>'
            '<marker id="ahm" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" '
            'orient="auto-start-reverse"><path class="arrowhead-mv" d="M0,0 L10,5 L0,10 z"/></marker></defs>')
    label = spec.get("caption", "The planned order above the revised one; dashed arrows are steps this review moves.")
    legend = []
    if any(n.get("moved") for n in nodes):
        legend.append('<span class="lg"><i class="sw sw-moved"></i>moved by this review</span>')
    if any(n.get("use") for n in nodes):
        legend.append('<span class="lg"><i class="sw sw-use"></i>first real use</span>')
    for tag in dict.fromkeys(n["tag"] for n in nodes if n.get("tag")):
        tone = " ok" if tones.get(tag) == "ok" else ""
        legend.append(f'<span class="lg"><i class="dotk{tone}"></i>{esc(tag)}</span>')
    legend.append('<span class="lg">Columns show order, not time to scale.</span>')
    return (f'<figure class="order"><svg viewBox="0 0 {width} {height:.0f}" role="img" aria-label="{esc(label)}">'
            f'{defs}{"".join(parts)}</svg><figcaption>{"".join(legend)}</figcaption></figure>')


def revised_order(body, stash):
    def render(m):
        try:
            spec = json.loads(m[1])
        except json.JSONDecodeError as e:
            raise SystemExit(f"build-page.py: order-diagram block is not valid JSON: {e}")
        return stash(diagram(spec))
    return re.sub(r"^```order-diagram\n(.*?)\n```$", render, body, flags=re.S | re.M)


def verdict_key(cell):
    plain = cell.replace("*", "").strip().lower()
    return next((k for k, word in VERDICT_WORDS.items() if plain.startswith(word)), "other")


def verdicts(body, stash):
    lines = body.splitlines()
    rows = [i for i, l in enumerate(lines) if l.lstrip().startswith("|")]
    if len(rows) < 3:
        return body
    def cells(line):
        return [c.strip() for c in line.strip().strip("|").split("|")]

    header = [h.lower() for h in cells(lines[rows[0]])]

    def col(row, name):
        # columns are found by header name, so a missing or reordered column still renders
        i = header.index(name) if name in header else len(row)
        return row[i] if i < len(row) else ""


    counts = {k: 0 for k, _ in VERDICTS}
    settled_count, cards = 0, []
    for i in rows[2:]:
        row = cells(lines[i])
        verdict, flags, settled_cell = col(row, "verdict"), col(row, "flags"), col(row, "settled")
        key = verdict_key(verdict)
        counts[key] += 1
        settled = settled_cell.lower() not in BLANK or "settled" in flags.lower()
        settled_count += settled
        m = re.match(r"([A-Z]+\d+[a-z]?)\b\s*(.*?)\s*(?:\[([^\]]+)\])?$", col(row, "step"))
        sid, title, status = (m[1], m[2], m[3] or "") if m else ("", col(row, "step"), "")
        split = any(w in verdict.replace("*", "").lower() for k, w in VERDICT_WORDS.items() if k != key)
        flag_chips = "".join(f'<span class="chip flag">{md_inline(f)}</span>' for f in flags.split(";")
                             if f.strip().lower() not in BLANK)
        note = (f'<p class="settled-note"><span class="chip sev-medium">changes a settled decision</span> '
                f'{md_inline(settled_cell)}</p>' if settled_cell.lower() not in BLANK else "")
        source = col(row, "source")
        cards.append(
            f'<article class="vcard v-{key}" data-v="{key}" data-settled="{int(settled)}">'
            f'<div class="vhead"><span class="fid">{esc(sid)}</span><span class="vtitle">{md_inline(title)}</span>'
            + (f'<span class="status">{esc(status)}</span>' if status else "")
            + f'<span class="vchip vc-{key}">{dict(VERDICTS)[key]}</span>'
            + ('<span class="chip v-plausible">split verdict</span>' if split else "")
            + f'</div><p class="vverdict">{md_inline(verdict)}</p>'
            f'<p class="vreason">{md_inline(col(row, "trigger or reason"))}</p>{note}'
            f'<div class="vfoot">{flag_chips}' + (f'<span class="src">{md_inline(source)}</span>' if source else "")
            + '</div></article>')

    total = sum(counts.values())
    segs, x = [], 0.0
    for key, _ in VERDICTS:
        if counts[key]:
            w = counts[key] / total * 1000
            segs.append(f'<rect class="seg seg-{key}" x="{x:.1f}" y="0" width="{w:.1f}" height="34"/>')
            if w > 36:
                segs.append(f'<text class="t-seg" x="{x + w / 2:.1f}" y="22" text-anchor="middle">{counts[key]}</text>')
            x += w
    legend = "".join(f'<span class="lg"><i class="sw seg-{k}"></i>{n} · {counts[k]}</span>'
                     for k, n in VERDICTS if counts[k])
    bar = (f'<figure class="bar"><svg viewBox="0 0 1000 34" preserveAspectRatio="none" role="img" '
           f'aria-label="Verdict counts across {total} steps">{"".join(segs)}</svg><figcaption>{legend}'
           f'<span class="lg">{settled_count} would change a settled decision</span></figcaption></figure>')
    filters = ([("all", f"All {total}")] + [(k, f"{n} {counts[k]}") for k, n in VERDICTS if counts[k]]
               + ([("settled", f"Changes a settled decision {settled_count}")] if settled_count else []))
    buttons = "".join(f'<button type="button" class="flt" data-f="{k}" aria-pressed="{str(k == "all").lower()}">'
                      f'{esc(label)}</button>' for k, label in filters)
    page = (f'{bar}<div class="filters" role="group" aria-label="Filter verdicts">{buttons}</div>'
            f'<div class="vlist">{"".join(cards)}</div>')
    return "\n".join(lines[:rows[0]]) + stash(page) + "\n".join(lines[rows[-1] + 1:])


def options(body, stash):
    paras = [p for p in re.split(r"\n\s*\n", body) if p.strip()]
    keep, cards = [], []
    for p in paras:
        text = flatten(p)
        if not text.startswith("**"):
            keep.append(p)
            continue
        settled = SETTLED.search(text)
        lead, rest = lead_and_rest(text[: settled.start()].strip() if settled else text)
        items = []
        for i, opt in enumerate(o.strip().rstrip(".") for o in rest.split(" · ") if o.strip()):
            m = re.match(r"\(([a-z])\)\s*(.*)", opt)
            letter, label = (m[1], m[2]) if m else ("", opt)
            dim = label.lower() in ("defer", "skip")
            rec = i == 0 and not dim
            items.append(f'<li class="{"rec" if rec else "dim" if dim else ""}">'
                         + (f"<b>{letter}</b> " if letter else "")
                         + ('<span class="chip v-confirmed">recommended</span> ' if rec else "")
                         + f"{md_inline(label)}</li>")
        note = (f'<p class="settled-note"><span class="chip sev-medium">changes a settled decision</span> '
                f'{md_inline(settled[1])}</p>' if settled else "")
        cards.append(f'<article class="opt{" settled" if settled else ""}"><h4>{md_inline(lead)}</h4>'
                     f'<ul>{"".join(items)}</ul>{note}</article>')
    if not cards:
        return body
    return "\n\n".join(keep) + stash(f'<div class="opts">{"".join(cards)}</div>')


def steps(body, stash):
    def render(m):
        n = len(m[1].splitlines())
        return stash(f'<details><summary>Show all {n} steps with their stated dependencies</summary>'
                     f'<pre>{esc(m[1])}</pre></details>')
    return re.sub(r"^```[^\n]*\n(.*?)\n```$", render, body, flags=re.S | re.M)


RENDERERS = {"headlines": headlines, "revised order": revised_order, "verdicts": verdicts,
             "per-step options": options}


def prepare(text, stash):
    out = []
    for head, body in sections(text):
        name = head[3:].strip().lower()
        render = RENDERERS.get(name) or (steps if name.startswith("steps") else None)
        out.append(head + (render(body, stash) if render else body))
    return "".join(out)


def transform(body):
    body = re.sub(r"<blockquote>\n<p><strong>Input, not decisions",
                  '<blockquote class="input">\n<p><span class="badge">Input only</span><strong>Input, not decisions',
                  body)
    start = body.find('<section id="revised-order">')
    if start < 0:
        return body
    end = body.find("</section>", start)
    end = len(body) if end < 0 else end

    seg = body[start:end]

    def mark(m):
        # only the item's own text, not a nested list's
        own = re.split(r"<li|<ul|<ol|</li>", seg[m.end():], maxsplit=1)[0]
        if MOVED.search(re.sub(r"<[^>]+>", "", own)):
            return '<li class="moved"><span class="chip sev-medium">moved</span> '
        return m[0]
    seg = re.sub(r"<li>", mark, seg).replace("<ol>", '<ol class="path">')
    return body[:start] + seg + body[end:]


HEAD = """
<style>
.spot.hl{border-left-color:var(--accent)} .spot.hl .rank{color:var(--accent)}
.spots{margin:8px 0 18px}
.settled-note{font-size:13.5px;color:var(--muted)}
blockquote.input{border-left:6px solid var(--amber);background:var(--amber-soft)}
blockquote.input .badge{background:var(--amber);font-size:13px;margin-right:10px}
figure.order figcaption,figure.bar figcaption{display:flex;flex-wrap:wrap;gap:6px 18px}
figure.order svg{min-width:720px}
.lg{display:inline-flex;align-items:center;gap:6px}
.sw{display:inline-block;width:14px;height:10px;border-radius:2px}
.dotk{display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--muted)}
.dotk.ok{background:var(--ok)}
.sw-moved{background:var(--amber-soft);box-shadow:inset 0 0 0 1.5px var(--amber)}
.sw-use{background:var(--accent-soft);box-shadow:inset 0 0 0 1.5px var(--accent)}
svg .t-lane{font:600 12px var(--cond);letter-spacing:.06em;text-transform:uppercase;fill:var(--muted)}
svg .t-tag{fill:var(--muted);font:600 10.5px var(--cond);letter-spacing:.05em;text-transform:uppercase}
svg .t-tag-ok{fill:var(--ok);font:600 10.5px var(--cond);letter-spacing:.05em;text-transform:uppercase}
svg .t-mv{fill:var(--amber);font:600 11px var(--cond)}
svg .t-band{fill:var(--ink);font-size:12px}
svg .t-seg{fill:var(--surface);font:600 13px var(--cond)}
svg .mv{stroke:var(--amber);stroke-width:1.6;stroke-dasharray:5 4;fill:none}
svg .arrowhead-mv{fill:var(--amber)}
svg .k-node{fill:var(--surface);stroke:var(--muted);stroke-width:1}
svg .k-moved{fill:var(--amber-soft);stroke:var(--amber);stroke-width:1.6}
svg .k-use{fill:var(--accent-soft);stroke:var(--accent);stroke-width:1.6}
svg .k-lbl{fill:var(--surface);stroke:var(--amber);stroke-width:1}
svg .k-band{fill:var(--new-soft);stroke:var(--new);stroke-width:1}
svg .k-dot{fill:var(--muted)} svg .k-dot-ok{fill:var(--ok)}
ol.path{list-style:none;padding:0;margin:8px 0 14px;display:grid;gap:6px;max-width:none;counter-reset:path}
ol.path>li{counter-increment:path;display:block;position:relative;padding:9px 12px 9px 44px;border-radius:6px;background:var(--surface);border:1px solid var(--rule);font-size:14px;margin:0}
ol.path>li::before{content:counter(path);position:absolute;left:14px;top:9px;font:600 16px/1.4 var(--cond);color:var(--muted)}
ol.path>li.moved{border-color:var(--amber);background:linear-gradient(90deg,var(--amber-soft),var(--surface) 60%)}
figure.bar{padding:12px 14px 8px}
figure.bar svg{min-width:0;height:34px;border-radius:4px}
.seg-now{fill:var(--accent);background:var(--accent)} .seg-move{fill:var(--amber);background:var(--amber)}
.seg-later{fill:var(--new);background:var(--new)} .seg-notneeded{fill:var(--bad);background:var(--bad)}
.seg-other{fill:var(--muted);background:var(--muted)}
.filters{display:flex;flex-wrap:wrap;gap:6px;margin:4px 0 14px}
.flt[aria-pressed="true"]{background:var(--ink);color:var(--ground);border-color:var(--ink)}
.vlist{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(100%,420px),1fr));gap:10px}
.vcard{background:var(--surface);border:1px solid var(--rule);border-left:5px solid var(--muted);border-radius:6px;padding:10px 14px;min-width:0;display:flex;flex-direction:column;gap:6px}
.vcard.v-now{border-left-color:var(--accent)} .vcard.v-move{border-left-color:var(--amber)}
.vcard.v-later{border-left-color:var(--new)} .vcard.v-notneeded{border-left-color:var(--bad)}
.vcard[data-settled="1"]{box-shadow:inset 0 0 0 1px var(--amber)}
.vcard p{margin:0}
.vhead{display:flex;flex-wrap:wrap;align-items:baseline;gap:6px 8px}
.vtitle{font-weight:600;flex:1 1 200px;min-width:0}
.status{font:500 11.5px var(--mono);color:var(--muted)}
.vchip{font:600 10.5px/1 var(--cond);letter-spacing:.06em;text-transform:uppercase;padding:4px 7px;border-radius:3px;color:var(--surface)}
.vc-now{background:var(--accent)} .vc-move{background:var(--amber)} .vc-later{background:var(--new)}
.vc-notneeded{background:var(--bad)} .vc-other{background:var(--muted)}
.vverdict,.vreason{font-size:13.5px} .vreason{color:var(--muted)}
.vfoot{display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin-top:auto}
.chip.flag{background:var(--sunk);color:var(--muted);text-transform:none;letter-spacing:0;font:500 12px/1.2 var(--sans);white-space:normal}
.src{font-size:11.5px;color:var(--muted);margin-left:auto;overflow-wrap:anywhere}
.src code{background:none;padding:0}
.opts{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(100%,380px),1fr));gap:10px}
.opt{background:var(--surface);border:1px solid var(--rule);border-radius:6px;padding:12px 14px;min-width:0}
.opt.settled{border-color:var(--amber)}
.opt h4{font:600 15px/1.3 var(--cond);margin:0 0 8px}
.opt ul{list-style:none;padding:0;margin:0;display:grid;gap:4px}
.opt li{font-size:13.5px;margin:0;padding:4px 8px;border-radius:4px}
.opt li.rec{background:var(--accent-soft)}
.opt li.dim{color:var(--muted);font-size:12.5px;padding-block:1px}
.opt li b{font:600 12px var(--mono);color:var(--muted);margin-right:2px}
details{background:var(--surface);border:1px solid var(--rule);border-radius:6px;padding:10px 14px}
summary{cursor:pointer;font-weight:500}
details pre{margin:10px 0 0}
</style>"""

SCRIPT = """
<script>
(function(){
  var flts=[].slice.call(document.querySelectorAll(".flt")), cards=[].slice.call(document.querySelectorAll(".vcard"));
  flts.forEach(function(b){b.addEventListener("click",function(){
    var f=b.dataset.f;
    flts.forEach(function(x){x.setAttribute("aria-pressed",String(x===b))});
    cards.forEach(function(c){c.hidden=!(f==="all"||c.dataset.v===f||(f==="settled"&&c.dataset.settled==="1"))});
  })});
})();
</script>"""


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: build-page.py <dossier-dir> <page-name>   (renders <page-name>.md)")
    name = sys.argv[2].removesuffix(".md")
    count = mdpage.build(pathlib.Path(sys.argv[1]), name,
                         generator="the pragmatic-review skill's <code>build-page.py</code>",
                         rail_key="pragmatic-review:rail", prepare=prepare, transform=transform,
                         head=HEAD, script=SCRIPT)
    print(f"{name}.html: {count} sections")


if __name__ == "__main__":
    main()
