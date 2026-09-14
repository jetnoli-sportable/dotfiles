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
  review-page.py --spec <spec.json> --out <answers.json> [--title TITLE] [--port N]   (default: 8765, or next free)

Behaviour:
  1. Load and validate the spec.
  2. Serve on 127.0.0.1:8765 so the URL is stable/bookmarkable (falls forward to the next free port if busy; --port N overrides).
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


def _wait_for_chan_or_death(chan: str, caller_pid, poll_interval: float = 1.0) -> bool:
    """Block until either `tmux wait-for <chan>` unblocks (the original
    process reached its own signal-and-exit) or <caller_pid> dies first
    (it was killed mid-review, so the signal will never come). Polls the
    subprocess and pid_alive() rather than a bare blocking wait-for, so a
    process that dies AFTER --reattach starts waiting is still caught —
    not just the already-dead case checked before the wait begins."""
    proc = subprocess.Popen(
        ["tmux", "wait-for", chan],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    while True:
        if proc.poll() is not None:
            return True
        if not pid_alive(caller_pid):
            proc.kill()
            return False
        time.sleep(poll_interval)


def mode_reattach(out_path: str):
    """--reattach <answers.json> — resume the wait recorded by an earlier
    (now backgrounded, possibly-dead) `review-page.py` invocation for the
    same --out path, mirroring open-buffer.sh's own reattach decision tree
    (references/spec-and-close-contract.md, mechanism.md) rather than a
    fresh one: this is the one case (a stale in-flight review) the two
    scripts share, so the shape stays recognizable across both.

    Decision tree:
      - no state file at all              -> nothing to reattach, exit 1
      - closed=1 (a normal prior close)    -> print <out_path>, exit 0
      - closed=0, caller_pid already dead  -> exit 3 (process died before
                                               submit — re-run)
      - closed=0, caller_pid alive         -> wait (tmux wait-for <chan> if
                                               tmux+TMUX are available, else
                                               poll the state file) until it
                                               flips to closed=1 or the pid
                                               dies underneath the wait.
    """
    out_path = os.path.abspath(out_path)
    sf = state_path_for(out_path)
    state = read_state(sf)
    if not state:
        sys.stderr.write("review-page.py: nothing to reattach for %s (no state file)\n" % out_path)
        sys.exit(1)

    if state.get("closed") == "1":
        # A normal close writes answers.json BEFORE rewriting the state
        # file (run_server returns, then main() calls write_state) — so
        # closed=1 always implies the file is already on disk.
        print(out_path)
        sys.exit(0)

    caller_pid = state.get("caller_pid")
    chan = state.get("chan")

    if not pid_alive(caller_pid):
        sys.stderr.write("review-page.py: page process died before submit — re-run\n")
        sys.exit(3)

    if shutil.which("tmux") and os.environ.get("TMUX"):
        signaled = _wait_for_chan_or_death(chan, caller_pid)
    else:
        signaled = False
        while True:
            time.sleep(1)
            cur = read_state(sf)
            if cur and cur.get("closed") == "1":
                signaled = True
                break
            if not pid_alive(caller_pid):
                break

    if not signaled:
        sys.stderr.write("review-page.py: page process died before submit — re-run\n")
        sys.exit(3)

    print(out_path)
    sys.exit(0)


DEFAULT_PORT = 8765  # stable, bookmarkable; a second concurrent page falls forward


def port_is_free(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        return s.connect_ex(("127.0.0.1", port)) != 0


def pick_port(preferred: int = DEFAULT_PORT, tries: int = 10) -> int:
    for p in range(preferred, preferred + tries):
        if port_is_free(p):
            return p
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def find_free_port() -> int:
    return pick_port()


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
        .replace("'", "&#39;")
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


def md_block(s: str) -> str:
    """Small block-level markdown -> HTML for long bodies (descriptions,
    top-of-page sections): paragraphs, `- `/`* ` bullets, `1. ` numbered
    lists, `#`/`##`/`###` headings, ``` fences, plus md_lite inline. Not a
    full markdown parser — enough for a task Plan body to read well."""
    if not s:
        return ""
    import re
    lines = s.splitlines()
    out, i = [], 0
    para = []
    def flush_para():
        if para:
            out.append("<p>%s</p>" % md_lite("\n".join(para)))
            para.clear()
    while i < len(lines):
        ln = lines[i]
        if ln.strip().startswith("```"):
            flush_para()
            j = i + 1
            buf = []
            while j < len(lines) and not lines[j].strip().startswith("```"):
                buf.append(lines[j]); j += 1
            if j >= len(lines):
                # Unclosed fence: never swallow the rest of the body — treat the
                # opening ``` as ordinary text and keep parsing from the next line.
                para.append(ln)
                i += 1
                continue
            out.append("<pre class='md-pre'>%s</pre>" % esc("\n".join(buf)))
            i = j + 1
            continue
        m = re.match(r"^(#{1,4})\s+(.*)$", ln)
        if m:
            flush_para()
            lvl = min(len(m.group(1)) + 2, 6)
            out.append("<h%d class='md-h'>%s</h%d>" % (lvl, md_lite(m.group(2)), lvl))
            i += 1
            continue
        if re.match(r"^\s*[-*]\s+", ln):
            flush_para()
            items = []
            while i < len(lines) and re.match(r"^\s*[-*]\s+", lines[i]):
                item = re.sub(r"^\s*[-*]\s+", "", lines[i])
                i += 1
                # continuation lines (indented, non-bullet) belong to the item
                while i < len(lines) and lines[i].startswith("  ") and not re.match(r"^\s*[-*]\s+|^\s*\d+\.\s+", lines[i]):
                    item += " " + lines[i].strip(); i += 1
                items.append("<li>%s</li>" % md_lite(item))
            out.append("<ul class='md-ul'>%s</ul>" % "".join(items))
            continue
        if re.match(r"^\s*\d+\.\s+", ln):
            flush_para()
            items = []
            while i < len(lines) and re.match(r"^\s*\d+\.\s+", lines[i]):
                item = re.sub(r"^\s*\d+\.\s+", "", lines[i])
                i += 1
                while i < len(lines) and lines[i].startswith("  ") and not re.match(r"^\s*[-*]\s+|^\s*\d+\.\s+", lines[i]):
                    item += " " + lines[i].strip(); i += 1
                items.append("<li>%s</li>" % md_lite(item))
            out.append("<ol class='md-ol'>%s</ol>" % "".join(items))
            continue
        if not ln.strip():
            flush_para()
            i += 1
            continue
        para.append(ln)
        i += 1
    flush_para()
    return "".join(out)


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

    def meta_html(meta):
        """`meta`: list of [label, value] pairs (or a dict) -> compact chips
        in the item cell — structured facts the reviewer should see without
        expanding anything (size, slug, stage path, owner, ...)."""
        if not meta:
            return ""
        pairs = meta.items() if isinstance(meta, dict) else meta
        chips = []
        for pair in pairs:
            try:
                k, v = pair
            except Exception:
                continue
            if v in (None, "", [], {}):
                continue
            if isinstance(v, (list, tuple)):
                v = ", ".join(str(x) for x in v)
            chips.append('<span class="meta-chip"><span class="meta-k">%s</span> %s</span>' % (esc(k), esc(v)))
        return ('<div class="item-meta">%s</div>' % "".join(chips)) if chips else ""

    def fields_html(iid, fields):
        """`fields`: list of {key,label,value,placeholder,wide} -> editable
        inputs inside the details panel. Values come back in answers.json
        under item.fields; a changed value marks the row touched."""
        if not fields:
            return ""
        parts = []
        for f in fields:
            key = esc(f.get("key", ""))
            if not key:
                continue
            label = esc(f.get("label", key))
            value = esc(f.get("value", ""))
            ph = esc(f.get("placeholder", ""))
            wide = " wide" if f.get("wide") else ""
            parts.append(
                '<label class="field%s"><span class="field-label">%s</span>'
                '<input type="text" class="field-input" data-item-id="%s" data-field-key="%s" '
                'data-original="%s" value="%s" placeholder="%s"></label>' % (
                    wide, label, iid, key, value, value, ph))
        return ('<div class="fields-grid">%s</div>' % "".join(parts)) if parts else ""

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
            meta = meta_html(item.get("meta"))
            description = item.get("description", "")
            fields = item.get("fields") or []
            has_details = bool(description or fields)
            details_html = ""
            if has_details:
                details_html = f'''
<tr id="details-{iid}" class="details-row" data-item-id="{iid}" data-area="{aid}" hidden>
  <td colspan="8" class="details-cell">
    {fields_html(iid, fields)}
    {f'<div class="details-body">{md_block(description)}</div>' if description else ''}
  </td>
</tr>'''
            details_btn = (
                f'<button type="button" class="details-toggle" data-action="toggle-details" '
                f'data-item-id="{iid}" title="expand details (d)">details &#9656;</button>'
            ) if has_details else ""
            needs_me = "1" if (not suggested or "unclear" in reason.lower()) else "0"

            rows_html.append(f'''
<tr id="row-{iid}" class="item-row" data-item-id="{iid}" data-area="{aid}"
    data-suggested="{esc(suggested)}" data-needs-me="{needs_me}">
  <td class="col-n">{row_counter}</td>
  <td class="col-item">
    <div class="item-title">{esc(item.get("title", iid))}</div>
    <div class="item-where">{where}</div>
    {meta}
    <div class="item-links">{links} {details_btn}</div>
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
</tr>{details_html}''')
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

    # `sections`: list of {title, md, open} rendered as collapsible panels
    # between the intro box and the tables — for a directions summary, a
    # glossary, a "how this maps onto the apply step" note. Closed unless
    # `open: true`.
    sections_html = ""
    for sec in spec.get("sections") or []:
        stitle = esc(sec.get("title", "section"))
        sbody = md_block(sec.get("md", ""))
        sopen = " open" if sec.get("open") else ""
        sections_html += f'<details class="page-section"{sopen}><summary>{stitle}</summary><div class="page-section-body">{sbody}</div></details>'

    # `hide_columns`: list of column keys (what, evidence, deps, group, note)
    # to hide when a review doesn't use them — frees width for the rest.
    hide_cols = spec.get("hide_columns") or []
    hide_css = "".join(
        ".review-table .col-%s { display: none; }" % esc(c) for c in hide_cols
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
        sections_html=sections_html,
        hide_css=hide_css,
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
.page-section {{
  background: var(--surface); border: 1px solid var(--overlay); border-radius: 10px;
  padding: 8px 16px; margin: 10px 0; max-width: 1100px;
}}
.page-section > summary {{ cursor: pointer; font-weight: 600; font-size: 15px; }}
.page-section-body {{ font-size: 14px; color: var(--text); margin-top: 6px; }}
.item-meta {{ margin-top: 4px; display: flex; flex-wrap: wrap; gap: 4px; }}
.meta-chip {{
  display: inline-block; background: var(--base); border: 1px solid var(--overlay);
  border-radius: 6px; padding: 1px 6px; font-size: 12px; font-family: monospace;
}}
.meta-k {{ color: var(--subtext); }}
.details-toggle {{
  background: var(--overlay); color: var(--text); border: none; border-radius: 6px;
  padding: 3px 8px; font-size: 12px; cursor: pointer; margin-left: 4px;
}}
.details-toggle.open {{ background: var(--mauve); color: var(--base); }}
.details-row td.details-cell {{
  background: var(--base); padding: 12px 18px 14px 40px; font-size: 14px;
  border-bottom: 2px solid var(--overlay);
}}
.details-body {{ max-width: 1100px; }}
.details-body p {{ margin: 4px 0 8px; }}
.md-h {{ margin: 10px 0 4px; font-size: 14px; color: var(--mauve); }}
.md-ul, .md-ol {{ margin: 4px 0 8px 20px; padding: 0; }}
.md-pre {{ background: var(--surface); padding: 8px 10px; border-radius: 6px; overflow-x: auto; font-size: 12px; }}
.fields-grid {{ display: flex; flex-wrap: wrap; gap: 10px 16px; margin-bottom: 10px; }}
.field {{ display: flex; flex-direction: column; gap: 2px; font-size: 12px; color: var(--subtext); min-width: 160px; }}
.field.wide {{ flex: 1 1 100%; }}
.field-input {{
  background: var(--surface); color: var(--text); border: 1px solid var(--overlay);
  border-radius: 6px; padding: 5px 7px; font-size: 13px; font-family: monospace;
}}
.field-input.changed {{ border-color: var(--yellow); }}
.details-row.hidden-by-filter {{ display: none; }}
{hide_css}
</style>
</head>
<body>
<header>
  <h1>{title}</h1>
  <div class="intro-box">{intro_html}</div>
  {sections_html}
  <div class="counts-strip" id="counts-strip"></div>
</header>
<div class="filter-bar">
  <input type="text" id="search-box" placeholder="search... (/)" />
  <select id="area-filter"><option value="">all areas</option>{area_filter_opts}</select>
  <select id="verdict-filter"><option value="">all suggested verdicts</option>{verdict_filter_opts}</select>
  <label><input type="checkbox" id="needs-me-filter"> needs me</label>
  <label><input type="checkbox" id="touched-filter"> touched only</label>
  <label><input type="checkbox" id="untouched-filter"> untouched only</label>
  <button type="button" class="btn secondary" id="expand-all" style="padding:4px 10px;font-size:12px">expand all details</button>
  <button type="button" class="btn secondary" id="collapse-all" style="padding:4px 10px;font-size:12px">collapse all</button>
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
    state[id] = {{ verdict: suggested, suggested, touched: false, agreed: false, group: '', note: '', fields: {{}}, fieldsChanged: false }};
    const details = document.getElementById('details-' + id);
    if (details) {{
      details.querySelectorAll('.field-input').forEach(inp => {{
        state[id].fields[inp.dataset.fieldKey] = inp.value;
      }});
    }}
  }});
}}

function setDetails(id, open) {{
  const details = document.getElementById('details-' + id);
  const btn = document.querySelector(`.details-toggle[data-item-id="${{CSS.escape(id)}}"]`);
  if (!details) return;
  details.hidden = !open;
  if (btn) {{
    btn.classList.toggle('open', open);
    btn.innerHTML = open ? 'details &#9662;' : 'details &#9656;';
  }}
}}

function toggleDetails(id) {{
  const details = document.getElementById('details-' + id);
  if (details) setDetails(id, details.hidden);
}}

function setAllDetails(open) {{
  document.querySelectorAll('.item-row:not(.hidden-by-filter)').forEach(row => setDetails(row.dataset.itemId, open));
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
    const details = document.getElementById('details-' + id);
    if (details) details.classList.toggle('hidden-by-filter', !show);
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
  const detailsBtn = row.querySelector('.details-toggle');
  if (detailsBtn) {{
    detailsBtn.addEventListener('click', () => toggleDetails(id));
  }}
  const detailsRow = document.getElementById('details-' + id);
  if (detailsRow) {{
    detailsRow.querySelectorAll('.field-input').forEach(inp => {{
      inp.addEventListener('input', () => {{
        state[id].fields[inp.dataset.fieldKey] = inp.value;
        const changed = inp.value !== inp.dataset.original;
        inp.classList.toggle('changed', changed);
        state[id].fieldsChanged = Array.from(detailsRow.querySelectorAll('.field-input')).some(x => x.value !== x.dataset.original);
        state[id].touched = true;
        refreshRowClasses(row, id);
        updateCounts();
      }});
    }});
  }}
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
    fields: s.fields || {{}}, fields_changed: !!s.fieldsChanged,
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
    }} else if (e.key === 'd') {{
      if (rs[focusedIdx]) {{ toggleDetails(rs[focusedIdx].dataset.itemId); e.preventDefault(); }}
    }} else if (e.key === 'D') {{
      const anyOpen = Array.from(document.querySelectorAll('.details-row')).some(d => !d.hidden);
      setAllDetails(!anyOpen);
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
document.getElementById('expand-all').addEventListener('click', () => setAllDetails(true));
document.getElementById('collapse-all').addEventListener('click', () => setAllDetails(false));
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
    spec_hash = ""          # the hash this server rendered; /submit must echo it
    port = 0                # bound port; /submit must come from this origin

    MAX_BODY = 8 * 1024 * 1024

    def _reject(self, code, msg):
        body = msg.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _origin_ok(self) -> bool:
        """Only the page this server rendered may submit: same-origin on
        127.0.0.1:<port>. A cross-origin page in the same browser (DNS
        rebinding, a hostile tab) sends a foreign Origin, or none with a
        foreign Referer; a bare curl sends neither and is allowed (agent /
        test use)."""
        allowed = {"http://127.0.0.1:%d" % self.port, "http://localhost:%d" % self.port}
        origin = self.headers.get("Origin")
        if origin is not None:
            return origin.rstrip("/") in allowed
        referer = self.headers.get("Referer")
        if referer:
            return any(referer.startswith(a + "/") or referer == a for a in allowed)
        return True

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
            if not self._origin_ok():
                self._reject(403, "forbidden: cross-origin submit")
                return
            ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
            if ctype != "application/json":
                self._reject(415, "unsupported media type: expected application/json")
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                self._reject(400, "bad Content-Length")
                return
            if length < 0 or length > self.MAX_BODY:
                self._reject(413, "payload too large")
                return
            raw = self.rfile.read(length) if length else b"{}"
            try:
                payload = json.loads(raw.decode("utf-8"))
            except Exception as e:
                self._reject(400, "bad json: %s" % e)
                return
            if not isinstance(payload, dict) or payload.get("spec_hash") != self.spec_hash:
                # A stale tab from an earlier review on the same port, or a
                # forged body, carries a different hash: never treat it as
                # this review's answers.
                self._reject(409, "spec_hash mismatch: this page is not the review being served")
                return
            if self.__class__.submitted_event.is_set():
                self._reject(409, "already submitted")
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


def bind_server(port, page_html: str, spec_hash: str, tries: int = 10):
    """Bind the HTTP server BEFORE anything is printed or a browser opened.
    `port` is an int to bind exactly, or "auto" to start at DEFAULT_PORT and
    fall forward on EADDRINUSE — the probe-then-bind race the old pick_port
    path had is closed by binding directly and retrying on failure."""
    ReviewHandler.page_html = page_html.encode("utf-8")
    ReviewHandler.result_holder = {}
    ReviewHandler.submitted_event = threading.Event()
    ReviewHandler.spec_hash = spec_hash
    candidates = [int(port)] if port != "auto" else list(range(DEFAULT_PORT, DEFAULT_PORT + tries))
    last_err = None
    for p in candidates:
        try:
            httpd = http.server.ThreadingHTTPServer(("127.0.0.1", p), ReviewHandler)
        except OSError as e:
            last_err = e
            continue
        ReviewHandler.port = p
        return httpd, p
    raise SystemExit("review-page.py: could not bind any port (%s..%s): %s" % (
        candidates[0], candidates[-1], last_err))


def run_server(httpd, out_path: str, timeout=None):
    """Blocks until /submit posts, or (with --timeout) until <timeout>
    seconds pass with no submit — a closed/never-opened tab otherwise waits
    forever. Returns the answers dict on a normal submit, or None on
    timeout; the caller (main) tells the two apart to decide whether to
    write answers.json / flip the state file to closed=1 at all."""
    server_thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    server_thread.start()

    got_submit = ReviewHandler.submitted_event.wait(timeout)
    if not got_submit:
        httpd.shutdown()
        return None

    answers = ReviewHandler.result_holder.get("answers", {})
    with open(out_path, "w") as f:
        json.dump(answers, f, indent=2)
        f.write("\n")

    httpd.shutdown()
    return answers


def main():
    ap = argparse.ArgumentParser(description="Serve a generic review-page buffer.")
    ap.add_argument("--spec", default=None, help="path to spec.json (required unless --reattach)")
    ap.add_argument("--out", default=None, help="path to write answers.json (required unless --reattach)")
    ap.add_argument("--title", default=None, help="override the page title")
    ap.add_argument("--port", default="auto", help="port number; default picks %d (or the next free one above it)" % DEFAULT_PORT)
    ap.add_argument("--reattach", metavar="ANSWERS_JSON", default=None,
                     help="resume waiting on an earlier --out invocation instead of starting a new review")
    ap.add_argument("--timeout", type=float, default=None, metavar="SECS",
                     help="give up waiting for a submit after SECS seconds (default: wait forever); "
                          "exits 4, leaves the state file closed=0, writes no answers.json")
    args = ap.parse_args()

    if args.reattach is not None:
        mode_reattach(args.reattach)  # never returns

    if not args.spec or not args.out:
        ap.error("--spec and --out are required (unless --reattach is given)")

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

    httpd, port = bind_server(args.port, page_html, spec_hash)

    url = "http://127.0.0.1:%d/" % port
    print("review-page.py: serving %s" % url)
    open_browser(url)

    answers = run_server(httpd, out_path, timeout=args.timeout)

    if answers is None:
        # Timed out — the tab was closed without Submit, or never opened.
        # Leave the state file at closed=0 (this run never happened, as far
        # as the state file is concerned) and write nothing: recovery is
        # `--reattach <out>` (if the caller wants to keep waiting) or a
        # fresh `--spec`/`--out` re-run, not a corrupted answers.json.
        sys.stderr.write(
            "review-page.py: timed out after %ss waiting for a submit — "
            "the tab may be closed or was never opened. Recover with "
            "`review-page.py --reattach %s` to keep waiting, or kill this "
            "process and re-run.\n" % (args.timeout, out_path)
        )
        sys.exit(4)

    write_state(sf, chan, "", "review-page", os.getpid(), spec_hash, reopen_count, 1)

    if shutil.which("tmux") and os.environ.get("TMUX"):
        subprocess.run(["tmux", "wait-for", "-S", chan], check=False)

    print("review-page.py: answers written to %s (%d items)" % (
        out_path, len(answers.get("items", []))
    ))
    sys.exit(0)


if __name__ == "__main__":
    main()
