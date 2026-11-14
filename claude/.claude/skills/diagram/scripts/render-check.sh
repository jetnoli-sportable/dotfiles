#!/usr/bin/env bash
# render-check.sh — render an SVG to a PNG so the agent can look at it before
# showing it (the /diagram skill's "check against a render" step).
#
# Usage: render-check.sh <in.svg> [out-dir]
#   Prints the PNG's path. out-dir defaults to a fresh temp dir, so two
#   sessions never share (or reuse) each other's PNG.
#
# Exit codes: 2 no such input file, 3 no renderer installed (stderr has the
# one-time install command), 4 the renderer failed or wrote no PNG.
#
# Text is drawn in a fixed colour on white, because a page diagram draws with
# currentColor and would otherwise render black-on-clear.
#
# Renderers, first found wins:
#   macOS  qlmanage (Quick Look, built in), on a copy of the SVG made
#          well-formed: xmlns added if missing, the colour merged into any
#          existing style= on the root, and a root tag split over lines handled.
#   Linux  Playwright's chrome-headless-shell, then its full chromium, from
#          ~/.cache/ms-playwright (newest version), on an HTML page wrapping
#          the SVG. The HTML parser accepts what an SVG cut out of a page
#          looks like (no xmlns, its own style=); opening it as a .svg file
#          makes Chromium parse strict XML and screenshot an error page.
#          Not the snap chromium: a snap has its own /tmp and can't read
#          hidden dirs, so it can't open a scratchpad file.
# --no-sandbox is needed where AppArmor blocks Chromium's user-namespace
# sandbox (Ubuntu 23.10+). It's safe here: the page is a local SVG we wrote,
# rendered with no network.
set -euo pipefail

in=${1:?usage: render-check.sh <in.svg> [out-dir]}
[ -f "$in" ] || { echo "render-check: no such file: $in" >&2; exit 2; }
out_dir=${2:-$(mktemp -d)}
mkdir -p "$out_dir"
out_dir=$(cd "$out_dir" && pwd)

base=$(basename "${in%.svg}")
check="$out_dir/$base.check.svg"
html="$out_dir/$base.check.html"
png="$out_dir/$base.check.png"
log="$out_dir/$base.check.log"
rm -f "$png" "$check.png" "$log"

# The SVG without any XML prolog or doctype, so it can sit inside HTML.
body=$(perl -0777 -pe 's/\A\s*<\?xml[^>]*\?>//; s/\A\s*<!DOCTYPE[^>]*>//i' "$in")

# Well-formed standalone copy: edit the first <svg ...> tag only.
printf '%s\n' "$body" | perl -0777 -pe '
  s{<svg\b([^>]*)>}{
    my $a = $1;
    $a =~ s/\bstyle=(["\x27])/style=$1color:#222;background:#fff;/
      or $a = " style=\"color:#222;background:#fff\"$a";
    $a = " xmlns=\"http://www.w3.org/2000/svg\"$a" unless $a =~ /\bxmlns=/;
    $a = " xmlns:xlink=\"http://www.w3.org/1999/xlink\"$a"
      if $_ =~ /\bxlink:/ && $a !~ /\bxmlns:xlink=/;
    "<svg$a>"
  }e' > "$check"

if command -v qlmanage >/dev/null 2>&1; then
  qlmanage -t -s 1400 -o "$out_dir" "$check" >"$log" 2>&1 || true
  [ -s "$check.png" ] || { echo "render-check: qlmanage wrote no PNG (see $log)" >&2; exit 4; }
  mv "$check.png" "$png"
  echo "$png"
  exit 0
fi

pw=${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}
chrome=$(
  { ls -d "$pw"/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell \
          "$pw"/chromium-*/chrome-linux64/chrome 2>/dev/null || true; } \
    | sort -V | tail -1
)
if [ -z "$chrome" ]; then
  cat >&2 <<'EOF'
render-check: no renderer found. Install Playwright's headless Chromium once:
  npx -y playwright@1.56.1 install chromium-headless-shell
EOF
  exit 3
fi

# The root <svg> fills the window, so a viewBox-only diagram scales to fit
# instead of overflowing it.
{
  printf '%s\n' '<!doctype html><meta charset="utf-8">' \
    '<style>html,body{margin:0;background:#fff;color:#222}body>svg{display:block;width:100vw;height:100vh}</style>'
  printf '%s\n' "$body"
} > "$html"

rc=0
"$chrome" --headless --no-sandbox --disable-gpu --hide-scrollbars \
  --window-size=1400,1000 --screenshot="$png" "file://$html" >"$log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "render-check: renderer failed (exit $rc): $chrome" >&2
  tail -n 5 "$log" >&2 || true
  exit 4
fi
[ -s "$png" ] || { echo "render-check: $chrome wrote no PNG (see $log)" >&2; exit 4; }
echo "$png"
