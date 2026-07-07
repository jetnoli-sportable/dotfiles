---
title: replay-tui
status: current
tile: Typed daemon-replay launcher for the Metrics Server — CLI + interactive TUI.
group: tuis
kind: guide
updated: 2026-07-07
---

## Overview

A typed Go launcher for daemon replays (separate repo, `~/code/replay-tui`).
It discovers live sessions from the Metrics Server (`:8888`), stages each
session's embedded pitch/anchors, and launches a single readiness-gated
daemon in tmux — replacing the old bash `replay` script with a typed,
testable core. Phase 1 (CLI) and Phase 2 (interactive Bubble Tea TUI) are
both shipped. Sibling to [notes-tui](notes-tui.html): same personal-repo
stack, but this one's subject matter is Sportable's replay/Metrics Server
tooling rather than personal notes.

## Try it now

```
replay --help
replay list                # discover and list live sessions
replay tui                  # interactive picker (also the default bare `replay`)
```

`replay doctor` validates Metrics Server reachability, daemon builds, and
the embedded pitch before you try to launch anything — worth running first
on a new machine or after switching `--env`.

## Reference

| Command | What it does |
|---|---|
| `replay <name\|id>` | Discover, resolve, stage, and launch a session (default form) |
| `replay --force <s>` | Replace a mid-flight replay without confirming |
| `replay --dry-run <s>` | Validate (resolve, pitch, build) without launching |
| `replay list [--search … --sport … --local]` | List live or downloaded sessions; table on a tty, TSV when piped |
| `replay local <id> --sport … --name …` | Run a downloaded session with metadata |
| `replay goto <pct>` / `pause` / `stop` / `step <n>` | Control the active replay |
| `replay doctor` | Validate MS reachability, daemon builds, embedded pitch |
| `replay tui` | Interactive session picker (fuzzy-filter, `enter` to launch, `r` refresh, `q` quit) |

Config resolves per environment: a matching `REPLAY_*` env var, then the
active env file (`config/<env>.env`, selected by `--env`/`REPLAY_ENV`,
default `dev`) — both embedded in the binary, so it runs with no external
files.

TUI live-progress keys (after launching): `←`/`→` seek ∓1%, `<`/`>` seek
∓10%, `:` then a number jumps to a percentage, `space`/`s` pause/stop, `m`
marks a cue, `1`–`9` jumps to one, `L` loops the last two, `esc` returns to
the picker without stopping the daemon.

## Known rough edges

- **In scope:** live discovery, staging from the embedded pitch (with a
  manual-drop fallback), a single readiness-gated daemon, transport
  controls, env-aware config, the TUI. **Out of scope:** cloud pitch fetch,
  a headless CI gate, multi-daemon A/B, auto-starting the Metrics Server
  itself.
- Session ids outside the discovery window return "not found" — widen with
  `--days`, or it's a cloud session (out of scope, local only).
- A launch that hangs then errors with a pane tail is a readiness timeout —
  the daemon started but its control port never answered; check the
  captured tail and the daemon build.
- Transport commands (`goto`/`pause`/`stop`/`step`) read the running id
  from the tmux daemon window, so one must be launched first.

## Next steps / reverting

- The full manual — install, config precedence, every flag, troubleshooting
  table, and scope — lives in
  [USAGE.md](../../../replay-tui/USAGE.md) or, as an interactive rendered
  version,
  [docs/replay-guide.html](../../../replay-tui/docs/replay-guide.html) in
  the replay-tui repo itself.
- Rebuild after pulling: `cd ~/code/replay-tui && go build -o "$HOME/go/bin/replay" ./cmd/replay`
  (the `replay` alias in `.zshrc` just points at that binary).
- Future ideas live in that repo's `improvements/` dir, not here.
