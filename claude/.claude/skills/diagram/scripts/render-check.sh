#!/usr/bin/env bash
# render-check.sh — render an SVG to a PNG so the agent can look at it before
# showing it (the /diagram skill's "check against a render" step).
#
# Usage: render-check.sh <in.svg> [out-dir]
#   Prints the PNG's path. out-dir defaults to $TMPDIR, else /tmp.
#
# The copy gets a fixed text colour and a white background, because a page
# diagram draws with currentColor and would otherwise render black-on-clear.
#
# Renderers, first found wins:
#   macOS  qlmanage (Quick Look, built in)
#   Linux  Playwright's chrome-headless-shell, then its full chromium, from
#          ~/.cache/ms-playwright (newest version). Not the snap chromium:
#          a snap has its own /tmp and can't read hidden dirs, so it can't
#          open a scratchpad file.
# --no-sandbox is needed where AppArmor blocks Chromium's user-namespace
# sandbox (Ubuntu 23.10+). It's safe here: the page is a local SVG we wrote,
# rendered with no network.
set -euo pipefail

in=${1:?usage: render-check.sh <in.svg> [out-dir]}
out_dir=${2:-${TMPDIR:-/tmp}}
[ -f "$in" ] || { echo "render-check: no such file: $in" >&2; exit 2; }
mkdir -p "$out_dir"
out_dir=$(cd "$out_dir" && pwd)

base=$(basename "${in%.svg}")
check="$out_dir/$base.check.svg"
png="$out_dir/$base.check.png"
sed 's/<svg /<svg style="color:#222;background:#fff" /' "$in" > "$check"

if command -v qlmanage >/dev/null 2>&1; then
  qlmanage -t -s 1400 -o "$out_dir" "$check" >/dev/null 2>&1
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

"$chrome" --headless --no-sandbox --disable-gpu --hide-scrollbars \
  --window-size=1400,1000 --screenshot="$png" "file://$check" >/dev/null 2>&1
[ -s "$png" ] || { echo "render-check: $chrome wrote no PNG" >&2; exit 4; }
echo "$png"
