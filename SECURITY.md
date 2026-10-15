# Security Policy

This action follows the security policy of agentcheckup:
[mustafakbaser/agentcheckup/SECURITY.md](https://github.com/mustafakbaser/agentcheckup/blob/main/SECURITY.md).

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Use GitHub's private vulnerability reporting in the main repository:
[Report a vulnerability](https://github.com/mustafakbaser/agentcheckup/security/advisories/new).
Say that the report is about the GitHub Action, and include the action version or commit.

In scope for this repository, among others:

- The token reaching a process, file, log line or command line it should not reach
- Code or configuration from the scanned repository being run, or shadowing agentcheckup
- A pull request choosing its own baseline, or hiding a change from the gate
- Files written outside the work directory, the workspace or the requested SARIF path
- Workflow command or Markdown injection through the summary, annotations or the comment

## Supported versions

The latest release of the action receives fixes. Pin a release and update it with Dependabot.
