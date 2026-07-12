# tests/helpers.bash - shared setup for the session-aligner bats test suite.
#
# The scripts in this repo mix top-level side effects (reading config, probing
# for the `claude`/`expect` binaries, and in ping.sh calling `exit` when they
# are missing) in among their function definitions. That means we cannot just
# `source` a whole script to get at one function - doing so would run the ping,
# hit launchctl/pmset, or exit the test.
#
# Instead we extract ONLY the function definitions (complete brace-balanced
# blocks whose `name() {` opener starts in column 0) and source those. Defining
# a function does not run its body, so no side effects fire. Tests then set the
# handful of globals a given function reads (the scripts expose DRY_RUN=1 and
# the FAKE_CLEAN / FORCE_RESET_EPOCH / FORCE_START_EPOCH hooks for exactly this).
#
# This keeps the production scripts unmodified. If a later milestone splits the
# scripts into cleanly sourceable lib/ modules, prefer sourcing those directly
# and retire the extractor for them.

# Absolute path to the repo root, regardless of the caller's CWD.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# print_functions <script-basename>
# Emit just the top-level function definitions from a repo script to stdout.
print_functions() {
  local path="${REPO_ROOT}/$1"
  if [ ! -f "$path" ]; then
    echo "print_functions: no such file: $path" >&2
    return 1
  fi
  awk '
    BEGIN { state = 0; depth = 0 }
    {
      line = $0
      # A function definition opener at column 0, e.g. `parse_reset_epoch() {`.
      if (state == 0 && line ~ /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{/) {
        state = 1; depth = 0
      }
      if (state == 1) {
        print line
        # Balance braces so nested blocks and one-line functions both close
        # correctly. gsub returns the count of substitutions it made.
        t = line; o = gsub(/{/, "", t)
        t = line; c = gsub(/}/, "", t)
        depth += o - c
        if (depth <= 0) state = 0
      }
    }
  ' "$path"
}

# load_functions <script-basename>
# Source the function definitions from a repo script into the current shell so
# individual functions can be called in isolation. Returns non-zero if the
# script is missing or the extracted definitions do not parse.
load_functions() {
  local extracted
  extracted="$(print_functions "$1")" || return 1
  # shellcheck disable=SC1090,SC1091
  source /dev/stdin <<<"$extracted"
}
