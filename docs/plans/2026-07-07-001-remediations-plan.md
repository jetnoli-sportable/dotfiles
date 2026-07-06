---
type: fix
status: active
origin: 7-persona ce-doc-review + code-delta review over PRs #7/#8 (2026-07-06)
  + decision buffer logs/decisions/2026-07-06-slice-review-decisions.md
---

# Pre-slice remediations — close out the review before slice 5

## Summary

Everything the 2026-07-06 review + decision buffer said must land BEFORE the
next build slice: PR hygiene, the unreviewed `wb.sh` delta fixes, the interim
`wb board` (Decision 5A), the 4a capture-habit setup (Decision 1A), the
Claude-session-id capture (9b amendment), the keeper-sweep credential guard
(§2 amendment), the standing artifact landing-path rule (9d-now), and task
store housekeeping. All units are small and independent unless noted.

## Scope Boundaries (non-goals)

- No slice-5 work (generator, INDEX, guides) — that's plan 002.
- No notes-tui CODE changes — 4a is setup+habit only; code is plan 003 (4b).
- No Decision-4 work (store remote / classification) — explicitly deferred
  by the owner to after the full flow is in place.
- Do not regenerate `roadmap.html` by hand — its drift banner stands until
  the slice-5 generator replaces it.

## Implementation Units

### U1: Retarget PR #8 to development

- **Goal:** PR #8's base still points at the merged `feat/agent-task-workflow`.
- **Approach:** `pgh pr edit 8 --base development` (personal repo → `pgh`,
  never `gh`). Verify the diff on GitHub collapses to only the docs commits.
- **Verification:** `pgh pr view 8 --json baseRefName` returns `development`.

### U2: wb.sh delta fixes (from the post-merge code review)

- **Goal:** fix the five verified defects in the `r`/`b` additions.
- **Files:** `scripts/.config/scripts/tmux/wb.sh` (~lines 717–760, bind
  block ~815–830), `docs/wb-guide.html` (hint wording).
- **Approach:**
  1. `_break_out`: capture identities instead of assuming indices —
     `created="$(tmux new-session -d -P -F '#{session_name}|#{window_id}' -s "$new")"`;
     use the returned session name for break-pane/cleanup targets and
     `kill-window -t "$window_id"` for the scratch window (immune to
     base-index and to tmux's silent `.`/`:`→`_` name rewriting).
  2. `_break_out` + `_rename`: sanitize input first (`wb_sanitize`, extended
     to map `:` as well) or reject names matching `[:.]` — never pass raw
     user input to a cleanup `kill-session` (the colon case can kill an
     UNRELATED session).
  3. Error visibility: drop `2>/dev/null` from `rename-session`; on any
     error path in `_rename`/`_break_out`, `read -rn1 -p "...press any key"`
     so the message survives the fzf repaint.
  4. Quote `"$SELF"` (and `$mode_file`) consistently inside execute() binds
     — r, b, x, tab, ctrl-x, transform-header.
  5. Fix the `b` hint (`b break out agent`, not `b new session`) in
     `wb_status_line` and wb-guide.html; correct `_break_out`'s comment —
     on a parent row it acts on the session's most-urgent agent pane.
- **Patterns to follow:** identity-not-index targeting mirrors the existing
  `=name:` exact-match convention (wb.sh header comment); sanitization
  mirrors `wb_sanitize` (wb.sh:106).
- **Test scenarios:** break-out with a dotted name (`v1.2`) — no orphan
  session, correct error or successful sanitized break; break-out on a
  base-index-0 tmux server (`tmux -L test -f /dev/null` with no config) —
  the rescued pane survives; rename to an existing name — error visible.
- **Verification:** live smoke tests via a scratch `tmux -L test` server for
  the base-index case; existing flows (`wb new`/`wb done`/picker jump)
  unbroken.

### U3: `wb board` — interim task-store board (Decision 5A)

- **Goal:** planned/doing/review/done tasks visible again (the presence-only
  picker hides them by design).
- **Files:** `scripts/.config/scripts/tmux/wb.sh` (new `cmd_board` +
  dispatch + usage header), `docs/overview.md` (+`.html` command tables),
  `docs/wb-guide.html` (mention under next steps).
- **Approach:** read-only: iterate `wb_task_files`, emit
  `STATUS / REPO / TASK / FOLLOW-UPS` columns via `wb_read_task` +
  `wb_task_title` + a per-file Follow-ups bullet count (same awk shape as
  `wb_followup_count`, scoped to one file). Sort by status
  (doing → review → planned → done). Plain text to stdout; no tmux, no fzf.
- **Execution note:** test-first is cheap here — bats-style or plain-bash
  assertions against a fixture store dir (also chips at the review's
  "no test coverage for frontmatter helpers" debt).
- **Test scenarios:** empty store; task with no Follow-ups section; title
  missing (falls back to slug); status ordering.
- **Verification:** `wb board` against the real store lists all current
  task files with correct statuses and counts.

### U4: 4a — capture habit setup (Decision 1A)

- **Goal:** start the notes-tui usage window; zero build.
- **Approach:** in `~/code/notes-tui`: merge `feat/usage-guide` →
  `development` (verified 1 ahead, clean); in dotfiles `zsh/.zshrc`: add a
  guarded `[ -f ~/code/notes-tui/scripts/note.sh ] && source ...` line.
  Record the window start + review date (~1 week) in
  `~/code/tasks/dotfiles--agent-task-workflow.md` Follow-ups.
- **Verification:** new shell → `note "test"` appends to
  `~/code/notes/inbox.md` with a ctx stamp; `N`/notes.sh flow unaffected.

### U5: Claude session-id capture at spawn (9b amendment)

- **Goal:** record each agent pane's Claude session id so a future
  `wb up --resume` can `claude --resume <id>` — cheap now, impossible
  retroactively.
- **Files:** `scripts/.config/scripts/tmux/claude-notify-hook.sh`.
- **Approach:** Claude Code hooks receive JSON on stdin including
  `session_id`. In the `start` branch, parse it (jq if present, else a
  minimal grep/sed fallback) and `tmux set -p @claude_session_id <id>`.
  Always exit 0; no-op outside tmux — same contract as the rest of the hook.
- **Test scenarios:** hook invoked with a fake JSON payload sets the pane
  option; invoked with empty stdin doesn't error.
- **Verification:** after a real `claude` turn,
  `tmux show -pv @claude_session_id` returns a UUID.

### U6: Keeper-sweep credential guard (§2 amendment)

- **Goal:** a `- [x] keep` can never carry a credential-shaped file into the
  sync-bound store.
- **Files:** `scripts/.config/scripts/tmux/wb.sh` (`wb_sweep_section` /
  `cmd_done` sweep loop).
- **Approach:** exclusion patterns (`.env*`, `*.pem`, `*.key`, `*secret*`,
  `*credential*`, `id_rsa*`) checked case-insensitively against each marked
  keeper's basename; matching keepers are skipped with a loud warning line
  in the close-out summary (not silently dropped).
- **Test scenarios:** worktree with a marked `.env` keeper → skipped +
  warned; normal `logs/decisions/*.md` keeper → swept as before.
- **Verification:** re-run the existing keeper-sweep smoke test plus the
  credential case.

### U7: Standing artifact landing-path rule (9d-now half)

- **Goal:** session-generated HTML artifacts can no longer exist only in
  scratch.
- **Files:** `~/.claude/CLAUDE.md` (global, user-level).
- **Approach:** add a short standing rule: any HTML doc published as a
  claude.ai Artifact must FIRST be written to a durable landing path — the
  repo's `docs/` when tracked-worthy, else `~/code/tasks/dossiers/` — never
  scratch-only; and employer-repo content never lands in personal surfaces
  (restating the boundary interim guardrail).
- **Verification:** rule present; next artifact-producing session follows it.

### U8: Task store housekeeping

- **Goal:** the store reflects reality post-merge.
- **Files:** `~/code/tasks/dotfiles--agent-task-workflow.md`.
- **Approach:** flip `status: review` → `done` (PR #7 merged 2026-07-06);
  update the `/roadmap` follow-up bullet to the ratified `/board` name +
  Decision 5A outcome; add a dated follow-up for §1's content-scan deletion
  clock (delete `tmux_pane_awaiting_input`'s version-pinned scan ~2026-07-13
  if hook data held); note the §3 validation-clock check-in (~2026-07-20).
- **Verification:** `wb board` (U3) shows the task as done.

## Deferred to Implementation

- U2's exact sanitization choice (reject vs sanitize) — either is
  acceptable; pick whichever reads cleaner in the prompt flow.
- U5's JSON parsing fallback when jq is absent.

## Dependency notes

U3 depends on nothing; U8's verification depends on U3. Everything else is
independent — safe to execute serially in any order, U1 first (fastest,
unblocks merging PR #8).
