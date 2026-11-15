# Requirements and the test seam

Read this at the start of stage 1, before any shaping. Its job is a numbered list of behaviour the task must have, and an agreed place to test it.

## Use what exists first

Look for a numbered list already written: a brainstorm's requirements, the task brief, the plan's Product Contract. Check the task file, its dossier and `docs/plans/`.

- **Found one.** Copy each item into `requirements` in `verify.json` with its number kept in the `id` (`R1` stays `R1`). Do not reword the sentences. Add the label, `why` and `wrong_when` yourself. Say in chat which list you took.
- **Found none.** Write one (below).

## Writing the list

1. **Do not interview.** Read the conversation, the task file, the dossier and the relevant code. Ask only when a gap would change the shape of the list. Unknown detail becomes an open decision, not a question.
2. **State what is already settled** in chat before drafting (architecture choices, sequencing, non-goals), so the list does not reopen it. Redraft if Jet corrects it.
3. **Agree the test seam first.** See the next section. Write nothing until Jet says yes.
4. **Write the numbered behaviour** using the template. Each requirement is one sentence a reviewer could turn into a test at the agreed seam. A list whose requirements cannot be tested at the seam is not finished.
5. **Put it in `verify.json`**, not in a separate spec file. If Jet also wants a readable spec for the team, write it from the document and land it at `docs/plans/<yyyy-mm-dd>-<slug>-spec.md` or in the dossier. Never leave it scratch-only.

## Agree the test seam first

The seam is where the behaviour is tested, not how.

- Prefer an existing seam over a new one.
- Prefer the highest seam that still shows the behaviour.
- Use as few seams as you can, ideally one.

Present the seam in one short paragraph: what it is, why it beats the alternatives, and which existing fixtures or harnesses it reuses. Then wait for a yes. If Jet names a different seam, redraft from his.

## Template

Write each requirement from the consumer's side. The consumer is whoever uses the surface: a caller, a job, a developer running a command. It is not always an end user.

```markdown
# <Feature> requirements

## Summary
One to three sentences: what changes and the outcome, from the consumer's view.

## Non-goals
What this explicitly does not do. Contested scope goes here, not in prose.

## User stories
Numbered. `As a <actor>, I want <capability>, so that <benefit>.`
Actors may be systems or roles. Cover every consumer of the surface.

## Behaviour
Numbered, testable invariants. Cover: the default flow, every state and
transition, inputs and responses, failure and missing-input states,
re-running, and what must not regress. Put an `**Open question:**` under
the requirement it belongs to.

## Test seams
Where the requirements are tested. Name the seam, why it won over the
alternatives, and which existing fixtures or harnesses it reuses.

## Open questions
Only those not already inline, each with who can answer it.
```

In `verify.json` the Behaviour items become `requirements`, the Open questions become `decisions`, and the seam goes in a decision if Jet has not yet agreed it. Summary, Non-goals and User stories stay in the spec file when you write one, and in the task file otherwise.

## Writing rules

- No implementation detail in a requirement: no module names, file paths, types or algorithms. They go stale.
- No ticket numbers, PR numbers or scratch paths in the body. Describe deferred work in words.
- Settled and open must be visible. A choice Jet made is stated as fact. Anything still being clarified is an open question, never "assumed" or "will land".
- Keep Summary and Non-goals thin, so the length reflects the feature and not the template.
- Plain words. Define a coined term at first use.
- Mark `lasting: true` on a requirement that states behaviour which should keep holding after the task ships. Stage 4 offers a live check for each.
