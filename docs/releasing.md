# Releasing

## Tags

Each release has two kinds of tag:

- An exact tag, `vX.Y.Z`, with a GitHub release. It never moves.
- A major tag, `v0`, moved to the latest `0.x` release. It has no release of its own.

Users who want a fixed version pin `@vX.Y.Z` or, stricter, the full commit SHA with the tag in a
comment. Users who want updates without changing their workflow pin `@v0`.

The action's version and the agentcheckup version are separate. Each action release pins one
agentcheckup version as the default of the `version` input. Changing that default is at least a
patch release of the action. Before 1.0, a change that alters exit codes, inputs or outputs is a
minor release.

## Immutable releases

GitHub's immutable releases lock a published release: its tag cannot move or be deleted and its
assets cannot change. Turn them on for this repository.

- An exact tag is then as safe as a SHA pin: nobody, the maintainer included, can point
  `@v0.1.0` at different code.
- `v0` is not attached to a release, so it can still move. That is what makes it useful, and
  also what makes it weaker: whoever can push tags can change what `@v0` runs for every user.
- A tag ruleset that blocks updates and deletions must target `v*.*.*` only. A `v*` pattern, as in
  the agentcheckup repository, would also freeze `v0`.
- A mistake in a published release cannot be fixed in place. Publish a new patch release and move
  `v0` to it.

## Bumping the agentcheckup version

1. Wait until the agentcheckup release is on npm with provenance.
2. Change `default:` of the `version` input in `action.yml`. It is the only place the version is
   pinned.
3. Set `AGENTCHECKUP_REF` in `.github/workflows/test.yml` to the commit of that release, so the
   packed-CLI test runs the same code.
4. Open a pull request. All test jobs must pass, including "Action with the npm release", which
   installs the new default from npm.

## Cutting a release

From an up-to-date `main` where all checks passed:

```sh
version=v0.1.0
git tag -s "$version" -m "$version"
git push origin "refs/tags/$version"
gh release create "$version" --verify-tag --title "$version" --generate-notes
```

The first release must be published to the GitHub Marketplace from the release page, with
"Publish this Action to the GitHub Marketplace" checked. Later releases can do the same.

Push the signed tag before you open the release page, and pick that existing tag there. For a tag
that does not exist yet, the page creates an unsigned one on the current `main`, and once the
release is published it cannot be moved. v0.4.0 was published that way before its commits
reached `main`, so it runs the code of v0.3.1. Before you publish, both lines must show the same
commit:

```sh
git ls-remote origin "refs/tags/$version^{}" refs/heads/main
```

Then move `v0` to the release commit:

```sh
git tag -s -f v0 -m "v0 is $version" "$version^{commit}"
git push --force origin refs/tags/v0
```

Finally, update the `@vX.Y.Z` examples in `README.md` in a pull request.

## Repository settings

- Default workflow token: read-only.
- Allowed actions: GitHub-owned actions plus `pnpm/action-setup`, `step-security/harden-runner`
  and `zizmorcore/zizmor-action`, pinned to full commit SHAs.
- `main`: pull requests with code owner review, required checks from `Test` and
  `Workflow security`, signed commits, linear history.
- Tags: the `v*.*.*` ruleset above, and `v0` movable by admins only. Immutable releases on.
- The rulesets are kept as JSON in `.github/rulesets/`. Apply one with
  `gh api -X POST repos/OWNER/agentcheckup-action/rulesets --input .github/rulesets/<file>.json`.
- Private vulnerability reporting points to the agentcheckup repository (see `SECURITY.md`).
