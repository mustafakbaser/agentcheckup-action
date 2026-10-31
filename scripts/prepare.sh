#!/usr/bin/env bash
# Validates the inputs, creates a work directory under $RUNNER_TEMP and decides where the
# baseline and the policy come from, and whether suggestions run. Reads the event payload with
# jq only.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "${BASH_SOURCE[0]%/*}/lib.sh"

if [ "${RUNNER_OS:-}" = Windows ]; then fail "Windows runners are not supported. Use a Linux or macOS runner."; fi
require_env RUNNER_TEMP GITHUB_WORKSPACE GITHUB_OUTPUT GITHUB_EVENT_NAME
require_tool jq
cd -- "$RUNNER_TEMP"

temp_real=$(real_dir "$RUNNER_TEMP") || fail "RUNNER_TEMP is not a directory."
workspace_real=$(real_dir "$GITHUB_WORKSPACE") || fail "GITHUB_WORKSPACE is not a directory."

# --- Inputs ------------------------------------------------------------------------------------

version=${AC_VERSION-}
if ! is_exact_version "$version"; then
  fail "Input version must be an exact version such as 1.2.3, not a range or a tag. Got \"$(clip "$version")\"."
fi

if ! path=$(normalize_relative_path "${AC_PATH-}"); then
  fail "Input path must be a directory inside the repository, without \"..\". Got \"$(clip "${AC_PATH-}")\"."
fi

gate=${AC_GATE-}
gate=${gate//[[:space:]]/}
if ! [[ $gate =~ ^[a-z-]+(,[a-z-]+)*$ ]]; then
  fail "Input gate must be none, security or a comma-separated list of gate classes. Got \"$(clip "${AC_GATE-}")\"."
fi

fail_on=${AC_FAIL_ON-}
case $fail_on in
  error | warn | info | none) ;;
  *) fail "Input fail-on must be error, warn, info or none. Got \"$(clip "$fail_on")\"." ;;
esac

comment=${AC_COMMENT-}
case $comment in
  true | false | on-change) ;;
  *) fail "Input comment must be true, false or on-change. Got \"$(clip "$comment")\"." ;;
esac

suggest=${AC_SUGGEST-}
case $suggest in
  true | false) ;;
  *) fail "Input suggest must be true or false. Got \"$(clip "$suggest")\"." ;;
esac

# Policy: `policy` names a file in this repository's trusted tree; `policy-repository` with
# `policy-path` and `policy-ref` a file in a central repository. policy-token itself never
# reaches this step, only whether it is set.
policy=${AC_POLICY-}
policy_repository=${AC_POLICY_REPOSITORY-}
policy_path=${AC_POLICY_PATH-}
policy_ref=${AC_POLICY_REF-}
if [ -n "$policy" ] && [ -n "$policy_repository" ]; then
  fail "Inputs policy and policy-repository cannot be combined. Use policy for a file in this repository, or policy-repository with policy-path for a central policy."
fi
if [ -z "$policy_repository" ]; then
  if [ -n "$policy_path" ] || [ -n "$policy_ref" ] || [ "${AC_POLICY_TOKEN_SET:-false}" = true ]; then
    fail "Inputs policy-path, policy-ref and policy-token need policy-repository."
  fi
fi
if [ -n "$policy" ]; then
  policy_path=$(normalize_file_path "$policy") ||
    fail "Input policy must be a file path inside the repository, with letters, digits, \".\", \"_\", \"-\", \"+\", \"@\" and \"/\" only, and without \"..\". Got \"$(clip "$policy")\"."
fi
if [ -n "$policy_repository" ]; then
  if ! [[ $policy_repository =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    fail "Input policy-repository must be owner/name. Got \"$(clip "$policy_repository")\"."
  fi
  if [ -z "$policy_path" ]; then fail "Input policy-repository needs policy-path."; fi
  policy_path=$(normalize_file_path "$policy_path") ||
    fail "Input policy-path must be a file path inside the policy repository, with letters, digits, \".\", \"_\", \"-\", \"+\", \"@\" and \"/\" only, and without \"..\". Got \"$(clip "${AC_POLICY_PATH-}")\"."
  if [ -z "$policy_ref" ]; then policy_ref=HEAD; fi
  if ! is_git_ref "$policy_ref"; then
    fail "Input policy-ref must be a branch, a tag or a full commit SHA. Got \"$(clip "$policy_ref")\"."
  fi
fi

targets=${AC_TARGETS-}
targets=${targets//[[:space:]]/}
if [ -n "$targets" ] && ! [[ $targets =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]]; then
  fail "Input targets must be a comma-separated list of platform ids. Got \"$(clip "${AC_TARGETS-}")\"."
fi

# sarif-file: relative to the workspace, or absolute. The directory must already exist and be
# inside the workspace or $RUNNER_TEMP, so a symlinked directory in the pull request cannot send
# the file elsewhere. scan.sh checks again before it copies.
sarif_file=
if [ -n "${AC_SARIF_FILE-}" ]; then
  raw=$AC_SARIF_FILE
  if [[ $raw =~ [[:cntrl:]] ]]; then fail "Input sarif-file contains a control character."; fi
  case $raw in
    /*) absolute=$raw ;;
    *) absolute="$workspace_real/$raw" ;;
  esac
  name=${absolute##*/}
  case $name in
    '' | . | ..) fail "Input sarif-file must name a file. Got \"$(clip "$raw")\"." ;;
  esac
  parent=$(real_dir "${absolute%/*}/") || true
  if [ -z "$parent" ]; then
    fail "The directory of sarif-file does not exist: \"$(clip "$raw")\"."
  fi
  if ! is_inside "$parent" "$workspace_real" && ! is_inside "$parent" "$temp_real"; then
    fail "sarif-file must be inside the workspace or \$RUNNER_TEMP. Got \"$(clip "$raw")\"."
  fi
  sarif_file="$parent/$name"
fi

# sarif-category: agentcheckup's --sarif-category, which 0.4.0 added, with the characters and
# length it takes. Checked here so that a wrong value fails before anything is installed.
sarif_category=${AC_SARIF_CATEGORY-}
if [ -n "$sarif_category" ]; then
  if [ -z "$sarif_file" ]; then fail "Input sarif-category needs sarif-file."; fi
  if [ "${#sarif_category}" -gt 100 ] ||
    ! [[ $sarif_category =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$ ]]; then
    fail "Input sarif-category must be letters, digits, \".\", \"_\" and \"-\", in parts separated by \"/\", at most 100 characters, such as api or packages/web. Got \"$(clip "$sarif_category")\"."
  fi
  if [[ $version =~ ^0\.([0-9]+)\. ]] && [ "${BASH_REMATCH[1]}" -lt 4 ]; then
    fail "Input sarif-category needs agentcheckup 0.4.0 or later; input version is $version."
  fi
fi

# Test-only inputs. Both must point into $RUNNER_TEMP: the workspace holds pull request content,
# and a tarball or baseline from there would let the pull request choose the code or the baseline.
test_package=
if [ -n "${AC_TEST_PACKAGE-}" ]; then
  raw=$AC_TEST_PACKAGE
  case $raw in
    /*.tgz) ;;
    *) fail "Input test-package must be an absolute path to a .tgz file in \$RUNNER_TEMP." ;;
  esac
  if [ -L "$raw" ] || [ ! -f "$raw" ]; then
    fail "Input test-package is not a regular file: \"$(clip "$raw")\"."
  fi
  parent=$(real_dir "${raw%/*}/") || true
  if [ -z "$parent" ] || ! is_inside "$parent" "$temp_real"; then
    fail "Input test-package must be inside \$RUNNER_TEMP."
  fi
  test_package="$parent/${raw##*/}"
  warning "Test-only input test-package is set: running agentcheckup from $test_package instead of npm."
fi

test_base_dir=
if [ -n "${AC_TEST_BASE_DIR-}" ]; then
  raw=$AC_TEST_BASE_DIR
  case $raw in
    /*) ;;
    *) fail "Input test-base-dir must be an absolute path in \$RUNNER_TEMP." ;;
  esac
  if [ -L "$raw" ] || [ ! -d "$raw" ]; then
    fail "Input test-base-dir is not a directory: \"$(clip "$raw")\"."
  fi
  test_base_dir=$(real_dir "$raw")
  if ! is_inside "$test_base_dir" "$temp_real" || [ "$test_base_dir" = "$temp_real" ]; then
    fail "Input test-base-dir must be a directory inside \$RUNNER_TEMP."
  fi
  warning "Test-only input test-base-dir is set: using $test_base_dir as the base tree."
fi

# --- Event -------------------------------------------------------------------------------------

base_sha=
head_sha=
pr_number=
same_repo=false
case $GITHUB_EVENT_NAME in
  pull_request_target)
    fail "This action does not run on pull_request_target. That event gives the workflow a write token and secrets while it handles pull request content. Use on: pull_request."
    ;;
  pull_request)
    require_env GITHUB_EVENT_PATH
    base_sha=$(jq -r '.pull_request.base.sha // empty' "$GITHUB_EVENT_PATH")
    head_sha=$(jq -r '.pull_request.head.sha // empty' "$GITHUB_EVENT_PATH")
    pr_number=$(jq -r '.pull_request.number // empty' "$GITHUB_EVENT_PATH")
    same_repo=$(jq -r '
      (.pull_request.head.repo.full_name // "") as $head
      | if $head != "" and $head == (.pull_request.base.repo.full_name // "")
        then "true" else "false" end' "$GITHUB_EVENT_PATH")
    if ! [[ $pr_number =~ ^[1-9][0-9]*$ ]]; then
      fail "The pull_request event has no pull request number."
    fi
    ;;
  merge_group)
    require_env GITHUB_EVENT_PATH
    base_sha=$(jq -r '.merge_group.base_sha // empty' "$GITHUB_EVENT_PATH")
    ;;
esac

if [ -n "$base_sha" ] && ! [[ $base_sha =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
  fail "The event payload has an invalid base commit SHA."
fi

work=$(mktemp -d "$temp_real/agentcheckup.XXXXXX")
chmod 700 "$work"

if [ -n "$test_base_dir" ]; then
  baseline=dir
  base_root=$test_base_dir
elif [ -n "$base_sha" ]; then
  baseline=fetch
  base_root="$work/base"
else
  baseline=none
  base_root=
  if [ "$gate" != none ]; then
    notice "No baseline on $GITHUB_EVENT_NAME events, so the gate does not apply. This run checks findings only."
  fi
fi

# The policy comes from a trusted tree, never from the workspace: the base commit on
# pull_request and merge_group, the default branch (HEAD of the repository) otherwise, or the
# central repository. test-base-dir stands for the base commit.
policy_source=none
policy_root=
if [ -n "$policy" ]; then
  policy_repository=$GITHUB_REPOSITORY
  if [ -n "$test_base_dir" ]; then
    policy_source=dir
    policy_root=$test_base_dir
  else
    policy_source=tree
    policy_root="$work/policy-tree"
    policy_ref=${base_sha:-HEAD}
  fi
elif [ -n "$policy_repository" ]; then
  policy_source=central
  policy_root="$work/policy-tree"
fi

# Suggestions need a pull request whose token can write: same repository only.
if [ "$suggest" = true ]; then
  if [ "$GITHUB_EVENT_NAME" != pull_request ]; then
    notice "suggest: true only applies to pull_request events. No suggestions."
    suggest=false
  elif [ "$same_repo" != true ]; then
    notice "This pull request comes from a fork, and its token cannot write review comments. No suggestions."
    suggest=false
  elif ! is_sha "$head_sha"; then
    notice "The pull_request event has no valid head commit SHA. No suggestions."
    suggest=false
  fi
fi
if [ "$suggest" != true ]; then head_sha=; fi

set_output work-dir "$work"
set_output path "$path"
set_output gate "$gate"
set_output fail-on "$fail_on"
set_output targets "$targets"
set_output sarif-file "$sarif_file"
set_output sarif-category "$sarif_category"
set_output test-package "$test_package"
set_output baseline "$baseline"
set_output base-root "$base_root"
set_output base-sha "$base_sha"
set_output pr-number "$pr_number"
set_output same-repo "$same_repo"
set_output comment "$comment"
set_output policy-source "$policy_source"
set_output policy-repository "$policy_repository"
set_output policy-path "$policy_path"
set_output policy-ref "$policy_ref"
set_output policy-root "$policy_root"
set_output suggest "$suggest"
set_output head-sha "$head_sha"
set_output head-root "$work/head"
