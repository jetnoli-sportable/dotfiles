---
title: Recap — Jira ticket interop (emit tasks to Jira tickets)
status: current
tile: A human-approved proposal buffer plus a locked write-back verb — turning a wb task or /wb-breakdown family into new Jira tickets (SFB by default, or SW), with each ticket's URL stamped back into the task.
group: recaps
kind: page
updated: 2026-07-16
---

`/wb-breakdown` gave the workbench one direction of Jira interop: a ticket
becomes a scoped task (or a family of them). The reverse was still
hand-work — an idea broken into tasks locally, then filed as tickets for
the team, meant copying each task's title and plan into Jira by hand. This
is the *emit* direction: take a task, or a whole breakdown family, and
create the tickets from it — in a chosen project (SFB by default, or SW) —
without leaving the workbench.

## What got built (Phase 1)

A **`wb jira-set <repo>--<slug> <url>`** verb
(`scripts/.config/scripts/tmux/wb.sh`, `cmd_jira_set`) — one locked,
single-field write that stamps a created ticket's canonical URL into an
existing task's `jira:` frontmatter. Modeled on `cmd_reviewed`'s locked
write, it is **idempotent-or-refuse**: an empty field is written, an
identical value is a no-op success (a partial create-then-stamp failure is
safe to retry), and a *different* value fails loud and writes nothing — it
never clobbers an existing ticket link. The compare-and-write happens under
the task-store lock (a pre-lock read is only a no-op fast path), so two
concurrent writers can't both see "empty" and lose a write.

A **`/wb-jira-create`** skill
(`claude/.claude/skills/wb-jira-create/SKILL.md`) that resolves a task or a
family, drops any task already carrying `jira:`, previews an MCP reachability
check, and authors a proposal buffer under `logs/jira-create/` — one
checkbox block per ticket with an editable issue type (default `Feature`)
and the task's full `## Plan` body shown verbatim as the description that
will publish. The human edits and approves; only then does the skill create
the tickets over the Atlassian MCP, link them, and write each URL back
through `wb jira-set`. It mirrors `/wb-breakdown`'s authoring → approve
posture: the buffer lives in the dotfiles repo (never the task store), the
blocking open uses the `WB_REVIEW_BUFFER=1` conform.nvim guard, and it
refuses to clobber a prior unresolved buffer.

## The decisions that shaped it

- **Create-only.** The skill only ever calls `createJiraIssue` and
  `createIssueLink` — it never updates, transitions, or edits an existing
  ticket. This is enforced not just by prose but by a grep guardrail in
  `tests/wb-jira-set.test.sh` that fails if the SKILL ever names a
  ticket-mutation tool or an Edit/Write-to-store instruction.
- **The only store write is `wb jira-set`.** Ticket creation lives
  agent-side over the MCP (bash can't create tickets), so there is no
  all-in-one bash apply like `wb breakdown --apply`; the sole store write is
  the locked field stamp, and the skill routes everything through it.
- **Generic "Relates" linkage, not Epic.** A single optional `Parent
  ticket:` field links children to a parent (an existing key, a batch row,
  or the family coordinator) with the config-independent "Relates" link. A
  real Epic hierarchy is a forward-compatible later upgrade — the field
  drives it with no buffer change.
- **Project is selectable, not hard-coded.** A run-level `Project:` buffer
  field (default `SFB`, editable to `SW` or another accessible key) sets the
  `projectKey`, the dedup JQL scope, and the `<KEY>-<n>` URL-shape check.
  Issue types are project-specific, so the buffer's `type:` options come from
  the chosen project's own metadata (resolved at preflight and re-resolved
  after approval if the field changed) rather than a fixed SFB list.
- **Retry-safe by two guards.** The gather-time `jira:` skip is the fast
  path; a Jira-side dedup (search the `wb` label + exact summary before
  creating) is the correctness backstop, because create-then-stamp is not
  one transaction. The MCP preflight (cloudId, accountId, tool presence)
  re-runs after the approval wait, since that wait is unbounded and the MCP
  can drop.

## Verification and what's deferred

`wb jira-set` is covered by `tests/wb-jira-set.test.sh` (happy path,
idempotent re-run, refuse-clobber, missing stem, empty URL, field-insert,
and a real-background-holder lock-contention scenario) plus the SKILL grep
guardrail. The skill halves are agent-driven, so their behavioral scenarios
live in the SKILL's own "Test scenarios" section; the end-to-end emit gate
(creating real tickets) is a manual run, since it depends on a live
Atlassian MCP and the shared tracker has no sandbox project.

**Phase 2** — pulling the user's current-sprint SFB tickets into wb tasks —
is sketched in the plan but not built here; it reuses `/wb-breakdown`'s
existing ticket→task path and ships independently.
