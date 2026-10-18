#!/usr/bin/env python3
"""review-page.py — the "review-page" shape's mechanism: a self-contained,
locally-served HTML review page for a big batch of items answered from one
shared verdict list (decision-page/SKILL.md owns the which-tool rule).

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
  3. Render the page from templates/page.html and the shared kit in
     ../decision-page/kit/ (inline CSS+JS, no CDNs); the page builds its rows
     in the browser from the embedded spec.
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
import html
import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path
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


# ---------------------------------------------------------------------------
# HTML rendering
# ---------------------------------------------------------------------------

SKILL_DIR = Path(os.path.realpath(__file__)).parent.parent  # resolves the stow symlink to the repo copy
TEMPLATE = SKILL_DIR / "templates" / "page.html"
KIT_DIR = SKILL_DIR.parent / "decision-page" / "kit"  # the page kit both pages share
KIT_CSS = KIT_DIR / "kit.css"
KIT_JS = KIT_DIR / "kit.js"
PAGEKIT = KIT_DIR / "pagekit.py"  # helpers shared with decision-page.py

sys.dont_write_bytecode = True  # keep __pycache__ out of the stowed kit dir
sys.path.insert(0, str(KIT_DIR))
try:
    from pagekit import open_browser, script_safe
except ImportError:
    sys.stderr.write('review-page.py: missing %s; run: stow --no-folding -t "$HOME" claude\n' % PAGEKIT)
    sys.exit(1)


def duplicate_ids(spec) -> list:
    """Item ids that appear more than once across all areas, in first-seen order.
    An item without an id is skipped: the page numbers it item-<n> itself."""
    seen, dups = set(), []
    for a in (spec.get("areas") or []) if isinstance(spec, dict) else []:
        for i in (a.get("items") or []) if isinstance(a, dict) else []:
            iid = i.get("id") if isinstance(i, dict) else None
            if not iid or not isinstance(iid, str):
                continue
            if iid in seen and iid not in dups:
                dups.append(iid)
            seen.add(iid)
    return dups


def render_page(spec: dict, title: str, spec_hash: str) -> str:
    """Fill templates/page.html. The page builds its rows in the browser from the
    embedded spec, on the shared kit (decision-page/kit/)."""
    for p in (TEMPLATE, KIT_CSS, KIT_JS):
        if not p.is_file():
            sys.stderr.write('review-page.py: missing %s; run: stow --no-folding -t "$HOME" claude\n' % p)
            sys.exit(1)
    n = sum(len(a.get("items", [])) for a in spec.get("areas") or [])
    parts = {
        "TITLE": html.escape(title),
        "DESCRIPTION": html.escape("Review page: %d row%s to review." % (n, "" if n == 1 else "s")),
        "SPEC_HASH": spec_hash,
        "KIT_CSS": KIT_CSS.read_text(encoding="utf-8"),
        "KIT_JS": KIT_JS.read_text(encoding="utf-8"),
        "SPEC_JSON": script_safe(json.dumps(spec, ensure_ascii=False)),
    }
    # One pass, so a placeholder-shaped string inside the spec or kit is never substituted.
    return re.sub(r"\{\{([A-Z_]+)\}\}", lambda m: parts.get(m.group(1), m.group(0)),
                  TEMPLATE.read_text(encoding="utf-8"))


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
    fall forward on EADDRINUSE. Binding directly and retrying on failure
    avoids a probe-then-bind race."""
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

    dups = duplicate_ids(spec)
    if dups:
        for d in dups:
            sys.stderr.write('review-page.py: item "%s": duplicate id\n' % d)
        sys.exit(2)

    spec_hash = hash_spec(spec_bytes)
    title = args.title or spec.get("title") or "Review"
    page_html = render_page(spec, title, spec_hash)  # before any state is written: a missing template exits cleanly
    reopen_count = prepare_open(out_path, spec_hash)

    sf = state_path_for(out_path)
    chan = gen_chan()
    write_state(sf, chan, "", "review-page", os.getpid(), spec_hash, reopen_count, 0)

    httpd, port = bind_server(args.port, page_html, spec_hash)

    url = "http://127.0.0.1:%d/" % port
    print("review-page.py: serving %s" % url)
    open_browser(url, "review-page.py: no browser opener found — open manually: %s" % url)

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
