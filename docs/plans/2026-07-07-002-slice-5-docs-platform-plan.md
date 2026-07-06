---
type: feat
status: active
origin: docs/roadmap.md §5/§6 + 9c, as amended by the 2026-07-06 ce-doc-review
  and ratified in logs/decisions/2026-07-06-slice-review-decisions.md
  (Decisions 1A, 2A, 3A)
---

# Slice 5 — the docs platform: one generator, INDEX, help picker, Q&A, guides

## Summary

Build the generated documentation platform that replaces every
hand-maintained doc surface. Ratified architecture (Decision 2A): **one
tool, three outputs** — markdown-with-frontmatter sources render to (i)
HTML pages, (ii) the HUB.html tile dashboard, (iii) the INDEX's doc
entries. Ratified end-state (Decision 3A): each surface owns one question;
`overview.md` and `HUB.md` are deleted at the END, after their generated
replacements render. Prerequisite: stow-claude-config (skills subset).

**Design specs the review demanded are IN this plan** (they were undefined
in the roadmap): the INDEX record schema, per-source preview/Enter
semantics, the Q&A mode's interaction design, and the guide-page template.
React to them here — changing a spec after U4 lands is rework.

## Scope Boundaries (non-goals)

- No notes-tui code (plan 003). No `/board` HTML feature (9a stays
  deferred; interim `wb board` is remediation U3).
- No 9d registry (unratified proposal, trigger-gated).
- No Decision-4 resolution — only the minimal redaction guard (U8).
- No Jira anything.
- `agent-workbench-findings.html` is NOT converted — it's a point-in-time
  audit with bespoke diagrams; it stays as-is, tiled from a small
  frontmatter sidecar entry (see U4) rather than regenerated.

## Key Technical Decisions

- **Generator stack — recommended: Go, new sibling tool `~/code/docgen`
  (or a `docgen/` package inside cli-kit).** Rationale: the roadmap's own
  §2 answer reserved "index grows real querying/aggregation needs" for
  Go/cli-kit territory — frontmatter aggregation across repos + INDEX
  merging is exactly that; Go gives a real markdown lib (goldmark) and
  html/template for the design system, and it slots into the existing
  personal-CLI stack (notes-tui/cli-kit). Bash+pandoc is the fallback if
  you veto Go at plan review. **This is the one decision worth vetoing
  before ce-work starts.**
- **Template system:** one `html/template` layout carrying the shared
  Catppuccin design system (tokens lifted from the existing pages), with
  per-`kind` blocks (page, guide, hub). Existing hand-tuned pages define
  the visual contract; the first rendered page must be visually diffed
  against its hand-built predecessor.
- **Frontmatter schema (doc sources):** `title`, `status`
  (current|wip|stale|archive → chip), `tile` (one-liner for HUB), `group`
  (personal-workflow|skills|tuis), `kind` (page|guide|hub-only), `updated`.

## INDEX.md record schema (spec — review finding D1)

One fenced JSONL block (machine half) + a rendered table (human half),
generated; fields per entry:

| field | meaning | example |
|---|---|---|
| `id` | stable slug | `tmux-bind-prefix-h` |
| `kind` | `bind` \| `alias` \| `function` \| `script` \| `skill` \| `tui` \| `doc` \| `decision` | `bind` |
| `name` | display name | `prefix+h` |
| `oneliner` | what it does | `open the docs Hub in the browser` |
| `source` | repo-relative path:line | `tmux/.config/tmux/tmux.conf:21` |
| `invoke` | how to run it | `prefix+h` |
| `guide` | link to its guide/doc, if any | `docs/hub.html` |
| `tags` | free list | `[docs, tmux]` |

Scan sources (roadmap §6a, corrected paths): tmux.conf binds, zshrc
aliases/functions, `scripts/.config/scripts/tmux/instructions.md`,
`nvim/.config/nvim/instructions.md`, `~/.claude/skills/*/SKILL.md`
descriptions, `MEMORY.md`, TUI READMEs, `logs/decisions/*.md` +
task-store `## Decisions` sections (provenance). **Fail loudly when a
declared source root is missing** — never emit a silently partial INDEX.

## Implementation Units

### U1: stow-claude-config, skills subset (prerequisite)

- **Goal:** `~/.claude/skills/` becomes version-controlled so the INDEX
  scans durable sources.
- **Files:** new `claude/` stow package in dotfiles →
  `claude/.claude/skills/{decision-buffer,park,parked-items,pr-review-session}/`.
- **Approach:** move the four skill dirs into the package, `stow -t "$HOME"
  claude`, verify symlinks resolve; seed from the existing
  `~/code/tasks/dotfiles--stow-claude-config.md` task record (worktree rule).
  Explicitly EXCLUDE `settings.json` and `parked-items/ledger.jsonl` (state,
  not config) this pass.
- **Test scenarios:** skill invocation still works post-stow (`/park` a test
  note); `stow -n` re-run is a no-op.
- **Verification:** `readlink ~/.claude/skills/park` points into the repo;
  all four skills listed by the harness.

### U2: docgen core — frontmatter + page rendering

- **Goal:** `docgen build` renders every `docs/*.md` with frontmatter into
  `.html` using the shared template; idempotent (second run = no diff).
- **Files:** new tool (see Key Technical Decisions); dotfiles gets a
  `Makefile` target or `scripts/.config/scripts/docgen.sh` wrapper.
- **Approach:** parse frontmatter → goldmark body render → layout template.
  Port the design tokens from `docs/HUB.html`/`wb-guide.html` verbatim
  (both themes + the `data-theme` override contract).
- **Execution note:** test-first on the frontmatter parser and idempotency.
- **Test scenarios:** doc with no frontmatter (loud error); unknown `kind`;
  pipe/HTML-entity content in titles; second-run no-op.
- **Verification:** `docgen build && docgen build` produces zero diff;
  first converted page visually matches its hand-built predecessor.

### U3: Convert existing sources to markdown-with-frontmatter

- **Goal:** `roadmap.md`, `overview.md` (interim — deleted in U9),
  `wb-guide` gain frontmatter; `wb-guide.html` gets a true markdown source
  (`docs/wb-guide.md`) transcribed from the current HTML.
- **Approach:** content-faithful transcription, no rewrites; the generated
  `roadmap.html` replaces the drift-bannered hand render.
- **Verification:** generated pages carry all sections of their
  predecessors (heading-count parity check) and resolve their cross-links.

### U4: HUB generation

- **Goal:** `HUB.html` is generated from doc frontmatter — tiles, chips,
  groups — plus a small sidecar list for non-converted/external entries
  (`agent-workbench-findings.html`, `~/code/notes-tui/notes-guide.html`).
- **Approach:** aggregate all frontmatter, render the tile grid using the
  existing HUB layout; `prefix+h` keeps opening it (path unchanged).
- **Verification:** generated HUB is link-checked (every `href` resolves on
  disk); visual parity with the current dashboard.

### U5: INDEX scan + generation

- **Goal:** `docgen index` emits `docs/INDEX.md` per the schema above.
- **Approach:** per-source parsers (tmux.conf `bind` lines + comments;
  zshrc alias/function lines + adjacent comments; SKILL.md frontmatter
  descriptions; doc frontmatter; decision-doc titles). Missing source root
  → hard error naming the root.
- **Test scenarios:** fixture mini-sources per kind; the fail-loudly case;
  an entry with no guide link.
- **Verification:** INDEX contains every tmux bind currently in tmux.conf
  (spot-check against `tmux list-keys`), all 10+ zsh aliases, all 4 skills.

### U6: help.sh — the fzf picker on prefix+?

- **Goal:** fzf over INDEX entries; `prefix+h` untouched (Decision D2 fix).
- **Per-kind interaction spec (review findings D3/D4):**
  - Preview — `doc`/`guide`: first ~40 lines of the source md; `skill`:
    SKILL.md description + When-to-use; `bind`/`alias`/`function`: the
    source line ± 5 lines of comment context; `tui`: README head;
    `decision`: the doc's title + options list.
  - Enter — `doc`/`guide`: xdg-open the rendered HTML; everything else:
    open the SOURCE in nvim at the line (`nvim +<line> <file>`), in a new
    tmux window. One consistent rule: Enter = "take me to it"; preview =
    "tell me about it". No kind ever executes/launches the thing — running
    is what the thing's own invoke column documents.
- **Files:** `scripts/.config/scripts/tmux/help.sh`, tmux.conf
  (`bind ? new-window "~/.config/scripts/tmux/help.sh"`), zshrc alias
  `h`... no — no new alias; keybind only (avoid alias sprawl).
- **Verification:** live tmux capture smoke test, same method as the wb
  picker rounds.

### U7: Q&A mode — /help skill (interaction spec, review finding D5)

- **Goal:** "why do I have binding X / what does Y do / how do I use Z"
  answered with provenance, not grep.
- **Design:** an agent-side skill (`~/.claude/skills/help/SKILL.md`, lands
  in the U1 stow package): on `/help <question>` the agent reads
  `docs/INDEX.md`, follows `source`/`guide` links (including decision docs
  for "why" questions), and answers in chat citing `file:line`. No-match
  state: say so and name the nearest entries — never invent. Terminal
  entry point: `help.sh` gains an `--ask` note pointing at `/help` (the
  picker itself stays deterministic; no LLM in bash).
- **Verification:** three canned questions — a why (binding provenance), a
  what (skill), a how (notes-tui) — answered with correct citations.

### U8: Redaction guard (Decision-4 interim)

- **Goal:** INDEX/HUB/HTML outputs never carry employer content.
- **Approach:** docgen carries a work-repo denylist (`be--monorepo`,
  `frontend`, `lib--algorithms`, `terraform-gcp`, `tool--*`, `qa--tools`,
  `docs--architecture`); MEMORY.md-derived and task-store-derived entries
  matching it render name-free or are dropped, with a build-log line saying
  what was withheld (loud, not silent).
- **Verification:** fixture MEMORY.md with a work line → excluded + logged.

### U9: Absorb-and-delete (LAST — Decision 3A)

- **Goal:** the end-state: `overview.md/.html` and `HUB.md` deleted.
- **Approach:** move overview's unique content into its owners (keybind
  tables → INDEX; skill/TUI guides → U10 guide pages; shell/terminal
  section → a small generated `setup.md` guide page). Update every
  cross-reference (roadmap.md, wb-guide, HUB footer, tasks repo). Delete.
- **Verification:** repo-wide grep: zero dangling references to
  `overview.md|overview.html|HUB.md`; HUB + INDEX carry the content.

### U10: Per-skill/TUI guide pages (9c, born generated)

- **Goal:** `decision-buffer`, `park`, `parked-items`, `pr-review-session`,
  `notes-tui` (+ a `wb` source from U3) each get a generated guide page.
- **Template (review finding D7 — wb-guide's REAL structure):** overview /
  try-it-now / per-verb-or-command reference / known rough edges /
  next-steps-or-reverting. Authored as `docs/guides/<name>.md`.
- **Approach:** content sourced from each SKILL.md + overview's current
  per-skill depth (this is where that content migrates before U9 deletes
  overview). HUB tiles repoint from `overview.html#<skill>` anchors to the
  guide pages.
- **Verification:** every HUB skill tile resolves to a generated guide;
  guides render with all five template sections.

## Sequencing

U1 ∥ U2 first → U3 → U4/U5 (∥) → U6/U7/U8 (∥) → U10 → U9 strictly last.

## Deferred to Implementation

- Generator language final call (Go recommended — veto at plan review, not
  mid-build).
- Whether findings-doc-style bespoke pages get a `raw-html` passthrough
  kind in docgen (needed only if another bespoke page ever gets written).
- INDEX one-liner extraction heuristics per source (comment-adjacent
  parsing will need per-file tuning).

## Verification (slice level)

`docgen build && docgen index` from clean → every doc surface regenerates
byte-identically on a second run; HUB link-check passes; `prefix+?` picker
and `/help` answer the three canned questions; zero hand-maintained HTML
files remain in `docs/` (grep for files without a `.md` source or sidecar
entry).
