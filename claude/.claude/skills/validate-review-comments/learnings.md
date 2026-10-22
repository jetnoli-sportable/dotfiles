# validate-review-comments learnings

One dated line per entry: what surprised on a run (a mapping the script got
wrong, a misread comment, a page Jet found unhelpful), the target, and the run
directory. Sportable runs log in their own dossier instead, and only a
scrubbed, skill-changing lesson comes here. See `SKILL.md`'s Learnings ledger
section.

- 2026-10-22 — API shape, captured on a synthetic pending review on a dotfiles PR before the script was written: pending review comments carry no `line`, `original_line`, `side`, `start_line`, `start_side` or `subject_type` keys at all (not null, absent), only `position`, `original_position`, `diff_hunk` and `commit_id`. Every `diff_hunk` ended on the commented line, a deleted-line comment's hunk ending in its `-` line; a multi-line comment comes back as its end line only, its start line lost.
