#!/usr/bin/env bash
# Validates the inputs, creates a work directory under $RUNNER_TEMP and decides where the
# baseline comes from. Reads the event payload with jq only.
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

case ${AC_COMMENT-} in
  true | false) ;;
  *) fail "Input comment must be true or false. Got \"$(clip "${AC_COMMENT-}")\"." ;;
esac

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
pr_number=
same_repo=false
case $GITHUB_EVENT_NAME in
  pull_request_target)
    fail "This action does not run on pull_request_target. That event gives the workflow a write token and secrets while it handles pull request content. Use on: pull_request."
    ;;
  pull_request)
    require_env GITHUB_EVENT_PATH
    base_sha=$(jq -r '.pull_request.base.sha // empty' "$GITHUB_EVENT_PATH")
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

set_output work-dir "$work"
set_output path "$path"
set_output gate "$gate"
set_output fail-on "$fail_on"
set_output targets "$targets"
set_output sarif-file "$sarif_file"
set_output test-package "$test_package"
set_output baseline "$baseline"
set_output base-root "$base_root"
set_output base-sha "$base_sha"
set_output pr-number "$pr_number"
set_output same-repo "$same_repo"
