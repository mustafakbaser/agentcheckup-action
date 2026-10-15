#!/usr/bin/env bash
# Tests the action's scripts without GitHub. Each case builds a fake runner layout in a temporary
# directory and runs the steps the way action.yml does, with a fake agentcheckup CLI
# (test/fake-cli.mjs), a fake gh, and a local git server reached through file://.
#
# Needs bash, git 2.31+, jq, tar, Node.js 22.12+ and npm. No network. Run: test/scripts.sh
#
# Several single-quoted strings below contain a literal $ on purpose (jq programs, inputs that
# must not expand).
# shellcheck disable=SC2016
set -euo pipefail

here=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo=${here%/*}
scripts="$repo/scripts"
tmp=$(mktemp -d)
tmp=$(cd -P -- "$tmp" && pwd -P)
trap 'rm -rf -- "$tmp"' EXIT

failures=0
ok() { printf 'ok   %s\n' "$1"; }
not_ok() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}
check() {
  local name=$1
  shift
  if "$@" >/dev/null; then ok "$name"; else not_ok "$name"; fi
}
# The last value of NAME in a GITHUB_OUTPUT file.
output() { awk -v key="$1=" 'index($0, key) == 1 { value = substr($0, length(key) + 1) } END { print value }' "$2"; }
contains() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }

readonly token=ghs_FakeToken0123456789abcdefABCDEF

# --- Fixtures shared by all cases ----------------------------------------------------------------

# Fake CLI package, installed through the test-package path of install.sh.
mkdir -p "$tmp/pkg/package/dist"
cp "$here/fake-cli.mjs" "$tmp/pkg/package/dist/cli.mjs"
printf '{ "name": "agentcheckup", "version": "0.0.0-fake", "type": "module", "bin": { "agentcheckup": "dist/cli.mjs" } }\n' \
  >"$tmp/pkg/package/package.json"

# Fake gh: logs calls, keeps --input files, answers from $FAKE_GH (existing, empty, deny).
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_GH_LOG"
input=
while [ $# -gt 0 ]; do
  case $1 in
    --input) input=$2; shift ;;
    --method) method=$2; shift ;;
    user) exit 1 ;;
  esac
  shift
done
if [ -n "$input" ]; then cp "$input" "$FAKE_GH_LOG.body.json"; fi
case ${method:-GET} in
  GET)
    if [ "$FAKE_GH" = existing ]; then
      printf '[{"id":7,"user":{"login":"mallory"},"body":"<!-- agentcheckup-action --> fake"}]'
      printf '[{"id":42,"user":{"login":"github-actions[bot]"},"body":"<!-- agentcheckup-action -->\\nold"}]'
    else
      printf '[]'
    fi
    ;;
  *) [ "$FAKE_GH" != deny ] ;;
esac
EOF
chmod +x "$tmp/bin/gh"

# Logging git wrapper: records every git command line, to prove the token is never on one.
real_git=$(command -v git)
cat >"$tmp/bin/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$tmp/git-argv.log"
if [ -n "\${GIT_CONFIG_VALUE_0:-}" ]; then printf '%s\n' "\$GIT_CONFIG_VALUE_0" >>"$tmp/git-env.log"; fi
exec "$real_git" "\$@"
EOF
chmod +x "$tmp/bin/git"
export PATH="$tmp/bin:$PATH"

# Local "GitHub": owner/repo.git with a base commit whose .gitattributes tries to hide and
# rewrite files in git archive output.
src="$tmp/src"
mkdir -p "$src/sub"
cp -R "$repo/test/fixtures/base/." "$src/sub/"
printf 'sub/.claude export-ignore\nsub/CLAUDE.md export-subst\n' >"$src/.gitattributes"
printf '\nCommit: $Format:%%H$\n' >>"$src/sub/CLAUDE.md"
git -C "$src" -c init.defaultBranch=main init --quiet
git -C "$src" add -A
git -C "$src" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false \
  commit --quiet -m base
base_sha=$(git -C "$src" rev-parse HEAD)
mkdir -p "$tmp/server/owner"
git clone --quiet --bare "$src" "$tmp/server/owner/repo.git"
git --git-dir="$tmp/server/owner/repo.git" config uploadpack.allowAnySHA1InWant true

# --- Running the action --------------------------------------------------------------------------

# new_case NAME: a fresh runner layout. The workspace holds the head fixture under sub/.
new_case() {
  case_dir="$tmp/case-$1"
  mkdir -p "$case_dir/temp" "$case_dir/workspace/sub"
  cp -R "$repo/test/fixtures/head/." "$case_dir/workspace/sub/"
  export RUNNER_TEMP="$case_dir/temp" GITHUB_WORKSPACE="$case_dir/workspace"
  export GITHUB_STEP_SUMMARY="$case_dir/summary" GITHUB_EVENT_PATH="$case_dir/event.json"
  export GITHUB_EVENT_NAME=push GITHUB_SERVER_URL="file://$tmp/server" GITHUB_REPOSITORY=owner/repo
  export GITHUB_RUN_ID=1 FAKE_LOG="$case_dir/cli.log" FAKE_WORKSPACE="$case_dir/workspace"
  export FAKE_GH_LOG="$case_dir/gh.log" FAKE_GH=empty FAKE_SCENARIO=clean
  : >"$GITHUB_STEP_SUMMARY"
  : >"$FAKE_LOG"
  printf '{}\n' >"$GITHUB_EVENT_PATH"
  COPYFILE_DISABLE=1 tar -czf "$RUNNER_TEMP/agentcheckup.tgz" -C "$tmp/pkg" package
  log="$case_dir/log"
  : >"$log"
}

pr_event() { # pr_event SAME_REPO(true|false)
  local head_repo=owner/repo
  if [ "$1" != true ]; then head_repo=fork/repo; fi
  export GITHUB_EVENT_NAME=pull_request
  jq -n --arg sha "$base_sha" --arg head "$head_repo" \
    '{pull_request: {number: 5, base: {sha: $sha, repo: {full_name: "owner/repo"}}, head: {repo: {full_name: $head}}}}' \
    >"$GITHUB_EVENT_PATH"
}

# step NAME VAR=VALUE...: runs scripts/NAME.sh with its own GITHUB_OUTPUT, as one action step.
step() {
  local name=$1
  shift
  : >"$case_dir/out.$name"
  env GITHUB_OUTPUT="$case_dir/out.$name" "$@" bash "$scripts/$name.sh" >>"$log" 2>&1
}

# run_action VAR=VALUE...: the steps of action.yml in order, stopping at the first failure. The
# arguments override the prepare step's inputs. Sets `result` to the action's exit status.
run_action() {
  local -a inputs=(AC_VERSION=0.1.0 AC_PATH=sub AC_GATE=security AC_FAIL_ON=error
    AC_SARIF_FILE= AC_COMMENT=false AC_TARGETS=
    "AC_TEST_PACKAGE=$RUNNER_TEMP/agentcheckup.tgz" AC_TEST_BASE_DIR= "$@")
  local comment=false item p
  for item in "${inputs[@]}"; do
    if [ "$item" = AC_COMMENT=true ]; then comment=true; fi
  done
  result=0
  step prepare "${inputs[@]}" || { result=$?; return 0; }
  p="$case_dir/out.prepare"
  step install "AC_WORK=$(output work-dir "$p")" AC_VERSION=0.1.0 \
    "AC_TEST_PACKAGE=$(output test-package "$p")" || { result=$?; return 0; }
  if [ "$(output baseline "$p")" = fetch ]; then
    step export-base "AC_WORK=$(output work-dir "$p")" "AC_BASE_SHA=$(output base-sha "$p")" \
      "AC_BASE_ROOT=$(output base-root "$p")" "AC_TOKEN=$token" || { result=$?; return 0; }
  fi
  step scan "AC_WORK=$(output work-dir "$p")" "AC_CLI=$(output cli "$case_dir/out.install")" \
    "AC_CLI_VERSION=$(output cli-version "$case_dir/out.install")" \
    "AC_PATH=$(output path "$p")" "AC_GATE=$(output gate "$p")" \
    "AC_FAIL_ON=$(output fail-on "$p")" "AC_TARGETS=$(output targets "$p")" \
    "AC_SARIF_FILE=$(output sarif-file "$p")" "AC_BASELINE=$(output baseline "$p")" \
    "AC_BASE_ROOT=$(output base-root "$p")" || { result=$?; return 0; }
  if [ "$comment" = true ]; then
    step comment "AC_WORK=$(output work-dir "$p")" "AC_PR_NUMBER=$(output pr-number "$p")" \
      "AC_SAME_REPO=$(output same-repo "$p")" "GH_TOKEN=$token" || { result=$?; return 0; }
  fi
  finish "$(output exit-code "$case_dir/out.scan")" || result=$?
}

# The "Set the result" step, taken from action.yml so the test runs the real code.
finish_script="$tmp/finish.sh"
awk '/- name: Set the result/ { found = 1 } found && /run: \|/ { body = 1; next } body { print }' \
  "$repo/action.yml" | sed 's/^        //' >"$finish_script"
finish() { env AC_EXIT_CODE="$1" bash "$finish_script" >>"$log" 2>&1; }

base_dir() { # a test-base-dir in RUNNER_TEMP whose sub/ holds fixture $1
  mkdir -p "$RUNNER_TEMP/base-$1/sub"
  cp -R "$repo/test/fixtures/$1/." "$RUNNER_TEMP/base-$1/sub/"
  printf '%s' "$RUNNER_TEMP/base-$1"
}

# --- Input validation ----------------------------------------------------------------------------

rejects() { # rejects NAME VAR=VALUE...: prepare must stop with exit 2 and exit-code=2
  local name=$1
  shift
  new_case "reject-$name"
  run_action "$@"
  check "rejects $name" test "$result" -eq 2 -a "$(output exit-code "$case_dir/out.prepare")" = 2
}

rejects version-latest AC_VERSION=latest
rejects version-range 'AC_VERSION=^0.1.0'
rejects version-partial AC_VERSION=0.1
rejects version-build AC_VERSION=0.1.0+build
rejects path-parent AC_PATH=../outside
rejects path-inner-parent AC_PATH=sub/../../x
rejects path-absolute AC_PATH=/etc
rejects path-option AC_PATH=--help
rejects path-newline "AC_PATH=sub"$'\n'"x"
rejects fail-on AC_FAIL_ON=sometimes
rejects gate-shell 'AC_GATE=mcp;rm -rf /'
rejects comment AC_COMMENT=yes
rejects targets 'AC_TARGETS=$(id)'
rejects test-package-relative AC_TEST_PACKAGE=agentcheckup.tgz

new_case reject-package-in-workspace
cp "$RUNNER_TEMP/agentcheckup.tgz" "$GITHUB_WORKSPACE/agentcheckup.tgz"
run_action "AC_TEST_PACKAGE=$GITHUB_WORKSPACE/agentcheckup.tgz"
check "rejects test-package in the workspace" test "$result" -eq 2

new_case reject-package-symlink
ln -s "$RUNNER_TEMP/agentcheckup.tgz" "$RUNNER_TEMP/link.tgz"
run_action "AC_TEST_PACKAGE=$RUNNER_TEMP/link.tgz"
check "rejects test-package symlink" test "$result" -eq 2

new_case reject-base-dir
run_action "AC_TEST_BASE_DIR=$GITHUB_WORKSPACE/sub"
check "rejects test-base-dir in the workspace" test "$result" -eq 2

new_case reject-sarif-symlinked-dir
mkdir -p "$tmp/outside"
ln -s "$tmp/outside" "$GITHUB_WORKSPACE/out"
run_action AC_SARIF_FILE=out/agentcheckup.sarif
check "rejects sarif-file through a symlinked directory" test "$result" -eq 2

new_case reject-pull-request-target
export GITHUB_EVENT_NAME=pull_request_target
run_action
check "refuses pull_request_target" test "$result" -eq 2
check "explains pull_request_target" contains "$log" 'does not run on pull_request_target'

new_case normalizes
run_action AC_PATH=./sub/ 'AC_GATE= mcp , env ' 'AC_TARGETS=claude-code, codex'
check "normalizes path" test "$(output path "$case_dir/out.prepare")" = sub
check "normalizes gate" test "$(output gate "$case_dir/out.prepare")" = mcp,env
check "normalizes targets" test "$(output targets "$case_dir/out.prepare")" = claude-code,codex
check "passes targets to the CLI" contains "$FAKE_LOG" '"--targets=claude-code,codex"'

new_case old-node
mkdir -p "$case_dir/node-bin"
printf '#!/usr/bin/env bash\necho 20.11.1\n' >"$case_dir/node-bin/node"
chmod +x "$case_dir/node-bin/node"
PATH="$case_dir/node-bin:$PATH" run_action
check "rejects Node.js older than 22.12" test "$result" -eq 2
check "explains the Node.js version" contains "$log" 'needs Node.js 22.12 or later'

# --- Scans ---------------------------------------------------------------------------------------

new_case gate
export FAKE_SCENARIO=gate
run_action "AC_TEST_BASE_DIR=$(base_dir base)" "AC_SARIF_FILE=$RUNNER_TEMP/out.sarif"
s="$case_dir/out.scan"
check "gate: action fails with 1" test "$result" -eq 1
check "gate: exit-code 1" test "$(output exit-code "$s")" = 1
check "gate: gate-hits 3" test "$(output gate-hits "$s")" = 3
check "gate: new-findings 2" test "$(output new-findings "$s")" = 2
check "gate: report is the JSON report" jq -e '.baseline.gate.hits | length == 3' "$(output report "$s")"
check "gate: SARIF written" jq -e '.version == "2.1.0"' "$RUNNER_TEMP/out.sarif"
check "gate: summary has the report" contains "$GITHUB_STEP_SUMMARY" 'Needs review: 3'
check "gate: summary has the exit code" contains "$GITHUB_STEP_SUMMARY" 'exit code 1.'
check "gate: annotations in the log" contains "$log" '::warning file=sub/CLAUDE.md'
check "gate: five CLI runs" test "$(wc -l <"$FAKE_LOG" | tr -d ' ')" -eq 5
check "gate: base scanned from the base root" \
  jq -se --arg d "$RUNNER_TEMP/base-base" '.[0].cwd == $d and .[0].head == false' "$FAKE_LOG"
check "gate: head scanned from the workspace" jq -se '.[1:] | all(.head)' "$FAKE_LOG"
check "gate: path passed after --" jq -se 'all(.argv[-2:] == ["--", "./sub"])' "$FAKE_LOG"
check "gate: head uses the baseline and gate" \
  jq -se '.[1:] | all(.argv | any(. == "--gate=security") and any(startswith("--baseline=")))' "$FAKE_LOG"
check "gate: no token in the CLI environment" jq -se 'all(.tokenInEnv | not)' "$FAKE_LOG"

new_case clean
run_action "AC_TEST_BASE_DIR=$(base_dir head)"
s="$case_dir/out.scan"
check "clean: action succeeds" test "$result" -eq 0
check "clean: exit-code 0" test "$(output exit-code "$s")" = 0
check "clean: gate-hits 0" test "$(output gate-hits "$s")" = 0
check "clean: new-findings 0" test "$(output new-findings "$s")" = 0

new_case gate-none
export FAKE_SCENARIO=gate
run_action "AC_TEST_BASE_DIR=$(base_dir base)" AC_GATE=none
check "gate none: passes --gate=none" contains "$FAKE_LOG" '"--gate=none"'
check "gate none: no gate hits" test "$(output gate-hits "$case_dir/out.scan")" = 0

new_case plain
export FAKE_SCENARIO=plain
run_action
s="$case_dir/out.scan"
check "plain: exit-code 1 from findings" test "$(output exit-code "$s")" = 1
check "plain: new-findings counts all findings" test "$(output new-findings "$s")" = 3
check "plain: gate-hits 0" test "$(output gate-hits "$s")" = 0
check "plain: no baseline or gate" jq -se 'all(.argv | all(startswith("--gate") or startswith("--baseline") | not))' "$FAKE_LOG"
check "plain: three head runs" test "$(wc -l <"$FAKE_LOG" | tr -d ' ')" -eq 3
check "plain: says the gate does not apply" contains "$log" 'the gate does not apply'

new_case usage-error
export FAKE_SCENARIO=error
run_action "AC_TEST_BASE_DIR=$(base_dir base)"
s="$case_dir/out.scan"
check "error: action fails with 2" test "$result" -eq 2
check "error: exit-code 2" test "$(output exit-code "$s")" = 2
check "error: report empty" test -z "$(output report "$s")"
check "error: summary explains" contains "$GITHUB_STEP_SUMMARY" 'before writing a report'

new_case stale-sarif
export FAKE_SCENARIO=error
printf 'planted\n' >"$GITHUB_WORKSPACE/agentcheckup.sarif"
run_action "AC_TEST_BASE_DIR=$(base_dir base)" AC_SARIF_FILE=agentcheckup.sarif
check "error: removes a SARIF file the pull request planted" test ! -e "$GITHUB_WORKSPACE/agentcheckup.sarif"

new_case base-crash
export FAKE_SCENARIO=base-crash
run_action "AC_TEST_BASE_DIR=$(base_dir base)"
check "base crash: exit-code 3" test "$(output exit-code "$case_dir/out.scan")" = 3
check "base crash: action fails with 3" test "$result" -eq 3

new_case big
export FAKE_SCENARIO=big
run_action "AC_TEST_BASE_DIR=$(base_dir base)"
size=$(wc -c <"$GITHUB_STEP_SUMMARY" | tr -d ' ')
check "big: summary within 1 MiB ($size bytes)" test "$size" -le 1048576
check "big: summary says it was cut" contains "$GITHUB_STEP_SUMMARY" 'Cut here'

new_case sarif-symlink
printf 'keep\n' >"$case_dir/victim"
ln -s "$case_dir/victim" "$GITHUB_WORKSPACE/agentcheckup.sarif"
run_action "AC_TEST_BASE_DIR=$(base_dir base)" AC_SARIF_FILE=agentcheckup.sarif
check "SARIF symlink: target untouched" test "$(cat "$case_dir/victim")" = keep
check "SARIF symlink: replaced by a regular file" \
  test -f "$GITHUB_WORKSPACE/agentcheckup.sarif" -a ! -L "$GITHUB_WORKSPACE/agentcheckup.sarif"

new_case new-directory
mkdir -p "$RUNNER_TEMP/base-empty"
run_action "AC_TEST_BASE_DIR=$RUNNER_TEMP/base-empty"
check "new directory: compares with an empty tree" \
  jq -se '.[0].cwd | endswith("/empty")' "$FAKE_LOG"
check "new directory: action succeeds" test "$result" -eq 0

new_case head-symlink-escape
rm -rf "$GITHUB_WORKSPACE/sub"
ln -s "$tmp/outside" "$GITHUB_WORKSPACE/sub"
run_action
check "head path symlinked outside: rejected" test "$result" -eq 2
check "head path symlinked outside: CLI not run" test ! -s "$FAKE_LOG"

# --- Base commit from the local server -----------------------------------------------------------

new_case fetch
pr_event true
: >"$tmp/git-argv.log"
: >"$tmp/git-env.log"
run_action
p="$case_dir/out.prepare"
base_root=$(output base-root "$p")
check "fetch: baseline mode" test "$(output baseline "$p")" = fetch
check "fetch: action succeeds" test "$result" -eq 0
check "fetch: base tree exported" test -f "$base_root/sub/.mcp.json"
check "fetch: export-ignore turned off" test -f "$base_root/sub/.claude/settings.json"
check "fetch: export-subst turned off" contains "$base_root/sub/CLAUDE.md" '$Format:%H$'
check "fetch: bare repository removed" test ! -e "$(output work-dir "$p")/base.git"
check "fetch: token never on a git command line" lacks "$tmp/git-argv.log" "$token"
check "fetch: header passed in the environment" contains "$tmp/git-env.log" 'AUTHORIZATION: basic '
check "fetch: token masked" contains "$log" "::add-mask::$token"
check "fetch: token not written under RUNNER_TEMP" \
  test -z "$(grep -rlF -- "$token" "$RUNNER_TEMP" 2>/dev/null || true)"
check "fetch: workspace untouched by git" test ! -e "$GITHUB_WORKSPACE/.git"

new_case fetch-bad-sha
pr_event true
jq '.pull_request.base.sha = "0000000000000000000000000000000000000001"' "$GITHUB_EVENT_PATH" \
  >"$case_dir/event2.json"
mv "$case_dir/event2.json" "$GITHUB_EVENT_PATH"
run_action
check "fetch: unknown base commit fails with 2" test "$result" -eq 2
check "fetch: unknown base commit sets exit-code 2" \
  test "$(output exit-code "$case_dir/out.export-base")" = 2

# --- Pull request comment ------------------------------------------------------------------------

new_case comment-update
pr_event true
export FAKE_GH=existing
run_action AC_COMMENT=true
check "comment: updates the bot's marker comment" contains "$FAKE_GH_LOG" 'issues/comments/42'
check "comment: leaves other marker comments alone" lacks "$FAKE_GH_LOG" 'issues/comments/7'
check "comment: body starts with the marker" \
  jq -e '.body | startswith("<!-- agentcheckup-action -->")' "$FAKE_GH_LOG.body.json"

new_case comment-create
pr_event true
run_action AC_COMMENT=true
check "comment: creates one when none exists" contains "$FAKE_GH_LOG" '--method POST repos/owner/repo/issues/5/comments'

new_case comment-fork
pr_event false
run_action AC_COMMENT=true
check "comment: skipped for forks" test ! -e "$FAKE_GH_LOG"
check "comment: fork notice" contains "$log" 'comes from a fork'
check "comment: fork run still succeeds" test "$result" -eq 0

new_case comment-denied
pr_event true
export FAKE_GH=deny
run_action AC_COMMENT=true
check "comment: no write permission is a notice" contains "$log" 'pull-requests: write'
check "comment: no write permission does not fail" test "$result" -eq 0

new_case comment-push
run_action AC_COMMENT=true
check "comment: skipped outside pull requests" contains "$log" 'only applies to pull_request'

# --- Result step ---------------------------------------------------------------------------------

new_case finish
for pair in 0:0 1:1 2:2 3:3 :3 x:3; do
  code=${pair%%:*}
  want=${pair##*:}
  got=0
  finish "$code" || got=$?
  check "result step: exit-code '$code' exits $want" test "$got" -eq "$want"
done

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed."
  exit 1
fi
echo "All checks passed."
