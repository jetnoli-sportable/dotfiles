#!/usr/bin/env bash
# artifact-summary.test.sh — checks resolve-source.py's source choice against a
# fixture dossier store, and html-text.py's output on server-rendered,
# Markdown-in-script and JSON-spec pages.
#
# Run: ./artifact-summary.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
FAKE_HOME="$WORK/home"
DOSSIERS="$FAKE_HOME/code/tasks/dossiers"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# resolve-source.py finds the store under $HOME
resolve() { HOME="$FAKE_HOME" python3 "$SCRIPT_DIR/resolve-source.py" "$1"; }
field() { python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"; }

expect() { # expect <label> <json> <field> <want>
  local got
  got="$(printf '%s' "$2" | field "$3")"
  if [ "$got" = "$4" ]; then pass "$1"; else fail "$1: $3 = '$got', want '$4'"; fi
}

# --- fixture store -----------------------------------------------------------
mkdir -p "$DOSSIERS/fam/sub" "$DOSSIERS/broken"
for page in plan ladder solo; do echo "<h1>$page</h1>" > "$DOSSIERS/fam/$page.html"; done
echo "# plan" > "$DOSSIERS/fam/plan.md"
echo "# ladder" > "$DOSSIERS/fam/ladder.md"
echo "not = [valid" > "$DOSSIERS/broken/INDEX.toml"
cat > "$DOSSIERS/fam/INDEX.toml" <<'EOF'
[[doc]]
title = "Plan"
file = "fam/plan.html"
url = "https://claude.ai/artifact/PLANID"
job = "the plan of record"
source = "tools/md2html.py"

[[doc]]
title = "Ladder"
file = "fam/ladder.html"
url = "https://claude.ai/code/artifact/LADDERID"
source = "tools/ladder_md2html.py"

[[doc]]
title = "Folder"
file = "fam/sub/"
url = "https://claude.ai/artifact/DIRID"

[[doc]]
title = "Gone"
file = "fam/missing.html"
url = "https://claude.ai/artifact/GONEID"
EOF

# --- resolve-source.py -------------------------------------------------------
out="$(resolve 'see https://claude.ai/artifact/PLANID please')"
expect "listed link, plain md2html: via" "$out" via dossier
expect "listed link, plain md2html: reads the .md" "$out" read "$DOSSIERS/fam/plan.md"

out="$(resolve https://claude.ai/code/artifact/LADDERID)"
expect "listed link, own generator: reads the .html" "$out" read "$DOSSIERS/fam/ladder.html"

out="$(resolve https://claude.ai/artifact/UNLISTED)"
expect "unlisted link falls back to the Artifact read" "$out" via artifact

out="$(resolve https://claude.ai/artifact/GONEID)"
expect "listed link whose file is missing falls back" "$out" via artifact

out="$(resolve "$DOSSIERS/fam/plan.html")"
expect "local .html with a .md beside it: reads the .md" "$out" read "$DOSSIERS/fam/plan.md"

out="$(resolve "$DOSSIERS/fam/solo.html")"
expect "local .html with no .md: reads the .html" "$out" read "$DOSSIERS/fam/solo.html"

out="$(resolve "$WORK/nope.html")"
expect "nonexistent path" "$out" via none

out="$(resolve "$DOSSIERS")"
expect "dossier root (used to crash) is not a page" "$out" via none

out="$(resolve "$DOSSIERS/fam/sub/")"
expect "dossier subdirectory is not a page" "$out" via none

out="$(resolve https://claude.ai/artifact/DIRID)"
expect "listed link whose file is a directory falls back" "$out" via artifact

if printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
   && resolve https://claude.ai/artifact/PLANID >/dev/null 2>"$WORK/err" && [ ! -s "$WORK/err" ]; then
  pass "malformed INDEX.toml is skipped quietly"
else
  fail "malformed INDEX.toml broke the resolver: $(cat "$WORK/err")"
fi

# --- html-text.py ------------------------------------------------------------
cat > "$WORK/server.html" <<'EOF'
<!doctype html><html><head><title>T</title><style>h2{color:red}</style>
<script>var noise = "## not a heading";</script></head>
<body><h1>Main title</h1><p>Intro   text.</p>
<h2>Section</h2><ul><li>first</li><li>second</li></ul>
<table><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table>
<svg><text>chart label</text></svg><figure><figcaption>Fig caption</figcaption></figure>
</body></html>
EOF
txt="$(python3 "$SCRIPT_DIR/html-text.py" "$WORK/server.html" 2>"$WORK/err")"
grep -qx '# Main title' <<<"$txt" && pass "h1 becomes '# '" || fail "h1 heading missing"
grep -qx '## Section' <<<"$txt" && pass "h2 becomes '## '" || fail "h2 heading missing"
grep -qx -- '- first' <<<"$txt" && pass "li becomes '- '" || fail "list item missing"
grep -q '| a | b |' <<<"$txt" && pass "tr becomes a | row" || fail "table row missing"
grep -q 'Fig caption' <<<"$txt" && pass "figcaption kept" || fail "figcaption dropped"
if grep -q -e 'not a heading' -e 'color:red' -e 'chart label' <<<"$txt"; then
  fail "script, style or svg text leaked"
else
  pass "script, style and svg dropped"
fi
[ ! -s "$WORK/err" ] && pass "server-rendered page: no warning" || fail "unexpected warning: $(cat "$WORK/err")"

cat > "$WORK/template.html" <<'EOF'
<!doctype html><html><head><title>Lanes</title></head><body>
<nav id="toc"><span>On this page</span></nav><main id="content"><pre id="src-fallback"></pre></main>
<script type="text/markdown" id="src">
# Lanes

Intro with **bold**.

## Decisions

```sh
    indented code
```
</script>
<script>var md = document.getElementById('src').textContent;</script>
</body></html>
EOF
txt="$(python3 "$SCRIPT_DIR/html-text.py" "$WORK/template.html" 2>"$WORK/err")"
grep -qx '## Decisions' <<<"$txt" && pass "text/markdown body is printed" || fail "text/markdown body missing"
grep -qx '    indented code' <<<"$txt" && pass "Markdown indentation kept" || fail "Markdown indentation lost"
grep -q 'getElementById' <<<"$txt" && fail "renderer script leaked" || pass "renderer script dropped"
[ ! -s "$WORK/err" ] && pass "Markdown-in-script page: no warning" || fail "unexpected warning: $(cat "$WORK/err")"

printf '%s' '<html><body><script type="application/json" id="src">"# From JSON\n\nbody"</script></body></html>' > "$WORK/json-src.html"
txt="$(python3 "$SCRIPT_DIR/html-text.py" "$WORK/json-src.html" 2>/dev/null)"
grep -qx '# From JSON' <<<"$txt" && pass "JSON-string source is printed" || fail "JSON-string source missing"

{
  printf '%s' '<html><head><title>Decisions</title></head><body><h1></h1>'
  printf '<script id="spec" type="application/json">{"title":"Decisions","items":[%s]}</script>' \
    "$(python3 -c 'print(",".join(["{\"title\":\"x\",\"question\":\"%s\"}" % ("q" * 400)] * 20))')"
  printf '%s' '</body></html>'
} > "$WORK/spec.html"
python3 "$SCRIPT_DIR/html-text.py" "$WORK/spec.html" >/dev/null 2>"$WORK/err"
grep -q 'warning:.*JSON <script>' "$WORK/err" && pass "JSON-spec page warns on stderr" || fail "no warning for JSON-spec page"

if [ "$FAIL" -eq 0 ]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "SOME TESTS FAILED"
  exit 1
fi
