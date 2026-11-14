"""pagekit.py: the helpers decision-page.py and review-page.py share. Each generator
imports it from this folder, found through its own realpath so the stow symlinks resolve."""

import os
import shutil
import subprocess
import webbrowser


def script_safe(js: str) -> str:
    """Keep spec text from ending or confusing the <script> it sits in.

    Every "<" becomes \\u003c, which covers "</script", "<script" and "<!--" and still
    parses back to the same text."""
    return js.replace("<", "\\u003c").replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")


def unopenable_reason(path: str):
    """Snap Chromium can't read /tmp or hidden directories; say why, or None."""
    parent = os.path.dirname(os.path.abspath(path))
    if parent == "/tmp" or parent.startswith("/tmp/"):
        return "under /tmp, which snap Chromium can't read"
    hidden = [p for p in parent.split(os.sep) if p.startswith(".") and p not in (".", "..")]
    if hidden:
        return "inside hidden directory %s, which snap Chromium can't read" % hidden[0]
    return None


def open_browser(url: str, no_opener_msg: str):
    """Open url in snap Chromium, else xdg-open, else the webbrowser module; print
    no_opener_msg if none of them works."""
    chromium = "/snap/bin/chromium"
    if os.path.exists(chromium):
        argv = [chromium, url]
    elif shutil.which("xdg-open"):
        argv = ["xdg-open", url]
    else:
        try:
            webbrowser.open(url)
        except Exception:
            print(no_opener_msg)
        return
    subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
