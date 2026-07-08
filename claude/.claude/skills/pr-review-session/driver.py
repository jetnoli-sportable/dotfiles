#!/usr/bin/env python3
"""
pr-review-session driver.

Deterministic glue for the `pr-review-session` skill. Does the parts that
don't need a model: query GitHub for open PRs across watched repos, decide
which are new/updated since last run, create a git worktree + tmux window per
PR, and scaffold a PR brief pre-filled from GitHub metadata.

The agent does the rest (run ce-code-review, write the brief narrative, mark
done). See SKILL.md.

Subcommands
  plan                       Scan watched repos, print JSON manifest of PRs
                             needing attention (new or new-commits-since-review).
                             No side effects.
  prepare <repo> <pr>        Idempotently ensure worktree + tmux window +
                             scaffolded brief exist for one PR. Prints JSON.
  complete <repo> <pr>       Mark a PR reviewed at its current head sha.
  status                     Show watched repos + tmux session state.

Config:  $PR_REVIEW_CONFIG  (default ~/.config/pr-review-session/config.json)
State:   $PR_REVIEW_STATE   (default ~/.local/state/pr-review-session/state.json)

Stdlib only. No third-party deps.
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

# ---- paths -----------------------------------------------------------------

def _expand(p: str) -> Path:
    return Path(os.path.expanduser(os.path.expandvars(p)))

CONFIG_PATH = _expand(os.environ.get("PR_REVIEW_CONFIG", "~/.config/pr-review-session/config.json"))
STATE_PATH = _expand(os.environ.get("PR_REVIEW_STATE", "~/.local/state/pr-review-session/state.json"))

# Owner of the Sportable GitHub org -> uses the default `gh` token.
# Everything else (personal repos under jetnoli-sportable, other owners)
# uses the personal-account PAT from the keyring, mirroring the `pgh` shell fn.
SPORTABLE_OWNER = "sportabletech"

# ---- small helpers ---------------------------------------------------------

def die(msg: str, code: int = 1):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(code)

def run(cmd, cwd=None, env=None, check=True, capture=True):
    res = subprocess.run(
        cmd, cwd=cwd, env=env, check=False,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        text=True,
    )
    if check and res.returncode != 0:
        err = (res.stderr or "").strip() if capture else ""
        die(f"command failed ({res.returncode}): {' '.join(cmd)}\n{err}")
    return res

def load_json(path: Path, default):
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return default

def save_json(path: Path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")

# ---- config ----------------------------------------------------------------

def load_config():
    cfg = load_json(CONFIG_PATH, None)
    if cfg is None:
        die(f"no config at {CONFIG_PATH}\n"
            f"create it — see SKILL.md. Minimal example:\n"
            f'{{"repos": ["~/code/be--monorepo"], "tmux_session": "pr-review"}}')
    cfg.setdefault("tmux_session", "pr-review")
    cfg.setdefault("limit", 30)
    cfg.setdefault("worktree_dir", ".worktrees")
    repos = cfg.get("repos") or []
    if not repos:
        die("config has no repos")
    # repos may be plain strings (paths) or {path, gh} objects
    norm = []
    for r in repos:
        if isinstance(r, str):
            norm.append({"path": r})
        else:
            norm.append(dict(r))
    cfg["repos"] = norm
    return cfg

# ---- gh / pgh --------------------------------------------------------------

def repo_owner(repo_path: Path) -> str:
    res = run(["git", "-C", str(repo_path), "remote", "get-url", "origin"], check=False)
    url = (res.stdout or "").strip()
    # ssh://git@github.com/OWNER/repo  OR  git@github.com:OWNER/repo.git
    # OR  https://github.com/OWNER/repo(.git) — check the host-path form
    # first: ssh:// URLs contain both ':' and '@' but the owner follows
    # 'github.com/', not the colon.
    if "github.com/" in url:
        tail = url.split("github.com/", 1)[1]
    elif ":" in url and "@" in url:
        tail = url.split(":", 1)[1]
    else:
        return ""
    return tail.split("/", 1)[0] if "/" in tail else ""

def gh_env_for(repo_path: Path):
    """Return (env, label). Personal repos get the keyring PAT (pgh behavior)."""
    owner = repo_owner(repo_path)
    if owner and owner != SPORTABLE_OWNER:
        res = run(["secret-tool", "lookup", "service", "gh", "account", "personal"], check=False)
        token = (res.stdout or "").strip()
        if token:
            env = dict(os.environ)
            env["GH_TOKEN"] = token
            return env, "pgh"
    return dict(os.environ), "gh"

def gh_json(repo_path: Path, args):
    env, _ = gh_env_for(repo_path)
    res = run(["gh", *args], cwd=str(repo_path), env=env)
    return json.loads(res.stdout)

# ---- core ops --------------------------------------------------------------

PR_LIST_FIELDS = "number,title,headRefName,baseRefName,author,isDraft,updatedAt,url"
PR_VIEW_FIELDS = ("number,title,body,author,baseRefName,headRefName,additions,deletions,"
                  "changedFiles,url,isDraft,createdAt,updatedAt,commits,files,labels,"
                  "headRefOid")

def gh_checks(repo_path: Path, pr: int):
    """Best-effort CI status. Fine-grained PATs often can't read statusCheckRollup,
    so failure here is non-fatal — the brief just omits checks."""
    env, _ = gh_env_for(repo_path)
    res = run(["gh", "pr", "checks", str(pr), "--json", "name,state,bucket"],
              cwd=str(repo_path), env=env, check=False)
    if res.returncode != 0 or not (res.stdout or "").strip():
        return None
    try:
        return json.loads(res.stdout)
    except json.JSONDecodeError:
        return None

def resolve_repo(cfg, ident: str):
    """Match a repo by path or basename against config."""
    ident_p = _expand(ident)
    for r in cfg["repos"]:
        rp = _expand(r["path"])
        if rp == ident_p or rp.name == ident or str(rp) == ident:
            return r, rp
    # allow ad-hoc path not in config
    if ident_p.exists():
        return {"path": str(ident_p)}, ident_p
    die(f"repo not found in config or filesystem: {ident}")

def state_key(repo_path: Path, pr: int) -> str:
    return f"{repo_path.name}#{pr}"

def cmd_plan(cfg, args):
    state = load_json(STATE_PATH, {})
    manifest = []
    for r in cfg["repos"]:
        rp = _expand(r["path"])
        if not rp.exists():
            print(f"warn: repo path missing, skipping: {rp}", file=sys.stderr)
            continue
        prs = gh_json(rp, ["pr", "list", "--state", "open", "--limit", str(cfg["limit"]),
                           "--json", PR_LIST_FIELDS])
        for pr in prs:
            if pr.get("isDraft") and not cfg.get("include_drafts"):
                continue
            key = state_key(rp, pr["number"])
            prev = state.get(key, {})
            reviewed_at = prev.get("reviewed_head")
            # head sha not in list payload; treat updatedAt change as "needs look"
            needs = prev.get("last_updated") != pr["updatedAt"] or reviewed_at is None
            manifest.append({
                "repo": str(rp),
                "repo_name": rp.name,
                "pr": pr["number"],
                "title": pr["title"],
                "branch": pr["headRefName"],
                "base": pr["baseRefName"],
                # author is null for deleted (ghost) users; don't crash the whole plan
                "author": (pr.get("author") or {}).get("login", "unknown"),
                "url": pr["url"],
                "draft": pr.get("isDraft", False),
                "updated_at": pr["updatedAt"],
                "reviewed": reviewed_at is not None and prev.get("last_updated") == pr["updatedAt"],
                "needs_attention": needs,
            })
    out = {"session": cfg["tmux_session"], "prs": manifest,
           "pending": [m for m in manifest if m["needs_attention"]]}
    print(json.dumps(out, indent=2))

def tmux_session_exists(name: str) -> bool:
    return run(["tmux", "has-session", "-t", name], check=False).returncode == 0

def tmux_window_exists(session: str, window: str) -> bool:
    res = run(["tmux", "list-windows", "-t", session, "-F", "#{window_name}"], check=False)
    if res.returncode != 0:
        return False
    return window in (res.stdout or "").splitlines()

def ensure_worktree(repo_path: Path, wt_dir: str, pr: int, branch: str) -> Path:
    wt_root = repo_path / wt_dir
    wt = wt_root / f"pr-{pr}"
    if wt.exists():
        return wt
    env, _ = gh_env_for(repo_path)
    # Fetch the PR head into a stable local branch, then attach a worktree.
    local_branch = f"pr-review/{pr}"
    run(["git", "-C", str(repo_path), "fetch", "origin",
         f"pull/{pr}/head:{local_branch}", "--force"], env=env)
    # also fetch base so reviewers can diff offline
    run(["git", "-C", str(repo_path), "worktree", "add", "--force",
         str(wt), local_branch])
    # ensure .worktrees is gitignored
    gi = repo_path / ".gitignore"
    needle = wt_dir.rstrip("/") + "/"
    existing = gi.read_text() if gi.exists() else ""
    if needle not in existing and wt_dir not in existing.split():
        with gi.open("a") as f:
            f.write(f"\n{needle}\n")
    return wt

def scaffold_brief(repo_path: Path, wt: Path, pr_data: dict) -> Path:
    brief = wt / "PR-BRIEF.md"
    commits = pr_data.get("commits", []) or []
    files = pr_data.get("files", []) or []
    labels = [l["name"] for l in (pr_data.get("labels") or [])]
    checks = pr_data.get("_checks")
    if checks is None:
        check_lines = ["_checks unavailable (token lacks access)_"]
    else:
        check_lines = [f"- {c.get('bucket') or c.get('state','?')}: {c.get('name','?')}"
                       for c in checks] or ["_none reported_"]
    commit_lines = [f"- `{c.get('oid','')[:8]}` {c.get('messageHeadline','')}" for c in commits]
    file_lines = [f"- `{f.get('path','')}` (+{f.get('additions',0)}/-{f.get('deletions',0)})"
                  for f in files[:50]] if files else []
    body = (pr_data.get("body") or "").strip() or "_(no description)_"
    md = f"""# PR Brief — {repo_path.name} #{pr_data['number']}

**{pr_data['title']}**

| | |
|---|---|
| Author | @{(pr_data.get('author') or {}).get('login', 'unknown')} |
| Branch | `{pr_data['headRefName']}` → `{pr_data['baseRefName']}` |
| Changes | +{pr_data['additions']} / -{pr_data['deletions']} across {pr_data['changedFiles']} files |
| Labels | {', '.join(labels) or '—'} |
| Draft | {'yes' if pr_data.get('isDraft') else 'no'} |
| URL | {pr_data['url']} |
| Head | `{pr_data.get('headRefOid','')[:12]}` |

## CI / Checks
{chr(10).join(check_lines) or '_none reported_'}

## What this PR says it does
{body}

## Commits
{chr(10).join(commit_lines) or '_none_'}

## Files changed
{chr(10).join(file_lines) or '_(more than 50 or none)_'}

---

## ⚠️ Critical findings
<!-- AGENT: fill from ce-code-review. Lead with anything that should block merge
     or that the reviewer must look at first. If clean, say "nothing critical". -->
_pending review_

## Review summary
<!-- AGENT: 3-6 bullet plain-language summary of what changed and why it matters,
     plus the ce-code-review verdict. -->
_pending review_
"""
    brief.write_text(md)
    return brief

def cmd_prepare(cfg, args):
    r, rp = resolve_repo(cfg, args.repo)
    pr = int(args.pr)
    pr_data = gh_json(rp, ["pr", "view", str(pr), "--json", PR_VIEW_FIELDS])
    pr_data["_checks"] = gh_checks(rp, pr)
    branch = pr_data["headRefName"]
    wt = ensure_worktree(rp, cfg["worktree_dir"], pr, branch)
    brief = scaffold_brief(rp, wt, pr_data)

    session = cfg["tmux_session"]
    window = f"{rp.name}#{pr}"
    if not tmux_session_exists(session):
        # -n names the first window at creation (avoids base-index 0/1 ambiguity)
        run(["tmux", "new-session", "-d", "-s", session, "-n", window, "-c", str(wt)])
    elif not tmux_window_exists(session, window):
        run(["tmux", "new-window", "-t", session, "-n", window, "-c", str(wt)])
    # point the window at the brief (read-only pager); harmless if re-run
    target = f"{session}:{window}"
    run(["tmux", "send-keys", "-t", target,
         f"clear; echo '== {window} =='; sed -n '1,40p' PR-BRIEF.md", "Enter"], check=False)

    # record head sha so `complete` can confirm it reviewed the right commit
    state = load_json(STATE_PATH, {})
    key = state_key(rp, pr)
    entry = state.get(key, {})
    entry.update({"prepared_head": pr_data.get("headRefOid"),
                  "last_updated": pr_data.get("updatedAt"),
                  "worktree": str(wt), "window": window, "branch": branch})
    state[key] = entry
    save_json(STATE_PATH, state)

    print(json.dumps({
        "repo": str(rp), "pr": pr, "branch": branch,
        "worktree": str(wt), "brief": str(brief),
        "tmux_session": session, "tmux_window": window,
        "tmux_target": target, "head": pr_data.get("headRefOid"),
        "review_cmd": f"/ce-code-review mode:headless {pr_data['url']}",
    }, indent=2))

def cmd_complete(cfg, args):
    r, rp = resolve_repo(cfg, args.repo)
    pr = int(args.pr)
    pr_data = gh_json(rp, ["pr", "view", str(pr), "--json", "headRefOid,updatedAt"])
    state = load_json(STATE_PATH, {})
    key = state_key(rp, pr)
    entry = state.get(key, {})
    entry.update({"reviewed_head": pr_data["headRefOid"],
                  "last_updated": pr_data["updatedAt"]})
    state[key] = entry
    save_json(STATE_PATH, state)
    print(json.dumps({"marked": key, "reviewed_head": pr_data["headRefOid"]}, indent=2))

def cmd_status(cfg, args):
    print(f"config: {CONFIG_PATH}")
    print(f"state:  {STATE_PATH}")
    print(f"session: {cfg['tmux_session']} (exists: {tmux_session_exists(cfg['tmux_session'])})")
    for r in cfg["repos"]:
        rp = _expand(r["path"])
        _, label = gh_env_for(rp) if rp.exists() else ({}, "?")
        print(f"  - {rp}  [{label}]  {'ok' if rp.exists() else 'MISSING'}")
    if tmux_session_exists(cfg["tmux_session"]):
        res = run(["tmux", "list-windows", "-t", cfg["tmux_session"],
                   "-F", "    #{window_index}: #{window_name}"], check=False)
        print(res.stdout.rstrip())

def main():
    p = argparse.ArgumentParser(description="pr-review-session driver")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("plan")
    pp = sub.add_parser("prepare"); pp.add_argument("repo"); pp.add_argument("pr")
    pc = sub.add_parser("complete"); pc.add_argument("repo"); pc.add_argument("pr")
    sub.add_parser("status")
    args = p.parse_args()
    cfg = load_config()
    {"plan": cmd_plan, "prepare": cmd_prepare,
     "complete": cmd_complete, "status": cmd_status}[args.cmd](cfg, args)

if __name__ == "__main__":
    main()
