#!/usr/bin/env bash
set -uo pipefail

range="$1"
employer='ronsin|ronsyn|wincopy|tristar|nas-prod|192\.168\.31'
attribution='Co-Authored-By:[[:space:]]*Claude|Generated with|claude\.ai/code'
coauthored='^(apps|clients)/|^gallery/[^/]*-(android|ios)/'
fail=0

bad() { echo "::error::$1"; fail=1; }

changed=$(git diff "$range" -U0 --no-color -- . ':!.github/scripts/rules.sh' | grep -E '^\+' | grep -vE '^\+\+\+' || true)
grep -Eiq "$employer" <<<"$changed" && bad "employer name in changed lines"
git log "$range" --format=%B | grep -Eiq "$employer" && bad "employer name in a commit message"
printf '%s\n%s\n' "${PR_TITLE:-}" "${PR_BODY:-}" | grep -Eiq "$employer" && bad "employer name in the PR title or body"

printf '%s\n%s\n' "${PR_TITLE:-}" "${PR_BODY:-}" | grep -Eiq "$attribution" && bad "AI attribution in the PR title or body"
for sha in $(git rev-list --no-merges "$range"); do
  msg=$(git log -1 --format=%B "$sha")
  files=$(git show --name-only --format= "$sha")
  if [ -n "$files" ] && ! grep -qvE "$coauthored|^docs/" <<<"$files" && grep -qE "$coauthored" <<<"$files"; then
    msg=$(grep -vxE 'Co-Authored-By: Claude [^<]*<noreply@anthropic\.com>' <<<"$msg" || true)
  fi
  grep -Eiq "$attribution" <<<"$msg" && bad "AI attribution in commit $sha"
done

if grep -nE 'generate_release_notes:[[:space:]]*true' .github/workflows/*; then bad "generate_release_notes true in a workflow"; fi
if grep -nE "(^|[[:space:]\"'(])@[A-Za-z0-9_-]+" .github/workflows/*; then bad "@mention in a workflow"; fi

exit $fail
