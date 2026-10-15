#!/usr/bin/env bash
# Creates or updates one pull request comment with the Markdown report. The comment is found by
# a hidden marker at the start of its body. Runs only for pull requests from the same
# repository; anything else, including a token that cannot write, ends with a notice and exit 0.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "${BASH_SOURCE[0]%/*}/lib.sh"

require_env AC_WORK GITHUB_REPOSITORY GITHUB_SERVER_URL
cd -- "$AC_WORK"

readonly marker='<!-- agentcheckup-action -->'
report="$AC_WORK/head.md"

if [ -z "${AC_PR_NUMBER:-}" ]; then
  notice "comment: true only applies to pull_request events. No comment written."
  exit 0
fi
if ! [[ $AC_PR_NUMBER =~ ^[1-9][0-9]*$ ]]; then fail "Invalid pull request number."; fi
if [ "${AC_SAME_REPO:-}" != true ]; then
  notice "This pull request comes from a fork, and its token cannot write comments. The report is in the job summary."
  exit 0
fi
if [ ! -s "$report" ]; then
  notice "There is no Markdown report, so no comment was written. See the log."
  exit 0
fi
if [ -z "${GH_TOKEN:-}" ]; then
  notice "Input token is empty, so no comment was written."
  exit 0
fi
require_tool gh jq

# gh reads the host and the token from the environment.
host=${GITHUB_SERVER_URL#*://}
host=${host%%/*}
export GH_HOST=$host GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1
if [ "$host" != github.com ]; then export GH_ENTERPRISE_TOKEN=$GH_TOKEN; fi

repo=$GITHUB_REPOSITORY
body="$AC_WORK/comment.md"
payload="$AC_WORK/comment.json"
run_url="$GITHUB_SERVER_URL/$repo/actions/runs/${GITHUB_RUN_ID:-}"

# A comment may hold 65,536 characters; bytes are a safe upper bound for characters.
printf '%s\n\n' "$marker" >"$body"
append_capped "$report" 60000 "$body"
printf '\n\n_[Workflow run](%s)_\n' "$run_url" >>"$body"
jq -n --rawfile body "$body" '{ body: $body }' >"$payload"

# The token's own login: a user token can read /user, the workflow token cannot.
login=$(gh api user --jq .login 2>/dev/null) || login='github-actions[bot]'

if ! comments=$(gh api --paginate "repos/$repo/issues/$AC_PR_NUMBER/comments?per_page=100"); then
  notice "Could not read the pull request comments. The job needs permissions: pull-requests: write."
  exit 0
fi
id=$(printf '%s' "$comments" | jq -rs --arg login "$login" --arg marker "$marker" '
  [ .[][] | select(.user.login == $login and (.body // "" | startswith($marker))) | .id ]
  | first // empty')

if [ -n "$id" ] && [[ $id =~ ^[0-9]+$ ]] &&
  gh api --method PATCH "repos/$repo/issues/comments/$id" --input "$payload" --silent; then
  echo "Updated the pull request comment."
elif gh api --method POST "repos/$repo/issues/$AC_PR_NUMBER/comments" --input "$payload" --silent; then
  echo "Created the pull request comment."
else
  notice "Could not write the pull request comment. The job needs permissions: pull-requests: write."
fi
