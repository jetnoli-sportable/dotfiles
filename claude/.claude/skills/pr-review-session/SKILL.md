---
name: pr-review-session
description: >
  Check GitHub for open PRs in watched repos, pull each PR down as a git
  worktree, spin up a per-PR tmux window, write a PR brief, and run a
  ce-code-review on each. Use when the user says "check my PRs", "review open
  PRs", "set up PR review sessions", "babysit my PRs", "/pr-review-session", or
  wants this run on a loop or scheduled (e.g. 8pm and 10am). Creates a "PR
  session" in tmux you can walk into to get the gist of each PR plus anything
  critical.
---

# PR Review Session

Turns the open PRs across your watched repos into a browsable **tmux session**:
one window per PR, each sitting in a real git worktree of that PR's branch, with
a `PR-BRIEF.md` that summarizes what changed and (after review) what's critical.

The deterministic plumbing is **`~/.claude/skills/pr-review-session/driver.py`**
(stdlib Python, no deps) — it queries GitHub, diffs against last-run state,
creates worktrees + tmux windows, and pre-fills each brief from PR metadata.
**You (the agent)** run `ce-code-review` per PR, write the brief narrative +
critical findings, and mark each PR done. Run this whole flow once per
invocation; loop or schedule it (see **Scheduling**).

All `driver.py` invocation shapes below were run and verified live.

## Setup (one-time)

Create the config listing which repos to watch:

```bash
mkdir -p ~/.config/pr-review-session
cp ~/.claude/skills/pr-review-session/config.example.json ~/.config/pr-review-session/config.json
# then edit ~/.config/pr-review-session/config.json — set the repos array
```

Config keys: `repos` (array of local repo paths — `~` ok), `tmux_session`
(default `pr-review`), `limit` (max PRs/repo, default 30), `include_drafts`
(default false), `worktree_dir` (default `.worktrees`).

`gh` vs personal token is **auto-detected per repo** from the origin owner:
`sportabletech` repos use the default `gh` login; everything else (personal
`jetnoli-sportable` repos, other owners) uses the personal PAT from the keyring
(`secret-tool lookup service gh account personal`) — the same thing `pgh` does.
No per-repo config needed.

## Run (agent path)

This is the loop you execute each invocation:

**1. Scan** — find PRs needing attention (new, or new commits since last review).
No side effects:

```bash
python3 ~/.claude/skills/pr-review-session/driver.py plan
```

Output is JSON: `{ session, prs:[…], pending:[…] }`. Each PR has `repo`, `pr`,
`title`, `branch`, `base`, `author`, `url`, `reviewed`, `needs_attention`.
Work the `pending` list.

**2. Prepare** — for each pending PR, create its worktree + tmux window +
scaffolded brief (idempotent — safe to re-run):

```bash
python3 ~/.claude/skills/pr-review-session/driver.py prepare <repo> <pr-number>
```

(Repo arg accepts the repo's basename or full path.) Prints JSON with
`worktree`, `brief`, `tmux_window`, `tmux_target`, and a ready-made
`review_cmd`. The tmux window opens in the worktree and displays the brief.

**3. Review** — run a headless code review against the PR, from inside its
worktree. Use the `ce-code-review` skill in headless mode:

```
/ce-code-review mode:headless https://github.com/<owner>/<repo>/pull/<pr-number>
```

(Or invoke the `ce-code-review` skill via the Skill tool with the same args.)
`mode:headless` is the programmatic path — it returns a structured report
instead of an interactive session.

**4. Write the brief** — edit `PR-BRIEF.md` in the worktree (path from step 2).
The driver pre-filled metadata, body, commits, and files. You fill the two
trailing sections:
- `## ⚠️ Critical findings` — lead with anything that should block merge or that
  the reviewer must look at first; pull from the ce-code-review report. If
  clean, say so.
- `## Review summary` — 3-6 plain-language bullets: what changed, why it
  matters, the review verdict.

**5. Complete** — record that this PR was reviewed at its current head sha, so
the next `plan` won't re-flag it unless new commits land:

```bash
python3 ~/.claude/skills/pr-review-session/driver.py complete <repo> <pr-number>
```

After the loop, tell the user the tmux session name and which windows hold which
PRs. They run `tmux attach -t pr-review` (or your configured session) and switch
windows to walk each PR.

### Inspect state any time

```bash
python3 ~/.claude/skills/pr-review-session/driver.py status
```

Shows config/state paths, each repo's resolved token (`[gh]`/`[pgh]`), whether
the tmux session is live, and its windows.

## Scheduling / looping

- **On a loop (foreground, user-driven):** use the `/loop` skill —
  `/loop /pr-review-session` (omit interval to self-pace, or `/loop 30m …`).
- **At fixed times (8pm + 10am):** use the `/schedule` skill to create two
  routines that invoke this skill. Schedule wants cron; `0 22 * * *` (10pm) etc.
  For 8pm and 10am daily that's `0 20 * * *` and `0 10 * * *`. Tell `/schedule`
  to run `/pr-review-session` headless. Note: scheduled/cloud runs may not have
  your local repos or keyring — prefer a local loop for the worktree+tmux parts,
  and schedule only if running on this machine.

## Gotchas (battle scars from building this)

- **`base-index 1`.** Your tmux config sets `base-index 1`, so a new session's
  first window is index **1**, not 0. The driver names the first window at
  creation time with `tmux new-session -n <name>` to sidestep this — never
  `rename-window -t session:0` (targets a window that doesn't exist → window
  stays named `zsh`).
- **Fine-grained PAT can't read `statusCheckRollup`.** `gh pr view --json
  statusCheckRollup` fails on the Sportable fine-grained token with
  `Resource not accessible by personal access token`. The driver drops it from
  the main view and fetches checks separately via `gh pr checks` (best-effort);
  if that also lacks access, the brief says `checks unavailable` rather than
  crashing.
- **PR head, not a fresh branch.** Unlike `ce-worktree` (which branches from
  base), this fetches `pull/<n>/head` into a local `pr-review/<n>` branch and
  attaches the worktree there — you review the PR author's actual commits.
- **`pgh` is a shell function, not a binary.** It can't be exec'd from Python.
  The driver replicates it: detect owner → if non-Sportable, set
  `GH_TOKEN=$(secret-tool lookup service gh account personal)` when calling `gh`.
- **State is keyed by `<repo-basename>#<pr>`** in `~/.local/state/pr-review-session/state.json`.
  Delete that file to force re-review of everything.

## Troubleshooting

- `error: no config at …` → run the Setup step.
- `command failed … Resource not accessible by personal access token` on a
  field other than checks → that field isn't readable by the fine-grained token;
  remove it from `PR_VIEW_FIELDS` in `driver.py`.
- tmux window named `zsh` instead of `repo#pr` → you're on an old driver;
  the `-n` fix in `new-session` is required (see Gotchas).
- Worktree already exists / dirty → `git -C <repo> worktree remove --force
  .worktrees/pr-<n>` then re-run `prepare`.

## Files

- `driver.py` — the harness (plan / prepare / complete / status).
- `config.example.json` — copy to `~/.config/pr-review-session/config.json`.
