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
# TEST_KEEP=1 keeps the cases for debugging.
if [ -n "${TEST_KEEP:-}" ]; then echo "Cases in $tmp"; else trap 'rm -rf -- "$tmp"' EXIT; fi

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
# The last value of NAME in a GITHUB_OUTPUT file; nothing when the step did not run.
output() {
  [ -f "$2" ] || return 0
  awk -v key="$1=" 'index($0, key) == 1 { value = substr($0, length(key) + 1) } END { print value }' "$2"
}
contains() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }
# The lines of file $1 that hold $2, except ::add-mask:: lines.
unmasked() { grep -F -- "$2" "$1" | grep -v '^::add-mask::' || true; }

readonly token=ghs_FakeToken0123456789abcdefABCDEF
readonly central_token=ghp_CentralToken0123456789abcdefABCD

# --- Fixtures shared by all cases ----------------------------------------------------------------

# Fake CLI package, installed through the test-package path of install.sh.
mkdir -p "$tmp/pkg/package/dist"
cp "$here/fake-cli.mjs" "$tmp/pkg/package/dist/cli.mjs"
printf '{ "name": "agentcheckup", "version": "0.0.0-fake", "type": "module", "bin": { "agentcheckup": "dist/cli.mjs" } }\n' \
  >"$tmp/pkg/package/package.json"

# Fake gh: logs calls and keeps --input files. Answers issue comments from $FAKE_GH (existing,
# empty, deny), the diff from $FAKE_GH_DIFF (ok, large, fail), review comments from the file
# $FAKE_GH_REVIEW_COMMENTS, and a new review from $FAKE_GH_REVIEW (ok, 422, deny).
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_GH_LOG"
input=
method=GET
endpoint=
while [ $# -gt 0 ]; do
  case $1 in
    --input) input=$2; shift ;;
    --method) method=$2; shift ;;
    -H | --jq) shift ;;
    api | --paginate | --silent) ;;
    *) endpoint=$1 ;;
  esac
  shift
done
case $endpoint in
  user) exit 1 ;;
  */reviews) if [ -n "$input" ]; then cp "$input" "$FAKE_GH_LOG.review.json"; fi ;;
  *) if [ -n "$input" ]; then cp "$input" "$FAKE_GH_LOG.body.json"; fi ;;
esac
case "$method $endpoint" in
  "GET repos/owner/repo/issues/5/comments?per_page=100")
    if [ "$FAKE_GH" = existing ]; then
      printf '[{"id":7,"user":{"login":"mallory"},"body":"<!-- agentcheckup-action --> fake"}]'
      printf '[{"id":42,"user":{"login":"github-actions[bot]"},"body":"<!-- agentcheckup-action -->\\nold"}]'
    else
      printf '[]'
    fi
    ;;
  "GET repos/owner/repo/pulls/5")
    case $FAKE_GH_DIFF in
      ok) cat "$FAKE_DIFF" ;;
      large)
        echo 'gh: Sorry, the diff exceeded the maximum number of lines (20000) (HTTP 406)' >&2
        exit 1
        ;;
      *)
        echo 'gh: Not Found (HTTP 404)' >&2
        exit 1
        ;;
    esac
    ;;
  "GET repos/owner/repo/pulls/5/comments?per_page=100")
    if [ -n "$FAKE_GH_REVIEW_COMMENTS" ]; then cat "$FAKE_GH_REVIEW_COMMENTS"; else printf '[]'; fi
    ;;
  "POST repos/owner/repo/pulls/5/reviews")
    case $FAKE_GH_REVIEW in
      ok) ;;
      422)
        echo 'gh: Validation Failed (HTTP 422)' >&2
        exit 1
        ;;
      *)
        echo 'gh: Resource not accessible by integration (HTTP 403)' >&2
        exit 1
        ;;
    esac
    ;;
  "DELETE repos/owner/repo/pulls/comments/"*) ;;
  *) [ "$FAKE_GH" != deny ] ;;
esac
EOF
chmod +x "$tmp/bin/gh"

# Logging git wrapper: records every git command line, to prove a token is never on one. It
# also plays a private repository: fetches from server/private/ without an Authorization header
# fail, as they do on GitHub.
real_git=$(command -v git)
cat >"$tmp/bin/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$tmp/git-argv.log"
if [ -n "\${GIT_CONFIG_VALUE_0:-}" ]; then printf '%s\n' "\$GIT_CONFIG_VALUE_0" >>"$tmp/git-env.log"; fi
case "\$*" in
  *" fetch "*"/server/private/"*)
    case "\${GIT_CONFIG_VALUE_0:-}" in
      "AUTHORIZATION: basic "*) ;;
      *)
        echo "fatal: could not read Username: terminal prompts disabled" >&2
        exit 128
        ;;
    esac
    ;;
esac
exec "$real_git" "\$@"
EOF
chmod +x "$tmp/bin/git"
export PATH="$tmp/bin:$PATH"
commit() { git -C "$1" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false -c tag.gpgsign=false "${@:2}"; }

# Local "GitHub": owner/repo.git with a base commit whose .gitattributes tries to hide and
# rewrite files in git archive output. It also holds policies (one hidden with export-ignore, a
# symlink, a directory, an oversized and an invalid one) and the workflow that runs the check.
# Branch pr-head is the pull request's head commit.
src="$tmp/src"
mkdir -p "$src/sub" "$src/policy/dir.json" "$src/.github/workflows"
cp -R "$repo/test/fixtures/base/." "$src/sub/"
printf 'sub/.claude export-ignore\nsub/CLAUDE.md export-subst\npolicy/agent-policy.json export-ignore\n' \
  >"$src/.gitattributes"
printf '\nCommit: $Format:%%H$\n' >>"$src/sub/CLAUDE.md"
printf '{ "policyVersion": 1, "name": "base policy", "forbid": ["broad-shell"] }\n' \
  >"$src/policy/agent-policy.json"
printf '{ "policyVersion": 1, "name": "audit policy", "mode": "audit", "forbid": ["broad-shell"] }\n' \
  >"$src/policy/audit.json"
printf '{ "policyVersion": 1, "name": "typo", "forbidd": [] }\n' >"$src/policy/invalid.json"
printf '{}\n' >"$src/policy/dir.json/inner.json"
ln -s agent-policy.json "$src/policy/link.json"
{
  printf '{ "policyVersion": 1, "name": "big", "$schema": "'
  head -c 300000 /dev/zero | tr '\0' 'a'
  printf '" }\n'
} >"$src/policy/big.json"
printf 'name: check\non: pull_request\n' >"$src/.github/workflows/check.yml"
git -C "$src" -c init.defaultBranch=main init --quiet
git -C "$src" add -A
commit "$src" commit --quiet -m base
base_sha=$(git -C "$src" rev-parse HEAD)
git -C "$src" checkout --quiet -b pr-head
printf '\nHead line.\n' >>"$src/sub/CLAUDE.md"
commit "$src" commit --quiet -am head
head_sha=$(git -C "$src" rev-parse HEAD)
git -C "$src" checkout --quiet main
mkdir -p "$tmp/server/owner" "$tmp/server/org" "$tmp/server/private"
git clone --quiet --bare "$src" "$tmp/server/owner/repo.git"
git --git-dir="$tmp/server/owner/repo.git" config uploadpack.allowAnySHA1InWant true

# Central policy repositories: org/policies is public, private/policies needs a token. Tag v1
# is annotated.
central="$tmp/central"
mkdir -p "$central"
printf '{ "policyVersion": 1, "name": "central policy", "forbid": ["broad-shell", "gemini-trust"] }\n' \
  >"$central/agent-policy.json"
git -C "$central" -c init.defaultBranch=main init --quiet
git -C "$central" add -A
commit "$central" commit --quiet -m central
commit "$central" tag -a v1 -m v1
central_sha=$(git -C "$central" rev-parse HEAD)
for name in org private; do
  git clone --quiet --bare "$central" "$tmp/server/$name/policies.git"
  git --git-dir="$tmp/server/$name/policies.git" config uploadpack.allowAnySHA1InWant true
done

policy_sha=$(shasum -a 256 <"$src/policy/agent-policy.json" | cut -d ' ' -f 1)
central_policy_sha=$(shasum -a 256 <"$central/agent-policy.json" | cut -d ' ' -f 1)

# The pull request's diff, as the API returns it.
cat >"$tmp/pr.diff" <<'EOF'
diff --git a/sub/CLAUDE.md b/sub/CLAUDE.md
index 1111111..2222222 100644
--- a/sub/CLAUDE.md
+++ b/sub/CLAUDE.md
@@ -1,3 +1,5 @@
 # Project notes

 Run `npm test` before you commit.
+
+Head line.
EOF

# Review comments already on the pull request, in two pages as gh api --paginate prints them.
# The fake CLI suggests markers aaaa, bbbb, dddd (whose suggested line holds marker cccc), eeee
# outside sub/, and one without a marker. Expected: post bbbb and dddd; delete 102 and 105.
cat >"$tmp/review-comments.json" <<'EOF'
[
  { "id": 101, "user": { "login": "github-actions[bot]" }, "path": "sub/CLAUDE.md",
    "body": "```suggestion\nRun `npm test` first.\n```\n\n<!-- agentcheckup-suggestion claude-code/fake-rule aaaaaaaaaaaa -->" },
  { "id": 102, "user": { "login": "github-actions[bot]" }, "path": "sub/CLAUDE.md",
    "body": "outdated\n<!-- agentcheckup-suggestion claude-code/fake-rule 999999999999 -->" },
  { "id": 103, "user": { "login": "mallory" }, "path": "sub/CLAUDE.md",
    "body": "<!-- agentcheckup-suggestion claude-code/fake-rule bbbbbbbbbbbb -->" }
]
[
  { "id": 104, "user": { "login": "github-actions[bot]" }, "path": "sub/CLAUDE.md",
    "body": "```suggestion\n<!-- agentcheckup-suggestion claude-code/fake-rule dddddddddddd -->\n```\nnot a marker line" },
  { "id": 105, "user": { "login": "github-actions[bot]" }, "path": "sub/CLAUDE.md",
    "body": "outdated\r\n<!-- agentcheckup-suggestion claude-code/fake-rule cccccccccccc -->\r\n" },
  { "id": 106, "user": { "login": "github-actions[bot]" }, "path": "other/AGENTS.md",
    "body": "<!-- agentcheckup-suggestion claude-code/fake-rule 888888888888 -->" }
]
EOF

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
  export FAKE_GH_LOG="$case_dir/gh.log" FAKE_GH=empty FAKE_SCENARIO=clean FAKE_SUGGEST=ok
  export FAKE_GH_DIFF=ok FAKE_GH_REVIEW=ok FAKE_GH_REVIEW_COMMENTS='' FAKE_DIFF="$tmp/pr.diff"
  unset GITHUB_WORKFLOW_REF
  policy_token=
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
  jq -n --arg sha "$base_sha" --arg head_sha "$head_sha" --arg head "$head_repo" \
    '{pull_request: {number: 5, base: {sha: $sha, repo: {full_name: "owner/repo"}},
      head: {sha: $head_sha, repo: {full_name: $head}}}}' >"$GITHUB_EVENT_PATH"
}

# step ID SCRIPT VAR=VALUE...: runs scripts/SCRIPT.sh as the action step with id ID, with its
# own GITHUB_OUTPUT.
step() {
  local id=$1 script=$2
  shift 2
  : >"$case_dir/out.$id"
  env GITHUB_OUTPUT="$case_dir/out.$id" "$@" bash "$scripts/$script.sh" >>"$log" 2>&1
}

# run_action VAR=VALUE...: the steps of action.yml in order, stopping at the first failure. The
# arguments override the prepare step's inputs; $policy_token is input policy-token. Sets
# `result` to the action's exit status.
run_action() {
  local token_set=false p w policy_source
  if [ -n "$policy_token" ]; then token_set=true; fi
  local -a inputs=(AC_VERSION=0.1.0 AC_PATH=sub AC_GATE=security AC_FAIL_ON=error
    AC_SARIF_FILE= AC_COMMENT=false AC_SUGGEST=false AC_TARGETS= AC_POLICY=
    AC_POLICY_REPOSITORY= AC_POLICY_PATH= AC_POLICY_REF= "AC_POLICY_TOKEN_SET=$token_set"
    "AC_TEST_PACKAGE=$RUNNER_TEMP/agentcheckup.tgz" AC_TEST_BASE_DIR= "$@")
  result=0
  step prepare prepare "${inputs[@]}" || { result=$?; return 0; }
  p="$case_dir/out.prepare"
  w=$(output work-dir "$p")
  step install install "AC_WORK=$w" AC_VERSION=0.1.0 \
    "AC_TEST_PACKAGE=$(output test-package "$p")" || { result=$?; return 0; }
  if [ "$(output baseline "$p")" = fetch ]; then
    step base export-tree "AC_WORK=$w" AC_TREE_KIND=base "AC_TREE_REF=$(output base-sha "$p")" \
      "AC_TREE_DEST=$(output base-root "$p")" "AC_TOKEN=$token" || { result=$?; return 0; }
  fi
  policy_source=$(output policy-source "$p")
  if [ "$policy_source" = tree ]; then
    step policy-tree export-tree "AC_WORK=$w" AC_TREE_KIND=policy \
      "AC_TREE_REF=$(output policy-ref "$p")" "AC_TREE_PATH=$(output policy-path "$p")" \
      "AC_TREE_DEST=$(output policy-root "$p")" "AC_TOKEN=$token" || { result=$?; return 0; }
  fi
  if [ "$policy_source" = central ]; then
    step policy-central export-tree "AC_WORK=$w" AC_TREE_KIND=policy-central \
      "AC_TREE_REPOSITORY=$(output policy-repository "$p")" \
      "AC_TREE_REF=$(output policy-ref "$p")" "AC_TREE_PATH=$(output policy-path "$p")" \
      "AC_TREE_DEST=$(output policy-root "$p")" "AC_SAME_REPO=$(output same-repo "$p")" \
      "AC_TOKEN=$policy_token" || { result=$?; return 0; }
  fi
  if [ "$policy_source" != none ]; then
    step policy policy "AC_WORK=$w" "AC_POLICY_SOURCE=$policy_source" \
      "AC_POLICY_ROOT=$(output policy-root "$p")" "AC_POLICY_PATH=$(output policy-path "$p")" \
      "AC_POLICY_REPOSITORY=$(output policy-repository "$p")" \
      "AC_POLICY_REF=$(output policy-ref "$p")" \
      "AC_POLICY_SHA=$(output sha "$case_dir/out.policy-tree")$(output sha "$case_dir/out.policy-central")" \
      "AC_BASELINE=$(output baseline "$p")" "AC_BASE_ROOT=$(output base-root "$p")" ||
      { result=$?; return 0; }
  fi
  step scan scan "AC_WORK=$w" "AC_CLI=$(output cli "$case_dir/out.install")" \
    "AC_CLI_VERSION=$(output cli-version "$case_dir/out.install")" \
    "AC_PATH=$(output path "$p")" "AC_GATE=$(output gate "$p")" \
    "AC_FAIL_ON=$(output fail-on "$p")" "AC_TARGETS=$(output targets "$p")" \
    "AC_SARIF_FILE=$(output sarif-file "$p")" "AC_BASELINE=$(output baseline "$p")" \
    "AC_BASE_ROOT=$(output base-root "$p")" \
    "AC_POLICY_FILE=$(output file "$case_dir/out.policy")" \
    "AC_POLICY_SHA256=$(output sha256 "$case_dir/out.policy")" || { result=$?; return 0; }
  if [ "$(output suggest "$p")" = true ]; then
    step head export-tree "AC_WORK=$w" AC_TREE_KIND=head "AC_TREE_REF=$(output head-sha "$p")" \
      "AC_TREE_DEST=$(output head-root "$p")" "AC_TOKEN=$token" || { result=$?; return 0; }
    step suggest suggest "AC_WORK=$w" "AC_CLI=$(output cli "$case_dir/out.install")" \
      "AC_PATH=$(output path "$p")" "AC_TARGETS=$(output targets "$p")" \
      "AC_PR_NUMBER=$(output pr-number "$p")" "AC_HEAD_SHA=$(output head-sha "$p")" \
      "AC_HEAD_ROOT=$(output head-root "$p")" "AC_HEAD_EXPORTED=$(output sha "$case_dir/out.head")" \
      "GH_TOKEN=$token" || { result=$?; return 0; }
  fi
  case $(output comment "$p") in
    true | on-change)
      step comment comment "AC_WORK=$w" "AC_COMMENT_MODE=$(output comment "$p")" \
        "AC_PR_NUMBER=$(output pr-number "$p")" "AC_SAME_REPO=$(output same-repo "$p")" \
        "GH_TOKEN=$token" || { result=$?; return 0; }
      ;;
  esac
  finish "$(output exit-code "$case_dir/out.scan")" || result=$?
}

# The action's exit-code output: the first step that set one, in the order of action.yml.
action_exit_code() {
  local id value
  for id in scan policy policy-central policy-tree base install prepare; do
    value=$(output exit-code "$case_dir/out.$id")
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return 0
    fi
  done
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
rejects suggest AC_SUGGEST=yes
rejects targets 'AC_TARGETS=$(id)'
rejects test-package-relative AC_TEST_PACKAGE=agentcheckup.tgz
rejects policy-and-repository AC_POLICY=policy/agent-policy.json AC_POLICY_REPOSITORY=org/policies \
  AC_POLICY_PATH=agent-policy.json
rejects policy-path-alone AC_POLICY_PATH=agent-policy.json
rejects policy-ref-alone AC_POLICY_REF=main
rejects policy-parent AC_POLICY=../policy.json
rejects policy-absolute AC_POLICY=/etc/passwd
rejects policy-root AC_POLICY=.
rejects policy-glob 'AC_POLICY=policy/*.json'
rejects policy-pathspec-magic 'AC_POLICY=:(top)policy.json'
rejects policy-dot-segment AC_POLICY=policy/./agent-policy.json
rejects policy-repository-format AC_POLICY_REPOSITORY=org AC_POLICY_PATH=agent-policy.json
rejects policy-repository-without-path AC_POLICY_REPOSITORY=org/policies
rejects policy-path-parent AC_POLICY_REPOSITORY=org/policies AC_POLICY_PATH=../x.json
rejects policy-ref-option AC_POLICY_REPOSITORY=org/policies AC_POLICY_PATH=agent-policy.json \
  'AC_POLICY_REF=--upload-pack=touch /tmp/x'
rejects policy-ref-range AC_POLICY_REPOSITORY=org/policies AC_POLICY_PATH=agent-policy.json \
  AC_POLICY_REF=main..HEAD
rejects policy-ref-refspec AC_POLICY_REPOSITORY=org/policies AC_POLICY_PATH=agent-policy.json \
  AC_POLICY_REF=+main:refs/heads/x

new_case reject-policy-token-alone
policy_token=$central_token
run_action
check "rejects policy-token without policy-repository" test "$result" -eq 2
check "explains policy-token without policy-repository" contains "$log" 'need policy-repository'

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
check "gate: policy-violations 0 without a policy" test "$(output policy-violations "$s")" = 0
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
check "gate: no policy without the input" jq -se 'all(.argv | any(startswith("--policy")) | not)' "$FAKE_LOG"
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
check "error: policy-violations empty" test -z "$(output policy-violations "$s")"
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
check "fetch: records the commit" test "$(output sha "$case_dir/out.base")" = "$base_sha"
check "fetch: bare repository removed" test ! -e "$(output work-dir "$p")/base.git"
check "fetch: token never on a git command line" lacks "$tmp/git-argv.log" "$token"
check "fetch: header passed in the environment" contains "$tmp/git-env.log" 'AUTHORIZATION: basic '
check "fetch: token masked" contains "$log" "::add-mask::$token"
check "fetch: token never printed otherwise" test -z "$(unmasked "$log" "$token")"
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
check "fetch: unknown base commit sets exit-code 2" test "$(action_exit_code)" = 2

# --- Policy from the trusted tree ----------------------------------------------------------------

new_case policy-tree
pr_event true
mkdir -p "$GITHUB_WORKSPACE/policy"
printf '{ "policyVersion": 1, "name": "weakened by the pull request" }\n' \
  >"$GITHUB_WORKSPACE/policy/agent-policy.json"
run_action AC_POLICY=./policy/agent-policy.json
p="$case_dir/out.prepare"
s="$case_dir/out.scan"
w=$(output work-dir "$p")
check "policy: from the trusted tree" test "$(output policy-source "$p")" = tree
check "policy: read at the base commit" test "$(output sha "$case_dir/out.policy-tree")" = "$base_sha"
check "policy: export-ignore turned off" test -f "$(output policy-root "$p")/policy/agent-policy.json"
check "policy: only the policy file exported" test ! -e "$(output policy-root "$p")/sub"
check "policy: head scans get the copy in the work directory" \
  jq -se --arg f "--policy=$w/policy/agent-policy.json" \
  '[.[] | select(.head) | .argv | any(. == $f)] | length == 3 and all' "$FAKE_LOG"
check "policy: base scan runs without it" \
  jq -se '.[0].head == false and (.[0].argv | any(startswith("--policy")) | not)' "$FAKE_LOG"
check "policy: report has the base version's digest" \
  jq -e --arg d "$policy_sha" '.policy.sha256 == $d and .policy.insideScanRoot == false' \
  "$(output report "$s")"
check "policy: the base version counts, not the pull request's" \
  test "$(output policy-violations "$s")" = 1
check "policy: failing violations fail the check" test "$result" -eq 1
check "policy: sha256 output" test "$(output sha256 "$case_dir/out.policy")" = "$policy_sha"
check "policy: summary has the commit" contains "$GITHUB_STEP_SUMMARY" "at \`$base_sha\` (the base commit)"
check "policy: summary has the digest" contains "$GITHUB_STEP_SUMMARY" "SHA-256 \`$policy_sha\`"
check "policy: summary notes the pull request's change" \
  contains "$GITHUB_STEP_SUMMARY" 'This pull request changes the policy; the check used the base version.'
check "policy: summary has the report's policy section" contains "$GITHUB_STEP_SUMMARY" '### Policy: base policy'
check "policy: no workflow warning without GITHUB_WORKFLOW_REF" lacks "$log" 'the workflow that runs this check'

new_case policy-unchanged
pr_event true
mkdir -p "$GITHUB_WORKSPACE/policy"
cp "$src/policy/agent-policy.json" "$GITHUB_WORKSPACE/policy/"
run_action AC_POLICY=policy/agent-policy.json
check "policy unchanged: no note" lacks "$GITHUB_STEP_SUMMARY" 'changes the policy'

new_case policy-symlink-in-workspace
pr_event true
mkdir -p "$GITHUB_WORKSPACE/policy"
cp "$src/policy/agent-policy.json" "$case_dir/elsewhere.json"
ln -s "$case_dir/elsewhere.json" "$GITHUB_WORKSPACE/policy/agent-policy.json"
run_action AC_POLICY=policy/agent-policy.json
check "policy symlinked in the pull request: counts as a change" \
  contains "$GITHUB_STEP_SUMMARY" 'This pull request changes the policy'

new_case policy-default-branch
run_action AC_POLICY=policy/agent-policy.json
check "policy on push: fetches the default branch" contains "$log" 'Fetching the default branch'
check "policy on push: resolved to its commit" test "$(output sha "$case_dir/out.policy-tree")" = "$base_sha"
check "policy on push: summary says so" contains "$GITHUB_STEP_SUMMARY" "at \`$base_sha\` (the default branch)"
check "policy on push: no change note" lacks "$GITHUB_STEP_SUMMARY" 'changes the policy'
check "policy on push: violations without a baseline fail" test "$result" -eq 1

new_case policy-audit
pr_event true
run_action AC_POLICY=policy/audit.json
s="$case_dir/out.scan"
check "audit: violations reported" \
  jq -e '.policy.mode == "audit" and (.policy.violations | length == 1 and all(.fails == false))' \
  "$(output report "$s")"
check "audit: policy-violations 0" test "$(output policy-violations "$s")" = 0
check "audit: never fails" test "$result" -eq 0

new_case policy-test-base-dir
d=$(base_dir base)
mkdir -p "$d/policy"
cp "$src/policy/agent-policy.json" "$d/policy/"
run_action "AC_TEST_BASE_DIR=$d" AC_POLICY=policy/agent-policy.json
check "policy with test-base-dir: read from it" test "$(output policy-source "$case_dir/out.prepare")" = dir
check "policy with test-base-dir: no fetch" test ! -e "$case_dir/out.policy-tree"
check "policy with test-base-dir: used" test "$(output policy-violations "$case_dir/out.scan")" = 1
check "policy with test-base-dir: summary" contains "$GITHUB_STEP_SUMMARY" 'from test-base-dir'

policy_refused() { # policy_refused NAME FILE MESSAGE: the run must stop with exit code 2
  new_case "policy-$1"
  pr_event true
  run_action "AC_POLICY=$2"
  check "policy $1: exit code 2" test "$result" -eq 2 -a "$(action_exit_code)" = 2
  check "policy $1: explains" contains "$log" "$3"
  check "policy $1: head not scanned" jq -se 'all(.head | not)' "$FAKE_LOG"
}
policy_refused symlink policy/link.json 'it is a symbolic link, not a regular file'
policy_refused directory policy/dir.json 'it is not a regular file'
policy_refused oversized policy/big.json 'the limit is 256 KiB'
policy_refused missing policy/missing.json 'Merge the policy file first, then the workflow that uses it.'

# Bootstrap: a pull request that adds the policy and the workflow at once is refused.
new_case policy-added-by-pull-request
pr_event true
mkdir -p "$GITHUB_WORKSPACE/policy"
cp "$src/policy/agent-policy.json" "$GITHUB_WORKSPACE/policy/new.json"
run_action AC_POLICY=policy/new.json
check "policy added by the pull request: exit code 2" test "$result" -eq 2
check "policy added by the pull request: bootstrap explained" contains "$log" 'Merge the policy file first'

new_case policy-escape
d=$(base_dir base)
mkdir -p "$tmp/outside-policy"
cp "$src/policy/agent-policy.json" "$tmp/outside-policy/"
ln -s "$tmp/outside-policy" "$d/policy"
run_action "AC_TEST_BASE_DIR=$d" AC_POLICY=policy/agent-policy.json
check "policy through a symlinked directory: refused" test "$result" -eq 2
check "policy through a symlinked directory: explains" contains "$log" 'symbolic link out of the tree'

new_case policy-invalid
pr_event true
run_action AC_POLICY=policy/invalid.json
check "invalid policy: exit code 2 from agentcheckup" test "$result" -eq 2 -a "$(action_exit_code)" = 2
check "invalid policy: agentcheckup's message in the log" contains "$log" 'Unknown field "forbidd"'

# --- Workflow changes ----------------------------------------------------------------------------

workflow_case() { # workflow_case NAME WORKFLOW_REF CONTENT(changed|same)
  new_case "workflow-$1"
  pr_event true
  export GITHUB_WORKFLOW_REF=$2
  mkdir -p "$GITHUB_WORKSPACE/.github/workflows"
  cp "$src/.github/workflows/check.yml" "$GITHUB_WORKSPACE/.github/workflows/check.yml"
  if [ "$3" = changed ]; then
    printf '# the policy input was removed here\n' >>"$GITHUB_WORKSPACE/.github/workflows/check.yml"
  fi
  run_action AC_POLICY=policy/agent-policy.json
}
workflow_case changed owner/repo/.github/workflows/check.yml@refs/pull/5/merge changed
check "workflow changed: warning" \
  contains "$log" '::warning title=agentcheckup::This pull request changes .github/workflows/check.yml'
check "workflow changed: in the summary" \
  contains "$GITHUB_STEP_SUMMARY" '**Warning:** This pull request changes .github/workflows/check.yml'
workflow_case same owner/repo/.github/workflows/check.yml@refs/pull/5/merge same
check "workflow unchanged: no warning" lacks "$log" 'the workflow that runs this check'
workflow_case central org/policies/.github/workflows/check.yml@refs/heads/main changed
check "workflow from another repository: no warning" lacks "$log" 'the workflow that runs this check'

# --- Central policy ------------------------------------------------------------------------------

new_case central-tag
pr_event true
policy_token=$central_token
: >"$tmp/git-argv.log"
: >"$tmp/git-env.log"
run_action AC_POLICY_REPOSITORY=org/policies AC_POLICY_PATH=agent-policy.json AC_POLICY_REF=v1
s="$case_dir/out.scan"
check "central: resolved the tag to its commit" test "$(output sha "$case_dir/out.policy-central")" = "$central_sha"
check "central: the central policy counts" test "$(output policy-violations "$s")" = 2
check "central: report has its digest" \
  jq -e --arg d "$central_policy_sha" '.policy.sha256 == $d' "$(output report "$s")"
check "central: summary names repository, commit and ref" \
  contains "$GITHUB_STEP_SUMMARY" "\`agent-policy.json\` from \`org/policies\` at \`$central_sha\` (ref v1)"
check "central: no pull request note" lacks "$GITHUB_STEP_SUMMARY" 'changes the policy'
check "central: token never on a git command line" lacks "$tmp/git-argv.log" "$central_token"
check "central: header in the environment of the fetch" \
  test "$(grep -c 'AUTHORIZATION: basic ' "$tmp/git-env.log")" -eq 2
check "central: token masked" contains "$log" "::add-mask::$central_token"
check "central: token never printed otherwise" test -z "$(unmasked "$log" "$central_token")"
check "central: token not in the summary" lacks "$GITHUB_STEP_SUMMARY" "$central_token"
check "central: token not written under RUNNER_TEMP" \
  test -z "$(grep -rlF -- "$central_token" "$RUNNER_TEMP" 2>/dev/null || true)"
check "central: no token in the CLI environment" jq -se 'all(.tokenInEnv | not)' "$FAKE_LOG"

new_case central-default-branch
run_action AC_POLICY_REPOSITORY=org/policies AC_POLICY_PATH=agent-policy.json
check "central default branch: resolved" test "$(output sha "$case_dir/out.policy-central")" = "$central_sha"
check "central default branch: summary" contains "$GITHUB_STEP_SUMMARY" '(the default branch)'
check "central default branch: violations without a baseline fail" test "$result" -eq 1

new_case central-pinned
pr_event false
run_action AC_POLICY_REPOSITORY=org/policies AC_POLICY_PATH=agent-policy.json "AC_POLICY_REF=$central_sha"
check "central pinned: works for forks when public" test "$(output policy-violations "$case_dir/out.scan")" = 2
check "central pinned: summary" contains "$GITHUB_STEP_SUMMARY" '(a pinned commit)'

new_case central-private-fork
pr_event false
run_action AC_POLICY_REPOSITORY=private/policies AC_POLICY_PATH=agent-policy.json
check "central private, fork: exit code 2" test "$result" -eq 2 -a "$(action_exit_code)" = 2
check "central private, fork: explains" \
  contains "$log" 'Pull requests from forks get no secrets. Make the policy repository public, or use input `policy`.'
check "central private, fork: head not scanned" jq -se 'all(.head | not)' "$FAKE_LOG"

new_case central-private-no-token
pr_event true
run_action AC_POLICY_REPOSITORY=private/policies AC_POLICY_PATH=agent-policy.json
check "central private, no token: exit code 2" test "$result" -eq 2
check "central private, no token: asks for policy-token" contains "$log" 'set input policy-token'

new_case central-private-token
pr_event true
policy_token=$central_token
run_action AC_POLICY_REPOSITORY=private/policies AC_POLICY_PATH=agent-policy.json AC_POLICY_REF=main
check "central private, token: fetched" test "$(output sha "$case_dir/out.policy-central")" = "$central_sha"
check "central private, token: policy applies" test "$(output policy-violations "$case_dir/out.scan")" = 2
check "central private, token: never printed" test -z "$(unmasked "$log" "$central_token")"

new_case central-missing
pr_event true
run_action AC_POLICY_REPOSITORY=org/policies AC_POLICY_PATH=nope.json
check "central missing file: exit code 2" test "$result" -eq 2
check "central missing file: explains" contains "$log" 'The file nope.json is not in'

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

# comment: on-change. on_change NAME SCENARIO FAKE_GH WANT(create|update|none) [inputs...]
on_change() {
  local name=$1 scenario=$2 gh=$3 want=$4
  shift 4
  new_case "on-change-$name"
  pr_event true
  export FAKE_SCENARIO=$scenario FAKE_GH=$gh
  run_action AC_COMMENT=on-change "$@"
  case $want in
    create)
      check "on-change $name: creates the comment" \
        contains "$FAKE_GH_LOG" '--method POST repos/owner/repo/issues/5/comments'
      ;;
    update)
      check "on-change $name: updates the comment" \
        contains "$FAKE_GH_LOG" '--method PATCH repos/owner/repo/issues/comments/42'
      check "on-change $name: creates none" lacks "$FAKE_GH_LOG" '--method POST'
      ;;
    none)
      check "on-change $name: creates none" lacks "$FAKE_GH_LOG" '--method POST'
      check "on-change $name: says why" contains "$log" 'nothing in this report needs review'
      ;;
  esac
}
on_change gate gate empty create
on_change gate-existing gate existing update
on_change new-findings findings empty create
on_change new-skips skips empty create
on_change not-read not-read empty none
on_change clean clean empty none
on_change clean-existing clean existing update
on_change policy clean empty create AC_POLICY=policy/agent-policy.json
on_change policy-audit clean empty none AC_POLICY=policy/audit.json

# --- Suggestions ---------------------------------------------------------------------------------

new_case suggest
pr_event true
export FAKE_GH_REVIEW_COMMENTS="$tmp/review-comments.json"
run_action AC_SUGGEST=true
w=$(output work-dir "$case_dir/out.prepare")
review="$FAKE_GH_LOG.review.json"
check "suggest: check result unchanged" test "$result" -eq 0
check "suggest: head commit exported" test "$(output sha "$case_dir/out.head")" = "$head_sha"
check "suggest: head tree is the head commit" contains "$w/head/sub/CLAUDE.md" 'Head line.'
check "suggest: CLI runs once, on the head tree" \
  jq -se --arg d "$w/head" 'map(select(.fix)) | length == 1 and .[0].cwd == $d and .[0].argv[-2:] == ["--", "."]' \
  "$FAKE_LOG"
check "suggest: diff fetched as a diff" \
  contains "$FAKE_GH_LOG" 'api -H Accept: application/vnd.github.diff repos/owner/repo/pulls/5'
check "suggest: one review on the head commit" \
  jq -e --arg sha "$head_sha" '.commit_id == $sha and .event == "COMMENT" and (.body | length > 0)' "$review"
check "suggest: posts only markers not yet posted, matched on the last line" \
  jq -e '[.comments[].body | split("\n") | last] == [
    "<!-- agentcheckup-suggestion claude-code/fake-rule bbbbbbbbbbbb -->",
    "<!-- agentcheckup-suggestion claude-code/fake-rule dddddddddddd -->"]' "$review"
check "suggest: hostile body posted whole" \
  jq -e '.comments[1].body | contains("cccccccccccc")' "$review"
check "suggest: keeps line ranges" \
  jq -e '.comments[0] | .start_line == 1 and .line == 2 and .side == "RIGHT" and .start_side == "RIGHT"' "$review"
check "suggest: deletes an outdated suggestion" \
  contains "$FAKE_GH_LOG" '--method DELETE repos/owner/repo/pulls/comments/102'
check "suggest: deletes one whose marker only appears inside a new body" \
  contains "$FAKE_GH_LOG" '--method DELETE repos/owner/repo/pulls/comments/105'
check "suggest: keeps a suggestion still made" lacks "$FAKE_GH_LOG" 'pulls/comments/101'
check "suggest: leaves other logins alone" lacks "$FAKE_GH_LOG" 'pulls/comments/103'
check "suggest: a marker inside a body is no marker" lacks "$FAKE_GH_LOG" 'pulls/comments/104'
check "suggest: leaves comments outside the path alone" lacks "$FAKE_GH_LOG" 'pulls/comments/106'
check "suggest: summary line" contains "$GITHUB_STEP_SUMMARY" \
  'Suggestions: 2 posted, 1 already on the pull request, 2 outdated removed. 2 outside the scanned path or unusable.'
check "suggest: no token in the CLI environment" jq -se 'all(.tokenInEnv | not)' "$FAKE_LOG"
check "suggest: token never printed" test -z "$(unmasked "$log" "$token")"

new_case suggest-422
pr_event true
export FAKE_GH_REVIEW=422
run_action AC_SUGGEST=true
check "suggest 422: notice" contains "$log" 'did not accept the suggestions (HTTP 422)'
check "suggest 422: check passes" test "$result" -eq 0

new_case suggest-denied
pr_event true
export FAKE_GH_REVIEW=deny
run_action AC_SUGGEST=true
check "suggest denied: notice" contains "$log" 'Could not post the suggestions'
check "suggest denied: check passes" test "$result" -eq 0

new_case suggest-gate
pr_event true
export FAKE_SCENARIO=gate FAKE_SUGGEST=crash
run_action AC_SUGGEST=true
check "suggest crash: notice" contains "$log" 'could not make suggestions (exit code 3)'
check "suggest crash: the gate still decides" test "$result" -eq 1
check "suggest crash: nothing posted" test ! -e "$FAKE_GH_LOG.review.json"

new_case suggest-usage-error
pr_event true
export FAKE_SUGGEST=error
run_action AC_SUGGEST=true
check "suggest exit 2: notice" contains "$log" 'could not make suggestions (exit code 2)'
check "suggest exit 2: check passes" test "$result" -eq 0
check "suggest exit 2: deletes nothing" lacks "$FAKE_GH_LOG" 'DELETE'

new_case suggest-garbage
pr_event true
export FAKE_SUGGEST=garbage
run_action AC_SUGGEST=true
check "suggest unreadable output: notice" contains "$log" 'no readable suggestions'
check "suggest unreadable output: check passes" test "$result" -eq 0

new_case suggest-diff-large
pr_event true
export FAKE_GH_DIFF=large
run_action AC_SUGGEST=true
check "suggest diff too large: notice" contains "$log" 'diff is too large'
check "suggest diff too large: CLI not run" jq -se 'all(.fix | not)' "$FAKE_LOG"
check "suggest diff too large: check passes" test "$result" -eq 0

new_case suggest-diff-failed
pr_event true
export FAKE_GH_DIFF=fail
run_action AC_SUGGEST=true
check "suggest diff failed: notice" contains "$log" 'Could not fetch the pull request diff'
check "suggest diff failed: check passes" test "$result" -eq 0

new_case suggest-bad-comments
pr_event true
printf 'not json\n' >"$case_dir/comments.txt"
export FAKE_GH_REVIEW_COMMENTS="$case_dir/comments.txt"
run_action AC_SUGGEST=true
check "suggest unreadable comments: notice" contains "$log" 'Could not read the suggestions or the review comments'
check "suggest unreadable comments: nothing deleted or posted" \
  test ! -e "$FAKE_GH_LOG.review.json" -a -z "$(grep -F DELETE "$FAKE_GH_LOG" || true)"
check "suggest unreadable comments: check passes" test "$result" -eq 0

new_case suggest-head-missing
pr_event true
jq '.pull_request.head.sha = "0000000000000000000000000000000000000002"' "$GITHUB_EVENT_PATH" \
  >"$case_dir/event2.json"
mv "$case_dir/event2.json" "$GITHUB_EVENT_PATH"
run_action AC_SUGGEST=true
check "suggest head missing: notice" contains "$log" 'Could not fetch the head commit'
check "suggest head missing: suggest step skips" contains "$log" 'The head commit was not exported'
check "suggest head missing: no exit-code from the head step" test -z "$(output exit-code "$case_dir/out.head")"
check "suggest head missing: check passes" test "$result" -eq 0

new_case suggest-fork
pr_event false
run_action AC_SUGGEST=true
check "suggest fork: notice" contains "$log" 'cannot write review comments'
check "suggest fork: skipped" test ! -e "$case_dir/out.head" -a ! -e "$FAKE_GH_LOG"
check "suggest fork: check passes" test "$result" -eq 0

new_case suggest-unexpected
pr_event true
got=0
step head export-tree "AC_WORK=$RUNNER_TEMP" AC_TREE_KIND=head "AC_TREE_REF=$head_sha" \
  "AC_TREE_DEST=$case_dir/missing/head" "AC_TOKEN=$token" || got=$?
step suggest suggest "AC_WORK=$case_dir/missing" AC_CLI=none AC_PATH=sub AC_PR_NUMBER=5 \
  "AC_HEAD_SHA=$head_sha" "AC_HEAD_ROOT=$case_dir/missing" "AC_HEAD_EXPORTED=$head_sha" \
  "GH_TOKEN=$token" || got=$?
check "suggest: unexpected errors end with status 0" test "$got" -eq 0
check "suggest: unexpected errors are notices" \
  test "$(grep -c 'They never fail the check.' "$log")" -eq 2
check "suggest: unexpected errors record no exit code" \
  test -z "$(output exit-code "$case_dir/out.head")$(output exit-code "$case_dir/out.suggest")"

new_case suggest-push
run_action AC_SUGGEST=true
check "suggest on push: notice" contains "$log" 'suggest: true only applies to pull_request'
check "suggest on push: skipped" test ! -e "$case_dir/out.head"

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
