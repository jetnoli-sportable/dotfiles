---
title: notes-tui
status: current
tile: Capture-dumb, retrieval-smart notes over a flat markdown corpus.
group: tuis
kind: guide
updated: 2026-07-07
---

## Overview

A notes tool (separate repo, `~/code/notes-tui`) over a flat git corpus of
markdown at `~/code/notes` — Denote-style filenames carry identity and tags.
Capture is deliberately dumb (sub-second, zero decisions); retrieval is
where the smarts live (`digest` windows, context grouping, tags). v1 is
AI-free by design; the LLM layer is a later additive phase. This is the
daily-notes flow the personal workflow is converging on — `notes.sh`
(`prefix+N`/`M`) is the current nvim-based tool it will eventually replace.

## Try it now

The capture hot-path is already wired into `.zshrc` (slice 4a):

```
note "redis eviction surprised me"    # appends to inbox.md, auto-stamped
kubectl logs pod-x | note             # capture command output the same way
```

Every entry is stamped with cwd, git repo+branch, and tmux session. Then
review what the week collected:

```
notes digest day
notes digest week --by context        # grouped by repo:branch
```

## Reference

| Command | What it does |
|---|---|
| `note "thought"` / `cmd \| note` | Zero-decision append to `inbox.md`, context-stamped |
| `notes digest [hour\|day\|week\|month]` | Review a window; `week` is rolling 7 days unless `--calendar` |
| `notes digest --since 3h` / `--from … --to …` | Arbitrary windows |
| `notes digest --by context` | Group by repo:branch from the capture stamp |
| `notes process [--dry-run]` | Mechanical cleanup proposals (rename → Denote scheme, split candidates); proposal-only in v1 |
| `notes tag [name]` | Tags with counts, or notes carrying a tag |

Corpus default `~/code/notes` (override `$NOTES_DIR` or `--dir`). The full
committed reference — install, global flags, conventions, roadmap — is
[notes-guide.html](../../../notes-tui/notes-guide.html) in the notes-tui
repo (`xdg-open ~/code/notes-tui/notes-guide.html`).

## Known rough edges

- cwd and tmux session are captured in the stamp but not yet used for
  grouping — `--by context` groups by repo:branch only; session-level
  filtering is the planned slice-4b `--context` flag.
- Not yet wired into `wb`: `wb new`/`wb done` don't stamp or pull digests
  automatically. That's slice 4b (`roadmap.md` §4), gated on this capture
  window's verdict.
- `notes process` proposes only; the apply path lands behind a git review
  gate later.

## Next steps / reverting

- Slice 4b (plan 003) adds the `--context` digest filter and the wb
  integration; a Bubble Tea TUI phase follows on the same core.
- The capture sourcing is one line in `.zshrc`
  (`source ~/code/notes-tui/scripts/note.sh`) — comment it out to unwire;
  the corpus is a plain git repo you keep either way.
