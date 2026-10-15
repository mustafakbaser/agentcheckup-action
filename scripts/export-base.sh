#!/usr/bin/env bash
# Exports the tree of the base commit into the work directory without running anything from it.
#
# - A new bare repository in the work directory fetches only the base commit (depth 1, no tags,
#   no submodules), so the result does not depend on how the workspace was checked out, and git
#   never runs inside the scanned checkout.
# - The token goes to git as a one-shot http.extraheader through GIT_CONFIG_* environment
#   variables of that one git process: not in any config file, not on a command line, and
#   masked in the log.
# - `git archive | tar -x` writes plain files. $GIT_DIR/info/attributes turns off export-ignore
#   and export-subst, so the base tree's .gitattributes cannot hide or rewrite files.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "${BASH_SOURCE[0]%/*}/lib.sh"

require_env AC_WORK AC_BASE_SHA AC_BASE_ROOT GITHUB_SERVER_URL GITHUB_REPOSITORY GITHUB_OUTPUT
require_tool git tar base64
cd -- "$AC_WORK"

# Read the token into a shell variable and drop it from the environment, so no child process
# other than the one git fetch below sees it.
token=${AC_TOKEN-}
unset AC_TOKEN

if [ -n "$token" ]; then
  if ! [[ $token =~ ^[A-Za-z0-9_.~+/=-]+$ ]]; then
    fail "Input token contains characters a GitHub token does not have."
  fi
  basic=$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\r\n')
  # The runner consumes ::add-mask:: lines and does not print them.
  printf '::add-mask::%s\n' "$token"
  printf '::add-mask::%s\n' "$basic"
fi

server=${GITHUB_SERVER_URL%/}
if [[ $server =~ [[:space:][:cntrl:]] ]]; then fail "GITHUB_SERVER_URL is not a URL."; fi
if ! [[ $GITHUB_REPOSITORY =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  fail "GITHUB_REPOSITORY is not owner/name."
fi
url="$server/$GITHUB_REPOSITORY.git"
sha=$AC_BASE_SHA
if ! [[ $sha =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then fail "Invalid base commit SHA."; fi

bare="$AC_WORK/base.git"
object_format=sha1
if [ "${#sha}" -eq 64 ]; then object_format=sha256; fi
git init --quiet --bare --object-format="$object_format" -- "$bare"
printf '* -export-ignore -export-subst\n' >"$bare/info/attributes"

printf 'Fetching base commit %s from %s\n' "$sha" "$url"
fetched=0
if [ -n "$token" ]; then
  GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=2 \
    GIT_CONFIG_KEY_0="http.$server/.extraheader" \
    GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $basic" \
    GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1='' \
    git --git-dir="$bare" fetch --quiet --no-tags --no-recurse-submodules --depth=1 \
    -- "$url" "$sha" && fetched=1
else
  GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0='' \
    git --git-dir="$bare" fetch --quiet --no-tags --no-recurse-submodules --depth=1 \
    -- "$url" "$sha" && fetched=1
fi
unset token basic
if [ "$fetched" -ne 1 ]; then
  fail "Could not fetch the base commit $sha. The job needs permissions: contents: read."
fi

mkdir -- "$AC_BASE_ROOT"
if ! git --git-dir="$bare" archive --format=tar "$sha" | tar -x -f - -C "$AC_BASE_ROOT"; then
  fail "Could not export the tree of the base commit $sha."
fi
rm -rf -- "$bare"
printf 'Exported the base tree to %s\n' "$AC_BASE_ROOT"
