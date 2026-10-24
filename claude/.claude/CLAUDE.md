# Global instructions (apply across all projects)

## Design decisions → decision-buffer, not AskUserQuestion

When an answer is needed in writing, asynchronously, in Jet's editor — and the direction is already basically agreed — route it through the **`decision-buffer`** skill (`~/.claude/skills/decision-buffer/SKILL.md`) instead of an AskUserQuestion menu. The skill itself handles the align-check-before-any-buffer sequence (present findings and a proposed direction in chat first, confirm whether the remaining open points should go to a buffer) and picks from six shapes (choice, findings-review, interview, paste-target, confirm-facts, code-review-triage) by the kind of answer needed — see the skill for the full trigger, shape-selection table, and close-contract rules (format templates, per-decision Recommendation/Questions-Notes structure, companion-HTML trigger, rewrite-fresh-not-append). For a batch answered at Jet's own pace on a page rather than in nvim, the page-based options are the **`decision-page`** skill (each item has its own options) and the **`review-page`** skill (one shared verdict list); `~/.claude/skills/decision-page/SKILL.md` says which to use. Don't restate the skill's template here; it drifts. If this section disagrees with the skill file, the skill is canonical — fix this section, not the skill.

Preferred open mode is a background **tmux split-pane** that blocks on a wait-channel (the user runs Claude Code inside tmux); closing the buffer re-invokes the agent. Fallbacks: `gnome-terminal --wait`, then a manual `! nvim <path>`. The user explicitly does NOT want a separate terminal window when tmux is available. Treat the closed buffer (checked boxes + inline notes) as the answer; answer any Questions/Notes before acting on a selection.

Trivial decisions (one obvious option, yes/no with an obvious default) skip the buffer — just proceed or ask briefly in chat. See the skill for the full format and parse-on-return contract.

## Worktree setup → seed from an existing task record

When setting up a new worktree (via `ce-worktree`, `wb new`, or otherwise) for a branch/ticket, first check the central task store at `~/code/tasks/` for an existing task file matching the target repo and name/ticket number — filter by the `repo:` frontmatter field (the repo's basename), then match the slug. Task filenames are `<repo>--<slug>.md` where the slug has `/` and `.` sanitized to `-` (e.g. repo `be--monorepo`, branch `feat/sfb-1062-…` → look for `~/code/tasks/be--monorepo--feat-sfb-1062-*.md`). If one exists, read it and use it as the starting point/context for the work — it often already captures the problem, the intended fix, and prior decisions. Surface what you found rather than starting from scratch. If none matches, proceed normally.

(Superseded the older per-repo `scratch/tasks/` convention — see `dotfiles/docs/roadmap.md` §0/§3 and `~/code/tasks/README.md` for the schema and why it moved centrally.)

## Worktree setup → copy gitignored bootstrap files (all repos)

When creating a new git worktree in **any** repo, copy the gitignored local bootstrap files from the main checkout into the new worktree so it runs with **zero per-worktree edits**. Fresh worktrees only contain tracked files, so anything gitignored (local config, secrets, installed deps) is missing and the app/dev-server/Makefile targets won't run.

- Identify what's gitignored-but-required: local config files (e.g. `config.hjson`, `.env`/`.env.*`), credential files, and installed-dependency dirs (`node_modules/`, vendored deps). Check `.gitignore` and how the run/build commands resolve paths.
- Copy **every** location a tool reads from, not just one. (Tooling sometimes copies from a nested path, not the repo root — e.g. a Makefile `run` target that copies `apps/x/config.hjson`; seeding only a root copy leaves the nested one missing.) For big dirs like `node_modules/`, copy or symlink — whatever gets it runnable without a reinstall.
- Never "fix" a missing-bootstrap-file by editing tracked build files with a worktree-relative path (e.g. `../../../../apps/x/config.hjson`) — that path is specific to the worktree's nesting depth and breaks the command in the main checkout and other worktrees. Seed the file instead.

Repo-specific specifics live in that repo's own memory/AGENTS.md; this rule is the general principle.

## wb sessions → stamp reviews immediately

After any `/ce-code-review` pass completes inside a `wb` session, run `wb reviewed` immediately — it stamps the task file's `reviewed:` frontmatter field with today's date, which `wb board --html`'s review stage relies on to render that stage as done. This is a convention, not automation: there is no hook wiring it up, so it only works if it's actually run each time. See `docs/wb-guide.md`'s board section for what this feeds into.

## GitHub CLI → use `pgh` for non-Sportable repos

The default `gh` is authenticated with a fine-grained PAT scoped to the **Sportable org**, so it can only see Sportable-org repos. For any repo **not** owned by the Sportable org — personal repos under `github.com/jetnoli-sportable/…`, or any other owner — use the **`pgh`** shell function instead of `gh` for all GitHub API operations (`pr create`, `issue`, `api`, `repo view`, etc.). `pgh` injects the personal-account PAT from the system keyring (defined in `~/.zshrc`).

- Decide by the origin remote owner: run `git remote get-url origin`. Owner `jetnoli-sportable` (or anything non-Sportable) → `pgh`. Sportable-org owner → plain `gh`.
- Signal you picked wrong: a `gh` call failing with `GraphQL: Could not resolve to a Repository` means the Sportable token can't see it — retry the same command with `pgh`.
- This only affects the `gh` CLI. Plain `git` push/pull works everywhere via SSH and needs no change.

## HTML artifacts → durable landing path first, never scratch-only

Any HTML doc worth publishing as a claude.ai Artifact must FIRST be written to a durable landing path — the repo's `docs/` when it's tracked-worthy, else the central task store's dossier area (`~/code/tasks/dossiers/<repo>--<slug>/`). Never leave it only in the session scratchpad or `/tmp`: scratch dirs get cleaned and the doc becomes unrecoverable (this happened; see `dotfiles/docs/roadmap.md` 9d). Publishing to claude.ai is the preview, the file on disk is the artifact.

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
