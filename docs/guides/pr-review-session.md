---
title: pr-review-session
status: current
tile: Open PRs → worktrees + tmux windows + briefs + reviews.
group: skills
kind: guide
updated: 2026-07-07
---

## Overview

Turns "go check my PRs" into one browsable tmux session: every open PR in
your watched repos gets a git worktree of its actual head, a tmux window,
and a `PR-BRIEF.md` with a review summary and critical findings up top. The
deterministic plumbing is `driver.py` (stdlib Python); the agent runs a
code review per PR and writes the narrative. Described in the workbench
findings as "the prototype of the end goal" of the whole workbench project.

## Try it now

One-time setup — declare which repos to watch:

```
mkdir -p ~/.config/pr-review-session
cp ~/.claude/skills/pr-review-session/config.example.json \
   ~/.config/pr-review-session/config.json
# edit the repos array
```

Then, in a Claude Code session: **"check my PRs"** (or `/pr-review-session`).
When it finishes, walk the results:

```
tmux attach -t pr-review     # one window per PR, brief on screen
```

## Reference

The agent's loop per invocation (all driver calls are idempotent):

| Step | Command | Does |
|---|---|---|
| Scan | `driver.py plan` | JSON of PRs needing attention (new, or new commits since last review) |
| Prepare | `driver.py prepare <repo> <pr>` | Worktree from `pull/<n>/head` + tmux window + scaffolded brief |
| Review | `ce-code-review` headless | Structured findings for the brief |
| Brief | edit `PR-BRIEF.md` | Critical findings first, then a plain-language summary |
| Complete | `driver.py complete <repo> <pr>` | Records head sha so unchanged PRs aren't re-flagged |

`driver.py status` shows config/state paths, per-repo token resolution
(`[gh]`/`[pgh]`, auto-detected from origin owner), and live tmux windows.
Config keys: `repos`, `tmux_session`, `limit`, `include_drafts`,
`worktree_dir`. State lives in
`~/.local/state/pr-review-session/state.json` — delete it to force
re-review of everything.

## Known rough edges

- The Sportable fine-grained PAT can't read `statusCheckRollup`; checks are
  fetched best-effort and the brief says `checks unavailable` when blocked.
- Worktrees check out the PR author's actual commits (`pull/<n>/head`), not
  a fresh branch from base — don't push from them casually.
- A stale/dirty worktree blocks `prepare`:
  `git -C <repo> worktree remove --force .worktrees/pr-<n>` and re-run.

## Next steps / reverting

- Run it on a cadence: `/loop /pr-review-session` (self-paced) or
  `/schedule` fixed times (e.g. 10:00 and 20:00) — local only; cloud runs
  lack your repos and keyring.
- Tear down any time: kill the `pr-review` session and remove
  `.worktrees/pr-*` worktrees; state and config are two small files. Skill
  source: `claude/.claude/skills/pr-review-session/`.
