# verify.json contract

One document per task, kept at `verify/verify.json` in the task's dossier. Every page is generated from it; nothing is edited in the HTML. `scripts/verify-plan.py check <file>` enforces what is marked **checked** below. On success it prints nothing and exits 0; on failure it prints one line per problem, naming the item id and the field, and exits 1. Every `id` (requirement, part, test, step, decision) matches `^[A-Za-z0-9_-]+$`, so it is safe in a file name (`steps/<stepId>.json`) and an HTML attribute; **checked**, with the bad id named. A worked example is `fixtures/example-verify.json` (an invented library-holds app).

## Top level

| Key | Type | Notes |
|---|---|---|
| `task` | string, required | The task's name. Must not be blank. |
| `title` | string, optional | A readable title for the page header, such as "Book holds". When absent the pages use `task`. |
| `summary` | string, optional | One line saying what the task is. Shown under the title on every page. |
| `page` | object | Page metadata (below). |
| `stage` | string, required | `shaping`, `map`, `run` or `results`. |
| `requirements` | list | Requirement objects. |
| `lanes` | list, optional | Display text for the four lanes. The ids are fixed in the script, not the document. If present it must hold exactly the four ids. When absent the page uses the script's default labels and one-line explanations. |
| `parts` | list, optional | System parts. Without it tests cannot name parts and the page shows the grid only. |
| `tests` | list | Test objects. |
| `walkthrough` | object | `revision` (integer, bumped when a step is added, removed or renumbered) and `steps`. |
| `decisions` | list | Decision objects. |
| `checked`, `unchecked`, `needs` | lists of strings | What the agent checked, could not check, and what it needs from you. |
| `run` | object, optional | Recorded walkthrough results (below). Written by `record-run`. |

`page`: `tags` (list, for the dossier index, normally `["verify-plan"]`), `retire_when` (string, e.g. `task:<stem> done`), optional `url` (the published page's address, once there is one).

## Ids and lanes

Ids are unique within their kind (requirements, tests, steps, decisions, parts); a duplicate fails.

- Lane ids: `unit`, `integration`, `e2e`, `walkthrough` (shown as Unit, Integration (real dependency), End-to-end, Your walkthrough). **Checked** on every test's `lane`.
- Access levels, five, on every step's `access` list: `local` (local only), `cloud-read` (touches cloud), `cloud-write` (changes cloud), `prod` (could affect prod), `permission` (needs permission). **Checked**: a value outside the five fails and the message lists them. A step needs at least one.

## Requirement

`id`, `label` (short), `sentence`, `why` (why it matters), `wrong_when` (how it could be wrong while tests pass), optional `lasting` (boolean, behaviour that should get a live check), optional `accepted_gap` (a reason string).

**Checked**: `label` and `sentence` not blank. A requirement must be covered: named by some test's `requirements`, or by some step's `requirements`, or by an **open** decision's `requirements`, or carry a non-blank `accepted_gap`. Otherwise it fails as uncovered. An answered decision does not cover.

## Test

`id`, `name` (plain words, the page's label), `test_name` (the real test's name), `lane`, `requirements` (ids proven), `real_parts`, `faked_parts` (part ids), `passing_tells` (what a pass tells you), `status` (`proposed`, `planned`, `built`), optional `decision` (id of the decision it rests on; a proposed test resting on an open decision is drawn tentative, derived and never stored).

**Checked**: `name` not blank; `lane` and `status` allowed; every id in `requirements`, `real_parts`, `faked_parts` and `decision` resolves (a document without `parts` therefore fails any test that names a part).

## Part

`id`, `label`, `what` (one line).

## Walkthrough step

`id`, `title`, `where`, `why`, `command` or `instruction` (a plain instruction with no command), `expected`, `wrong_if`, `risk`, `access` (list), `paste` (boolean, show a paste box), `requirements` (ids).

**Checked**: `title` not blank; `command` or `instruction` present; `access` values; `requirements` resolve.

## Decision

`id`, `question`, `options` (list of `{id, label, cost, proves}`), `recommended` (option id), `answer` (option id, or null while open), `note`, `status` (`open` or `answered`), `requirements` (ids the decision names; this is how an open decision stands in for missing proof).

**Checked**: `question` not blank; `status` allowed; `recommended` and `answer` name real options; an answered decision has an answer; `requirements` resolve. Decisions are answered only through `/decide`, never on the page or by hand.

## Run

Written by `record-run`; the shape is:

```json
"run": {
  "revision": 1,
  "steps": {
    "S1": {"outcome": "passed", "skip_reason": "", "output": "", "note": "", "time": "2026-11-16T10:02:00Z"}
  }
}
```

`revision` is the walkthrough revision the results were recorded against. `outcome` is `passed`, `failed`, `skipped` or `not-run`. **Checked**: every key under `steps` is a real step id and every `outcome` is allowed. A `run` whose `revision` differs from `walkthrough.revision` fails the check: it was recorded against another version of the walkthrough, so re-run and `record-run` again, or remove it. A document with no `run` passes.

### Stored documents and the exported run state

A published run page (stage `run`, or `map` with a `run` section) keeps its state in the page's database. `rev` is the source's `walkthrough.revision`, stored as a string (`"1"`); readers compare it as a string, so `1` and `"1"` match.

`steps/<stepId>` (one per touched step): `{"outcome": "passed", "skip_reason": "", "output": "", "note": "", "rev": "1", "updatedAt": "2026-11-16T10:02:00.000Z"}`. `outcome` is `passed`, `failed`, `skipped` or `""` (cleared, read as not run).

`meta/submitted`: `{"at": "...", "rev": "1", "counts": {"passed": 2, "failed": 1, "skipped": 1, "not_run": 0}, "threadId": "...", "sent": true, "send_error": ""}`.

The session exports both with the page-database tool's `out_dir` option into `<dossier>/verify/run-state/`, which writes `<out_dir>/<collection>/<doc id>.json`: `steps/<stepId>.json` and `meta/submitted.json`. `fixtures/example-run-state/` shows the layout. An exported file is either the document itself or a wrapper that carries it under `data` beside fields such as `id` and `version`; `record-run` accepts both.

`record-run <verify.json> <state-dir>` reads `<state-dir>/steps/*.json` (the file name is the step id). It ignores documents whose `rev` is not the current revision and reports how many (this is checked first, so an old document for a step since removed is only ignored). It refuses current-revision state naming a step id that is not in the source (non-zero exit, source untouched). A stale `run` already in the source does not block it, since the section is replaced. It then replaces the whole `run` section with `{revision, steps}` built from the rest (`time` is the document's `updatedAt`; a cleared outcome becomes `not-run`), validates the result as `check` does, and writes atomically (temp file and rename) as JSON with 2-space indent, a trailing newline and the key order kept, so a second run with the same state leaves the file byte-identical.
