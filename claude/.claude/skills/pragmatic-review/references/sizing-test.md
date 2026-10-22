# Sizing test

The right-sizing pass gives every step one verdict. This file holds the
test that decides it, the rule for foundations, and two traps to check
before cutting anything that looks like hardening. All of it is general;
the business context from the learnings file and the interview decides how
each condition comes out for a given step.

## Where the test comes from

The two conditions are restated from the mechanism-sizing rule in the
scope-guardian reviewer of the Compound Engineering plugin's
`ce-doc-review` skill (`references/personas/scope-guardian-reviewer.md`,
section 5). It is restated here, not linked, because the plugin cache path
carries the plugin's version number and a link would break on the next
update. The difference: scope-guardian judges a step against the plan's own
goals; this skill judges it against the business the plan is for.

## The test

A step that isn't the core of what was asked earns a place now only when an
existing contract requires it, or one of these holds:

1. **Leaving it out causes harm nobody would catch in time.** The failure
   can actually happen here (trace it), and the way the result is used
   would not show it quickly to someone who can fix it cheaply. A person
   being told to avoid the failure, or to clean up by hand afterwards, does
   not count as catching it.
2. **Adding it later would be expensive**, because it concerns stored data
   or its format, a public or shared interface, money, or security.

Business context decides both. "Caught in time" depends on who uses the
output and how fast a wrong result reaches someone who would notice. "Later
is expensive" depends on how much data will exist by then and how many
consumers will depend on the interface.

## Verdicts

Every step gets exactly one (R4):

| Verdict | Means | The line must say |
|---|---|---|
| **needed now** | Core to what was asked, or passes the test in the current order | Which condition it passes, or that it is the core |
| **needed later** | Fails the test today, but a foreseeable event would make it pass | The trigger: the volume, consumer, date or incident that makes it needed |
| **not needed** | Fails the test, and nothing on the roadmap would change that | Why neither condition holds |
| **move** | Needed, but in the wrong place | Its new position in the revised order (points at the sequencing pass) |

A trigger is a concrete, observable event ("a second team starts reading
this table", "more than one deploy a day"), never "when we scale" or "if it
becomes a problem".

When you can't tell whether a step passes, say so, pick the verdict you'd
default to, and add a question to the interview naming the fact that would
settle it. Never guess silently.

## Steps already built or in flight

Judge only the work that remains. Code already written is a sunk cost: the
question is whether to spend more on it now, not whether it should have been
built.

- **Built, merged or ready to merge, consumer arrives later:** "needed now"
  for finishing as built, with "no further investment until <trigger>" as
  its line. Don't recommend removing working code just because its
  consumer is later, unless keeping it costs something real (it must be
  maintained against a moving interface, or it misleads users).
- **In flight:** size the rest of it. If the remaining part fails the test,
  recommend stopping at the smallest point that leaves something usable,
  and name that point.
- **Done:** context, not a verdict. List it in the step list so the order
  makes sense, and give it no verdict.

## The foundation rule

Two pulls run against each other. Cutting everything not needed today
throws away foundations that make the next step cheap. Building every
foundation adds structure for consumers that may never arrive.

A foundation or abstraction counts as justified (R5) when either:

- **its next variant is already named on the roadmap**: a planned step,
  ticket or rung says what the second consumer is. "We might want X" is not
  named; "rung 3 adds X" is.
- **adding it later would be expensive**, by condition 2 above: retrofitting
  it means migrating stored data, changing a shared interface other teams
  call, or touching money or security.

A justified foundation is built as small as its named variants need, not
for every variant imaginable. One that meets neither condition is "needed
later", with the second consumer's arrival as its trigger.

## Two traps before cutting hardening

Check both before giving "needed later" or "not needed" to anything that
looks like robustness, validation or protection.

### Trap 1: a survival need that looks like polish

Some steps that read as hardening are what keeps the feature from being
silently wrong. The test: without this step, does the core output come out
wrong with no error? If yes, it is a must, not a should.

- Recognise it: a guard, a lock, an ordering constraint, or a check that
  protects the core fact the feature exists to produce. Typical shape:
  something else overwrites or races the value, so the feature works in a
  demo and quietly breaks in real use.
- Example: a flag stamped on a record that another process rewrites in full
  on every sync. Without a guard that keeps the flag, it disappears seconds
  after it is set. The guard is "needed now", even though it looks like
  defensive code.

### Trap 2: trust work timed to its consumer

Security, anti-forgery, access checks and audit trails become needed at the
moment something starts relying on the fact they protect, not before and
not after.

- Recognise it: the step protects a value that some later reader will
  trust to make a decision (grant access, charge money, report a number
  outward).
- Find when that reader arrives. If it is far off, "needed later" with the
  reader's arrival as the trigger. If it is imminent, keep the step now:
  deferring it means removing tested code and adding it back days later,
  with a gap where the value can be forged.

## Folding in extra work

When a review turns up a same-shaped problem the plan left out, fold it into
the plan only if confidence is high and the change is low-risk (for example
test-only, applying a pattern already proven elsewhere in the plan).
Anything uncertain or touching production behaviour stays out until it is
an observed problem, recorded as "needed later" with that observation as
the trigger.
