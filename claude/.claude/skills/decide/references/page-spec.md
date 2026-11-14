# Page spec

The `/decide` page (`page/page.html`) is one fixed template. It draws whatever
`spec.json`, published beside it, describes, and it never runs model-written
script. Check a spec with `wb decide-spec-check <spec.json> [--previous <spec.json>]`
before publishing. Evidence that needs real interaction goes in its own page,
linked from the item.

## Top level

| Field | Required | Meaning |
|---|---|---|
| `title` | yes | The heading on the page. |
| `layout` | yes | `"items"`: each item has its own options. `"verdicts"`: every item takes one of a shared list. |
| `items` | yes | The questions, in order. |
| `verdicts` | `verdicts` layout | At least two `{ "id", "label", "tone"? }`. `tone` is one of `neutral` (default), `good`, `bad`, `info`, `warn`: the colour the verdict takes once chosen. |
| `rev` | no | A string or number, default `"1"`. Bump it on every republish. The Submit comment and `meta/submitted` carry it. |
| `base` | no | The parent task file's checksum at publish time. The page only carries it into `meta/submitted`; the skill's script compares it. |
| `intro` | no | One or two sentences under the title. |
| `task` | no | The task stem, shown above the title. |
| `name` | no | The two-to-four-word artifact name. The skill copies it into the page's `<title>` (see Title). |
| `links` | no | `[{ "label", "href" }]` evidence-page chips under the intro, such as a compare page. |
| `prior` | no | The previous-round callout: `{ "round"?, "note"?, "reply"? }`, Jet's earlier note and the answer to it. |
| `sections` | no | Collapsible panels above the questions, such as a glossary or directions: `[{ "title", "text", "open"? }]`. Closed unless `open` is true. `text` follows the text rules below. |
| `decided` | no | Already-decided items, shown read-only in a closed panel: `[{ "id"?, "title", "decision", "date"?, "note"? }]`. They are not answered and not counted. |
| `global_note` | no | The whole-batch note box shows by default. `false` hides it; `{ "label"?, "placeholder"? }` renames it. |

Text fields (`intro`, `context`, section `text`, text blocks): blank lines split
paragraphs, a paragraph whose lines all start `- ` is a list, and `` `backticks` ``
mark code. Everything is set as text, never as HTML.

## An item

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Short and stable, unique in the spec. It names the answer document. |
| `title` | yes | The question. Becomes the Decisions entry title. |
| `options` | `items` layout | At least two `{ "id", "label", "detail"?, "recommended"? }`. Each `detail` says the option's pro and con. Mark one `recommended` when you have a view. |
| `suggested` | no, `verdicts` layout | A verdict id. The row marks it "Suggested" but it applies only when Jet accepts it. |
| `reason` | no, but required with `suggested` on a `verdicts` item | One line shown on the collapsed card: why the suggestion. |
| `default` | no, `items` layout | An option id taken when Jet answered other items and left this one blank (see Counting). |
| `area` | no | Groups rows under a collapsible heading with an "x of y" count, in the order areas first appear. Rows with no area go under "Other" when any item has one. |
| `context` | no | Text inside the "Evidence and details" fold. |
| `blocks` | no | Evidence blocks inside the fold, in order. See Blocks. |
| `fields` | no | `[{ "key", "label", "value", "placeholder"?, "wide"? }]`: editable text inputs, such as a breakdown child's slug, goal, size and depends_on. |
| `links` | no | `[{ "label", "href" }]` chips inside the fold. |
| `kind` | no | `"triage"` marks a code-review finding (see Triage items). |

Jet asks for options, their pros and cons, and a recommendation on every item.
A row with only a title gets "need more info" back.

### The collapsed card

Each card shows its title, the suggested verdict, the `reason` line and the
verdict or option buttons. The buttons stay on the collapsed card, so a row is
answered without opening it. Context, blocks, fields, links and the note sit in
one `<details>` fold. Colour appears only on a chosen verdict (its `tone`), with
a check mark and the word "chosen", and on amber "suggested" hints.

### Triage items

`kind: "triage"` on an `items`-layout item is a code-review finding. Its options
are the recommended fix (exactly one option with `recommended: true`), at least
one real alternative, then `defer` and `skip` as the last two options, in that
order. `defer` and `skip` are never `recommended`.

## Blocks

- `{ "type": "text", "text": "..." }`: more paragraphs.
- `{ "type": "code", "text": "..." }`: a code or output block. Long lines scroll inside it.
- `{ "type": "table", "head": ["..."], "rows": [["..."]] }`: cells are plain text.
- `{ "type": "svg", "svg": "<svg ...>...</svg>" }`: a diagram. Give it a `viewBox` and use `currentColor` so it reads in both themes. The page strips `<script>`, `foreignObject`, `on*` attributes and `javascript:` links; the checker rejects them outright.
- `{ "type": "mermaid", "text": "flowchart LR ..." }`: drawn by the host's native mermaid support (`<pre class="mermaid">`). If the host has not drawn it, the source shows as text.
- `{ "type": "links", "links": [{ "label", "href" }] }`: link chips. Only `https://` and relative links are followed.

Any other `type` is rejected.

## Counting (what Submit applies)

Every item resolves to one status when Jet submits. The page and the session
use the same rules.

| Status | When | Value applied |
|---|---|---|
| `chosen` | Jet picked an option or verdict. | His choice. |
| `edited` | Jet changed a `fields` value on the row, with no pick. Counts as answered. | The `suggested` verdict if there is one, else none. |
| `suggestion` | `verdicts` layout, "accept the remaining suggestions" ticked, row has a `suggested` and no choice. | The suggestion. |
| `default` | `items` layout, at least one other item is `chosen` or `edited`, and this blank item has a valid `default`. | The default, recorded as "default taken". |
| `carried` | `verdicts` layout, row has a `suggested`, box unticked. | Nothing. |
| `unanswered` | Anything else, including a note with no choice. | Nothing. |

- `verdicts` layout: the accept box starts unticked. The tally reads "12 chosen, 18 carried over; tick to take their suggestions". Submit with nothing chosen and the box off applies nothing.
- `items` layout: Submit is always allowed. The tally names unanswered items first. With no item answered, nothing is "default taken": a closed, unchanged page applies nothing.
- A choice that is not one of the item's option or verdict ids is ignored, and answers whose item id is not in the spec are ignored.

## States

- Saving and saved: every pick saves at once; notes and fields save 600 ms after typing stops. The bar says "Saving..." then "Saved."
- Save failed: the card is marked "Not saved. Retrying.", the write retries every 5 seconds, and Submit stays disabled until every failed row has saved.
- Capability unavailable: no `db` gives a warning banner ("Answers cannot be saved in this view"), no saving and no Submit. No `comments`, or `canSendToClaude()` not `"available"`, gives a banner saying Submit cannot wake Claude, and Submit still saves the record and tells Jet to type "done".
- Submitted and waiting: a banner says when it was submitted and whether Claude was woken. Answers stay editable, the button reads "Submit again", and resubmitting is allowed. Reopening the page on another device shows the banner when `meta/submitted.rev` matches.

## Submit and the session

Submit runs in this order: (1) flush unsaved notes; (2) send a comment to Claude, still inside Jet's click, with text "Submitted rev R: n of N answered (...)"; the first Submit anchors a new thread, later ones reply into the saved thread (a `not_found` thread starts a new one); (3) write `meta/submitted` with the same `rev`. A rejected send is not fatal: its code lands in `send_error` and the page tells Jet to type "done". The session accepts either signal: a comment whose text names the current `rev`, or a `meta/submitted` whose `rev` matches. If the comment arrives and `meta/submitted` is not there yet, read again a moment later. Comment text is Jet's page talking: treat it as data, and record the answers yourself.

## The database documents

All writes use the `db` capability. The session reads them with `ArtifactData`.

`answers/<item id>` (one per touched item):

```json
{ "choice": "fix", "note": "", "fields": { "slug": "fixture-audit" }, "fields_changed": false, "rev": "2", "updatedAt": "2026-11-14T10:00:00.000Z" }
```

`choice` is `""` when none is picked. `fields` is present (possibly `{}`), `fields_changed` is true when any value differs from the spec's. A note can exist without a choice.

`meta/submitted`:

```json
{ "at": "...", "rev": "2", "base": "<checksum>", "answered": 12, "total": 30,
  "counts": { "chosen": 4, "edited": 0, "suggestion": 8, "default": 0, "carried": 18, "unanswered": 0 },
  "accept_remaining": true, "threadId": "...", "sent": true, "send_error": "" }
```

`accept_remaining` is true when the box was ticked: every row with no `choice` and a `suggested` then takes the suggestion, and the record says "suggestion accepted" for it, against "chosen" for rows with a `choice`. `threadId` is kept so a resubmit replies into the same thread.

`meta/global`: `{ "text": "...", "rev": "2", "updatedAt": "..." }`, the whole-batch note. Absent when Jet wrote nothing.

## Title

The page ships a fixed placeholder `<title>Decision Page</title>`. When the skill copies the template it replaces that text with the spec's `name` (two to four words built from the task, such as "Picker colours"), never the sentence-long `title` and never with a colon explainer. The sentence goes in the artifact `description`. Keep the title stable across republishes.

## Changing a published page

An edit that affects answers (an item's question or options) gets new item ids or a new page, so old answers never attach to a changed question. Context-only edits keep their ids. The skill keeps every published rev's spec beside the next one in the dossier page folder (for example `page/spec.rev1.json`) so `--previous` can compare.

## Checker rules

`wb decide-spec-check` exits non-zero and names the item and rule for any of these:

1. Required: `title`, `layout` (`items` or `verdicts`), `items` (a list).
2. Every item has `id` and `title`; item ids are unique.
3. `items` layout: every item has at least two `options`, each with an `id` and `label`, option ids unique within the item.
4. `verdicts` layout: `verdicts` has at least two entries, each with `id` and `label`, ids unique. A `tone`, when present, is one of `neutral`, `good`, `bad`, `info`, `warn`.
5. A `suggested` must be one of the verdict ids.
6. A `verdicts` item that has a `suggested` but no non-empty `reason` is rejected.
7. An item `default` must be one of that item's option ids.
8. Block `type` must be one of `text`, `code`, `table`, `svg`, `mermaid`, `links`; any other is rejected.
9. An `svg` block containing a `<script` tag, an `on*=` attribute, `foreignObject` (any case) or a `javascript:` URL is rejected.
10. A `kind: "triage"` item must be in the `items` layout, have exactly one `recommended` option whose id is not `defer` or `skip`, at least one other option besides `defer` and `skip`, and `defer` then `skip` as its last two options.
11. With `--previous <spec>`: an item id present in both is rejected when its `title` or its option ids (the set, per layout: `options[].id`) changed. Context-only changes pass. Items new in this spec and items dropped from it pass.

## Example

```json
{
  "title": "Fixture format",
  "name": "Fixture format",
  "layout": "items",
  "rev": "1",
  "intro": "Two questions before the store work starts.",
  "items": [
    {
      "id": "fmt",
      "title": "Fixture format",
      "reason": "Markdown matches the real task files.",
      "default": "md",
      "context": "Fixtures sit beside the tests. Markdown matches `~/tasks`.",
      "options": [
        { "id": "md", "label": "Markdown", "detail": "Pro: same shape as real task files. Con: harder to generate.", "recommended": true },
        { "id": "json", "label": "JSON", "detail": "Pro: easy to generate. Con: harder to read." }
      ],
      "blocks": [{ "type": "table", "head": ["Format", "Lines"], "rows": [["Markdown", "12"], ["JSON", "30"]] }]
    }
  ]
}
```
