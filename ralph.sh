#!/usr/bin/env bash
# Ralph loop for session-aligner. Runs an AI coding agent repeatedly; each
# iteration does ONE task from PLAN.md. Stops on sentinel, failure streak, or
# max laps.
#
# Usage: ./ralph.sh [max_iterations] [engine]
#   max_iterations  default 30 (use 5 for supervised first laps)
#   engine          claude | codex | mix   (default mix)
#                   mix alternates: odd iterations = claude, even = codex,
#                   spreading token usage across both subscriptions.
#
# Env:
#   RALPH_CODEX_MODEL  optional model for codex iterations (passed as -m).
#                      Unset = Codex CLI's default model.
#   RALPH_DRY=1        print each iteration's command instead of running it.
set -u

MAX_ITER="${1:-30}"
ENGINE="${2:-mix}"
case "$ENGINE" in
  claude|codex|mix) ;;
  *) echo "usage: ./ralph.sh [max_iterations] [claude|codex|mix]" >&2; exit 2 ;;
esac

i=0
fails=0

run_claude() {
  claude -p --dangerously-skip-permissions "$(cat PROMPT.md)" 2>&1
}

run_codex() {
  if [ -n "${RALPH_CODEX_MODEL:-}" ]; then
    codex exec --dangerously-bypass-approvals-and-sandbox \
      -m "$RALPH_CODEX_MODEL" "$(cat PROMPT.md)" 2>&1
  else
    codex exec --dangerously-bypass-approvals-and-sandbox \
      "$(cat PROMPT.md)" 2>&1
  fi
}

while [ "$i" -lt "$MAX_ITER" ]; do
  i=$((i + 1))

  # Pick this iteration's engine.
  eng="$ENGINE"
  if [ "$ENGINE" = "mix" ]; then
    if [ $((i % 2)) -eq 1 ]; then eng="claude"; else eng="codex"; fi
  fi

  echo "=== ralph iteration $i / $MAX_ITER [$eng] — $(date '+%H:%M:%S') ==="

  if [ "${RALPH_DRY:-0}" = "1" ]; then
    if [ "$eng" = "claude" ]; then
      echo "DRY: claude -p --dangerously-skip-permissions \"\$(cat PROMPT.md)\""
    else
      echo "DRY: codex exec --dangerously-bypass-approvals-and-sandbox${RALPH_CODEX_MODEL:+ -m $RALPH_CODEX_MODEL} \"\$(cat PROMPT.md)\""
    fi
    continue
  fi

  if [ "$eng" = "claude" ]; then
    out="$(run_claude)"; status=$?
  else
    out="$(run_codex)"; status=$?
  fi
  echo "$out" | tail -20

  if echo "$out" | grep -q "RALPH_ALL_TASKS_COMPLETE"; then
    echo "=== plan complete after $i iterations ==="
    break
  fi

  if [ "$status" -ne 0 ]; then
    fails=$((fails + 1))
    [ "$fails" -ge 3 ] && { echo "=== 3 consecutive failures, stopping ==="; break; }
  else
    fails=0
  fi
done
