# Global instructions (apply across all projects)

## Design decisions → /decide, not AskUserQuestion

When several answers are needed from Jet in writing, at his own pace — and the direction is already basically agreed — route them through the **`/decide`** skill (`~/.claude/skills/decide/SKILL.md`) instead of an AskUserQuestion menu. `/decide` replaced `decision-buffer`, `decision-page` and `review-page` in Nov 2026. The skill handles the align-first sequence (present findings and a proposed direction in chat, and open nothing until Jet agrees), picks the surface (an nvim buffer in a tmux split for quick text answers and run-and-paste loops; a private claude.ai page for evidence or many items; both when a run-and-paste loop needs visuals), and records each answer in the task's Decisions with `wb decision`. Its shapes, page layouts, per-item Recommendation and Questions/Notes, and rewrite-fresh rounds live in the skill; don't restate them here, they drift. If this section disagrees with the skill file, the skill is canonical: fix this section, not the skill.

The buffer opens in a split of the task's tmux session as a background command, and closing it re-invokes the agent; a page's Submit wakes the session through a comment, or Jet types "done". Jet does NOT want a separate terminal window when tmux is available. Answer any Questions/Notes before acting on a selection.

Trivial decisions (one obvious option, yes/no with an obvious default) and a single question skip `/decide`: just proceed, or ask briefly in chat.

## Worktree setup → seed from an existing task record

When setting up a new worktree (via `ce-worktree`, `wb new`, or otherwise) for a branch/ticket, first check the central task store at `~/code/tasks/` for an existing task file matching the target repo and name/ticket number — filter by the `repo:` frontmatter field (the repo's basename), then match the slug. Task filenames are `<repo>--<slug>.md` where the slug has `/` and `.` sanitized to `-` (e.g. repo `be--monorepo`, branch `feat/sfb-1062-…` → look for `~/code/tasks/be--monorepo--feat-sfb-1062-*.md`). If one exists, read it and use it as the starting point/context for the work — it often already captures the problem, the intended fix, and prior decisions. Surface what you found rather than starting from scratch. If none matches, proceed normally.

(Superseded the older per-repo `scratch/tasks/` convention — see `~/code/tasks/README.md` for the schema and why it moved centrally.)

## Worktree setup → copy gitignored bootstrap files (all repos)

When creating a new git worktree in **any** repo, copy the gitignored local bootstrap files from the main checkout into the new worktree so it runs with **zero per-worktree edits**. Fresh worktrees only contain tracked files, so anything gitignored (local config, secrets, installed deps) is missing and the app/dev-server/Makefile targets won't run.

- Identify what's gitignored-but-required: local config files (e.g. `config.hjson`, `.env`/`.env.*`), credential files, and installed-dependency dirs (`node_modules/`, vendored deps). Check `.gitignore` and how the run/build commands resolve paths.
- Copy **every** location a tool reads from, not just one. (Tooling sometimes copies from a nested path, not the repo root — e.g. a Makefile `run` target that copies `apps/x/config.hjson`; seeding only a root copy leaves the nested one missing.) For big dirs like `node_modules/`, copy or symlink — whatever gets it runnable without a reinstall.
- Never "fix" a missing-bootstrap-file by editing tracked build files with a worktree-relative path (e.g. `../../../../apps/x/config.hjson`) — that path is specific to the worktree's nesting depth and breaks the command in the main checkout and other worktrees. Seed the file instead.

Repo-specific specifics live in that repo's own memory/AGENTS.md; this rule is the general principle.

## wb sessions → reviews stamp themselves; check for the message

When a `/ce-code-review` of the session's own branch finishes inside a `wb` session, the review-stamp hook (`review-stamp-hook.sh`, on Stop and SubagentStop) runs `wb reviewed`, which stamps the task file's `reviewed:` frontmatter field with today's date; `wb board --html`'s review stage relies on it to render that stage as done. The session then shows a one-line "stamped" message. If that message doesn't appear after a finished review (the hook's settings entries aren't live yet, the review targeted another PR or branch, or stamping failed and the message says why), run `wb reviewed` by hand. See `docs/wb-guide.md`'s board section for what this feeds into.

## Before any code review → run `/haircut` first

After implementation and any simplification pass, and before any code review starts, run `/haircut` on the branch diff and commit its result. This covers `ce-work`'s shipping step (after simplify, before `ce-code-review`), a review started by a `/wb-resume` `run` directive in a fresh session, and a review Jet asks for by hand. The rules for what it keeps, removes and flags live in `~/.claude/skills/haircut/SKILL.md`; don't restate them here. The haircut gate (`haircut-gate-hook.sh`, on the Skill tool and on typed prompts) stops a `/ce-code-review` of the current branch when no haircut commit follows the branch's newest code commit; run `/haircut` and commit its result, then retry. A sweep with nothing to trim makes no commit. It records the swept HEAD in the worktree's git dir, and the gate accepts that. The gate only sees commits: code edited after the last haircut and left uncommitted passes it unswept, so still run `/haircut` first.

## Live cloud commands → Jet runs them; hand over a command card

Never run `gcloud`, `gsutil` or `bq`, or anything that uses their credentials (e.g. `curl -H "Authorization: Bearer $(gcloud auth print-access-token)" …`), without Jet's explicit approval for that exact command. That includes read-only commands, and approval for one command doesn't cover the next. Live-cloud work is Jet's to run, to be safe.

- **Default: hand over a command card** instead of asking to run it: the exact command, what it does, whether it's read-only or mutating, which project/account it acts on, and what Jet should paste back.
- **Terraform/OpenTofu/Terragrunt:** the agent never runs `apply`, `destroy`, `import`, `taint`/`untaint`, `force-unlock`, `refresh`, a state write (`state rm|mv|push|replace-provider`), `workspace delete`, or anything with `-auto-approve` or `-lock=false` (including through `TF_CLI_ARGS`); those go on a command card too.
- **The one exception:** `terraform fmt`, `validate`, `init`, `plan`, `show`, `graph`, `output` and `state list/show/pull`, and read-only `kubectl` (`get`, `describe`, `logs`), may run without asking even though they use the same credentials. They read live state but don't change it.
- The `risky-command-guard.sh` PreToolUse hook enforces this for the Bash tool (deny for the terraform writes, ask for every `gcloud`/`gsutil`/`bq` call, including inside `$( )`), but it only sees the typed command text. A script or program that calls them is still covered by this rule.

## GitHub CLI → use `pgh` for non-Sportable repos

The default `gh` is authenticated with a fine-grained PAT scoped to the **Sportable org**, so it can only see Sportable-org repos. For any repo **not** owned by the Sportable org — personal repos under `github.com/jetnoli-sportable/…`, or any other owner — use the **`pgh`** shell function instead of `gh` for all GitHub API operations (`pr create`, `issue`, `api`, `repo view`, etc.). `pgh` injects the personal-account PAT from the system keyring (defined in `~/.zshrc`).

- Decide by the origin remote owner: run `git remote get-url origin`. Owner `jetnoli-sportable` (or anything non-Sportable) → `pgh`. Sportable-org owner → plain `gh`.
- Signal you picked wrong: a `gh` call failing with `GraphQL: Could not resolve to a Repository` means the Sportable token can't see it — retry the same command with `pgh`.
- This only affects the `gh` CLI. Plain `git` push/pull works everywhere via SSH and needs no change.

## HTML artifacts → durable landing path first, never scratch-only

Any HTML doc worth publishing as a claude.ai Artifact must FIRST be written to a durable landing path — the repo's `docs/` when it's tracked-worthy, else the central task store's dossier area (`~/code/tasks/dossiers/<repo>--<slug>/`). Never leave it only in the session scratchpad or `/tmp`: scratch dirs get cleaned and the doc becomes unrecoverable (this happened once). Publishing to claude.ai is the preview, the file on disk is the artifact.

- Boundary: employer-repo (Sportable) content never lands in, or gets published from, personal surfaces — work docs go in the work repo's own scratch/docs conventions.
- The Artifact URL may be shared in chat, but the durable path must be named alongside it.
- When the doc lives in the task store, the file on disk is generated too: see the next section.

## Task store → the source of truth; HTML is generated from it

For all work tracked in `~/code/tasks` (every repo and task family, decided 2026-10-17), the task store as a whole is the source of truth, and every published page can be rebuilt from it:

- **Task files own status and decisions.** Any table of ticket or rung status on a page is generated from task-file frontmatter and sections, never hand-kept beside them.
- **Each lasting page has a source in its dossier**, normally Markdown (`<name>.md` beside `<name>.html`). A page that's really a tool or data view (a matrix, a review page, a dashboard) may instead have a generator script plus its data in the dossier. Either way, the source is what gets edited.
- **HTML is always generated from that source** and is never edited by hand: change the source, regenerate, republish to the same URL. Keep the generator in the dossier's `tools/` (or the store's shared tooling once it exists) and say in `tools/README.md` how to run it.
- **Scope and migration.** This applies to lasting pages: plans, explainers, references, hubs. One-off decision aids may stay HTML-only. Existing HTML-only pages get a source the next time they change; don't convert them all at once.
- **Retire, don't delete.** A superseded page keeps its file and URL, gains a banner naming its replacement, and drops out of the hub links. The family's `INDEX.html` is the one list of pages, and the overview.

The "What goes where" section of `~/code/tasks/README.md` carries the same rule for the store.

## Explaining → complete, self-contained answers, not fragments

When Jet asks what something means or why it matters, answer so each point stands on its own without the earlier chat (asked for 2026-10-17, after several rounds of half-explanations):

- **Lead with why it matters, then the mechanism.** Say what goes wrong or what it protects before describing how it works; describing the problem a thing causes isn't explaining why it matters.
- **Define every term at first use in that answer**, even if it came up earlier ("the image" → the Cloud Run Job's container image, built by `cd.yml` on each merge). Never point back with "the bug above", "the caveat", "the slot" — restate the thing.
- **Show, don't assert.** Use a concrete example: a small code snippet, a real file excerpt (e.g. an example `outcome.json`), or the output of a quick command run to demonstrate it.
- **End each point with the conclusion and a recommendation**, stated plainly: what it means for what we're building and what to do.
- **Correct earlier wording explicitly** when a previous answer was wrong or loose, instead of quietly changing it.

## Identifiers → always with a plain description

Never show Jet a bare identifier: a commit SHA, a ticket number (SW-…, SFB-…), a PR number or link, a task slug, a run id or an artifact URL. Every one gets a short plain description of what it is, in the same sentence or table cell (asked for 2026-10-21, after "push `3ce3c41`?" with no word on what that commit held).

- Commit: what it changes, e.g. "the commit recording that prod's dataset is in the US (`3ce3c41`)".
- Ticket or PR: its subject, e.g. "A3, dropping the unread BigQuery outputs (SW-6702)"; "#1361, the run-folder bucket and its grants".
- Task slug, artifact link, run id: what it is or holds, never the bare name or URL.
- The identifier still goes alongside, so Jet can look it up; the description comes first.
- Applies everywhere Jet reads: chat, buffers, decision pages, summaries, handoffs and relays.

## Ending a turn → a Needs-you line, or "Nothing needed."

A reply that ends a turn closes with one of two lines, so Jet and the scripts that read last replies (the page server's waiting-on-you list, `day_end.py`) can tell at a glance whether a session waits on him (decided 2026-11-08, after 6 of 13 last replies on 5 Nov didn't say):

- **Something waits on Jet:** `**Needs you:**` followed by the exact ask, e.g. `**Needs you:** merge PR #2203 (the SportsCode half-timings row) or tell me to hold it.` Several asks go in a numbered list under it.
- **Nothing does:** `**Nothing needed.**`, with at most one clause on what happens next. That clause must not sound like an ask: no "your call", "for you to", "up to you" or "needs you", which the scripts read as one.
- **A `/decide` buffer or page is open:** `**Needs you:** answer the buffer at <path>` (or the page's link).
- Only for replies that end a turn. Progress updates, subagent reports and permission prompts don't take the line.
