# Shaping: what to check, what to put to Jet

Read this when you move from the numbered requirements to proposing proof. Every check here comes from a real case where a test passed, or nearly did, for the wrong reason. Run them before you propose anything, and record what you did in `checked` and `unchecked`.

## Before you propose

1. **Find the nearest test.** Name the existing test file closest to the change, and read it. New tests go beside it, in its style. Use the repo's own test command, found in its README, AGENTS.md or Makefile. Do not detect the stack or invent a command. If you cannot tell which command runs the tests, say so under `unchecked`.
2. **Write `why` and `wrong_when` for every requirement.** `why` says what goes wrong for someone if the requirement fails. `wrong_when` says how it could be wrong while every test passes. If you cannot think of a way, the requirement is probably too vague to test, so tighten it.
3. **Run the checks below** and let each one change the proposal.
4. **List what you checked and what you could not** (`checked`, `unchecked`). A check you skipped for lack of access goes under `unchecked`, with the reason. Never leave the page implying a check happened.

## The checks

### How does a local caller get the identity the code expects?

Code that gates on who is calling cannot be run for real until you can be that caller. Find out how a local run gets that identity: a dev login, a seeded user, a signed test token, or nothing at all. Do it early, because the answer decides how much of the walkthrough is worth buying.

Do not take "it needs a real login" on trust. Try the cheapest route first, such as one request with a hand-built token. Also try the reverse: an identity path you assumed was cheap may need setup nobody has done.

Example: a library book-holds app checks the member id on every request. If a local run can set the member id with one header, the walkthrough can be a single command. If not, push the proof into tests.

### What does the real client actually send?

A test sends what its author assumed. The real client may send something else: a different parameter name, a field that is always present or never present, extra headers, another format. Read the client's code, or capture one real request, and compare it with what the test sends.

This reorders priorities. A branch you called defence in depth may be the one the client always takes. A mismatch you feared may already be handled by shared code. Settle it before writing tests.

### Is the cheap layer reachable?

A plan often says "this test is cheap because we reuse X", where X is a harness, a fixture builder or a helper. Check that X is reachable from where the test will run and does what the test needs. Look for visibility (test-package-private), scope (one database schema when the test needs two), and required setup (non-null columns, seeded lookup tables).

The check works in the other direction too. When you find "no such helper exists", search once across neighbouring packages before accepting a build-from-scratch cost. Shared helpers often sit one level up.

If the layer is not reachable, say so in the proposal and cost it honestly.

### What else could make a gating test pass?

A gating test checks that something is allowed for one caller and refused for another. It is worthless if the two cases differ in more than the thing under test.

For every gating test, ask: what else could make this pass? List the other differences between the two cases. Then build the test so that only one variable changes:

- **Prefer one subject with one variable toggled.** The same user, the same data, with only the flag flipped.
- Avoid two different subjects whose results can differ for unrelated reasons, such as different memberships or different data.
- Check that the setup does not hand the answer to the case you expect to be refused. A view or a default that grants wider access than you think can make a "refused" case pass for the wrong reason. Remove or omit the grant so only the rule under test can decide.

State the toggled variable in the test's `passing_tells`. Write what a pass tells you, not what the test does.

### Is every wiring of the gate covered?

One rule is often enforced at several entry points: two endpoints, a list and a detail view, a job and a request. For each gate, list every place it is wired in. Cover each one, or record the ones you do not cover as an accepted gap with a reason. Do not mark a gate verified because one of its wirings is. Do not call a second wiring covered because it looks the same.

## Decisions to consider putting to Jet

Put a choice to Jet when it is his: it changes cost, risk or what he has to do. Each decision carries options, a cost and "what this proves" for each option, and a recommendation (R4). Write the cost and the proof honestly. Leave a field out rather than invent one.

Consider these three every time. Drop one only when the answer is obvious, and then state the default in chat.

1. **How Jet sees it working.** Options run from "no hands-on step, tests only" through "one short local walkthrough" to "a walkthrough that touches cloud". Cost is his time and the access it needs. Proof is what he sees that no test shows. Use the result of the identity check to recommend.
2. **Where the main automated proof sits.** Options are the seams you found: unit, integration against a real dependency, end to end. Cost is setup and run time. Proof is what that lane shows and what it fakes. Recommend the highest seam whose setup you have confirmed is reachable.
3. **What to do about an untested requirement.** For each requirement that no test or step covers, the options are: accept the gap with a reason (`accepted_gap`), add a walkthrough step, or add a test. Cost differs, and so does what each proves. Recommend one, and say why.

Add task-specific decisions as they come up. Link each decision to the requirements it concerns in `requirements`, so an open decision stands in for proof that is not yet agreed.

## Marking firm and tentative

A proposed test or step that rests on an open decision is shown as tentative. A test names the decision it rests on in `decision`. Never store firm or tentative. The page derives it from the decision's status.
