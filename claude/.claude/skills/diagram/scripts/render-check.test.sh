#!/usr/bin/env bash
# render-check.test.sh — checks render-check.sh's usage errors, its
# no-renderer message, how it reports a renderer that fails or writes nothing
# (Linux, with stub renderers), and, when a real renderer is installed, that
# each common shape of <svg> root renders as a drawing rather than an error
# page: with and without xmlns, with its own style=, split over lines, and
# behind an XML prolog.
#
# Run: ./render-check.test.sh
# pass and fail always return 0, so "check && pass || fail" is safe here.
# shellcheck disable=SC2015
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC="$SCRIPT_DIR/render-check.sh"
WORK="$(mktemp -d)"
FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
trap 'rm -rf "$WORK"' EXIT

# Each fixture fills its whole viewBox with currentColor, so a real render has
# a dark centre pixel; an error page or XML tree view has a white one.
RECT='<rect width="100" height="100" fill="currentColor"/>'
NS='xmlns="http://www.w3.org/2000/svg"'
printf '%s\n' "<svg $NS viewBox=\"0 0 100 100\">$RECT</svg>" > "$WORK/plain.svg"
printf '%s\n' "<svg viewBox=\"0 0 100 100\" role=\"img\">$RECT</svg>" > "$WORK/noxmlns.svg"
printf '%s\n' "<svg $NS viewBox=\"0 0 100 100\" style=\"max-width:100%\">$RECT</svg>" > "$WORK/styled.svg"
printf '%s\n' '<svg' "  $NS" '  viewBox="0 0 100 100">' "$RECT</svg>" > "$WORK/multiline.svg"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' "<svg $NS viewBox=\"0 0 100 100\">$RECT</svg>" > "$WORK/prolog.svg"
FIXTURES="plain noxmlns styled multiline prolog"

# No argument: usage error, nonzero.
if bash "$RC" >/dev/null 2>&1; then fail "no argument exits nonzero"; else pass "no argument exits nonzero"; fi

# Missing file: exit 2.
bash "$RC" "$WORK/nope.svg" "$WORK/out" >/dev/null 2>&1
[ $? -eq 2 ] && pass "missing file exits 2" || fail "missing file exits 2"

# The standalone copy (what qlmanage renders) is well-formed XML with the
# colour on its root exactly once, for every fixture shape. Checked through
# the no-renderer path, which writes the copy before looking for a renderer.
if command -v python3 >/dev/null 2>&1 && ! command -v qlmanage >/dev/null 2>&1; then
  for f in $FIXTURES; do
    PLAYWRIGHT_BROWSERS_PATH="$WORK/none" bash "$RC" "$WORK/$f.svg" "$WORK/copy" >/dev/null 2>&1
    python3 - "$WORK/copy/$f.check.svg" <<'PY' && pass "$f: copy is well-formed with the colour once" || fail "$f: copy is well-formed with the colour once"
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
assert root.tag == "{http://www.w3.org/2000/svg}svg", root.tag
style = root.get("style", "")
assert style.count("color:#222") == 1, style
PY
  done
fi

# No renderer (Linux only; macOS always has qlmanage): exit 3 with the
# install hint.
if ! command -v qlmanage >/dev/null 2>&1; then
  err=$(PLAYWRIGHT_BROWSERS_PATH="$WORK/none" bash "$RC" "$WORK/plain.svg" "$WORK/out" 2>&1 >/dev/null)
  code=$?
  [ $code -eq 3 ] && pass "no renderer exits 3" || fail "no renderer exits 3 (got $code)"
  [[ $err == *"playwright"*"install chromium-headless-shell"* ]] \
    && pass "no renderer prints the install command" \
    || fail "no renderer prints the install command: $err"

  # Stub renderers, found the way a real install is.
  stub() {
    local dir="$WORK/$1/chromium_headless_shell-9999/chrome-headless-shell-linux64"
    mkdir -p "$dir"
    printf '#!/bin/sh\n%s\n' "$2" > "$dir/chrome-headless-shell"
    chmod +x "$dir/chrome-headless-shell"
  }

  # A renderer that exits 0 but writes nothing: exit 4, even when an old PNG
  # from an earlier round sits where the new one would go.
  stub silent 'exit 0'
  mkdir -p "$WORK/stale" && echo old > "$WORK/stale/plain.check.png"
  PLAYWRIGHT_BROWSERS_PATH="$WORK/silent" bash "$RC" "$WORK/plain.svg" "$WORK/stale" >/dev/null 2>&1
  code=$?
  [ $code -eq 4 ] && pass "renderer writing nothing exits 4, old PNG ignored" \
    || fail "renderer writing nothing exits 4, old PNG ignored (got $code)"

  # A renderer that crashes: exit 4 with a message naming the failure.
  stub crash 'echo boom >&2; exit 1'
  err=$(PLAYWRIGHT_BROWSERS_PATH="$WORK/crash" bash "$RC" "$WORK/plain.svg" "$WORK/crash-out" 2>&1 >/dev/null)
  code=$?
  [ $code -eq 4 ] && pass "crashing renderer exits 4" || fail "crashing renderer exits 4 (got $code)"
  [[ $err == *"renderer failed (exit 1)"*boom* ]] \
    && pass "crashing renderer is reported with its output" \
    || fail "crashing renderer is reported with its output: $err"
fi

# No out-dir: a fresh temp dir each run, never a shared fixed path.
if ! command -v qlmanage >/dev/null 2>&1; then
  a=$(PLAYWRIGHT_BROWSERS_PATH="$WORK/silent" bash "$RC" "$WORK/plain.svg" 2>&1 | sed -n 's/.*(see \(.*\)\/plain\.check\.log).*/\1/p')
  b=$(PLAYWRIGHT_BROWSERS_PATH="$WORK/silent" bash "$RC" "$WORK/plain.svg" 2>&1 | sed -n 's/.*(see \(.*\)\/plain\.check\.log).*/\1/p')
  [ -n "$a" ] && [ "$a" != "$b" ] && pass "default out-dir is fresh per run" || fail "default out-dir is fresh per run ('$a' vs '$b')"
  rm -rf "$a" "$b"
fi

# Real render of every fixture shape, when a renderer exists.
bash "$RC" "$WORK/plain.svg" "$WORK/probe" >/dev/null 2>&1
if [ $? -eq 3 ]; then
  echo "SKIP: no renderer installed, real render not checked"
else
  for f in $FIXTURES; do
    png=$(bash "$RC" "$WORK/$f.svg" "$WORK/out" 2>/dev/null)
    code=$?
    if [ $code -ne 0 ] || [ ! -s "$png" ]; then
      fail "$f: renders a PNG (code $code, '$png')"
      continue
    fi
    if ! command -v python3 >/dev/null 2>&1; then
      pass "$f: renders a non-empty PNG (no python3, drawing not checked)"
      continue
    fi
    python3 - "$png" <<'PY' && pass "$f: render shows the drawing" || fail "$f: render shows the drawing (error page?)"
import sys, struct, zlib
data = open(sys.argv[1], "rb").read()
assert data[:8] == b"\x89PNG\r\n\x1a\n"
pos, idat = 8, b""
while pos < len(data):
    n, kind = struct.unpack(">I4s", data[pos:pos + 8])
    body = data[pos + 8:pos + 8 + n]
    if kind == b"IHDR":
        w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
    elif kind == b"IDAT":
        idat += body
    pos += 12 + n
assert depth == 8 and ctype in (2, 6), (depth, ctype)
bpp = 3 if ctype == 2 else 4
raw, stride, prev, rows, i = zlib.decompress(idat), w * bpp, bytearray(w * bpp), [], 0
for _ in range(h):
    f, line = raw[i], bytearray(raw[i + 1:i + 1 + stride]); i += 1 + stride
    for x in range(stride):
        a = line[x - bpp] if x >= bpp else 0
        b, c = prev[x], prev[x - bpp] if x >= bpp else 0
        if f == 1: line[x] = (line[x] + a) & 255
        elif f == 2: line[x] = (line[x] + b) & 255
        elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
        elif f == 4:
            p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
    rows.append(line); prev = line
px = rows[h // 2][(w // 2) * bpp:(w // 2) * bpp + 3]
assert max(px) < 100, f"centre pixel {tuple(px)} is not the dark fill"
PY
  done
  grep -q 'style=' "$WORK/plain.svg" && fail "original left untouched" || pass "original left untouched"
fi

[ $FAIL -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
