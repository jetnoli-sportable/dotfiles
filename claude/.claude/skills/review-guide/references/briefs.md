# review-guide: lens and coordinator briefs

The instructions every review agent receives. `SKILL.md` stage 4 builds the
briefs from this file:

- `briefs/common.md` = the run's context (intent summary, rules, inventory
  table, logic files with changed ranges, skim list, worktree paths) followed by
  the **Shared rules** section below, copied word for word.
- `briefs/L1.md` … `briefs/L5.md` and `briefs/coordinator.md` = that agent's
  section below, copied word for word, with the placeholders filled in.

An agent gets `briefs/common.md` plus its own brief and nothing else. Nothing
here may point back to the pipeline page or the plan; if an agent would need
them, the rule belongs in this file.

`scripts/build-briefs.py` does the copying and fills the placeholders:
`<run>` is the run directory (`<dossier>/review-guide/<target>/`), `<worktree>`
the detached checkout the agent reads from, `<base>`/`<head>` the pinned SHAs,
`<pr>` the PR number (or branch name for a branch target), `<report>` the L1
report file name, `<stack>` the stack's PR list. `<paths>` is filled by the
orchestrator when it resumes the coordinator.

---

## Shared rules

*(Copied into `briefs/common.md` word for word, after the run context.)*

### Where you read

Read files and run tests **only** in the worktree named in your brief. It is a
detached checkout at the exact commit under review. Never read the session's
own checkout or any other branch: it may hold different code. To see code the
change removed, run `git show <base-sha>:<path>` in your worktree, with the base
SHA your brief names. Write only to your
report file in `<run>`.

### Depth rules

1. **Read whole changed files, not just the hunks** (the changed blocks of
   lines in a diff). A hunk hides the state it depends on: a comment saying
   "`$out` is already trimmed" is only true if the caller, outside the hunk,
   trims it.
2. **One hop out.** For every changed function, read its callers and the
   functions it calls (grep, or LSP where the language has a server).
3. **Read the tests that touch each logic file**, and the intent in the run
   context.
4. **Every finding is evidence, not opinion:** `file:line`, a verbatim excerpt
   copied from that line, a concrete scenario (this input or state gives this
   wrong result), a severity and a confidence.
5. **Report what is clean as well.** List what you examined and found sound in
   `checked_clean`. That list is what lets the page tell a reviewer "skim this"
   with grounds.
6. **No style nits.** Naming, formatting and comment wording are not findings.
   Line-by-line review is another tool's job. Respect your finding cap; rank by
   severity, then confidence.
7. **Skip the skim list.** Files the run context lists as skim (generated,
   renames, fixtures) are not read unless a finding traces into them.

### Finding schema

Each finding is one JSON object with exactly these fields:

| Field | Value |
|---|---|
| `id` | `<lens>-<NN>`, e.g. `L1-03`. For a per-PR L1 in a stack, `L1.<PR number>-NN`, e.g. `L1.543-02`. The coordinator uses `C-NN`. |
| `lens` | `L1` … `L5`, or `coordinator` |
| `pr` | the PR number this finding belongs to, or the branch name for a branch target. Required even for a single PR. |
| `file` | repo-relative path. `context.md` only for an L3 "stated but not done" finding, which has no line in the code. |
| `line` | 1-based line number of the excerpt's first line, in `file` at the commit `side` names. For `context.md`, its line in that file. |
| `side` | `head` (default) for code that exists after the change; `base` for code the change removed. |
| `excerpt` | one to three lines copied **verbatim** from `file` at `line`. A script checks it is within three lines of `line`; a paraphrase fails and the finding is dropped. |
| `claim` | one sentence: what is wrong or worth attention. |
| `scenario` | the concrete path: input or state → what the code does → the wrong result. |
| `severity` | `high` (data loss, security, breaks existing callers or the main path), `medium` (wrong result on a plausible input or path), `low` (unlikely edge, or cost without harm) |
| `confidence` | `high` (traced end to end), `plausible` (the path looks real but one link is unproven), `low` (a suspicion worth a look) |

### Report file

Write one JSON file, `<run>/<your report name>`, shaped:

```json
{ "lens": "L1", "pr": "95", "status": "DONE",
  "findings": [ { "id": "L1-01", "...": "..." } ],
  "checked_clean": ["timeout and non-zero exit paths in run_sweep: unchanged and tested"],
  "rulings": ["Ruling: treated hooks.json as logic — it wires behaviour — a missed hook bug if wrong"] }
```

Your brief may add lens-specific top-level fields (named there). Valid JSON
only; no comments.

### Status and rulings

- Return a short final message: one of `DONE`, `DONE_WITH_CONCERNS`,
  `NEEDS_CONTEXT`, `BLOCKED`, then the report path, then one line per concern
  or blocker. The report holds everything else.
- On a judgment call, add a line to `rulings` and carry on:
  `Ruling: <decision> — <why> — <cost if wrong>`. Don't stall, and don't guess
  silently.
- `NEEDS_CONTEXT` only when the run context is missing something you cannot
  find in the worktree (e.g. the intent is absent). Say exactly what.

---

## L1 Risk: what can break

*Report: `<report>`. Cap: 8 findings.*

**Your question:** what inputs and states can this code see, and which of them
make it do the wrong thing?

You review `<pr>`: diff `<base>..<head>`, worktree `<worktree>`. In a stack,
the other PRs have their own L1: cite lines at your PR's head (or base, for
removed code), and set `pr` to `<pr>` on every finding.

Method, for each logic hunk:
1. Name what it can be given (arguments, files, env, stdin, model output) and
   what state it can see (files on disk, locks, other processes).
2. Walk: the error path (non-zero exit, exception, timeout); empty and odd
   input; ordering and concurrency (two processes writing one file, a lock held
   across a slow call); stored data and migrations; permissions and secrets;
   compatibility with existing callers and with data already on disk.
3. For each walk that ends in a wrong result, write the finding with that walk
   as its `scenario`.
4. Put each path you walked and found sound in `checked_clean`.

Hot-flagged files (in the run context's inventory) come first. Read the repo's
`AGENTS.md`/`CLAUDE.md` rules in the run context; a broken rule that can cause
harm is a finding, a broken style rule is not.

## L2 Design: what was chosen, and instead of what

*Report: `lens-L2.json`. Cap: 6 decisions, plus findings (cap 4).*

**Your question:** what design decisions does this change make, and how do they
compare with the real alternatives?

A decision is: where state lives; a new boundary, module or process; a data
format or protocol; a new dependency; a public name or interface; a choice of
mechanism (polling vs events, lock vs queue).

Extra top-level fields:

- `decisions`: list of
  `{ "id": "D1", "pr": …, "what": …, "where": "file:line", "chosen": …, "alternatives": [ { "option": …, "precedent": "file:line or null", "pros": …, "cons": … } ], "fit": …, "reversal_cost": "low|medium|high — why" }`.
  At least **two real alternatives** per decision. Prefer alternatives the repo
  already uses elsewhere (cite the precedent) over textbook ones. "Do nothing"
  counts only when it is a real option.
- `component_map`: `{ "nodes": [ { "id": …, "label": …, "kind": "file|function|process|store|hook", "change": "added|removed|changed|unchanged" } ], "edges": [ { "from": …, "to": …, "label": …, "change": … } ] }`.
  Include unchanged neighbours one hop out, so a before/after diagram can be
  drawn from it.

`findings` holds only decisions that look wrong (a misfit with the repo's
architecture, a high reversal cost taken without need), in the finding schema.
For a stack, tag every decision and finding with the PR that introduces it.

## L3 Intent: what was said against what was done

*Report: `lens-L3.json`. Cap: 6 findings.*

**Your question:** does the change do what its intent says, only that, and is it
explained in proportion?

Compare the intent in the run context (PR body, commit messages, task plan and
decisions, ticket) with the diff:
- **Done but not stated:** behaviour changes no intent source mentions.
- **Stated but not done:** a promised change missing from the diff. Cite the
  promise in `context.md` (`file: "context.md"`, its line and verbatim text).
- **Scope creep:** unrelated changes riding along.

Extra top-level fields:

- `reading_order`: list of `{ "step": 1, "pr": …, "files": ["path", …], "why": … }`.
  Dependencies before dependants: what a function calls before the function,
  a schema before its users. In a stack, the PR the others build on comes
  first.
- `proportion`: `{ "ratio": <from the inventory>, "verdict": "fine|heavy|light", "why": … }`.
  The inventory gives explanation lines (PR body words plus added plan docs)
  against logic lines. Judge whether it matters: a 400-line plan beside a
  60-line fix is "heavy"; a large feature with no description is "light".
- `skim_extra`: files that look like logic to the inventory but carry no
  control-flow change (prompt wording, a reworded message, a constant), each
  with a one-line reason.

## L4 Tests: is the risky part covered

*Report: `lens-L4.json`. Cap: 6 findings.*

**Your question:** which logic paths does a test exercise, and which risky ones
does nothing exercise?

Extra top-level fields:

- `coverage`: list of `{ "path": "file:function or behaviour", "tests": ["test file:case", …], "runs_in_ci": true|false|null, "note": … }`.
  `runs_in_ci` comes from the CI config and check results in the run context;
  `null` when you can't tell.
- `manual_checks`: commands a reviewer can run to see the risky path work, each
  with what to look for. If the suite has known failures on the base branch
  (the run context says so), name the specific test files to run and say
  "judge by these files' results", not the suite's exit code.

A test gap on a hot-flagged or high-risk path is a finding (cite the untested
code, not the test file). Run a test only when it is quick and touches no
shared state.

## L5 Reuse: a small simplify sweep

*Report: `lens-L5.json`. Cap: 5 findings.*

**Your question:** does the change copy code within itself, or rewrite something
the repo already has?

Look for:
- **Duplication inside the change:** a block repeated across the change's own
  files, or (in a stack) across its PRs.
- **Reinvented helpers:** new code doing what an existing function, method or
  library call already does. Search for the *operation*, not just the name:
  grep the idiom, the key calls and likely helper names (`trim`, `parse_`,
  `_lock`); use LSP references where the language has a server.

A reuse finding must show the existing helper is **usable from here**:
1. It is loaded or importable in that file (sourced, imported, same package).
2. It behaves the same on the inputs this code sees.
3. Calling it costs nothing the call site can't afford (a subshell in a hook
   that runs on every prompt is a cost).
4. The inline form is not simply the repo's own convention (count other uses).

If any of the four fails, it is not a finding: put it in `checked_clean` with
the reason. Worked non-finding: a hook trims whitespace inline with
`"${prompt#"${prompt%%[![:space:]]*}"}"` while a `_trim` helper exists in
another script. The hook's script doesn't source that helper, the helper
returns through `printf` (a subshell per call on every prompt), and the same
inline idiom appears in 20+ places. So: clean, "inline is the house idiom".
A real finding would be a new 15-line block re-implementing locking that a
sourced `locks.sh` already provides.

Each finding's `claim` names the existing helper's `file:line`. No general
refactoring ideas. These become "simplify before merge" notes, never risk
items, so use `severity: low` unless the copy already diverges in behaviour
(then `medium`).

---

## Coordinator, part 1: quick pass

*Opus. Report: `quick-pass.json`. Started at the same time as the lenses.*

You are the run's coordinator. Five lenses are reviewing this change in depth,
each with one question (L1 risk, L2 design, L3 intent, L4 tests, L5 reuse).
Your first job is the opposite: **one fast read of the whole change**, to catch
what falls between their questions and to give their findings something
independent to be checked against. Later you will be resumed to verify their
work, so remember what you read.

Rough on purpose: read the logic diff once, in a sensible order, using the
worktree for surrounding code. No one-hop tracing, no tests run. Write:

```json
{ "lens": "coordinator", "status": "DONE",
  "overall": "three sentences: what this change really does, how it hangs together, where it is weakest",
  "spots": [ { "file": "…", "line": 0, "excerpt": "verbatim", "worry": "one line", "severity": "high|medium|low" } ],
  "architecture": ["anything that looks wrong for this repo's architecture, one line each"],
  "rulings": [] }
```

At most 5 `spots`, hot-flagged files first. `excerpt` follows the finding
schema's verbatim rule.

## Coordinator, part 2: verify and reconcile

*Sent when the lenses finish, as a message to the same agent. Report:
`verified.json`.*

The lens reports (after a script cite check) are at: `<paths>`. Findings whose
cite check came back `missing` have already been dropped; `moved` ones have
corrected lines.

1. **Refute.** For every finding with severity `high` or `medium`, try to prove
   it wrong. Read the code in the worktree, follow the scenario, run the
   relevant test when that is cheap. For a reuse finding, call the existing
   helper on the change's real inputs and compare. Verdict per finding:
   `CONFIRMED` (you followed the scenario and it holds), `PLAUSIBLE` (it may
   hold; you could not prove or refute it), `REJECTED` (it does not hold), each
   with a one-line `reason`. `low` findings pass through as `PLAUSIBLE` unless
   you happen to refute them.
2. **Merge duplicates** across lenses (e.g. an L1 risk and an L4 test gap on the
   same line): keep one finding, list the merged ids.
3. **Cover the gaps.** Any quick-pass spot no lens finding touches gets a
   targeted check by you now. If it holds up, add it as a finding with
   `lens: "coordinator"`, id `C-NN`; its verdict is at most `PLAUSIBLE`, since
   no second agent checked it.
4. **Flag disagreements.** Where a lens rated a finding very differently from
   your quick pass (or two lenses contradict), don't settle it; list it for the
   orchestrator.

Write:

```json
{ "lens": "coordinator", "status": "DONE",
  "findings": [ { "...finding schema...": "", "verdict": "CONFIRMED", "reason": "…", "merged": ["L4-02"] } ],
  "disagreements": [ { "ids": ["L1-03"], "what": "…" } ],
  "rulings": [] }
```

`findings` lists **every** finding from every lens (after merges) with its
verdict, including `REJECTED` ones, plus your own. The orchestrator drops the
rejected ones; keeping them here makes the drop traceable.

## Stack note

*(Added to `briefs/common.md` for a stack target.)*

This change is a stack of PRs, each building on the one before:

<stack>

L1 runs once per PR on that PR's own diff. L2–L5 and
the coordinator read the whole range `<base>..<head>` in the tip's worktree and
**tag every finding, decision and reading-order step with the PR that
introduces the code** (use `git -C <worktree> log --format=%H <base>..<head> --
<file>` against the PR list to tell). L5 also looks for blocks copied from one
PR into a later one.
