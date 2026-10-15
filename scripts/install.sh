#!/usr/bin/env bash
# Installs the exact agentcheckup version into the work directory and prints the path of its
# CLI script. npm runs from the work directory, so the scanned repository's .npmrc,
# package.json and node_modules play no part. scan.sh then starts the CLI with `node <path>`.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "${BASH_SOURCE[0]%/*}/lib.sh"

require_env AC_WORK AC_VERSION GITHUB_OUTPUT
require_tool node npm jq
cd -- "$AC_WORK"

node_version=$(node -p 'process.versions.node') || fail "Could not run node."
IFS=. read -r major minor _ <<<"$node_version"
if ! [[ $major =~ ^[0-9]+$ && $minor =~ ^[0-9]+$ ]] || ((major < 22 || (major == 22 && minor < 12))); then
  fail "agentcheckup needs Node.js 22.12 or later, and this runner has $(clip "$node_version"). Add actions/setup-node with node-version: 24 before this action."
fi

prefix="$AC_WORK/cli"
mkdir -- "$prefix"
printf '{ "private": true }\n' >"$prefix/package.json"

if [ -n "${AC_TEST_PACKAGE:-}" ]; then
  spec=$AC_TEST_PACKAGE
  source_name="test package $AC_TEST_PACKAGE"
else
  spec="agentcheckup@$AC_VERSION"
  source_name="npm"
fi

if ! (cd -- "$prefix" && npm install --prefix "$prefix" --no-save --no-package-lock \
  --ignore-scripts --no-audit --no-fund --loglevel=error -- "$spec"); then
  fail "Could not install agentcheckup $AC_VERSION from $source_name."
fi

package="$prefix/node_modules/agentcheckup"
manifest="$package/package.json"
[ -f "$manifest" ] || fail "The installed package has no package.json."
name=$(jq -r '.name // empty' "$manifest")
installed=$(jq -r '.version // empty' "$manifest")
bin=$(jq -r '.bin | if type == "string" then . else (.agentcheckup // empty) end' "$manifest")

[ "$name" = agentcheckup ] || fail "The installed package is not agentcheckup."
if [ -z "${AC_TEST_PACKAGE:-}" ] && [ "$installed" != "$AC_VERSION" ]; then
  fail "npm installed agentcheckup $(clip "$installed"), not $AC_VERSION."
fi
bin=${bin#./}
if ! [[ $bin =~ ^[A-Za-z0-9._/-]+$ ]] || [[ "/$bin/" == */../* ]] || [ ! -f "$package/$bin" ]; then
  fail "The installed package has no usable bin entry."
fi

printf 'Installed agentcheckup %s from %s.\n' "$installed" "$source_name"
set_output cli "$package/$bin"
set_output cli-version "$installed"
