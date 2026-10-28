#!/usr/bin/env python3
"""compare-page.py — turn a compare-page JSON spec into one self-contained HTML page.

Usage:
    compare-page.py --spec <dossier>/<slug>.json [--out page.html] [--no-open]

The page compares 2-5 options for one decision. Each option's component diagram is
drawn from its zones, nodes and edges: zones are columns, nodes sit in rows, and edges
are routed at right angles through the gaps between zones and between rows, so the
spec never holds a coordinate. Validates the spec, collecting every problem before
exiting 2, then fills templates/page.html. Output is deterministic.

Exit codes: 0 ok, 2 bad input (usage, unreadable spec, invalid JSON, invalid spec),
1 the template or page kit could not be found.
"""

import argparse
import html
import json
import os
import re
import sys
from pathlib import Path

ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
ID_RULE = ID_RE.pattern[1:-1]
MIN_OPTIONS, MAX_OPTIONS = 2, 5
MAX_ZONES = 4
ZONE_TONES = ("", "accent")
LETTERS = "ABCDE"

SKILL_DIR = Path(os.path.realpath(__file__)).parent.parent  # resolves the stow symlink to the repo copy
TEMPLATE = SKILL_DIR / "templates" / "page.html"
KIT_DIR = SKILL_DIR.parent / "decision-page" / "kit"  # the browser helpers the page skills share
PAGEKIT = KIT_DIR / "pagekit.py"

sys.dont_write_bytecode = True  # keep __pycache__ out of the stowed kit dir
sys.path.insert(0, str(KIT_DIR))
try:
    from pagekit import open_browser, unopenable_reason
except ImportError:
    sys.stderr.write('compare-page.py: missing %s; run: stow --no-folding -t "$HOME" claude\n' % PAGEKIT)
    sys.exit(1)

# Diagram geometry, in SVG user units. The viewBox is VW wide; its height follows the rows.
VW = 760
MARGIN = 10
ZONE_GAP = 20
NODE_INSET = 15
ROW_GAP = 56
LANE = 8
TITLE_CHAR_W = 7.6  # 13px semibold body font, a generous average
LINE_CHAR_W = 6.7  # 11px mono


def die(msg: str, code: int = 2):
    print("compare-page.py: " + msg, file=sys.stderr)
    sys.exit(code)


def warn(msg: str):
    print("compare-page.py: warning: " + msg, file=sys.stderr)


def esc(v) -> str:
    return html.escape(str(v), quote=True)


def strip_tags(s: str) -> str:
    return html.unescape(re.sub(r"<[^>]+>", "", s or "")).strip()


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def bad_id(v) -> bool:
    return not (isinstance(v, str) and ID_RE.match(v))


def blank(v) -> bool:
    return not (isinstance(v, str) and v.strip())


def html_list(v) -> bool:
    return isinstance(v, list) and len(v) > 0 and all(not blank(x) for x in v)


def validate_diagram(where: str, d) -> list:
    errs = []
    if not isinstance(d, dict):
        return ["%s: diagram must be an object" % where]
    zones = d.get("zones")
    if not isinstance(zones, list) or not 1 <= len(zones) <= MAX_ZONES:
        errs.append("%s: diagram needs 1-%d zones" % (where, MAX_ZONES))
        zones = []
    zone_ids = set()
    for z in zones:
        if not isinstance(z, dict) or bad_id(z.get("id")):
            errs.append("%s: zone id must match %s" % (where, ID_RULE))
            continue
        if z["id"] in zone_ids:
            errs.append('%s: duplicate zone "%s"' % (where, z["id"]))
        zone_ids.add(z["id"])
        if blank(z.get("label")):
            errs.append('%s: zone "%s" needs a label' % (where, z["id"]))
        if z.get("tone", "") not in ZONE_TONES:
            errs.append('%s: zone "%s" tone must be one of %s' % (where, z["id"], ", ".join(t or '""' for t in ZONE_TONES)))

    nodes = d.get("nodes")
    if not isinstance(nodes, list) or not nodes:
        errs.append("%s: diagram needs at least one node" % where)
        nodes = []
    node_ids, cells = set(), {}
    for n in nodes:
        if not isinstance(n, dict) or bad_id(n.get("id")):
            errs.append("%s: node id must match %s" % (where, ID_RULE))
            continue
        nid = n["id"]
        if nid in node_ids:
            errs.append('%s: duplicate node "%s"' % (where, nid))
        node_ids.add(nid)
        if n.get("zone") not in zone_ids:
            errs.append('%s: node "%s" names unknown zone "%s"' % (where, nid, n.get("zone")))
        row = n.get("row")
        if not isinstance(row, int) or isinstance(row, bool) or row < 0:
            errs.append('%s: node "%s" row must be an integer of at least 0' % (where, nid))
        elif n.get("zone") in zone_ids:
            cell = (n["zone"], row)
            if cell in cells:
                errs.append('%s: nodes "%s" and "%s" share zone "%s" row %d' % (where, cells[cell], nid, n["zone"], row))
            cells[cell] = nid
        if blank(n.get("title")):
            errs.append('%s: node "%s" needs a title' % (where, nid))
        lines = n.get("lines", [])
        if not isinstance(lines, list) or not all(isinstance(x, str) for x in lines):
            errs.append('%s: node "%s" lines must be a list of strings' % (where, nid))

    edges = d.get("edges", [])
    if not isinstance(edges, list):
        errs.append("%s: edges must be a list" % where)
        edges = []
    numbers = []
    for i, e in enumerate(edges):
        label = "edge %d" % (i + 1)
        if not isinstance(e, dict):
            errs.append("%s: %s must be an object" % (where, label))
            continue
        for end in ("from", "to"):
            if e.get(end) not in node_ids:
                errs.append('%s: %s "%s" names unknown node "%s"' % (where, label, end, e.get(end)))
        if e.get("from") == e.get("to"):
            errs.append("%s: %s goes from a node to itself" % (where, label))
        if "n" in e:
            n = e["n"]
            if not isinstance(n, int) or isinstance(n, bool) or n < 1:
                errs.append("%s: %s n must be an integer of at least 1" % (where, label))
            else:
                numbers.append(n)
    if len(set(numbers)) != len(numbers):
        errs.append("%s: edge numbers repeat" % where)
    elif sorted(numbers) != list(range(1, len(numbers) + 1)):
        errs.append("%s: edge numbers must run 1..%d with no gaps" % (where, len(numbers)))
    return errs


def numbered_edges(d) -> int:
    return sum(1 for e in d.get("edges", []) if isinstance(e, dict) and "n" in e)


def validate(spec) -> list:
    errs = []
    if not isinstance(spec, dict):
        return ["spec must be a JSON object"]
    if bad_id(spec.get("slug")):
        errs.append("slug must match %s" % ID_RULE)
    for f in ("title", "eyebrow", "lede", "sources"):
        if f in spec and not isinstance(spec[f], str):
            errs.append("%s must be a string" % f)
    problem = spec.get("problem")
    if problem is not None and not (isinstance(problem, dict) and set(problem) <= {"why", "hard"}
                                    and all(isinstance(v, str) for v in problem.values())):
        errs.append("problem must be an object with string fields why and hard")
    if "shared" in spec and not html_list(spec["shared"]):
        errs.append("shared must be a non-empty list of strings")

    options = spec.get("options")
    if not isinstance(options, list) or not MIN_OPTIONS <= len(options) <= MAX_OPTIONS:
        errs.append("options must be a list of %d-%d options" % (MIN_OPTIONS, MAX_OPTIONS))
        options = [o for o in options if isinstance(o, dict)] if isinstance(options, list) else []
    ids = []
    recs = 0
    for i, o in enumerate(options):
        if not isinstance(o, dict):
            errs.append("option %d must be an object" % (i + 1))
            continue
        oid = o.get("id")
        where = 'option "%s"' % oid if isinstance(oid, str) else "option %d" % (i + 1)
        if bad_id(oid):
            errs.append("%s: id must match %s" % (where, ID_RULE))
        ids.append(oid)
        if o.get("rec") is True:
            recs += 1
            if "wins_if" in o:
                errs.append("%s: wins_if is for the alternatives, not the recommended option" % where)
        for f in ("name", "summary"):
            if blank(o.get(f)):
                errs.append("%s: needs %s" % (where, f))
        for f in ("pros", "cons"):
            if not html_list(o.get(f)):
                errs.append("%s: %s must be a non-empty list of strings" % (where, f))
        if "diagram" not in o:
            errs.append("%s: needs a diagram" % where)
            continue
        derrs = validate_diagram(where, o["diagram"])
        errs.extend(derrs)
        if not derrs:
            k = numbered_edges(o["diagram"])
            steps = o.get("steps", [])
            if not isinstance(steps, list) or len(steps) != k or any(blank(s) for s in steps):
                errs.append("%s: steps must hold one non-blank entry per numbered edge (%d), found %s"
                            % (where, k, len(steps) if isinstance(steps, list) else "none"))
    if len(set(i for i in ids if isinstance(i, str))) != len([i for i in ids if isinstance(i, str)]):
        errs.append("option ids repeat")
    if options and recs != 1:
        errs.append("exactly one option needs rec: true, found %d" % recs)

    compare = spec.get("compare", [])
    if not isinstance(compare, list):
        errs.append("compare must be a list of rows")
        compare = []
    for i, row in enumerate(compare):
        if not isinstance(row, dict) or blank(row.get("label")):
            errs.append("compare row %d needs a label" % (i + 1))
            continue
        cells = row.get("cells")
        if not isinstance(cells, dict):
            errs.append('compare row "%s": cells must be an object keyed by option id' % strip_tags(row["label"]))
            continue
        missing = [oid for oid in ids if isinstance(oid, str) and oid not in cells]
        extra = [k for k in cells if k not in ids]
        if missing:
            errs.append('compare row "%s": no cell for %s' % (strip_tags(row["label"]), ", ".join(missing)))
        if extra:
            errs.append('compare row "%s": cells for unknown options %s' % (strip_tags(row["label"]), ", ".join(extra)))

    rec = spec.get("recommendation")
    if not isinstance(rec, dict) or blank(rec.get("summary")):
        errs.append("recommendation needs a summary")
    elif "changed" in rec and not isinstance(rec["changed"], str):
        errs.append("recommendation.changed must be a string")
    return errs


# ---------------------------------------------------------------------------
# Diagram layout
# ---------------------------------------------------------------------------

def node_height(n) -> int:
    return 36 + 16 * len(n.get("lines", []))


def fmt(v: float) -> str:
    return ("%.1f" % v).rstrip("0").rstrip(".")


def shorten(p1, p2, by=2.0):
    """Move p2 back towards p1 by `by`, so an arrowhead's tip stops at the box edge."""
    (x1, y1), (x2, y2) = p1, p2
    if x1 == x2:
        return (x2, y2 - by if y2 > y1 else y2 + by)
    return (x2 - by if x2 > x1 else x2 + by, y2)


def spread(lo: float, size: float, k: int, m: int) -> float:
    return lo + size * (k + 1) / (m + 1)


def lanes(k: int, m: int) -> float:
    return (k - (m - 1) / 2) * LANE


def layout(d, where: str):
    """Place zones and nodes, route every edge; return (geometry, edge paths)."""
    zones = d["zones"]
    nz = len(zones)
    zw = (VW - 2 * MARGIN - (nz - 1) * ZONE_GAP) / nz
    zi = {z["id"]: i for i, z in enumerate(zones)}
    zx = [MARGIN + i * (zw + ZONE_GAP) for i in range(nz)]
    nodes = {n["id"]: n for n in d["nodes"]}
    rank = {r: i for i, r in enumerate(sorted({n["row"] for n in d["nodes"]}))}
    edges = d.get("edges", [])

    route = []
    for e in edges:
        a, b = nodes[e["from"]], nodes[e["to"]]
        za, zb, ra, rb = zi[a["zone"]], zi[b["zone"]], rank[a["row"]], rank[b["row"]]
        if za == zb:
            blocked = any(zi[n["zone"]] == za and min(ra, rb) < rank[n["row"]] < max(ra, rb) for n in d["nodes"])
            if blocked:
                route.append(("lane", "right", "right"))
            else:
                route.append(("vertical", "bottom", "top") if ra < rb else ("vertical", "top", "bottom"))
        elif abs(za - zb) == 1:
            route.append(("adjacent", "right", "left") if zb > za else ("adjacent", "left", "right"))
        else:
            route.append(("skip", "right" if zb > za else "left", "top"))

    top_lanes = sum(1 for (kind, _, _), e in zip(route, edges) if kind == "skip" and rank[nodes[e["to"]]["row"]] == 0)
    y0 = 40 + max(0, top_lanes - 1) * 10
    heights = {}
    for n in d["nodes"]:
        heights[rank[n["row"]]] = max(heights.get(rank[n["row"]], 0), node_height(n))
    row_y, y = {}, y0
    for r in sorted(heights):
        row_y[r] = y
        y += heights[r] + ROW_GAP
    bottom = y - ROW_GAP + 34

    box = {}
    for nid, n in nodes.items():
        x = zx[zi[n["zone"]]] + NODE_INSET
        box[nid] = (x, row_y[rank[n["row"]]], zw - 2 * NODE_INSET, node_height(n))
        w = box[nid][2] - 24
        if len(n["title"]) * TITLE_CHAR_W > w:
            warn('%s: node "%s" title may overflow its box' % (where, nid))
        for line in n.get("lines", []):
            if len(line) * LINE_CHAR_W > w:
                warn('%s: node "%s" line "%s" may overflow its box' % (where, nid, line))

    def centre(nid):
        x, y, w, h = box[nid]
        return (x + w / 2, y + h / 2)

    # Ports: edges sharing a side of a node are spread along it, ordered by where the
    # other end sits, so they leave in the order they travel.
    ports = {}
    for i, (e, (kind, sa, sb)) in enumerate(zip(edges, route)):
        for nid, side, other in ((e["from"], sa, e["to"]), (e["to"], sb, e["from"])):
            ox, oy = centre(other)
            key = oy if side in ("left", "right") else ox
            ports.setdefault((nid, side), []).append((key, i, nid == e["from"]))
    port_at = {}
    for (nid, side), items in ports.items():
        x, y, w, h = box[nid]
        items.sort()
        for k, (_, i, is_from) in enumerate(items):
            if side in ("left", "right"):
                port_at[(i, is_from)] = (x if side == "left" else x + w, spread(y, h, k, len(items)))
            else:
                port_at[(i, is_from)] = (spread(x, w, k, len(items)), y if side == "top" else y + h)

    # An edge between neighbouring zones runs straight when one end is alone on its
    # side and the other end's height falls within that box.
    for i, (e, (kind, sa, sb)) in enumerate(zip(edges, route)):
        if kind != "adjacent":
            continue
        pa, pb = port_at[(i, True)], port_at[(i, False)]
        for nid, side, mine, other, is_from in ((e["to"], sb, pb, pa, False), (e["from"], sa, pa, pb, True)):
            _, y, _, h = box[nid]
            if len(ports[(nid, side)]) == 1 and y + 8 <= other[1] <= y + h - 8:
                port_at[(i, is_from)] = (mine[0], other[1])
                break

    gutter_users, gap_users = {}, {}
    for i, (e, (kind, sa, sb)) in enumerate(zip(edges, route)):
        za, zb = zi[nodes[e["from"]]["zone"]], zi[nodes[e["to"]]["zone"]]
        pa, pb = port_at[(i, True)], port_at[(i, False)]
        if kind == "adjacent" and abs(pa[1] - pb[1]) > 0.5:
            gutter_users.setdefault(min(za, zb), []).append((pa[1], i))
        elif kind == "skip":
            gutter_users.setdefault(za if zb > za else za - 1, []).append((pa[1], i))
            gap_users.setdefault(rank[nodes[e["to"]]["row"]], []).append((pb[0], i))
    gutter_x = {}
    for g, items in gutter_users.items():
        items.sort()
        centre_x = zx[g] + zw + ZONE_GAP / 2
        for k, (_, i) in enumerate(items):
            gutter_x[i] = centre_x + lanes(k, len(items))
    gap_y = {}
    for r, items in gap_users.items():
        items.sort()
        for k, (_, i) in enumerate(items):
            gap_y[i] = (y0 - 18 - k * 10) if r == 0 else (row_y[r] - ROW_GAP / 2 + lanes(k, len(items)))
    lane_k = {}

    paths = []
    for i, (e, (kind, sa, sb)) in enumerate(zip(edges, route)):
        pa, pb = port_at[(i, True)], port_at[(i, False)]
        if kind == "vertical":
            pts = [pa, (pa[0], pb[1])]
        elif kind == "adjacent":
            pts = [pa, (pb[0], pa[1])] if i not in gutter_x else [pa, (gutter_x[i], pa[1]), (gutter_x[i], pb[1]), pb]
        elif kind == "skip":
            gx, gy = gutter_x[i], gap_y[i]
            pts = [pa, (gx, pa[1]), (gx, gy), (pb[0], gy), pb]
        else:
            zone = nodes[e["from"]]["zone"]
            k = lane_k.get(zone, 0)
            lane_k[zone] = k + 1
            lx = pa[0] + 7 + k * 5
            pts = [pa, (lx, pa[1]), (lx, pb[1]), pb]
        pts[-1] = shorten(pts[-2], pts[-1])
        if e.get("both"):
            pts[0] = shorten(pts[1], pts[0])
        longest = max(range(len(pts) - 1), key=lambda j: abs(pts[j + 1][0] - pts[j][0]) + abs(pts[j + 1][1] - pts[j][1]))
        (x1, y1), (x2, y2) = pts[longest], pts[longest + 1]
        paths.append((e, pts, ((x1 + x2) / 2, (y1 + y2) / 2)))

    geometry = {"zw": zw, "zx": zx, "box": box, "bottom": bottom, "height": bottom + MARGIN}
    return geometry, paths


def render_diagram(d, did: str, alt: str, where: str) -> str:
    g, paths = layout(d, where)
    marker = "ah-" + did
    out = ['<div class="dg-wrap">',
           '<svg class="dg" viewBox="0 0 %d %s" role="img" aria-labelledby="%s-t">' % (VW, fmt(g["height"]), did),
           '<title id="%s-t">%s</title>' % (did, esc(alt)),
           '<defs><marker id="%s" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="8" markerHeight="8" '
           'orient="auto-start-reverse"><path class="head" d="M0,0 L8,4 L0,8 z"/></marker></defs>' % marker]
    for i, z in enumerate(d["zones"]):
        cls = "zone accent" if z.get("tone") == "accent" else "zone"
        out.append('<rect class="%s" x="%s" y="10" width="%s" height="%s" rx="8"/>'
                   % (cls, fmt(g["zx"][i]), fmt(g["zw"]), fmt(g["bottom"] - 10)))
        out.append('<text class="z" x="%s" y="%s">%s</text>' % (fmt(g["zx"][i] + 12), fmt(g["bottom"] - 10), esc(z["label"].upper())))
    for n in d["nodes"]:
        x, y, w, h = g["box"][n["id"]]
        cls = "box key" if n.get("key") else "box"
        out.append('<rect class="%s" x="%s" y="%s" width="%s" height="%s" rx="6"/>' % (cls, fmt(x), fmt(y), fmt(w), fmt(h)))
        out.append('<text class="t" x="%s" y="%s">%s</text>' % (fmt(x + 12), fmt(y + 22), esc(n["title"])))
        for k, line in enumerate(n.get("lines", [])):
            out.append('<text class="s" x="%s" y="%s">%s</text>' % (fmt(x + 12), fmt(y + 40 + 16 * k), esc(line)))
    badges = []
    for e, pts, (bx, by) in paths:
        dpath = "M" + " L".join("%s,%s" % (fmt(px), fmt(py)) for px, py in pts)
        cls = "edge dash" if e.get("dashed") else "edge"
        start = ' marker-start="url(#%s)"' % marker if e.get("both") else ""
        out.append('<path class="%s"%s marker-end="url(#%s)" d="%s"/>' % (cls, start, marker, dpath))
        if "n" in e:
            badges.append('<g class="num"><circle cx="%s" cy="%s" r="9"/><text x="%s" y="%s">%d</text></g>'
                          % (fmt(bx), fmt(by), fmt(bx), fmt(by + 4), e["n"]))
    out.extend(badges)
    out.append("</svg>")
    out.append("</div>")
    return "\n".join(out)


# ---------------------------------------------------------------------------
# Page
# ---------------------------------------------------------------------------

def short_name(o) -> str:
    return o.get("short") or strip_tags(o["name"])


def render_body(spec, spec_name: str) -> str:
    options = spec["options"]
    toc, body = [], []
    title = spec.get("title") or spec["slug"]

    body.append("<main>")
    if spec.get("eyebrow"):
        body.append('<p class="eyebrow">%s</p>' % esc(spec["eyebrow"]))
    body.append("<h1>%s</h1>" % esc(title))
    if spec.get("lede"):
        body.append('<p class="lede">%s</p>' % spec["lede"])
    if spec.get("sources"):
        body.append('<p class="meta">%s</p>' % spec["sources"])

    body.append('<div class="glance">')
    for i, o in enumerate(options):
        rec = o.get("rec") is True
        badge = '<span class="badge rec">Recommended</span>' if rec else '<span class="badge">Option %s</span>' % LETTERS[i]
        blurb = '<span class="s">%s</span>' % esc(o["tagline"]) if o.get("tagline") else ""
        body.append('<a href="#opt-%s"%s>%s<b>%s · %s</b>%s</a>'
                    % (o["id"], ' class="rec"' if rec else "", badge, LETTERS[i], esc(short_name(o)), blurb))
    body.append("</div>")

    problem = spec.get("problem") or {}
    if problem:
        toc.append(("problem", "The problem"))
        body.append('<h2 id="problem">The problem</h2>')
        if problem.get("why"):
            body.append("<p><b>Why it matters.</b> %s</p>" % problem["why"])
        if problem.get("hard"):
            body.append("<p><b>Why it's hard.</b> %s</p>" % problem["hard"])
    if spec.get("shared"):
        toc.append(("shared", "What every option shares"))
        body.append('<h2 id="shared">What every option shares</h2>')
        body.append("<ul>%s</ul>" % "".join("<li>%s</li>" % s for s in spec["shared"]))

    for i, o in enumerate(options):
        rec = o.get("rec") is True
        anchor = "opt-" + o["id"]
        toc.append((anchor, "%s · %s" % (LETTERS[i], short_name(o))))
        badge = '<span class="badge rec">Recommended</span>' if rec else '<span class="badge">Alternative</span>'
        body.append('<h2 id="%s">%s · %s %s</h2>' % (anchor, LETTERS[i], o["name"], badge))
        body.append("<p>%s</p>" % o["summary"])
        where = 'option "%s"' % o["id"]
        alt = o["diagram"].get("alt") or "%s: component diagram" % strip_tags(o["name"])
        body.append(render_diagram(o["diagram"], o["id"], alt, where))
        if o.get("steps"):
            body.append('<ol class="legend">%s</ol>' % "".join("<li>%s</li>" % s for s in o["steps"]))
        body.append('<div class="pc">')
        body.append('<div class="pro"><h4>Pros</h4><ul>%s</ul></div>' % "".join("<li>%s</li>" % s for s in o["pros"]))
        body.append('<div class="con"><h4>Cons</h4><ul>%s</ul></div>' % "".join("<li>%s</li>" % s for s in o["cons"]))
        body.append("</div>")
        if o.get("wins_if"):
            body.append('<div class="wins"><b>This wins if</b> %s</div>' % o["wins_if"])

    if spec.get("compare"):
        toc.append(("compare", "Side by side"))
        body.append('<h2 id="compare">Side by side</h2>')
        head = "".join('<th scope="col"%s>%s · %s</th>' % (' class="rec"' if o.get("rec") else "", LETTERS[i], esc(short_name(o)))
                       for i, o in enumerate(options))
        rows = []
        for row in spec["compare"]:
            cells = "".join('<td%s>%s</td>' % (' class="rec"' if o.get("rec") else "", row["cells"][o["id"]]) for o in options)
            rows.append('<tr><th scope="row">%s</th>%s</tr>' % (row["label"], cells))
        body.append('<div class="tbl"><table><thead><tr><th scope="col"></th>%s</tr></thead><tbody>%s</tbody></table></div>'
                    % (head, "".join(rows)))

    rec = spec["recommendation"]
    toc.append(("recommendation", "Recommendation"))
    body.append('<h2 id="recommendation">Recommendation</h2>')
    body.append('<div class="verdict">%s</div>' % rec["summary"])
    if rec.get("changed"):
        body.append("<h4 style=\"margin-top:20px\">What changed</h4><p>%s</p>" % rec["changed"])
    body.append("<footer>Generated by compare-page from <code>%s</code>. Edit the spec and regenerate; never edit this file.</footer>"
                % esc(spec_name))
    body.append("</main>")

    nav = ['<nav class="toc" aria-label="Sections"><p>On this page</p><ol>']
    nav.extend('<li><a href="#%s">%s</a></li>' % (a, esc(t)) for a, t in toc)
    nav.append("</ol></nav>")
    return "\n".join(nav + body)


def main():
    ap = argparse.ArgumentParser(description="Render a compare-page spec to HTML.")
    ap.add_argument("--spec", required=True)
    ap.add_argument("--out")
    ap.add_argument("--no-open", action="store_true")
    args = ap.parse_args()

    try:
        with open(args.spec) as f:
            spec = json.load(f)
    except OSError as e:
        die("cannot read %s: %s" % (args.spec, e.strerror))
    except json.JSONDecodeError as e:
        die("invalid JSON in %s: %s" % (args.spec, e))
    errs = validate(spec)
    if errs:
        for m in errs:
            print("compare-page.py: " + m, file=sys.stderr)
        sys.exit(2)
    if not TEMPLATE.exists():
        die('missing %s; run: stow --no-folding -t "$HOME" claude' % TEMPLATE, 1)

    out = args.out or os.path.splitext(args.spec)[0] + ".html"
    title = spec.get("title") or spec["slug"]
    page = (TEMPLATE.read_text()
            .replace("{{TITLE}}", esc(title))
            .replace("{{DESCRIPTION}}", esc(strip_tags(spec.get("lede", ""))[:300]))
            .replace("<!--BODY-->", render_body(spec, os.path.basename(args.spec))))
    with open(out, "w") as f:
        f.write(page)
    out = os.path.abspath(out)
    print("wrote: " + out)
    if args.no_open:
        print("not opened: --no-open")
        return
    reason = unopenable_reason(out)
    if reason:
        print("not opened: " + reason)
        return
    open_browser("file://" + out, "not opened: no browser opener found")
    print("opened: " + out)


if __name__ == "__main__":
    main()
