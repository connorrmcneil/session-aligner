#!/usr/bin/env bash
# preflight-awake.sh - keep the Mac awake from wake time through the window start.
#
# The auto-wake daemon schedules a pmset wake a few minutes BEFORE each Claude
# window start (WAKE_LEAD_MIN). On its own, a freshly-woken Mac can drift back
# toward sleep before the ping LaunchAgent fires, so the ping lands late. This
# helper runs at the wake time (from the com.sessionaligner.preflight LaunchAgent,
# as YOU - not root) and uses macOS `caffeinate` to hold the Mac fully awake until
# a few minutes after the window start, so the ping fires on time.
#
# Timeline (defaults): 04:45 wake + preflight starts caffeinate -> 05:00 ping runs
#                      -> 05:05 caffeinate expires.
#
# Usage: preflight-awake.sh <project_dir>
#   DRY_RUN=1 - print the caffeinate command instead of running it (for testing)
set -u

PROJECT_DIR="${1:-}"
if [ -z "$PROJECT_DIR" ]; then
  echo "usage: preflight-awake.sh <project_dir>" >&2
  exit 2
fi

CONFIG_FILE="${PROJECT_DIR}/aligner.config"
LOG_FILE="${PROJECT_DIR}/preflight.log"

# Default, overridden by aligner.config if present.
KEEP_AWAKE_MIN=20
# shellcheck disable=SC1090
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# Clamp to a sane range in case aligner.config was hand-edited.
case "$KEEP_AWAKE_MIN" in *[!0-9]*|'') KEEP_AWAKE_MIN=20 ;; esac
[ "$KEEP_AWAKE_MIN" -lt 5 ]  && KEEP_AWAKE_MIN=5
[ "$KEEP_AWAKE_MIN" -gt 90 ] && KEEP_AWAKE_MIN=90

SECS=$((KEEP_AWAKE_MIN * 60))

log() {
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

log "preflight keep-awake started for ${KEEP_AWAKE_MIN} minutes"

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "DRY: caffeinate -dimsu -t ${SECS}"
else
  # -d display, -i idle, -m disk, -s system, -u user-active: keep the Mac fully
  # awake (not just dark-wake) so the ping LaunchAgent fires on schedule.
  caffeinate -dimsu -t "$SECS"
fi

log "preflight keep-awake finished"
