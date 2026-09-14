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
- There is no `--reattach` equivalent yet — if the backgrounded process dies
  mid-review, the state file is left with `closed=0` and a dead `caller_pid`;
  treat that the same way `open-buffer.sh`'s PaneGone case is treated: read
  `answers.json` if it exists (it won't, if the process died before submit),
  otherwise report the close as not deliberate and ask before re-running.

## Spec format (`spec.json`, written by the agent before invoking the script)

```json
{
  "title": "Short page title",
  "intro_md": "Short 'how to read this' block — markdown-ish (**bold**, `code`, newlines).",
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
          "links": [{"label": "PR #12", "href": "https://..."}]
        }
      ]
    }
  ],
  "close_rule": "One or two sentences on what happens to touched vs untouched rows — shown inline in the intro box."
}
```

**Richer rows (added 2026-09-14, first use: the wb-breakdown proposal page).** All optional, per item unless noted:

- `meta`: list of `[label, value]` pairs (or a dict). Rendered as compact monospace chips under the title — structured facts the reviewer should see without expanding anything (size, slug, stage path, deps count). Empty values are dropped; list values join with ", ".
- `description`: a long markdown body (paragraphs, `- ` bullets, `1.` lists, `#`..`####` headings, ``` fences, inline **bold**/`code`). Rendered in a collapsed **details** row under the item; toggled by the row's "details ▸" button, `d` on the focused row, `D` / the "expand all details" button for every visible row. Use it for the thing the verdict is really about (a proposed child's Plan body, a finding's full write-up) — evidence stays the short, checkable list.
- `fields`: list of `{key, label, value, placeholder, wide}` — editable text inputs shown at the top of the details row. Their current values come back in answers under `item.fields` (`{key: value}`) with `item.fields_changed` true when any differs from what the spec set; editing a field marks the row touched. This is how a page can drive a downstream grammar (e.g. a breakdown child's slug/goal/size) without a second buffer.
- Spec-level `sections`: list of `{title, md, open}` rendered as collapsible panels between the intro box and the first table — a directions summary, a glossary, "how your answers map onto the apply step". Closed unless `open: true`. Not a substitute for `intro_md`'s six lines; it is where the longer context lives.
- Spec-level `hide_columns`: list of column keys among `what`, `evidence`, `deps`, `group`, `note` to hide when a review does not use them, freeing width for the rest.

Every `item.id` must be unique across the whole spec (dep chips and row anchors
are keyed on it). `suggested` may be `""` (no default) — the page then leaves no
verdict pre-selected and counts that row as "needs me" automatically.

Each row also has an **Agree ✓** button beside the verdict radios, for the
common case of reviewing many rows where the suggested verdict is simply
right — clicking it sets `verdict=suggested` and `touched=true` (a subtle
green left accent marks the row), and clicking again untouches it. Keyboard:
`a` agrees with the keyboard-focused row, `A` (shift) agrees with every
currently *visible* (filtered) row at once. **The Agree button is a
convenience, not a requirement** — see the contract below: leaving a row
alone already accepts its suggestion, Agree just marks it touched so it
doesn't read as something you missed. A sticky footer badge ("untouched: N")
tracks rows never interacted with — including via Agree — purely as a
visibility aid, not a warning. The footer's "accept remaining defaults for
untouched rows" checkbox is **pre-ticked by default** (`accept_defaults_default`
defaults to `true`; set it to `false` in the spec to require an explicit
tick). Submit only warns when that checkbox has been unticked AND N>0 — the
opposite direction from what you might expect from an nvim decision-buffer,
where silence means nothing happens. Here, silence means "I accept the
suggestion" (see Close semantics below).

## Answers format (`answers.json`, written by the script, read by the agent)

```json
{
  "spec_hash": "sha256 of the exact spec.json bytes the page was rendered from",
  "accept_defaults": true,
  "global_note": "free text from the footer's 'questions for the agent' box, or empty",
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
   the user unticked the footer checkbox) → only `touched` rows apply.**
   Untouched rows get no action at all — not even their `suggested` default.
   This is the one case where silence is read as "not yet decided," not as
   consent — it only applies when the checkbox is explicitly off.
5. **A submit with zero touched rows and `accept_defaults=false` applies
   nothing.** Report this plainly rather than treating it as an empty-but-valid
   result — it usually means the user looked and left without deciding, not
   that they agreed with every default.

`group` values are free text the user chose per row (via the "same as ↑"
button or by typing) — treat rows sharing a non-empty `group` value as a
cluster the user intends to be handled together, but don't infer meaning
beyond "these belong together" from the text itself.

## When it earns its place vs. a companion HTML

This page IS the interactive artifact — it never gets a separate companion
HTML the way decision-buffer's `choice.md`/`findings-review.md` sometimes do
(§11 of decision-buffer's SKILL.md). Don't write both a review-page spec and a
companion doc for the same review.
