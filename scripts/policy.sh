#!/usr/bin/env bash
# Checks the policy file that export-tree.sh took from the trusted tree or the central
# repository, copies it into the work directory for scan.sh, and writes to the job summary which
# commit it came from and its SHA-256.
#
# The policy is never read from the workspace. On pull requests the workspace copy is only
# compared byte for byte with the trusted one, to say when the pull request changes the policy.
# The workflow file that runs this check is compared with the base commit the same way.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "${BASH_SOURCE[0]%/*}/lib.sh"

require_env AC_WORK AC_POLICY_SOURCE AC_POLICY_ROOT AC_POLICY_PATH GITHUB_WORKSPACE \
  GITHUB_REPOSITORY GITHUB_EVENT_NAME GITHUB_OUTPUT
cd -- "$AC_WORK"

# agentcheckup reads at most this much of a policy file. Refuse more here, with the action's
# own message.
readonly max_bytes=262144

path=$(normalize_file_path "$AC_POLICY_PATH") || fail "Invalid policy path."
root=$(real_dir "$AC_POLICY_ROOT") || fail "The policy tree is missing."
sha=${AC_POLICY_SHA-}
repo=${AC_POLICY_REPOSITORY:-$GITHUB_REPOSITORY}
ref=${AC_POLICY_REF-}

case $AC_POLICY_SOURCE in
  tree)
    if is_sha "$ref"; then from="the base commit"; else from="the default branch"; fi
    ;;
  central)
    if [ "$ref" = HEAD ]; then
      from="the default branch"
    elif is_sha "$ref"; then
      from="a pinned commit"
    else
      from="ref $ref"
    fi
    ;;
  dir) from="test-base-dir" ;;
  *) fail "Internal error: unknown policy source." ;;
esac
if [ "$AC_POLICY_SOURCE" != dir ] && ! is_sha "$sha"; then
  fail "Internal error: the policy export recorded no commit."
fi

missing_message="The policy file $path is not in $from. The action reads the policy from the trusted tree, never from the pull request, so a pull request cannot add or change the policy it is checked against. Merge the policy file first, then the workflow that uses it."

# The file, and every directory on the way to it, must be inside the exported tree.
file="$root/$path"
if [ "${path%/*}" != "$path" ]; then
  parent=$(real_dir "$root/${path%/*}") || fail "$missing_message"
  is_inside "$parent" "$root" ||
    fail "Refusing to read the policy file $path: a directory on its path is a symbolic link out of the tree."
  file="$parent/${path##*/}"
fi
if [ -L "$file" ]; then
  fail "Refusing to read the policy file $path: it is a symbolic link, not a regular file."
fi
if [ ! -e "$file" ]; then fail "$missing_message"; fi
if [ ! -f "$file" ]; then fail "Refusing to read the policy file $path: it is not a regular file."; fi
size=$(wc -c <"$file" | tr -d ' ')
if [ "$size" -gt "$max_bytes" ]; then
  fail "Refusing to read the policy file $path: it has $size bytes, and the limit is 256 KiB ($max_bytes bytes)."
fi

# scan.sh passes this copy to agentcheckup: a file in the work directory, outside the checkout.
mkdir -- "$AC_WORK/policy"
copy="$AC_WORK/policy/${path##*/}"
cp -- "$file" "$copy"
digest=$(file_sha256 "$copy") || fail "Could not compute the SHA-256 of the policy file."

if [ "$AC_POLICY_SOURCE" = dir ]; then
  line="**Policy:** \`$path\` from test-base-dir (test only). SHA-256 \`$digest\`."
  printf 'Policy %s from test-base-dir, SHA-256 %s.\n' "$path" "$digest"
else
  line="**Policy:** \`$path\` from \`$repo\` at \`$sha\` ($from). SHA-256 \`$digest\`."
  printf 'Policy %s from %s at %s (%s), SHA-256 %s.\n' "$path" "$repo" "$sha" "$from" "$digest"
fi
summary "$line"
summary ""

case $GITHUB_EVENT_NAME in
  pull_request) change='This pull request' ;;
  merge_group) change='This merge group' ;;
  *) change= ;;
esac

# The pull request's own copy of the policy, compared and never read otherwise.
if [ -n "$change" ] && [ "$AC_POLICY_SOURCE" != central ]; then
  head_file=$(regular_file_in "$GITHUB_WORKSPACE" "$path")
  if [ -z "$head_file" ] || ! cmp -s -- "$head_file" "$copy"; then
    message="$change changes the policy; the check used the base version."
    notice "$message"
    summary "**Note:** $message"
    summary ""
  fi
fi

# Defense in depth: a pull request that changes the workflow running this check also chooses
# its inputs, the policy among them. GITHUB_WORKFLOW_REF is owner/repo/<path>@<ref>; a workflow
# from another repository, such as one a ruleset requires, is out of the pull request's reach.
# Compared with the exported base commit only, not with a test-base-dir.
workflow_ref=${GITHUB_WORKFLOW_REF-}
if [ -n "$change" ] && [ "${AC_BASELINE-}" = fetch ] && [ -n "$workflow_ref" ]; then
  workflow=${workflow_ref%%@refs/*}
  if [ "$workflow" = "$workflow_ref" ]; then workflow=${workflow_ref%@*}; fi
  case $workflow in
    "$GITHUB_REPOSITORY"/*)
      workflow=${workflow#"$GITHUB_REPOSITORY"/}
      if workflow=$(normalize_file_path "$workflow"); then
        base_file=$(regular_file_in "${AC_BASE_ROOT:-/nonexistent}" "$workflow")
        head_file=$(regular_file_in "$GITHUB_WORKSPACE" "$workflow")
        if [ -z "$base_file" ] || [ -z "$head_file" ] || ! cmp -s -- "$base_file" "$head_file"; then
          message="$change changes $workflow, the workflow that runs this check, so it also chooses the check's inputs, the policy among them. Review the workflow change. To enforce the policy, require the workflow through a ruleset, or require code owner review for .github/workflows/."
          warning "$message"
          summary "**Warning:** $message"
          summary ""
        fi
      fi
      ;;
  esac
fi

set_output file "$copy"
set_output sha256 "$digest"
