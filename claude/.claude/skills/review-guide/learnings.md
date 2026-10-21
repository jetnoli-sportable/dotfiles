# review-guide learnings

One dated line per entry: what surprised on a run (a stage that broke, a lens
that drifted, a page Jet found unhelpful), the target, and the run directory.
See `SKILL.md`'s Learnings ledger section.

- 2026-10-22 — trial 1, branch fix/capture-handback-none (1c96d77..380b089, 75 logic lines), run dir `dossiers/dotfiles--fix-capture-handback-none/review-guide/fix-capture-handback-none/`. 6 agents, about 5 minutes wall-clock from dispatch to verified.json (lenses 23–93 s, coordinator 98 s quick pass + 77 s verify), about 420k subagent tokens in all (lenses 57–73k each, coordinator 87k). 11 lens findings, all cite `ok`; merged to 8 + 1 coordinator finding, none rejected. Fixed in the skill: a branch target passed no `--words`, so the proportion read 0 (commit bodies now count); hand-copying sections into the briefs was slow and error-prone, so `build-briefs.py` does it; the L1 brief's report-name line misfired for a branch; the page title needs to be a short name with no colon. Worth knowing: the coordinator's quick pass found the only medium finding (C-01), which no lens raised, and L4 ran the Docker tests itself, settling a gap three other lenses reported.
