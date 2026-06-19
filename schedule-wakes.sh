#!/usr/bin/env bash
# schedule-wakes.sh - keep macOS wake events scheduled before each ping time.
#
# macOS `pmset repeat` only allows ONE repeating wake per day, so to wake before
# EVERY ping time we schedule one-time `wakeorpoweron` events a few minutes before
# each time, for the next few days, and refresh them often.
#
# This is meant to run as root from the com.sessionaligner.wake LaunchDaemon
# (so pmset needs no password). It is idempotent: it only adds wakes that are
# missing, and one-time events disappear once they fire, so the list stays small.
#
# Usage: schedule-wakes.sh <project_dir> [cancel]
#   cancel   - remove the wakes we would have scheduled (used by `wake off`)
#   DRY_RUN=1 - print pmset commands instead of running them (for testing)
set -u

PROJECT_DIR="${1:-}"
MODE="${2:-schedule}"
if [ -z "$PROJECT_DIR" ]; then
  echo "usage: schedule-wakes.sh <project_dir> [cancel]" >&2
  exit 2
fi

CONFIG_FILE="${PROJECT_DIR}/aligner.config"
LOG_FILE="${PROJECT_DIR}/wake.log"

# Defaults (overridden by aligner.config if present).
TIMES="05:00 10:00 15:00"
DAYS="*"
WAKE_LEAD_MIN=15    # wake this many minutes before each ping time (config-driven)
KEEP_AWAKE_MIN=20   # preflight caffeinate duration (read by preflight-awake.sh)
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# Clamp lead to a sane range in case aligner.config was hand-edited.
case "$WAKE_LEAD_MIN" in *[!0-9]*|'') WAKE_LEAD_MIN=15 ;; esac
[ "$WAKE_LEAD_MIN" -lt 1 ]  && WAKE_LEAD_MIN=1
[ "$WAKE_LEAD_MIN" -gt 60 ] && WAKE_LEAD_MIN=60

HORIZON_DAYS=3      # schedule today + the next couple of days as a buffer

run() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "DRY: $*"
  else
    "$@"
  fi
}

log() {
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

# ---------- single-instance lock ----------
# RunAtLoad, the hourly StartInterval catch-up, and the manual seed from
# `wake on` can fire within the same second. Without serialization two runs race
# in already_scheduled() — both see a time as "missing" and both schedule it,
# producing the duplicate wakeorpoweron events you'd see in `pmset -g sched`. An
# atomic mkdir lock makes the later run wait, then find the time already there
# and add nothing. The lock is skipped in DRY_RUN so tests never block.
if [ "${DRY_RUN:-0}" != "1" ]; then
  LOCK_DIR="${PROJECT_DIR}/.wake-schedule.lock"
  _now=$(date +%s)
  # Clear a stale lock left by a run that was killed mid-flight, so we never deadlock.
  if [ -d "$LOCK_DIR" ]; then
    _lock_mtime=$(stat -f %m "$LOCK_DIR" 2>/dev/null || echo "$_now")
    if [ $((_now - _lock_mtime)) -gt 120 ]; then
      rmdir "$LOCK_DIR" 2>/dev/null || true
      log "cleared a stale wake-schedule lock"
    fi
  fi
  _have_lock=0
  for _try in $(seq 1 12); do
    if mkdir "$LOCK_DIR" 2>/dev/null; then _have_lock=1; break; fi
    sleep 1
  done
  if [ "$_have_lock" != "1" ]; then
    log "another scheduler run is active; skipping this run"
    exit 0
  fi
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
fi

# Is a wake already scheduled at this exact "MM/DD/YYYY HH:MM:SS" datetime?
already_scheduled() {
  pmset -g sched 2>/dev/null | grep -qF "$1"
}

NOW_EPOCH=$(date +%s)
added=0

for off in $(seq 0 $((HORIZON_DAYS - 1))); do
  d_date=$(date -v+"${off}"d +"%m/%d/%Y")
  d_wd=$(date -v+"${off}"d +%u)   # 1=Mon .. 7=Sun

  # Weekdays-only mode: skip Saturday (6) and Sunday (7).
  if [ "$DAYS" = "1-5" ] && { [ "$d_wd" -eq 6 ] || [ "$d_wd" -eq 7 ]; }; then
    continue
  fi

  for t in $TIMES; do
    h=$((10#${t%%:*}))
    m=$((10#${t##*:}))
    total=$((h * 60 + m - WAKE_LEAD_MIN))
    [ "$total" -lt 0 ] && total=0
    dt=$(printf '%s %02d:%02d:00' "$d_date" $((total / 60)) $((total % 60)))

    ep=$(date -j -f "%m/%d/%Y %H:%M:%S" "$dt" +%s 2>/dev/null)
    [ -n "$ep" ] || continue

    if [ "$MODE" = "cancel" ]; then
      if already_scheduled "$dt"; then
        run pmset schedule cancel wakeorpoweron "$dt"
        log "cancelled wake $dt"
      fi
      continue
    fi

    # Don't bother scheduling a time that has already passed.
    [ "$ep" -le "$NOW_EPOCH" ] && continue
    already_scheduled "$dt" && continue

    run pmset schedule wakeorpoweron "$dt"
    log "scheduled wake $dt"
    added=$((added + 1))
  done
done

if [ "$MODE" != "cancel" ]; then
  log "run complete: added ${added} wake(s) for times [${TIMES}] (${DAYS})"
fi
