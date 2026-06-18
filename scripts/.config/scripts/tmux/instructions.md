# tmux scripts — instructions & reference

A small set of fzf-driven helpers for navigating tmux: jump to repos, open daily
notes, and survey/jump-to running Claude Code agents. All scripts live in
`~/.config/scripts/tmux/` and share one helper library.

## At a glance

| Script               | Alias       | tmux keybind        | What it does |
|----------------------|-------------|---------------------|--------------|
| `session.sh`         | `s`         | `prefix + m`        | Fuzzy-pick a git repo under `~/code`, attach/create its tmux session |
| `notes.sh`           | `N`         | `prefix + N` / `prefix + M` | Open daily/any note in nvim inside a persistent `notes` session |
| `claude-sessions.sh` | `ca` / `cad`| `prefix + a`        | Overview of all Claude Code agents across tmux + jump to one |
| `lib.sh`             | —           | —                   | Shared helpers (sourced by the three scripts above) |

`prefix` is `Ctrl-Space`.

> **After editing aliases:** run `source ~/.zshrc` or open a new shell.
> **After editing `tmux.conf`:** `prefix + r` (or `tmux source-file ~/.config/tmux/tmux.conf`).

---

## claude-sessions.sh — Claude agent overview & jump

The reason this whole thing exists: when several Claude Code agents run at once
(one per tmux window across many sessions), there's no single place to see them
or jump to the one that needs you.

### Usage

```sh
ca            # fzf picker of all Claude agents, enter to jump
ca <query>    # pre-filtered; auto-selects on a single match
cad           # live auto-refreshing dashboard (ctrl-c quits)
# prefix + a  # opens the picker in a new tmux window
```

- **Picker** lists every agent as `<target>  <icon status>  <task>`, **sorted
  needs-input-first**, color-coded. Enter jumps your client straight to that pane.
- **Dashboard** groups agents under `⚑ NEEDS YOUR INPUT` / `DONE — AWAITING YOU` /
  `WORKING` / `IDLE` and redraws every 2s — keep it open in a window while agents run.

### The four statuses

The whole point of the redesign: separate an agent that's **blocked on you** from
one that's merely **done and idle**. Both look identical by title glyph (`✳`), so
the script refines them.

| Status        | Picker         | Means | How detected |
|---------------|----------------|-------|--------------|
| `needs-input` | magenta `◆ needs you` | Blocked: a permission/question modal is up, or it's waiting on a decision-buffer nvim split | `@claude_blocked` marker **or** a modal in the pane content |
| `waiting`     | green `○ done` | Turn finished, sitting idle at the `✳` prompt awaiting your next message | `✳` glyph + no modal |
| `working`     | yellow `● working` | Mid-turn (braille spinner in the title) | spinner glyph |
| `idle`        | grey `· idle`  | Plain-text title, no spinner | fallthrough |

### How detection works

Claude Code already tells tmux most of it through the pane:

- **Identity:** `#{pane_current_command} == "claude"` marks a Claude pane.
- **Glyph (first pass):** the leading token of `#{pane_title}`:
  - `✳` (U+2733) → idle/ready **or** a modal is up (the glyph can't tell them apart)
  - a braille spinner frame (U+2800–U+28FF, e.g. `⠐ ⠂`) → **working**
  - the text after the glyph is the live task description
- **`needs-input` (second pass)**, two signals, either promotes the row:
  1. **`@claude_blocked` pane option** — an agent sets this on its own pane before
     it blocks on something invisible-in-the-pane, namely the decision-buffer nvim
     split (that block runs as a background command, so the pane shows a *working
     spinner* — only an explicit marker can catch it). The value is the reason
     (`nvim-buffer`). Cleared when the block ends.
  2. **`pane_awaiting_input()`** — for `✳` panes only, capture the pane and check
     for a live permission / AskUserQuestion modal. Calibrated against Claude Code
     **v2.1.179**: every such modal drops the `-- INSERT --` input box and shows an
     `Esc to cancel` footer (permission prompts also say `Do you want to proceed?`);
     idle/working panes always keep `-- INSERT --`.

Enumeration command (the heart of the tool — note the `@claude_blocked` field):

```sh
tmux list-panes -a -F \
  '#{pane_current_command}|#{session_name}|#{window_index}|#{pane_index}|#{@claude_blocked}|#{pane_title}'
```

**Caveats**
- A window can hold both a `claude` pane and a non-claude pane (e.g. `make`), so
  we filter on `pane_current_command` and target the specific
  `session:window.pane` — you land on the agent, not just the window.
- Status is classified in shell (`case`), **not** mawk — Debian's default `awk`
  isn't UTF-8 aware and would mis-split the multibyte glyphs.
- The glyph mapping **and** the modal-content signatures are observed conventions,
  not a documented API. If a future Claude Code build changes its title glyphs,
  update the `case` in `collect_rows()`; if it changes the modal UI, recalibrate
  the two greps in `pane_awaiting_input()` (capture a live prompt with
  `tmux capture-pane -ep -t <target>` and compare). Both live in one file.
- The content scan runs one `capture-pane` per `✳` claude pane per refresh tick —
  a handful of agents at 2–3s is negligible.
- `window_activity_flag` is unreliable here (monitor-activity is off), so status
  comes solely from the title glyph + the two `needs-input` signals.

---

## session.sh — repo sessionizer

```sh
s            # fuzzy-pick a repo under ~/code
s <query>    # pre-filter; auto-selects on a single match
# prefix + m # opens the picker in a new tmux window
```

- Lists every git repo under `~/code` plus the `additional_dirs` array
  (`~/code/notes`, `~/code/daemon`), de-duplicated.
- Session name = repo folder basename. Attaches if the session exists, otherwise
  creates it rooted at the repo.
- fzf `--preview` shows `git status -s` + last 5 commits for the highlighted repo.

### Repo discovery detail (why the flags matter)

```sh
fdfind --type d --hidden --no-ignore-vcs \
  --exclude .terraform --exclude node_modules \
  '^\.git$' "$HOME/code" -X dirname
```

- `--no-ignore-vcs` is **required** — `fd` excludes `.git` by default, so without
  it you get zero repos.
- `^\.git$` is anchored on purpose. The old pattern `.git` accidentally matched
  `.github/` dirs (and only worked because `dirname .github` ≈ the repo root),
  silently missing every repo without a `.github` folder.
- `--exclude` drops vendored `.git` dirs (e.g. Terraform modules) that aren't
  session targets.

### TODO (not yet implemented)
If the selected repo contains a `.tmux_session.sh`, source it to lay out panes
(editor + server + logs) instead of opening a bare shell — turning `s <repo>`
into a full project launcher.

---

## notes.sh — daily notes

```sh
N            # fuzzy-pick any note under ~/code/notes
N .          # jump straight to today's daily note
N <query>    # fuzzy-pick, pre-filtered
# prefix + N # picker in a new window   |   prefix + M # today's note
```

- Today's note: `~/code/notes/daily/DD-MM-YYYY.md` (created on demand).
- **One persistent `notes` session.** Each note opens in its own window *named
  after the file* and is reused if already open. This avoids two old bugs:
  - it never `send-keys`-types `nvim ...` into a focused editor, and
  - it doesn't spawn a brand-new tmux session per day.

---

## lib.sh — shared helpers

Sourced by all three scripts; keeps the attach/switch logic and the
fd-binary quirk in one place.

| Function | Purpose |
|----------|---------|
| `FD_BIN` (var) | Resolved `fd`/`fdfind` path. `fd` is only a *zsh alias* (`alias fd=fdfind`), invisible to bash scripts — so we resolve the real binary once. |
| `tmux_ensure_session <name> <dir>` | Create a detached session if absent (exact `=name` match, so `03` never attaches to `03-foo`). |
| `tmux_focus <name>` | Bring a session to the foreground (`switch-client` inside tmux, `attach` outside). |
| `tmux_attach_or_create <name> <dir>` | `ensure` + `focus`. |
| `tmux_find_claude_pane <cwd>` | Print the `session:window.pane` of the Claude pane running in `<cwd>` (first match), or exit 1. Same `pane_current_command == claude` detection as the picker. Useful for a "is there already an agent in this repo?" reverse-jump. |
| `tmux_goto_pane <target>` | Focus a specific `session:window.pane` (switch+select-window+select-pane inside tmux, or `attach \; select-window \; select-pane` outside). |

---

## Wiring

**`~/.zshrc`** (Script Aliases block):
```sh
alias s="~/.config/scripts/tmux/session.sh"
alias N="~/.config/scripts/tmux/notes.sh"
alias ca="~/.config/scripts/tmux/claude-sessions.sh"
alias cad="~/.config/scripts/tmux/claude-sessions.sh dash"
```

**`~/.config/tmux/tmux.conf`**:
```sh
bind m new-window "~/.config/scripts/tmux/session.sh"
bind a new-window "~/.config/scripts/tmux/claude-sessions.sh"
bind N new-window "~/.config/scripts/tmux/notes.sh"
bind M new-window "~/.config/scripts/tmux/notes.sh ."
```

---

## Conventions when editing these scripts

- Every script starts with `set -euo pipefail` and sources `lib.sh` via
  `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`.
- fzf cancellation (Esc) must exit cleanly: `... )" || exit 0` then guard
  `[ -n "$x" ] || exit 0`. No debug `echo`/`ls` left in the run path.
- Use the `=name` exact-match form for `tmux has-session` / targets.
- Reuse `lib.sh` helpers rather than re-inlining attach/switch blocks.

## Verifying changes

```sh
# Syntax-check all scripts
for f in lib.sh claude-sessions.sh session.sh notes.sh; do bash -n "$f" && echo "ok $f"; done

# Exercise the Claude detection without launching the interactive picker:
bash -c 'source ./lib.sh
'"$(sed -n "/^collect_rows()/,/^}/p" claude-sessions.sh)"'
collect_rows | sort -n'

# Confirm a jump target resolves to a claude pane (read-only):
tmux display-message -p -t <session:window.pane> '#{pane_current_command}'

# Confirm repo discovery:
fdfind --type d --hidden --no-ignore-vcs --exclude .terraform --exclude node_modules '^\.git$' "$HOME/code" -X dirname | sort -u
```
