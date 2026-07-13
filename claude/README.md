# claude — curated ~/.claude config (skills subset)

Version-controls the hand-authored, portable skills under `~/.claude/skills/`
so the docs INDEX can scan durable sources and a fresh machine reproduces them.

Stow with `--no-folding` (install.sh does this): `~/.claude/` holds live
untracked state, so individual files are symlinked into the existing real
directory instead of replacing it.

## Tracked

- `skills/decision-buffer/` — design decisions via nvim buffer docs
- `skills/handoff/` — route in-conversation discussion to the right worker (switch or spawn)
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

- `.claude/settings.recommended.json` — two independent things worth
  merging separately:
  - a `permissions.allow` rule that pre-authorizes reads under
    `~/code/tasks/`, so spawned agents (`/handoff`, `wb new --agent`) never
    hit the "Do you want to proceed?" read-outside-cwd prompt for that path
    (`docs/roadmap-handoff.md`, "Dry-run findings", finding 4). Its exact
    `Read(...)` glob syntax was pattern-matched against other
    `permissions.allow` rules already on this machine (not verified against
    the installed Claude Code version's own docs) — smoke-test after
    merging: add it, start a fresh session, confirm the prompt no longer
    fires for a `~/code/tasks/` read.
  - a `hooks.PreToolUse` block wiring every `Bash`/`Edit`/`Write`/`MultiEdit`
    tool call through `tasks-git-hooks/pretooluse-guard.sh`, which asks
    before a command looks like it would rewind history inside
    `~/code/tasks` (see [`tasks-store-guards.md`](../docs/guides/tasks-store-guards.html)
    for the full three-layer model this is one layer of). Needs
    `wb install-hooks` to have installed the script itself first — this
    file only wires Claude Code up to call it.

  Merge both blocks into your real, untracked `~/.claude/settings.json` by
  hand — this file is reference only, never auto-merged.
