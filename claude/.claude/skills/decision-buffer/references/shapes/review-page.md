# Shape: Review Page

The seventh shape. For a batch too large or too structured for a markdown buffer —
more than ~25 rows, or when what's needed is per-row defaults (a suggested verdict
per item), free-text grouping, AND per-row questions all at once. A markdown buffer
with 40+ checkbox blocks is unreadable and slow to scan; this shape trades the nvim
buffer for a locally-served HTML page with filtering, keyboard navigation, and a
submit button, while keeping the same open/wait/parse contract as every other shape.

Use `findings-review.md` or `code-review-triage.md` instead for a small batch (under
~25 items) with no grouping/defaults need — this shape's extra machinery (a local
HTTP server, a spec file, a browser tab) isn't worth it below that size.

## Mechanism (differs from the nvim-buffer shapes)

This shape does NOT call `scripts/open-buffer.sh`. It calls
`scripts/review-page.py` instead, which mirrors the same contract described in
`references/mechanism.md` — same state-file fields, same "always run backgrounded"
rule, same `tmux wait-for` signal on close — but serves a page over
`http://127.0.0.1:<port>` rather than opening nvim in a tmux pane or terminal.

**Why HTTP, not `file://`:** snap-packaged Chromium cannot open `file://` URLs
under hidden directories (a documented environment limitation) — serving over
`127.0.0.1` sidesteps this entirely, so it's not a decision to revisit per-use.

Invoke exactly like this, as a **backgrounded** Bash call:

```bash
python3 claude/.claude/skills/decision-buffer/scripts/review-page.py \
  --spec /path/to/spec.json --out /path/to/answers.json --title "Something Review"
# run_in_background: true — this blocks until the page POSTs /submit
```

- `--port auto` (the default) picks a free port; pass a specific port only if
  the caller has a reason to.
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

Every `item.id` must be unique across the whole spec (dep chips and row anchors
are keyed on it). `suggested` may be `""` (no default) — the page then leaves no
verdict pre-selected and counts that row as "needs me" automatically.

Each row also has an **Agree ✓** button beside the verdict radios, for the
common case of reviewing many rows where the suggested verdict is simply
right — clicking it sets `verdict=suggested` and `touched=true` (a subtle
green left accent marks the row), and clicking again untouches it. Keyboard:
`a` agrees with the keyboard-focused row, `A` (shift) agrees with every
currently *visible* (filtered) row at once. A sticky footer badge
("untouched: N") tracks rows never interacted with — including via Agree —
and Submit warns before submitting with `accept_defaults` unticked and N>0.
Set top-level spec flag `"accept_defaults_default": true` to pre-tick that
footer checkbox (default `false`).

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
      "note": ""
    }
  ]
}
```

`spec_hash` lets the agent confirm the answers correspond to the spec it wrote —
compare it against a fresh hash of the spec file; a mismatch means the page was
reloaded against a stale spec and the answers should not be trusted without
asking first.

## Close semantics — read in this order

1. **A non-empty `global_note` is answered before anything else is acted on.**
   It applies to the whole review, not one row — treat it like a blocking
   question, the same way an unresolved note blocks its own row (below).
2. **Any item with a non-empty `note` must be answered before its verdict is
   acted on**, regardless of what `verdict` or `touched` say for that row. A
   question attached to a row means the row isn't settled yet, even if a
   verdict was also picked.
3. **`accept_defaults=false` → only `touched` rows apply.** Untouched rows
   (the ones where the user never interacted with the verdict, group, or note
   fields) get no action at all — not even their `suggested` default. Silence
   is never read as consent, same rule as every other shape.
4. **`accept_defaults=true` → untouched rows take their `suggested` verdict.**
   This only fires for rows that still have a non-empty `suggested` value —
   a row with no suggestion and no interaction stays unresolved and should be
   flagged back to the user rather than silently skipped.
5. **A submit with zero touched rows and `accept_defaults=false` applies
   nothing.** Report this plainly rather than treating it as an empty-but-valid
   result — it usually means the user looked and left without deciding, not
   that they agreed with every default.

`group` values are free text the user chose per row (via the "same as ↑"
button or by typing) — treat rows sharing a non-empty `group` value as a
cluster the user intends to be handled together, but don't infer meaning
beyond "these belong together" from the text itself.

## When it earns its place vs. a companion HTML

This shape IS the interactive artifact — it never gets a separate companion
HTML the way `choice.md`/`findings-review.md` sometimes do (§11 of SKILL.md).
Don't write both a review-page spec and a companion doc for the same review.
