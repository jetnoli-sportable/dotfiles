# Sequencing checks

The checklist the sequencing pass runs over every step. One entry per
pattern: what it is, how to recognise it in a plan, and an example. Each
entry is a general rule about how plans go wrong, never a fact about one
business. Business context only changes how hard a finding bites, not
whether the pattern is present.

Read the list once per run and check every step against every pattern. A
step can match more than one. A flag names the pattern and the step it
wrongly blocks or waits on (R2), for example "S6 — hardening before first
use: blocks S7, the first version users touch".

## The question behind all of them

What is the earliest point at which someone real uses this work, and what is
the shortest path to it? Steps on that path go first. Everything else is
placed by what it needs and what needs it, not by the order a textbook
would list it in.

## 1. An abstraction before its second consumer

- **What it is:** a generic layer, registry, plugin point or shared library
  built before more than one thing uses it.
- **Recognise it:** the step says "generic", "framework", "pluggable",
  "reusable", or "so that later X is easy", and only one current step
  consumes it. Look for who calls it: if the answer is one step, the
  abstraction is a guess about the second.
- **Move it to:** just before the step that brings the second consumer, or
  fold it into that step. Build the first consumer concretely.
- **Exception:** the foundation rule in `sizing-test.md`. When the second
  variant is already named on the roadmap, or the shape is expensive to
  change later, building it first is justified and this is not a flag.
- **Example:** "U2: build a pluggable exporter interface; U3: CSV export".
  The interface has one implementation. Do U3 directly; extract the
  interface when the second format is scheduled.

## 2. Hardening or scaling before first real use

- **What it is:** retries, rate limits, caching, horizontal scaling, load
  tests, failover or broad edge-case handling placed before anyone has used
  the first version.
- **Recognise it:** the step protects against load, failure rates or misuse
  that no one has observed, and it sits earlier than the step where the
  feature first reaches a user. Ask: what evidence says this failure
  happens at this volume?
- **Move it to:** after first use, with the trigger that would make it
  needed (an error rate, a volume, a second tenant). Then it is a "needed
  later" verdict, not a step in the first slice.
- **Check first:** the two traps in `sizing-test.md`. Some things that look
  like hardening are what keeps the feature from being silently wrong.
- **Example:** "Phase 1: autoscaling and a load test; Phase 2: the first
  endpoint". The load test measures a system nobody calls yet.

## 3. A step that needs a later step's output

- **What it is:** a forward dependency. Step N consumes something step N+k
  produces.
- **Recognise it:** read each step's inputs (a table, a schema, an API, a
  config value, a decision) and find where each is produced. Any input
  produced later in the order is a flag. Stated dependencies often miss
  these; read the step's body, not only its `depends_on`.
- **Move it to:** after its producer, or split the producer so the part the
  step needs comes first.
- **Example:** "U3: write the report query; U5: add the column the report
  reads". U3 can't be tested until U5 lands.

## 4. Best-practice order over unblock-real-use order

- **What it is:** steps placed first by habit because they are "foundational"
  in general, when nothing in this plan needs them yet. CI pipelines,
  observability dashboards, test infrastructure, linting, documentation
  sites and environment parity are the usual ones.
- **Recognise it:** the step is early, but no step before first use consumes
  its output. Ask: if this step were removed from the front, which earlier
  step would break? If none, it was placed by habit.
- **Move it to:** the point where something first needs it. A dashboard goes
  next to the first thing worth watching; a CI gate goes in when there is a
  test worth gating on.
- **Example:** "Step 1: full CI/CD with staging and prod; Step 2: prototype
  to show the team". The prototype needs a laptop, not a pipeline.

## 5. Work forced into a sequence that could run in parallel

- **What it is:** steps chained one after another when they share no inputs,
  outputs or files.
- **Recognise it:** two steps have no dependency in either direction (by the
  check in pattern 3) and touch different files or systems, but the plan
  lists them in series or gives one a `depends_on` on the other.
- **Move it to:** a parallel group in the revised order (R3). Name the
  group. Note any shared resource (one test database, one reviewer) that
  limits how parallel it really is.
- **Example:** "U4 backend endpoint, then U5 frontend form" when the API
  contract is already fixed. Both can start once the contract is written.

## 6. A prerequisite buried late

- **What it is:** something many steps need (an access grant, an account, a
  decision from someone outside the team, a data export, a contract) placed
  in the middle or at the end, or not listed at all.
- **Recognise it:** look for steps that assume access, approval or data
  they don't obtain themselves. Anything with a lead time the team doesn't
  control (another team, a vendor, a review board) belongs at the front
  even when the work it unblocks is later.
- **Move it to:** the front, as its own step, started in parallel with
  whatever doesn't need it.
- **Example:** "U6: request production database credentials" behind five
  units that read production data.

## 7. A step with no consumer

- **What it is:** a step whose output nothing in the plan uses, and no named
  roadmap item uses either.
- **Recognise it:** for each step, find what reads its output: a later
  step, a user, an operator, a scheduled job. If nothing does, the step is
  either a missing link in the plan (some consumer isn't written down) or
  not needed.
- **Move it to:** nowhere. Give it a "not needed" verdict, or ask which
  consumer was meant and add that to the review's questions.
- **Example:** "U7: emit usage metrics" when no dashboard, alert or report
  in the plan or roadmap reads them.

## Building the revised order (R3)

1. Put the shortest path to first real use first, in dependency order.
2. Pull buried prerequisites (pattern 6) to the front.
3. Place every other step just before its first consumer, and steps with a
   trigger after the first slice with that trigger named.
4. Group steps with no dependency between them into named parallel groups.
5. Give each moved step one line saying why it moved. A step that stays put
   gets no line.

Propose one order. If two orders are close, pick one and mention the other
in a single line in the review's context section.
