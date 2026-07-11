---
title: Residual review findings — feat/queue-command
status: current
tile: Two non-blocking findings from the queue-command ce-code-review pass, accepted rather than fixed.
group: personal-workflow
kind: doc
updated: 2026-07-11
---

## Overview

`ce-code-review` (9-persona pass, `docs/plans/2026-07-11-003-feat-queue-command-plan.md`) surfaced two residuals that were accepted rather than fixed in `feat/queue-command`. Everything else at P0-P2 with a concrete code fix was applied — see commit `c934c4f` (`fix(review): close stash race, guard cmd_new failure, add test coverage`).

## 1. Manual smoke-testing gotcha: `tmux.wb` resolves via stow symlink to the main checkout, not the worktree under test

**Finding (adversarial reviewer, P2, confidence 100):** `nvim/.config/nvim/lua/claude-tmux/config.lua`'s default `tmux.wb = vim.fn.expand("~/.config/scripts/tmux/wb.sh")` is a hardcoded absolute path. On a real dev machine, `~/.config/scripts/tmux/wb.sh` is a GNU Stow symlink that always resolves to the **main dotfiles checkout**, never to a feature-branch worktree — confirmed live: `readlink -f ~/.config/scripts/tmux/wb.sh` pointed at the `development`-branch checkout, which (until this PR merges) has no `wb_ensure_repo_ignore` function at all.

**Why it's not a code fix:** changing `config.lua`'s default to a worktree-relative path would be wrong for real deployed usage — after this PR merges, the default *must* keep pointing at the deployed `~/.config/scripts/tmux/wb.sh`, which is exactly where stow puts the (now-updated) main checkout's copy. The bug isn't in the code; it's an inherent property of testing a `wb.sh`-touching nvim feature from inside a worktree while still on the branch, before merge.

**What actually happened:** I hit this myself during Phase 2 manual verification — an early headless-nvim smoke test of `queue.lua`'s lazy stash reported "could not register ignore rule (unknown error)" and `git status` showed `??` instead of `!!`. Root-caused to the symlink, then worked around it in each subsequent manual-test script by passing an explicit override: `require("claude-tmux").setup({ tmux = { wb = "<worktree>/scripts/.config/scripts/tmux/wb.sh" } })`.

**Follow-up idea (not built, scoped out by the plan itself):** the existing `scripts/.config/scripts/tmux/tests/Dockerfile` sandboxes the *bash* test suite, but it has no nvim installed and never touches `~/.config/scripts/tmux/` — the bash tests source `wb.sh` by a path relative to the test file itself, so they were never exposed to this symlink ambiguity in the first place. A sibling Docker image with nvim installed, whose Dockerfile symlinks the container's `~/.config/scripts/tmux/wb.sh` to the mounted `/repo`'s own copy (deterministic per-run, since the container has no host stow state), would let a Lua/nvim smoke test run inside a container that's always testing the checked-out worktree rather than whatever the host's real stow symlinks happen to point at. This is the same automated Lua-test-harness investment the plan's own Scope Boundaries section already flagged as "genuinely valuable but a standalone investment benefiting the whole `claude-tmux` plugin, not just this feature" — not something to fold into this PR's diff.

## 2. `queue.lua`'s picker silently misattributes content on a malformed queue file

**Finding (adversarial reviewer, P3, confidence 75):** `parse_entries` (`nvim/.config/nvim/lua/claude-tmux/queue.lua`) splits the queue file into entries strictly on the `^## %d%d%d%d%-%d%d%-%d%dT` heading pattern. If a user manually hand-edits `.claude-queue.md` and deletes a heading line (or the file is otherwise malformed), the content between the missing heading and the next one silently gets folded into the *previous* entry rather than flagged as an error.

**Why it's accepted, not fixed:** this requires a user to manually edit a scratch file the feature itself never asks them to touch by hand — a narrow, self-inflicted edge case, not a normal-usage path. P3 per the review's own severity scale ("low-impact, narrow scope, minor improvement — user's discretion").

## Disposition

Both accepted as-is. No further code changes planned for this PR. Revisit item 1 if/when the deferred Lua-test-harness follow-up gets picked up.
