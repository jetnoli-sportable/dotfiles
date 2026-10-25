---
session_id: SID
task: TASK
cwd: /work/demo
branch: feat/demo
created: 2026-10-20T08:00:00Z
---

# demo · 2026-10-20 10:00

## 2026-10-20 11:00 · why does the parser skip blank lines?
<!-- turn {"prompt_id":"p3","session_id":"SID","ts":"2026-10-20T09:00:00.000Z"} -->
### Prompt
> why does the parser skip blank lines? and is that safe?
### Reply
#### Blank lines are skipped on purpose
*Why does the parser skip blank lines?*

They carry no fields, so skipping them keeps the counts right.
#### Skipping them is safe
*Is that safe?*

Yes: nothing downstream reads them.

