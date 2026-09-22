---
title: Where we are
status: current
tile: The strategy page — task-store numbers, which tool to reach for when, the save/resume workflow, every skill/verb/doc with measured usage and a verdict, the architecture direction, and what's next.
group: where-we-are
kind: guide
updated: 2026-09-22
---

<style>
  /* Page-scoped components. Colours come only from the shared template tokens. */
  .wwa-stats { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
    gap: .75rem; margin: 1.25rem 0 .5rem; }
  .wwa-stat { background: var(--panel); border: 1px solid var(--line); border-radius: 10px;
    padding: .8rem 1rem; border-top: 3px solid var(--k, var(--line)); }
  .wwa-stat b { display: block; font-family: var(--mono); font-size: 1.7rem; line-height: 1.1;
    font-variant-numeric: tabular-nums; color: var(--ink); }
  .wwa-stat span { font-size: .78rem; color: var(--ink2); }
  .wwa-stat.doing { --k: var(--acc); } .wwa-stat.review { --k: var(--warn); }
  .wwa-stat.paused { --k: var(--mut); } .wwa-stat.planned { --k: var(--acc2); }
  .wwa-stat.done { --k: var(--ok); } .wwa-stat.prosp { --k: var(--line); }
  .wwa-cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(290px, 1fr));
    gap: .85rem; margin: 1rem 0; }
  .wwa-card { background: var(--panel); border: 1px solid var(--line); border-left: 4px solid var(--acc);
    border-radius: 0 10px 10px 0; padding: .85rem 1rem; }
  .wwa-card h3 { font-family: var(--mono); font-size: .9rem; margin: 0 0 .4rem; }
  .wwa-card p { font-size: .84rem; color: var(--ink2); margin: .25rem 0 0; max-width: none; }
  .wwa-card .use { font-family: var(--mono); font-size: .82rem; color: var(--ink); }
  .wwa-card.new { border-left-color: var(--warn); }
  .wwa-card.task { border-left-color: var(--acc2); }
  .wwa-card.batch { border-left-color: var(--ok); }
  .wwa-flow { display: flex; flex-wrap: wrap; align-items: stretch; gap: .5rem; margin: 1rem 0; }
  .wwa-flow .step { background: var(--panel); border: 1px solid var(--line); border-radius: 8px;
    padding: .6rem .8rem; flex: 1 1 170px; font-size: .82rem; color: var(--ink2); }
  .wwa-flow .step b { display: block; font-family: var(--mono); color: var(--ink); font-size: .85rem; margin-bottom: .2rem; }
  .wwa-flow .arrow { align-self: center; color: var(--mut); font-family: var(--mono); }
  article details { background: var(--panel); border: 1px solid var(--line); border-radius: 8px;
    padding: .5rem 1rem; margin: 1rem 0; }
  article details > summary { cursor: pointer; font-family: var(--mono); font-size: .88rem;
    padding: .25rem 0; color: var(--ink); }
  article details[open] > summary { margin-bottom: .5rem; }
  .wwa-num { font-family: var(--mono); font-variant-numeric: tabular-nums; text-align: right; white-space: nowrap; }
  @media (max-width: 600px) { .wwa-cards { grid-template-columns: 1fr; } }
</style>

The strategy page for the personal workflow: where things stand, which tool
to reach for in which situation, what every piece is actually used for,
and what comes next. Rewritten 2026-09-22 from the old status snapshot.
The [Roadmap](roadmap.html) still holds the long-form history. Usage
numbers come from Claude Code transcripts, 2026-07-01 → 2026-09-22.

## At a glance

The workbench is in daily use. `wb` runs one tmux session per worktree
over a central task store, and the **weekly loop now exists**:
`/park` drops loose ends into a standing capture doc,
`/weekly-review` turns the week's evidence into a handful of suggestions on
the review page, and `wb board --html` shows everything across four views.
Since 2026-09-14: the strategy family shipped the review page and `wb
status`/`wb set` (#52), the weekly review (#55–#58), the rebuilt board
(#59, #62), per-family `CONCEPTS.md` (#61), and the `store-specialist`
subagent (#63). A quick-fix batch is in flight, and four tasks that need
decisions are queued (see [Next up](#next-up)).

<div class="wwa-stats">
  <div class="wwa-stat doing"><b>22</b><span>doing (62 on 2026-09-14)</span></div>
  <div class="wwa-stat review"><b>7</b><span>in review</span></div>
  <div class="wwa-stat paused"><b>5</b><span>paused</span></div>
  <div class="wwa-stat planned"><b>183</b><span>planned</span></div>
  <div class="wwa-stat prosp"><b>8</b><span>prospective</span></div>
  <div class="wwa-stat done"><b>94</b><span>done</span></div>
</div>

Task-store status counts as of 2026-09-22 (319 files). The 2026-09-14 triage
took `doing` from 62 to about 20, and it has stayed there. The old
non-standard `todo`/`open` values are gone.

## Which tool when

One card per situation. A tool named here is the default; the others are
alternatives for a specific shape of the problem.

<div class="wwa-cards">
  <div class="wwa-card"><h3>Capture a loose end</h3>
    <p class="use">/park &lt;note&gt;</p>
    <p>Appends to the standing capture doc (<code>~/code/tasks/weeks/capture.md</code>), which the weekly review rolls up. If it's shaped like work, it's proposed as a <code>prospective</code> task instead. <kbd>prefix</kbd>+<kbd>N</kbd> opens the capture doc directly. <a href="guides/park.html">guide</a></p></div>
  <div class="wwa-card"><h3>Make a settled choice</h3>
    <p class="use">/decision-buffer</p>
    <p>Once the direction is agreed in chat and what's left needs a written answer. Six shapes: choice, findings-review, interview, paste-target, confirm-facts, code-review triage. Past ~25 rows, use <code>/review-page</code> instead. <a href="guides/decision-buffer.html">guide</a></p></div>
  <div class="wwa-card"><h3>Review a big batch</h3>
    <p class="use">/review-page</p>
    <p>A local HTML page with evidence per row, a suggested verdict, grouping and questions. Use it for audits, prune lists and triage, where an nvim buffer becomes unreadable. <a href="guides/review-page.html">guide</a></p></div>
  <div class="wwa-card"><h3>Scope an open question</h3>
    <p class="use">/ce-brainstorm → /ce-plan</p>
    <p>Brainstorm for what to build, <code>/ce-ideate</code> for generating options, <code>/spec-doc</code> when requirements need pinning down for others, <code>/ce-pov</code> for "should we adopt X?".</p></div>
  <div class="wwa-card"><h3>Split something too big</h3>
    <p class="use">/wb-breakdown</p>
    <p>Turns one oversized task or Jira ticket into a parent/child family, via an approved proposal that <code>wb breakdown --apply</code> writes. <a href="wb-guide.html#wb-breakdown--split-an-oversized-task-into-a-family">wb guide</a></p></div>
  <div class="wwa-card"><h3>Start or reopen work</h3>
    <p class="use">wb  ·  wb new  ·  wb resume &lt;task&gt;</p>
    <p>The picker (<kbd>prefix</kbd>+<kbd>m</kbd>) lists live and dormant sessions. <code>wb new</code> makes a worktree, session and task file. <code>wb resume</code> rebuilds a torn-down one from its task file. <a href="wb-guide.html">wb guide</a></p></div>
  <div class="wwa-card"><h3>Free up context mid-task</h3>
    <p class="use">/wb-save → /clear → /wb-resume</p>
    <p>The most-used loop in the whole system (91 and 86 transcripts). See <a href="#save--resume--the-intended-workflow">save &amp; resume</a> below.</p></div>
  <div class="wwa-card"><h3>End a session</h3>
    <p class="use">/close-out</p>
    <p>Sweeps the session for follow-ups, updates the task file, then runs <code>wb down</code> (keeps the worktree; use when a PR is open) or <code>wb done</code> through <code>/wb-done</code> (removes the worktree and marks the task done).</p></div>
  <div class="wwa-card"><h3>Hand work to another session</h3>
    <p class="use">/handoff</p>
    <p>Routes one piece of the current discussion to its own worker. It switches to the live session if one exists, or spawns one with <code>wb new --agent</code>, with the context written into the target's task file first. <a href="handoff-guide.html">guide</a></p></div>
  <div class="wwa-card"><h3>Start the week</h3>
    <p class="use">/weekly-review</p>
    <p>Gathers reconcile drift, unreviewed capture entries, tasks moved, PRs merged and skill usage, shows at most a handful of suggestions on the review page, and writes <code>weeks/&lt;iso&gt;-review.md</code>. Accepted suggestions become <code>planned</code> tasks. <a href="guides/weekly-review.html">guide</a></p></div>
  <div class="wwa-card"><h3>See everything</h3>
    <p class="use">wb board --html</p>
    <p>Writes <a href="../logs/board.html">logs/board.html</a> with four views: <b>Active</b>, <b>Roadmap</b>, <b>Week</b> and <b>Family</b> (per-family ladder, plus a <code>family-rollup.json</code> side output). It is generated on demand.</p></div>
  <div class="wwa-card"><h3>Ask the task store something</h3>
    <p class="use">store-specialist (subagent)</p>
    <p>For an agent that needs "what does the store say about X" with <code>file#section</code> pointers, or needs to write a decision or frontmatter change back through the locked <code>wb</code> verbs rather than a hand edit. New in #63.</p></div>
  <div class="wwa-card"><h3>Ship a change</h3>
    <p class="use">/ce-code-review → wb reviewed → PR</p>
    <p>Review before the PR, then stamp the task's <code>reviewed:</code> field immediately (the board's review stage reads it). <code>/ce-commit-push-pr</code> opens the PR.</p></div>
  <div class="wwa-card"><h3>"Why do I have X?"</h3>
    <p class="use"><kbd>prefix</kbd>+<kbd>?</kbd></p>
    <p>A fuzzy picker over the generated <a href="INDEX.md">INDEX</a> (binds, aliases, skills, docs), with source links.</p></div>
</div>

### Newer skills — when to reach for them

These are too new, or too rarely used, to judge. Each has a concrete trigger
so it has a fair chance of being tried.

<div class="wwa-cards">
  <div class="wwa-card new"><h3>/quick-wins <span class="chip mut">0 uses</span></h3>
    <p>You have an hour and want to finish something: it ranks planned tasks and captured items by effort, isolation and ownership. <em>Example:</em> Friday afternoon, "which planned dotfiles tasks are S-sized and need nothing from anyone?"</p></div>
  <div class="wwa-card new"><h3>/spec-doc <span class="chip mut">1 use</span></h3>
    <p>Before <code>/wb-breakdown</code> or <code>/ce-plan</code> on something big enough that the requirements need writing down. <em>Example:</em> the task-store schema owner (T2 below), where the numbered rules decide the module's API.</p></div>
  <div class="wwa-card new"><h3>/visual-explore <span class="chip ok">4 uses</span></h3>
    <p>Choosing the look of a new HTML surface by comparing 3–4 mockups side by side before building. <em>Example:</em> the <code>/wb-breakdown</code> review page (T3 below).</p></div>
  <div class="wwa-card new"><h3>/find-skills <span class="chip mut">0 uses</span></h3>
    <p>When you think "there's probably a skill for this": search installable skills before writing a new one. <em>Example:</em> before building a custom statusline or a new Jira helper.</p></div>
  <div class="wwa-card new"><h3>/write-product-spec · /write-tech-spec <span class="chip mut">0 uses</span></h3>
    <p>Vendored for features in Warp's own repo. Outside Warp, <code>/spec-doc</code> covers product specs and hands off to write-tech-spec only when a separate TECH spec helps. <em>Example:</em> a contribution to Warp itself. Otherwise, leave them alone.</p></div>
</div>

## Save & resume — the intended workflow

The session boundary is where context gets lost, so this is the workflow to
get right. It's already the most-used loop in the system.

<div class="wwa-flow">
  <div class="step"><b>/wb-save</b>Writes a rich <code>## Handoffs</code> entry (Done / In flight / Next, plus an optional <code>```run</code> directive) into the task file found via the tmux session's <code>@task</code>.</div>
  <div class="arrow">→</div>
  <div class="step"><b>/clear</b>Manual. Context is gone; the task file is the only carrier.</div>
  <div class="arrow">→</div>
  <div class="step"><b>/wb-resume</b>Reads the newest rich entry and continues with its Next. If terse automatic entries (<code>wb pause</code>/<code>done</code>/<code>resume</code>) landed after it, it states the gap and asks first.</div>
</div>

At the **session** level, the same idea works without `/clear`:

- **`wb down`** closes the tmux session and keeps the worktree. The status
  moves to `review` if the branch has an open PR, otherwise it stays as it was.
  Resume is warm: the picker's dormant rows and `wb resume` pre-type
  `claude --resume <id>` from the transcript Claude Code already keeps
  on disk. No session-id capture is needed. [Details](wb-guide.html#session-lifecycle-wb-down-wb-pause-and-warm-resume).
- **`wb pause`** is `wb down` plus `status: paused`, for deliberately
  shelving something.
- **`wb done`** is the safe wind-down: it aborts on a dirty worktree, runs a
  sweep-review buffer, removes the worktree and marks the task `done`. From
  inside Claude, go through `/wb-done` (background plus relay) so the buffer
  doesn't hang the turn.
- **`/close-out`** wraps all of it for the end of a session.

The per-skill references stay as they are: [wb-save](guides/wb-save.html) ·
[wb-resume](guides/wb-resume.html). **Next evolution:** the
`dotfiles--feat-wb-implicit-handoff` task (planned) makes saving automatic.
A cheap Haiku-class writer runs from a Stop/PreCompact hook, and a manual
`/wb-save` stays for rich snapshots.

## Inventory and verdicts

Every piece, with measured usage and a verdict. "Transcripts" means distinct
Claude Code sessions that invoked it between 2026-07-01 and 2026-09-22;
"since 9/15" shows recent uptake. Verdicts carry forward the 2026-09-14
piece audit, re-checked against the refreshed counts.

> **Correction to the 2026-09-14 numbers.** The earlier snapshot undercounted
> Skill-tool calls badly (for example `/handoff` showed 1 session; the real
> number is 27; `ce-code-review` showed 3 against 53). None of that
> audit's *removals* were wrong: every removed piece is still at zero. But
> several "keep (light)" verdicts were really core pieces. Source:
> `dossiers/dotfiles--feat-strategy-doc/usage-inventory-2026-09-22.md`.

### Local skills

| Skill | Transcripts | Since 9/15 | Verdict | Note |
|---|---|---|---|---|
| wb-resume | <span class="wwa-num">91</span> | <span class="wwa-num">26</span> | <span class="chip ok">keep</span> | Top of the list. |
| wb-save | <span class="wwa-num">86</span> | <span class="wwa-num">25</span> | <span class="chip ok">keep</span> | Automatic saving planned (implicit-handoff task). |
| decision-buffer | <span class="wwa-num">56</span> | <span class="wwa-num">9</span> | <span class="chip ok">keep</span> | v2 rewrite (#47); big batches go to review-page. |
| handoff | <span class="wwa-num">27</span> | <span class="wwa-num">8</span> | <span class="chip ok">keep</span> | Was "keep (light)" on the undercount. |
| close-out | <span class="wwa-num">19</span> | <span class="wwa-num">11</span> | <span class="chip ok">keep</span> | Growing fast. |
| wb-done | <span class="wwa-num">11</span> | <span class="wwa-num">1</span> | <span class="chip ok">keep</span> | Mostly reached through close-out now. |
| park | <span class="wwa-num">5</span> | <span class="wwa-num">4</span> | <span class="chip ok">keep</span> | Plus 19 capture-doc entries; now feeds the weekly review. |
| wb-jira-create | <span class="wwa-num">5</span> | <span class="wwa-num">2</span> | <span class="chip ok">keep</span> | Was zero on the undercount. |
| wb-breakdown | <span class="wwa-num">4</span> | <span class="wwa-num">2</span> | <span class="chip warn">keep · revamp</span> | Proposal moves to the review page, see T3. |
| visual-explore | <span class="wwa-num">4</span> | <span class="wwa-num">1</span> | <span class="chip acc">too new · in use</span> | |
| review-page | <span class="wwa-num">1</span> | <span class="wwa-num">1</span> | <span class="chip acc">too new</span> | Shipped 2026-09-14; weekly-review uses it underneath. |
| weekly-review | <span class="wwa-num">1</span> | <span class="wwa-num">1</span> | <span class="chip acc">too new</span> | Has run once (W38). |
| spec-doc | <span class="wwa-num">1</span> | <span class="wwa-num">0</span> | <span class="chip acc">too new</span> | |
| quick-wins | <span class="wwa-num">0</span> | <span class="wwa-num">0</span> | <span class="chip mut">no uptake</span> | A month old. Question for the weekly review, not a removal. |
| help | <span class="wwa-num">0</span> | <span class="wwa-num">0</span> | <span class="chip mut">no uptake</span> | Kept in the audit; the <kbd>prefix</kbd>+<kbd>?</kbd> picker does the same job. |
| find-skills | <span class="wwa-num">0</span> | <span class="wwa-num">0</span> | <span class="chip acc">too new</span> | |
| write-product-spec · write-tech-spec | <span class="wwa-num">0</span> | <span class="wwa-num">0</span> | <span class="chip mut">no uptake</span> | Specific to Warp's repo, vendored. |
| store-specialist (subagent) | <span class="wwa-num">0</span> | <span class="wwa-num">0</span> | <span class="chip acc">too new</span> | Landed today (#63). |

**Already removed** (the 2026-09-14 audit, all still at zero): `handoff-pane`
and `wb-board` (#52), `parked-items` (absorbed into `/weekly-review`, #55).
**The prune list (R12) is empty:** every remove, archive and merge verdict
from that audit has shipped or is covered by this rewrite, so no prune
follow-up tasks are needed.

### Plugin skills (compound-engineering)

Plugin-provided, so they get guidance on when to use them rather than
verdicts. They are central to how work gets done: plan → work → review
runs through them.

| Group | Skills (transcripts) | Reach for it when |
|---|---|---|
| **Core loop** | `ce-code-review` 53 · `ce-work` 37 · `ce-plan` 30 · `ce-doc-review` 23 | Every non-trivial task: plan it, doc-review the plan if it's big, work it, code-review before the PR. |
| **Situational** | `ce-simplify-code` 12 · `ce-debug` 8 · `ce-ideate` 5 · `ce-brainstorm` 5 · `ce-explain` 2 · `ce-commit-push-pr` 2 | Debug a failure, tidy after a feature lands, generate or refine ideas, learn a diff, open a PR. |
| **Deliberately** | `ce-worktree` 4 · `ce-pov` 0 · `ce-resolve-pr-feedback` 0 · `ce-compound` 0 · `ce-test-browser` 0 | `ce-worktree` only outside dotfiles: here, `wb new` also bootstraps. `ce-pov` for "adopt X?". `ce-resolve-pr-feedback` when PR comments pile up. `ce-compound` to record a hard-won fix. |
| **Not needed here** | `ce-strategy` · `ce-commit` · `ce-compound-refresh` · `ce-optimize` · `ce-proof` · `ce-riffrec-feedback-analysis` (all 0) | This page plays the STRATEGY.md role. Commits happen inside other flows. The rest target setups that don't exist here. |

### wb verbs

Usage is measured two ways: automatic `## Handoffs` entries the verb writes
into task files, and distinct transcripts that ran it through Bash.

| Verb | Evidence | Verdict |
|---|---|---|
| `wb resume` | 103 auto entries | <span class="chip ok">keep</span> |
| `wb done` | 81 auto entries | <span class="chip ok">keep</span> |
| `wb new` | 40 transcripts; the picker's `n`; used by 6 skills | <span class="chip ok">keep</span> |
| `wb set` · `wb status` | 54 / 29 auto entries | <span class="chip ok">keep</span> (new since #52) |
| `wb board` | 25 transcripts | <span class="chip ok">keep</span> (rebuilt #59/#62) |
| `wb reconcile` | 12 transcripts; first evidence step of the weekly review | <span class="chip ok">keep</span> · duplicate detection → T1 |
| `wb week` | 10 transcripts | <span class="chip acc">too new</span> |
| `wb breakdown` | 8 auto entries | <span class="chip warn">keep · refine</span> → T3 |
| `wb down` · `wb pause` · `wb pr-open` · `wb append` · `wb install-hooks` | Used by close-out, wb-resume, handoff, wb-save and weekly-review | <span class="chip ok">keep</span> |
| `wb reviewed` · `wb jira-set` · `wb sync` · `wb unsafe-rewind` | Rare by design (stamps and escape hatches) | <span class="chip ok">keep (light)</span> |

### Docs pages

<details>
<summary>30 pages: 19 current, 7 archived by this rewrite, and a note on staleness</summary>

| Page | Updated | Verdict |
|---|---|---|
| [where-we-are](where-we-are.html) (this page) | 2026-09-22 | <span class="chip ok">keep</span>: the strategy page |
| [try-it](try-it.html) · [ceremonies](ceremonies.html) · guides: [weekly-review](guides/weekly-review.html) · [park](guides/park.html) · [review-page](guides/review-page.html) · [decision-buffer](guides/decision-buffer.html) | 2026-09-09 → 09-22 | <span class="chip ok">keep</span> |
| [wb-guide](wb-guide.html) | 2026-08-24 | <span class="chip warn">keep · stale</span>: its board section still describes v2, before the #59/#62 rebuild |
| [roadmap](roadmap.html) | 2026-07-18 | <span class="chip warn">keep · stale</span>: long-form history; this page supersedes its "Up next" |
| [handoff-guide](handoff-guide.html) | 2026-07-19 | <span class="chip warn">keep · stale</span>: still documents pane mode, whose skill was removed in #52 |
| [setup](setup.html) · [glossary](glossary.html) · [limitations](limitations.html) · [docgen](docgen.html) · [guide-format](guide-format.html) | 2026-07-07 → 07-14 | <span class="chip ok">keep</span> |
| guides: [wb-save](guides/wb-save.html) · [wb-resume](guides/wb-resume.html) · [tasks-store-guards](guides/tasks-store-guards.html) · [help](guides/help.html) · [claude-tmux](guides/claude-tmux.html) · [notes-tui](guides/notes-tui.html) · [replay-tui](guides/replay-tui.html) | 2026-07-07 → 07-14 | <span class="chip ok">keep</span>. The workflow now lives here; replay-tui simplification is tracked in `replay-tui--replay-improvements` |
| 7 `roadmap-*` design notes | 2026-07-08 → 07-19 | <span class="chip mut">archived</span>, folded into [wb design &amp; open threads](#wb-design--open-threads) |
| 10 recaps plus slice-4b | — | <span class="chip mut">archived</span> in #52 |

</details>

## wb design & open threads

The seven `roadmap-*` design notes are folded in here: one paragraph each on
what shipped and what's still genuinely open. The originals are kept, word
for word, in `docs/archive/`.

<div class="wwa-cards">
  <div class="wwa-card"><h3>Board <span class="chip ok">shipped</span></h3>
    <p>The interim text <code>wb board</code>, then the v1 HTML board, then v2 (stepper, Pipeline, relationships, Key Findings), then the rebuild into the four views (#59, #62). Jira stays excluded. Nothing is open. <a href="archive/roadmap-board.html">archived note</a></p></div>
  <div class="wwa-card"><h3>Day bookends <span class="chip warn">partly open</span></h3>
    <p>Single-session <code>wb down</code> and <code>wb resume</code> shipped. The "precious session id" worry went away: transcripts on disk already make resume warm. Still open: the <code>wb down --all</code> sweep and <code>wb up</code>'s startup review buffer. The weekly review now covers the start of the week. Principle: sessions can always be rebuilt from the task file. <a href="archive/roadmap-day-bookends.html">archived note</a></p></div>
  <div class="wwa-card"><h3>Handoff <span class="chip warn">partly open</span></h3>
    <p>v1 (switch or spawn, the task file as the payload) shipped in #21. Pane mode shipped in #34; its skill was removed in #52, though <code>handoff.sh --pane</code> remains. Still open: fan-out to several targets (parent/child now exists, and the board's <code>family-rollup.json</code> is built for it), instructing a live agent, non-blocking handoff, and handoff between stages of the same task. <a href="archive/roadmap-handoff.html">archived note</a></p></div>
  <div class="wwa-card"><h3>Task recall <span class="chip warn">open</span></h3>
    <p>Mentioning a task in any session should bring up its context and offer to resume it. Partly covered by the worktree-seeding rule, per-family <code>CONCEPTS.md</code> (#61) and <code>store-specialist</code> (#63). Open decisions: the matching heuristic, how eagerly to trigger it automatically, and the personal/employer boundary. <a href="archive/roadmap-task-recall.html">archived note</a></p></div>
  <div class="wwa-card"><h3>wb design <span class="chip ok">settled</span></h3>
    <p>Picker rows are tasks from the store, grouped by status first. <code>wb done</code> fails fast on a dirty worktree. It's bash, not Go, because it's tmux/fzf glue. The task record's sections are Plan / Handoffs / Decisions / Done / Follow-ups. The 2026-07-20 check on the parked ledger was resolved by making the weekly review the main path (#55). <a href="archive/roadmap-wb-design.html">archived note</a></p></div>
  <div class="wwa-card"><h3>wb reconcile <span class="chip warn">one gap</span></h3>
    <p>Presence-diff plus the review flow (do nothing / remove / discuss / create / attach / merge) shipped in #14, and it never auto-applies. Duplicate detection for two worktrees sharing a commit was deliberately deferred and kept report-only. It's now T1. <a href="archive/roadmap-wb-reconcile.html">archived note</a></p></div>
  <div class="wwa-card"><h3>Open questions <span class="chip mut">record</span></h3>
    <p><code>~/code/tasks</code> and <code>~/code/notes</code> stay separate repos (the "everything is a note" north star is parked). The "(F4)" mystery was traced. The <b>personal/employer boundary rule</b> is deliberately left as the last decision. <a href="archive/roadmap-open-questions.html">archived note</a></p></div>
</div>

## Architecture direction

**One schema owner for the task store.** Today every `wb` verb, skill and
agent reads and writes frontmatter its own way. The ratified order (parked
item 7, 2026-09-14) is:

1. **`--json` on `wb` read commands.** Agents stop scraping human-formatted output. → `dotfiles--feat-task-store-json-read` <span class="chip acc">planned</span>
2. **A single frontmatter read/write module** that every verb goes through. The `store-specialist` subagent (#63) is already a partial single owner on the agent side; this step decides how the two relate.
3. **The schema migration**, run through that module. It's much smaller than it was: every `status:` value is now valid. The empty-key backfill for `parent`/`closed`/`depends_on` is in the quick-fix batch. What's left is deciding whether `size`/`priority`/`value` (missing from ~70–75% of files) are required with empty defaults or genuinely optional.
4. **Read-only HTTP** over the store.
5. **MCP last**, and only for mutating operations.

All of this is held by the parent task `dotfiles--feat-task-store-schema-owner`,
which gets split with `/wb-breakdown` as each step comes up. **Already fixed:**
the `CODE_DIR` sourcing hazard behind the 2026-07-10 deletion incident.
`wb.sh` now only sets it if unset (`CODE_DIR="${CODE_DIR:-$HOME/code}"`).

## Next up

The old "Next up" list, re-checked 2026-09-22. None of the three items had
landed. Each is now either in the quick-fix batch or a task with its open
decisions written down.

### In flight — quick-fix batch

<div class="wwa-cards">
  <div class="wwa-card batch"><h3>dotfiles--fix-strategy-quick-fixes <span class="chip acc">doing</span></h3>
    <p>Clear fixes with no design decisions, in one worker session:</p>
    <p>① <code>wb new</code> bootstrap self-heal (bootstrap was skipped when the worktree dir already existed) · ② <code>be--monorepo</code> bootstrap manifest (local) · ③ empty-key schema backfill · ④ docgen: a missing source root becomes a warning · ⑤ statusline usage and reset times, if Claude Code provides the data · ⑥ render <code>docs/archive/</code> pages (fixes 22 broken recap links)</p></div>
</div>

### Tasks that need a decision first

<div class="wwa-cards">
  <div class="wwa-card task"><h3>T1 · wb reconcile duplicate detection <span class="chip">M</span></h3>
    <p>Decide what counts as a duplicate (shared commit? same Jira key? stuttered slugs?), whether it stays report-only, and whether it appears in the weekly review. <code>dotfiles--feat-wb-reconcile-duplicate-detection</code></p></div>
  <div class="wwa-card task"><h3>T2 · task-store schema owner <span class="chip">L</span></h3>
    <p>The parent for the five-step direction above; the <code>size</code>/<code>priority</code>/<code>value</code> policy is decided here. <code>dotfiles--feat-task-store-schema-owner</code></p></div>
  <div class="wwa-card task"><h3>T2a · <code>--json</code> read output <span class="chip">M</span></h3>
    <p>Which commands get it, the JSON shape and versioning, and how store-specialist consumes it. <code>dotfiles--feat-task-store-json-read</code></p></div>
  <div class="wwa-card task"><h3>T3 · /wb-breakdown on the review page <span class="chip">M</span></h3>
    <p>Replace the buffer or keep it as a fallback, what replaces the approve gate, and how answers reach <code>wb breakdown --apply</code>. <code>dotfiles--feat-wb-breakdown-review-page</code></p></div>
</div>

### Queued behind those

- **Family follow-ons:** `dotfiles--feat-task-file-structure` (unblocked once
  this page ships) and `dotfiles--chore-ceremonies-refresh`.
- **Task recall**, **`wb down --all` / `wb up`**, **handoff fan-out**: see
  the open threads above.
- **Jira Phase 2 (sprint pull)**: `dotfiles--loop-jira-watch`. Also a
  real Epic hierarchy for emit.
- **Implicit save/resume** (`dotfiles--feat-wb-implicit-handoff`) and
  **replay-tui simplification** (`replay-tui--replay-improvements`).
- **Personal/employer boundary rule**: deliberately the last decision.

## Shipped

<details>
<summary><span class="chip ok">53 merged</span> PRs #11 → #63. Full history is on the linked recaps and the roadmap.</summary>

| PR | What |
|---|---|
| #63 | `store-specialist` subagent: a task-store retriever and mechanical writer |
| #62 | Board Family view (re-landed) + UX pass driven by the side rail |
| #61 | Per-family `CONCEPTS.md` seeded automatically into every worktree agent |
| #59 | `wb board` rebuilt as the Active/Roadmap/Week renderer |
| #57, #58 | Capture-doc bind (<kbd>prefix</kbd>+<kbd>N</kbd>) |
| #55, #56 | **Weekly review loop**: week file, `/park` capture, review-page ceremony |
| #54 | wb + review-page follow-ups after #52 |
| #53 | decision-buffer learning from the parked-items run |
| #52 | **Requirements plan, `/review-page`, `wb status`/`wb set`, piece-audit prune** |
| #49–#51 | Picker + session lifecycle: `wb down`, dormant rows, warm resume from transcripts |
| #48 | `/spec-doc` + vendored find-skills and Warp spec skills |
| #47 | **decision-buffer v2**: align check, six shapes, approve gate |
| #46 | Jira emit marked verified live |
| #45 | `wb breakdown` captures `size:`/`depends_on:`; `wb new --size` |
| #44 | `/wb-jira-create` checkbox-select |
| #43 | Machine-readable next-action directive for `/wb-save`/`/wb-resume` |
| #42 | Auto-generated try-it catalog |
| #41 | Per-agent cgroup isolation |
| #40 | Lazy nvim window per wb session |
| #39 | `/quick-wins` |
| #37, #38 | tmux: agent windows survive shell exit; picker idle/done fix |
| #36 | `/parked-items` (retired in #55) |
| #34, #35 | `/handoff --pane`; post-crash verification checklist |
| #33 | Docs platform + board UX overhaul |
| #32 | **Jira interop, emit (Phase 1)**, verified live 2026-09-07 |
| #31 | Hub + roadmap refresh |
| #30 | Board display v2 |
| #29 | **`/wb-breakdown`** |
| #28 | Default-browser hijack fix |
| #26, #27 | `wb-save`/`wb-resume`/`wb-done`/`wb-board` skills |
| #25 | tmux: land in another session on kill |
| #24 | Per-worktree `/queue` |
| #22, #23 | **Task-store concurrency safety** |
| #21 | **`/handoff` v1** |
| #19, #20 | `wb done --close`; lifecycle-stage detection |
| #17, #18 | **Task parent/child**; Hub v0 |
| #14–#16 | **wb workbench extensions**: resume / pause / board / reconcile |
| #11–#13 | GPaste; roadmap restructure; docgen hook |

</details>
