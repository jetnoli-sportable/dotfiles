# wb breakdown — feat-big (proj--feat-big)

> Approved on the /decide page, converted by answers-to-proposal.sh. `wb breakdown --apply` executes exactly what is checked.

<!-- wb-breakdown: block=approve parent=proj--feat-big -->
- [x] **Approve — apply everything ticked below**

## child 1 — First slice
<!-- wb-breakdown: block=child n=1 parent=proj--feat-big repo=proj -->
- [x] create child: `feat-big-renamed`
- goal: first slice of the big task
- size:
- depends_on:
<!-- wb-breakdown: begin-plan n=1 -->
plan body for child one
<!-- wb-breakdown: end-plan -->

## child 2 — Second slice
<!-- wb-breakdown: block=child n=2 parent=proj--feat-big repo=proj -->
- [x] create child: `feat-big-two`
- goal: second slice
- size: S
- depends_on: `feat-big-renamed`
<!-- wb-breakdown: begin-plan n=2 -->
plan body for child two
<!-- wb-breakdown: end-plan -->

## parent edits
<!-- wb-breakdown: block=parent parent=proj--feat-big -->
- [x] rewrite parent ## Plan as below
<!-- wb-breakdown: begin-plan parent -->
post split summary

Not split out: Third slice

plan body for child three
<!-- wb-breakdown: end-plan -->
- [x] move follow-up: "explore wb breakdown verb further" → child: `feat-big-two`
