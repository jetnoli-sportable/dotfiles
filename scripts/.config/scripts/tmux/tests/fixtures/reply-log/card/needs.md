---
session_id: SID
task: TASK
cwd: /work/demo
branch: feat/demo
created: 2026-10-20T08:00:00Z
---

# demo · 2026-10-20 10:00

## 2026-10-20 10:00 · Set up the widget parser
<!-- turn {"prompt_id":"p1","session_id":"SID","ts":"2026-10-20T08:00:00.000Z"} -->
### Prompt
> Set up the widget parser
### Reply
The parser is in place.
### Artifacts
- wrote: /work/demo/parser.sh
- https://claude.ai/artifact/AAAA1111

## 2026-10-20 10:30 · Now wire it into the CLI and tell me what's left
<!-- turn {"prompt_id":"p2","session_id":"SID","ts":"2026-10-20T08:30:00.000Z"} -->
### Prompt
> Now wire it into the CLI and tell me what's left
>
> Keep the flags short.
### Reply
#### The CLI calls the parser
It runs on every invocation now. Should the old path stay?
```sh
echo "is this a question?"
```
#### Needs you
- Pick the flag name: `-w` or `-p`?
- Approve deleting the old path.
#### After that
Nothing else.
### Artifacts
- edited: /work/demo/cli.sh
- wrote: /work/demo/parser.sh

