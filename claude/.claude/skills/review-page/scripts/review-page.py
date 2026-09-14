#!/usr/bin/env python3
"""review-page.py — the "review-page" shape's mechanism: a self-contained,
locally-served HTML review table for a batch of items too large for a
markdown buffer (>~25 rows, or needing defaults + grouping + questions).

Mirrors the decision-buffer skill's scripts/open-buffer.sh contract (see
claude/.claude/skills/decision-buffer/references/mechanism.md) rather than
reinventing one: same state-file fields (chan, pane_id,
mode, opened_at, caller_pid, content_hash, reopen_count, closed), same
tmux wait-for signal on close, same "run this backgrounded" expectation
for the calling agent. mode is always "review-page" here; pane_id is
always empty (this isn't a tmux pane — it's a browser tab talking to a
local HTTP server).

Usage:
  review-page.py --spec <spec.json> --out <answers.json> [--title TITLE] [--port auto|N]

Behaviour:
  1. Load and validate the spec.
  2. Pick a free port (or use --port N).
  3. Render the page (inline CSS+JS, no CDNs) from the spec.
  4. Write <out>.buffer-state (mode=review-page, closed=0).
  5. Serve on 127.0.0.1:<port>; open it in a browser (snap chromium, else
     xdg-open) over http:// (never file:// — snap chromium can't open
     file:// under hidden dirs).
  6. Block until the page POSTs /submit.
  7. Write <out> (answers.json), rewrite state closed=1, signal
     `tmux wait-for -S <chan>` if tmux is present, exit 0.

Run backgrounded by the caller, exactly like open-buffer.sh --tmux.
"""

import argparse
import hashlib
import http.server
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
import webbrowser
from urllib.parse import urlparse

STATE_FIELDS = [
    "chan", "pane_id", "mode", "opened_at", "caller_pid",
    "content_hash", "reopen_count", "closed",
]


def state_path_for(out_path: str) -> str:
    return out_path + ".buffer-state"


def gen_chan() -> str:
    return "decision-buffer-done-%d-%d" % (os.getpid(), int(time.time() * 1000) % 100000)


def hash_spec(spec_bytes: bytes) -> str:
    return hashlib.sha256(spec_bytes).hexdigest()


def read_state(sf: str):
    if not os.path.isfile(sf):
        return None
    fields = {}
    with open(sf) as f:
        for line in f:
            if "=" in line:
                k, _, v = line.rstrip("\n").partition("=")
                fields[k] = v
    return fields


def write_state(sf: str, chan, pane_id, mode, caller_pid, content_hash, reopen_count, closed):
    with open(sf, "w") as f:
        f.write("chan=%s\n" % chan)
        f.write("pane_id=%s\n" % pane_id)
        f.write("mode=%s\n" % mode)
        f.write("opened_at=%s\n" % int(time.time()))
        f.write("caller_pid=%s\n" % caller_pid)
        f.write("content_hash=%s\n" % content_hash)
        f.write("reopen_count=%s\n" % reopen_count)
        f.write("closed=%s\n" % closed)


def pid_alive(pid) -> bool:
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def prepare_open(out_path: str, spec_hash: str):
    """Mirrors open-buffer.sh's prepare_open: refuse if a live waiter still
    holds the state file for this path; otherwise compute reopen_count
    carry-forward from the previous state file (if any)."""
    sf = state_path_for(out_path)
    prev = read_state(sf)
    reopen = 0
    if prev:
        if pid_alive(prev.get("caller_pid")):
            sys.stderr.write(
                "review-page.py: already waiting on %s (pid %s, chan %s) — "
                "not starting a second wait\n" % (out_path, prev.get("caller_pid"), prev.get("chan"))
            )
            sys.exit(1)
        if prev.get("content_hash") == spec_hash and spec_hash != "nohash":
            try:
                reopen = int(prev.get("reopen_count", "0")) + 1
            except ValueError:
                reopen = 0
    return reopen


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def open_browser(url: str):
    chromium = "/snap/bin/chromium"
    if os.path.exists(chromium):
        subprocess.Popen(
            [chromium, url],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        return
    if shutil.which("xdg-open"):
        subprocess.Popen(
            ["xdg-open", url],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        return
    try:
        webbrowser.open(url)
    except Exception:
        print("review-page.py: no browser opener found — open manually: %s" % url)


# ---------------------------------------------------------------------------
# HTML rendering
# ---------------------------------------------------------------------------

def esc(s) -> str:
    if s is None:
        return ""
    return (
        str(s)
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def md_lite(s: str) -> str:
    """Very small markdown-ish -> HTML: **bold**, `code`, newlines to <br>."""
    if not s:
        return ""
    out = esc(s)
    import re
    out = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", out)
    out = re.sub(r"`(.+?)`", r"<code>\1</code>", out)
    out = out.replace("\n", "<br>")
    return out


def render_page(spec: dict, title: str, spec_hash: str) -> str:
    verdicts = spec.get("verdicts") or []
    areas = spec.get("areas") or []
    intro_md = spec.get("intro_md", "")
    close_rule = spec.get("close_rule", "")

    all_items = []
    for area in areas:
        for item in area.get("items", []):
            all_items.append((area, item))

    verdict_json = json.dumps(verdicts)
    areas_json = json.dumps(areas)
    spec_hash_json = json.dumps(spec_hash)
    close_rule_html = md_lite(close_rule)

    def verdict_radios(item_id, suggested):
        parts = []
        for i, v in enumerate(verdicts, start=1):
            vid = esc(v["id"])
            label = esc(v.get("label", v["id"]))
            color = esc(v.get("color", ""))
            checked = " checked" if v["id"] == suggested else ""
            sug_cls = " suggested" if v["id"] == suggested else ""
            parts.append(
                '<label class="verdict-opt%s" style="--vc:%s" data-key="%d">'
                '<input type="radio" name="verdict-%s" value="%s"%s> %s'
                '%s</label>' % (
                    sug_cls, color or "var(--overlay)", i, esc(item_id), vid, checked, label,
                    ' <span class="sug-badge">suggested</span>' if v["id"] == suggested else "",
                )
            )
        return "".join(parts)

    def dep_chips(ids, label_prefix=""):
        if not ids:
            return ""
        chips = []
        for did in ids:
            chips.append('<span class="chip dep-chip" data-target="row-%s">%s%s</span>' % (
                esc(did), label_prefix, esc(did)
            ))
        return "".join(chips)

    def evidence_html(evidence):
        if not evidence:
            return ""
        if isinstance(evidence, list):
            items = "".join("<li>%s</li>" % md_lite(e) for e in evidence)
            return "<ul class='evidence-list'>%s</ul>" % items
        return "<div class='evidence-text'>%s</div>" % md_lite(evidence)

    def links_html(links):
        if not links:
            return ""
        return " ".join(
            '<a href="%s" target="_blank" rel="noopener">%s</a>' % (esc(l.get("href", "#")), esc(l.get("label", l.get("href", "link"))))
            for l in links
        )

    area_tables = []
    row_counter = 0
    for area in areas:
        aid = esc(area.get("id", ""))
        atitle = esc(area.get("title", aid))
        anote = md_lite(area.get("note", ""))
        rows_html = []
        for item in area.get("items", []):
            row_counter += 1
            iid = esc(item.get("id", "item-%d" % row_counter))
            suggested = item.get("suggested", "")
            reason = esc(item.get("suggested_reason", ""))
            what = md_lite(item.get("what", ""))
            where = esc(item.get("where", ""))
            evidence = evidence_html(item.get("evidence"))
            deps = dep_chips(item.get("depends_on"), "&larr; ")
            depby = dep_chips(item.get("depended_on_by"), "&rarr; ")
            links = links_html(item.get("links"))
            needs_me = "1" if (not suggested or "unclear" in reason.lower()) else "0"

            rows_html.append(f'''
<tr id="row-{iid}" class="item-row" data-item-id="{iid}" data-area="{aid}"
    data-suggested="{esc(suggested)}" data-needs-me="{needs_me}">
  <td class="col-n">{row_counter}</td>
  <td class="col-item">
    <div class="item-title">{esc(item.get("title", iid))}</div>
    <div class="item-where">{where}</div>
    <div class="item-links">{links}</div>
  </td>
  <td class="col-what">{what}</td>
  <td class="col-evidence">
    <button type="button" class="ev-toggle" data-action="toggle-evidence">evidence</button>
    <div class="ev-body" hidden>{evidence}</div>
  </td>
  <td class="col-deps">
    {('<div class="deps-in">' + deps + '</div>') if deps else ''}
    {('<div class="deps-out">' + depby + '</div>') if depby else ''}
  </td>
  <td class="col-verdict">
    <div class="verdict-group" data-item-id="{iid}">{verdict_radios(iid, suggested)}</div>
    <button type="button" class="agree-btn" data-item-id="{iid}" title="agree with suggested verdict (a)">Agree &#10003;</button>
    {f'<div class="sug-reason">{md_lite(reason)}</div>' if reason else ''}
  </td>
  <td class="col-group">
    <input type="text" class="group-input" list="group-options" data-item-id="{iid}" placeholder="group">
    <button type="button" class="same-as-above" title="same as row above">same as &uarr;</button>
  </td>
  <td class="col-note">
    <textarea class="note-input" data-item-id="{iid}" rows="1" placeholder="ask / note"></textarea>
  </td>
</tr>''')
        area_tables.append(f'''
<section class="area-block" data-area="{aid}">
  <h2 class="area-title">{atitle} <span class="area-count" data-area-count="{aid}"></span></h2>
  {f'<div class="area-note">{anote}</div>' if anote else ''}
  <div class="table-wrap">
    <table class="review-table">
      <thead>
        <tr>
          <th class="col-n">#</th>
          <th class="col-item">item</th>
          <th class="col-what">what</th>
          <th class="col-evidence">evidence</th>
          <th class="col-deps">deps</th>
          <th class="col-verdict">verdict</th>
          <th class="col-group">group</th>
          <th class="col-note">ask / note</th>
        </tr>
      </thead>
      <tbody>
        {"".join(rows_html)}
      </tbody>
    </table>
  </div>
</section>''')

    verdict_filter_opts = "".join(
        '<option value="%s">%s</option>' % (esc(v["id"]), esc(v.get("label", v["id"])))
        for v in verdicts
    )
    area_filter_opts = "".join(
        '<option value="%s">%s</option>' % (esc(a.get("id", "")), esc(a.get("title", a.get("id", ""))))
        for a in areas
    )

    intro_html = md_lite(intro_md)
    if close_rule_html:
        intro_html += '<hr style="border-color:var(--overlay); margin:8px 0;">' + close_rule_html

    # Contract (2026-09-14): no action on a row = accept its suggestion.
    # accept-remaining-defaults is pre-ticked by default; a spec can turn it
    # off with "accept_defaults_default": false.
    accept_defaults_checked = " checked" if spec.get("accept_defaults_default", True) else ""

    return PAGE_TEMPLATE.format(
        title=esc(title),
        intro_html=intro_html,
        area_tables="".join(area_tables),
        verdict_filter_opts=verdict_filter_opts,
        area_filter_opts=area_filter_opts,
        verdict_json=verdict_json,
        areas_json=areas_json,
        spec_hash_json=spec_hash_json,
        total_items=len(all_items),
        accept_defaults_checked=accept_defaults_checked,
    )


PAGE_TEMPLATE = """<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>{title}</title>
<style>
:root {{
  --base: #1e1e2e; --surface: #313244; --overlay: #45475a;
  --text: #cdd6f4; --subtext: #a6adc8;
  --mauve: #cba6f7; --green: #a6e3a1; --yellow: #f9e2af;
  --red: #f38ba8; --blue: #89b4fa; --peach: #fab387;
}}
* {{ box-sizing: border-box; }}
html, body {{
  background: var(--base); color: var(--text); margin: 0; padding: 0;
  font-family: -apple-system, "Segoe UI", Inter, system-ui, sans-serif;
  font-size: 17px; line-height: 1.5; color-scheme: dark;
}}
a {{ color: var(--blue); }}
code {{ background: var(--overlay); padding: 0 4px; border-radius: 4px; font-family: monospace; }}
header {{ padding: 20px 32px 12px; border-bottom: 1px solid var(--overlay); }}
h1 {{ margin: 0 0 8px; font-size: 22px; }}
.intro-box {{
  background: var(--surface); border: 1px solid var(--overlay);
  border-radius: 10px; padding: 12px 16px; margin: 10px 0; max-width: 900px;
}}
.counts-strip {{ display: flex; flex-wrap: wrap; gap: 10px; margin-top: 10px; font-size: 14px; color: var(--subtext); }}
.counts-strip .pill {{ background: var(--surface); border: 1px solid var(--overlay); border-radius: 8px; padding: 4px 10px; }}
.filter-bar {{
  position: sticky; top: 0; z-index: 20; background: var(--base);
  border-bottom: 1px solid var(--overlay); padding: 10px 32px;
  display: flex; flex-wrap: wrap; gap: 12px; align-items: center;
}}
.filter-bar input[type=text], .filter-bar select {{
  background: var(--surface); color: var(--text); border: 1px solid var(--overlay);
  border-radius: 8px; padding: 6px 10px; font-size: 14px;
}}
.filter-bar label {{ font-size: 14px; color: var(--subtext); display: flex; align-items: center; gap: 6px; }}
main {{ padding: 10px 32px 140px; width: 100%; }}
.area-block {{ margin: 28px 0; }}
.area-title {{ font-size: 18px; margin-bottom: 4px; }}
.area-count {{ font-size: 13px; color: var(--subtext); font-weight: normal; }}
.area-note {{ color: var(--subtext); font-size: 14px; margin-bottom: 10px; }}
.table-wrap {{ width: 100%; overflow-x: hidden; }}
table.review-table {{
  width: 100%; table-layout: fixed; border-collapse: collapse;
  background: var(--surface); border-radius: 10px; overflow: hidden;
}}
table.review-table col {{ }}
.review-table th, .review-table td {{
  border-bottom: 1px solid var(--overlay); padding: 10px 10px; vertical-align: top;
  word-wrap: break-word; overflow-wrap: break-word;
}}
.review-table th {{ text-align: left; font-size: 13px; color: var(--subtext); font-weight: 600; }}
.col-n {{ width: 3%; }}
.col-item {{ width: 16%; }}
.col-what {{ width: 20%; }}
.col-evidence {{ width: 15%; }}
.col-deps {{ width: 10%; }}
.col-verdict {{ width: 16%; }}
.col-group {{ width: 10%; }}
.col-note {{ width: 10%; }}
.item-title {{ font-weight: 600; }}
.item-where {{ font-family: monospace; font-size: 12px; color: var(--subtext); margin-top: 2px; }}
.item-links {{ margin-top: 4px; font-size: 13px; }}
.ev-toggle {{
  background: var(--overlay); color: var(--text); border: none; border-radius: 6px;
  padding: 3px 8px; font-size: 12px; cursor: pointer;
}}
.ev-body {{ margin-top: 6px; font-size: 13px; color: var(--subtext); }}
.evidence-list {{ margin: 4px 0 0 16px; padding: 0; }}
.chip {{
  display: inline-block; background: var(--overlay); border-radius: 6px;
  padding: 2px 6px; font-size: 12px; margin: 2px 4px 2px 0; cursor: pointer;
  font-family: monospace;
}}
.chip:hover {{ background: var(--mauve); color: var(--base); }}
.verdict-group {{ display: flex; flex-direction: column; gap: 4px; }}
.verdict-opt {{
  display: flex; align-items: center; gap: 6px; font-size: 13px;
  border-left: 3px solid var(--vc); padding-left: 6px;
}}
.verdict-opt.suggested {{ font-weight: 600; }}
.sug-badge {{
  font-size: 10px; background: var(--mauve); color: var(--base);
  border-radius: 4px; padding: 1px 5px; margin-left: 4px;
}}
.sug-reason {{ font-size: 12px; color: var(--subtext); margin-top: 4px; }}
.group-input, .note-input {{
  width: 100%; background: var(--base); color: var(--text);
  border: 1px solid var(--overlay); border-radius: 6px; padding: 5px 7px; font-size: 13px;
}}
.note-input {{ resize: vertical; min-height: 32px; }}
.same-as-above {{
  margin-top: 4px; background: var(--overlay); color: var(--text); border: none;
  border-radius: 6px; padding: 2px 6px; font-size: 11px; cursor: pointer;
}}
.item-row.touched {{ }}
.item-row.diverged {{ box-shadow: inset 4px 0 0 var(--yellow); }}
.item-row.agreed {{ box-shadow: inset 4px 0 0 var(--green); }}
.agree-btn {{
  margin-top: 6px; background: var(--overlay); color: var(--text); border: 1px solid var(--green);
  border-radius: 6px; padding: 3px 8px; font-size: 12px; cursor: pointer;
}}
.agree-btn.active {{ background: var(--green); color: var(--base); font-weight: 600; }}
.item-row.has-note td.col-item .item-title::after {{
  content: " ?"; color: var(--yellow); font-weight: bold;
}}
.item-row.hidden-by-filter {{ display: none; }}
.item-row.focused-kb {{ outline: 2px solid var(--mauve); outline-offset: -2px; }}
footer.submit-bar {{
  position: fixed; bottom: 0; left: 0; right: 0; background: var(--surface);
  border-top: 1px solid var(--overlay); padding: 12px 32px;
  display: flex; flex-wrap: wrap; align-items: center; gap: 14px; z-index: 30;
}}
footer.submit-bar textarea {{
  flex: 1; min-width: 240px; background: var(--base); color: var(--text);
  border: 1px solid var(--overlay); border-radius: 8px; padding: 6px 10px; font-size: 14px;
  min-height: 36px;
}}
.btn {{
  background: var(--mauve); color: var(--base); border: none; border-radius: 8px;
  padding: 8px 16px; font-size: 14px; font-weight: 600; cursor: pointer;
}}
.btn.secondary {{ background: var(--overlay); color: var(--text); }}
.status-msg {{ font-size: 13px; color: var(--subtext); }}
.footer-badge {{
  background: var(--overlay); color: var(--text); border-radius: 8px;
  padding: 6px 12px; font-size: 13px; font-weight: 600;
}}
.footer-badge.warn {{ background: var(--yellow); color: var(--base); }}
</style>
</head>
<body>
<header>
  <h1>{title}</h1>
  <div class="intro-box">{intro_html}</div>
  <div class="counts-strip" id="counts-strip"></div>
</header>
<div class="filter-bar">
  <input type="text" id="search-box" placeholder="search... (/)" />
  <select id="area-filter"><option value="">all areas</option>{area_filter_opts}</select>
  <select id="verdict-filter"><option value="">all suggested verdicts</option>{verdict_filter_opts}</select>
  <label><input type="checkbox" id="needs-me-filter"> needs me</label>
  <label><input type="checkbox" id="touched-filter"> touched only</label>
  <label><input type="checkbox" id="untouched-filter"> untouched only</label>
</div>
<datalist id="group-options"></datalist>
<main id="main">
{area_tables}
</main>
<footer class="submit-bar">
  <span class="footer-badge" id="untouched-badge">untouched: 0</span>
  <label><input type="checkbox" id="accept-defaults"{accept_defaults_checked}> accept remaining defaults for untouched rows</label>
  <textarea id="global-note" placeholder="questions for the agent (applies to the whole review)"></textarea>
  <button class="btn" id="submit-btn">Submit</button>
  <button class="btn secondary" id="copy-btn">Copy answers as JSON</button>
  <span class="status-msg" id="status-msg"></span>
</footer>
<script>
const VERDICTS = {verdict_json};
const AREAS = {areas_json};
const SPEC_HASH = {spec_hash_json};

const state = {{}}; // itemId -> {{verdict, suggested, touched, group, note}}

function initState() {{
  document.querySelectorAll('.item-row').forEach(row => {{
    const id = row.dataset.itemId;
    const suggested = row.dataset.suggested || '';
    state[id] = {{ verdict: suggested, suggested, touched: false, agreed: false, group: '', note: '' }};
  }});
}}

function updateGroupOptions() {{
  const dl = document.getElementById('group-options');
  const groups = new Set();
  Object.values(state).forEach(s => {{ if (s.group) groups.add(s.group); }});
  dl.innerHTML = Array.from(groups).map(g => `<option value="${{g}}"></option>`).join('');
}}

function refreshRowClasses(row, id) {{
  const s = state[id];
  row.classList.toggle('touched', !!s.touched);
  row.classList.toggle('diverged', !!s.touched && s.verdict !== s.suggested);
  row.classList.toggle('agreed', !!s.agreed);
  row.classList.toggle('has-note', !!(s.note && s.note.trim()));
  const btn = row.querySelector('.agree-btn');
  if (btn) btn.classList.toggle('active', !!s.agreed);
}}

function updateCounts() {{
  const strip = document.getElementById('counts-strip');
  const total = Object.keys(state).length;
  let touched = 0;
  const perArea = {{}};
  const perVerdict = {{}};
  Object.entries(state).forEach(([id, s]) => {{
    if (s.touched) touched++;
    const row = document.getElementById('row-' + id);
    const area = row ? row.dataset.area : '';
    perArea[area] = (perArea[area] || 0) + 1;
    const v = s.verdict || '(none)';
    perVerdict[v] = (perVerdict[v] || 0) + 1;
  }});
  const parts = [`<span class="pill">${{total}} items</span>`, `<span class="pill">${{touched}} touched</span>`];
  AREAS.forEach(a => {{
    parts.push(`<span class="pill">${{a.title}}: ${{perArea[a.id] || 0}}</span>`);
    const cEl = document.querySelector(`[data-area-count="${{a.id}}"]`);
    if (cEl) cEl.textContent = `(${{perArea[a.id] || 0}})`;
  }});
  VERDICTS.forEach(v => {{
    parts.push(`<span class="pill">${{v.label}}: ${{perVerdict[v.id] || 0}}</span>`);
  }});
  strip.innerHTML = parts.join('');

  const untouched = total - touched;
  const badge = document.getElementById('untouched-badge');
  if (badge) {{
    badge.textContent = `untouched: ${{untouched}}`;
    badge.classList.toggle('warn', untouched > 0);
  }}
}}

function applyFilters() {{
  const q = document.getElementById('search-box').value.toLowerCase();
  const areaSel = document.getElementById('area-filter').value;
  const verdictSel = document.getElementById('verdict-filter').value;
  const needsMe = document.getElementById('needs-me-filter').checked;
  const touchedOnly = document.getElementById('touched-filter').checked;
  const untouchedOnly = document.getElementById('untouched-filter').checked;

  document.querySelectorAll('.item-row').forEach(row => {{
    const id = row.dataset.itemId;
    const s = state[id];
    let show = true;
    if (areaSel && row.dataset.area !== areaSel) show = false;
    if (verdictSel && row.dataset.suggested !== verdictSel) show = false;
    if (needsMe && row.dataset.needsMe !== '1') show = false;
    if (touchedOnly && !s.touched) show = false;
    if (untouchedOnly && s.touched) show = false;
    if (q) {{
      const text = row.textContent.toLowerCase();
      if (!text.includes(q)) show = false;
    }}
    row.classList.toggle('hidden-by-filter', !show);
  }});
}}

function wireRow(row) {{
  const id = row.dataset.itemId;
  row.querySelectorAll('input[type=radio]').forEach(r => {{
    r.addEventListener('change', () => {{
      state[id].verdict = r.value;
      state[id].touched = true;
      state[id].agreed = false;
      refreshRowClasses(row, id);
      updateCounts();
    }});
  }});
  const agreeBtn = row.querySelector('.agree-btn');
  if (agreeBtn) {{
    agreeBtn.addEventListener('click', () => {{ toggleAgree(row, id); }});
  }}
  const groupInput = row.querySelector('.group-input');
  groupInput.addEventListener('input', () => {{
    state[id].group = groupInput.value;
    state[id].touched = true;
    refreshRowClasses(row, id);
    updateGroupOptions();
  }});
  const sameAsAbove = row.querySelector('.same-as-above');
  sameAsAbove.addEventListener('click', () => {{
    const rows = Array.from(document.querySelectorAll('.item-row'));
    const idx = rows.indexOf(row);
    if (idx > 0) {{
      const prevId = rows[idx - 1].dataset.itemId;
      const g = state[prevId].group || '';
      groupInput.value = g;
      state[id].group = g;
      state[id].touched = true;
      refreshRowClasses(row, id);
      updateGroupOptions();
    }}
  }});
  const noteInput = row.querySelector('.note-input');
  noteInput.addEventListener('input', () => {{
    state[id].note = noteInput.value;
    state[id].touched = true;
    autoGrow(noteInput);
    refreshRowClasses(row, id);
    updateCounts();
  }});
  const evToggle = row.querySelector('.ev-toggle');
  if (evToggle) {{
    evToggle.addEventListener('click', () => {{
      const body = row.querySelector('.ev-body');
      body.hidden = !body.hidden;
    }});
  }}
  row.querySelectorAll('.dep-chip').forEach(chip => {{
    chip.addEventListener('click', () => {{
      const target = document.getElementById(chip.dataset.target);
      if (target) {{
        target.scrollIntoView({{ behavior: 'smooth', block: 'center' }});
        target.classList.add('focused-kb');
        setTimeout(() => target.classList.remove('focused-kb'), 1200);
      }}
    }});
  }});
}}

function autoGrow(el) {{
  el.style.height = 'auto';
  el.style.height = (el.scrollHeight) + 'px';
}}

function setRadioForVerdict(row, verdict) {{
  const radio = row.querySelector(`input[type=radio][value="${{CSS.escape(verdict)}}"]`);
  if (radio) radio.checked = true;
}}

function toggleAgree(row, id) {{
  const s = state[id];
  if (s.agreed) {{
    // toggle off — revert to untouched default
    s.agreed = false;
    s.touched = false;
    s.verdict = s.suggested;
  }} else {{
    s.verdict = s.suggested;
    s.touched = true;
    s.agreed = true;
  }}
  setRadioForVerdict(row, s.verdict);
  refreshRowClasses(row, id);
  updateCounts();
}}

function agreeAllVisible() {{
  document.querySelectorAll('.item-row:not(.hidden-by-filter)').forEach(row => {{
    const id = row.dataset.itemId;
    const s = state[id];
    s.verdict = s.suggested;
    s.touched = true;
    s.agreed = true;
    setRadioForVerdict(row, s.verdict);
    refreshRowClasses(row, id);
  }});
  updateCounts();
}}

function buildAnswers() {{
  const acceptDefaults = document.getElementById('accept-defaults').checked;
  const globalNote = document.getElementById('global-note').value;
  const items = Object.entries(state).map(([id, s]) => ({{
    id, verdict: s.verdict, suggested: s.suggested, touched: !!s.touched,
    group: s.group || '', note: s.note || '',
  }}));
  const untouchedCount = items.filter(i => !i.touched).length;
  return {{
    spec_hash: SPEC_HASH, accept_defaults: acceptDefaults, global_note: globalNote,
    untouched_count: untouchedCount, items,
  }};
}}

function wireKeyboard() {{
  let focusedIdx = -1;
  function rows() {{ return Array.from(document.querySelectorAll('.item-row:not(.hidden-by-filter)')); }}
  document.addEventListener('keydown', (e) => {{
    const tag = (e.target.tagName || '').toLowerCase();
    if (tag === 'input' || tag === 'textarea' || tag === 'select') {{
      if (e.key === 'Escape') e.target.blur();
      return;
    }}
    const rs = rows();
    if (e.key === 'j' || e.key === 'k') {{
      if (focusedIdx >= 0 && rs[focusedIdx]) rs[focusedIdx].classList.remove('focused-kb');
      if (e.key === 'j') focusedIdx = Math.min(rs.length - 1, focusedIdx + 1);
      else focusedIdx = Math.max(0, focusedIdx - 1);
      if (rs[focusedIdx]) {{
        rs[focusedIdx].classList.add('focused-kb');
        rs[focusedIdx].scrollIntoView({{ block: 'center', behavior: 'smooth' }});
      }}
    }} else if (/^[1-9]$/.test(e.key)) {{
      if (rs[focusedIdx]) {{
        const radios = rs[focusedIdx].querySelectorAll('input[type=radio]');
        const idx = parseInt(e.key, 10) - 1;
        if (radios[idx]) {{ radios[idx].checked = true; radios[idx].dispatchEvent(new Event('change')); }}
      }}
    }} else if (e.key === 'a') {{
      if (rs[focusedIdx]) {{
        const row = rs[focusedIdx];
        toggleAgree(row, row.dataset.itemId);
        e.preventDefault();
      }}
    }} else if (e.key === 'A') {{
      agreeAllVisible();
      e.preventDefault();
    }} else if (e.key === 'g') {{
      if (rs[focusedIdx]) {{ rs[focusedIdx].querySelector('.group-input').focus(); e.preventDefault(); }}
    }} else if (e.key === 'n') {{
      if (rs[focusedIdx]) {{ rs[focusedIdx].querySelector('.note-input').focus(); e.preventDefault(); }}
    }} else if (e.key === '/') {{
      document.getElementById('search-box').focus();
      e.preventDefault();
    }}
  }});
}}

async function submit() {{
  const answers = buildAnswers();
  if (answers.untouched_count > 0 && !answers.accept_defaults) {{
    const ok = confirm(
      `${{answers.untouched_count}} rows untouched — they will NOT be applied unless ` +
      `'accept remaining defaults' is ticked. Submit anyway?`
    );
    if (!ok) return;
  }}
  document.getElementById('status-msg').textContent = 'submitting...';
  try {{
    const resp = await fetch('/submit', {{
      method: 'POST', headers: {{ 'Content-Type': 'application/json' }},
      body: JSON.stringify(answers),
    }});
    if (resp.ok) {{
      document.getElementById('status-msg').textContent = 'submitted — you can close this tab.';
      document.body.innerHTML = '<div style="padding:60px;text-align:center;font-size:20px;color:#a6e3a1;">Submitted. You can close this tab.</div>';
    }} else {{
      document.getElementById('status-msg').textContent = 'submit failed: ' + resp.status;
    }}
  }} catch (err) {{
    document.getElementById('status-msg').textContent = 'submit failed: ' + err;
  }}
}}

function copyJson() {{
  const answers = buildAnswers();
  const text = JSON.stringify(answers, null, 2);
  navigator.clipboard.writeText(text).then(() => {{
    document.getElementById('status-msg').textContent = 'copied to clipboard.';
  }}).catch(() => {{
    document.getElementById('status-msg').textContent = 'copy failed — select manually.';
  }});
}}

initState();
document.querySelectorAll('.item-row').forEach(wireRow);
updateGroupOptions();
updateCounts();
applyFilters();
wireKeyboard();
['search-box'].forEach(id => document.getElementById(id).addEventListener('input', applyFilters));
['area-filter', 'verdict-filter'].forEach(id => document.getElementById(id).addEventListener('change', applyFilters));
['needs-me-filter', 'touched-filter', 'untouched-filter'].forEach(id => document.getElementById(id).addEventListener('change', applyFilters));
document.getElementById('submit-btn').addEventListener('click', submit);
document.getElementById('copy-btn').addEventListener('click', copyJson);
document.querySelectorAll('.note-input').forEach(autoGrow);
</script>
</body>
</html>
"""


# ---------------------------------------------------------------------------
# HTTP server
# ---------------------------------------------------------------------------

class ReviewHandler(http.server.BaseHTTPRequestHandler):
    page_html = b""
    result_holder = {}
    submitted_event = None

    def log_message(self, fmt, *args):
        pass  # quiet — this is a short-lived local server, not a service

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/", "/index.html"):
            body = self.page_html
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/submit":
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                payload = json.loads(raw.decode("utf-8"))
            except Exception as e:
                self.send_response(400)
                self.end_headers()
                self.wfile.write(("bad json: %s" % e).encode("utf-8"))
                return
            self.__class__.result_holder["answers"] = payload
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"ok":true}')
            self.__class__.submitted_event.set()
        else:
            self.send_response(404)
            self.end_headers()


def run_server(port: int, page_html: str, out_path: str):
    ReviewHandler.page_html = page_html.encode("utf-8")
    ReviewHandler.result_holder = {}
    ReviewHandler.submitted_event = threading.Event()

    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), ReviewHandler)
    server_thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    server_thread.start()

    ReviewHandler.submitted_event.wait()  # blocks until /submit posts

    answers = ReviewHandler.result_holder.get("answers", {})
    with open(out_path, "w") as f:
        json.dump(answers, f, indent=2)
        f.write("\n")

    httpd.shutdown()
    return answers


def main():
    ap = argparse.ArgumentParser(description="Serve a generic review-page buffer.")
    ap.add_argument("--spec", required=True, help="path to spec.json")
    ap.add_argument("--out", required=True, help="path to write answers.json")
    ap.add_argument("--title", default=None, help="override the page title")
    ap.add_argument("--port", default="auto", help="port number, or 'auto' for a free port")
    args = ap.parse_args()

    spec_path = os.path.abspath(args.spec)
    out_path = os.path.abspath(args.out)

    if not os.path.isfile(spec_path):
        sys.stderr.write("review-page.py: spec file not found: %s\n" % spec_path)
        sys.exit(2)

    with open(spec_path, "rb") as f:
        spec_bytes = f.read()
    try:
        spec = json.loads(spec_bytes.decode("utf-8"))
    except Exception as e:
        sys.stderr.write("review-page.py: invalid spec JSON: %s\n" % e)
        sys.exit(2)

    spec_hash = hash_spec(spec_bytes)
    reopen_count = prepare_open(out_path, spec_hash)

    sf = state_path_for(out_path)
    chan = gen_chan()
    write_state(sf, chan, "", "review-page", os.getpid(), spec_hash, reopen_count, 0)

    title = args.title or spec.get("title") or "Review"
    page_html = render_page(spec, title, spec_hash)

    if args.port == "auto":
        port = find_free_port()
    else:
        port = int(args.port)

    url = "http://127.0.0.1:%d/" % port
    print("review-page.py: serving %s" % url)
    open_browser(url)

    answers = run_server(port, page_html, out_path)

    write_state(sf, chan, "", "review-page", os.getpid(), spec_hash, reopen_count, 1)

    if shutil.which("tmux") and os.environ.get("TMUX"):
        subprocess.run(["tmux", "wait-for", "-S", chan], check=False)

    print("review-page.py: answers written to %s (%d items)" % (
        out_path, len(answers.get("items", []))
    ))
    sys.exit(0)


if __name__ == "__main__":
    main()
