# session-aligner tests

Unit tests for the session-aligner scripts, written with
[bats-core](https://github.com/bats-core/bats-core). These are **dev-only**
dependencies — the tool itself adds no runtime dependencies.

## Requirements

- `bats` (bats-core) — the test runner
- `shellcheck` — static analysis, run in CI alongside the tests

On macOS:

```sh
brew install bats-core shellcheck
```

On Debian/Ubuntu CI:

```sh
sudo apt-get install -y bats shellcheck
```

## Running

From the repo root:

```sh
bats tests/          # run the whole suite
bats tests/foo.bats  # run one file
```

Lint every shell script (must be clean):

```sh
shellcheck *.sh
```

## How tests reach the code (`helpers.bash`)

The production scripts interleave function definitions with top-level side
effects — reading config, probing for the `claude`/`expect` binaries, and (in
`ping.sh`) `exit`ing when they are missing. Sourcing a whole script would fire
those effects, so `helpers.bash` extracts **only** the function definitions
(complete, brace-balanced blocks whose `name() {` opener sits in column 0) and
sources those. Defining a function does not run its body, so no ping, no
`launchctl`, no `pmset`, no `exit`.

```bash
load helpers            # bats picks up tests/helpers.bash

load_functions ping.sh  # now parse_reset_epoch, run_one_ping, ... are defined
```

A test then sets whatever globals the function under test reads. The scripts
expose hooks built for this:

- `DRY_RUN=1` — print the launchctl/pmset/caffeinate command instead of running it
- `FAKE_CLEAN` — supply a canned ping transcript to `run_one_ping`
- `FORCE_RESET_EPOCH` / `FORCE_START_EPOCH` — pin the reset/start epochs so
  classification boundaries can be tested deterministically

## Safety

Tests must **never** invoke the real `claude` or `codex` binaries, and must
never touch `launchctl`, `pmset`, or `caffeinate` for real — a real ping would
consume the user's usage window. Use `DRY_RUN=1`, the `FAKE_*`/`FORCE_*` hooks,
fixtures, or stub binaries on `PATH`.
