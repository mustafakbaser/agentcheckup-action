#!/usr/bin/env bash
# Exports a tree from a repository on this GitHub server into the work directory without running
# anything from it: the whole tree of a commit (the base or head commit of a pull request), or
# one file in it (the policy).
#
# Environment:
# - AC_TREE_KIND: base, head, policy (from this repository) or policy-central. Picks the messages.
# - AC_TREE_REPOSITORY: owner/name. Default: this repository.
# - AC_TREE_REF: a full commit SHA, a branch or tag name, or HEAD for the default branch.
# - AC_TREE_PATH: optional. Export only this file or directory.
# - AC_TREE_DEST: the directory to create and export into.
# - AC_TOKEN: optional. The token for this one fetch.
# Output: sha, the commit that was exported.
#
# - A new bare repository in the work directory fetches only that commit (depth 1, no tags, no
#   submodules), so the result does not depend on how the workspace was checked out, and git
#   never runs inside the scanned checkout.
# - The token goes to git as a one-shot http.extraheader through GIT_CONFIG_* environment
#   variables of that one git process: not in any config file, not on a command line, and
#   masked in the log.
# - `git archive <sha> [-- <path>] | tar -x` writes plain files. Pathspecs are literal, so a path
#   is never a glob or pathspec magic. With a path, `git ls-tree` first checks that the commit
#   has it. $GIT_DIR/info/attributes turns off export-ignore and export-subst, so the tree's
#   .gitattributes cannot hide or rewrite files.
# - For head (suggestions), every problem is a notice and the step succeeds without the sha
#   output: suggestions never fail the check.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "${BASH_SOURCE[0]%/*}/lib.sh"

kind=${AC_TREE_KIND-}
case $kind in
  head) never_fail ;;
  base | policy | policy-central) ;;
  *) fail "Internal error: unknown tree kind \"$(clip "$kind")\"." ;;
esac

require_env AC_WORK AC_TREE_REF AC_TREE_DEST GITHUB_SERVER_URL GITHUB_REPOSITORY GITHUB_OUTPUT
require_tool git tar base64
cd -- "$AC_WORK"

# Read the token into a shell variable and drop it from the environment, so no child process
# other than the one git fetch below sees it.
token=${AC_TOKEN-}
unset AC_TOKEN
with_token=false

if [ -n "$token" ]; then
  with_token=true
  if ! [[ $token =~ ^[A-Za-z0-9_.~+/=-]+$ ]]; then
    input=token
    if [ "$kind" = policy-central ]; then input=policy-token; fi
    fail "Input $input contains characters a GitHub token does not have."
  fi
  basic=$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\r\n')
  # The runner consumes ::add-mask:: lines and does not print them.
  printf '::add-mask::%s\n' "$token"
  printf '::add-mask::%s\n' "$basic"
fi

server=${GITHUB_SERVER_URL%/}
if [[ $server =~ [[:space:][:cntrl:]] ]]; then fail "GITHUB_SERVER_URL is not a URL."; fi
repo=${AC_TREE_REPOSITORY:-$GITHUB_REPOSITORY}
if ! [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  fail "The repository \"$(clip "$repo")\" is not owner/name."
fi
url="$server/$repo.git"

ref=$AC_TREE_REF
is_git_ref "$ref" || fail "Invalid commit or ref \"$(clip "$ref")\"."
path=
if [ -n "${AC_TREE_PATH-}" ]; then
  path=$(normalize_file_path "$AC_TREE_PATH") || fail "Invalid path \"$(clip "$AC_TREE_PATH")\"."
fi

# What was asked for, for messages.
if is_sha "$ref"; then
  case $kind in
    base | policy) where="the base commit $ref" ;;
    head) where="the head commit $ref" ;;
    *) where="commit $ref" ;;
  esac
elif [ "$ref" = HEAD ]; then
  where="the default branch"
else
  where="ref $ref"
fi
if [ "$kind" = policy-central ]; then where="$where of $repo"; fi

fetch_failed() {
  case $kind in
    base) fail "Could not fetch the base commit $ref. The job needs permissions: contents: read." ;;
    head) fail "Could not fetch the head commit $ref, so there are no suggestions." ;;
    policy) fail "Could not fetch $where to read the policy. The job needs permissions: contents: read." ;;
  esac
  if [ "${GITHUB_EVENT_NAME:-}" = pull_request ] && [ "${AC_SAME_REPO:-}" != true ]; then
    fail "Could not fetch $where. Pull requests from forks get no secrets. Make the policy repository public, or use input \`policy\`."
  fi
  if [ "$with_token" = true ]; then
    fail "Could not fetch $where with input policy-token. Check policy-repository and policy-ref, and that the token can read the repository."
  fi
  fail "Could not fetch $where. If the repository is private, set input policy-token to a token that can read it."
}

path_missing() {
  local at=$where
  if ! is_sha "$ref"; then at="$where ($sha)"; fi
  case $kind in
    policy)
      fail "The policy file $path is not in $at. The action reads the policy from the trusted tree, never from the pull request, so a pull request cannot add or change the policy it is checked against. Merge the policy file first, then the workflow that uses it."
      ;;
    *) fail "The file $path is not in $at." ;;
  esac
}

bare="$AC_WORK/$kind.git"
object_format=sha1
if [ "${#ref}" -eq 64 ] && is_sha "$ref"; then object_format=sha256; fi
git init --quiet --bare --object-format="$object_format" -- "$bare"
printf '* -export-ignore -export-subst\n' >"$bare/info/attributes"

printf 'Fetching %s from %s\n' "$where" "$url"
fetched=0
if [ "$with_token" = true ]; then
  GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=2 \
    GIT_CONFIG_KEY_0="http.$server/.extraheader" \
    GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $basic" \
    GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1='' \
    git --git-dir="$bare" fetch --quiet --no-tags --no-recurse-submodules --depth=1 \
    -- "$url" "$ref" && fetched=1
else
  GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0='' \
    git --git-dir="$bare" fetch --quiet --no-tags --no-recurse-submodules --depth=1 \
    -- "$url" "$ref" && fetched=1
fi
unset token basic
if [ "$fetched" -ne 1 ]; then fetch_failed; fi

sha=$(git --git-dir="$bare" rev-parse --verify --quiet 'FETCH_HEAD^{commit}') || sha=
if ! is_sha "$sha"; then fail "Could not resolve $where to a commit."; fi
if is_sha "$ref" && [ "$sha" != "$ref" ]; then
  fail "Fetching $where returned commit $sha instead."
fi

archive=(git --literal-pathspecs --git-dir="$bare" archive --format=tar "$sha")
if [ -n "$path" ]; then
  found=false
  while IFS= read -r -d '' entry; do
    if [ "${entry#*$'\t'}" = "$path" ]; then found=true; fi
  done < <(git --literal-pathspecs --git-dir="$bare" ls-tree -z "$sha" -- "$path" 2>/dev/null || true)
  if [ "$found" != true ]; then path_missing; fi
  archive+=(-- "$path")
fi

mkdir -- "$AC_TREE_DEST"
if ! "${archive[@]}" | tar -x -f - -C "$AC_TREE_DEST"; then
  fail "Could not export $where."
fi
rm -rf -- "$bare"
if [ -n "$path" ]; then
  printf 'Exported %s from %s at %s to %s\n' "$path" "$repo" "$sha" "$AC_TREE_DEST"
else
  printf 'Exported the tree of %s at %s to %s\n' "$repo" "$sha" "$AC_TREE_DEST"
fi
set_output sha "$sha"
