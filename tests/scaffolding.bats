#!/usr/bin/env bats
#
# Smoke test for the test scaffolding itself (M1.1). Proves that helpers.bash
# can extract and source function definitions from the repo scripts without
# running their main bodies. Real behavior tests are added in M1.3 onward.

load helpers

@test "helpers: REPO_ROOT points at a checkout containing aligner.sh" {
  [ -f "${REPO_ROOT}/aligner.sh" ]
}

@test "helpers: print_functions fails on a missing script" {
  run print_functions no-such-script.sh
  [ "$status" -ne 0 ]
}

@test "helpers: can load ping.sh functions without invoking a ping" {
  load_functions ping.sh
  [ "$(type -t parse_reset_epoch)" = "function" ]
  [ "$(type -t run_one_ping)" = "function" ]
}

@test "helpers: can load aligner.sh functions" {
  load_functions aligner.sh
  [ "$(type -t validate_times)" = "function" ]
  [ "$(type -t build_plist)" = "function" ]
  [ "$(type -t load_config)" = "function" ]
}

@test "helpers: can load schedule-wakes.sh and preflight-awake.sh functions" {
  load_functions schedule-wakes.sh
  [ "$(type -t already_scheduled)" = "function" ]
  load_functions preflight-awake.sh
  [ "$(type -t log)" = "function" ]
}
