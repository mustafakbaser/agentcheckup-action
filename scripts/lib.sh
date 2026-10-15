# shellcheck shell=bash
# Helpers shared by the action's scripts. Sourced, never run on its own.
#
# Rules for every script in this directory:
# - Input values arrive in environment variables. They are validated, quoted, and never
#   evaluated as shell code.
# - The current directory is never the scanned repository, except for the agentcheckup process
#   itself (scan.sh), which is the trusted CLI started by absolute path.

# Escapes a value for a workflow command message: the runner reads %, CR and LF specially.
escape_data() {
  local s=$1
  s=${s//'%'/'%25'}
  s=${s//$'\r'/'%0D'}
  s=${s//$'\n'/'%0A'}
  printf '%s' "$s"
}

notice() { printf '::notice title=agentcheckup::%s\n' "$(escape_data "$*")"; }
warning() { printf '::warning title=agentcheckup::%s\n' "$(escape_data "$*")"; }
error() { printf '::error title=agentcheckup::%s\n' "$(escape_data "$*")"; }

# Writes name=value to the step outputs. Values never contain a line break.
set_output() {
  case $2 in
    *$'\n'* | *$'\r'*)
      error "Internal error: output $1 contains a line break."
      exit 3
      ;;
  esac
  printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
}

# Reports an error and stops the step with exit code 2: the action could not run.
fail() {
  error "$1"
  exit 2
}

# A step that stops early still records an exit code: 2 from fail(), 3 for anything unexpected.
record_exit_code() {
  local status=$?
  if [ "$status" -ne 0 ] && [ -n "${GITHUB_OUTPUT:-}" ]; then
    if [ "$status" -ne 2 ]; then status=3; fi
    printf 'exit-code=%s\n' "$status" >>"$GITHUB_OUTPUT"
  fi
}
trap record_exit_code EXIT

# At most 60 characters of a value, for error messages.
clip() {
  local s=$1
  if [ "${#s}" -gt 60 ]; then s="${s:0:57}..."; fi
  printf '%s' "$s"
}

require_env() {
  local name
  for name in "$@"; do
    if [ -z "${!name:-}" ]; then fail "The runner did not set $name."; fi
  done
}

require_tool() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      fail "This action needs $tool on the runner. GitHub-hosted Linux and macOS runners have it."
    fi
  done
}

# The physical path of an existing directory, or nothing.
real_dir() {
  (cd -P -- "$1" 2>/dev/null && pwd -P)
}

# Whether the physical path $1 is $2 or inside it. Both must be physical paths.
is_inside() {
  [ "$1" = "$2" ] && return 0
  case $1 in
    "$2"/*) return 0 ;;
  esac
  return 1
}

# Exact semantic version, optionally with a prerelease. No ranges, tags or build metadata.
is_exact_version() {
  local re='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
  [[ $1 =~ $re ]]
}

# Prints a repository-relative directory in normal form ("." for the root), or fails when the
# value is absolute, starts with "-", contains a ".." segment or a control character.
normalize_relative_path() {
  local p=$1
  if [ -z "$p" ] || [[ $p =~ [[:cntrl:]] ]]; then return 1; fi
  case $p in
    /* | -*) return 1 ;;
  esac
  case "/$p/" in
    */../*) return 1 ;;
  esac
  while [ "${p#./}" != "$p" ]; do p=${p#./}; done
  while [ "${p%/}" != "$p" ]; do p=${p%/}; done
  if [ -z "$p" ]; then p=.; fi
  printf '%s' "$p"
}

# 32 random hex characters, for ::stop-commands:: tokens.
random_token() {
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}

# Appends at most $2 bytes of file $1 to file $3. A cut drops the last, partial line and says so.
append_capped() {
  local source=$1 limit=$2 target=$3 size
  size=$(wc -c <"$source" | tr -d ' ')
  if [ "$size" -le "$limit" ]; then
    cat -- "$source" >>"$target"
    return 0
  fi
  head -c "$limit" -- "$source" | LC_ALL=C sed '$d' >>"$target"
  printf '\n\n_Cut here: the full report is %s bytes. The JSON report has everything._\n' \
    "$size" >>"$target"
}
