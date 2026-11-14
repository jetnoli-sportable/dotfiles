# Buffer shapes

Four shapes for the `/decide` buffer. Each is plain markdown Jet edits in nvim
and closes with `:wq`. Keep each shape's top comment: it is the only
instruction he sees. Load only the shape you use.

Rules for every shape:

- No option is ever pre-ticked, the recommended one included.
- Every checkbox is on its own line, below the first heading. Never two
  `- [ ]` on one row.
- Every question says why it is asked and what stage it belongs to, and stands
  alone: terms defined at first use, code excerpts inline, every ticket, PR or
  link given with a plain description.
- Findings or choices that need a reaction ("agree / disagree") fold into
  Questions: a recommended option first, one to four real alternatives (five
  at most), and escape hatches `Dig deeper` and `Out of scope` where they fit.
  A pure fact-check can be a short yes/no list in the same shape.
- A buffer past about six questions, or one needing a diagram, table or long
  evidence, is a page.

## Questions

A choice between named options, plus free text. Each question has its options
with a pro and a con, a Recommendation, a stated default, and its own
Questions / Notes part directly under it (never one at the end of the file).

~~~markdown
# Decisions: <topic>
<!-- Tick one box per question, or write under "Other". Put any question or note
     under that question's "Questions / Notes". A question left blank takes its
     stated default, but only if you answered at least one other question; a
     buffer closed unchanged applies nothing. :wq when done. -->

## 1. <Short title, used as the Decisions entry title>

<Two or three sentences of context: what hangs on it, why it is asked now, and
what stage it belongs to. Inline code or an excerpt when it is about code.>

- [ ] A. <option> — Pro: ... Con: ...
- [ ] B. <option> — Pro: ... Con: ...
- Other:

**Recommendation:** A — <one line on why it beats B here>.
**Default if left blank:** A (or "none: I'll ask you in chat").

### Questions / Notes

_(yours)_

## 2. <Short title>

(same shape)
~~~

The Recommendation and Default lines go after the last option and before that
question's Questions / Notes. Write a Recommendation on every question (Jet
asks for one each time); state the default only when a blank answer is
genuinely safe. A question with no stated default is unanswered when left
blank.

## Interview

Free-text answers, where there is no menu to pick from: clarifying a
brainstorm, filling in intent you can't infer, surfacing assumptions before
planning. Each question says why it matters and what you will assume if left
blank.

~~~markdown
# Interview: <topic>
<!-- Nothing here is an option to pick. Write your answer under "Answer:", as
     short or long as you like. A blank answer means my stated default goes
     forward as an explicit assumption, labelled as yours by silence, not as a
     decision. Write "ask me in chat" to take one live. :wq when done. -->

## I1. <short topic name>

<The question, with enough standalone context to answer without another doc.>

**Why it matters:** <what this answer changes downstream>.

**My default if blank:** <the concrete assumption, specific enough that
"silence = this" is unambiguous>.

Answer:

## Anything else

_(yours)_
~~~

A blank answer with a stated default is recorded with `wb decision --default`
and says so wherever the assumption is used next, so it stays visible and
reversible.

## Code-review triage

Per finding: a Recommendation, the recommended fix first, one to four real
alternatives, then Defer and Skip last. Never a flat Apply / Defer / Skip row.
Lead a design-call finding with its big-picture tie (which rung or goal owns
it, why it surfaces now), and say why a previously deferred item has come back.

~~~markdown
# Triage: <review or PR, with a plain description>
<!-- Tick ONE option per finding. Nothing is pre-ticked, and a finding left
     unmarked is not applied: the recommendation is never applied on silence.
     A ticked fix is applied as written; Defer goes to a follow-up note;
     Skip is dropped. Editing a finding counts as a note and is answered first.
     :wq when done. -->

## <File or area>

### Finding 1 — <one-line summary>

<The issue, with a `file:line` so it can be checked, and the big-picture tie.>

```<lang>
<the snippet the finding points at>
```

**Recommendation:** A — <one line on why it beats the alternatives>.

- [ ] **A — <recommended fix>** — <what changes>
- [ ] **B — <alternative fix>** — <what changes, and the trade-off against A>
- [ ] **Defer** — carry to a follow-up, don't change it in this pass
- [ ] **Skip** — not worth acting on; drop it

### Questions / Notes

_(yours)_
~~~

An alternative must differ in what gets built, not restate A. A finding with
one sensible fix lists it, then Defer and Skip, with no straw man. Defer and
Skip are always the last two, in that order.

## Run and paste

A loop where Jet runs commands somewhere you can't (another machine, a real
login, a GUI) and pastes back what he sees.

~~~markdown
# Run and paste: <topic>
<!-- Run each command where it says, paste what it prints under Output.
     Skip one by writing "skip". :wq when done. -->

## 1. <What this checks, and why>

Where: <machine or app>

```sh
<command>
```

Output:

Notes:
~~~

Keep it small. If a step gets no new output after the buffer is reopened about
three times, ask in chat instead of reopening. The pasted output is evidence
for the next step, not a Decisions entry: record a decision only for what Jet
decided.

## Reading a closed buffer

Read `changed:` from `wb decide-buffer` first. `changed: no` applies nothing.
When `changed: yes`, in order:

1. **`Closing because:`**, if Jet wrote one, is read first. A reason that
   signals abort ("too early", "wrong shape", "ignore", "let's talk") applies
   nothing; echo any ticks back as "you also ticked X: carry into the next
   round?". An ambiguous reason is asked about in chat first.
2. **Real answers only:** a checkbox line outside any fenced block,
   blockquote or HTML comment, below the first heading. A literal `[x]` in the
   header comment or an example is never an answer.
3. **Notes before selections.** Any text Jet added or changed (an edited
   option, a reordered list, a struck line, a Questions / Notes entry) counts
   as a reaction and is answered before you act on that item. A note asking a
   question means the item is unanswered until it is settled.
4. **Ambiguity:** two ticks on one question, ask which in chat before touching
   it. A question left unticked is unanswered, except that a stated default is
   taken once Jet answered at least one other question (recorded "default
   taken"). No stated default, or only a note, is unanswered.
5. A ticked fix is applied as written. Defer is carried into a follow-up and
   not re-asked unless Jet asks. Skip is dropped.
