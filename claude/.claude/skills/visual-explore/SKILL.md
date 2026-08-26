---
name: visual-explore
description: Explores HTML/visual design directions by fanning out parallel low-effort subagents, each producing a self-contained mockup of a distinct visual approach against the same small sample content, then opening all of them in the browser at once for side-by-side comparison. Runs in rounds — each round either explores fresh directions or refines/combines the winning elements from the previous round by having each new variant read the actual winning file as its base rather than a re-description — until the user converges on a direction, which then gets applied to the real, full deliverable. Use when the user wants to compare visual styles/layouts for a diagram, dashboard, or doc before committing to one ("show me a few options", "let's mock up some visuals", "I want to see this as a pipeline/dashboard/etc and compare").
---

# visual-explore — parallel mockup fan-out for visual design decisions

Design decisions about *how something should look* are usually cheaper to
resolve by looking at real rendered options than by describing them in
prose. This skill encodes a workflow validated across several rounds in a
real session: fan out N cheap, fast mockups exploring distinct visual
directions, open them together, let the user react, then converge.

## When to use

The user wants to compare visual/layout approaches for something that will
render as HTML — a diagram, a dashboard, a status board, a report. Trigger
phrases: "let's see a few visual options", "mock this up a few different
ways", "I want to compare styles before we commit". Not for cases where the
user already knows exactly what they want and just wants it built.

## The core loop

1. **Pick a small, representative sample of the real content.** Don't use
   the full dataset — 2-4 representative items is enough to judge a visual
   style. Use the *same* sample across every variant in a round so the
   comparison is apples-to-apples, not confounded by different content.

2. **Fan out N parallel subagents (N=3-5 typically), each on the platform's
   cheap/fast model tier** (e.g. Sonnet when the session model is Opus),
   with instructions to move fast: "do NOT research or verify anything, use
   the sample content given, just build the visual." Each variant gets:
   - The same sample content, verbatim.
   - A distinctly different visual-style directive — not just a color
     tweak, an actually different visual paradigm (e.g. "swimlane rows"
     vs. "vertical funnel cards" vs. "literal pipe/valve metaphor" — real
     conceptual variety, not minor reskins of one idea, especially in the
     first exploration round).
   - A unique output filename.
   - Self-contained-HTML constraints (inline CSS, no external fonts/scripts/
     CDNs) and a short one-line caption identifying which mockup it is.
   - An instruction to report back only a one-sentence description when
     done, not a running commentary.

3. **Write mockups to a location the browser can actually see — not the
   session scratchpad.** This is the load-bearing gotcha this skill exists
   to encode: if the browser is a Linux **snap package** (e.g.
   `/snap/bin/chromium`), it runs in a confined mount namespace where
   `/tmp` is often private to the snap and invisible to the rest of the
   system. A `file:///tmp/...` URL will silently fail to open — no error,
   just nothing happens, and you'll have no way to tell from the launch
   command alone. Use a directory under `$HOME` instead (e.g.
   `~/pipeline-mocks/`, `~/design-mocks/` — pick something scoped to the
   task, gitignored/untracked, throwaway). Check `which google-chrome
   google-chrome-stable chromium chromium-browser` and `ls /snap/bin/` up
   front to find the real launch binary — `google-chrome` often doesn't
   exist even when a Chromium-family browser does.

4. **Open all N variants in one browser invocation.** Pass every file URL
   as a separate argument to the same launch command:
   ```
   /snap/bin/chromium "file:///home/USER/mocks/a.html" "file:///home/USER/mocks/b.html" ...
   ```
   Most browsers are single-instance apps — a new invocation sends the URLs
   to the already-running instance via IPC and the launching process exits
   immediately. Redirect stdout/stderr to a log file and check it:
   `"Opening in existing browser session."` is a genuine success signal:
   trust it. A silent/empty log with no such message is the signal
   something (usually the snap-sandboxing path issue above) is wrong — fix
   the path, don't assume it worked. Don't try to verify the tab opened via
   window-manager tools like `wmctrl` — in remote/Wayland desktop sessions
   these often can't see the actual windows and an empty listing proves
   nothing either way.

5. **Get the user's reaction.** They'll typically like specific *elements*
   across different variants rather than one whole variant outright — capture
   that precisely (e.g. "2's badge idea is good but needs fleshing out, 3's
   expand-on-click is nice, 4's header treatment is the one").

6. **Next round: refine or combine, always building on the actual winning
   file(s).** Fan out again, but this time each subagent's prompt starts
   with "read this existing mockup file in full" (the winner from the last
   round) rather than re-describing it from scratch — this keeps iteration
   convergent instead of drifting. Each new variant in the round explores
   ONE clearly-scoped change against that same base (a polish pass, one new
   feature, a structural tweak) so the user can attribute what they like/
   dislike to a specific, isolated change. Avoid combining multiple
   unrelated changes into one variant in a refinement round — that muddies
   which change earned the reaction.

7. **Repeat until the user signals convergence** ("that's the one", "let's
   finalize", explicit acceptance of a combination of elements).

8. **Apply the converged direction to the real, full deliverable** — not
   just the sample. This is usually its own dispatch: give the agent the
   winning mockup file(s) to read as the visual/structural reference, and
   the actual full content to render into that structure. If the "more
   fleshing out" the user asked for on some element (a badge system, an
   icon set, whatever) is substantial, it's reasonable to treat that as
   follow-up work rather than trying to perfect it in the same turn as
   finalizing the direction — say so explicitly rather than quietly
   shipping a half-finished version of that element.

## Notes

- Keep mockup directories out of version control — they're throwaway
  comparison artifacts, not the deliverable. The real output goes wherever
  the actual deliverable belongs (a docs/ path, an Artifact, etc.).
- Real conceptual variety in round 1 matters more than polish — a round of
  5 near-identical reskins teaches the user less than 3 genuinely different
  paradigms. Save polish/refinement variety for later rounds once a
  direction is chosen.
- This skill is about **exploring and converging on a visual direction**,
  not about producing the final deliverable itself — the last step (8)
  hands off to whatever normal authoring process produces that deliverable
  (write the doc, publish the Artifact, etc.).
