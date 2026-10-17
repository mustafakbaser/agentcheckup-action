#!/usr/bin/env bash
# Runs agentcheckup on the base tree (when there is a baseline) and on the head, then writes the
# outputs, the step summary and the optional SARIF file. Always ends with exit status 0 once the
# outputs are written; the action's last step turns exit-code into the step result.
#
# The CLI writes one format per run, so the head is scanned once per format: JSON (whose exit
# code counts), Markdown, SARIF when requested, and GitHub annotations to the log. Scans are
# deterministic, so every run sees the same result. With a policy, every head run gets
# --policy with the copy policy.sh made from the trusted tree.
#
# The CLI reports paths relative to its working directory, and annotations and SARIF need them
# relative to the repository root. So each scan runs with the scanned tree's root as working
# directory, and the CLI is started by absolute path: `node <work>/cli/.../cli.js`. Nothing is
# resolved from that directory: no npx, no node_modules/.bin, no .npmrc.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "${BASH_SOURCE[0]%/*}/lib.sh"

require_env AC_WORK AC_CLI AC_PATH AC_GATE AC_FAIL_ON AC_BASELINE GITHUB_WORKSPACE GITHUB_OUTPUT
require_tool node jq
cd -- "$AC_WORK"

head_json="$AC_WORK/head.json"
head_md="$AC_WORK/head.md"
head_sarif="$AC_WORK/head.sarif"
base_json="$AC_WORK/base.json"
version=${AC_CLI_VERSION:-unknown}

target=.
if [ "$AC_PATH" != . ]; then target="./$AC_PATH"; fi

common=(--untrusted --no-gitignore --context)
if [ -n "${AC_TARGETS:-}" ]; then common+=("--targets=$AC_TARGETS"); fi

# Runs the CLI in directory $1 with the remaining arguments and sets `status`.
status=0
run_cli() {
  local dir=$1
  shift
  status=0
  (cd -P -- "$dir" && exec node "$AC_CLI" "$@") || status=$?
}

# Same, with workflow commands turned off: the JSON, Markdown and SARIF runs print nothing that
# the runner should act on.
run_cli_quiet() {
  local stop
  stop=$(random_token)
  printf '::stop-commands::%s\n' "$stop"
  run_cli "$@"
  printf '::%s::\n' "$stop"
}

# The physical directory to scan inside root $1, or nothing when $AC_PATH does not exist there.
# Fails when the path leads outside the root, for example through a symlink.
scan_dir() {
  local root=$1 dir
  if [ ! -e "$root/$AC_PATH" ] && [ ! -L "$root/$AC_PATH" ]; then return 0; fi
  dir=$(real_dir "$root/$AC_PATH") || true
  if [ -z "$dir" ] || ! is_inside "$dir" "$root"; then return 1; fi
  printf '%s' "$dir"
}

write_outputs() {
  local code=$1 gate_hits='' new_findings='' policy_violations='' report=''
  if [ -s "$head_json" ] && jq -e 'type == "object"' "$head_json" >/dev/null 2>&1; then
    report=$head_json
    gate_hits=$(jq -r '(.baseline.gate.hits // []) | length' "$head_json")
    new_findings=$(jq -r '
      if .baseline then (.baseline.findings.new // 0)
      else ((.summary.errors // 0) + (.summary.warnings // 0) + (.summary.infos // 0)) end' \
      "$head_json")
    policy_violations=$(jq -r '[.policy.violations[]? | select(.fails == true)] | length' "$head_json")
  fi
  set_output exit-code "$code"
  set_output gate-hits "$gate_hits"
  set_output new-findings "$new_findings"
  set_output policy-violations "$policy_violations"
  set_output report "$report"
  printf 'agentcheckup exit code %s, gate hits %s, new findings %s, policy violations %s.\n' \
    "$code" "${gate_hits:-unknown}" "${new_findings:-unknown}" "${policy_violations:-unknown}"
}

workspace=$(real_dir "$GITHUB_WORKSPACE") || fail "GITHUB_WORKSPACE is not a directory."
head_dir=$(scan_dir "$workspace") || fail "Input path leads outside the repository: $AC_PATH"
[ -n "$head_dir" ] || fail "Input path does not exist in the repository: $AC_PATH"

# --- Base ---------------------------------------------------------------------------------------

head_args=("${common[@]}" "--fail-on=$AC_FAIL_ON")
# policy.sh checked the file and copied it into the work directory, outside the checkout. The
# base scan runs without it: agentcheckup checks the baseline's inventory against the policy
# itself.
if [ -n "${AC_POLICY_FILE:-}" ]; then
  if [ -L "$AC_POLICY_FILE" ] || [ ! -f "$AC_POLICY_FILE" ]; then fail "The policy file is missing."; fi
  head_args+=("--policy=$AC_POLICY_FILE")
fi
if [ "$AC_BASELINE" != none ]; then
  base_root=$(real_dir "${AC_BASE_ROOT:-}") || fail "The base tree is missing."
  base_dir=$(scan_dir "$base_root") || fail "Input path leads outside the base tree: $AC_PATH"
  if [ -z "$base_dir" ]; then
    # The directory is new in this pull request: compare with an empty tree.
    base_root="$AC_WORK/empty"
    mkdir -p -- "$base_root/$AC_PATH"
    notice "$AC_PATH does not exist in the base commit. Comparing with an empty directory."
  fi
  echo "Scanning the base tree."
  run_cli_quiet "$base_root" "${common[@]}" --fail-on=none --format=json \
    "--output=$base_json" -- "$target"
  if [ "$status" -ge 2 ] || [ ! -s "$base_json" ]; then
    code=$status
    if [ "$code" -lt 2 ]; then code=3; fi
    error "The scan of the base commit failed with exit code $status, so there is nothing to compare with."
    summary "agentcheckup could not scan the base commit (exit code $status). See the log."
    write_outputs "$code"
    exit 0
  fi
  head_args+=("--baseline=$base_json" "--gate=$AC_GATE")
fi

# --- Head ---------------------------------------------------------------------------------------

echo "Scanning the head tree."
run_cli_quiet "$workspace" "${head_args[@]}" --format=json "--output=$head_json" -- "$target"
code=$status

# The report must name the policy this action checked, byte for byte.
if [ -n "${AC_POLICY_FILE:-}" ] && [ "$code" -lt 2 ]; then
  reported=$(jq -r '.policy.sha256? // empty' "$head_json" 2>/dev/null) || reported=
  if [ "$reported" != "${AC_POLICY_SHA256:-}" ]; then
    error "The report does not show the policy this action checked (SHA-256 ${AC_POLICY_SHA256:-unknown}). Is the version input an agentcheckup version with --policy?"
    code=3
  fi
fi

# Another run failing (2 or 3) when the JSON run did not would be a CLI bug; keep the worse code.
merge_status() {
  if [ "$status" -ge 2 ] && [ "$status" -gt "$code" ]; then code=$status; fi
}

if [ "$code" -lt 2 ]; then
  run_cli_quiet "$workspace" "${head_args[@]}" --format=markdown "--output=$head_md" -- "$target"
  merge_status
  if [ -n "${AC_SARIF_FILE:-}" ]; then
    run_cli_quiet "$workspace" "${head_args[@]}" --format=sarif "--output=$head_sarif" -- "$target"
    merge_status
  fi
  # Annotations: this run prints workflow commands on purpose. The CLI escapes scanned text.
  run_cli "$workspace" "${head_args[@]}" --format=github -- "$target"
  merge_status
fi

# --- SARIF copy ---------------------------------------------------------------------------------

# prepare.sh resolved the directory; check it again, and never write through a symlink. A file
# already at that path (for example one committed in the pull request) is removed first, so a
# failed scan cannot leave a stale or planted SARIF file for the upload step.
if [ -n "${AC_SARIF_FILE:-}" ]; then
  temp=$(real_dir "${RUNNER_TEMP:-/nonexistent}") || temp=
  parent=$(real_dir "${AC_SARIF_FILE%/*}/") || parent=
  if [ -z "$parent" ] ||
    { ! is_inside "$parent" "$workspace" && { [ -z "$temp" ] || ! is_inside "$parent" "$temp"; }; } ||
    [ "$parent/${AC_SARIF_FILE##*/}" != "$AC_SARIF_FILE" ] ||
    { [ -e "$AC_SARIF_FILE" ] && [ ! -L "$AC_SARIF_FILE" ] && [ ! -f "$AC_SARIF_FILE" ]; }; then
    error "Did not write sarif-file: its directory moved, or the path is a directory or special file."
    if [ "$code" -lt 2 ]; then code=2; fi
  else
    rm -f -- "$AC_SARIF_FILE"
    if [ -s "$head_sarif" ]; then
      cp -- "$head_sarif" "$AC_SARIF_FILE"
      printf 'Wrote SARIF to %s\n' "$AC_SARIF_FILE"
    fi
  fi
fi

# --- Summary and outputs ------------------------------------------------------------------------

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  if [ -s "$head_md" ]; then
    # A step summary may hold 1 MiB. Leave room for the footer.
    append_capped "$head_md" 1000000 "$GITHUB_STEP_SUMMARY"
    summary ""
    summary "_agentcheckup $version, exit code $code._"
  else
    summary "agentcheckup $version exited with code $code before writing a report. See the log."
  fi
fi

write_outputs "$code"
