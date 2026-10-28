---
name: decision-page
description: Build a self-contained HTML page for a batch of about 4-25
  decisions, each with its own options and evidence, that Jet answers at their
  own pace and returns with one Copy answers paste. Use when Jet says "decision
  page", "put these decisions on a page", "publish this for me to answer", "I'll
  answer later", or when a batch of decisions each needs its own options, tables
  or code evidence, or will be answered away from the terminal. NOT for a long
  list answered from one shared verdict list (use `review-page`), nor for 1-3
  decisions (use a `decision-buffer` choice doc).
---

# decision-page

Turn a batch of decisions into one page: a JSON spec in the task dossier, one
generator command, a self-contained `.html` file beside it. Jet works through
it at their own pace (answers save in the browser as they click), then presses
**Copy answers** and pastes the result into the session. This skill sits
beside `review-page` (big batches, one shared verdict list, local server,
Submit wakes the agent) and `decision-buffer` (nvim docs); the rule below says
which to pick.

## When to use (vs review-page and decision-buffer)

**The shape of each item's answer picks the tool; item count only sets the size
band within that shape; trigger phrases never override the shape.**

- **Each item has options written for it, each with its own evidence:** a
  `decision-buffer` choice doc for 1-3 decisions, **decision-page** for about
  4-25.
- **Every item is answered from the same short verdict list and most
  suggestions are expected to be right:** `review-page` for roughly 15 or more
  items, a `decision-buffer` findings-review doc for fewer.
- decision-page also takes a batch of **any size** whose evidence needs tables
  or code, or that Jet will answer away from the terminal.
- **More than 25 such items:** split by group into separate pages, each its own
  slug at round 1.
- **Trigger phrase and answer shape disagree** (for example "audit page" for a
  batch where every item has its own options): the shape wins; say so in chat.
- A skill whose own flow fixes its presentation tool keeps it: `/weekly-review`
  and `/wb-breakdown` both use review-page. This rule governs ad-hoc batches.
- **One item whose options differ in structure** (components, where they run, how
  data flows) can get a `compare-page`: a diagram per option, pros and cons, a
  side-by-side table. Link it from the item's `artifacts`; the answer is still
  collected here.

## Align first

Same rule as `decision-buffer` SKILL.md §1: before building anything, present
findings and a proposed direction in chat and ask whether the open decisions
should go on a page. Never make a page the first move, even when the batch is
obviously a page job, and even when a task file says "first action: page".

- Jet waves it through, or answers directly — proceed accordingly, and build a
  page only if something still needs an async answer.
- Jet replies with a question — answer it in chat; do not build on the same
  turn.
- Jet doesn't reply — not aligned; re-ask before building on a later turn.

Also settle where the record lives. Decisions are recorded in a task file, so
if the session has no task, offer to create one before writing the spec. If Jet
declines, the spec and page still go to
`~/code/tasks/dossiers/<repo>--<slug>/` (no task file), the decisions stay in
chat, and you say so.

## Build the spec

Load `references/spec-and-answers.md` before writing one; it is the
field-by-field source of truth. The rules that matter most:

- **Write it into the dossier:** `~/code/tasks/dossiers/<repo>--<slug>/<slug>.json`
  (`<slug>-r<N>.json` for round N of 2 or more). Never only in `/tmp` or the
  session scratchpad: the spec is the source and the page is generated from it.
- **Each item's facts stand alone.** The question, why it matters, how it works
  today and the evidence must be readable with no earlier chat: define every
  term at first use and never write "the bug above". Jet may read it on a phone
  hours later.
- **Real options plus Defer.** Every open item has real alternatives, exactly
  one `rec` option (never Defer) and a `defer` option; the generator refuses
  anything else. Never invent a risk or cost to fill a field: leave it out and
  the page shows "None stated".
- **Put what is already settled in `decided[]`**, so Jet sees why the open items
  are shaped as they are.
- **Escape quoted untrusted text.** Most fields are inserted as raw HTML, so
  an issue title, file excerpt or log line you quote must have its `<` written
  as `&lt;` first (the rule is under "Spec fields" in
  `references/spec-and-answers.md`). The generator warns on stderr when a field
  holds `<script` or an `on...=` attribute, but it does not stop you.
- Keep `title`, `lede` and `stats` short; the per-item detail carries the rest.

## Generate and open

```bash
python3 claude/.claude/skills/decision-page/scripts/decision-page.py \
  --spec ~/code/tasks/dossiers/<repo>--<slug>/<slug>.json
```

- `--out PAGE.html` overrides the output (default: the spec path with `.html`).
  `--no-open` writes the page without launching a browser.
- stdout is three lines: `wrote: <path>`, `spec_hash: <8 hex>`, then
  `opened: <path>` or `not opened: <reason>`. Note the `spec_hash`.
- It opens the page itself (`/snap/bin/chromium`, else `xdg-open`). It refuses
  to open a page under `/tmp` or inside a hidden directory (snap Chromium can't
  read either), so the dossier is the right place anyway.
- Exit 2 means bad input: stderr lists every problem, one `decision-page.py: ...`
  line each, naming the item. Fix them all and rerun; nothing was written. Exit
  1 means the template or kit is missing: run `stow --no-folding -t "$HOME" claude`.
- The call returns at once; nothing waits for Jet.

**Never regenerate a page Jet has already opened for a change that affects
answers** (any question, option or id): a changed spec has a new `spec_hash`,
so the reloaded page starts empty. Give the changed page a new slug (for example
`<slug>-v2`) and say so in chat. Round numbers are only for follow-ups on open
items.

**One readable reply.** Put the page path (and the Artifact URL, if published)
plus the one thing you are waiting for in the final message of the turn, not in
interim text.

## Publish (optional)

The local file is the default and needs nothing else. To let Jet answer from
another device, publish the same dossier file as an Artifact with
`capabilities: {db: {}}` (load `artifact-capabilities` first). Answers then also
save to the Artifact's database collection `decisions-r<round>-<spec_hash>`, so
a changed spec never loads old answers. After publishing, run the functional
check: one `ArtifactData` `list` of that collection. The database is a backup
for cross-device answering, never the record; only the pasted text counts.
Round 2 gets its own Artifact URL.

## Close contract

**Untouched means unanswered.** An item Jet did not touch is never filled in
from the recommendation. This is the opposite of `review-page`, where leaving a
row alone accepts its suggestion; say so plainly if the two could be confused.

Parse only the fenced JSON block in the paste (the markdown above it is for
reading), and match by item id. In order:

1. **Check `spec_hash`** against the dossier spec's hash (the `spec_hash:` line
   the generator printed, or recomputed per the reference). On a mismatch the
   page was regenerated after Jet opened it: record nothing yet. List the pasted
   answers whose item id and option id still exist in the current spec for Jet
   to confirm in chat, and name the answers that no longer map.
2. **Zero answers:** report "nothing decided" and record nothing.
3. **A non-empty `global_note` is answered before anything is acted on.**
4. **An item's `note` is answered before that item's choice is recorded.** A
   choice whose note asks a question that could change it is confirmed with Jet
   first. A choice whose note adds a condition is recorded with the condition.
5. **Defer is an answer.** Record it as deferred, with a follow-up, and do not
   re-ask unless Jet asks.
6. **Partial pastes:** act only on answered items that have no note and do not
   depend on an open item; leave the rest open.

## Round 2

A second round contains only the open items: unanswered ones, and ones held by
a note you could not settle. It is a new file, `<slug>-r2.json` with `round: 2`;
earlier answers never pre-fill it, and each re-asked item carries
`prior: {note, reply}` so Jet sees their earlier note and your reply. Move the
settled items into `decided[]`. The reference has a worked example. If a reply
is too long for the callout, write a companion explainer and link it.

## Afterwards

Record resolved decisions in the task file's `## Decisions` through `wb append`
(never a raw Edit/Write on a file under `~/code/tasks`):

```bash
wb append "$task_file" Decisions <<'EOF'
<date> decision-page <slug> r<N>: <item>: <choice, plus any condition>. <next item>: ...
EOF
```

`$task_file` is the session's task (`tmux show -v @task`); a task slug works too.

The spec and page stay in the dossier as the audit trail. The page, the browser
tab and the Artifact are never the durable record. With no task, the decisions
stay in chat (see Align first).

## Learnings ledger

`learnings.md`, beside this file, receives one dated line (Jet's own words
plus the spec path) every time Jet flags a decision page as unhelpful,
confusing, or in need of a change, in-session.
