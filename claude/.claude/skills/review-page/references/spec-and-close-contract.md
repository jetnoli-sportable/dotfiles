# review-page: spec format and close contract

The mechanism this skill uses in place of a markdown buffer, for a batch too
large or too structured for one — more than ~25 rows, or when what's needed is
per-row defaults (a suggested verdict per item), free-text grouping, AND
per-row questions all at once. A markdown buffer with 40+ checkbox blocks is
unreadable and slow to scan; this shape trades the nvim buffer for a
locally-served HTML page with filtering, keyboard navigation, and a submit
button, while keeping the same open/wait/parse contract as decision-buffer's
own shapes.

Use `decision-buffer`'s `findings-review.md` or `code-review-triage.md`
instead for a small batch (under ~25 items) with no grouping/defaults need —
this shape's extra machinery (a local HTTP server, a spec file, a browser tab)
isn't worth it below that size.

## Mechanism (differs from the nvim-buffer shapes)

This does NOT call decision-buffer's `scripts/open-buffer.sh`. It calls this
skill's own `scripts/review-page.py` instead, which mirrors the same contract
described in decision-buffer's `references/mechanism.md` — same state-file
fields, same "always run backgrounded" rule, same `tmux wait-for` signal on
close — but serves a page over `http://127.0.0.1:<port>` rather than opening
nvim in a tmux pane or terminal.

**Why HTTP, not `file://`:** snap-packaged Chromium cannot open `file://` URLs
under hidden directories (a documented environment limitation) — serving over
`127.0.0.1` sidesteps this entirely, so it's not a decision to revisit per-use.

Invoke exactly like this, as a **backgrounded** Bash call:

```bash
python3 claude/.claude/skills/review-page/scripts/review-page.py \
  --spec /path/to/spec.json --out /path/to/answers.json --title "Something Review"
# run_in_background: true — this blocks until the page POSTs /submit
```

- **A row note marks the row touched** (Jet, 2026-09-14): its verdict stands as displayed —
  the suggestion, or whatever was picked — and the note is answered before that verdict is
  acted on. Notes are never treated as silence.
- Default port 8765 (stable URL); falls forward to the next free port if busy; `--port N`
  overrides.
- **The server binds before it prints the URL or opens a browser** (2026-09-14 review): on
  `EADDRINUSE` it retries the next port up to ten times, so a lost race for 8765 can never
  leave a dead tab open.
- **`/submit` verifies the request is this review's own page** (2026-09-14 review):
  a cross-origin `Origin`/`Referer` → 403; a non-`application/json` body → 415; a body whose
  `spec_hash` differs from the hash this server rendered → 409 (a stale tab from an earlier
  review on the same port, or a forged POST); a second submit after the first → 409. Only a
  passing body is written to `answers.json` and fires the wait channel. A bare `curl` with no
  Origin header is allowed (agent/test use).
- The script writes `<answers.json>.buffer-state` beside the output file, with
  the same fields as `open-buffer.sh`'s state file (`chan`, `pane_id`, `mode`,
  `opened_at`, `caller_pid`, `content_hash`, `reopen_count`, `closed`) —
  `mode=review-page` always, `pane_id` always empty (there is no tmux pane; the
  "pane" is a browser tab talking to a local server, which this state file
  format has no field for and doesn't need one for).
- It opens the page itself (`/snap/bin/chromium` if present, else `xdg-open`) —
  the agent does not open a browser separately.
- It blocks synchronously until the page's Submit button POSTs to `/submit`,
  then writes `answers.json`, rewrites the state file to `closed=1`, runs
  `tmux wait-for -S <chan>` if tmux is present (so a caller that also waits on
  the channel unblocks the same way it would for any other shape), and exits 0.
- `python3 review-page.py --reattach <answers.json>` resumes the wait recorded
  by an earlier invocation of the same `--out` path — mirrors
  `open-buffer.sh --reattach`'s decision tree, adapted for a browser tab
  instead of a tmux pane (there's no pane/nvim-process to probe, only the
  state file and the backgrounded script's own `caller_pid`):
  - `closed=1` (a normal prior close) → prints `<answers.json>`'s path and
    exits 0. Closed always implies the file is already on disk — a normal
    close writes `answers.json` before rewriting the state file.
  - `closed=0` and `caller_pid` is dead → the process died before submit;
    exits 3 with "page process died before submit — re-run" and writes
    nothing. Re-run the original invocation (same `--spec`/`--out`) rather
    than reattaching again.
  - `closed=0` and `caller_pid` is alive → re-waits for the same close
    signal the original invocation would have waited on itself (`tmux
    wait-for <chan>` when tmux and `$TMUX` are available, otherwise polls
    the state file once a second) and exits 0 once it flips to `closed=1`,
    or 3 if the process dies while `--reattach` is still waiting.
  - No state file at all → nothing to reattach; exits 1.

## Spec format (`spec.json`, written by the agent before invoking the script)

```json
{
  "title": "Short page title",
  "intro_md": "Short 'how to read this' block. Paragraphs split at blank lines: the first shows, the rest fold away.",
  "context": {
    "task": "repo--task-slug",
    "here": "this page",
    "stages": [
      {"name": "Round 1", "state": "done"},
      {"name": "Round 2", "state": "current", "note": "this page"},
      {"name": "Apply the verdicts", "state": "upcoming"}
    ]
  },
  "verdicts": [
    {"id": "apply", "label": "Apply", "color": "#a6e3a1"},
    {"id": "defer", "label": "Defer", "color": "#f9e2af"},
    {"id": "skip", "label": "Skip", "color": "#f38ba8"}
  ],
  "areas": [
    {
      "id": "area-a",
      "title": "Area A",
      "note": "Optional one-liner shown under the area heading.",
      "items": [
        {
          "id": "item-1",
          "title": "One-line item title",
          "where": "file.py:123",
          "what": "What this item is / claims / proposes.",
          "evidence": "A string, or a list of strings, shown behind an 'evidence' toggle.",
          "suggested": "apply",
          "suggested_reason": "Why this verdict is pre-selected — state 'unclear' explicitly if genuinely unclear.",
          "depends_on": ["item-0"],
          "depended_on_by": ["item-2"],
          "links": [{"label": "PR #12", "href": "https://..."}],
          "prior": {"note": "Jet's note from the earlier round.", "reply": "The answer, shown under the note."}
        }
      ]
    }
  ],
  "close_rule": "One or two sentences on what happens to touched vs untouched rows — shown inline in the intro box."
}
```

**Richer rows (added 2026-09-14, first use: the wb-breakdown proposal page).** All optional, per item unless noted:

- `meta`: list of `[label, value]` pairs (or a dict). Rendered as compact monospace chips under the title — structured facts the reviewer should see without expanding anything (size, slug, stage path, deps count). Empty values are dropped; list values join with ", ".
- `description`: a long markdown body (paragraphs, `- ` bullets, `1.` lists, `#`..`####` headings, ``` fences, inline **bold**/`code`). Rendered inside the row's collapsed **Evidence and details** block (open it with `e`/`o`, Enter on the row, or `E` for every visible row). Use it for the thing the verdict is really about (a proposed child's Plan body, a finding's full write-up) — evidence stays the short, checkable list.
- `fields`: list of `{key, label, value, placeholder, wide}` — editable text inputs shown at the top of the details block. Their current values come back in answers under `item.fields` (`{key: value}`) with `item.fields_changed` true when any differs from what the spec set; editing a field marks the row touched. This is how a page can drive a downstream grammar (e.g. a breakdown child's slug/goal/size) without a second buffer.
- `prior`: `{note, reply}` — an earlier note of Jet's on this row and the answer to it. The row gets an "Earlier note" marker and shows both under the suggestion. With no `prior`, no marker renders.
- Spec-level `context`: `{task, here, stages: [{name, state, note?}]}`, the same shape as decision-page's. `state` is one of `done`, `current`, `upcoming`, `later`; at most one stage is `current`. Rendered as the "Where this sits" strip at the top of the overview band. Without it, no strip renders.
- Spec-level `sections`: list of `{title, md, open}` rendered as collapsible panels between the title and the overview band — a directions summary, a glossary, "how your answers map onto the apply step". Closed unless `open: true`. Not a substitute for `intro_md`'s six lines; it is where the longer context lives.
- Per-verdict `color` is no longer used: verdict colours come from the page's theme tokens so they stay readable in light and dark. A long `label` is cut at " — " or " (" for the button, and the full label shows on hover.
- Spec-level `hide_columns` is retired: the page is no longer a table, and no caller ever set it. A spec that still carries it renders normally; the key is ignored.

Every `item.id` must be unique across the whole spec (dep chips and row anchors
are keyed on it). `suggested` may be `""` (no default) — the page then leaves no
verdict pre-selected and counts that row as "needs me" automatically.

Each row also has an **Agree** button beside the verdict buttons, for the
common case of reviewing many rows where the suggested verdict is simply
right — clicking it marks the row agreed (`verdict=suggested`, `touched=true`),
and clicking again undoes it; it is disabled on a row with no suggestion.
**Agree to all in this area** agrees every row of that area that has a
suggestion and does not need you (a row with no suggestion, or whose reason
says "unclear", is skipped). **The Agree button is a convenience, not a
requirement** — see the contract below: leaving a row alone already accepts its
suggestion, Agree just marks it reviewed so it doesn't read as something you
missed. The sidebar's progress counts rows that were agreed or answered; its
"Needs you" box counts rows that still need you and `u` jumps to the next one.
The close-out block's "Accept remaining defaults" checkbox is **pre-ticked by
default** (`accept_defaults_default` defaults to `true`; set it to `false` in
the spec to require an explicit tick; a choice saved in the browser for this
spec wins on reload). Submit only warns when that checkbox has been unticked
AND some rows are untouched — the opposite direction from what you might expect
from an nvim decision-buffer, where silence means nothing happens. Here,
silence means "I accept the suggestion" (see Close semantics below).

A row **needs you** when its `suggested` is empty or its `suggested_reason`
contains "unclear"; the flag clears once the row is agreed or answered.

## The page: layout and keys

Rendered in the browser on the page kit shared with decision-page
(`decision-page/kit/`), so the two pages use one look and one key map; a key
never means different things on the two.

- **Overview band** at the top: the "Where this sits" strip (from `context`), at-a-glance counts with a chip per suggested verdict, a plain statement of what untouched rows do, and the intro (first paragraph, the rest and `close_rule` folded).
- **Collapsible left sidebar** (`[`): progress, needs you (with next), overrides, verdict tallies (click one to filter by final verdict), and search with an area filter.
- **Rows grouped by area**, each area with its `note` and "Agree to all in this area". A row shows its task title, `where`, `meta` chips, dependency chips, links, the suggested verdict with its reason, the verdict control, Agree, and Note / Group toggles. Evidence, `description` and `fields` are collapsed.
- **Close-out block** at the end of the content column: accept remaining defaults, the global questions box, Submit and Copy JSON. It is never fixed to the screen, so the sidebar never overlaps it.

| Key | Does |
|---|---|
| `j` / `k` | next / previous stop: overview, each visible row, the close-out block |
| `Enter` | on the overview: first row that needs you; on a row: toggle its details; on the close-out block: Submit |
| `1`-`9` | pick the n-th verdict |
| `a` | agree with the suggestion (again to undo) |
| `c` | clear the row back to untouched (verdict, agree, group, note, and edited fields) |
| `n` | open the note (the global questions box on the close-out block) |
| `g` / `t` | open the group tag |
| `e` / `o` | toggle this row's evidence and details |
| `E` | expand / collapse every visible row's details |
| `u` | jump to the next row that needs you |
| `/` | focus search |
| `[` | collapse / expand the sidebar |
| `?` / `Esc` | show / hide the key list; leave a text box |

No key fires while typing in a text box. **Retired keys** (they now mean nothing): `A` (agree with every visible row — replaced by the per-area button), `d` / `D` (details — now `e` / `E`). The filters "needs me", "touched only", "untouched only" and "suggested verdict", the "same as above" group button and the sticky footer are gone with the table layout.

Progress is saved in the browser under `review-page:<spec_hash>`, so reloading the tab keeps answers and two different reviews never share them.

## Answers format (`answers.json`, written by the script, read by the agent)

```json
{
  "spec_hash": "sha256 of the exact spec.json bytes the page was rendered from",
  "accept_defaults": true,
  "global_note": "free text from the close-out block's 'questions for the agent' box, or empty",
  "untouched_count": 0,
  "items": [
    {
      "id": "item-1",
      "verdict": "apply",
      "suggested": "apply",
      "touched": true,
      "group": "g1",
      "note": "",
      "fields": {"slug": "feat/x", "size": "M"},
      "fields_changed": false
    }
  ]
}
```

`spec_hash` lets the agent confirm the answers correspond to the spec it wrote —
compare it against a fresh hash of the spec file; a mismatch means the page was
reloaded against a stale spec and the answers should not be trusted without
asking first.

## Close semantics — read in this order

**The headline rule, stated once up front because it inverts the nvim
decision-buffer default:** in this flow, **no action on a row means accept
its suggested verdict.** Opt-out is an explicit act — a changed verdict, a
row note, or a word in the global questions box — never silence. This is the
*opposite* of decision-buffer's nvim shapes, where a silent close applies
nothing. Every review-page intro must say this plainly ("leaving a row alone
accepts its suggestion") so it's never assumed from memory.

1. **A non-empty `global_note` is answered before anything else is acted on.**
   It applies to the whole review, not one row — treat it like a blocking
   question, the same way an unresolved note blocks its own row (below).
2. **Any item with a non-empty `note` must be answered before its verdict is
   acted on**, regardless of what `verdict` or `touched` say for that row. A
   question attached to a row means the row isn't settled yet, even if a
   verdict was also picked. A row note is the correct way to opt a row out of
   the "no action = accept" default.
3. **`accept_defaults=true` (the default) → untouched rows take their
   `suggested` verdict.** This only fires for rows that still have a
   non-empty `suggested` value — a row with an **empty** `suggested` (no
   signal) that's also untouched is **unresolved**, never defaulted; flag it
   back to the user and re-ask rather than silently skipping or applying
   anything.
4. **`accept_defaults=false` (spec set `accept_defaults_default: false`, or
   the user unticked the close-out checkbox) → only `touched` rows apply.**
   Untouched rows get no action at all — not even their `suggested` default.
   This is the one case where silence is read as "not yet decided," not as
   consent — it only applies when the checkbox is explicitly off.
5. **A submit with zero touched rows and `accept_defaults=false` applies
   nothing.** Report this plainly rather than treating it as an empty-but-valid
   result — it usually means the user looked and left without deciding, not
   that they agreed with every default.

`group` values are free text the user chose per row (by typing, with earlier tags offered as suggestions) — treat rows sharing a non-empty `group` value as a
cluster the user intends to be handled together, but don't infer meaning
beyond "these belong together" from the text itself.

## When it earns its place vs. a companion HTML

This page IS the interactive artifact — it never gets a separate companion
HTML the way decision-buffer's `choice.md`/`findings-review.md` sometimes do
(§11 of decision-buffer's SKILL.md). Don't write both a review-page spec and a
companion doc for the same review.
