---
name: haircut
description: Use when the user types `/haircut`, or says "comment sweep", "trim the comments", "clean up comments before review". Also run it unasked after implementation and any simplification pass, before any code review starts — ce-work's shipping step, a `/wb-resume` run directive that starts a review, or a review asked for by hand.
---

# haircut

Code reviewers read every comment a branch adds. Most of them restate the
code or narrate the change. `/haircut` removes those, keeps the ones that
carry intent, and flags code that is only understandable with its comment.
It is a comment-only sweep. It never edits code, so it is safe to run
unasked.

## Scope

- **Only comment lines the branch added or changed.** Comments that predate
  the branch are never touched, even on a line next to a changed one.
- **Resolve the default branch, never hard-code it.** `origin/HEAD` is set
  by `git clone` but not by `git remote add`, so fall back to asking the
  remote:

  ```bash
  base=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)
  if [ -z "$base" ]; then
    def=$(git ls-remote --symref origin HEAD 2>/dev/null \
      | awk '$1 == "ref:" { sub("^refs/heads/", "", $2); print $2; exit }')
    [ -n "$def" ] && base="origin/$def"
  fi
  mb=$(git merge-base "$base" HEAD)
  ```

  If `base` is still empty, stop: `haircut: cannot resolve the default
  branch (no origin/HEAD, and ls-remote gave nothing)`. Never fall back to a
  guessed `main`.
- **A branch stacked on a blocker's branch** starts from that branch, not
  from the default, so the default merge base would also sweep the
  blocker's commits. In a wb session (step 6 shows how to find the task
  file), for each stem in the task file's `depends_on:`, read the blocker's
  `branch:` from `~/code/tasks/<stem>.md`. Where that branch exists (as
  `origin/<branch>` or locally), take `git merge-base <branch> HEAD`. Use
  whichever candidate is newest (a later one has the earlier one as an
  ancestor: `git merge-base --is-ancestor "$mb" "$cand"`). A blocker that
  has already merged into the default gives no newer candidate, so the
  default merge base stands. Name the base you used in the report.
- **Committed work:** `git diff "$mb" HEAD`. **Uncommitted work:**
  `git diff HEAD`. Take the `+` lines that are comments from both.
- **Skip these files:** `*.md` and other prose (skill text is writing, not
  code comments), generated files, vendored dirs, lock files
  (`package-lock.json`, `go.sum`).
- **Never edits code.** If a comment can only go by changing code, flag it.

## Rules

Each added or changed comment gets one of three outcomes.

### Remove

| What | Example |
|------|---------|
| Restates code that reads clearly | `# increment the counter` above `count += 1` |
| Narrates the change | `# now uses the new helper` |
| Refers to the session, plan or task | `# per the plan, U3` or `# see SW-1234` |
| Commented-out code | `# old_call(x)` |
| Link to anything but reference documentation | a PR link, a Jira link, a chat link |

### Keep

| What | Example |
|------|---------|
| Why or intent | `# retry because the API returns 503 during deploys` |
| Workaround with its cause | `# sleep: tmux drops keys sent before the pane is ready` |
| Invariant | `# caller holds the lock` |
| Link to reference documentation | `# see https://www.rfc-editor.org/rfc/rfc9110` |
| License header | `# SPDX-License-Identifier: MIT` |
| A comment a tool reads | see below |

**Comments a tool reads** (never remove, never reword):

- docgen's index takes the `#` block directly above a tmux keybind, a zsh
  alias or a zsh function (except functions named `_…` or `zvm_…`) as its
  one-liner (`commentAbove` in `~/code/docgen/index.go`; the block ends at a
  blank line, and `##` or `#!` lines are not read):

  ```tmux
  # Open the task picker
  bind t run-shell "wb pick"
  ```

- docgen takes a `.sh` script's first comment line after the shebang as its
  one-liner (`parseScripts`):

  ```bash
  #!/usr/bin/env bash
  # Pick a wb task and attach to its session.
  ```

- A script's help text, when the script prints its own comments for
  `--help`. Look for a `sed` or `grep` on `"$0"`; the lines it prints are
  output, not comments:

  ```bash
  -h|--help) sed -n '/^# Usage:/,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//' ;;
  ```

- Directives: `# shellcheck disable=SC2086`, `// eslint-disable-next-line`,
  `//go:build linux`, `# type: ignore`.
- Doc comments on exported symbols: `// Run starts the server.` above
  `func Run()`.

### Flag

A comment that explains what code does, where the code does not read
clearly without it, stays. The code is reported as a rework or
simplification candidate:

```python
# match YYYY-MM-DD or YYYY/MM/DD
DATE = re.compile(r"(\d{4})[-/](\d{2})[-/](\d{2})")   # flag: dense regex
```

The test is the code alone. If a reader would get it without the comment,
remove. If not, keep the comment and flag the code. When unsure, keep and
flag.

### Not comments

- `#` lines inside a heredoc or a string are data, not comments. Leave them:

  ```bash
  cat <<'EOF'
  # this line is file content
  EOF
  ```

- A shebang (`#!/usr/bin/env bash`) and an encoding line
  (`# -*- coding: utf-8 -*-`) stay.

## What to do

### 1. Collect

Run the commands in Scope. List each added or changed comment line with its
file and line number. If there are none, say "nothing to trim", make no
commit, and stop.

### 2. Decide

Give each comment one outcome: remove, keep, or flag. Apply the Rules in
order: not a comment, tool-read, keep list, remove list, flag. Keep comes
before remove, so a comment that carries intent, a workaround's cause or an
invariant is kept whole even when it also cites a ticket or a link. Keep
it, and list the reference under Flagged in the report so a person can
decide whether it still belongs there:

```bash
# retry: the API returns 503 during deploys (SW-1234)   <- kept; SW-1234 flagged
# TODO(SW-1234): drop this shim after the migration      <- kept; SW-1234 flagged
# see SW-1234                                            <- removed: nothing but a reference
```

### 3. Edit

Delete the removed comment lines. When the comment is trailing on a code
line, delete only the comment and its leading whitespace. Change nothing
else: not the code, not blank lines around it, not comments that predate the
branch.

### 4. Commit only the sweep's hunks

The commit holds the haircut's own edits and nothing else. The tree may hold
uncommitted code edits, including in a file the sweep touched. Those stay
uncommitted and unstaged.

- A file with no other uncommitted changes: `git add <file>`.
- A file that also holds uncommitted code edits: build a patch of only the
  sweep's hunks (`git diff -U0 -- <file>`, cut down to those hunks) and apply
  it to the index with `git apply --cached --unidiff-zero comment-only.patch`.
- A removed comment that was itself uncommitted leaves no hunk against
  `HEAD`; it just disappears from the uncommitted work.
- Check with `git diff --cached --word-diff`: every change is a removed
  comment, either a deleted comment line or a code line whose only
  difference is a dropped trailing comment. Anything else (including changes
  that were already staged before the sweep) means stop and report; do not
  commit.
- **Pre-commit hooks can add files after that check.** In a repo whose hook
  stages its own output (this dotfiles repo's docgen hook regenerates
  `docs/` from the working tree and runs `git add docs/` when a staged file
  is one it reads), stop before committing if `git status --porcelain --
  docs/` shows anything, or if a file the hook reads holds other
  uncommitted edits. The hook would put them in the haircut commit.
- Then plain `git commit`. Not `git commit -- <file>`: a pathspec commits the
  whole working file, uncommitted code included. Never `--no-verify`.
- After the commit, check it: `git show --name-only --format= HEAD` lists
  only the swept files, plus `docs/` regenerated from those edits. If it
  lists anything else, report it. Do not amend.
- If a hunk cannot be separated from an uncommitted code edit, stop. Do not
  commit that file. Name it in the report.
- **Never use `git stash`.** The stash stack is shared with every other
  session and worktree.
- Commit message: `chore: trim comments (haircut)`, with the attribution
  lines the session requires.

### 5. Report

Short, grouped by outcome, each with `file:line`:

```
Haircut: 3 removed, 3 kept, 2 flagged (base: origin/development)
Removed: scripts/a.sh:12 (restates), scripts/a.sh:30 (task ref), lib/b.py:8 (commented-out code)
Kept:    lib/b.py:21 (why), tmux/keys.conf:4 (docgen reads it), lib/d.py:40 (workaround)
Flagged: lib/c.py:15 (dense regex, needs its comment; rework candidate),
         lib/d.py:40 (cites SW-1234; check the reference still belongs)
```

### 6. Follow-ups in a wb session

Find the task file the way `/wb-save` does:

```bash
tmux show -t "=$(tmux display-message -p '#S'):" -v @task
```

If it is empty, this is not a wb session: report only. Otherwise run one
append per flagged spot:

```bash
wb append <task> Follow-ups - "lib/c.py:15: dense date regex needs its comment; consider a named helper"
```

## Test scenarios

1. A branch adds `# increment the counter` above `count += 1`: removed.
2. A branch adds `# retry because the API returns 503 during deploys` above
   a retry loop: kept.
3. A branch adds `# see SW-1234` or a PR link: removed.
   `# see https://www.rfc-editor.org/rfc/rfc9110` is kept.
4. A branch adds a tmux keybind with a comment above it under `tmux/`: kept
   (docgen reads it).
5. A dense regex carries `# match YYYY-MM-DD or YYYY/MM/DD`: the comment
   stays and the line is flagged as a rework candidate; in a wb session a
   `Follow-ups` entry is appended.
6. A comment that predates the branch, on a line the branch did not touch:
   untouched.
7. A `#` line inside a heredoc: untouched.
8. No comments in the diff: reports "nothing to trim", no commit.
9. Dirty tree with an uncommitted code edit in a file whose branch comment is
   trimmed: the haircut commit holds only the comment change, and the code
   edit is still uncommitted and unstaged afterwards.
10. A hunk that mixes a trimmed comment with an uncommitted code edit and
    cannot be split: stop, name the file, commit nothing for it.
11. A branch adds `# retry: the API returns 503 during deploys (SW-1234)`:
    kept whole, SW-1234 listed under Flagged. `# TODO(SW-1234): drop this
    shim after the migration` is kept the same way; a bare `# see SW-1234`
    is removed.
12. A branch adds a zsh function with a comment above it in `zsh/.zshrc`:
    kept (docgen reads it). A function named `_helper` gets no such
    protection.
13. A script's `# Usage:` block that its `--help` prints with `sed` on
    `"$0"`: kept.
14. A trailing comment removed from a committed code line: the staged
    change is that line without its comment, the check passes, and the code
    is unchanged.
15. A repo with no `origin/HEAD` (e.g. one set up with `git remote add`):
    the base comes from `git ls-remote --symref origin HEAD`. If that is
    also empty, stop with the cannot-resolve message.
16. A wb task whose `depends_on:` blocker branch is not merged yet: the
    sweep covers only this task's own commits, and the report names the
    blocker branch as the base.
17. A trimmed comment in a docgen input (e.g. a `.sh` under
    `scripts/.config/scripts/`) while `docs/` holds an uncommitted edit:
    stop before committing and name `docs/`. With `docs/` clean, the commit
    holds the swept file plus the regenerated `docs/`, and the
    post-commit check passes.

## Notes

- The rules live here only. `CLAUDE.md` and any later hook point at this
  skill and do not restate them, so they drift in one place.
- Prose files are out of scope on purpose: `.md` and skill text are writing,
  not code comments.
- This skill does not rewrite code to make it self-describing. It flags the
  code and leaves the rework to a person.
