# agentcheckup-action

[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-agentcheckup-blue?logo=github)](https://github.com/marketplace/actions/agentcheckup)
[![agentcheckup on npm](https://img.shields.io/npm/v/agentcheckup?label=agentcheckup)](https://www.npmjs.com/package/agentcheckup)
[![Test](https://github.com/mustafakbaser/agentcheckup-action/actions/workflows/test.yml/badge.svg)](https://github.com/mustafakbaser/agentcheckup-action/actions/workflows/test.yml)

The GitHub Action for [agentcheckup](https://github.com/mustafakbaser/agentcheckup). It checks
the coding-agent configuration in a pull request: `AGENTS.md`, `CLAUDE.md`, skills, Cursor rules,
MCP servers, hooks, permissions and env overrides.

On a pull request it compares the head with the base commit and reports:

- new findings, as annotations on the changed files;
- security-relevant changes (the gate): a new or unpinned MCP server, a broader permission, a new
  hook, an endpoint or TLS env override, hidden Unicode;
- what each agent loads, and how that changed.

The report goes to the job summary, and optionally to SARIF and a pull request comment. The
check fails when there are new findings at or above `fail-on`, or when the gate trips.
Optionally, it checks the repository against an [organization policy](#organization-policy)
read from a trusted tree, and posts agentcheckup's safe fixes as
[suggested changes](#suggested-fixes).

## Quick start

`.github/workflows/agentcheckup.yml`:

```yaml
name: agentcheckup

on:
  pull_request:
  push:
    branches: [main]

permissions: {}

jobs:
  agentcheckup:
    name: agentcheckup
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read # check out the repository and fetch the base commit
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1 # v7.1.0
        with:
          node-version: 24
      - uses: mustafakbaser/agentcheckup-action@v0.1.0
```

Run the action right after checkout, before steps that install or build anything. It scans the
workspace as it finds it, and generated files would show up as changes.

Release tags are immutable. For a stricter pin, use the release's full commit SHA with the tag in
a comment, `@<commit-sha> # v0.1.0`; Dependabot updates both. `@v0` follows the latest `0.x`
release without review. [docs/releasing.md](docs/releasing.md) explains the tags.

agentcheckup needs Node.js 22.12 or later. `actions/setup-node` makes sure of that.

## Inputs

| Input               | Default               | Description                                                                                                                                                                                      |
| ------------------- | --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `version`           | pinned by the release | Exact agentcheckup version, such as `0.1.0`. Ranges and tags such as `^0.1.0` or `latest` are rejected. The default is the version this release of the action was tested with; see `action.yml`. |
| `path`              | `.`                   | Directory to scan, relative to the repository root. No `..`.                                                                                                                                     |
| `gate`              | `security`            | Changes that fail the check on pull requests: `security` (all classes), `none`, or a comma-separated list of [gate classes](#gate-classes).                                                      |
| `fail-on`           | `error`               | Fail on new findings at or above this severity: `error`, `warn`, `info` or `none`.                                                                                                               |
| `sarif-file`        | empty                 | Also write SARIF to this path, for upload to code scanning. Relative paths start at the workspace. The directory must exist inside the workspace or `runner.temp`.                               |
| `comment`           | `false`               | Pull request comment with the report: `true`, `on-change` or `false`. See [Pull request comment](#pull-request-comment). Needs `pull-requests: write`. Skipped for forks.                        |
| `suggest`           | `false`               | Post safe fixes as one review with suggested changes. See [Suggested fixes](#suggested-fixes). Needs `pull-requests: write`. Same-repository pull requests only. Never fails the check.          |
| `policy`            | empty                 | Path of a policy file in this repository, read from the trusted tree, never from the pull request. See [Organization policy](#organization-policy). Not with `policy-repository`.                |
| `policy-repository` | empty                 | `owner/name` of a central repository on the same GitHub server that holds the policy. Use with `policy-path`. Not with `policy`.                                                                 |
| `policy-path`       | empty                 | Path of the policy file in `policy-repository`.                                                                                                                                                  |
| `policy-ref`        | default branch        | Branch, tag or full commit SHA of `policy-repository`. A commit SHA pins the policy.                                                                                                             |
| `policy-token`      | empty                 | Token that can read a private `policy-repository` (`contents: read`). Used only by the one fetch of the policy.                                                                                  |
| `targets`           | all                   | Comma-separated agents to check against, for example `claude-code,codex,cursor`.                                                                                                                 |
| `token`             | `github.token`        | Used only to fetch the base commit, the head commit and a `policy` from this repository, and to write the comment and suggestions. agentcheckup never sees it.                                   |
| `test-package`      | empty                 | Test only. See [Testing](#testing).                                                                                                                                                              |
| `test-base-dir`     | empty                 | Test only. See [Testing](#testing).                                                                                                                                                              |

Policy paths may hold letters, digits, `.`, `_`, `-`, `+`, `@` and `/`, and no `..`.

## Outputs

| Output              | Description                                                                                                                                                                     |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `exit-code`         | agentcheckup's exit code. See [Exit codes](#exit-codes).                                                                                                                        |
| `gate-hits`         | Number of gate hits, one per change and class: a new unpinned server counts under both `mcp` and `mcp-unpinned`, while the summary shows it as one row. `0` without a baseline. |
| `new-findings`      | Number of findings not in the baseline. Without a baseline, every finding counts. Empty on errors.                                                                              |
| `policy-violations` | Number of policy violations that fail the run. `0` without a policy and in audit mode. Empty on errors.                                                                         |
| `report`            | Path of the JSON report, in `runner.temp`. Empty when no report was written.                                                                                                    |

The action fails after it has written all outputs, the job summary, the SARIF file and the
comment. To read the outputs of a failed run, give the step an `id` and
`continue-on-error: true`.

## Exit codes

| Code | Meaning                                                                                                                                |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------- |
| 0    | No new findings at or above `fail-on`, the gate did not trip, and no policy violation fails the run.                                   |
| 1    | New findings at or above `fail-on`, the gate tripped, or a policy violation fails the run.                                             |
| 2    | Invalid usage or configuration, or the action could not run (inputs, install, base commit, a missing, refused or invalid policy file). |
| 3    | Internal error in agentcheckup.                                                                                                        |

The step fails with the same code. Suggestions and the comment never change it.

## Gate classes

The gate looks at changes between the base commit and the head. Removals never trip it.

| Class          | Trips when                                                                                                                                                   |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `mcp`          | An MCP server is added or changed, or a new MCP config file cannot be parsed.                                                                                |
| `mcp-unpinned` | An added or changed MCP server runs a package that is not pinned to an exact version or digest.                                                              |
| `permissions`  | A broad or auto-approving permission is added, or `defaultMode` changes.                                                                                     |
| `hooks`        | A hook is added or changed.                                                                                                                                  |
| `env`          | An env override that sets an endpoint, a credential, TLS behavior or code execution is added or changed, for example `ANTHROPIC_BASE_URL` or `NODE_OPTIONS`. |
| `unicode`      | A new hidden-Unicode finding appears.                                                                                                                        |

## Events

| Event                                        | What the action does                                                                          |
| -------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `pull_request`                               | Compares the head with `pull_request.base.sha`. Findings and the gate count only new changes. |
| `merge_group`                                | Compares with `merge_group.base_sha`, so the check also works with a merge queue.             |
| `push`, `workflow_dispatch` and other events | Scans without a baseline. Every finding counts and the gate does not apply.                   |
| `pull_request_target`                        | Refused with exit code 2.                                                                     |

**Why not `pull_request_target`.** That event runs in the context of the base repository with a
write token and access to secrets, even for pull requests from forks. A workflow that checks out
and reads the pull request there hands untrusted content to a privileged job. This action reads
pull request content, so it only runs on `pull_request`, where a fork gets a read-only token and
no secrets.

## How it works

1. **Check inputs.** `version` must be an exact version. `path` must stay inside the repository.
   Input values are passed to scripts as environment variables, never as shell code.
2. **Install.** `npm install agentcheckup@<version>` runs in a new directory under
   `runner.temp`. The repository's `.npmrc`, `package.json` and `node_modules` play no part, so a
   package committed to the repository cannot replace agentcheckup.
3. **Export the base commit** (pull requests and merge groups). A new bare repository under
   `runner.temp` fetches only the base commit: `git fetch --depth=1 --no-tags` of
   `pull_request.base.sha`, read from the event payload. `git archive | tar -x` writes its tree to
   `runner.temp`. Nothing from it runs. This works however the workspace was checked out,
   including with `persist-credentials: false`, and git never runs inside the checkout.
   `export-ignore` and `export-subst` are turned off, so the base branch's `.gitattributes` cannot
   hide files from the baseline.
4. **Export the policy** (with `policy` or `policy-repository`). The same export, limited to
   one file with `git archive <sha> -- <path>`, from the trusted tree or the central repository.
   The file is checked and copied into `runner.temp`; see [Organization policy](#organization-policy).
5. **Scan the base** with `--untrusted --no-gitignore --context --format json`. This report is
   the baseline. The action never reads a baseline from the pull request.
6. **Scan the head** with `--untrusted --no-gitignore --context --baseline <base.json>
--gate <gate> --fail-on <fail-on>`, and `--policy <file>` when there is a policy.
7. **Suggest** (with `suggest: true`). Export the head commit, fetch the diff, run
   `agentcheckup fix --untrusted --format suggestions` on the head tree, post one review.
8. **Report.** Job summary, outputs, SARIF and comment, then the step fails with the exit code.

agentcheckup writes one format per run, so the head is scanned once per format: JSON (its exit
code is the result), Markdown, SARIF when requested, and GitHub annotations into the log. With
the base scan that is four or five runs on a pull request, and three or four otherwise. Scans
are deterministic and usually take well under a second each.

Each scan runs with the scanned tree's root as its working directory, and the CLI is started
by absolute path with `node`. agentcheckup reports paths relative to its working directory, and
annotations and SARIF need paths relative to the repository root. Running `npx` from
`runner.temp` would give paths such as `../repo/repo/.mcp.json`. Running `npx` in the checkout
would let the repository's `.npmrc` and `node_modules/.bin` (including a fake `node`) take part.
Installing once into `runner.temp` and running `node <path>` avoids both.

`--untrusted` ignores the repository's agentcheckup config and inline suppressions.
`--no-gitignore` scans files that `.gitignore` lists, so a pull request cannot hide a committed
`.mcp.json` by adding it to `.gitignore`. The checkout only holds committed files.

## Requiring the check, and CODEOWNERS

Make the check required in a branch ruleset ("Require status checks to pass", check name
`agentcheckup`, the job name). Then pair it with code owners for agent configuration, and turn
on "Require review from Code Owners" in the same ruleset:

```text
# .github/CODEOWNERS
/.mcp.json              @your-org/agent-config
/.claude/               @your-org/agent-config
/.cursor/               @your-org/agent-config
/.codex/                @your-org/agent-config
/.agents/               @your-org/agent-config
/.vscode/mcp.json       @your-org/agent-config
/.github/copilot-instructions.md @your-org/agent-config
/.github/instructions/  @your-org/agent-config
/.github/workflows/     @your-org/agent-config
AGENTS.md               @your-org/agent-config
AGENTS.override.md      @your-org/agent-config
CLAUDE.md               @your-org/agent-config
CLAUDE.local.md         @your-org/agent-config
SKILL.md                @your-org/agent-config
.cursorrules            @your-org/agent-config
```

Patterns without a leading `/` match at any depth.

A tripped gate fails the required check, so a security-relevant change cannot merge silently.
When a code owner has reviewed and accepts such a change, someone allowed to bypass the ruleset
merges it. If you prefer review alone to block merging, leave the check optional: code owner
review is then the gate, and the failing check shows the reviewer what changed.

## Organization policy

An [agentcheckup policy](https://github.com/mustafakbaser/agentcheckup/blob/main/docs/policy.md)
sets rules a repository must follow: allowed MCP servers, forbidden settings, denied tools and
commands, required hooks and startup token budgets. A violation fails the run with exit code 1,
unless the policy has `"mode": "audit"`, which reports violations and never fails. With a
baseline and `"existing": "report"`, only violations the pull request adds fail.

A policy only means something if the change under review cannot edit it, so the action never
reads it from the workspace.

### From this repository

```yaml
- uses: mustafakbaser/agentcheckup-action@v0.1.0
  with:
    policy: .github/agentcheckup-policy.json
```

The action reads the file from the trusted tree: the base commit on `pull_request` and
`merge_group`, the default branch on other events. It exports only that file, as for the base
commit, with `git archive <sha> -- <path>`.

- **Bootstrap.** The file must exist in the trusted tree first. A pull request that adds the
  policy and the workflow at once fails with exit code 2: merge the policy file first, then the
  workflow that uses it.
- **Changes.** When a pull request changes the policy file, the check still uses the base
  version, and the job summary says "This pull request changes the policy; the check used the
  base version." The new version applies once it is merged.

### From a central repository

```yaml
- uses: mustafakbaser/agentcheckup-action@v0.1.0
  with:
    policy-repository: acme/agent-policy
    policy-path: agentcheckup-policy.json
    # A full commit SHA pins the policy. A branch or tag also works; the default is the
    # repository's default branch.
    policy-ref: 0123456789abcdef0123456789abcdef01234567
    policy-token: ${{ secrets.AGENT_POLICY_TOKEN }} # only for a private repository
```

The policy is fetched into `runner.temp` by one `git fetch` of that ref, on the same GitHub
server. `policy-token` reaches that fetch only, as an `http.extraheader` in environment
variables: not on a command line, not in a file, masked in the log. A public policy repository
needs no token, which also makes it work for forks.

### Checks on the file

- The file must be a regular file of at most 256 KiB. A symbolic link, a directory, or a path
  through a symbolic link is refused with exit code 2.
- A file missing from the trusted tree, or one agentcheckup cannot read as a policy, stops the
  run with exit code 2.
- The job summary shows where the policy came from, the commit it resolved to, and its SHA-256,
  which equals `shasum -a 256` of the file and the `policy.sha256` field of the JSON report.
- When a pull request changes the workflow that runs the check (`GITHUB_WORKFLOW_REF`), the
  action adds a warning to the log and the job summary: that pull request also chooses the
  check's inputs, the policy among them.

### Enforcing it

A required status check alone can be spoofed: a pull request can edit the workflow that runs it,
for example to drop the `policy` input, and the check still passes under the same name. To
enforce a policy:

- require the workflow with an organization or repository ruleset ("Require workflows to pass
  before merging") that runs it from a central repository at a pinned ref, so pull requests in
  the checked repository cannot change it; or
- protect `.github/workflows/` with CODEOWNERS and required code owner review, as above.

The warning about a changed workflow is defense in depth, not a substitute.

## Pull requests from forks

A pull request from a fork gets a read-only token and no secrets.

| Feature                                          | On a fork pull request                                                                                            |
| ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------- |
| Findings, the gate, annotations, the job summary | Yes. The base commit comes from the base repository with the read-only token.                                     |
| `policy` (from the base commit)                  | Yes.                                                                                                              |
| `policy-repository`, public                      | Yes, fetched without a token.                                                                                     |
| `policy-repository`, private                     | Exit code 2: "Pull requests from forks get no secrets. Make the policy repository public, or use input `policy`." |
| `comment`                                        | Skipped with a notice: the token cannot write.                                                                    |
| `suggest`                                        | Skipped with a notice: the token cannot write.                                                                    |
| SARIF upload                                     | Needs `security-events: write`, which forks do not get. Skip the upload step for forks, as in the example below.  |

Require approval for workflow runs from outside contributors (Settings, Actions, General).

**No `workflow_run` relay.** A common way to comment on fork pull requests is a second workflow,
triggered by `workflow_run`, that reads an artifact the fork's run uploaded and writes with a
privileged token. The fork's run controls that artifact, so the privileged workflow would post,
or act on, whatever a forged artifact says. This action does not offer such a relay: on forks,
the job summary and the annotations are the report.

## Code scanning (SARIF)

```yaml
permissions:
  contents: read # check out the repository and fetch the base commit
  security-events: write # upload SARIF
steps:
  # checkout and setup-node as in the quick start
  - uses: mustafakbaser/agentcheckup-action@v0.1.0
    id: agentcheckup
    with:
      sarif-file: ${{ runner.temp }}/agentcheckup.sarif
  - if: >-
      !cancelled() && (github.event_name != 'pull_request' ||
      github.event.pull_request.head.repo.full_name == github.repository)
    uses: github/codeql-action/upload-sarif@24c54180a607b1449ed407dd24f251e4e9147c8d # v4.38.3
    with:
      sarif_file: ${{ runner.temp }}/agentcheckup.sarif
```

Write the SARIF file to `runner.temp`, not into the checkout. When a scan fails, the action
removes any file at `sarif-file`, so the upload cannot pick up a stale or planted one.

## Pull request comment

```yaml
permissions:
  contents: read # check out the repository and fetch the base commit
  pull-requests: write # create or update the agentcheckup comment
steps:
  # checkout and setup-node as in the quick start
  - uses: mustafakbaser/agentcheckup-action@v0.1.0
    with:
      comment: true
```

The action keeps one comment per pull request, found by the hidden marker
`<!-- agentcheckup-action -->` on a comment by the token's own login. It uses the `gh` CLI with
the body in a file. Long reports are cut to fit GitHub's comment limit. When the comment cannot
be written, for example on a fork or without `pull-requests: write`, the action writes a notice
and the run continues.

| `comment`   | What the action does                                                                                                                                                                                                                                                       |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `false`     | No comment.                                                                                                                                                                                                                                                                |
| `true`      | Creates the comment, or updates it, on every run.                                                                                                                                                                                                                          |
| `on-change` | Creates the comment only when the JSON report shows something to review: gate hits, new findings, policy violations that fail the run, or files this change makes an agent skip ("What this change makes each agent miss"). Otherwise it only updates an existing comment. |

With `on-change`, a pull request that never needed review gets no comment. Once a comment
exists, every later run updates it, so it never shows a stale result.

## Suggested fixes

```yaml
permissions:
  contents: read # check out the repository and fetch the base and head commits
  pull-requests: write # read the diff, post and clean up suggestions
steps:
  # checkout and setup-node as in the quick start
  - uses: mustafakbaser/agentcheckup-action@v0.1.0
    with:
      suggest: true
```

With `suggest: true`, the action posts agentcheckup's safe fixes as one pull request review
with suggested changes, on lines the pull request changes. Reviewers apply them with GitHub's
"Commit suggestion" button.

1. It exports the head commit, `pull_request.head.sha`, like the base commit. The checkout is
   usually a merge commit, whose line numbers can differ from the head's.
2. It fetches the pull request's diff with
   `gh api -H 'Accept: application/vnd.github.diff'`.
3. It runs `agentcheckup fix --untrusted --format suggestions --diff <file>` on the head tree.
   Only `safe` fixes are suggested, one verified round, and only on lines inside the diff;
   agentcheckup makes at most 50 comments. Comments outside `path` are dropped.
4. Each comment body ends with a marker line,
   `<!-- agentcheckup-suggestion <rule ids> <hash> -->`. The action compares markers on the
   last line of a body only, because the suggested lines are repository text and may contain
   marker-like text. A suggestion whose marker is already on a review comment by the token's
   login is not posted again. Such a comment whose marker the run no longer produces, because
   the line changed or the fix was applied, is deleted.
5. It posts the rest as one review with `event: COMMENT` and `commit_id` set to the head SHA.

Suggestions never fail the check. A fork pull request, a diff too large for the API, an
agentcheckup error (exit code 2 or 3), a rejected review (HTTP 422, for example when the pull
request moved on during the run) or a missing permission each end with a notice. Suggestions
run only on `pull_request` events from the same repository.

## Security

- The action never runs code from the scanned repository. It does not use `npx` or anything else
  that resolves from the checkout. Only the agentcheckup process runs with the checkout as its
  working directory, started by absolute path.
- The baseline is built by the action from the base commit, and the policy comes from the
  base commit, the default branch or a central repository. Neither is ever read from the pull
  request.
- `token` reaches the export steps (base commit, head commit, a `policy` from this repository)
  and the comment and suggestion steps, nothing else. Each export gives it to one `git fetch` as
  an `http.extraheader` in `GIT_CONFIG_*` environment variables: it is not written to any git
  config, not put on a command line, and both the token and the encoded header are masked. The
  comment and suggestion steps give it to `gh`; agentcheckup runs without it. `policy-token`
  reaches only the one fetch of the central policy, the same way, and never reaches the
  preparing step. The install and scan steps have no token.
- Suggestions are compared by the marker on the last line of each comment body, so text in the
  suggested lines cannot hide a suggestion or keep an outdated one alive.
- `version` must be an exact version. npm checks the package's integrity.
- All shell variables are quoted. Scripts use `set -euo pipefail`. No `${{ }}` expression
  appears inside a `run:` script.
- The action uses no other actions. The workflows in this repository pin every action to a full
  commit SHA and are checked with [zizmor](https://docs.zizmor.sh) in pedantic mode.
- agentcheckup escapes scanned text in annotations, Markdown and SARIF. The action also turns
  workflow commands off while the JSON, Markdown and SARIF runs execute.
- The action writes only to a new directory under `runner.temp`, to the job summary, and to
  `sarif-file`. It never writes `sarif-file` through a symlink. On GitHub, it writes only the
  comment and the suggestions, and deletes only its own outdated suggestions.

If you restrict actions to an allowlist, add `mustafakbaser/agentcheckup-action`. With
`step-security/harden-runner` in block mode, allow `registry.npmjs.org:443` (install),
`github.com:443` (base and head commits, policy) and `api.github.com:443` (comment, diff and
suggestions).

Report vulnerabilities as described in [SECURITY.md](SECURITY.md).

## Requirements

- A Linux or macOS runner with bash, git 2.31 or later, jq, tar, Node.js 22.12 or later and npm.
  GitHub-hosted runners have them; use `actions/setup-node` for Node.js. The comment and the
  suggestions need `gh`; a policy needs `sha256sum` or `shasum`.
- The repository checked out at the workspace root, which is the `actions/checkout` default.
- agentcheckup 0.1.0 or later: earlier versions do not have `--context`, `--baseline`, `--gate`,
  `--policy` and `fix --format suggestions`.

Windows runners are not supported.

## Testing

- `test/scripts.sh` runs the scripts locally with a fake agentcheckup (`test/fake-cli.mjs`), a
  fake `gh` and a git server reached through `file://`, with a central policy repository and a
  "private" one that refuses fetches without a token. It covers input validation, the base,
  head and policy exports and token handling, the policy checks (trusted tree, central
  repository, symlinks, size, bootstrap, forks, audit mode, changed policy and workflow),
  outputs, exit codes, the summary size limit, SARIF handling, the comment modes and the
  suggestions (last-line markers, hostile bodies, outdated comments, 422 and other failures).
  No network.
- `.github/workflows/test.yml` runs the action itself on the fixtures in `test/fixtures`. The
  head adds an unpinned MCP server, a broad permission and an `ANTHROPIC_BASE_URL` override. The
  test checks that the gate trips with exit code 1, that an unchanged pair passes with 0, and
  that invalid inputs fail with 2.

The "Action with a packed CLI" job builds agentcheckup from source at `AGENTCHECKUP_REF` in the
workflow, the commit of the release `action.yml` pins, and hands the tarball to the action through
two test-only inputs:

- `test-package`: absolute path to an agentcheckup `.tgz`, installed instead of the npm release.
- `test-base-dir`: absolute path to a directory used as the base tree instead of the pull
  request's base commit, so the test can choose both trees. With `policy`, the policy is read
  from it too.

Both inputs only accept paths inside `runner.temp`. The workspace holds pull request content, and
accepting paths there would let a pull request choose the code that runs or its own baseline. The
"Action with the npm release" job runs the default `version` from npm and passes once that
version is published.

## License

[MIT](LICENSE)
