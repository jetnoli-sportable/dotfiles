#!/usr/bin/env bash
# Coverage test for the terraform/tofu/terragrunt permissions.deny rules in
# claude/.claude/settings.recommended.json. Needs jq.
#
# Run: bash scripts/.config/scripts/tmux/tests/settings-deny-rules.test.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
REL=claude/.claude/settings.recommended.json
SETTINGS="$REPO/$REL"

fail=0
ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1"
  fail=1
}

if jq empty "$SETTINGS" 2>/dev/null; then ok "settings file is valid JSON"; else
  bad "settings file is not valid JSON"
  exit 1
fi

mapfile -t DENY < <(jq -r '.permissions.deny[]?' "$SETTINGS")
has() {
  local r
  for r in "${DENY[@]}"; do [ "$r" = "$1" ] && return 0; done
  return 1
}
want() { # <rule>
  if has "$1"; then ok "deny has $1"; else bad "deny is missing $1"; fi
}

SUBS=("apply" "destroy" "import" "taint" "untaint" "force-unlock" "refresh"
  "state rm" "state mv" "state push" "state replace-provider" "workspace delete")

for tool in terraform tofu terragrunt; do
  for sub in "${SUBS[@]}"; do
    want "Bash($tool $sub *)"
    want "Bash(env * $tool $sub*)"
    case "$tool" in terraform | tofu) want "Bash($tool -chdir=* $sub*)" ;; esac
  done
done
for sub in "${SUBS[@]}"; do
  want "Bash(terragrunt run-all $sub*)"
  want "Bash(terragrunt run $sub*)"
  want "Bash(terragrunt run --all $sub*)"
done
for r in 'apply-all' 'destroy-all' 'apply --all' 'destroy --all'; do
  want "Bash(terragrunt $r*)"
done

# A rule matches a command when the glob (`*` wildcard) matches it; a trailing
# " *" also matches the bare command, as in the Claude Code permissions docs.
rule_matches() { # <pattern> <command>
  local pat="$1" cmd="$2"
  # shellcheck disable=SC2053
  [[ $cmd == $pat ]] && return 0
  if [[ $pat == *' *' ]]; then
    # shellcheck disable=SC2053
    [[ $cmd == ${pat% \*} ]] && return 0
  fi
  return 1
}

READONLY=("terraform plan" "terraform init" "terraform validate" "terraform fmt"
  "terraform show" "terraform output" "terraform state list" "terraform state show"
  "terraform state pull" "terragrunt plan" "tofu plan" "terraform -chdir=infra plan")
for cmd in "${READONLY[@]}"; do
  hit=""
  for r in "${DENY[@]}"; do
    [[ $r == Bash\(*\) ]] || continue
    pat="${r#Bash(}"
    pat="${pat%)}"
    if rule_matches "$pat" "$cmd"; then
      hit="$r"
      break
    fi
  done
  if [ -z "$hit" ]; then ok "no deny rule matches: $cmd"; else bad "deny rule $hit matches read-only: $cmd"; fi
done

# Sanity that the matcher itself works, so the loop above cannot pass vacuously.
if rule_matches 'terraform apply *' 'terraform apply' && rule_matches 'env * terraform apply*' 'env TF_LOG=1 terraform apply -auto-approve'; then
  ok "matcher self-check"
else bad "matcher self-check"; fi

# The rules this file carried before the deny list must survive edits to it.
if jq -e '.permissions.allow | index("Read(/home/jetnoli/code/tasks/**)")' "$SETTINGS" >/dev/null; then
  ok "allow keeps the task-store Read rule"
else bad "allow lost the task-store Read rule"; fi
for pair in 'Bash|tasks-git-hooks/pretooluse-guard.sh' 'Bash|risky-command-guard.sh' \
  'Edit|Write|MultiEdit|tasks-git-hooks/pretooluse-guard.sh'; do
  matcher="${pair%|*}" script="${pair##*|}"
  if jq -e --arg m "$matcher" --arg s "$script" \
    '[.hooks.PreToolUse[]? | select(.matcher == $m) | .hooks[].command | endswith($s)] | any' \
    "$SETTINGS" >/dev/null; then
    ok "PreToolUse $matcher still runs $script"
  else bad "PreToolUse $matcher no longer runs $script"; fi
done

exit "$fail"
