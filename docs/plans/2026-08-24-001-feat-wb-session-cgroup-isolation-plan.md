---
title: "feat: wb per-agent cgroup isolation + concurrency cap"
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
type: feat
date: 2026-08-24
origin: ~/code/tasks/dotfiles--wb-session-memory-mitigations.md
decision_record: logs/decisions/2026-08-24-wb-session-memory-mitigations.md
---

# feat: wb per-agent cgroup isolation + concurrency cap

Structural fix for the recurring **systemd-oomd crash that wipes every wb tmux
session at once** (twice on 2026-08-24). Puts each `claude` agent in its own
memory-bounded transient systemd scope so oomd kills one runaway agent instead
of the shared Ghostty scope that holds the tmux server and every other session.

---

## Summary

The tmux **server** is pinned for life to one Ghostty surface scope
(`app-ghostty-surface-transient-*.scope`); every wb session's panes fork from
that server, so **all sessions share one cgroup**. When that scope wins the
memory-pressure race, oomd SIGKILLs it and every session dies together. PR #40's
lazy-nvim lowered the per-session floor but the crash **recurred 8 hours later**.

The fix, decided in `logs/decisions/2026-08-24-wb-session-memory-mitigations.md`:

1. **Per-agent cgroup isolation (Direction 1, primary).** A `claude()` zsh
   wrapper — gated to wb panes — re-launches the real binary under
   `systemd-run --user --scope` with `MemoryHigh=6G`/`MemoryMax=8G`. Because
   every launch path types `claude` into a wb pane's zsh, one wrapper covers the
   scripted sites **and** manually-typed `claude` (the common `wb resume` case).
2. **Concurrency cap (Direction 2, complementary).** A pre-launch warning when
   ≥8 live agents already run, plus the live-agent count surfaced in the picker
   and `wb board`. Warn-only — Direction 1 does the real containment.

**Capability + contract, both probed on this box (not assumed):**
- `systemd-run --user --scope -p MemoryMax=…` runs cleanly (systemd 255, exit 0);
  the `memory` controller is delegated to the user manager (`cgroup.controllers`
  = `cpu memory pids`); cgroup v2 unified. No root, no config change.
- A `claude` launched under the scope (with **or** without `exec`) leaves
  `pane_current_command` reading exactly **`claude`** — so the wrapper does **not**
  break the live-agent detection that the picker, board, handoff, and tests all
  key on.

**Target repo:** `dotfiles` (this repo). All paths below are repo-relative.

---

## Problem Frame

- **Trigger:** N concurrent `claude` agents (the debug pass reconstructed ~9 at
  the 19:16 crash), all in the single Ghostty cgroup, drive aggregate usage past
  oomd's 60%-pressure-for-20s threshold.
- **Symptom:** oomd kills the whole surface scope → tmux server + all sessions
  gone at once.
- **Why prior fix was insufficient:** PR #40 only made nvim/gopls lazy; it did
  nothing about blast radius (still one shared scope) or agent count (no cap).
- **In scope:** isolate `claude`; warn + surface the count.
- **Not in scope this iteration:** isolating nvim/gopls (D4 → A; deferred),
  swap headroom, moving the tmux server out of the Ghostty scope (largely falls
  out of Direction 1 — the Ghostty scope shrinks to server + idle shells).

---

## Requirements

- **R1** — Every `claude` process started in a wb-managed pane runs inside its
  own transient `systemd --user` scope with `MemoryHigh=6G` and `MemoryMax=8G`.
- **R2** — Coverage includes manually-typed `claude` (the `wb resume` common
  case), not only the scripted `--agent`/handoff/ask launches.
- **R3** — `claude` started outside a wb pane (e.g. this ad-hoc session, session
  name `0`) is **unchanged** — no scope, no wrapper side effects.
- **R4** — The wrapper preserves `pane_current_command == "claude"` so
  `tmux_session_agent_state` (`scripts/.config/scripts/tmux/lib.sh:171`),
  `tmux_claude_panes` (`lib.sh:115`), the picker count (`wb.sh:5236-5248`), the
  HTML board (`wb.sh:3027-3042`), handoff (`handoff.sh:329`), and their tests
  keep working.
- **R5** — Quitting `claude` returns to the shell prompt as it does today (no
  `exec`-replacing the pane's interactive shell).
- **R6** — Starting a `claude` when ≥ `WB_AGENT_WARN_AT` (default 8) live agents
  already exist prints a non-blocking warning to stderr and proceeds.
- **R7** — The live-agent count is visible in the picker header and in
  `wb board` (plain-text) output.
- **R8** — Memory limits and the warn threshold are overridable env vars
  (`WB_AGENT_MEM_HIGH`, `WB_AGENT_MEM_MAX`, `WB_AGENT_WARN_AT`) with the defaults
  above, so tuning needs no code edit (`~/.zshrc.local` is the host-local seam).

---

## Key Technical Decisions

All four resolved via the decision buffer (`decision_record` in frontmatter);
recorded here for traceability.

- **KTD1 (D1→A): zsh `claude()` wrapper gated to wb panes.** One chokepoint
  covers all four launch sites because each types `claude` into a wb pane's zsh.
  Chosen over a per-session PATH shim (B: adds a new env seam + second file for
  marginal isolation benefit) and over wrapping only scripted sites (C: reopens
  the manual-launch gap).
- **KTD2 (D2→C): `MemoryHigh=6G` + `MemoryMax=8G`.** Throttle band before a hard
  backstop. Starting values, explicitly tunable once per-scope `memory.current`
  is observable. A heavy `go build` child runs inside the agent scope and counts
  against the cap — 8G is generous enough that a normal compile never trips it;
  "heavy children get their own scope" is a future refinement.
- **KTD3 (D3→C): warn at 8, surface the count, never block.** Direction 1 is the
  real containment, so a hard block is disproportionate; a silent warn misses the
  chance to make the count ambient.
- **KTD4 (D4→A): isolate `claude` only this iteration.** gopls (the *original*
  driver, now lazy) stays in the shared scope; isolating it is a deferred
  fast-follow. This is an accepted **partial** fix — see Risks.
- **KTD5 (probe-driven, refines the buffer snippet): no `exec`, resolve the real
  binary.** The buffer's snippet used `exec systemd-run … command claude`. Two
  corrections from probing: (a) drop `exec` — probe B showed the non-exec form
  also preserves `pane_current_command == claude` (R4) **and** keeps quit→prompt
  behavior (R5); `exec` would kill the pane's shell on quit. (b) `command` is a
  shell builtin `systemd-run` cannot exec — resolve the real path with
  `whence -p claude` (zsh) and pass that absolute path to `systemd-run`, which
  also sidesteps any wrapper recursion.

---

## High-Level Technical Design

Every `claude` invocation flows through the one wrapper; the gate decides
isolate-vs-passthrough, and (when isolating) the count-warn fires first.

```mermaid
flowchart TD
    A["user or send-keys types: claude"] --> B{"in tmux AND<br/>@wb_repo set?"}
    B -- no --> P["command claude (unchanged)  · R3"]
    B -- yes --> C["count live agents<br/>(tmux list-panes -a | grep -c claude)"]
    C --> D{"count ≥ WB_AGENT_WARN_AT (8)?"}
    D -- yes --> W["warn to stderr (non-blocking)  · R6"]
    D -- no --> E
    W --> E["real=$(whence -p claude)"]
    E --> F["systemd-run --user --scope --quiet<br/>--unit=wb-agent-&lt;session&gt;-$$<br/>-p MemoryHigh=$H -p MemoryMax=$M<br/>$real \"$@\"   (NO exec)  · R1,R5,KTD5"]
    F --> G["pane_current_command still == 'claude'  · R4"]
```

**Scope topology (the payoff):** after isolation, each agent is a sibling scope
under `app.slice`; the Ghostty scope shrinks to the tmux server + idle shells (+
lazy nvim). oomd now evaluates each scope separately and kills the single worst
agent — the server and other sessions survive. Full before/after diagram:
`logs/decisions/2026-08-24-wb-session-memory-mitigations.html`.

---

## Implementation Units

### U1. `claude` isolation wrapper (zsh), gated to wb panes

**Goal:** the core of Direction 1 — a `claude()` function that re-launches the
real binary under a memory-bounded transient scope in wb panes, and is a no-op
elsewhere. Because the scripted sites (`wb.sh:820`, `handoff.sh:229`,
`ask.sh:18`) all type `claude` into a wb pane's zsh, this one function
automatically covers them plus manual launches — no edits to those sites needed.

**Requirements:** R1, R2, R3, R4, R5, R8, KTD1, KTD2, KTD5.

**Dependencies:** none (first unit).

**Files:**
- `zsh/.zshrc` — add the `claude()` function (near the existing inline `pgh()`
  function ~`:109`) and the three overridable limit/threshold env-var defaults.
  Confirm the `~/.zshrc` → `zsh/.zshrc` symlink is stow-managed (it is).
- `scripts/.config/scripts/tmux/tests/wb-claude-wrapper.test.sh` — **new** test
  file (follow the `lib-claude-panes.test.sh` private-socket + stub pattern).

**Approach:**
- Gate: `[[ -n $TMUX ]]` **and** a non-empty `tmux show-options -qv @wb_repo`
  (the `-q` suppresses the missing-option error; empty string ⇒ not a wb pane ⇒
  passthrough). This satisfies R3 — the current ad-hoc session (name `0`, no
  `@wb_repo`) falls through to `command claude`.
- Isolate branch (no `exec`, per KTD5):
  `real=$(whence -p claude)` then
  `systemd-run --user --scope --quiet --unit="wb-agent-${session}-$$" -p MemoryHigh=$WB_AGENT_MEM_HIGH -p MemoryMax=$WB_AGENT_MEM_MAX "$real" "$@"`.
- `session=$(tmux display -p '#{session_name}')`; sanitize to a
  systemd-unit-safe token (wb session names are already `repo--slug` sanitized,
  but defensively strip anything outside `[A-Za-z0-9_-]` and truncate) so
  `--unit` never fails on an odd name.
- Env defaults at the top of the block, each `${VAR:=default}` so `~/.zshrc.local`
  can override: `WB_AGENT_MEM_HIGH=6G`, `WB_AGENT_MEM_MAX=8G`,
  `WB_AGENT_WARN_AT=8` (WARN_AT consumed in U2).
- Passthrough branch: `command claude "$@"` (bypasses the function; no recursion).

**Technical design** (directional — not final syntax):
```zsh
: ${WB_AGENT_MEM_HIGH:=6G} ${WB_AGENT_MEM_MAX:=8G} ${WB_AGENT_WARN_AT:=8}
claude() {
  [[ -n $TMUX ]] || { command claude "$@"; return }
  local repo; repo=$(tmux show-options -qv @wb_repo 2>/dev/null)
  [[ -n $repo ]] || { command claude "$@"; return }
  # (U2 inserts the count-warn here)
  local sess; sess=$(tmux display -p '#{session_name}' | tr -c 'A-Za-z0-9_-' '-')
  local real; real=$(whence -p claude)
  systemd-run --user --scope --quiet --unit="wb-agent-${sess}-$$" \
    -p MemoryHigh=$WB_AGENT_MEM_HIGH -p MemoryMax=$WB_AGENT_MEM_MAX \
    "$real" "$@"
}
```

**Patterns to follow:** inline-function style of `pgh()` in `zsh/.zshrc`; the
`${VAR:=default}` + `~/.zshrc.local` override idiom already used in that file.

**Test scenarios** (stub `systemd-run` as a fake on `PATH` that echoes its argv
to a temp file then execs the trailing command — lets us assert the invocation
shape without a real user-manager/cgroup, which the read-only Docker suite can't
provide):
- **Passthrough, no tmux:** with `$TMUX` unset, calling the function runs the
  stub `claude` directly; the `systemd-run` stub is **never** invoked. (R3)
- **Passthrough, tmux but no `@wb_repo`:** in a private-socket session with no
  `@wb_repo` option set, `systemd-run` stub is never invoked. (R3)
- **Isolate, wb pane:** in a session with `@wb_repo` set, the `systemd-run` stub
  **is** invoked, and its recorded argv contains `--scope`, `--user`,
  `MemoryHigh=6G`, `MemoryMax=8G`, a `--unit=wb-agent-…` token, and the resolved
  absolute `claude` path (not the literal string `command`). (R1, KTD5)
- **Env override:** with `WB_AGENT_MEM_MAX=4G` exported, the recorded argv shows
  `MemoryMax=4G`. (R8)
- **Unit-name sanitization:** a session name containing a `.`/`/` yields a
  `--unit` token with only `[A-Za-z0-9_-]`. (R1 robustness)
- **Detection contract (integration):** launch the wrapped stub `claude` (stub =
  renamed `sleep`, per the lib-claude-panes convention) in a real private-socket
  pane and assert `pane_current_command` reads `claude`. **If** `systemd-run
  --user` is unavailable in the harness, `skip` this scenario with an explicit
  message (it is covered by the manual verification checklist instead — see
  Verification Contract). (R4)
- `Covers` the R5 quit→prompt behavior is verified manually (Verification
  Contract), not in the bash suite (needs a real interactive quit).

**Execution note:** Start with the passthrough scenarios (they need no
`systemd-run` at all and lock in R3 first), then the stub-argv scenarios.

**Verification:** in a real wb session, `claude` launches and
`systemctl --user list-units 'wb-agent-*'` shows an active scope with the
expected `MemoryMax`; in the ad-hoc session `0`, `claude` starts with no scope.

---

### U2. Pre-launch concurrency warning (in the wrapper)

**Goal:** implement the warn half of Direction 2 at the same chokepoint — before
isolating, count live agents server-wide and warn (non-blocking) at the
threshold. Placing it in the wrapper (not `cmd_new`) means it also covers
manually-typed launches, matching KTD1's "unify through the wrapper" logic.

**Requirements:** R6, R8, KTD3.

**Dependencies:** U1 (extends the same function).

**Files:**
- `zsh/.zshrc` — insert the count-warn block into `claude()` at the marked point
  (after the wb-pane gate, before the `systemd-run` launch).
- `scripts/.config/scripts/tmux/tests/wb-claude-wrapper.test.sh` — extend with
  warn scenarios.

**Approach:**
- Count: `local n; n=$(tmux list-panes -a -F '#{pane_current_command}' 2>/dev/null | grep -cx claude)` — a server-wide count of panes whose foreground is `claude`. (`-x` for exact match; consistent with the `== "claude"` contract.)
- If `(( n >= WB_AGENT_WARN_AT ))`, print to **stderr**:
  `wb: ${n} claude agents already running (warn ≥ ${WB_AGENT_WARN_AT}); starting another. Ctrl-C to abort.` Then proceed (no prompt, no block — R6/KTD3).
- The count is taken before the new agent starts, so N is the pre-existing count.

**Patterns to follow:** stderr-warn style already used across `wb.sh` (`echo …
>&2`); the `tmux list-panes -a` server-wide enumeration mirrors the picker's
live-session iteration.

**Test scenarios:**
- **Below threshold, silent:** with fewer than `WB_AGENT_WARN_AT` stub-`claude`
  panes live, launching emits no warning on stderr. (R6)
- **At/above threshold, warns:** with `WB_AGENT_WARN_AT=2` and 2 stub-`claude`
  panes already live, launching a third prints the warning to stderr **and**
  still invokes the `systemd-run` stub (never blocks). (R6, KTD3)
- **Threshold override:** `WB_AGENT_WARN_AT` exported to a different value shifts
  where the warning first fires. (R8)

**Execution note:** reuse U1's `systemd-run` stub; drive the live count by
launching stub-`claude` panes on the private socket (the lib-claude-panes
convention) rather than mocking the count function, so the real
`tmux list-panes -a | grep -cx claude` path is exercised.

**Verification:** open 8 agents, start a 9th → warning prints, agent still
starts.

---

### U3. Surface the live-agent count in the picker and `wb board`

**Goal:** the ambient-awareness half of Direction 2 — make the current
live-agent count visible where the user already looks, so the count is a glance
not a guess.

**Requirements:** R7, KTD3.

**Dependencies:** none on U1/U2 for correctness, but land after them (same
feature). Uses existing enumeration (`tmux_claude_panes`, `wb.sh:5236-5248`).

**Files:**
- `scripts/.config/scripts/tmux/wb.sh` — (a) picker: add a total live-agent
  count to the picker header/prompt near `render_rows`/`picker` (`wb.sh:5521-5529`,
  `5673-5742`); (b) `cmd_board` plain-text path (`wb.sh:4903-4933`): add a single
  summary line reporting the live-agent count. (The HTML board already consults
  live sessions via `wb_board_live_session_for` — add the same count to its
  header for parity.)
- `scripts/.config/scripts/tmux/tests/wb-board.test.sh` — extend the existing
  board test with a live-count assertion.

**Approach:**
- Add a small helper `wb_live_agent_count` (server-wide
  `tmux list-panes -a … | grep -cx claude`, the same expression U2 uses — define
  once in `lib.sh` and call from both the wrapper's sibling context and wb.sh if
  practical; otherwise a one-liner in each). Prefer the shared helper in `lib.sh`
  to avoid drift.
- Picker: render `agents: N live` in the header line.
- Board (plain text): emit e.g. `live agents: N (warn ≥ 8)` as a header/footer
  line above the task table. Keep it one line — the plain board is otherwise
  task-store-only.

**Patterns to follow:** `wb_session_urgency`/`collect_live_rows` for live
enumeration; `cmd_board`'s existing `column -t` table assembly.

**Test scenarios:**
- **Board shows count:** with a stubbed `tmux_claude_panes` (per the
  `wb-lifecycle.test.sh:113-123` redefine convention) reporting 3 agents,
  `wb board` output contains a `live agents: 3` line. (R7)
- **Board with zero agents:** reports `live agents: 0` (or omits gracefully — pick
  one and assert it), never errors when no sessions exist. (R7 edge)
- `Test expectation:` picker header rendering is verified manually (fzf UI) — the
  bash suite asserts the count **helper** value, not the interactive header.

**Verification:** `wb board` shows the live-agent line matching
`tmux list-panes -a | grep -cx claude`; picker header shows the same.

---

### U4. Docs, docgen regen, and record-keeping

**Goal:** document the new isolation/cap behavior and the tunable env vars, and
regenerate the docs platform so the change is discoverable via `/help`.

**Requirements:** supports R8 discoverability; project docgen convention.

**Dependencies:** U1–U3 (document what was built).

**Files:**
- `docs/wb-guide.md` (or the correct indexed source — **not** the generated
  `.html`/`INDEX`): add a short "Session memory isolation" subsection covering
  the per-agent scope, the three env vars + defaults, the `~/.zshrc.local`
  override seam, and the warn threshold.
- Rerun `docgen.sh` after editing the indexed source (per repo convention —
  never hand-edit generated `.html`/`INDEX.md`).
- Fold the decision record + this plan into the bookkeeping (see DoD): flip
  `~/code/tasks/dotfiles--wb-session-memory-mitigations.md` status, and note the
  gopls fast-follow.

**Approach:** prose + a one-line table of the env vars. Keep it inside the
existing wb-guide structure; match the generated-doc visual language.

**Test scenarios:** `Test expectation: none — docs/generated content, no
behavioral code.` Verify docgen runs clean (no diff drift beyond the intended
change) and the pre-commit docgen hook passes.

**Verification:** `docgen.sh` exits clean; `/help "how do I limit agent memory"`
surfaces the new subsection.

---

## Scope Boundaries

**In scope:** per-agent `claude` cgroup isolation (wrapper + limits), pre-launch
warn, live-count surfacing, docs.

### Deferred to Follow-Up Work
- **Isolate nvim/gopls (D4→B).** gopls was the original driver and still launches
  in the shared Ghostty scope when Enter is pressed in win1. The U1 wrapper is
  built to extend to nvim trivially; do it as a fast-follow if post-ship
  measurement shows unisolated gopls still pushes the Ghostty scope to the top of
  oomd's kill list. **Tracked as a known residual risk (see Risks).**
- **Per-child sub-scopes** (give a heavy `go build`/browser its own scope so it
  can't trip the agent's `MemoryMax`) — future refinement of KTD2.
- **gopls per-instance memory tuning** (`GOMEMLIMIT`) — complementary lever from
  the task file; pairs with the nvim-isolation follow-up.

### Out of scope
- Swap headroom changes (a stopgap, orthogonal).
- Moving the tmux server to its own scope — largely obtained for free by
  Direction 1 (the Ghostty scope shrinks to server + idle shells), not worth a
  dedicated change.
- Lowering `DefaultMemoryPressureLimit` in `oomd.conf` — a blunt global lever
  that doesn't fix blast radius.

---

## Risks & Dependencies

- **Partial fix (accepted, KTD4).** With only `claude` isolated, a few
  manually-opened nvim/gopls instances can still make the Ghostty scope the
  highest-pressure one and reproduce the crash. Mitigation: the deferred
  nvim-isolation follow-up; ship-then-measure using the per-scope observability
  this plan unlocks.
- **`go build` inside the agent scope (KTD2).** A large compile counts against
  the agent's `MemoryMax=8G` and could OOM the agent. Mitigation: 8G is generous;
  the value is env-tunable; per-child sub-scopes are a deferred refinement.
- **Detection-contract regression (R4).** If any launch path ends up **not**
  reading `pane_current_command == claude`, the picker/board/handoff and their
  tests break. Mitigation: probed both exec/no-exec forms preserve it; U1's
  integration test asserts it (skipped only where `systemd-run --user` is
  unavailable, then covered by the manual checklist).
- **Global-zsh blast radius (KTD1).** The function is parsed by every interactive
  zsh. Mitigation: it no-ops outside wb panes (R3); the gate is the first thing
  it does.
- **Test-harness limitation.** The read-only Docker suite has no systemd user
  manager, so real cgroup creation isn't unit-testable — the invocation *shape*
  is (via the `systemd-run` stub), and real behavior is covered by manual
  verification. Not a blocker, but the reason a manual checklist exists.

---

## Verification Contract

1. **Unit tests green:** `wb-claude-wrapper.test.sh` (new) and the extended
   `wb-board.test.sh` pass in the Docker suite; the suite's known-failure floor
   (3 env-dependent files) is unchanged — don't read that floor as a regression.
2. **Manual verification (real cgroups — author a tickable HTML checklist per the
   repo convention, durable path + artifact):**
   - In a real wb session: `claude` starts; `systemctl --user list-units
     'wb-agent-*'` shows an active scope with `MemoryMax=8G`; `pane_current_command`
     reads `claude`; quitting `claude` returns to the shell prompt (R5).
   - In the ad-hoc session `0`: `claude` starts with **no** `wb-agent-*` scope (R3).
   - Env override: `WB_AGENT_MEM_MAX=4G claude` in a wb pane → scope shows 4G (R8).
   - Warn: with 8 live agents, starting a 9th prints the warning and still starts (R6).
   - Count surfaces: `wb board` and the picker header show the live count (R7).
   - **Blast-radius smoke:** deliberately drive one agent's scope past `MemoryMax`
     (e.g. a memory hog) and confirm only that scope is killed — tmux server and
     other sessions survive.
3. **docgen clean:** `docgen.sh` runs without drift beyond the intended edit;
   pre-commit docgen hook passes.

---

## Definition of Done

- [ ] U1–U4 implemented; new/extended tests green; docgen clean.
- [ ] Manual verification checklist (HTML, durable path + artifact) authored and
      its automated-done vs to-verify split completed.
- [ ] `~/code/tasks/dotfiles--wb-session-memory-mitigations.md` flipped from
      `planned` to done on merge; the gopls-isolation follow-up captured as a new
      planned task (and `/park`ed if not filed immediately).
- [ ] Memory `2026-08-24-tmux-oom-crash-and-recovery` updated with the shipped
      mitigation + PR link.
- [ ] Worktree created via `wb new` (not plain `git worktree add`) so
      docgen's logs/decisions symlinks exist and the pre-commit hook passes.

---

## Sources & Research

- Decision record (all four KTDs): `logs/decisions/2026-08-24-wb-session-memory-mitigations.md` (+ `.html` companion with the before/after diagram).
- Origin task: `~/code/tasks/dotfiles--wb-session-memory-mitigations.md`.
- Root-cause diagnosis: this session's `/ce-debug` pass; memory `2026-08-24-tmux-oom-crash-and-recovery`.
- Code seams (verified): launch sites `wb.sh:820`, `handoff.sh:229`, `ask.sh:18`; manual gap `cmd_resume` `wb.sh:1107`; detection `lib.sh:115,171`; picker `wb.sh:5236-5248,5521-5529,5673-5742`; board `wb.sh:4903-4933,3027-3042`; no existing guardrail (`wb.sh:791-792` is comment-only); test template `tests/lib-claude-panes.test.sh`.
- Capability + contract probes (this box): `systemd-run --user --scope` exit 0 (systemd 255); `memory` controller delegated; cgroup v2; `pane_current_command == claude` preserved with and without `exec`.
