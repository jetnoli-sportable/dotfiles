---
name: wb-continue
description: Save the session like /wb-save, then ask for this pane to restart with a fresh Claude that carries out an instruction — the save, /clear and /wb-resume in one step, with no visit to the pane. Use when Jet types `/wb-continue <instruction>` (e.g. "/wb-continue /ce-code-review", "/wb-continue tell me where the entrypoint PR stands"), or when a session reaches a step that must run in a fresh context and wants to continue by itself (a build reaching its code review). Not for a plain save (that's /wb-save, which saves and stays). Never types into any pane: a Stop hook does the restart once the turn ends, and a script decides whether the restart happens by itself or waits in the picker's ready list.
---

# wb-continue

`/wb-continue <instruction>` means: save, restart this pane in a fresh context,
and do this. It replaces the manual `/wb-save` → `/clear` → `/wb-resume` round
trip for the stops where Jet has nothing to decide.

A Claude cannot clear its own context (Claude Code's auto-mode check refused an
agent typing `/clear` into its own pane, twice, in July 2026). This skill never
tries. It writes the save and a restart request; when the turn ends, the
wb-continue Stop hook checks that nothing is still running and restarts the pane
with a fresh Claude, which picks up exactly this save through
`/wb-resume --continue`. The design is in
`docs/plans/2026-11-15-1125-feat-wb-continue-plan.md`.

## Who decides what

- **Jet typed `/wb-continue`** (the turn opened with it): any instruction
  qualifies, and the fresh Claude receives his words verbatim. The script reads
  them from the transcript's record of the prompt, not from this skill.
- **The session calls it by itself** (through the Skill tool, or after a turn Jet
  opened with something else): the restart happens by itself only when the
  command is a code review (`/ce-code-review`, `/compound-engineering:ce-code-review`
  or `/code-review`) and Jet isn't looking at the pane. Anything else waits in the
  picker's "ready to continue" list for Jet to release with one key.
- **A session started by a restart** never restarts itself again; its
  self-initiated continues always go to the ready list.

The script decides the lane, never this skill. The skill can only decline (step
3); it cannot make a request qualify.

## What to do

### 1. Save

Run `/wb-save`'s procedure, steps 1 to 5 (`claude/.claude/skills/wb-save/SKILL.md`):
locate the task through `@task`, the shelf review, the drift check, compose the
entry, and the two locked writes. The instruction is the save's next action:

- **Next:** describes it in plain words.
- When the instruction is a command (it starts with `/`, or names a skill to
  run), it also goes in the ` ```run ` block, copied exactly.
- `/wb-save`'s step 5 already stages a ready request (`wb continue stage`); the
  arm in step 4 below replaces it.

If any part of the save fails or stops (no `@task`, a write refused), stop there.
Never arm without a save that landed.

### 2. Skip `/wb-save`'s step 6

Don't print "/clear when you're ready": step 5 below replaces that line.

### 3. Decline when Jet must act first

Decline the restart (`--decline` in step 4) when the save itself says Jet has to
do something before the next step: switch the model or effort, answer a question,
read or approve something, run a command only he can run. A declined request
still lands in the ready list, so Jet releases it once he has done his part.

An open `/decide` surface for this task needs no step here: the hook won't
restart a pane while the needs-you marker has lines, so its answers never arrive
at a session that no longer exists.

### 4. Arm

Pass the instruction on stdin, exactly as given, in every case. When Jet typed
the command, the script ignores stdin and reads his words itself.

```bash
printf '%s' "$instruction" | wb continue arm "$task_file"
# when declining:
printf '%s' "$instruction" | wb continue arm --decline "$task_file"
```

### 5. Say what happens, then end the turn

One line, built from what `wb continue arm` printed: either that the pane
restarts into a fresh context when this turn ends (and with which command), or
that the save is waiting in the picker's ready list and why. When step 1's drift
check found drift, add the drift sentence `/wb-save` would have added.

Then end the turn at once. Don't carry out the instruction yourself, don't start
anything in the background, and don't schedule anything: running background work
or a scheduled wakeup holds the restart until it finishes.

## Rules

- Never type into any pane, never send `/clear`, never run `tmux send-keys`. The
  restart belongs to the Stop hook and its helper.
- One request per task. Running `/wb-continue` again replaces the last request.
- `/wb-save` keeps its meaning: save and stay. Don't arm a restart from a plain
  `/wb-save`; Jet releases a plain save from the picker or with the continue key.

## Test scenarios (behaviour to follow)

- **Jet types `/wb-continue tell me where things stand`:** save with that as the
  next action (no `run` block, it isn't a command), arm, one line saying the pane
  restarts when the turn ends, end the turn.
- **A build session reaches its review and calls `/wb-continue /ce-code-review`:**
  save with the review in the `run` block, arm with `/ce-code-review` on stdin;
  the script arms it for an automatic restart unless Jet is looking at the pane.
- **A build session calls `/wb-continue /ce-work`:** same steps; the script puts
  it in the ready list, and the line says so.
- **Jet types `/wb-continue switch to Opus, then /ce-plan`:** save, then arm with
  `--decline` (Jet switches the model first); the line says it waits in the
  ready list.
- **A `/decide` buffer is still open:** save and arm as usual; the hook holds the
  restart until the buffer is answered, and the line says so.
- **Not a wb session (no `@task`):** `/wb-save`'s step 1 error; nothing armed.
