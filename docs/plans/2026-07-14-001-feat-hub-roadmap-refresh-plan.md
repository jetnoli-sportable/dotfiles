---
title: Hub + Roadmap Refresh - Plan
type: feat
date: 2026-07-14
topic: hub-roadmap-refresh
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Hub + Roadmap Refresh - Plan

## Goal Capsule

- **Objective:** fold the repo's latest shipped work into `docs/roadmap.md`/`docs/HUB.html`, fix every genuinely stale claim a full `docs/*.md` audit found, close the skill-guide gap (7 skills currently unlinked or unwritten), split the Hub's 25-tile "Personal workflow" block into sections, and add a lightweight mechanism so this doesn't need another one-off pass.
- **Product authority:** the decision buffer `logs/decisions/2026-07-14-hub-roadmap-refresh-scoping.md` (+ companion `.html`), mirrored in `~/code/tasks/dotfiles--docs-hub-roadmap-refresh.md`'s `## Decisions`, resolved the four original open questions (recap consolidation, guide format, stays-updated mechanism, PR-depth triage). This document's Planning Contract records four further scope calls made during `/ce-plan`'s solo scoping gate: the Hub-sectioning shape, in-scope new-guide authorship, full-audit depth, and the two mechanically-hard-to-define lint checks dropped in favor of two well-defined ones (KTD3).
- **Stop conditions:** surface rather than guess if (a) `docgen`'s `IndexSource.Guide` override field (`config.go:78-82`) turns out to already be wired for the `skills` kind by the time U6 starts (re-verify before assuming it's `tui`-only), or (b) any unit's edit would contradict a Decision already resolved in the buffer.
- **Execution profile:** almost entirely prose/config edits in this repo (`dotfiles`) plus one Go feature spanning a separate local repo, `~/code/docgen` (has a GitHub remote, `jetnoli-sportable/docgen`, `development` branch in sync as of this plan — U6/U9 must commit and push there, not just locally). `docgen.sh` auto-rebuilds its binary from source on change, so no separate build step is needed beyond running it.
- **Product Contract preservation:** no upstream brainstorm exists; this plan is the first structured artifact for this work.

**Target repo note:** every unit operates in this repo (`dotfiles`) except U6 and U9, which also modify `~/code/docgen` (a separate local git repo). Paths below are repo-relative within whichever repo the unit names.

---

## Product Contract

### Summary

Update `docs/roadmap.md` and related pages to reflect everything shipped since the last refresh, fix every stale claim a full audit of `docs/*.md` surfaced, close the skill-guide gap for all 7 currently-unlinked-or-unwritten skills, split the Hub's flat 25-tile "Personal workflow" group into sections, and add a build-time lint plus a light `/wb-done` nudge so drift gets caught going forward instead of needing another full pass.

### Problem Frame

`docs/roadmap.md`'s frontmatter says `updated: 2026-07-12`, but `development` has moved 11 PRs since. The task's own handoff notes already found five concrete staleness gaps (detailed in the decision buffer); verifying them during scoping found two more (PR #24 and PR #28 both shipped with zero roadmap mention) and one correction (the skill-guide gap is 7 skills, not 6 — `help` was missed, and 4 of the 7 already have written content sitting unlinked in `docs/wb-guide.md`/`docs/handoff-guide.md`). A follow-up full audit of every other `docs/*.md` page (run during this planning pass) found eight more genuine staleness cases — pages describing already-shipped or already-resolved things as still pending, one dead link, and one stale manual-check entry. Separately, the Hub's "Personal workflow" tile group has grown to 25 tiles with no internal structure, which the requester flagged as part of the clutter problem in its own right. This plan closes all of it in one pass and adds a cheap mechanism (a docgen lint, not a new ceremony) so the next pass isn't another full-repo sweep — directly responding to the `workflow-goals-vs-tools-tension` finding that meta-documentation about this workflow already outweighs its tooling. Most of this plan's units (U1-U5, U7, U8) are themselves content/config edits, adding to that same side of the ledger; only U6/U9's docgen code and U10's nudge add tooling weight. That trade is accepted here because the alternative — leaving the audit's findings uncorrected — is worse, not because this plan is exempt from the tension it cites.

### Requirements

**Roadmap and doc currency**
- R1. `docs/roadmap.md`'s Shipped ledger includes rows for PR #30 (board display v2), PR #24 (`/queue`), and PR #28 (xdg-open fix).
- R2. The `/handoff` Live-table row moves to Shipped, reflecting PR #21 (fan-out extension stays noted as still live).
- R3. PR #19, #20, #25, #27 get inline backfill sized to the roadmap's own "small completed items noted inline" convention, not a new row each.
- R4. Every genuine staleness case the full `docs/*.md` audit found is corrected to match current reality.

**Guide system**
- R5. The 6-page shape already shared by most of `docs/guides/*.md` is captured as a named, reusable convention.
- R6. `docgen`'s indexer resolves a non-empty `guide` for `wb-done`, `wb-breakdown`, `wb-board`, and `handoff` from their existing content, instead of reporting empty.
- R7. `wb-resume`, `wb-save`, and `help` each get a genuine new guide page in the R5 shape.

**Hub structure**
- R8. The 25-tile "Personal workflow" Hub group is split into multiple top-level `docgen.json` groups.

**Stays-updated mechanism**
- R9. `docgen` warns (non-fatal) when a skill's guide resolves empty.
- R10. `docgen` warns (non-fatal) on an orphaned `#detail-*` href, a duplicate `id="detail-*"` anchor, or a same-repo relative link that resolves to no existing file — the last covers the R13 dead-link class, which a fragment-only check can't catch.
- R11. `/wb-done`'s finish path prints a one-line reminder when the closing task's repo/tags intersect a roadmap-tracked area.

**Recap consolidation**
- R12. `2026-07-12-tasks-dir-concurrency-safety-recap.md`'s content is merged into `docs/guides/tasks-store-guards.md`, and the recap is excluded from the docgen scan (kept on disk).
- R13. The dead `tasks-store-guards.html` link (should be `guides/tasks-store-guards.html`) is fixed everywhere it appears.

---

## Planning Contract

### Key Technical Decisions

- **KTD1 — Recap retirement uses `docgen.json`'s existing `exclude` array**, not a file-move workaround. `config.go:19-21` and `page.go:67-80` already implement basename-based exclusion (tested in `build_test.go:29,62`) — the decision buffer incorrectly assumed no such mechanism existed; this corrects that in the implementation, not just the buffer.
- **KTD2 — Guide resolution gets a per-skill override map** threaded through the existing `skills`-kind `IndexSource` (the `case "skills":` closure in `index.go`), falling back to the current `docs/guides/<name>.html` convention when no override is set. This reuses the override pattern `config.go:78-82` already applies to the `tui` kind, rather than inventing a new mechanism.
- **KTD3 — The docgen lint covers well-defined checks (empty guide; orphaned href / duplicate id; general dead links, KTD7), not the buffer's other idea** ("`roadmap.md`'s `updated:` older than the newest commit touching tracked source paths"). Even scoped to non-docs source paths (scripts/, skills, `~/code/docgen`) as the buffer originally framed it, that heuristic still has no clean trigger definition (which commits count as "roadmap-relevant" isn't mechanically decidable) — so it's dropped for this pass rather than built speculatively; R9/R10/KTD7 satisfy the buffer's "make staleness detection code" intent with checks that are cleanly definable. Revisiting a narrower version is a fair follow-up if PR #24/#28-shaped gaps recur (Open Questions).
- **KTD4 — Hub sectioning splits into multiple flat top-level `docgen.json` groups**, reassigning frontmatter only. The alternative (a new subgroup-rendering concept in `hub.go`) is left for later if flat groups prove insufficient — see Scope Boundaries.
- **KTD5 — The `/wb-done` nudge is print-only**, keyed on a small fixed list of roadmap-tracked repo/tag values, never blocking — directly answers the buffer's own "risk of becoming ignorable noise" caution.
- **KTD6 — The passed `~2026-07-13` ceremony clock is surfaced, not resolved**, in U5. Whether the hook-based attention pipeline has held up without regressions is a usage judgment only the requester can make (Open Questions).
- **KTD7 — R10's lint covers general same-repo dead links, not just `#detail-*` fragments.** A doc-review pass on this plan pointed out that a fragment-only anchor check structurally cannot catch the R13 dead-link class (a wrong relative path to a whole other file) — the exact bug this pass needed a manual fix for. Broadened U9 to add a second, independent check rather than leave that gap in the mechanism meant to prevent another one-off pass.

### Assumptions

- The `docgen.json` `skills` `IndexSource`'s `Guide` override field is genuinely unwired for the `skills` kind today (confirmed by reading `index.go`'s `case "skills":` closure during planning — it only checks the conventional path). Re-verify at U6 start per the Goal Capsule's stop condition.
- U8's exact 2-4 group split and names are not fixed here — see Open Questions (OQ2); the mechanism (flat top-level groups) is fixed, the taxonomy is deferred to implementation once the ~25 pages are re-read for natural clusters.

---

## Implementation Units

**Unit Index**

| U-ID | Title | Files (primary) | Depends on |
|---|---|---|---|
| U1 | Roadmap ledger & Live-table currency | `docs/roadmap.md`, `docs/roadmap-board.md` | — |
| U2 | Recap consolidation + dead-link fix | `docs/guides/tasks-store-guards.md`, `docs/docgen.json` | — |
| U3 | 4a/4b capture-window narrative sync | `docs/slice-4b-deep-dive.md`, `docs/guides/notes-tui.md`, `docs/roadmap-day-bookends.md`, `docs/9g-gpaste-recap.md` | — |
| U4 | Status corrections (wb-reconcile, handoff) | `docs/roadmap-wb-reconcile.md`, `docs/handoff-guide.md`, `docs/roadmap-handoff.md` | — |
| U5 | Anchor re-verification + ceremonies check-in | `docs/limitations.md` | — |
| U6 | Guide template + docgen indexer override | `~/code/docgen/config.go`, `index.go`, `docs/docgen.json` | — |
| U7 | Write the 3 missing guides | `docs/guides/wb-resume.md`, `wb-save.md`, `help.md` | U6 |
| U8 | Hub tile sectioning | `docs/docgen.json`, ~25 pages' frontmatter | after U6 (same file) |
| U9 | Docgen lint checks | `~/code/docgen/index.go`, `build.go` | U6 (code); U1-U8 (zero-warnings test) |
| U10 | `/wb-done` roadmap-currency nudge | `claude/.claude/skills/wb-done/SKILL.md` or `wb.sh` | — |

### U1. Roadmap ledger & Live-table currency

**Goal:** bring the Shipped ledger and Live table current with the four decision-buffer resolutions on PR depth and `/handoff` status.
**Requirements:** R1, R2, R3
**Dependencies:** none
**Files:** `docs/roadmap.md`, `docs/roadmap-board.md`
**Approach:** Add three Shipped-ledger bullets (PR #30 board-display-v2, PR #24 `/queue`, PR #28 xdg-open fix) matching the existing bullet shape (`<a id="detail-...">`**Name** — description — links — PR #N`). Move the `/handoff` row from the Live table to the Shipped ledger, updating its status to reflect PR #21 shipping (keep the fan-out-extension note — that part is still genuinely live). Backfill "— PR #20" onto the existing lifecycle-stepper bullet in `docs/roadmap-board.md`'s "What shipped in v2" section, and add one short inline clause each for PR #19 and PR #27 to the Shipped ledger's prose, sized to the roadmap's own "small completed items noted inline" convention — a clause, not a new anchor row.
**Patterns to follow:** the existing Shipped-ledger bullet shape (`docs/roadmap.md`'s Shipped section).
**Test scenarios:** Test expectation: none — content-only edit; verified by reading the rebuilt page.
**Verification:** Shipped ledger lists PR #30/#24/#28 and the migrated `/handoff` entry citing PR #21; the Live table no longer contains `/handoff`; `docs/roadmap-board.md`'s stepper bullet cites PR #20.

### U2. Recap consolidation + dead-link fix

**Goal:** merge the one confirmed-duplicate recap into its guide and fix the dead link it (and the roadmap) both carry.
**Requirements:** R12, R13
**Dependencies:** none
**Files:** `docs/guides/tasks-store-guards.md`, `docs/2026-07-12-tasks-dir-concurrency-safety-recap.md`, `docs/docgen.json`, `docs/roadmap.md`
**Approach:** Fold any content from the recap not already covered by the guide into `docs/guides/tasks-store-guards.md` (the guide is canonical per the buffer's Decision 1). Replace the recap file's body with a short pointer stub noting the merge and linking to the guide. Add the recap's basename to `docs/docgen.json`'s `exclude` array (KTD1) so it drops out of the Hub/INDEX scan while staying on disk. Fix the dead `tasks-store-guards.html` link at `docs/roadmap.md` (and the recap stub) to `guides/tasks-store-guards.html`, matching the already-correct pattern in `docs/wb-guide.md`.
**Patterns to follow:** `docs/wb-guide.md`'s correct relative link to the same guide.
**Test scenarios:** Test expectation: none — content/config change; verify via rebuild.
**Verification:** `docgen.sh all` run; `docs/INDEX.md` has no entry for the merged recap; the tasks-concurrency-safety link resolves.

### U3. 4a/4b capture-window narrative sync

**Goal:** bring the three pages still describing the notes-tui capture-window verdict as pending up to date with its actual early resolution.
**Requirements:** R4
**Dependencies:** none
**Files:** `docs/slice-4b-deep-dive.md`, `docs/guides/notes-tui.md`, `docs/roadmap-day-bookends.md`, `docs/9g-gpaste-recap.md`
**Approach:** In each, replace the "verdict due ~2026-07-14" / "gated on this capture window" framing with: the window resolved early on 2026-07-10 (unused, per `docs/ceremonies.md`'s Resolved section), and 4b's original wiring plan is now superseded by the capture fix-forward experiment (new clock ~2026-07-24). `docs/9g-gpaste-recap.md:147-149` carries the identical stale "slice 4b (gated on the 4a usage-window verdict, ~2026-07-14)" line despite being `status: current`, not archived — update it alongside the other three. Match the phrasing `docs/roadmap.md`'s own current Live-table row and `docs/ceremonies.md` already use, so all pages tell the same story.
**Patterns to follow:** `docs/roadmap.md`'s current Live-table wording for this item; `docs/ceremonies.md`'s Resolved section.
**Test scenarios:** Test expectation: none — content sync.
**Verification:** all four pages plus `docs/roadmap.md`/`docs/ceremonies.md` describe the same state with no contradiction.

### U4. Status corrections (wb-reconcile, handoff)

**Goal:** fix three independently-stale status claims the audit found.
**Requirements:** R4
**Dependencies:** none
**Files:** `docs/roadmap-wb-reconcile.md`, `docs/handoff-guide.md`, `docs/roadmap-handoff.md`
**Approach:** `roadmap-wb-reconcile.md` — replace "scoped, ready to plan — not yet built" with: basic presence-diff/review-apply shipped in PR #14 (`cmd_reconcile()` in `scripts/.config/scripts/tmux/wb.sh`); only the narrower same-commit-duplicate-detection gap stays open. `handoff-guide.md` — fan-out is blocked on wiring `/handoff` to the already-shipped parent/child schema (PR #17), not on the schema being built. `roadmap-handoff.md` — bump the frontmatter `updated:` date and rewrite the header Status line to state v1 shipped 2026-07-11 (PR #21), matching its own later Sequencing section.
**Patterns to follow:** `docs/limitations.md`'s correct "parent/child is live" framing.
**Test scenarios:** Test expectation: none — content correction.
**Verification:** each page's opening status line matches its own later body and the actual PR history.

### U5. Anchor re-verification + ceremonies check-in

**Goal:** refresh `limitations.md`'s stale anchor-check entry, and surface (not resolve) the passed ceremony clock.
**Requirements:** R4
**Dependencies:** none
**Files:** `docs/limitations.md`
**Approach:** Update the "Roadmap anchor/link integrity" entry with today's date and the current counts (verified during planning: `docs/roadmap.md` has 31 `id="detail-*"` anchors and 7 `href="#detail-*"` references, zero orphans, zero duplicates), noting that three edits (PR #22, #26, #29) landed since the last manual check without the re-check this entry itself prescribes. Do not edit `docs/ceremonies.md` — the passed `~2026-07-13` clock's resolution is a usage judgment call left to the requester (KTD6, Open Questions OQ1).
**Test scenarios:** Test expectation: none — verification + doc update.
**Verification:** `docs/limitations.md`'s entry cites today's date and matches a fresh grep count.

### U6. Guide template + docgen indexer override

**Goal:** formalize the existing single-skill guide shape and teach docgen's indexer to resolve guide links for skills whose content lives in a shared, differently-named page.
**Requirements:** R5, R6
**Dependencies:** none
**Files (docgen repo, `~/code/docgen`):** `config.go`, `index.go`, `index_test.go`
**Files (dotfiles repo):** `docs/guide-format.md` (new page naming the convention — not `docs/_templates`, which docgen only ever globs as `*.html` Go-template partials via `loadTemplates`/`ParseGlob` and which isn't one of `docgen.json`'s scanned `pageDirs`; a normal frontmatter page under `docs/` is scanned, rendered, and indexed like every other doc), `docs/docgen.json`
**Approach:** Add a `GuideOverrides map[string]string` (skill name → guide path) to the `skills`-kind `IndexSource` in `config.go`, near the existing `Guide` override field that today only serves the `tui` kind. Thread it into the closure passed to `parseSkills`: check the override map first — validated with the same `os.Stat` check the fallback uses, falling through to `""` if the override path doesn't exist so U9's empty-guide warning still fires on a stale override — then fall back to the existing `docs/guides/<name>.html` stat check when no override is set. Populate `docs/docgen.json`'s `skills` source with overrides for `wb-done`, `wb-breakdown`, `wb-board` (in-page anchors within `docs/wb-guide.html`) and `handoff` (the whole `docs/handoff-guide.html` page, no fragment — it has no `id="handoff"` anchor and doesn't need one, since the page is entirely about `/handoff` already). Write `docs/guide-format.md` naming the 5-section single-skill shape (Overview / Try it now / Reference / Known rough edges / Next steps) already followed by 6 of 8 existing guide pages as the standard, and naming the shared command-family guide (what `wb-guide.md`/`handoff-guide.md` already are) as the explicit alternate shape.
**Technical design (directional):**
```go
case "skills":
    got, err = parseSkills(abs, src.Path, func(name string) string {
        if p, ok := src.GuideOverrides[name]; ok {
            if _, statErr := os.Stat(filepath.Join(root, p)); statErr == nil {
                return p
            }
            return ""
        }
        guide := filepath.Join("docs", "guides", name+".html")
        if _, statErr := os.Stat(filepath.Join(root, guide)); statErr == nil {
            return guide
        }
        return ""
    })
```
**Patterns to follow:** the existing `tui`-kind override pattern in `config.go`'s `IndexSource.Guide` field; `index_test.go`'s fixture-based skills tests.
**Test scenarios:**
- Happy path: a skill with a configured override pointing at a real file resolves `Guide` to the override path (new fixture test in `index_test.go`).
- Edge: a skill with an override pointing at a non-existent file resolves to `""`, not the dead path — matches U9's empty-guide warning firing rather than silently shipping a broken link.
- Edge: a skill with no override and no `docs/guides/<name>.html` resolves to `""` — existing behavior must not regress.
- Edge: a skill with no override but a real `docs/guides/<name>.html` still resolves via the conventional path.
- Integration: running `docgen.sh index` against this repo's `docs/docgen.json` produces a non-empty `guide` in `docs/INDEX.md` for `wb-done`, `wb-breakdown`, `wb-board`, `handoff`.
**Verification:** `go test ./...` passes in `~/code/docgen`; `docgen.sh all` (with `DOTFILES` exported) regenerates `docs/INDEX.md` with all four overridden skills showing a non-empty guide.

### U7. Write the 3 missing guides

**Goal:** give `wb-resume`, `wb-save`, and `help` genuine guide content (currently zero anywhere).
**Requirements:** R7
**Dependencies:** U6
**Files:** `docs/guides/wb-resume.md`, `docs/guides/wb-save.md`, `docs/guides/help.md`
**Approach:** Write each in the U6-formalized shape, sourced from the skill's own `SKILL.md` plus actual behavior: `wb-resume` (reads the task's `## Handoffs` log via tmux `@task`, distinguishes rich vs. terse entries), `wb-save` (writes a structured handoff snapshot before `/clear`), `help` (reads `docs/INDEX.md` and follows provenance links, contrasted with the deterministic `prefix+?` picker). No `docgen.json` change needed — these land at the conventional path U6's fallback already checks.
**Patterns to follow:** `docs/guides/park.md` / `docs/guides/parked-items.md` as the closest-shaped existing examples.
**Test scenarios:** Test expectation: none — new content, right-sized to the convention's typical length.
**Verification:** all three files parse with valid frontmatter; after a rebuild, `docs/INDEX.md` shows a non-empty guide for `wb-resume`, `wb-save`, `help` via the unmodified conventional path.

### U8. Hub tile sectioning

**Goal:** split the 25-tile "Personal workflow" Hub group into multiple top-level groups.
**Requirements:** R8
**Dependencies:** run after U6 (same `docs/docgen.json` file, different section — sequencing avoids a merge conflict, not a logical dependency); the "25-tile" figure below assumes U2 has already excluded the merged recap — as of planning the group holds 26 tagged items (24 `docs/*.md` pages + 1 `docs/guides` page + the "Task board" sidecar tile) until U2 lands
**Files:** `docs/docgen.json`; the `group:` frontmatter line in the affected `docs/*.md` pages currently tagged `personal-workflow`
**Approach:** Replace the single `"personal-workflow"` entry in `docs/docgen.json`'s `hub.groups` with 2-4 new groups reflecting what's actually in the flat list (exact split deferred to implementation — OQ2), then reassign each affected page's `group:` field to its new key. Also reassign `docs/docgen.json`'s `hub.sidecar` "Task board" tile's `"group": "personal-workflow"` to one of the new keys — `hub.go`'s `buildHub` folds sidecar tiles into the same group map as frontmatter pages and hard-errors on an orphaned group key, so missing this would break the build. No other change to `hub.go`'s rendering — it already iterates `cfg.Hub.Groups` generically.
**Patterns to follow:** the existing 4-group `hub.groups` array shape in `docs/docgen.json`.
**Test scenarios:** Test expectation: none — config + frontmatter change.
**Verification:** `docgen.sh build` succeeds (every `group:` value has a matching `hub.groups` entry, per the existing hard-error check in `hub.go`); `docs/HUB.html` renders 2-4 sections instead of one 25-tile block.

### U9. Docgen lint checks

**Goal:** make the guide-gap and anchor/href-integrity checks automatic instead of manual.
**Requirements:** R9, R10
**Dependencies:** U6 (for the lint code itself); the zero-warnings integration test additionally requires U1-U8 to have landed first
**Files (docgen repo):** `index.go`, `build.go`, `index_test.go`, `build_test.go`
**Approach:** In the guide-resolution closure from U6, log a non-fatal warning when resolution returns `""` for a skill. Add a check — run against any page whose rendered HTML contains `id="detail-` anchors — that collects all `id="detail-<slug>"` and `href="#detail-<slug>"` occurrences and warns on any orphaned href or duplicate id, scoped per rendered page (matching how fragment links actually resolve in a browser). Add a second, separate check across every rendered page: collect same-repo relative `href`s (excluding external/`mailto:`/bare-fragment links) and warn on any that resolve to no file on disk — this is the general dead-link class R13 needed a manual fix for this pass, which the fragment-only check above can't catch (KTD7). All warnings print during `docgen.sh build`/`index` without failing the build.
**Test scenarios:**
- Happy path: a skill with a resolved guide produces no warning.
- Edge: a skill with an empty guide produces exactly one warning naming the skill.
- Happy path: a page with matched ids/hrefs produces no anchor warning.
- Edge: a page with an orphaned href produces exactly one warning naming it.
- Edge: a page with a duplicate id produces exactly one warning naming it.
- Happy path: a page whose relative links all resolve to real files produces no dead-link warning.
- Edge: a page with a relative link to a non-existent file produces exactly one warning naming the broken link (the R13 shape).
- Integration: running `docgen.sh all` against this repo's `docs/` post-U1-U8 produces zero warnings of any of the three kinds.
**Verification:** `go test ./...` passes in `~/code/docgen`; a manual `docgen.sh all` run against this worktree shows no warnings once U1-U8 have landed.

### U10. `/wb-done` roadmap-currency nudge

**Goal:** catch future ledger/Live-table drift at the moment a task closes, complementing U9's build-time lint.
**Requirements:** R11
**Dependencies:** none
**Files:** `claude/.claude/skills/wb-done/SKILL.md` or `scripts/.config/scripts/tmux/wb.sh` (confirm which owns the finish-path text during implementation)
**Approach:** After a successful `wb done`, match on the closing task's `repo:` field (a clean scalar via `wb_get_frontmatter`) against a small fixed list of roadmap-tracked repos (e.g. `dotfiles`, `docgen`) — not a raw-substring match against the bracketed `tags:` text, which could false-positive on an unrelated tag. Print one non-blocking line suggesting a `docs/roadmap.md` check. No new frontmatter field, no gating — a single line, per KTD5.
**Test scenarios:**
- Happy path: closing a `dotfiles`-repo task prints the nudge.
- Edge: closing a task in an unrelated repo prints nothing.
**Verification:** manually run `wb done` against a matching and a non-matching test task; confirm the nudge fires only for the former.

---

## Scope Boundaries

- Not redesigning `docs/roadmap.md`'s core Up-next/Live/Parked/Not-doing/Shipped grammar — this plan extends it, matching the buffer's own framing.
- Not building the generic "`roadmap.md` `updated:` vs. commit history" staleness heuristic — dropped per KTD3 as ill-defined.
- Not adding a new subgroup-rendering concept to docgen's Hub template — flat top-level groups only (KTD4); the richer concept is left for later if flat groups prove insufficient.

### Deferred to Follow-Up Work

- Resolving the passed `~2026-07-13` `tmux_pane_awaiting_input` ceremony clock — needs the requester's own usage judgment (OQ1).
- The `/queue` task's own follow-up (a `wb done` flow explicitly listing queued items as "deferred") — out of scope here.
- Deeper merges of `wb-board-display-v2-recap.md` / `wb-breakdown-recap.md` into their detail pages — the buffer's Decision 1 already ruled these stay standalone (verified distinct content).

## Open Questions

- **OQ1 (deferred, non-blocking):** should the `~2026-07-13` `tmux_pane_awaiting_input` ceremony clock resolve now? Needs the requester's call on whether the hook-based attention pipeline has held up without regressions — independent of the rest of this plan.
- **OQ2 (deferred, non-blocking):** exact 2-4 group split and names for U8 — the mechanism (multiple top-level `docgen.json` groups) is decided; the taxonomy is finalized during implementation once the ~25 pages are re-read for natural clusters.
- **OQ3 (deferred, non-blocking):** if a PR #24/#28-shaped gap (real code shipped, roadmap untouched) recurs after this plan, revisit a narrower version of the heuristic KTD3 dropped — scoped only to non-docs source paths — as a fourth docgen lint check.

---

## Verification Contract

| Command / check | Applies to | Gate |
|---|---|---|
| `go test ./...` (run in `~/code/docgen`) | U6, U9 | must pass |
| `docgen.sh all` (export `DOTFILES=$(git rev-parse --show-toplevel)` from this worktree) | all units | must exit 0, zero U9 lint warnings |
| `docs/INDEX.md` shows non-empty `guide` for all 7 previously-empty skills | U6, U7 | manual read after rebuild |
| `docs/HUB.html` shows 2-4 sections in place of the 25-tile block | U8 | manual read after rebuild |
| Manual link spot-check on the U2 dead link | U2 | no 404 |
| Manual `wb done` smoke test (matching + non-matching task) | U10 | nudge fires only for matching |

## Definition of Done

- R1-R13 all satisfied.
- `docgen.sh all` runs clean with zero U9 lint warnings.
- `go test ./...` passes in `~/code/docgen`.
- No dead-end config left over (e.g., if U8's group split changes during implementation, superseded `docgen.json` entries are removed, not left alongside the final ones).
- OQ1 and OQ2 are either resolved or left explicitly open in the shipped docs — not silently dropped.
