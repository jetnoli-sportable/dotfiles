# Overview — the personal workflow

> Originally "Dotfiles overview" — renamed: this covers the whole personal
> workflow, not just this repo (notes-tui and the central task store already
> live in separate repos under `~/code/`).
>
> **Status: work in progress.** This is the manually-maintained precursor to
> the "help dashboard" (see `roadmap.md` §5/§6) — a scanned,
> auto-generated index + Q&A layer that will eventually replace hand-writing
> this file. Until that's built, this is where "what do I have and why" lives.
> See `HUB.md` for the index of all docs in this project.

Companion docs: [`agent-workbench-findings.html`](agent-workbench-findings.html)
(deep dive on the tmux/Claude agent tooling specifically) and
[`roadmap.md`](roadmap.md) (the plan that grew out
of it). This doc is the wider net — everything in the personal workflow, not
just the agent workbench slice, even where the pieces live in other repos.

## Coverage status

| Area | Status |
|---|---|
| Shell & terminal (zsh, ghostty, ohmyposh, git) | **Documented here** — no dedicated docs exist elsewhere |
| tmux workflow tooling (wb, claude-sessions, notes.sh) | **Indexed here, documented in full elsewhere** — see links per item |
| nvim (claude-tmux bridge) | **Indexed here, documented in full elsewhere** — has its own README/instructions.md |
| Claude skills (decision-buffer, park, parked-items, pr-review-session) | **Documented here** |
| TUIs (notes-tui) | **Documented here** — usage from its own README; not yet wired into `wb` (slice 4) |

---

## Shell & terminal

### zsh — `zsh/.zshrc`
Prompt (oh-my-posh), zsh-vi-mode, and the aliases/functions that drive the rest
of this stack.

| Alias/function | What it does |
|---|---|
| `vim` | → `nvim` |
| `fd` | fdfind wrapper (Debian/Ubuntu package name mismatch) |
| `lz` / `ld` | lazygit / lazydocker |
| `s` | repo sessionizer (fallback — `wb` absorbs this on `prefix+m`) |
| `N` | notes picker (`notes.sh`) |
| `ca` | claude-agent picker (fallback — `wb` absorbs this on `prefix+a`) |
| `wb` | the workbench — see the tmux tooling section below |
| `pgh` | `gh` with a personal-account PAT injected, for non-Sportable-org repos (see global CLAUDE.md) |
| `replay` | work tool — daemon replay launcher (`replay-tui`, Sportable stack, not part of this personal workflow) |
| `msconfig` | (see `.zshrc` for current definition — replay/msconfig config helpers) |

### Ghostty — `ghostty/.config/ghostty/config`
Terminal emulator config, kept **alongside** GNOME Terminal rather than
replacing it — Ghostty is used for inline image support GNOME Terminal lacks.
Catppuccin Mocha palette, `MesloLGL Nerd Font`, `minimum-contrast = 1.6`.
Known limitation (see decision record): the grayscale-AA glyph rendering is
softer than GNOME Terminal's and isn't fixable via config — don't re-add
render knobs chasing this, it's been tried.

### oh-my-posh — `ohmyposh/.config/ohmyposh/zen.json`
The prompt theme (`zen` segment set) sourced from `.zshrc`.

### git — `git/.gitconfig`
Minimal: identity (`jetnoli-sportable`), and a `gh auth git-credential` helper
scoped separately for `github.com` and `gist.github.com`. No aliases defined —
if you're looking for a `git` shortcut and it's not in `.zshrc`, it doesn't
exist yet.

---

## tmux workflow tooling — `scripts/.config/scripts/tmux/`

This is the biggest, most actively-developed area. Full inventory and design
history: [`agent-workbench-findings.html`](agent-workbench-findings.html).
Full `wb` usage guide: see the Artifact published during the PR #7 build
(not yet committed to this repo — ask to have it added here if it should be).

| Script | Job | Fuller doc |
|---|---|---|
| `wb.sh` | The workbench: `wb new` (worktree + task + session), `wb` (picker — sessions/agents, presence-only, `Tab`-cyclable modes, `r` rename, `b` break-out-to-own-session), `wb done` (safe wind-down) | `agent-workbench-findings.html`, `roadmap.md` §2 |
| `lib.sh` | Shared helpers: session management, `tmux_claude_panes` (modal-detection, shared by wb + claude-sessions), repo enumeration | `agent-workbench-findings.html` §Inventory |
| `session.sh` | Legacy repo sessionizer (`s` alias) — superseded by `wb` but kept as fallback | `agent-workbench-findings.html` |
| `claude-sessions.sh` | Legacy agent picker/dashboard (`ca`/`cad`) — superseded by `wb`'s agents mode | `agent-workbench-findings.html` |
| `claude-status.sh` | `status-left` segment: live `✳N`/`✔N` count of agents needing you / just finished, server-wide | `agent-workbench-findings.html` §Signal contract |
| `claude-notify-hook.sh` | Push side of the attention pipeline — wired from `~/.claude/settings.json` hooks (`UserPromptSubmit`/`Notification`/`Stop`) | `agent-workbench-findings.html` §Signal contract |
| `notes.sh` | Daily/any note in nvim inside a persistent `notes` session (`N` alias, `prefix+N`/`prefix+M`) — the *current* notes tool; `notes-tui` below is the planned replacement | — |
| `instructions.md` (in this dir) | Predates the notification work — known stale, flagged in the findings doc's gaps section | needs a refresh (tracked gap) |

### Global tmux keybindings (`prefix` = `Ctrl+Space`)

| Binding / alias | Action |
|---|---|
| `prefix`+`m` / `prefix`+`a` | Both open `wb`, the unified picker (as of PR #7). The legacy `s` (repo sessionizer) and `ca`/`cad` (agent picker/dashboard) zsh aliases still work if typed by name, but aren't bound to these keys directly anymore. |
| `prefix`+`j` | Jump to the most-urgent waiting agent, server-wide (needs-input beats done) |
| `prefix`+`J` | 80%×60% popup preview of the most-urgent agent — Enter/j jumps, else closes |
| `prefix`+`N` / `prefix`+`M` | Note picker / today's daily note (`notes.sh`) |
| `prefix`+`g` / `A` | lazygit / lazydocker |
| `Ctrl`+`h`/`j`/`k`/`l` | vim-tmux-navigator pane movement (reserved — a window manager must never bind these) |
| pane-focus-in hook | `set -pu @claude_blocked` — acknowledge-on-arrival |
| status-left | live `✳N`/`✔N` agent-attention count, `#(claude-status.sh)` |

### `wb` picker keybindings

| Key | Does |
|---|---|
| `Tab` | Cycle combined → sessions → agents → combined |
| `j` / `k` | Move down / up |
| `g` / `G` | Jump to top / bottom |
| `l` / `Enter` | Jump to the row's session or agent pane |
| `x` | Send `Esc` to the row's most-urgent agent pane (interrupt), without leaving the picker |
| `r` | Rename the row's tmux session (prompts inline, cosmetic only) |
| `b` | Break the row's agent pane out into a brand new session of its own (prompts for a name) |
| `Ctrl`+`x` | On a task row: the full `wb done` wind-down. On a plain session/agent row: a raw kill. |
| `Ctrl`+`r` | Force a refresh (also auto-refreshes every few seconds) |
| `i` or `/` | Start typing to search; `Esc` back to normal mode |
| `q` / `h` | Close the picker |

---

## nvim — `nvim/.config/nvim/`

Own git repo history, own docs: `nvim/.config/nvim/README.md` and
`instructions.md`. The piece relevant to this project is the `claude-tmux`
bridge (`lua/claude-tmux/`, `<leader>a` — "[A]gent (Claude)") — grab/pick/follow
Claude's transcript into a readable buffer, reply by pasting into the pane.

| Map / cmd | What it does |
|---|---|
| `<leader>ao` · `:ClaudeGrab` | Latest assistant message → read-only markdown buffer (render-markdown styled) |
| `<leader>ap` · `:ClaudePick` | Telescope picker over all assistant messages in the session |
| `<leader>af` · `:ClaudeFollow` | Live-follow: fs-poll (1s) on the transcript, re-render without stealing focus |
| `<leader>ay` · `:ClaudeYankCode` | Yank fenced code blocks out of the rendered output |
| `<leader>ar` / `as` · `:ClaudeReply` / `:ClaudeSend` | Separate reply buffer; send = bracketed paste into the Claude pane + one Enter (empty-draft gated) |
| `<leader>as` (visual) / `ac` | Push selection as fenced, location-tagged context / push current file as `@path` — pasted, not submitted |
| `<leader>aj` · `gf` (in output buffer) | Jump to `file:line` references Claude wrote |

---

## Claude skills (personal) — `~/.claude/skills/`

Not version-controlled today (a known gap — see `roadmap.md` §1
step-zero notes on stowing `~/.claude` config). Four skills exist:

### decision-buffer
**What:** routes design decisions through a markdown doc edited in nvim instead
of an `AskUserQuestion` menu — a tmux split blocking on `wait-for`, checked
boxes + inline notes are the answer.
**Why:** decisions with 2+ non-trivial options are easier to react to in an
editor (strike, edit inline, add notes) than a chat menu, and it leaves a
durable decision record behind.
**Use it:** happens automatically when an agent is about to present a
non-trivial design choice — mention "decision doc" or "open a buffer for this"
to invoke it explicitly. Records land in `logs/decisions/*.md` (or
`docs/decisions/*.md`) per repo.

### park
**What:** `<10` second capture of a "deal with this later" item — one JSON
line appended to a global ledger with cwd + branch for later routing.
**Why:** zero-ceremony deferral so "let's discuss this later" doesn't just
evaporate at the end of a conversation.
**Use it:** `/park <note>`, or just say "park this" / "let's discuss this
later" / "revisit this" in passing. Ledger: `~/.claude/parked-items/ledger.jsonl`.

### parked-items
**What:** the weekly review half of `park` — gathers the ledger plus a
transcript backstop scan, reconciles against the central task store
(`~/code/tasks`), presents a checklist in an nvim buffer to act on
(make a task, drop, keep parked, discuss now).
**Why:** parked items are only useful if something forces you to look at them
again; this is that forcing function.
**Use it:** `/parked-items` (last 7 days) or `/parked-items --backfill` (full
history, run once to establish a baseline).

### pr-review-session
**What:** checks GitHub for open PRs across watched repos, pulls each into a
git worktree, spins up a per-PR tmux window with a PR brief, and runs a code
review on each — described in the findings doc as "the prototype of the end
goal" this whole workbench project generalizes.
**Why:** turns "go check my PRs" into one browsable tmux session instead of N
manual `gh pr checkout` round-trips.
**Use it:** "check my PRs" / "review open PRs" / `/pr-review-session`, can run
on a loop or schedule.

---

## TUIs

### notes-tui — `~/code/notes-tui`
**What:** a capture-dumb, retrieval-smart notes tool over a flat git corpus of
markdown (`~/code/notes`, Denote-style filenames). Sibling to `replay-tui`
(a Sportable *work* tool, out of scope for this doc), built on the shared
`cli-kit` library.
**Why:** the daily-notes flow this personal workflow actually wants — capture
auto-stamped with cwd/git branch/tmux session, periodic digest review, and
(later) mechanical cleanup proposals you approve rather than do by hand.
**Full usage guide:** `~/code/notes-tui/notes-guide.html` — a committed,
comprehensive install/commands/global-flags/conventions/roadmap reference
(commit `48c6d25`). Not linked from notes-tui's own README, easy to miss —
open it directly (`file://` or `xdg-open ~/code/notes-tui/notes-guide.html`).
**Use it today:** `source scripts/note.sh` from shell rc, then capture with:

| Command | What it does |
|---|---|
| `note "thought"` | Zero-decision, sub-second append to `inbox.md`, auto-stamped with cwd, git repo+branch, and tmux session |
| `cmd \| note` | Capture command output the same way |
| `notes digest [hour\|day\|week\|month] [--since 3h] [--from … --to …] [--by date\|context]` | Review notes in the given window. `week` is a rolling 7 days unless `--calendar`. `--by context` groups by cwd/branch/session instead of date. |
| `notes process [--dry-run]` | Mechanical cleanup proposals (rename → Denote scheme, split candidates); proposal-only in v1, apply-path gated behind git review |
| `notes tag [name]` | List tags with counts, or notes carrying a tag |
**Status:** cloned but not yet wired into `wb` — that's slice 4
(`roadmap.md` §4): adding a `--context <tmux-session>` digest
filter and having `wb new`/`wb done` stamp and pull from it automatically.
Until then, `notes.sh` (the nvim-based daily note, above) is what's actually
wired to `prefix+N`/`prefix+M`.

---

## What's still missing from this doc

- A written guide for `wb` itself (usage guide was built as a Claude Artifact
  during the PR #7 session but not committed here — worth doing once slice 5
  gives this project a real docs home).
- `scripts/.config/scripts/tmux/instructions.md` refresh (flagged stale in
  `agent-workbench-findings.html`).
- Anything about the compound-engineering plugin skills (`ce-*`) is
  deliberately out of scope here — those are Sportable-org tooling, not
  personal dotfiles configuration.
