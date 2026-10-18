# decision-page: spec format, validation and answers

The source of truth that `SKILL.md` summarises. The generator
(`scripts/decision-page.py`) validates the spec, then fills `templates/page.html`
with the spec JSON and the shared kit. `fixtures/example-spec.json` is a full
working example (one decided entry, four open items, one round-2 `prior`).

## Where files live

- Spec: `~/code/tasks/dossiers/<repo>--<slug>/<slug>.json`; round N of 2 or more
  is `<slug>-r<N>.json`. The page is written beside it with the same stem
  (`<slug>.html`) unless `--out` says otherwise.
- The spec is the source; the HTML is generated and never edited by hand.
- Never leave the spec or page only in `/tmp` or the session scratchpad.

## Command

```bash
python3 claude/.claude/skills/decision-page/scripts/decision-page.py \
  --spec <path.json> [--out <page.html>] [--no-open]
```

| Exit | Meaning |
|---|---|
| 0 | page written |
| 1 | template or kit file missing (message names `stow --no-folding -t "$HOME" claude`) |
| 2 | bad input: missing `--spec`, unreadable file, invalid JSON, or invalid spec; nothing written |

On exit 2 every problem is listed on stderr, one `decision-page.py: ...` line
each, for example `item "sweep": needs exactly one rec option, found 0`.

On success stdout is three lines: `wrote: <abs path>`, `spec_hash: <8 hex>`, and
`opened: <path>` or `not opened: <reason>`. The reason is `--no-open`, or says
the path is under `/tmp` or inside a hidden directory (snap Chromium can't read
either); open it from a non-hidden path under `$HOME`.

## Spec fields

Text fields marked **HTML** are inserted as HTML: write plain prose, and use
only inline tags like `<code>`, `<b>`, `<em>`, `<br>`. Escape a literal `<` as
`&lt;`. Fields marked **plain** are escaped, so tags show literally.

### Top level

| Field | Required | Notes |
|---|---|---|
| `slug` | yes | matches `[a-z0-9][a-z0-9-]*`; names the page, the storage key and the record |
| `round` | yes | integer, at least 1 |
| `title` | no | **plain**; falls back to `slug` |
| `lede` | no | **HTML**; one or two sentences under the title; left out when absent |
| `stats` | no | list of **HTML** strings shown as a line of facts |
| `context` | no | the "where this sits" strip, below |
| `decided` | no | settled entries, below |
| `items` | yes | the open decisions (a list; the page has one card each) |

`context`: `{task, here, stages}`. `stages` is a list of `{name, state, note?}`;
`state` is one of `done`, `current`, `upcoming`, `later`, with at most one
`current`. `task` is the task name shown in the heading and `here` is the text of
"You are here".

### `decided[]` entries (no options)

`{id, title, decision, date}`. `decision` (**HTML**) and `date` are required and
must not be blank; `title` is optional (falls back to the id). A `decided` entry
must not have an `options` key. `id` follows the id rule and shares one id space
with the items.

### `items[]` entries (open decisions)

| Field | Required | Notes |
|---|---|---|
| `id` | yes | matches `[a-z0-9][a-z0-9-]*`, unique across `decided` and `items` |
| `title` | no | **HTML**; falls back to the id |
| `group` | no | **plain**; items sharing a value sit under one heading; one "Decisions" group when absent |
| `tag` | no | `{label, tone}`, both **plain**; `tone` of `keep`, `tweak` or `delete` is coloured, anything else is grey |
| `question` | yes | **HTML**; the decision, as a full sentence |
| `short_q` | no | **plain**; one line for the at-a-glance table; falls back to `question` stripped of tags |
| `why_it_matters` | yes | **HTML**; what goes wrong or what is protected |
| `today` | no | **HTML**; how it works now; `today_full` adds a collapsed "in full" section |
| `evidence_summary` | no | **HTML**; the checkable facts in a line or two; `evidence_full` adds a collapsed full version |
| `shift` | no | **HTML**; shown when the evidence changed the earlier answer |
| `prior` | no | `{note, reply}` for a round-2 re-ask: `note` is Jet's earlier note (**plain**), `reply` your answer (**HTML**) |
| `recommendation` | yes | **HTML**; what you recommend and why |
| `artifacts` | no | list of `{kind, label, path}` chips, all **plain**; `path` that starts with `/` or `http(s)://` becomes a link |
| `options` | yes | a non-empty list, below |

### `options[]` entries

| Field | Required | Notes |
|---|---|---|
| `v` | yes | the option id, `[a-z0-9][a-z0-9-]*`, unique within the item; this is what comes back in the answers |
| `name` | yes | **HTML**; the full label |
| `short` | no | **plain**; label for the glance table; falls back to `name` stripped of tags |
| `rec` | one per item | `true` on exactly one option; never on `defer` |
| `changes` | no | **HTML**; what would happen; left out when absent |
| `pros`, `cost`, `risk`, `trade` | no | **HTML**; a missing one renders as "None stated". Leave it out rather than invent one |

Every open item must include an option with `v: "defer"`; it is a real answer
(see the close contract in `SKILL.md`).

## Validation rules (what exit 2 enforces)

- `slug`, every item id, decided id and option id match `[a-z0-9][a-z0-9-]*`.
- Item and decided ids are unique together; option ids are unique within an item.
- `round` is an integer of at least 1.
- Every item has non-blank `question`, `why_it_matters` and `recommendation`, and
  a non-empty `options` list in which every option has `name`.
- Exactly one option has `rec`, an option with `v: "defer"` is present, and the
  `defer` option is not the `rec` one.
- Every `decided` entry has non-blank `decision` and `date` and no `options`.
- `context.stages` is a list, each `state` is one of `done`, `current`,
  `upcoming`, `later`, and at most one is `current`.
- `items` and `decided` are lists of objects.

Everything else is optional and never refused. The page never shows "undefined":
absent fields are left out or fall back as listed above.

## Minimal valid spec

```json
{
  "slug": "example-batch",
  "round": 1,
  "items": [
    {
      "id": "cache-layer",
      "question": "Should the API add a response cache?",
      "why_it_matters": "Slow list endpoints are the top complaint; a wrong cache serves stale data to users.",
      "recommendation": "Add a 60-second cache: it removes most of the load and stale data is tolerable here.",
      "options": [
        {"v": "cache-60", "name": "Add a 60-second cache", "rec": true},
        {"v": "no-cache", "name": "Leave it uncached"},
        {"v": "defer", "name": "Defer"}
      ]
    }
  ]
}
```

## Hash and storage

`spec_hash` is the first 8 hex digits of the SHA-256 of the spec re-serialised as
`json.dumps(spec, sort_keys=True, separators=(",", ":"), ensure_ascii=False)`.
The generator prints it. To recompute from the dossier spec:

```bash
python3 -c 'import json,hashlib,sys; s=json.load(open(sys.argv[1])); print(hashlib.sha256(json.dumps(s,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest()[:8])' <spec.json>
```

Browser state is keyed `decision-page:<slug>:r<round>:<spec_hash>` in
localStorage, so two pages, or two versions of one, never share answers. A
published page also writes each item to the Artifact database collection
`decisions-r<round>-<spec_hash>`.

## Copy answers

The **Copy answers** button puts readable markdown on the clipboard, then one
fenced `json` block as the last thing in the text. Only the JSON is
authoritative. Notes are indented in the markdown so a note with newlines can't
forge a sibling item.

````text
# wb deletion audit: answers (round 1)

- Gitignored-file sweep at wb done: Make it automatic, with an allowlist
    Yes, but skip anything over 10 MB.
- Lock orphan auto-clear: (no answer)

Anything else:
    Ask me about the rest tomorrow.

```json
{
  "slug": "wb-deletion-audit",
  "round": 1,
  "spec_hash": "1b2c4d7b",
  "global_note": "Ask me about the rest tomorrow.",
  "fixed": ["done-review"],
  "items": [
    {"id": "sweep", "choice": "tweak-auto", "note": "Yes, but skip anything over 10 MB."},
    {"id": "lock-orphan", "choice": null, "note": ""}
  ]
}
```
````

- `choice` is the option id (`v`), or `null` for an untouched item or an option
  id that no longer exists. Every open item appears in `items`, answered or not.
- `fixed` lists the ids of the `decided[]` entries; they never appear in `items`.
- Parse the JSON, match by `id`, and compare `spec_hash` with the dossier spec's
  hash. The close contract in `SKILL.md` says what to do on a mismatch.
- If the clipboard is blocked, the page shows the same text in a textarea for
  Jet to copy by hand.

## Worked round 2

Round 1 returned: `sweep` answered `tweak-auto` with the condition "skip anything
over 10 MB"; `stamps` answered `defer`; `lock-orphan` untouched; `config-seed`
answered `keep` with the note "what actually reads these?". The global note was
empty.

What you do: record `sweep` (with its condition) and `stamps` (as deferred, with a
follow-up) through `wb append`. Answer `config-seed`'s question in chat first and
re-ask it. `lock-orphan` is unanswered, so it is re-asked too.

Write `<slug>-r2.json` with `round: 2`, the two re-asked items only, and the
settled ones moved into `decided[]`. Do not pre-fill any answer:

```json
{
  "slug": "wb-deletion-audit",
  "round": 2,
  "decided": [
    {"id": "sweep", "title": "Gitignored-file sweep", "decision": "Automatic, with an allowlist, skipping files over 10 MB.", "date": "2026-10-19"}
  ],
  "items": [
    {
      "id": "config-seed",
      "question": "...",
      "why_it_matters": "...",
      "prior": {
        "note": "what actually reads these?",
        "reply": "Only <code>wb new</code> reads them, to seed a fresh worktree; nothing reads them afterwards."
      },
      "recommendation": "...",
      "options": [
        {"v": "keep", "name": "Keep", "rec": true},
        {"v": "drop", "name": "Drop"},
        {"v": "defer", "name": "Defer"}
      ]
    },
    {"id": "lock-orphan", "question": "...", "why_it_matters": "...", "recommendation": "...", "options": ["..."]}
  ]
}
```

Round 2 is a new file and a new page, never a regeneration of round 1, and it
gets its own Artifact URL if published. A reply too long for the callout belongs
in a companion explainer, linked from `reply`. A page Jet has already opened that must change in a way that affects answers
is a new slug (`<slug>-v2`), not a round.
