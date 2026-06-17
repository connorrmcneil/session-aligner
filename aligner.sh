#!/usr/bin/env bash
#
# aligner.sh - Manage the Claude session-aligner schedule (macOS / launchd).
#
# This is the ONE script you run. It creates a launchd agent that pings Claude
# Code at the times you choose, so a fresh 5-hour window starts then. launchd is
# used (instead of cron) because it survives reboots and can run a missed ping
# when the Mac wakes from sleep.
#
# Usage:
#   ./aligner.sh setup                 Interactive setup (pick days + times)
#   ./aligner.sh test                  Send one ping right now
#   ./aligner.sh times "05:00 10:00 15:00"   Change times (keeps current days)
#   ./aligner.sh on                    Enable the schedule
#   ./aligner.sh off                   Disable the schedule (remembers settings)
#   ./aligner.sh status                Show schedule + recent log lines
#   ./aligner.sh wake on               Auto-wake the Mac before EACH ping (sudo)
#   ./aligner.sh wake off              Remove the auto-wake helper (sudo)
#   ./aligner.sh wake status           Show the helper + upcoming wakes
#
# Reminder: this does NOT increase your 5-hour quota. It only controls WHEN a
# new 5-hour window starts.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PING_SCRIPT="${SCRIPT_DIR}/ping.sh"
CONFIG_FILE="${SCRIPT_DIR}/aligner.config"
LOG_FILE="${SCRIPT_DIR}/aligner.log"
LAUNCHD_LOG="${SCRIPT_DIR}/aligner.launchd.log"

# launchd agent identity (the pinger, runs as you).
LABEL="com.sessionaligner.ping"
PLIST_FILE="${HOME}/Library/LaunchAgents/${LABEL}.plist"

# launchd DAEMON identity (the wake-scheduler, runs as root so pmset needs no password).
WAKE_LABEL="com.sessionaligner.wake"
WAKE_PLIST_FILE="/Library/LaunchDaemons/${WAKE_LABEL}.plist"
WAKE_SCRIPT="${SCRIPT_DIR}/schedule-wakes.sh"

# Old cron markers (from the previous cron-based version) so we can clean them up.
MARKER_BEGIN="# >>> session-aligner (managed) >>>"
MARKER_END="# <<< session-aligner (managed) <<<"

# Defaults: everyday at 05:00, 10:00, 15:00.
DEFAULT_TIMES="05:00 10:00 15:00"
DEFAULT_DAYS="*"   # "*" = every day; "1-5" = weekdays (Mon-Fri)

# ---------- config helpers ----------

load_config() {
  TIMES="$DEFAULT_TIMES"
  DAYS="$DEFAULT_DAYS"
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
  fi
}

save_config() {
  {
    echo "TIMES=\"${TIMES}\""
    echo "DAYS=\"${DAYS}\""
  } > "$CONFIG_FILE"
}

# Validate "HH:MM HH:MM ..." input.
validate_times() {
  local times="$1"
  [ -n "$times" ] || return 1
  for t in $times; do
    echo "$t" | grep -qE '^([01]?[0-9]|2[0-3]):[0-5][0-9]$' || return 1
  done
  return 0
}

human_days() {
  case "$1" in
    "*") echo "every day" ;;
    "1-5") echo "weekdays (Mon-Fri)" ;;
    *) echo "days: $1" ;;
  esac
}

# Weekday numbers for launchd (1=Mon ... 5=Fri). Empty = every day.
launchd_weekdays() {
  case "$DAYS" in
    "1-5") echo "1 2 3 4 5" ;;
    *) echo "" ;;
  esac
}

# ---------- launchd plist ----------

# Emit one <dict> StartCalendarInterval entry.
plist_interval() {
  local hour="$1" minute="$2" weekday="${3:-}"
  printf '    <dict>\n'
  printf '      <key>Hour</key><integer>%d</integer>\n' "$hour"
  printf '      <key>Minute</key><integer>%d</integer>\n' "$minute"
  if [ -n "$weekday" ]; then
    printf '      <key>Weekday</key><integer>%d</integer>\n' "$weekday"
  fi
  printf '    </dict>\n'
}

build_plist() {
  load_config
  local weekdays hour minute
  weekdays="$(launchd_weekdays)"

  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${PING_SCRIPT}</string>
  </array>
  <key>StartCalendarInterval</key>
  <array>
EOF

  for t in $TIMES; do
    hour=$((10#${t%%:*}))
    minute=$((10#${t##*:}))
    if [ -n "$weekdays" ]; then
      for wd in $weekdays; do
        plist_interval "$hour" "$minute" "$wd"
      done
    else
      plist_interval "$hour" "$minute"
    fi
  done

  cat <<EOF
  </array>
  <key>StandardOutPath</key>
  <string>${LAUNCHD_LOG}</string>
  <key>StandardErrorPath</key>
  <string>${LAUNCHD_LOG}</string>
</dict>
</plist>
EOF
}

# Remove the old cron-based schedule, if present, so we never double-ping.
migrate_cron_off() {
  command -v crontab >/dev/null 2>&1 || return 0
  crontab -l 2>/dev/null | grep -qF "$MARKER_BEGIN" || return 0
  local cleaned
  cleaned="$(crontab -l 2>/dev/null | awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
    $0==b {skip=1; next}
    $0==e {skip=0; next}
    skip!=1 {print}
  ')"
  if [ -n "$cleaned" ]; then
    printf '%s\n' "$cleaned" | crontab -
  else
    crontab -r 2>/dev/null || true
  fi
  echo "Removed the older cron schedule (now using launchd)."
}

is_installed() {
  [ -f "$PLIST_FILE" ] && launchctl list 2>/dev/null | grep -q "$LABEL"
}

install_schedule() {
  migrate_cron_off
  mkdir -p "$(dirname "$PLIST_FILE")"
  build_plist > "$PLIST_FILE"
  # Reload cleanly.
  launchctl unload "$PLIST_FILE" 2>/dev/null || true
  launchctl load "$PLIST_FILE"
}

remove_schedule() {
  if [ -f "$PLIST_FILE" ]; then
    launchctl unload "$PLIST_FILE" 2>/dev/null || true
    rm -f "$PLIST_FILE"
  fi
}

# ---------- pmset wake (auto, before every ping time) ----------

# Build the root LaunchDaemon plist that runs the wake-scheduler hourly + on wake.
build_wake_plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${WAKE_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${WAKE_SCRIPT}</string>
    <string>${SCRIPT_DIR}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>3600</integer>
  <key>StandardOutPath</key>
  <string>${SCRIPT_DIR}/wake.daemon.log</string>
  <key>StandardErrorPath</key>
  <string>${SCRIPT_DIR}/wake.daemon.log</string>
</dict>
</plist>
EOF
}

cmd_wake() {
  load_config
  case "${1:-status}" in
    on)
      local tmp
      tmp="$(mktemp -t sessionaligner-wake)"
      build_wake_plist > "$tmp"
      chmod +x "$WAKE_SCRIPT" 2>/dev/null || true

      echo "Setting up the auto-wake helper so your Mac wakes ~2 min before EACH"
      echo "ping time (${TIMES}). You'll be asked for your Mac password once."
      echo

      # One sudo block = a single password prompt (sudo caches for the rest).
      sudo bash -c '
        set -e
        plist_dst="$1"; tmp="$2"; script="$3"; proj="$4"
        # Drop the old single repeating wake from the previous version.
        pmset repeat cancel 2>/dev/null || true
        install -m 644 -o root -g wheel "$tmp" "$plist_dst"
        launchctl bootout system "$plist_dst" 2>/dev/null || true
        launchctl bootstrap system "$plist_dst" 2>/dev/null \
          || launchctl load -w "$plist_dst"
        # Seed wakes right now so tonight is covered without waiting an hour.
        bash "$script" "$proj"
      ' _ "$WAKE_PLIST_FILE" "$tmp" "$WAKE_SCRIPT" "$SCRIPT_DIR"

      rm -f "$tmp"
      echo
      echo "Done. The helper refreshes wakes hourly (and whenever the Mac wakes)."
      echo "Check it with: ./aligner.sh wake status"
      ;;
    off)
      echo "Removing the auto-wake helper (asks for your Mac password)."
      sudo bash -c '
        plist_dst="$1"; script="$2"; proj="$3"
        launchctl bootout system "$plist_dst" 2>/dev/null || true
        rm -f "$plist_dst"
        # Clear any wakes we already scheduled, plus the old repeat (if any).
        bash "$script" "$proj" cancel 2>/dev/null || true
        pmset repeat cancel 2>/dev/null || true
      ' _ "$WAKE_PLIST_FILE" "$WAKE_SCRIPT" "$SCRIPT_DIR"
      echo "Done."
      ;;
    status|*)
      if [ -f "$WAKE_PLIST_FILE" ]; then
        echo "Auto-wake helper: ON (${WAKE_LABEL})"
      else
        echo "Auto-wake helper: OFF (run './aligner.sh wake on')"
      fi
      echo
      echo "Upcoming scheduled wakes (pmset):"
      if pmset -g sched 2>/dev/null | grep -qiE 'wake|poweron'; then
        pmset -g sched 2>/dev/null | grep -iE 'wake|poweron'
      else
        echo "  (none yet - they appear after 'wake on' seeds them)"
      fi
      ;;
  esac
}

# ---------- subcommands ----------

cmd_setup() {
  load_config
  echo "Session Aligner setup"
  echo "---------------------"
  echo "Schedules a tiny ping to Claude Code so a fresh 5-hour window starts at"
  echo "the times you choose. It does NOT add to your quota."
  echo

  printf 'Run every day or weekdays only? [everyday/weekdays] (everyday): '
  read -r days_in
  case "$(echo "${days_in:-everyday}" | tr '[:upper:]' '[:lower:]')" in
    weekday|weekdays|w) DAYS="1-5" ;;
    *) DAYS="*" ;;
  esac

  while true; do
    printf 'Ping times, 24h clock, space-separated (%s): ' "$DEFAULT_TIMES"
    read -r times_in
    times_in="${times_in:-$DEFAULT_TIMES}"
    if validate_times "$times_in"; then
      TIMES="$times_in"
      break
    fi
    echo "  Please use HH:MM times like: 05:00 10:00 15:00"
  done

  save_config
  install_schedule
  echo
  echo "Scheduled: ping at [${TIMES}] $(human_days "$DAYS")."
  echo
  echo "To make pings fire even while the Mac sleeps (lid closed + plugged into"
  echo "power), also run:  ./aligner.sh wake on   (wakes ~2 min before each time)"
  echo "Then check everything with:     ./aligner.sh status"
}

cmd_test() {
  echo "Sending one ping now..."
  "$PING_SCRIPT"
}

cmd_times() {
  local new_times="$1"
  if ! validate_times "$new_times"; then
    echo "Invalid times. Example: ./aligner.sh times \"05:00 10:00 15:00\"" >&2
    exit 1
  fi
  load_config
  TIMES="$new_times"
  save_config
  if is_installed; then
    install_schedule
    echo "Updated. Now pinging at [${TIMES}] $(human_days "$DAYS")."
    if [ -f "$WAKE_PLIST_FILE" ]; then
      echo "Auto-wake will pick up the new times within an hour (or run"
      echo "'./aligner.sh wake on' to apply them right now)."
    fi
  else
    echo "Saved times [${TIMES}]. Schedule is currently OFF; run './aligner.sh on' to enable."
  fi
}

cmd_on() {
  load_config
  install_schedule
  echo "Schedule ON: ping at [${TIMES}] $(human_days "$DAYS")."
}

cmd_off() {
  remove_schedule
  echo "Schedule OFF. Your saved times are remembered; run './aligner.sh on' to resume."
  echo "(The scheduled wake, if any, is separate: ./aligner.sh wake off)"
}

cmd_status() {
  load_config
  echo "Session Aligner status"
  echo "----------------------"
  echo "Folder:   ${SCRIPT_DIR}"
  echo "Times:    ${TIMES}"
  echo "Days:     $(human_days "$DAYS")"
  if is_installed; then
    echo "Schedule: ON (launchd agent ${LABEL})"
    echo "Plist:    ${PLIST_FILE}"
  else
    echo "Schedule: OFF"
  fi
  echo
  if [ -f "$WAKE_PLIST_FILE" ]; then
    echo "Auto-wake:  ON (wakes ~2 min before each ping time)"
  else
    echo "Auto-wake:  OFF (run './aligner.sh wake on')"
  fi
  echo "Scheduled wakes (pmset):"
  if pmset -g sched 2>/dev/null | grep -qiE 'wake|poweron'; then
    pmset -g sched 2>/dev/null | grep -iE 'wake|poweron'
  else
    echo "  (none yet)"
  fi
  echo
  if [ -f "$LOG_FILE" ]; then
    echo "Recent log (last 5 lines):"
    tail -n 5 "$LOG_FILE"
  else
    echo "No log yet. Try './aligner.sh test'."
  fi
}

usage() {
  sed -n '3,23p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------- dispatch ----------

case "${1:-}" in
  setup)  cmd_setup ;;
  test)   cmd_test ;;
  times)  shift; cmd_times "${1:-}" ;;
  on)     cmd_on ;;
  off)    cmd_off ;;
  status) cmd_status ;;
  wake)   shift; cmd_wake "${1:-status}" ;;
  ""|-h|--help|help) usage ;;
  *) echo "Unknown command: $1" >&2; echo; usage; exit 1 ;;
esac
