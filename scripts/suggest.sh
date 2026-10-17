#!/usr/bin/env bash
# Posts the safe fixes agentcheckup finds in a pull request as one review with suggested
# changes. Opt-in (suggest: true), same-repository pull requests only: prepare.sh decides.
#
# 1. export-tree.sh exported the head commit, pull_request.head.sha, to AC_HEAD_ROOT. The
#    workspace is usually the merge commit, whose line numbers can differ from the head's.
# 2. The diff comes from the API (Accept: application/vnd.github.diff), into a file.
# 3. `agentcheckup fix --untrusted --format suggestions --diff <file>` runs on the head tree and
#    writes review comments, each ending with the marker line
#    `<!-- agentcheckup-suggestion <rule ids> <hash> -->`.
# 4. Markers are compared on the last line of each body only: suggested lines are repository
#    text and can hold marker-like text. A comment whose marker is already on a review comment
#    by this token's login is not posted again. Such comments whose marker this run does not
#    produce any more are deleted.
# 5. One review with event COMMENT and commit_id the head SHA.
#
# Never fails the check: every problem is a notice, and the step ends with exit status 0.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "${BASH_SOURCE[0]%/*}/lib.sh"
never_fail

require_env AC_WORK AC_CLI AC_PATH AC_PR_NUMBER AC_HEAD_SHA AC_HEAD_ROOT GITHUB_REPOSITORY \
  GITHUB_SERVER_URL
cd -- "$AC_WORK"

if ! [[ $AC_PR_NUMBER =~ ^[1-9][0-9]*$ ]]; then fail "Invalid pull request number. No suggestions."; fi
if ! is_sha "$AC_HEAD_SHA"; then fail "Invalid head commit SHA. No suggestions."; fi
if [ "${AC_HEAD_EXPORTED:-}" != "$AC_HEAD_SHA" ]; then
  fail "The head commit was not exported. No suggestions."
fi
head_root=$(real_dir "$AC_HEAD_ROOT") || fail "The head tree is missing. No suggestions."
if [ -z "${GH_TOKEN:-}" ]; then fail "Input token is empty. No suggestions."; fi
require_tool gh jq node
use_gh

repo=$GITHUB_REPOSITORY
pr=$AC_PR_NUMBER
diff="$AC_WORK/pull-request.diff"
suggestions="$AC_WORK/suggestions.json"
existing="$AC_WORK/review-comments.json"
plan="$AC_WORK/suggestions-plan.json"
review="$AC_WORK/review.json"
errors="$AC_WORK/gh-errors.txt"

# --- Diff ----------------------------------------------------------------------------------------

# agentcheckup reads at most 16 MiB of diff.
readonly max_diff_bytes=16777216
if ! gh api -H 'Accept: application/vnd.github.diff' "repos/$repo/pulls/$pr" >"$diff" 2>"$errors"; then
  if grep -qiE 'HTTP 406|too large|too_large|exceeded the maximum' "$errors"; then
    fail "The pull request diff is too large for the GitHub API. No suggestions."
  fi
  fail "Could not fetch the pull request diff. The job needs permissions: pull-requests: write. No suggestions."
fi
size=$(wc -c <"$diff" | tr -d ' ')
if [ "$size" -gt "$max_diff_bytes" ]; then
  fail "The pull request diff has $size bytes, more than agentcheckup reads (16 MiB). No suggestions."
fi

# --- Suggestions ---------------------------------------------------------------------------------

args=(fix --untrusted --format=suggestions "--diff=$diff" "--output=$suggestions")
if [ -n "${AC_TARGETS:-}" ]; then args+=("--targets=$AC_TARGETS"); fi
echo "Looking for safe fixes in the head commit $AC_HEAD_SHA."
stop=$(random_token)
printf '::stop-commands::%s\n' "$stop"
status=0
# The token stays with gh: the CLI runs without it.
(unset GH_TOKEN GH_ENTERPRISE_TOKEN && cd -P -- "$head_root" && exec node "$AC_CLI" "${args[@]}" -- .) ||
  status=$?
printf '::%s::\n' "$stop"
if [ "$status" -ne 0 ]; then
  fail "agentcheckup could not make suggestions (exit code $status). See the log. No suggestions."
fi
if ! jq -e '.schemaVersion == 1 and (.comments | type == "array")' "$suggestions" >/dev/null 2>&1; then
  fail "agentcheckup wrote no readable suggestions. No suggestions."
fi
jq -r '.skipped[]? | select((.reason | type) == "string" and (.reason | test("^[a-z-]+$"))
  and (.count | type) == "number") | "Not suggested (\(.reason)): \(.count)"' "$suggestions"

# --- Existing review comments --------------------------------------------------------------------

login=$(token_login)
if ! gh api --paginate "repos/$repo/pulls/$pr/comments?per_page=100" >"$existing" 2>"$errors"; then
  fail "Could not read the review comments. The job needs permissions: pull-requests: write. No suggestions."
fi

# Which comments to post and which to delete. The marker is the last line of a body, after
# trailing empty lines and carriage returns are dropped; a body whose last line is not a
# marker has none. Only comments in the scanned path count, on both sides.
jq -n --slurpfile produced "$suggestions" --slurpfile pages "$existing" \
  --arg login "$login" --arg path "$AC_PATH" '
  def last_line:
    (if type == "string" then . else "" end)
    | split("\n") | map(rtrimstr("\r"))
    | until(length == 0 or (.[-1] | length) > 0; .[:-1])
    | .[-1] // "";
  def marker:
    last_line
    | if test("^<!-- agentcheckup-suggestion [a-z0-9/,-]+ [0-9a-f]{12} -->$") then . else null end;
  def in_scope:
    (.path | type) == "string" and ($path == "." or (.path | startswith($path + "/")));
  def valid:
    in_scope and (.line | type) == "number" and .line >= 1 and .side == "RIGHT"
    and (.body | type) == "string" and (.body | marker) != null
    and (if has("start_line")
      then (.start_line | type) == "number" and .start_line >= 1 and .start_line < .line
        and .start_side == "RIGHT"
      else (has("start_side") | not) end);
  ([$pages[] | if type == "array" then .[] else empty end
    | select(type == "object" and (.user.login? == $login) and in_scope
      and (.id | type) == "number")
    | {id, marker: (.body | marker)} | select(.marker != null)]) as $mine
  | ([$produced[0].comments[] | select(type == "object")]) as $all
  | ([$all[] | select(valid)] | .[:50]) as $wanted
  | ($mine | map(.marker)) as $posted
  | ($wanted | map(.body | marker)) as $markers
  | {
      post: [$wanted[] | (.body | marker) as $m | select(any($posted[]; . == $m) | not)
        | {path, line, side, body}
          + (if has("start_line") then {start_line, start_side} else {} end)],
      already: [$wanted[] | (.body | marker) as $m | select(any($posted[]; . == $m))] | length,
      ignored: (($all | length) - ($wanted | length)),
      delete: [$mine[] | .marker as $m | select(any($markers[]; . == $m) | not) | .id]
    }' >"$plan" || fail "Could not read the suggestions or the review comments. No suggestions."

# --- Stale comments ------------------------------------------------------------------------------

deleted=0
while IFS= read -r id; do
  [[ $id =~ ^[0-9]+$ ]] || continue
  if gh api --method DELETE "repos/$repo/pulls/comments/$id" --silent 2>"$errors"; then
    deleted=$((deleted + 1))
  else
    notice "Could not delete the outdated suggestion $id."
  fi
done < <(jq -r '.delete[]' "$plan")

# --- Review --------------------------------------------------------------------------------------

count=$(jq '.post | length' "$plan")
already=$(jq '.already' "$plan")
ignored=$(jq '.ignored' "$plan")
posted=0
if [ "$count" -gt 0 ]; then
  noun=fixes
  if [ "$count" -eq 1 ]; then noun=fix; fi
  jq --arg sha "$AC_HEAD_SHA" \
    --arg body "**agentcheckup** suggests $count safe $noun for the agent configuration in this pull request. Review each suggestion before you apply it." \
    '{commit_id: $sha, event: "COMMENT", body: $body, comments: .post}' "$plan" >"$review"
  if gh api --method POST "repos/$repo/pulls/$pr/reviews" --input "$review" --silent 2>"$errors"; then
    posted=$count
  elif grep -qF 'HTTP 422' "$errors"; then
    notice "GitHub did not accept the suggestions (HTTP 422), for example because the pull request changed during this run. No suggestions posted."
  else
    notice "Could not post the suggestions. The job needs permissions: pull-requests: write."
  fi
fi

line="Suggestions: $posted posted, $already already on the pull request, $deleted outdated removed."
if [ "$ignored" -gt 0 ]; then line="$line $ignored outside the scanned path or unusable."; fi
echo "$line"
summary ""
summary "_${line}_"
