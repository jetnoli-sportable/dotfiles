# Hook payload fixtures

Real payloads Claude Code sent to command hooks, captured for the format, review-stamp and haircut-gate hook tests (plan U7). Captured 2026-11-14 with Claude Code 2.1.325 (`claude --version`).

## How they were captured

A throwaway hook script (stdin saved to one file per call, exit 0) was registered through `--settings` for PostToolUse (matcher `Write|Edit|MultiEdit`), PreToolUse (matcher `Skill`), UserPromptSubmit, Stop and SubagentStop. Runs were `env -u TMUX -u TMUX_PANE claude --setting-sources project --settings <file> -p --permission-mode bypassPermissions "<prompt>"` in a temp directory that was not a git repo, so no user settings, hooks, user skills or plugin skills loaded. The hook blocked any prompt containing `ce-code-review` (`decision: block`) and denied every Skill call, so no review or skill ran. Prompts used: write then edit `hello.txt`; `/ce-code-review`; `/compound-engineering:ce-code-review base:development`; "invoke the Skill tool with skill 'simplify' and args 'base:development'"; "use the Agent tool to spawn a subagent that runs `echo hi`".

Because plugin skills did not load, the Skill call used the bundled `simplify` skill, not `ce-code-review`. The payload shape is the same for any skill.

## Files

| File | Event | Matcher / trigger |
|---|---|---|
| `PostToolUse-Write.json` | PostToolUse | Write |
| `PostToolUse-Edit.json` | PostToolUse | Edit |
| `PreToolUse-Skill.json` | PreToolUse | Skill (`skill: simplify`, `args: base:development`) |
| `UserPromptSubmit-ce-code-review.json` | UserPromptSubmit | typed `/ce-code-review` |
| `UserPromptSubmit-ce-code-review-base-development.json` | UserPromptSubmit | typed `/compound-engineering:ce-code-review base:development` |
| `Stop.json` | Stop | main agent finished (from the write/edit run) |
| `SubagentStop.json` | SubagentStop | Agent-tool subagent (`general-purpose`) finished |
| `transcript-excerpt.jsonl` | n/a | scrubbed transcript lines, see below |

## Placeholders

`__HOME__` home directory, `__USER__` user name, `__CWD__` the temp project directory, `__TMPDIR__` the temp parent, `__TRANSCRIPT__` the session transcript path, `__AGENT_TRANSCRIPT__` the subagent transcript path, `__SESSION_ID__` any UUID (session ids and, in the excerpt, message uuids), `__PROMPT_ID__` the `prompt_id` field, `__TOOL_USE_ID__`, `__AGENT_ID__`. Tests should substitute real temp paths for these. Everything else is as captured, so `last_assistant_message`, timestamps and `tool_response` bodies are real. Field names and structure are untouched.

## Fields the plan assumed

| Assumption | Finding |
|---|---|
| `hook_event_name` on every event | Present on all seven payloads. |
| `tool_input.file_path` on PostToolUse Write/Edit | Present on both. Absolute path. `tool_name` is `Write` or `Edit`. Write also has `tool_input.content`; Edit has `old_string`, `new_string`, `replace_all`. Also present: `tool_response.filePath`, `tool_use_id`, `duration_ms`. |
| `tool_input.skill` and `tool_input.args` on PreToolUse Skill | Present, `tool_name` is `Skill`. `args` is a plain string (`base:development`). Not captured: the shape when no args are given (likely absent, treat as empty). |
| `prompt` on UserPromptSubmit; typed command raw or expanded | `prompt` present. A typed slash command arrives RAW: `"/ce-code-review"` and `"/compound-engineering:ce-code-review base:development"` verbatim, no expansion, no leading whitespace. Both the bare and the plugin-qualified names arrive as typed. |
| `transcript_path` on Stop | Present. Also present: `session_id`, `cwd`, `permission_mode`, `prompt_id`, `stop_hook_active` (false), `last_assistant_message`, `background_tasks`, `session_crons`. |
| `agent_transcript_path` (and `transcript_path`) on SubagentStop | Both present. `transcript_path` is the PARENT session transcript; `agent_transcript_path` is `<session-dir>/<session-id>/subagents/agent-<agent_id>.jsonl`. Also `agent_id`, `agent_type`, `last_assistant_message`. |
| `stop_hook_active` | Present on Stop and SubagentStop (false). Absent on the other events. |
| `cwd` | Present on every event. |

Extra fields not assumed: `session_id`, `prompt_id`, `permission_mode`, `effort.level` (absent on UserPromptSubmit).

Absent: nothing the plan assumed was missing. PostToolUse has no separate "success" flag; failures show in `tool_response`.

## Transcript shapes (`transcript-excerpt.jsonl`)

One JSON object per line. The excerpt holds, in order:

1. A blocked typed `/ce-code-review`: a `queue-operation` line (`operation: enqueue`, `content` is the raw typed text), then a `system` line (`subtype: informational`) whose `content` ends `Original prompt: /ce-code-review`. NO `user` line is written for a prompt a hook blocked. So a stamp hook cannot rely on a `type:"user"` line for a typed command.
2. An allowed typed slash command (`/simplify base:development`): a `queue-operation` enqueue line with `content: "/simplify base:development"`, then a `type:"user"` line with `message.content` a STRING `<command-message>simplify</command-message>\n<command-name>/simplify</command-name>\n<command-args>base:development</command-args>`. The skill body follows as a separate `isMeta:true` user line (not in the excerpt, it is long). For `ce-code-review` the same shape would hold with `<command-name>/ce-code-review</command-name>` (or the plugin-qualified name) and `<command-args>` carrying the arguments. This is inferred from `/simplify`, since plugin skills did not load.
3. A Skill tool call: an `assistant` line whose `message.content` array holds `{"type":"tool_use","name":"Skill","input":{"skill":"simplify","args":"base:development"}}`. Its `tool_result` (here an error, since the hook denied it) is a following `user` line.

A grep for the Skill call's args works on the `"args":"…"` text inside the `tool_use` input. A grep for a typed command works on `<command-args>…</command-args>` in an allowed prompt, and on the `queue-operation` `content` (present in both allowed and blocked cases, so it is the most reliable place to find the raw typed text). Not captured: a real ce-code-review run folder path in a transcript (plugin skills did not load), so KTD9's run-folder grep is untested here.

## wb continue captures (2026-11-15, Claude Code 2.1.325)

Captured for the wb continue plan (`docs/plans/2026-11-15-1125-feat-wb-continue-plan.md`, U1). One interactive Claude ran in a throwaway tmux server with the `claude` zsh wrapper active, started as `claude --session-id <uuid> --setting-sources project --settings <file> --permission-mode acceptEdits … -- "/wb-continue launch-arg"`, with a project skill `wb-continue` that only replies `armed`. A capture hook was registered for UserPromptSubmit, Stop, SubagentStop, SessionStart and SessionEnd. The runner typed prompts into the pane with `tmux send-keys`.

| File | Event | What it shows |
|---|---|---|
| `Stop-background-work.json` | Stop | A turn that ended with a background Bash shell, a Monitor, a background subagent and a one-off CronCreate job all pending |
| `UserPromptSubmit-scheduled.json` | UserPromptSubmit | The prompt a CronCreate job fired (`/wb-continue from-cron`); same shape as a typed prompt |
| `SessionStart-startup.json` | SessionStart | `source: startup`, `session_id` is the `--session-id` given |
| `SessionStart-clear.json` | SessionStart | After a typed `/clear`: `source: clear`, a NEW `session_id` |
| `SessionEnd-clear.json` | SessionEnd | `/clear`: `reason: clear`, the old session id |
| `SessionEnd-respawn.json` | SessionEnd | `tmux respawn-pane -k` on the pane while Claude was idle: `reason: other` |
| `transcript-continue-sources.jsonl` | n/a | Scrubbed transcript lines for each way a prompt arrived, plus the background-task tool results |

Findings:

- **Telling a typed prompt from other sources.** The hook payloads cannot: UserPromptSubmit looks the same for a typed prompt and a cron-fired one. The transcript can. A prompt typed in the TUI and a prompt given on the command line at launch both get `origin: {kind: "human"}` and `turnOrigin: "human"` (a typed plain-text prompt also has `promptSource: "typed"`; a typed slash command and a launch-argument prompt do not). A cron-fired prompt has NO `origin`, `turnOrigin: "scheduled"` and `wakeupSource: "schedule_wakeup"`. Task notifications have `origin.kind: "task-notification"`; subagent hand-backs and peer messages `"peer"` (seen in older transcripts); usage-limit resumes `"auto-continuation"`. A Skill-tool call writes no origin-bearing line: the turn keeps the `promptId` of the prompt that opened it.
- **Slash command records.** A typed `/wb-continue typed "quoted" <angle> & amp` is the string `<command-message>wb-continue</command-message>\n<command-name>/wb-continue</command-name>\n<command-args>typed "quoted" <angle> & amp</command-args>`: arguments raw, unescaped. With no arguments the `<command-args>` element is absent.
- **`background_tasks` element shapes.** `{id, type: "shell", status, description, command}` for a background Bash shell AND for a Monitor (a Monitor is NOT `type: "monitor"` in this version); `{id, type: "subagent", status, description, agent_type}` for a background Agent. Monitors are told apart through the transcript: the Monitor tool result's `toolUseResult` is `{taskId, timeoutMs, persistent}`, a background Bash result's is `{…, backgroundTaskId}`. A finished task drops out of the list at the next Stop.
- **`session_crons` element shape.** `{id, schedule, recurring, prompt}`; a one-off job leaves the list once it has fired.
- **Background shells survive `/clear`.** A shell started before `/clear` delivered its task notification into the new session.
- **`respawn-pane -k` ends Claude cleanly enough for hooks.** SessionEnd ran (`reason: other`) and the Claude process was gone; the pane's shell was back (`pane_current_command` = `zsh`) about 9 ms after the respawn. So SessionEnd consumers (the reply log's final fill-in, wb-capture's end hook) run on a restart without help.
- **Launch through the wrapper.** The command typed into the restarted shell ran the real `claude` inside a `wb-agent-<session>-<shell-pid>-<ts>.scope` systemd scope; `--session-id` became the session id of the startup SessionStart, the launch-argument slash command ran the skill and fired UserPromptSubmit. With a stub `claude` and the real `~/.zshrc` (zsh-vi-mode, oh-my-posh), the shell accepted typed-ahead input about 1 s after the respawn and quitting the stub returned to a zsh prompt.
- **Hook environment.** Every hook process had `CLAUDE_CODE_SESSION_ID` (switching to the new id after `/clear`), `TMUX_PANE` and `CLAUDE_CODE_ENTRYPOINT=cli`.
- **Model and effort.** The Stop payload carries `effort.level` and `permission_mode`; the model id is `.message.model` on the transcript's assistant lines (`claude-opus-5-5`).
