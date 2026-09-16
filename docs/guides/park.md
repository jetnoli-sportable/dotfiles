---
title: park
status: current
tile: <10s capture of a "deal with this later" item.
group: skills
kind: guide
updated: 2026-09-15
---

## Overview

Near-zero-ceremony deferral. Not-work-shaped items go straight into the
standing weekly-capture doc (`wb week append`) with no confirmation step —
work-shaped items propose a `prospective` task and ask first, since that's
a real store write. Exists so "let's discuss this later" doesn't evaporate
when the conversation ends. Capture half of the pair — [weekly-review](weekly-review.html)
is the ceremony that reviews everything captured here.

## Try it now

In any Claude Code session:

```
/park try out the new help picker on a real question
```

Not work-shaped — the agent appends it under the capture doc's `New ideas`
section (or whichever fits) and confirms in one line: `Parked (not
work-shaped) to "New ideas": "try out the new help picker on a real
question"`. That's the whole flow for non-work capture.

For a work-shaped note (e.g. `/park the export endpoint should retry on a
timeout`), the agent instead asks before creating anything — see Reference.

## Reference

| Trigger | Behavior |
|---|---|
| `/park <note>`, not work-shaped | Appends under the best-fit capture-doc section, no asking |
| `/park <note>`, work-shaped | Proposes a `status: prospective` task, asks first — declining falls back to the capture doc |
| `/park` (no argument) | Agent summarizes the thing under discussion into a one-liner, then judges it the same way |
| Saying "park this" / "revisit later" / "make a follow-up task for this" in passing | Agent captures proactively and tells you in one line |

The capture doc lives at `~/code/tasks/weeks/capture.md` (`wb week path` to
print it, or **`prefix+p`** to open it directly in nvim) with four standing
sections: `What's working`, `What's not working`, `New ideas`, `Notes`.
Each entry is stamped with date/repo/branch and starts unreviewed
(`- [ ]`); `/weekly-review` rolls every unreviewed entry into that week's
output record — its durable, immutable copy — and then removes it from the
capture doc, which stays bounded to only what's still unreviewed rather
than growing forever. Nothing is silently re-offered or silently dropped:
the record is where a reviewed entry's text lives on.

## Known rough edges

- The work-shaped/not-shaped judgement is a one-line guess, stated so a
  wrong call is easy to correct — it is not infallible.
- If something needs action *now*, don't park it — the skill itself will
  refuse the detour and just do the work.

## Next steps / reverting

- Review captured items weekly with [/weekly-review](weekly-review.html).
- The capture doc is a plain markdown file — `prefix+p`, read it, edit an
  entry by hand, or move something out if it should never resurface. Skill
  source: `claude/.claude/skills/park/SKILL.md`.
