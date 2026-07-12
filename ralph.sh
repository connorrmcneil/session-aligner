#!/usr/bin/env bash
# Ralph loop for session-aligner. Runs Claude Code repeatedly; each iteration
# does ONE task from PLAN.md. Stops on sentinel, failure streak, or max laps.
#
# Usage: ./ralph.sh [max_iterations]   (default 30; use 5 for supervised laps)
set -u

MAX_ITER="${1:-30}"
i=0
fails=0

while [ "$i" -lt "$MAX_ITER" ]; do
  i=$((i + 1))
  echo "=== ralph iteration $i / $MAX_ITER — $(date '+%H:%M:%S') ==="

  out="$(claude -p --dangerously-skip-permissions "$(cat PROMPT.md)" 2>&1)"
  status=$?
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
