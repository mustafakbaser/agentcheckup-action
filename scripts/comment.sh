#!/usr/bin/env bash
# Creates or updates one pull request comment with the Markdown report. The comment is found by
# a hidden marker at the start of its body. Runs only for pull requests from the same
# repository; anything else, including a token that cannot write, ends with a notice and exit 0.
#
# AC_COMMENT_MODE true: create or update the comment on every run. on-change: create it only
# when the JSON report shows something to review (gate hits, new findings, failing policy
# violations, or files the change makes an agent skip); otherwise only update an existing one.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "${BASH_SOURCE[0]%/*}/lib.sh"

require_env AC_WORK GITHUB_REPOSITORY GITHUB_SERVER_URL
cd -- "$AC_WORK"

readonly marker='<!-- agentcheckup-action -->'
report="$AC_WORK/head.md"
json="$AC_WORK/head.json"
mode=${AC_COMMENT_MODE:-true}

case $mode in
  true | on-change) ;;
  *) fail "Invalid comment mode." ;;
esac
if [ -z "${AC_PR_NUMBER:-}" ]; then
  notice "comment: $mode only applies to pull_request events. No comment written."
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
use_gh

# Whether the report shows anything a reviewer must look at. A report that cannot be read
# counts as yes. New skips are the ones the change adds to a load plan, except files the agent
# does not read at all (code not-read), as in the report's "What this change makes each agent
# miss" table.
needs_review=true
if [ "$mode" = on-change ]; then
  needs_review=$(jq -r '
    ((.baseline.gate.hits // []) | length) as $gate
    | (if .baseline then (.baseline.findings.new // 0)
       else ((.summary.errors // 0) + (.summary.warnings // 0) + (.summary.infos // 0)) end) as $new
    | ([.policy.violations[]? | select(.fails == true)] | length) as $policy
    | [.context.plans[]?] as $plans
    | ([.baseline.context[]? as $delta | $delta.skipped.added[]? as $id
        | [$plans[] | select(.agent == $delta.agent and .cwd == $delta.cwd)
            | .skipped[]? | select(.id == $id)] as $skips
        | select(($skips | length) == 0 or any($skips[]; .code != "not-read"))] | length) as $missed
    | if $gate + $new + $policy + $missed > 0 then "true" else "false" end' "$json" 2>/dev/null) ||
    needs_review=true
  if [ "$needs_review" != false ]; then needs_review=true; fi
fi

repo=$GITHUB_REPOSITORY
body="$AC_WORK/comment.md"
payload="$AC_WORK/comment.json"
run_url="$GITHUB_SERVER_URL/$repo/actions/runs/${GITHUB_RUN_ID:-}"

# A comment may hold 65,536 characters; bytes are a safe upper bound for characters.
printf '%s\n\n' "$marker" >"$body"
append_capped "$report" 60000 "$body"
printf '\n\n_[Workflow run](%s)_\n' "$run_url" >>"$body"
jq -n --rawfile body "$body" '{ body: $body }' >"$payload"

login=$(token_login)

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
elif [ "$needs_review" != true ]; then
  if [ -n "$id" ]; then
    notice "Could not update the pull request comment. The job needs permissions: pull-requests: write."
  else
    echo "comment: on-change, and nothing in this report needs review: no comment created."
  fi
elif gh api --method POST "repos/$repo/issues/$AC_PR_NUMBER/comments" --input "$payload" --silent; then
  echo "Created the pull request comment."
else
  notice "Could not write the pull request comment. The job needs permissions: pull-requests: write."
fi
