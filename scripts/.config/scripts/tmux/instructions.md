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

### The five statuses

The whole point of the redesign: separate an agent that's **blocked on you** from
one that's merely **done and idle**, and — since the glyph alone can't do it on
current Claude Code (see below) — from one that's still **actively working**.

| Status        | Picker         | Means | How detected |
|---------------|----------------|-------|--------------|
| `needs-input` | magenta `◆ needs you` | Blocked: a permission/question modal is up, or it's waiting on a decision-buffer nvim split | `@claude_blocked` marker **or** a modal in the pane content |
| `done`        | cyan `✔ finished` | A long-running turn (≥30s) just finished; awaiting you | `@claude_blocked=done` (Stop hook) |
| `waiting`     | green `○ done` | Turn finished, sitting idle at the `✳` prompt, no active-turn marker | `✳` glyph, no `@claude_working`, no modal |
| `working`     | yellow `● working` | Mid-turn | `@claude_working=1` marker, **or** (fallback, no hook data) a spinner glyph |
| `idle`        | grey `· idle`  | Plain-text title, no spinner | fallthrough |

### How detection works

Claude Code tells tmux part of it through the pane; a Claude Code hook pushes
the rest as ground truth, because the pane alone is no longer enough:

- **Identity:** `#{pane_current_command} == "claude"` marks a Claude pane.
- **Glyph (first pass):** the leading token of `#{pane_title}`:
  - `✳` (U+2733) → idle/ready **or** a modal is up **or** (on current Claude
    Code) an active turn — the glyph alone can no longer tell these apart, see
    the `@claude_working` note below
  - a braille spinner frame (U+2800–U+28FF, e.g. `⠐ ⠂`) → **working** — this
    was the sole busy/idle signal until Claude Code v2.1.241 started showing a
    static `✳` during both busy and idle; kept as a fallback for a pane with
    no hook data (an older Claude Code build, or `claude` launched outside
    this tmux/hooks setup)
  - the text after the glyph is the live task description
- **`@claude_working` marker (ground truth for "working")** — pushed by
  `claude-notify-hook.sh` on the `UserPromptSubmit` hook (`start` case, set to
  `1`) and cleared on the `Stop` hook (`done` case). Wins over a `✳` glyph
  that would otherwise read as idle, unless `@claude_blocked` or a live modal
  (next signal) already claimed the row.
- **`needs-input`/`done` (second pass)**, promotes or relabels the row:
  1. **`@claude_blocked` pane option** — an agent sets this on its own pane
     before it blocks on something invisible-in-the-pane, namely the
     decision-buffer nvim split (that block runs as a background command, so
     the pane shows a *working spinner* — only an explicit marker can catch
     it). Value `needs-input`/`nvim-buffer`/... → blocked; value `done` (set
     by the `Stop` hook only for turns ≥30s) → finished, awaiting you.
     Cleared at the next `UserPromptSubmit`.
  2. **`tmux_pane_awaiting_input()`** — for `✳` panes only, capture the pane
     and check for a live permission / AskUserQuestion modal. Calibrated
     against Claude Code **v2.1.179**: every such modal drops the
     `-- INSERT --` input box and shows an `Esc to cancel` footer (permission
     prompts also say `Do you want to proceed?`); idle/working panes always
     keep `-- INSERT --`. **Not yet reconfirmed against v2.1.241** — the same
     version bump that broke the glyph-only working/idle split; if this modal
     UI drifted too, recalibrate the two greps the same way the
     `@claude_working` marker replaced the glyph for "working" (capture a
     live prompt with `tmux capture-pane -ep -t <target>` and compare).

Enumeration command (the heart of the tool — note the `@claude_blocked` and
`@claude_working` fields):

```sh
tmux list-panes -a -F \
  '#{pane_current_command}|#{session_name}|#{window_index}|#{pane_index}|#{@claude_blocked}|#{@claude_working}|#{pane_title}'
```

**Caveats**
- A window can hold both a `claude` pane and a non-claude pane (e.g. `make`), so
  we filter on `pane_current_command` and target the specific
  `session:window.pane` — you land on the agent, not just the window.
- Status is classified in shell (`case`), **not** mawk — Debian's default `awk`
  isn't UTF-8 aware and would mis-split the multibyte glyphs.
- The glyph mapping **and** the modal-content signatures are observed conventions,
  not a documented API. Both the glyph case and `tmux_pane_awaiting_input()`
  now live in `lib.sh`'s `tmux_claude_panes()` (shared by `claude-sessions.sh`
  and `wb.sh`, not duplicated) — `claude-sessions.sh`'s own `collect_rows()` is
  just a one-line call into it. If a future Claude Code build changes its title
  glyphs again, add/adjust a ground-truth pane marker the way `@claude_working`
  was added, rather than re-deriving from the glyph; if it changes the modal
  UI, recalibrate the two greps in `tmux_pane_awaiting_input()`.
- The content scan runs one `capture-pane` per `✳` claude pane per refresh tick —
  a handful of agents at 2–3s is negligible.
- `window_activity_flag` is unreliable here (monitor-activity is off), so status
  comes solely from the title glyph, the `@claude_working`/`@claude_blocked`
  markers, and the modal content-scan.

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

## wb.sh / tasks-git-hooks/ — see the dedicated guide

`wb.sh`, `handoff.sh`, and `tasks-git-hooks/` are a separate, newer tool
family in this same directory — not documented in this file (see the
`wb-guide` doc for `wb.sh` itself). This section is only a pointer to the
concurrency-safety pieces the 2026-07-11/12 plan added on top of them:

- `wb-locks.sh` — the per-task-file `flock` side-car lock module, sourced
  by `wb.sh` and `handoff.sh`.
- `tasks-git-hooks/` — three scripts: `pretooluse-guard.sh` (Claude Code
  `PreToolUse` "ask" hook), `reference-transaction` (the `core.hooksPath`
  git hook that refuses history-orphaning ref updates), and
  `replay-refusals.sh` (read-only X7 replay tool for the git hook's
  enablement gate).
- New `wb` verbs: `wb sync`, `wb unsafe-rewind`, `wb append`,
  `wb install-hooks`.

Full reference — the three-layer model, coverage matrix, a command traced
through all three layers, kill switches, and runbooks for lock contention,
a refused rewind's aftermath, and install/enablement — lives in
[`docs/guides/tasks-store-guards.md`](../../../../docs/guides/tasks-store-guards.html)
(rendered guide), not here.

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
