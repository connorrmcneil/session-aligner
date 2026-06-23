#!/usr/bin/env bash
#
# aligner.sh - Manage the Claude session-aligner schedule (macOS / launchd).
#
# This is the core script. It creates a launchd agent that sends a tiny
# interactive Claude Code ping at the times you choose, so a fresh 5-hour Claude
# window STARTS then. launchd is used (instead of cron) because it survives
# reboots and can run a missed ping when the Mac wakes from sleep.
#
# It does NOT increase your 5-hour quota. It only controls WHEN a new 5-hour
# window starts. Run `session-aligner help` (or `./aligner.sh help`) for commands.

set -u

# Bump on each release. Surfaced by `version`/`--version`/`-v` and `report`.
VERSION="0.1.0"

# Resolve the real folder this script lives in, even when invoked through the
# /usr/local/bin/session-aligner symlink (so ping.sh, ping.exp, schedule-wakes.sh,
# aligner.config and the logs are always found in the real repo, not in
# /usr/local/bin). No GNU readlink -f needed; this is portable + space-safe.
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  dir="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [ "${SOURCE:0:1}" != "/" ] && SOURCE="$dir/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

# How we were invoked, so help/examples show the right command name.
if [ "$(basename "$0")" = "session-aligner" ]; then
  CMD_NAME="session-aligner"
else
  CMD_NAME="./aligner.sh"
fi

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
WAKE_LOG="${SCRIPT_DIR}/wake.log"
WAKE_DAEMON_LOG="${SCRIPT_DIR}/wake.daemon.log"

# launchd agent identity (the preflight keep-awake, runs as you - NOT root).
# It fires at each wake time (window start minus WAKE_LEAD_MIN) and runs
# caffeinate so the Mac stays awake until the ping fires on time.
PREFLIGHT_LABEL="com.sessionaligner.preflight"
PREFLIGHT_PLIST_FILE="${HOME}/Library/LaunchAgents/${PREFLIGHT_LABEL}.plist"
PREFLIGHT_SCRIPT="${SCRIPT_DIR}/preflight-awake.sh"
PREFLIGHT_LOG="${SCRIPT_DIR}/preflight.log"

# Where install.sh puts the global command (used by uninstall).
SELF_LINK="/usr/local/bin/session-aligner"

# Old cron markers (from the previous cron-based version) so we can clean them up.
MARKER_BEGIN="# >>> session-aligner (managed) >>>"
MARKER_END="# <<< session-aligner (managed) <<<"

# Defaults: everyday at 05:00, 10:00, 15:00.
DEFAULT_TIMES="05:00 10:00 15:00"
DEFAULT_DAYS="*"   # "*" = every day; "1-5" = weekdays (Mon-Fri)

# Wake/preflight defaults. The Mac wakes WAKE_LEAD_MIN before each window start,
# then caffeinate keeps it awake for KEEP_AWAKE_MIN (which must outlast the lead so
# it spans past the ping). Defaults: wake 15 min early, hold awake 20 min (lead+5).
DEFAULT_WAKE_LEAD_MIN=15    # range 1-60
DEFAULT_KEEP_AWAKE_MIN=20   # range 5-90

# Retry-after-reset defaults. After a ping, ping.sh reads the /usage reset time
# to tell whether a FRESH window started; if the OLD window is still active and
# about to reset, it waits past the reset and pings once more. Read by ping.sh.
DEFAULT_RETRY_AFTER_ACTIVE_WINDOW=1   # 0/1 flag
DEFAULT_RETRY_GRACE_MIN=20            # range 1-60
DEFAULT_RETRY_AFTER_RESET_SEC=60      # range 0-600

# ---------- config helpers ----------

load_config() {
  TIMES="$DEFAULT_TIMES"
  DAYS="$DEFAULT_DAYS"
  WAKE_LEAD_MIN="$DEFAULT_WAKE_LEAD_MIN"
  KEEP_AWAKE_MIN="$DEFAULT_KEEP_AWAKE_MIN"
  RETRY_AFTER_ACTIVE_WINDOW="$DEFAULT_RETRY_AFTER_ACTIVE_WINDOW"
  RETRY_GRACE_MIN="$DEFAULT_RETRY_GRACE_MIN"
  RETRY_AFTER_RESET_SEC="$DEFAULT_RETRY_AFTER_RESET_SEC"
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
  fi
  # Clamp to sane ranges in case aligner.config was hand-edited.
  case "$WAKE_LEAD_MIN" in *[!0-9]*|'') WAKE_LEAD_MIN="$DEFAULT_WAKE_LEAD_MIN" ;; esac
  [ "$WAKE_LEAD_MIN" -lt 1 ]  && WAKE_LEAD_MIN=1
  [ "$WAKE_LEAD_MIN" -gt 60 ] && WAKE_LEAD_MIN=60
  case "$KEEP_AWAKE_MIN" in *[!0-9]*|'') KEEP_AWAKE_MIN="$DEFAULT_KEEP_AWAKE_MIN" ;; esac
  [ "$KEEP_AWAKE_MIN" -lt 5 ]  && KEEP_AWAKE_MIN=5
  [ "$KEEP_AWAKE_MIN" -gt 90 ] && KEEP_AWAKE_MIN=90
  case "$RETRY_AFTER_ACTIVE_WINDOW" in 0|1) ;; *) RETRY_AFTER_ACTIVE_WINDOW="$DEFAULT_RETRY_AFTER_ACTIVE_WINDOW" ;; esac
  case "$RETRY_GRACE_MIN" in *[!0-9]*|'') RETRY_GRACE_MIN="$DEFAULT_RETRY_GRACE_MIN" ;; esac
  [ "$RETRY_GRACE_MIN" -lt 1 ]  && RETRY_GRACE_MIN=1
  [ "$RETRY_GRACE_MIN" -gt 60 ] && RETRY_GRACE_MIN=60
  case "$RETRY_AFTER_RESET_SEC" in *[!0-9]*|'') RETRY_AFTER_RESET_SEC="$DEFAULT_RETRY_AFTER_RESET_SEC" ;; esac
  [ "$RETRY_AFTER_RESET_SEC" -lt 0 ]   && RETRY_AFTER_RESET_SEC=0
  [ "$RETRY_AFTER_RESET_SEC" -gt 600 ] && RETRY_AFTER_RESET_SEC=600
}

save_config() {
  {
    echo "TIMES=\"${TIMES}\""
    echo "DAYS=\"${DAYS}\""
    echo "WAKE_LEAD_MIN=\"${WAKE_LEAD_MIN}\""
    echo "KEEP_AWAKE_MIN=\"${KEEP_AWAKE_MIN}\""
    echo "RETRY_AFTER_ACTIVE_WINDOW=\"${RETRY_AFTER_ACTIVE_WINDOW}\""
    echo "RETRY_GRACE_MIN=\"${RETRY_GRACE_MIN}\""
    echo "RETRY_AFTER_RESET_SEC=\"${RETRY_AFTER_RESET_SEC}\""
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

# Validate that $1 is an integer within [$2, $3].
validate_int() {
  local v="$1" lo="$2" hi="$3"
  case "$v" in *[!0-9]*|'') return 1 ;; esac
  [ "$v" -ge "$lo" ] && [ "$v" -le "$hi" ]
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

# Wake/preflight times = each window start minus WAKE_LEAD_MIN, as "HH:MM".
# Clamped to 00:00 (mirrors schedule-wakes.sh) so the wake daemon and the
# preflight LaunchAgent always agree on the wake time. Needs load_config first.
preflight_times() {
  local t h m total
  for t in $TIMES; do
    h=$((10#${t%%:*}))
    m=$((10#${t##*:}))
    total=$((h * 60 + m - WAKE_LEAD_MIN))
    [ "$total" -lt 0 ] && total=0
    printf '%02d:%02d\n' $((total / 60)) $((total % 60))
  done
}

# Same as preflight_times but comma-separated on one line, for status display.
preflight_times_csv() {
  preflight_times | paste -sd, - | sed 's/,/, /g'
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

# Build the root LaunchDaemon plist that runs the wake-scheduler at load and hourly
# (a missed StartInterval also catches up soon after the Mac wakes).
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

# ---------- preflight keep-awake LaunchAgent (runs as you, not root) ----------

# Build the user LaunchAgent plist that runs preflight-awake.sh at each wake time
# (window start minus WAKE_LEAD_MIN). Needs load_config first.
build_preflight_plist() {
  local weekdays wd
  weekdays="$(launchd_weekdays)"

  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PREFLIGHT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${PREFLIGHT_SCRIPT}</string>
    <string>${SCRIPT_DIR}</string>
  </array>
  <key>StartCalendarInterval</key>
  <array>
EOF

  local wt hour minute
  for wt in $(preflight_times); do
    hour=$((10#${wt%%:*}))
    minute=$((10#${wt##*:}))
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
  <string>${PREFLIGHT_LOG}</string>
  <key>StandardErrorPath</key>
  <string>${PREFLIGHT_LOG}</string>
</dict>
</plist>
EOF
}

preflight_installed() { [ -f "$PREFLIGHT_PLIST_FILE" ]; }

install_preflight() {
  chmod +x "$PREFLIGHT_SCRIPT" 2>/dev/null || true
  mkdir -p "$(dirname "$PREFLIGHT_PLIST_FILE")"
  build_preflight_plist > "$PREFLIGHT_PLIST_FILE"
  launchctl unload "$PREFLIGHT_PLIST_FILE" 2>/dev/null || true
  launchctl load "$PREFLIGHT_PLIST_FILE"
}

remove_preflight() {
  if [ -f "$PREFLIGHT_PLIST_FILE" ]; then
    launchctl unload "$PREFLIGHT_PLIST_FILE" 2>/dev/null || true
    rm -f "$PREFLIGHT_PLIST_FILE"
  fi
}

cmd_wake() {
  load_config
  case "${1:-status}" in
    on)
      local tmp
      tmp="$(mktemp -t sessionaligner-wake)"
      build_wake_plist > "$tmp"
      chmod +x "$WAKE_SCRIPT" 2>/dev/null || true

      echo "Setting up auto-wake so your Mac wakes ${WAKE_LEAD_MIN} min before each window"
      echo "start (${TIMES}) and stays awake until the ping fires."
      echo
      echo "Wake times: $(preflight_times_csv)   Ping times: $(printf '%s' "$TIMES" | tr ' ' ',' | sed 's/,/, /g')"
      echo
      echo "Auto-wake needs your Mac password once because macOS requires admin"
      echo "access to schedule system wake events (via pmset). Your password is"
      echo "handled by macOS sudo and is NOT stored by Session Aligner. The helper"
      echo "only keeps wake events scheduled before your chosen window start times"
      echo "- it never sees your Claude account. (The ping schedule and the preflight"
      echo "keep-awake both run as you and need no admin access.)"
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

      # Preflight keep-awake LaunchAgent runs as you - no sudo needed.
      install_preflight

      echo
      echo "Done. The root helper refreshes wakes at load/startup and hourly (and"
      echo "usually soon after the Mac wakes, when a missed hourly run catches up)."
      echo "The preflight keep-awake agent runs caffeinate for ${KEEP_AWAKE_MIN} min at each"
      echo "wake time so the ping lands on time. Check it with: ${CMD_NAME} wake status"
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
      # The preflight keep-awake agent runs as you - remove it without sudo.
      remove_preflight
      echo "Done."
      ;;
    lead)
      local n="${2:-}"
      if ! validate_int "$n" 1 60; then
        echo "Invalid wake lead. Use a whole number of minutes, 1-60." >&2
        echo "Example: ${CMD_NAME} wake lead 15" >&2
        exit 1
      fi
      WAKE_LEAD_MIN="$n"
      if [ "$KEEP_AWAKE_MIN" -le "$WAKE_LEAD_MIN" ]; then
        KEEP_AWAKE_MIN=$((WAKE_LEAD_MIN + 5))
        [ "$KEEP_AWAKE_MIN" -gt 90 ] && KEEP_AWAKE_MIN=90
        echo "Note: keep-awake must outlast the wake lead, so it was raised to"
        echo "${KEEP_AWAKE_MIN} min (caffeinate would otherwise expire before the ping)."
      fi
      save_config
      echo "Wake lead set to ${WAKE_LEAD_MIN} min. Mac will wake at: $(preflight_times_csv)"
      if wake_installed; then
        echo "Applying now (re-seeds wakes and rebuilds the preflight agent)..."
        cmd_wake on
      else
        echo "Auto-wake is OFF; this applies when you run '${CMD_NAME} wake on'."
      fi
      ;;
    keep-awake)
      local n="${2:-}"
      if ! validate_int "$n" 5 90; then
        echo "Invalid keep-awake. Use a whole number of minutes, 5-90." >&2
        echo "Example: ${CMD_NAME} wake keep-awake 20" >&2
        exit 1
      fi
      if [ "$n" -le "$WAKE_LEAD_MIN" ]; then
        echo "Note: keep-awake ($n) must be greater than the wake lead"
        echo "(${WAKE_LEAD_MIN}) or caffeinate expires before the ping fires."
        n=$((WAKE_LEAD_MIN + 5))
        [ "$n" -gt 90 ] && n=90
        echo "Raised keep-awake to ${n} min."
      fi
      KEEP_AWAKE_MIN="$n"
      save_config
      echo "Keep-awake set to ${KEEP_AWAKE_MIN} min (caffeinate duration at each wake)."
      # The preflight script reads KEEP_AWAKE_MIN at runtime, so no rebuild is
      # required; rebuild anyway when installed so the agent stays tidy.
      if preflight_installed; then install_preflight; fi
      ;;
    status|*)
      if wake_installed; then
        echo "Auto-wake helper: ON (${WAKE_LABEL})"
      else
        echo "Auto-wake helper: OFF (run '${CMD_NAME} wake on')"
      fi
      if preflight_installed; then
        echo "Preflight keep-awake: ON (${PREFLIGHT_LABEL})"
      else
        echo "Preflight keep-awake: OFF"
      fi
      echo
      printf '%-15s %s\n' "Window starts:" "$(printf '%s' "$TIMES" | tr ' ' ',' | sed 's/,/, /g')"
      printf '%-15s %s\n' "Wake lead:" "${WAKE_LEAD_MIN} minutes"
      printf '%-15s %s\n' "Keep-awake:" "${KEEP_AWAKE_MIN} minutes"
      printf '%-15s %s\n' "Wake times:" "$(preflight_times_csv)"
      printf '%-15s %s\n' "Ping times:" "$(printf '%s' "$TIMES" | tr ' ' ',' | sed 's/,/, /g')"
      echo
      echo "Upcoming wakes before your window starts:"
      local any=0 ep
      while read -r ep; do
        [ -z "$ep" ] && continue
        any=1
        printf '    %s\n' "$(human_when "$ep")"
      done <<EOF
$(upcoming_wake_epochs)
EOF
      [ "$any" -eq 0 ] && echo "    (none yet - they appear after 'wake on' seeds them)"
      if [ "${2:-}" = "--raw" ]; then
        echo
        echo "--- raw: pmset -g sched ---"
        pmset -g sched 2>/dev/null
      fi
      ;;
  esac
}

# ---------- retry-after-reset settings ----------

cmd_retry() {
  load_config
  case "${1:-status}" in
    on)
      RETRY_AFTER_ACTIVE_WINDOW=1
      save_config
      echo "Retry after an active old window: ON"
      echo "If a ping lands while the old window is still active and about to reset,"
      echo "the tool waits until ${RETRY_AFTER_RESET_SEC}s past the reset, then pings once more."
      ;;
    off)
      RETRY_AFTER_ACTIVE_WINDOW=0
      save_config
      echo "Retry after an active old window: OFF"
      echo "Pings still report FRESH/OLD/USED honestly, but won't auto-retry."
      ;;
    grace)
      local n="${2:-}"
      if ! validate_int "$n" 1 60; then
        echo "Invalid grace. Use a whole number of minutes, 1-60." >&2
        echo "Example: ${CMD_NAME} retry grace 20" >&2
        exit 1
      fi
      RETRY_GRACE_MIN="$n"
      save_config
      echo "Retry grace set to ${RETRY_GRACE_MIN} min (reset within this => OLD window => retry)."
      ;;
    after-reset)
      local n="${2:-}"
      if ! validate_int "$n" 0 600; then
        echo "Invalid after-reset. Use a whole number of seconds, 0-600." >&2
        echo "Example: ${CMD_NAME} retry after-reset 60" >&2
        exit 1
      fi
      RETRY_AFTER_RESET_SEC="$n"
      save_config
      echo "Retry after-reset set to ${RETRY_AFTER_RESET_SEC}s (wait past the reset before re-pinging)."
      ;;
    status|*)
      local on_off="OFF"
      [ "$RETRY_AFTER_ACTIVE_WINDOW" = "1" ] && on_off="ON"
      printf '%-22s %s\n' "Retry after old window:" "$on_off"
      printf '%-22s %s\n' "Grace (OLD window):" "${RETRY_GRACE_MIN} minutes"
      printf '%-22s %s\n' "Wait after reset:" "${RETRY_AFTER_RESET_SEC} seconds"
      echo
      echo "A ping is FRESH only when /usage shows the window resetting ~5h out."
      echo "If it resets within the grace window, that's an OLD window still active;"
      echo "with retry ON the tool waits past the reset and pings once more."
      ;;
  esac
}

# ---------- shared display helpers ----------

# Find the claude binary the same way ping.sh does (PATH may be minimal).
find_claude_path() {
  if command -v claude >/dev/null 2>&1; then command -v claude; return 0; fi
  local c
  for c in "/opt/homebrew/bin/claude" "/usr/local/bin/claude" \
           "${HOME}/.local/bin/claude" "${HOME}/.claude/local/claude"; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

# True if the Mac is on AC power.
on_ac_power() {
  pmset -g batt 2>/dev/null | grep -q "AC Power"
}

wake_installed() { [ -f "$WAKE_PLIST_FILE" ]; }

# Turn an epoch into "today at HH:MM" / "tomorrow at HH:MM" / "Mon Jun 19 at HH:MM".
human_when() {
  local ep="$1" hm that today tom
  hm=$(date -r "$ep" +%H:%M 2>/dev/null) || return 1
  that=$(date -r "$ep" +%Y%m%d)
  today=$(date +%Y%m%d)
  tom=$(date -v+1d +%Y%m%d)
  if [ "$that" = "$today" ]; then echo "today at $hm"
  elif [ "$that" = "$tom" ]; then echo "tomorrow at $hm"
  else echo "$(date -r "$ep" '+%a %b %-d') at $hm"; fi
}

# Epoch of the next configured window start (respects weekdays-only).
next_window_epoch() {
  local off d_wd d_date cand best="" now
  now=$(date +%s)
  for off in 0 1 2 3 4 5 6 7; do
    d_wd=$(date -v+"${off}"d +%u)
    if [ "$DAYS" = "1-5" ] && { [ "$d_wd" -eq 6 ] || [ "$d_wd" -eq 7 ]; }; then continue; fi
    d_date=$(date -v+"${off}"d +%m/%d/%Y)
    for t in $TIMES; do
      cand=$(date -j -f "%m/%d/%Y %H:%M" "$d_date $t" +%s 2>/dev/null) || continue
      [ -z "$cand" ] && continue
      if [ "$cand" -gt "$now" ]; then
        if [ -z "$best" ] || [ "$cand" -lt "$best" ]; then best="$cand"; fi
      fi
    done
    [ -n "$best" ] && break
  done
  [ -n "$best" ] && echo "$best"
}

# Sorted, de-duplicated epochs of the wakes WE scheduled (owner 'pmset').
upcoming_wake_epochs() {
  pmset -g sched 2>/dev/null | grep -i 'wakeorpoweron' | while read -r line; do
    local dt ep
    dt=$(printf '%s' "$line" | grep -oE '[0-9]{2}/[0-9]{2}/[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}')
    [ -z "$dt" ] && continue
    ep=$(date -j -f "%m/%d/%Y %H:%M:%S" "$dt" +%s 2>/dev/null)
    [ -n "$ep" ] && echo "$ep"
  done | sort -n | uniq
}

# Most recent meaningful result line from a log, summarized. Recognizes the ping
# outcome vocabulary (FRESH/OLD/USED/UNCONFIRMED) as well as the SUCCESS/FAILURE
# words still used by the wake log (so "Last refresh:" keeps working).
last_log_summary() {
  local file="$1"
  [ -f "$file" ] || return 1
  local line
  line=$(grep -iE 'FRESH WINDOW STARTED|OLD WINDOW ACTIVE|USED EXISTING WINDOW|UNCONFIRMED|SUCCESS|FAILURE' "$file" 2>/dev/null | tail -n 1)
  [ -z "$line" ] && line=$(tail -n 1 "$file" 2>/dev/null)
  [ -z "$line" ] && return 1
  # "2026-06-17 10:00:01 -0300  FRESH WINDOW STARTED: ..." -> "FRESH  2026-06-17 10:00"
  local stamp word
  stamp=$(printf '%s' "$line" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}')
  if   printf '%s' "$line" | grep -qi 'FRESH WINDOW STARTED'; then word="FRESH"
  elif printf '%s' "$line" | grep -qi 'OLD WINDOW ACTIVE';    then word="OLD-WINDOW"
  elif printf '%s' "$line" | grep -qi 'USED EXISTING WINDOW'; then word="USED-EXISTING"
  elif printf '%s' "$line" | grep -qi 'UNCONFIRMED';          then word="UNCONFIRMED"
  elif printf '%s' "$line" | grep -qi 'SUCCESS';              then word="SUCCESS"
  elif printf '%s' "$line" | grep -qi 'FAILURE';              then word="FAILURE"
  else word=""; fi
  printf '%s%s%s' "$word" "${word:+ }" "$stamp"
}

# ---------- subcommands ----------

cmd_setup() {
  load_config
  echo "Session Aligner Setup"
  echo "---------------------"
  echo "This tool starts Claude's 5-hour window at times you choose, by sending a"
  echo "tiny interactive Claude Code ping. It does NOT increase your usage limit."
  echo
  echo "Recommended window start times:"
  echo "    05:00 10:00 15:00"
  echo
  echo "These are START times. A 05:00 ping starts a Claude window around 05:00."
  echo

  printf 'Use recommended schedule? [Y/n] '
  read -r rec
  case "$(printf '%s' "${rec:-y}" | tr '[:upper:]' '[:lower:]')" in
    n|no)
      while true; do
        echo "Claude window start times, 24h clock, space-separated:"
        printf 'Example: 08:00 13:00 18:00 : '
        read -r times_in
        times_in="${times_in:-$DEFAULT_TIMES}"
        if validate_times "$times_in"; then TIMES="$times_in"; break; fi
        echo "  Please use HH:MM times like: 05:00 10:00 15:00"
      done
      ;;
    *) TIMES="$DEFAULT_TIMES" ;;
  esac

  echo
  echo "Run on:"
  echo "    1) Every day"
  echo "    2) Weekdays only"
  printf 'Choose [1/2] (1): '
  read -r days_in
  case "${days_in:-1}" in
    2) DAYS="1-5" ;;
    *) DAYS="*" ;;
  esac

  save_config
  install_schedule
  echo
  echo "Scheduled: Claude windows start at [${TIMES}] $(human_days "$DAYS")."
  echo

  printf 'Enable auto-wake before each window start? [Y/n] '
  read -r wk
  case "$(printf '%s' "${wk:-y}" | tr '[:upper:]' '[:lower:]')" in
    n|no)
      echo
      echo "Skipped auto-wake. If your Mac may be asleep at a window start time,"
      echo "run later:  ${CMD_NAME} wake on"
      ;;
    *)
      echo
      cmd_wake on
      ;;
  esac

  echo
  echo "Setup complete."
  echo
  echo "Try:"
  echo "    ${CMD_NAME} status"
  echo "    ${CMD_NAME} test"
}

cmd_test() {
  echo "Sending one tiny ping now (this starts a fresh Claude window)..."
  "$PING_SCRIPT"
}

cmd_times() {
  local new_times="$1"
  if ! validate_times "$new_times"; then
    echo "Invalid times. Example: ${CMD_NAME} times \"05:00 10:00 15:00\"" >&2
    exit 1
  fi
  load_config
  TIMES="$new_times"
  save_config
  if is_installed; then
    install_schedule
    echo "Updated. Claude windows now start at [${TIMES}] $(human_days "$DAYS")."
    if wake_installed; then
      echo "Auto-wake will pick up the new times within an hour (or run"
      echo "'${CMD_NAME} wake on' to apply them right now)."
    fi
  else
    echo "Saved times [${TIMES}]. Schedule is currently OFF; run '${CMD_NAME} start' to enable."
  fi
}

cmd_on() {
  load_config
  install_schedule
  echo "Schedule ON: Claude windows start at [${TIMES}] $(human_days "$DAYS")."
}

cmd_off() {
  remove_schedule
  echo "Schedule OFF. Your saved times are remembered; run '${CMD_NAME} start' to resume."
  echo "(The auto-wake helper, if any, is separate: ${CMD_NAME} wake off)"
}

cmd_status() {
  local raw=0
  [ "${1:-}" = "--raw" ] && raw=1
  load_config

  local sched_on="OFF" wake_on="OFF"
  is_installed && sched_on="ON"
  wake_installed && wake_on="ON"

  # Comma-separated window starts for readability.
  local starts; starts="$(printf '%s' "$TIMES" | tr ' ' ',' | sed 's/,/, /g')"

  echo "Session Aligner Status"
  echo "----------------------"
  echo
  printf '%-15s %s\n' "Schedule:" "$sched_on"
  printf '%-15s %s\n' "Auto-wake:" "$wake_on"
  printf '%-15s %s\n' "Days:" "$(human_days "$DAYS")"
  printf '%-15s %s\n' "Window starts:" "$starts"
  printf '%-15s %s\n' "Ping times:" "$starts"
  printf '%-15s %s\n' "Wake lead:" "${WAKE_LEAD_MIN} minutes"
  printf '%-15s %s\n' "Keep-awake:" "${KEEP_AWAKE_MIN} minutes"
  printf '%-15s %s\n' "Wake times:" "$(preflight_times_csv)"

  local nw; nw="$(next_window_epoch)"
  if [ -n "$nw" ]; then printf '%-15s %s\n' "Next start:" "$(human_when "$nw")"; fi

  if [ "$wake_on" = "ON" ]; then
    local firstwake; firstwake="$(upcoming_wake_epochs | head -n 1)"
    if [ -n "$firstwake" ]; then printf '%-15s %s\n' "Next wake:" "$(human_when "$firstwake")"; fi
  fi

  local cpath; cpath="$(find_claude_path || true)"
  if [ -n "$cpath" ]; then printf '%-15s %s\n' "Claude Code:" "found at $cpath"
  else printf '%-15s %s\n' "Claude Code:" "NOT found (install it and run /login)"; fi

  if on_ac_power; then printf '%-15s %s\n' "Power:" "plugged in"
  else printf '%-15s %s\n' "Power:" "on battery"; fi

  local lp lr
  lp="$(last_log_summary "$LOG_FILE" || true)"
  [ -n "$lp" ] && printf '%-15s %s\n' "Last ping:" "$lp"
  lr="$(last_log_summary "$WAKE_LOG" || true)"
  [ -n "$lr" ] && printf '%-15s %s\n' "Last refresh:" "$lr"

  if [ "$wake_on" = "ON" ]; then
    echo
    echo "Upcoming wakes:"
    local any=0 ep
    while read -r ep; do
      [ -z "$ep" ] && continue
      any=1
      printf '    %s\n' "$(human_when "$ep")"
    done <<EOF
$(upcoming_wake_epochs)
EOF
    [ "$any" -eq 0 ] && echo "    (none found - the helper seeds them within the hour)"
  fi

  echo
  # Friendly closing line / hints.
  if [ "$sched_on" = "ON" ] && [ "$cpath" != "" ]; then
    if [ "$wake_on" = "OFF" ]; then
      echo "Auto-wake is OFF."
      echo "If your Mac may be asleep at a window start time, run:"
      echo "    ${CMD_NAME} wake on"
    elif ! on_ac_power; then
      echo "Note: scheduled wakes are less reliable when the lid is closed and the"
      echo "Mac is on battery. Keep it plugged in for the wakes to fire."
    else
      echo "Everything looks good."
    fi
  else
    echo "Run '${CMD_NAME} doctor' to diagnose."
  fi

  if [ "$raw" -eq 1 ]; then
    echo
    echo "--- raw: pmset -g sched ---"
    pmset -g sched 2>/dev/null
  fi
}

cmd_version() {
  echo "session-aligner ${VERSION}"
}

# Count recent ping outcomes from the ping log (last $1 matching lines, default
# 50). Echoes "<fresh> <old> <used> <unconfirmed> <failures>". Returns 1 when
# there are no outcome lines yet (so callers can warn about "no recent pings").
count_recent_pings() {
  local n="${1:-50}" lines
  [ -f "$LOG_FILE" ] || { echo "0 0 0 0 0"; return 1; }
  lines="$(grep -E 'FRESH WINDOW STARTED|OLD WINDOW ACTIVE|USED EXISTING WINDOW|PING SENT \(UNCONFIRMED\)|FAILURE' "$LOG_FILE" 2>/dev/null | tail -n "$n")"
  [ -z "$lines" ] && { echo "0 0 0 0 0"; return 1; }
  local f o u c x
  f=$(printf '%s\n' "$lines" | grep -c 'FRESH WINDOW STARTED')
  o=$(printf '%s\n' "$lines" | grep -c 'OLD WINDOW ACTIVE')
  u=$(printf '%s\n' "$lines" | grep -c 'USED EXISTING WINDOW')
  c=$(printf '%s\n' "$lines" | grep -c 'UNCONFIRMED')
  x=$(printf '%s\n' "$lines" | grep -c 'FAILURE')
  echo "$f $o $u $c $x"
}

# HH:MM wake times currently scheduled in pmset that are NOT in the expected set
# (each window start minus the current wake lead). These are usually leftovers
# from an earlier wake lead. Needs load_config first.
stale_wake_times() {
  local expected actual t
  expected="$(preflight_times | sort -u)"
  actual="$(upcoming_wake_epochs | while read -r ep; do date -r "$ep" +%H:%M; done | sort -u)"
  for t in $actual; do
    printf '%s\n' "$expected" | grep -qx "$t" || echo "$t"
  done
}

# A fuller health summary than `status`: quick to scan, with a warnings section.
# Always exits 0 (informational) - warnings do not make it fail.
cmd_report() {
  load_config

  local sched_on="OFF" wake_on="OFF" preflight_on="OFF" retry_on="OFF"
  is_installed && sched_on="ON"
  wake_installed && wake_on="ON"
  preflight_installed && preflight_on="ON"
  [ "$RETRY_AFTER_ACTIVE_WINDOW" = "1" ] && retry_on="ON"

  local starts; starts="$(printf '%s' "$TIMES" | tr ' ' ',' | sed 's/,/, /g')"
  local cpath; cpath="$(find_claude_path || true)"
  local on_ac=1; on_ac_power || on_ac=0

  echo "Session Aligner Report"
  echo
  printf '%-15s %s\n' "Version:" "$VERSION"
  printf '%-15s %s\n' "Schedule:" "$sched_on"
  printf '%-15s %s\n' "Auto-wake:" "$wake_on"
  printf '%-15s %s\n' "Preflight:" "$preflight_on"
  printf '%-15s %s\n' "Retry:" "$retry_on"
  printf '%-15s %s\n' "Days:" "$(human_days "$DAYS")"
  echo
  printf '%-15s %s\n' "Window starts:" "$starts"
  printf '%-15s %s\n' "Ping times:" "$starts"
  printf '%-15s %s\n' "Wake lead:" "${WAKE_LEAD_MIN} minutes"
  printf '%-15s %s\n' "Keep-awake:" "${KEEP_AWAKE_MIN} minutes"
  printf '%-15s %s\n' "Wake times:" "$(preflight_times_csv)"
  echo

  if [ -n "$cpath" ]; then printf '%-15s %s\n' "Claude Code:" "found at $cpath"
  else printf '%-15s %s\n' "Claude Code:" "NOT found (install it and run /login)"; fi
  if [ "$on_ac" -eq 1 ]; then printf '%-15s %s\n' "Power:" "plugged in"
  else printf '%-15s %s\n' "Power:" "on battery"; fi

  local nw; nw="$(next_window_epoch)"
  [ -n "$nw" ] && printf '%-15s %s\n' "Next start:" "$(human_when "$nw")"
  if [ "$wake_on" = "ON" ]; then
    local fw; fw="$(upcoming_wake_epochs | head -n 1)"
    [ -n "$fw" ] && printf '%-15s %s\n' "Next wake:" "$(human_when "$fw")"
  fi
  echo

  local lp lr; lp="$(last_log_summary "$LOG_FILE" || true)"; lr="$(last_log_summary "$WAKE_LOG" || true)"
  [ -n "$lp" ] && printf '%-15s %s\n' "Last ping:" "$lp"
  [ -n "$lr" ] && printf '%-15s %s\n' "Last refresh:" "$lr"

  local counts have_pings=1
  counts="$(count_recent_pings 50)" || have_pings=0
  set -- $counts
  if [ "$have_pings" -eq 1 ]; then
    printf '%-15s %s\n' "Recent pings:" "$1 fresh, $2 old-window, $3 used-existing, $4 unconfirmed, $5 failures"
  else
    printf '%-15s %s\n' "Recent pings:" "(none yet)"
  fi

  # ---- Warnings (informational only; never change the exit code) ----
  local warnings=() stale
  [ "$sched_on" = "OFF" ]    && warnings+=("Schedule is OFF; pings won't fire. Run '${CMD_NAME} start'.")
  [ "$wake_on" = "OFF" ]     && warnings+=("Auto-wake is OFF; the Mac won't wake for window starts. Run '${CMD_NAME} wake on'.")
  [ "$preflight_on" = "OFF" ] && warnings+=("Preflight keep-awake is OFF; a freshly-woken Mac may doze before the ping. Run '${CMD_NAME} wake on'.")
  [ -z "$cpath" ]            && warnings+=("Claude Code not found; install it and run 'claude' then '/login'.")
  [ "$on_ac" -eq 0 ]        && warnings+=("Mac is on battery; scheduled wakes are less reliable in clamshell mode.")
  [ "$have_pings" -eq 0 ]   && warnings+=("No recent ping outcomes in the log yet. Try '${CMD_NAME} test'.")

  case "${lp%% *}" in
    FAILURE)       warnings+=("Last ping FAILED. See '${CMD_NAME} logs ping'.") ;;
    UNCONFIRMED)   warnings+=("Last ping was UNCONFIRMED (couldn't read /usage). Check '/usage' in Claude Code.") ;;
    USED-EXISTING) warnings+=("Last ping only USED an existing window (no fresh window started).") ;;
    OLD-WINDOW)    warnings+=("Last ping hit an OLD window still active; a retry should have followed - check '${CMD_NAME} logs ping'.") ;;
  esac

  if [ "$wake_on" = "ON" ]; then
    stale="$(stale_wake_times | paste -sd, - | sed 's/,/, /g')"
    [ -n "$stale" ] && warnings+=("Stale wake entries detected: ${stale}. Run '${CMD_NAME} wake off && ${CMD_NAME} wake on'.")
  fi

  if [ "${#warnings[@]}" -gt 0 ]; then
    echo
    echo "Warnings:"
    local w
    for w in "${warnings[@]}"; do printf '  * %s\n' "$w"; done
  fi

  return 0
}

cmd_next() {
  load_config
  local nw; nw="$(next_window_epoch)"
  if [ -n "$nw" ]; then
    echo "Next Claude window start: $(human_when "$nw")"
  else
    echo "Next Claude window start: (none scheduled - run '${CMD_NAME} setup')"
  fi
  if wake_installed; then
    local fw; fw="$(upcoming_wake_epochs | head -n 1)"
    [ -n "$fw" ] && echo "Next scheduled wake:      $(human_when "$fw")"
    echo "Auto-wake:                ON"
  else
    echo "Auto-wake:                OFF"
    echo
    echo "If your Mac may be asleep then, run:"
    echo "    ${CMD_NAME} wake on"
  fi
}

cmd_logs() {
  local which="${1:-all}"
  _block() {
    local title="$1" file="$2" hint="$3"
    echo "${title}:"
    if [ -f "$file" ] && [ -s "$file" ]; then
      tail -n 8 "$file" | sed 's/^/  /'
    else
      echo "  $hint"
    fi
    echo
  }
  echo "Recent Session Aligner Activity"
  echo "-------------------------------"
  echo
  case "$which" in
    ping)      _block "Ping log"        "$LOG_FILE"        "No ping log yet. Run: ${CMD_NAME} test" ;;
    wake)      _block "Wake log"        "$WAKE_LOG"        "No wake log yet. Run: ${CMD_NAME} wake on" ;;
    daemon)    _block "Wake daemon log" "$WAKE_DAEMON_LOG" "No wake daemon log yet." ;;
    preflight) _block "Preflight log"   "$PREFLIGHT_LOG"   "No preflight log yet. Appears after a wake fires." ;;
    *)
      _block "Ping log"        "$LOG_FILE"        "No ping log yet. Run: ${CMD_NAME} test"
      _block "Wake log"        "$WAKE_LOG"        "No wake log yet. Run: ${CMD_NAME} wake on"
      _block "Wake daemon log" "$WAKE_DAEMON_LOG" "No wake daemon log yet."
      _block "Preflight log"   "$PREFLIGHT_LOG"   "No preflight log yet. Appears after a wake fires."
      ;;
  esac
}

cmd_doctor() {
  load_config
  local problems=()
  local C_OK="  \xE2\x9C\x93" C_BAD="  \xE2\x9C\x97" C_WARN="  \xE2\x9A\xA0"
  pass()  { printf "${C_OK} %s\n" "$1"; }
  cross() { printf "${C_BAD} %s\n" "$1"; problems+=("$2"); }
  warng() { printf "${C_WARN} %s\n" "$1"; problems+=("$2"); }

  echo "Session Aligner Doctor"
  echo "----------------------"
  echo
  echo "Checking setup..."

  if [ "$(uname -s)" = "Darwin" ]; then pass "macOS detected"
  else cross "not macOS" "This tool is macOS-only."; fi

  local cpath; cpath="$(find_claude_path || true)"
  if [ -n "$cpath" ]; then pass "Claude Code found: $cpath"
  else cross "Claude Code was not found" "Install Claude Code and run /login."; fi

  if command -v expect >/dev/null 2>&1; then pass "expect found: $(command -v expect)"
  else cross "expect not found" "Install Xcode Command Line Tools: xcode-select --install"; fi

  local f missing=""
  for f in aligner.sh ping.sh ping.exp schedule-wakes.sh preflight-awake.sh; do
    [ -f "${SCRIPT_DIR}/$f" ] || missing="$missing $f"
  done
  if [ -z "$missing" ]; then pass "all scripts present"
  else cross "missing scripts:$missing" "Re-download the project files."; fi

  if [ -x "${SCRIPT_DIR}/ping.sh" ] && [ -x "${SCRIPT_DIR}/schedule-wakes.sh" ] \
     && [ -x "${SCRIPT_DIR}/preflight-awake.sh" ]; then
    pass "scripts are executable"
  else
    cross "scripts are not executable" "Run: ${CMD_NAME} repair"
  fi

  if [ -f "$PLIST_FILE" ]; then pass "ping schedule installed"
  else warng "ping schedule not installed" "Run: ${CMD_NAME} setup"; fi
  if launchctl list 2>/dev/null | grep -q "$LABEL"; then pass "ping schedule is loaded"
  else warng "ping schedule is not loaded" "Run: ${CMD_NAME} start"; fi

  if wake_installed; then
    pass "auto-wake helper is installed"
    local fw; fw="$(upcoming_wake_epochs | head -n 1)"
    if [ -n "$fw" ]; then pass "upcoming wakes found"
    else warng "no upcoming wakes found" "Run: ${CMD_NAME} repair"; fi
  else
    warng "auto-wake is off" "Run: ${CMD_NAME} wake on"
  fi

  if on_ac_power; then pass "Mac is plugged into power"
  else warng "Mac is on battery" "Keep the Mac plugged in for reliable scheduled wakes."; fi

  if [ -f "$CONFIG_FILE" ]; then pass "config found (${TIMES}, $(human_days "$DAYS"))"
  else warng "no config yet - defaults will be used (${DEFAULT_TIMES})" "Run: ${CMD_NAME} setup"; fi

  echo
  if [ "${#problems[@]}" -eq 0 ]; then
    echo "No problems found."
  else
    echo "Suggested fixes:"
    local i=1 p
    for p in "${problems[@]}"; do
      printf '    %d. %s\n' "$i" "$p"
      i=$((i + 1))
    done
  fi
}

cmd_repair() {
  load_config
  echo "Repairing Session Aligner..."
  echo "Note: repair reloads and ENABLES the ping schedule (turns it ON if it was"
  echo "stopped). Run '${CMD_NAME} stop' afterwards if you wanted it off."
  echo
  chmod +x "${SCRIPT_DIR}/aligner.sh" "${SCRIPT_DIR}/ping.sh" "${SCRIPT_DIR}/ping.exp" \
           "${SCRIPT_DIR}/schedule-wakes.sh" "${SCRIPT_DIR}/preflight-awake.sh" 2>/dev/null || true
  echo "  Scripts made executable"

  if [ ! -f "$CONFIG_FILE" ]; then
    echo "  No config found - using defaults (${DEFAULT_TIMES}); run '${CMD_NAME} setup' to customize"
  fi
  install_schedule
  echo "  Ping schedule reloaded and enabled"

  if wake_installed; then
    echo
    echo "Reloading the auto-wake helper needs your Mac password (macOS requires"
    echo "admin access for pmset). Your password is not stored."
    cmd_wake on
    echo "  Auto-wake helper reloaded; upcoming wakes + preflight keep-awake refreshed"
  fi

  echo
  echo "Done. Run:"
  echo "    ${CMD_NAME} status"
}

cmd_uninstall() {
  load_config
  echo "Uninstall Session Aligner"
  echo "-------------------------"
  echo
  echo "This will:"
  echo "    - stop the ping schedule"
  echo "    - remove the auto-wake helper"
  echo "    - cancel scheduled wake events"
  echo "    - optionally remove the session-aligner command"
  echo
  printf 'Continue? [y/N] '
  read -r go
  case "$(printf '%s' "${go:-n}" | tr '[:upper:]' '[:lower:]')" in
    y|yes) ;;
    *) echo "Cancelled."; return 0 ;;
  esac

  remove_schedule
  echo "Ping schedule stopped."
  if wake_installed; then
    cmd_wake off    # also removes the preflight keep-awake agent
  else
    remove_preflight
  fi

  echo
  printf 'Remove logs and config too? [y/N] '
  read -r rl
  case "$(printf '%s' "${rl:-n}" | tr '[:upper:]' '[:lower:]')" in
    y|yes)
      rm -f "$CONFIG_FILE" "$LOG_FILE" "$LAUNCHD_LOG" "$WAKE_LOG" "$WAKE_DAEMON_LOG" "$PREFLIGHT_LOG"
      echo "Removed logs and config."
      ;;
    *) echo "Kept logs and config." ;;
  esac

  if [ -L "$SELF_LINK" ] || [ -e "$SELF_LINK" ]; then
    echo
    printf 'Remove the session-aligner command (%s)? [y/N] ' "$SELF_LINK"
    read -r rc
    case "$(printf '%s' "${rc:-n}" | tr '[:upper:]' '[:lower:]')" in
      y|yes)
        if rm -f "$SELF_LINK" 2>/dev/null; then
          echo "Removed ${SELF_LINK}."
        else
          echo "Removing ${SELF_LINK} needs admin rights (asks for your password)."
          if sudo rm -f "$SELF_LINK"; then echo "Removed ${SELF_LINK}."
          else echo "Could not remove ${SELF_LINK}."; fi
        fi
        ;;
      *) echo "Kept ${SELF_LINK}." ;;
    esac
  fi

  echo
  echo "Uninstall complete. The project files in ${SCRIPT_DIR} were left in place."
}

usage() {
  cat <<EOF
Session Aligner
---------------

Usage:
  ${CMD_NAME} setup
  ${CMD_NAME} status
  ${CMD_NAME} report                 (full health summary + warnings)
  ${CMD_NAME} version | --version | -v
  ${CMD_NAME} test
  ${CMD_NAME} times "05:00 10:00 15:00"
  ${CMD_NAME} start | stop
  ${CMD_NAME} wake on | off | status
  ${CMD_NAME} wake lead <min>        (how early to wake, 1-60; default 15)
  ${CMD_NAME} wake keep-awake <min>  (caffeinate duration, 5-90; default 20)
  ${CMD_NAME} retry status
  ${CMD_NAME} retry on | off              (recover when old window still active)
  ${CMD_NAME} retry grace <min>           (reset within this => OLD, 1-60; default 20)
  ${CMD_NAME} retry after-reset <sec>     (wait past reset before re-ping, 0-600; default 60)
  ${CMD_NAME} next
  ${CMD_NAME} doctor
  ${CMD_NAME} repair
  ${CMD_NAME} logs [ping|wake|daemon|preflight]
  ${CMD_NAME} uninstall

Default/recommended window start times:
  05:00 10:00 15:00

These are START times. For example, 05:00 starts a Claude window around 05:00.
This does NOT increase your usage - it only lines up the 5-hour window with your day.

If you did not run install.sh, use:
  ./aligner.sh status
EOF
}

# ---------- dispatch ----------

case "${1:-}" in
  setup)        cmd_setup ;;
  test)         cmd_test ;;
  times)        shift; cmd_times "${1:-}" ;;
  on|start)     cmd_on ;;
  off|stop)     cmd_off ;;
  status)       shift; cmd_status "${1:-}" ;;
  wake)         shift; cmd_wake "$@" ;;
  retry)        shift; cmd_retry "$@" ;;
  report)       cmd_report ;;
  version|--version|-v) cmd_version ;;
  next)         cmd_next ;;
  doctor|check) cmd_doctor ;;
  repair)       cmd_repair ;;
  logs)         shift; cmd_logs "${1:-all}" ;;
  uninstall)    cmd_uninstall ;;
  ""|-h|--help|help) usage ;;
  *) echo "Unknown command: $1" >&2; echo; usage; exit 1 ;;
esac
