# claude — curated ~/.claude config (skills subset)

Version-controls the hand-authored, portable skills under `~/.claude/skills/`
so the docs INDEX can scan durable sources and a fresh machine reproduces them.

Stow with `--no-folding` (install.sh does this): `~/.claude/` holds live
untracked state, so individual files are symlinked into the existing real
directory instead of replacing it.

## Tracked

- `skills/decision-buffer/` — design decisions via nvim buffer docs
- `skills/park/` — capture "later" items to the ledger
- `skills/parked-items/` — weekly review of parked items
- `skills/pr-review-session/` — PR review worktree/tmux sessions

## Deliberately NOT tracked (this pass)

- `~/.claude/settings.json` — mixes machine-local state (enabled plugins,
  theme, permission allowlists) with portable config; needs its own
  curation + secret audit before it's safe to track (it currently
  references Sportable-owned plugin marketplaces, which shouldn't land in
  this personal repo without a deliberate call).
- `~/.claude/parked-items/ledger.jsonl` — state, not config.
- `~/.claude/projects/`, `todos/`, caches, telemetry — machine state,
  never track.

## Recommended settings (not auto-applied)

- `.claude/settings.recommended.json` — a `permissions.allow` rule that
  pre-authorizes reads under `~/code/tasks/`, so spawned agents (`/handoff`,
  `wb new --agent`) never hit the "Do you want to proceed?" read-outside-cwd
  prompt for that path (`docs/roadmap-handoff.md`, "Dry-run findings",
  finding 4). Merge its `permissions.allow` entries into your real, untracked
  `~/.claude/settings.json` by hand — this file is reference only, never
  auto-merged. Its exact `Read(...)` glob syntax was pattern-matched against
  other `permissions.allow` rules already on this machine (not verified
  against the installed Claude Code version's own docs) — smoke-test after
  merging: add it, start a fresh session, confirm the prompt no longer
  fires for a `~/code/tasks/` read.
