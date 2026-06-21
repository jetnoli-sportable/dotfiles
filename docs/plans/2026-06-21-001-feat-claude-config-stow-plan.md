---
title: "feat: version-control curated ~/.claude config as a stow package"
status: active
date: 2026-06-21
type: feat
---

# feat: version-control curated ~/.claude config as a stow package

## Summary

Bring the **hand-authored, portable** parts of `~/.claude/` under version control as a new `claude/` stow package — global instructions, custom skills, keybindings, and non-secret settings — so the user's Claude Code setup is reproducible across machines like every other tool in the dotfiles repo. **Explicitly exclude machine state and anything sensitive**: session transcripts, auto-generated project memories, caches, and any file containing secrets. The hard part is not stow mechanics — it's drawing the track/ignore line correctly and auditing for secrets before anything is committed.

---

## Problem Frame

Over time the user has accumulated genuinely portable Claude Code config — `~/.claude/CLAUDE.md` (global instructions), bespoke skills under `~/.claude/skills/`, `keybindings.json`, and curated `settings.json` — that today lives only on this machine. It belongs in the dotfiles repo for the same reasons as zsh/tmux/nvim. But `~/.claude/` is a busy directory that also holds **non-portable, sometimes-sensitive** material: `projects/` (full session transcripts + the auto-generated, project-keyed memory files), `todos/`, telemetry/cache dirs, plugin caches, and potentially `settings.local.json` with tokens or machine-specific permissions. Naively stowing `~/.claude` would either commit secrets/transcripts or fight stow's directory folding. This plan curates a safe subset.

---

## Requirements

- **R1.** Track the portable, hand-authored config: `CLAUDE.md`, `skills/`, `keybindings.json`, and the non-secret parts of `settings.json`.
- **R2.** Never commit secrets, tokens, or machine-local state — audited before first commit.
- **R3.** Never commit `~/.claude/projects/` (session transcripts + auto-generated memories) or other regenerable machine state (`todos/`, caches, plugin caches, statsig/telemetry).
- **R4.** Stow cleanly into `~/.claude/` without clobbering or folding the untracked live state already there.
- **R5.** Decide and document the policy for **memories** specifically (they live under `projects/<encoded-path>/memory/`).
- **R6.** Reproducible: a fresh machine can `stow claude` and get the curated config.

---

## Key Technical Decisions

- **Curate, don't mirror.** Track an explicit allowlist, not all of `~/.claude/`. Default-exclude everything; opt-in the portable files.
- **Stow target is `$HOME`, package mirrors `.claude/…`.** Layout `claude/.claude/CLAUDE.md` → `~/.claude/CLAUDE.md`, etc. **Use `stow --no-folding`** so stow symlinks individual files into the existing real `~/.claude/` directory instead of trying to replace the whole dir with a symlink (which would hide the live `projects/`, `todos/`, etc.). This is the crux of R4.
- **Memories: exclude by default (R5).** They live under `~/.claude/projects/<encoded-path>/memory/` — keyed to absolute project paths (non-portable), auto-generated, and may carry sensitive work context. Tracking them would also drag the `projects/` tree in. Decision: **do not track memories** in this package. (If durable cross-machine memory is wanted later, that's a separate, deliberate curation effort — noted in Deferred.)
- **Secret audit is a gate, not a step.** `settings.json` / `settings.local.json` can contain tokens, MCP credentials, or machine-specific permission allowlists. Nothing commits until grepped and reviewed. The personal GitHub PAT already lives in the system keyring (not a file), which is the model to preserve.

---

## Output Structure

```
claude/
  .claude/
    CLAUDE.md            # global instructions (portable)
    keybindings.json     # portable
    settings.json        # curated: non-secret settings only
    skills/              # hand-authored skills (e.g. decision-buffer/)
  README.md              # what's tracked, what's deliberately not, and why
```

Excluded (live, untracked, machine-local — must NOT appear in the package): `~/.claude/projects/`, `~/.claude/todos/`, `~/.claude/settings.local.json` (unless audited clean), plugin/extension caches, statsig/telemetry dirs.

---

## Implementation Units

### U1. Inventory `~/.claude/` and classify every entry

- **Goal:** a definitive track / ignore / audit-first classification of everything in `~/.claude/`.
- **Requirements:** R1, R2, R3, R5
- **Dependencies:** none
- **Files:** `claude/README.md` (the classification table)
- **Approach:** enumerate top-level entries; bucket each as **track** (CLAUDE.md, skills/, keybindings.json, settings.json-after-audit), **ignore** (projects/, todos/, caches, plugin caches, telemetry), or **audit-first** (settings*.json). Record the rationale in README so the policy is legible later.
- **Test scenarios:**
  - Every current top-level entry under `~/.claude/` appears in exactly one bucket (no unclassified leftovers).
  - `Test expectation: none -- classification/inventory step, verified by review against `ls -a ~/.claude`.`
- **Verification:** README table accounts for everything in `~/.claude/`.

### U2. Secret + sensitivity audit of settings before tracking

- **Goal:** confirm no secrets enter the repo.
- **Requirements:** R2
- **Dependencies:** U1
- **Files:** `claude/.claude/settings.json` (curated)
- **Approach:** grep `settings.json`/`settings.local.json` for tokens/keys/credentials/MCP secrets and absolute machine paths. Keep portable, non-secret settings; leave anything sensitive in an untracked `settings.local.json`. Confirm the GitHub PAT is keyring-only (it is) and stays that way.
- **Test scenarios:**
  - `git grep` over the staged `claude/` tree for common secret patterns (token, key, secret, PAT, bearer, `ghp_`, `sk-`) returns nothing.
  - A machine-specific absolute path in settings does not get committed (either omitted or templated).
  - `Covers R2.`
- **Verification:** staged package is secret-free on inspection.

### U3. Build the `claude/` stow package + .gitignore guards

- **Goal:** the package mirrors only the allowlisted files; ignores guard against accidental adds.
- **Requirements:** R1, R3, R4
- **Dependencies:** U1, U2
- **Files:** `claude/.claude/{CLAUDE.md,keybindings.json,settings.json,skills/}`, repo `.gitignore`
- **Approach:** copy the allowlisted files into `claude/.claude/`. Add defensive `.gitignore` entries (e.g. `claude/.claude/settings.local.json`, `claude/.claude/projects/`, caches) so a future careless `git add` can't pull excluded material in.
- **Test scenarios:**
  - `git status` after staging shows only allowlisted files; no `projects/`, `todos/`, or cache paths.
  - `git check-ignore` confirms the excluded paths are ignored.
  - `Covers R3.`
- **Verification:** `git add claude/ && git status` lists only intended files.

### U4. Verify clean stow into the live `~/.claude/`

- **Goal:** `stow claude` symlinks the curated files without disturbing live untracked state.
- **Requirements:** R4, R6
- **Dependencies:** U3
- **Files:** `claude/README.md` (stow instructions)
- **Approach:** `stow -n --no-folding claude` (dry run) from the repo, confirm it only links the allowlisted files and reports no conflicts; resolve any conflict by move-first (back up the live file, then stow), never `--adopt` blindly. Document the `--no-folding` requirement and why.
- **Test scenarios:**
  - `stow -n --no-folding claude` reports only the intended links, no conflicts, and does not propose replacing `~/.claude/` itself with a symlink.
  - After a real `stow`, `~/.claude/projects/` and `~/.claude/todos/` remain real dirs (untouched).
  - `Covers R4, R6.`
- **Verification:** curated files are symlinks into the repo; live state intact.

---

## Scope Boundaries

### In scope
Curated track of CLAUDE.md, skills/, keybindings.json, audited settings.json; explicit ignores; clean `--no-folding` stow; documented policy.

### Deferred to follow-up work
- **Durable cross-machine memories.** If wanted, a separate deliberate effort to curate and de-sensitize selected memory files — not the auto-generated `projects/` tree wholesale.
- **MCP server config sharing** — only if it can be done without committing credentials.

### Out of scope
- `~/.claude/projects/` (transcripts + auto memories), `todos/`, caches, telemetry — machine state, never tracked.

---

## Risks & Dependencies

- **Secret leakage** — the dominant risk; U2 is a hard gate. A committed token is a credential rotation, not just a revert.
- **Stow folding clobber** — without `--no-folding`, stow may try to replace the whole `~/.claude/` dir with a single symlink, hiding live session state. U4 guards this.
- **Skill portability** — some skills may hardcode this machine's absolute paths; flag any that won't work on a fresh machine during U1 (document rather than fix here).

---

## Verification

End state: `claude/` is a stow package tracking only portable, secret-free Claude config; `stow --no-folding claude` reproduces it on a fresh machine; `~/.claude/projects/` and other machine state remain untracked and untouched; README documents exactly what is and isn't tracked, and why memories are excluded.
