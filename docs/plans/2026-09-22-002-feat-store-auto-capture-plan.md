---
title: "Store auto-capture (decision nudge + Haiku sweep) - Plan"
type: feat
date: 2026-09-22
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
task: dotfiles--feat-store-auto-capture
parent: dotfiles--living-task-store
---

# Store auto-capture (decision nudge + Haiku sweep) - Plan

## Goal Capsule

- **Objective:** Decisions made in a wb session land in that task's `## Decisions` without the human remembering to record them. The cut-1 mechanism is a nudge plus a propose-only background sweep. The live agent always makes the actual write.
- **Authority:** the decisions D1–D6 recorded in `~/code/tasks/dotfiles--feat-store-auto-capture.md` `## Decisions` > this plan > repo conventions. Evidence: `~/code/tasks/dossiers/dotfiles--feat-store-auto-capture/stage4-findings.html`.
- **Execution profile:** bash hook scripts plus a plain skill plus a hooks-only Claude Code plugin. U1 is a hands-on verification spike that gates the rest.
- **Stop conditions:** stop and surface the problem, rather than working around it, if U1 finds that a stowed skills-dir plugin doesn't load or fire hooks, that docgen breaks on the plugin dir, or that the headless child can't be kept out of the capture hooks. Stop, too, if any unit would need to write `~/code/tasks` from a hook.
- **Tail ownership:** the PR is opened with `pgh` against `development`. Post-merge stow/restart plus the live verification checklist are handed to Jet.

---

## Product Contract

### Summary

Four Claude Code hooks, registered by a new hooks-only plugin, watch wb sessions.
- A **Stop** hook phrase-matches Claude's last reply for decision-shaped language. It sets a per-session marker unless a Decisions append already ran that turn.
- The next **UserPromptSubmit** injects a one-line nudge pointing at a new `/wb-decide` skill. That skill is the Decisions counterpart of `/wb-save`.
- Every N turns in which the task file hasn't changed, an **async Stop** hook asks headless Haiku whether anything decided went unrecorded. Haiku writes only a draft, which the next nudge surfaces.
- A local log records nudges fired, followed, dismissed and left pending, giving a measurable follow rate for the two-week graduation review.

### Problem Frame

The living-task-store loop is detect → distill → apply → propagate. Stages 1–3 built the substrate, the conventions and the `store-specialist` writer. Nothing yet *detects*. Today a decision reaches `## Decisions` only if someone remembers.
- **The baseline is poor:** 31 of 94 done tasks (33%) closed with an empty `## Decisions` (store scan, 2026-09-22).
- **The convention doesn't reach agents:** stage 2's "Authoring discipline" lives in `~/code/tasks/README.md`, which nothing loads into an agent's context.
- **A nudge alone is a weak lever:** a prose guardrail in a seeded task file was ignored by a restarted agent (`crash-restart-seed-guardrail-weak` memory), and the `/wb-*` skills get zero slash-command invocations from the human (2026-07-20 usage audit). An agent-directed nudge plus an independent sweep is the cut-1 answer. The follow rate says whether it works.

### Requirements

**Detect and nudge**
- R1. At each top-level Stop in a wb session, phrase-match `last_assistant_message` against a configurable decision-phrase list and set a per-session marker on a match.
- R2. Set no marker when a `wb append … Decisions` ran during that turn, from the main agent or a sub-agent.
- R3. After a phrase nudge fires, suppress phrase nudges for a configurable cooldown (default 3 turns).
- R4. At the next UserPromptSubmit, deliver at most one single-line `additionalContext` nudge and clear what it delivered. A pending Haiku draft takes precedence over a phrase marker.
- R5. All capture hooks no-op outside tmux, outside wb sessions (no resolvable `@task`), when the kill switch file exists, inside the sweep's own child process, and when `jq` is missing.

**Record (the `/wb-decide` skill)**
- R6. `/wb-decide` writes a `### <YYYY-MM-DD HH:MM> — <source>` entry through `wb append <task> Decisions -` and never through Edit/Write.
- R7. `/wb-decide` can review a pending Haiku draft, and accept it as-is or edited. Either way the draft is cleared.
- R8. `/wb-decide dismiss` clears the session's marker and draft and logs a dismissal.
- R9. `/wb-decide mute` / `unmute` silences or restores nudges and sweeps for the current session.

**Measure**
- R10. Every capture event (nudge fired with its source, followed, dismissed, muted, sweep ran/skipped, pending at end) appends one JSON line to a local log outside `~/code/tasks`.
- R11. At SessionEnd, a still-pending marker or draft is logged as `pending_at_end`. Nothing is written to the task's `## Handoffs`.
- R12. A dated graduation-review follow-up (about 2 weeks after merge) is recorded. The log is enough on its own to compute the follow rate and the dismissal rate.

**Sweep**
- R13. When the task file's content has been unchanged for N consecutive turns (default 4), an async Stop hook runs one headless Haiku review of the recent transcript against the task's `## Decisions`.
- R14. The sweep writes only a per-session draft file, never the task file. An answer of "nothing unrecorded" writes nothing.
- R15. The sweep's child process can never trigger capture hooks or another sweep.
- R16. The sweep has an on/off setting (default on). N, cooldown and the phrase list are adjustable in one config file.

**Packaging**
- R17. The hooks are registered by a tracked plugin that auto-loads for every session once stowed. Nothing is hand-merged into `~/.claude/settings.json`.

### Scope Boundaries

- Automatic writes to `## Decisions` by any hook or background process: the sweep proposes and the live agent decides (D5, umbrella D-iii).
- Decisions made entirely inside a sub-agent: Stop and UserPromptSubmit are top-level only, so these are never nudged. This gap is accepted for cut 1. A sub-agent's own `wb append` does still count as "recorded" (R2).
- Non-wb sessions: there's no task file to point at.
- Cross-agent propagation and staleness belong to stage 5 (`dotfiles--feat-store-cross-agent-sync`).
- Routing writes through `store-specialist`: `/wb-decide` shells out to `wb append` directly, as `/wb-save` does.

#### Deferred to Follow-Up Work

- A docgen source kind for plugin directories. It lives in the separate `~/code/docgen` repo, and the same gap is already tracked for `claude/.claude/agents/` in `dotfiles--feat-store-specialist-docgen-index`.
- A "Decisions are recorded via `/wb-decide`" line in `~/code/tasks/README.md#authoring-discipline`, which is a separate repo with direct-to-`development` commits.
- The graduation decision itself: build background auto-extraction, or tune/retire the nudge.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Deferred nudge, split across two hooks (D1).** A Stop hook can't inject context without `decision:"block"`, which forces the agent to keep going; without the block its `additionalContext` is discarded. So Stop only sets a marker, and UserPromptSubmit delivers the nudge. Nothing ever blocks a turn.
- KTD2. **"Already recorded" comes from a PostToolUse(Bash) hook, not a transcript scan.** It matches `tool_input.command` against `wb append` plus the `Decisions` heading using a cheap raw-stdin grep pre-filter (the `pretooluse-guard.sh` pattern). This is exact, costs one grep per Bash call, fires for sub-agents too, and gives the "followed" event for free. The Stop hook then only needs `last_assistant_message` from its stdin, with no JSONL parsing on the hot path.
- KTD3. **Per-session state under `${XDG_STATE_HOME:-$HOME/.local/state}/wb/capture/<session_id>/`, plus one shared `log.jsonl`.** Keying by `session_id` keeps two sessions on one task file separate, and makes `/clear` (new session_id) naturally orphan the stale marker or draft. The UserPromptSubmit hook stamps the tmux pane option `@wb_capture_sid`, so `/wb-decide` (run via the agent's Bash, which inherits `TMUX_PANE`) can find its own session without a dependency on `claude-notify-hook.sh`. The kill switch is `…/wb/disable-capture`, matching the existing `disable-agent-hook` shape. Nothing is written under `~/code/tasks`, so the tasks-store guard is never involved.
- KTD4. **The scripts live in `scripts/.config/scripts/tmux/`, and the plugin only registers them (refines D6).** A skills-dir plugin loads from its folder (it isn't cache-copied), so bundling the scripts would have been possible. Keeping them beside the existing hooks buys docgen indexing (the `scripts` source kind), the pre-commit regen trigger (`scripts/.config/scripts/tmux/*.sh`), and the established test conventions. The plugin is `claude/.claude/skills/wb-capture/`, holding `.claude-plugin/plugin.json` and `hooks/hooks.json`. `stow --no-folding -t "$HOME" claude` places it at `~/.claude/skills/wb-capture/`, where Claude Code auto-loads it as `wb-capture@skills-dir`, with no marketplace. Hook commands are shell-form: `"${WB_CAPTURE_BIN:-$HOME/.config/scripts/tmux}/capture.sh" <verb>`. The override lets a worktree be tested with `claude --plugin-dir` before merge.
- KTD5. **Hooks never source `wb.sh` and never write the store.** Only `/wb-decide`, run by the live agent, writes to `~/code/tasks`, by running `wb append` as a separate process. This keeps the 2026-07-10 deletion-incident class (`CODE_DIR` clobbered by `source wb.sh`) out of hook code, and matches the existing split where hooks write transient state and skills write the store.
- KTD6. **The sweep is a non-bare headless child on the subscription.** It runs as `WB_CAPTURE_SWEEP=1 timeout <T> claude -p --model haiku --no-session-persistence --max-turns 1`, with tools disabled, cwd set to the session state dir (so no repo `CLAUDE.md` or project settings load), and stdin carrying the prompt, the transcript excerpt and the task's `## Decisions`. `--bare` would skip hooks outright, but it needs an API key instead of the subscription, so the recursion guard is our own environment flag, checked first by every capture script. `--no-session-persistence` keeps the child out of `wb_transcripts`. The output contract is the literal `NONE` or a draft body. The draft is written tmp-then-`mv`, so a reader never sees a partial file.
- KTD7. **One nudge line, with the draft taking precedence.** Phrase nudge: `[wb-capture] Last turn read like a decision ("<matched phrase>"). If it settled something, run /wb-decide; otherwise ignore or /wb-decide dismiss.` Draft nudge: `[wb-capture] A background review drafted an unrecorded decision (<draft path>). Run /wb-decide to review/accept, or /wb-decide dismiss.` Neither restates `@task`, since the agent already has it.
- KTD8. **Defaults live in `capture.sh`, overridden by an optional untracked `${XDG_CONFIG_HOME:-$HOME/.config}/wb/capture.conf`.** It's parsed as `KEY=value` lines (never sourced). The keys are phrase list, cooldown, sweep N, sweep on/off and sweep timeout. The agent tunes behaviour with plain Read/Edit of one documented file, not a task-store verb, since this isn't task metadata.
- KTD9. **`/wb-decide` is a plain skill** (`claude/.claude/skills/wb-decide/`), not inside the plugin. Plugin skills are namespaced (`/wb-capture:wb-decide`), and a plain skill keeps the short `/wb-decide` that the nudge text and `/wb-save` symmetry rely on.

### High-Level Technical Design

Per-turn lifecycle of one wb session (all hooks exit 0; none block):

```mermaid
sequenceDiagram
  participant U as User
  participant CC as Claude Code
  participant P as capture.sh hook-prompt
  participant T as capture.sh hook-posttool
  participant S as capture.sh hook-stop
  participant W as capture-sweep.sh (async)
  participant H as claude -p haiku (child)
  participant St as state dir (per session_id)
  U->>CC: prompt
  CC->>P: UserPromptSubmit (session_id)
  P->>St: stamp @wb_capture_sid; read draft / marker
  P-->>CC: additionalContext (one line) or nothing
  Note over CC: agent works; may run /wb-decide → wb append … Decisions
  CC->>T: PostToolUse(Bash) (tool_input.command)
  T->>St: recorded-flag (+ log followed if nudge outstanding)
  CC->>S: Stop (last_assistant_message, transcript_path)
  S->>St: recorded? clear : phrase-match → marker (cooldown); update task-hash counter
  CC->>W: Stop (async)
  W->>St: counter ≥ N and enabled and not muted?
  W->>H: WB_CAPTURE_SWEEP=1, transcript tail + Decisions on stdin
  H-->>W: NONE | draft
  W->>St: atomic draft write (if not NONE)
  Note over CC: next prompt → hook-prompt surfaces draft first
```

Per-session state (`…/wb/capture/<session_id>/`):

| File | Written by | Cleared by |
|---|---|---|
| `marker` (matched phrase) | hook-stop | hook-prompt on delivery, `/wb-decide`, dismiss |
| `recorded` | hook-posttool | hook-stop (same turn) |
| `cooldown` (turns remaining) | hook-stop | counts down in hook-stop |
| `taskhash` + `unchanged` counter | hook-stop | reset on hash change or after a sweep |
| `draft` | capture-sweep.sh | `/wb-decide` accept, dismiss |
| `muted` | `/wb-decide mute` | `/wb-decide unmute` |
| `outstanding` (a nudge was delivered, awaiting follow) | hook-prompt | hook-posttool (→ `followed`), dismiss |

At SessionEnd, `hook-end` logs `pending_at_end` if `marker` or `draft` exists, then removes that session's directory by its exact computed path, which is never a variable that could be empty.

### Assumptions

None beyond those U1 verifies. Each U1 check has a named fallback in U1.

### Sequencing

U1 gates everything. U2 (the shared script and state) precedes U3–U5. U6 (the skill) depends only on U2's agent-facing verbs. U7 (plugin wiring) needs U3–U5. U8 (docs and follow-up) comes last.

---

## Implementation Units

### U1. Verification spike (gate)

- **Goal:** Confirm the load-bearing platform assumptions on the installed Claude Code (2.1.280) before building on them, and record the findings as a Decisions entry via `wb append`.
- **Requirements:** R5, R13, R15, R17.
- **Dependencies:** none.
- **Files:** none committed, apart from a throwaway probe plugin in the session scratchpad. Findings go to the task file via `wb append … Decisions -`.
- **Approach:** check each of the following.
  1. A skills-dir plugin whose files are stow-style symlinks loads, and its hooks fire. Check with a probe plugin that logs stdin, via `--plugin-dir` and then as a symlinked `~/.claude/skills/<probe>/`, removed afterwards.
  2. The Stop stdin carries `last_assistant_message` and `transcript_path`, and the PostToolUse(Bash) stdin carries `tool_input.command`, including for sub-agent tool calls.
  3. An `async: true` Stop hook can launch `claude -p --model haiku --no-session-persistence --max-turns 1` with tools disabled. Find the exact flag for "no tools". The child inherits `WB_CAPTURE_SWEEP` and does fire user and plugin hooks (so our guard is what stops recursion). It writes no transcript. It runs inside the parent's `wb-agent-*.scope`: check with `systemd-cgls`, and note peak memory against `MemoryMax`.
  4. `docgen.sh` tolerates a `claude/.claude/skills/wb-capture/` directory with no `SKILL.md`. Run it in a `git archive` clean-room copy, never the shared checkout.
- **Execution note:** this is a spike. Probe artifacts live in the scratchpad and are removed; nothing here ships. Kill no processes and stop no units without asking Jet.
- **Fallbacks:** if check 1 fails, install the same plugin dir from a local-directory marketplace (loads in place per docs). If check 4 fails, move the plugin to a new non-stowed top-level `plugins/wb-capture/`, installed via a local marketplace. If check 3 shows the guard leaking, add `--settings` with hooks disabled if the flag exists; otherwise stop and ask about `--bare` with an API key.
- **Test scenarios:** Test expectation: none. This is a spike whose output is a findings entry.
- **Verification:** a Decisions entry states pass/fail per check, with the fallback taken where one was needed.

### U2. Shared capture core (`capture.sh`: state, config, guards, log, agent verbs)

- **Goal:** One script that owns the state dir, config parsing, guard chain, log append and the agent-facing verbs. Every hook and the skill go through it.
- **Requirements:** R5, R8, R9, R10, R16.
- **Dependencies:** U1.
- **Files:** `scripts/.config/scripts/tmux/capture.sh` (new), `scripts/.config/scripts/tmux/tests/capture-core.test.sh` (new).
- **Approach:**
  - Subcommand dispatch in the same shape as `claude-notify-hook.sh` (`case "$1"`). Hook verbs are added in U3–U5. The agent verbs are `clear`, `dismiss`, `mute`, `unmute` and `status`. `clear` drops the marker, draft and outstanding flag without logging; it's used after a successful write, whose `followed` event the PostToolUse hook already logs. `dismiss` does the same clearing but logs `dismissed`. `status` prints the session's pending marker/draft, mute state and log path.
  - Session resolution: from stdin JSON for hooks; from the pane option `@wb_capture_sid` for agent verbs.
  - The guard chain runs before reading stdin wherever possible: recursion flag, then kill switch, then tmux present, then `@task` resolvable (via the tmux session option, never `wb.sh`), then `jq` present.
  - `set -uo pipefail` with no `-e`, and `exit 0` on every path, including a `fail_open` helper modelled on `pretooluse-guard.sh`.
  - Log lines are compact JSON built with `jq -nc` and appended with `>>`: ISO-8601 local timestamp with offset, `session_id`, task stem, event, source.
  - No `rm -rf`. Removal is by explicit file name inside a validated `<state>/<session_id>` path.
- **Patterns to follow:** `scripts/.config/scripts/tmux/claude-notify-hook.sh` (header contract, stdin guard, jq-with-fallback), `scripts/.config/scripts/tmux/tasks-git-hooks/pretooluse-guard.sh` (kill switch, `fail_open`, raw-stdin pre-filter), `scripts/.config/scripts/tmux/tests/tasks-agent-hook.test.sh` (stdin-fed harness), `wb-install-hooks.test.sh` (`new_scenario` isolation).
- **Test scenarios:**
  - Each guard short-circuits with exit 0, no output and no state written: recursion flag set, kill switch present, no tmux, `@task` unset, jq missing (a `NOJQ_BIN` PATH fixture).
  - `mute` then `status` reports muted, and `unmute` clears it. Both log one line each.
  - `dismiss` with a marker and a draft present removes both and logs `dismissed`. `dismiss` with nothing pending is a quiet no-op.
  - `clear` with a marker and a draft present removes both and logs nothing.
  - Config: a missing file gives the defaults. A file with an unknown key or a malformed line is ignored and the valid keys are applied. The file is never executed: a line containing `$(…)` stays literal.
  - Two session_ids with the same `@task` get separate state dirs, and verbs on one don't touch the other.
  - An agent verb with `@wb_capture_sid` unset prints one clear error line and exits 0.
- **Verification:** `capture-core.test.sh` passes in the Docker sandbox.

### U3. Detect and nudge hooks (`hook-stop`, `hook-posttool`, `hook-prompt`)

- **Goal:** The synchronous nudge loop: detect at Stop, suppress on a recorded decision, deliver at the next prompt.
- **Requirements:** R1, R2, R3, R4, R10.
- **Dependencies:** U2.
- **Files:** `scripts/.config/scripts/tmux/capture.sh` (add verbs), `scripts/.config/scripts/tmux/tests/capture-hooks.test.sh` (new).
- **Approach:**
  - `hook-posttool`: raw-stdin grep pre-filter for `wb` plus `append` plus `Decisions` before any jq; then confirm on `.tool_input.command`. Sets `recorded`. If `outstanding` exists, logs `followed` and clears it.
  - `hook-stop`, in order:
    1. If `recorded` is set, clear it and set no marker.
    2. Otherwise, if not muted and the cooldown is 0, case-insensitive fixed-string match of `last_assistant_message` against the phrase list. A match writes `marker` (the matched phrase) and sets the cooldown.
    3. Always decrement the cooldown and update the task-hash/unchanged counter. The hash is computed on the `@task` file with `sha1sum`, and a missing file is treated as changed.
  - `hook-prompt`:
    1. Stamp `@wb_capture_sid`.
    2. If a `draft` exists, emit the draft nudge; otherwise, if a `marker` exists, emit the phrase nudge. The nudge is emitted with `jq -n` as `hookSpecificOutput.additionalContext`, nested correctly.
    3. Clear `marker`, write `outstanding`, and log `nudge_fired` with the source (`phrase|sweep`).
- **Patterns to follow:** `pretooluse-guard.sh`'s `emit_decision` jq template and pre-filter, and `claude-notify-hook.sh`'s pane-option writes.
- **Test scenarios:**
  - Happy path: Stop with "we're going with option B" writes `marker`, and the next prompt emits one line naming the phrase and `/wb-decide`, clears the marker and logs `nudge_fired{source:phrase}`.
  - Suppression: PostToolUse with `wb append ~/code/tasks/x.md Decisions -` then Stop with decision language writes no marker and clears `recorded`.
  - Followed: nudge delivered, then PostToolUse with a Decisions append, logs `followed` exactly once.
  - Non-matching append: PostToolUse with `wb append x Handoffs -` sets nothing.
  - Cooldown: two matching Stops in consecutive turns give one marker; a match after the cooldown elapses gives a new marker.
  - Precedence: both `draft` and `marker` present gives the draft line only, and both are cleared from the next nudge's consideration.
  - Empty or missing `last_assistant_message` sets no marker and doesn't error.
  - Muted session: a matching Stop sets no marker.
  - Output shape: prompt output parses as JSON with `.hookSpecificOutput.hookEventName == "UserPromptSubmit"` and a single-line `additionalContext` (no newline).
  - Nothing pending: prompt emits nothing (empty stdout).
  - Task-hash: an unchanged task file increments the counter, and an external append to the task file resets it to 0.
- **Verification:** `capture-hooks.test.sh` passes in the sandbox.

### U4. Haiku sweep (`capture-sweep.sh`)

- **Goal:** A propose-only background review that drafts an unrecorded decision when the task file has gone stale.
- **Requirements:** R13, R14, R15, R16, R10.
- **Dependencies:** U2, U3 (the task-hash counter).
- **Files:** `scripts/.config/scripts/tmux/capture-sweep.sh` (new), `scripts/.config/scripts/tmux/tests/capture-sweep.test.sh` (new).
- **Approach:**
  - Guards come from U2, plus: sweep enabled, not muted, `unchanged ≥ N`, and no draft already pending (never stack drafts).
  - Build the excerpt from `transcript_path` with jq: user and assistant text blocks since the last sweep, capped to a byte budget and truncated from the oldest end. Add the task's `## Decisions` section, extracted with awk, never by sourcing `wb.sh`.
  - Pipe prompt plus excerpt on stdin to the KTD6 child. The prompt asks for `NONE` or a single entry body naming what was decided and the alternative rejected, and forbids restating entries already present.
  - Reset the counter whether or not a draft results. Log `sweep_ran{result:none|draft|error|timeout}` or `sweep_skipped{reason}`.
- **Execution note:** start with the stubbed-`claude` test. The real Haiku call is only exercised in U1 and the live checklist.
- **Patterns to follow:** `wb-claude-wrapper.test.sh` (a fake binary on `PATH` that records argv/env), `wb_transcript_dir`/`wb_transcripts` in `scripts/.config/scripts/tmux/wb.sh` (JSONL location conventions).
- **Test scenarios:**
  - Fires: `unchanged=N` with a fake `claude` printing a draft writes `draft` atomically (no `.tmp` left behind), logs `sweep_ran{result:draft}` and resets the counter.
  - Nothing found: a fake `claude` printing `NONE` writes no draft and logs `result:none`.
  - Child invocation shape: the fake records `WB_CAPTURE_SWEEP=1`, `--model haiku`, `--no-session-persistence` and `--max-turns 1`, with cwd equal to the session state dir.
  - Recursion: running `capture-sweep.sh` and every `capture.sh` hook verb with `WB_CAPTURE_SWEEP=1` in the environment does nothing and logs nothing.
  - Timeout or error: a fake `claude` that sleeps past the timeout, or exits non-zero, writes no draft and logs `result:timeout|error`.
  - Skips: sweep disabled, muted, `unchanged < N`, or a draft already pending each log `sweep_skipped` with the reason, and the fake `claude` is never invoked.
  - Excerpt budget: an oversized transcript fixture yields stdin at or under the byte cap, keeping the newest turns.
- **Verification:** `capture-sweep.test.sh` passes in the sandbox. U1 check 3 recorded the real-child behaviour.

### U5. SessionEnd hook (`hook-end`)

- **Goal:** Close out a session's capture state and log anything left pending, within the 1.5s SessionEnd budget.
- **Requirements:** R11, R10.
- **Dependencies:** U2.
- **Files:** `scripts/.config/scripts/tmux/capture.sh` (add verb), `scripts/.config/scripts/tmux/tests/capture-hooks.test.sh` (extend).
- **Approach:** if `marker` or `draft` exists, log `pending_at_end{marker:bool,draft:bool}`, then remove the session's state directory by explicit path. There's no jq-heavy work, no network and no task-file access.
- **Test scenarios:**
  - A pending marker at SessionEnd gives one `pending_at_end` log line, the session dir is gone, and the task file is byte-identical, `## Handoffs` included.
  - Nothing pending: the dir is removed and nothing is logged.
  - The state-dir path computes to empty or to a path outside the capture root: nothing is removed and it fails open.
- **Verification:** the extended `capture-hooks.test.sh` passes.

### U6. `/wb-decide` skill

- **Goal:** The agent-facing record/accept/dismiss/mute surface the nudge points at.
- **Requirements:** R6, R7, R8, R9.
- **Dependencies:** U2 (the agent verbs and `@wb_capture_sid`).
- **Files:** `claude/.claude/skills/wb-decide/SKILL.md` (new).
- **Approach:** mirror `claude/.claude/skills/wb-save/SKILL.md`: trigger-dense `description` frontmatter, `@task` resolution with its two distinct error paths, and a heredoc `wb append "$task_file" Decisions <<EOF` call.
  - **Default mode:** if `capture.sh status` shows a draft, present it and accept it, or edit it, only if it reflects a real decision. Otherwise compose from session context: what was decided, the rejected alternative, and why, in the task's existing Decisions style.
  - **After writing:** run `capture.sh clear`, which drops the draft and marker without a `dismissed` event. The write's own `followed` event comes from the PostToolUse hook.
  - **Other modes:** `dismiss`, `mute` and `unmute` are passthroughs to `capture.sh`.
  - **Rules restated from `/wb-save`:** never Edit/Write the task file, and a correction is a new entry naming what it supersedes.
- **Test scenarios:** skills have no automated harness in this repo (as with `/wb-save`). The SKILL.md carries a "Test scenarios" checklist: happy path, draft accept, draft reject → dismiss, mute/unmute, not a wb session, stale `@task`. It's exercised in the live checklist.
- **Verification:** the skill is listed by docgen after regen and passes the live-checklist rows.

### U7. Plugin wiring (`wb-capture`)

- **Goal:** Register the four hook entries through a tracked, auto-loading plugin.
- **Requirements:** R17.
- **Dependencies:** U1 (placement confirmed), U3, U4, U5.
- **Files:** `claude/.claude/skills/wb-capture/.claude-plugin/plugin.json` (new), `claude/.claude/skills/wb-capture/hooks/hooks.json` (new), `scripts/.config/scripts/tmux/tests/capture-plugin.test.sh` (new).
- **Approach:**
  - `plugin.json` holds name, description and author only.
  - `hooks.json` has these entries:
    - UserPromptSubmit → `capture.sh hook-prompt`
    - PostToolUse matcher `Bash` → `capture.sh hook-posttool`
    - Stop → `capture.sh hook-stop`
    - Stop `async: true` → `capture-sweep.sh`
    - SessionEnd → `capture.sh hook-end`
  - Every command is shell-form `"${WB_CAPTURE_BIN:-$HOME/.config/scripts/tmux}/…"`. Short timeouts apply to the sync hooks, matching the existing `timeout: 5` convention.
  - The same hooks must not also be added to `settings.recommended.json`, because plugin and settings hooks both run and would double-fire.
- **Test scenarios:**
  - `hooks.json` and `plugin.json` parse with jq.
  - Every referenced script path exists (resolved against the repo with `WB_CAPTURE_BIN` pointed at `scripts/.config/scripts/tmux`) and is executable.
  - Exactly one sync Stop entry and one async Stop entry.
  - No capture hook appears in `claude/.claude/settings.recommended.json`.
- **Verification:** `capture-plugin.test.sh` passes, and `claude --plugin-dir claude/.claude/skills/wb-capture` with `WB_CAPTURE_BIN` set to the worktree's scripts shows the hooks firing in one manual session (recorded in the live checklist).

### U8. Docs, graduation follow-up, live checklist

- **Goal:** Make the feature discoverable and operable, and schedule its graduation review.
- **Requirements:** R12, R16.
- **Dependencies:** U2–U7.
- **Files:** `docs/guides/wb-decide.md` (new; auto-tiles with the skill), `claude/README.md` (add the plugin and its stow/restart note), generated docs via `docgen.sh` (never hand-edited), and `~/code/tasks/dossiers/dotfiles--feat-store-auto-capture/live-verification.html` (new).
- **Approach:**
  - **Guide:** what fires when, the one-line nudge forms, the state/log/config/kill-switch paths, a `jq` recipe for follow rate and dismissal rate over `log.jsonl`, and how to disable (kill switch, sweep off, mute).
  - **Follow-up:** append a dated follow-up to the task file for 2026-10-06, "graduation review: compute follow and dismissal rates from `log.jsonl`; compare empty-Decisions rate on tasks closed since merge against the 31/94 baseline".
  - **Checklist:** build the tickable live-verification checklist, split into automated-done and to-verify items, per the verification-checklist norm.
- **Test scenarios:** Test expectation: none. This unit is docs and a follow-up only.
- **Verification:** docgen regen succeeds (the pre-commit hook covers the guide and scripts), the guide appears on the Hub skills tile, and the task file shows the dated follow-up.

---

## System-Wide Impact

- **Every new session loads the plugin.** On a non-wb session the four hooks each exit at the tmux or `@task` guard within milliseconds. On a wb session, PostToolUse adds one grep per Bash call.
- **Memory:** the sweep child runs inside the agent's `wb-agent-*.scope`, so it counts against that agent's `MemoryMax` (8G). U1 records the observed peak.
- **Subscription usage:** at most one Haiku call per N stale turns per session, with `--max-turns 1`. The cwd is the state dir, so no repo context loads.
- **Existing hooks are untouched.** `claude-notify-hook.sh` and the PreToolUse guard stay in `~/.claude/settings.json`, and plugin hooks run alongside them.

## Risks & Dependencies

| Risk | Mitigation |
|---|---|
| Platform behaviour differs from the docs (the stage-1 hook assumption precedent) | U1 checks each point hands-on before any build unit, and each has a fallback |
| The nudge becomes noise and gets ignored | cooldown, draft precedence, `mute`, a `dismissed` log bucket, and the graduation review on a fixed date |
| Recursion via the sweep child | env guard checked first by every capture script, a test covering all verbs, and U1 confirming env inheritance |
| A false-positive draft duplicates an existing entry | the prompt forbids restating present entries, no stacked drafts, and the agent decides in `/wb-decide` |
| Docgen doesn't index the plugin dir | accepted; scripts and skill are indexed and the plugin dir is a follow-up (existing docgen task) |
| Full Docker suite has a drifting env-dependent failure floor | re-baseline via clean-room compare; judge only the new `capture-*.test.sh` files and any newly failing file |

## Open Questions

- Deferred: initial phrase-list contents and the defaults (cooldown 3, N 4, sweep timeout). Tune them against real transcripts during U3 and at the graduation review.

---

## Verification Contract

| Gate | Command / action | Applies to |
|---|---|---|
| New suites | `docker build -t wb-tests -f scripts/.config/scripts/tmux/tests/Dockerfile .` then `docker run --rm -v "$(pwd)":/repo:ro -w /repo wb-tests bash scripts/.config/scripts/tmux/tests/<capture-*.test.sh>` | U2–U5, U7 |
| Full suite, no regressions | run the full sandbox suite and compare failing files against a clean-room `development` baseline; a failure that also fails on baseline is not a regression | all |
| Docs regen | `docgen.sh` (the pre-commit hook regenerates on commit); run clean-room if the worktree is shared | U6, U8 |
| Platform spike | U1 findings entry in the task's `## Decisions` | U1 |
| Live behaviour | tick through `live-verification.html` in a real wb session after stow and restart | U3–U7 |

## Definition of Done

- All `capture-*.test.sh` suites pass in the sandbox, and the full suite shows no new failing files versus the clean-room baseline.
- U1 findings are recorded, and any fallback taken is reflected in the committed layout.
- The plugin, scripts, skill and guide are committed. The generated docs have been regenerated, not hand-edited.
- There are no writes to `~/code/tasks` from any hook script (verified by a repo grep for the task dir in capture scripts), and no `source` of `wb.sh` in them.
- The task file carries the dated graduation-review follow-up, and the live checklist exists at its dossier path.
- Abandoned probe or spike code is removed from the diff and the scratchpad probe plugin is deleted.
- The PR is open against `development` via `pgh`.

---

## Sources & Research

- Hook contract, from the Claude Code hooks reference: Stop `additionalContext` is discarded without `decision:"block"`; Stop stdin has `last_assistant_message`/`transcript_path`; PostToolUse can't block; SessionEnd has a 1.5s budget; `async: true`; plugin hooks merge with settings hooks.
- Plugins, from the plugins reference and plugin-marketplaces docs: local-directory and skills-dir plugins load in place (no cache); `claude plugin init` → `~/.claude/skills/<name>/` auto-loads as `<name>@skills-dir` (confirmed via `claude plugin --help` on 2.1.280); `--plugin-dir`; plugin skills are namespaced.
- Headless, from the headless and sessions docs: `--bare` skips hooks and plugins but needs an API key; `--no-session-persistence`; `--max-turns`; `--model haiku`.
- Repo patterns: `scripts/.config/scripts/tmux/claude-notify-hook.sh`, `scripts/.config/scripts/tmux/tasks-git-hooks/pretooluse-guard.sh`, `scripts/.config/scripts/tmux/tests/tasks-agent-hook.test.sh`, `scripts/.config/scripts/tmux/tests/wb-claude-wrapper.test.sh`, `claude/.claude/skills/wb-save/SKILL.md`, `cmd_append` / `_wb_append_under_heading` in `scripts/.config/scripts/tmux/wb.sh`, `docs/docgen.json`, `.githooks/pre-commit`.
- Prior plans and learnings: `docs/plans/2026-09-21-001-feat-task-family-concepts-hook-plan.md` (hooks can't reach sub-agents; spike-first precedent), `docs/plans/2026-09-22-001-feat-store-specialist-subagent-plan.md` (shim requirement), `docs/plans/2026-08-24-001-feat-wb-session-cgroup-isolation-plan.md`, `logs/decisions/2026-06-19-agent-attention-notification.md` (anti-alert-fatigue precedent).
