# quick-wins — tunable thresholds

The knobs that set what this skill counts as "quick." Edit this file to tune;
it is read at the top of every `/quick-wins` run (SKILL.md step 1). No code, no
flags — this one file is the whole tuning surface. Keep it short and legible.

**This file can only make the auto-lane STRICTER, never looser.** SKILL.md holds
the inviolable hard floors (≤ 15 lines, ≤ 2 files, confidence: high, ≤ 3
auto-lane actions/run). If a value here is *looser* than a floor, the skill
ignores it, clamps to the floor, and notes the clamp. So tightening (e.g. cap
of 1, confidence-only-with-a-test) takes effect; loosening does not — widening
the gate is a change to SKILL.md, not a knob here.

Defaults are deliberately conservative: the skill would rather surface a genuine
quick win for a pick than auto-act on something with a hidden seam.

---

## effort — when is a change "low" effort?

- max_lines_changed: 15          # SKILL.md floor; a smaller value here tightens
- shape_must_be_settled: true    # the "how" must already be decided (a sibling/prior
                                 #   pattern, an obvious one-liner). If "how" is a
                                 #   choice, it is NEEDS-A-PLAN regardless of size.
- open_implementation_choice: disqualifies   # any real fork in approach → not quick

## isolation — when is an item "clean"?

- max_files_touched: 2           # SKILL.md floor; spanning more files reads as coupled
- single_repo_only: true         # cross-repo items are never auto-lane
- unmet_depends_on: disqualifies # a task with an unresolved depends_on is not isolated
- pending_design_decision: disqualifies   # an open decision-buffer round → not isolated
- coupling_not_in_depends_on: surface     # real coupling not captured in depends_on:
                                 #   frontmatter is still coupling — absence of a
                                 #   depends_on is not proof of isolation

## ownership — when is it safe to act here?

- act_only_if: none              # act only when ownership is POSITIVELY none (SKILL.md
                                 #   ownership axis) — a missing reference is `unclear`
- unclear_ownership: surface_never_act     # ambiguous owner → OWNED-ELSEWHERE, surface
- check: [item text, task jira: field (NOT a follow-up's parent jira),
          referenced ticket/PR, open PR/branch touching the target path]

## auto-lane — the "just do it unasked" gate

- enabled: true                  # set false to require an explicit pick for EVERYTHING
- require_confidence: high       # SKILL.md floor; never auto-act below high
- max_auto_lane_items_per_run: 3 # SKILL.md floor; a smaller value here tightens
- always_ask_first: [rm -rf, recursive delete, kill, pkill, DROP, TRUNCATE,
                     PR create, push to shared branch]
                                 # standing rules — no auto-lane exception, ever.
                                 # (Jira is not here because it is NEVER written at
                                 #  all — read-only always; see SKILL.md guardrails.)

## ranking / output

- surface_needs_a_plan_tail: true   # still list NEEDS-A-PLAN items (one line each)
                                    #   so it's clear they were considered, not missed
- max_shortlist_before_buffer: 8    # above this, present as an nvim pick-buffer, not inline
