#!/usr/bin/env bash
#
# ping.sh - Send one tiny message to Claude Code so a fresh 5-hour SUBSCRIPTION
# session window starts NOW.
#
# IMPORTANT (June 15, 2026 billing change): headless `claude -p` no longer counts
# toward the Pro/Max 5-hour subscription session window - it bills a separate
# metered pool. Only INTERACTIVE Claude Code starts that window. So this script
# drives the real interactive TUI through `expect` (a pseudo-terminal) and types
# one "hi" message. It uses your existing Claude Code login (no API key).
#
# It does NOT increase your quota; it only controls WHEN a 5-hour window begins.
#
# Run it directly to test:  ./ping.sh
# It is also what the launchd schedule runs (installed by ./aligner.sh setup).

set -u

# Resolve the folder this script lives in, so logs and ping.exp are found even
# when launchd/cron runs us from a different working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/aligner.log"
EXP_SCRIPT="${SCRIPT_DIR}/ping.exp"
CONFIG_FILE="${SCRIPT_DIR}/aligner.config"
# Last known-good auth marker (written on a successful ping, read by `report`/
# `auth status`). A successful ping proves Claude Code was authenticated.
STATE_FILE="${SCRIPT_DIR}/.session-aligner-state"

# Retry-after-reset behaviour (config-driven). After a ping, we read the /usage
# reset time to tell whether a FRESH 5-hour window actually started. If the OLD
# window is still active and about to reset, we wait until just after the reset
# and ping ONCE more so the fresh window opens. Configured ping times never move.
RETRY_AFTER_ACTIVE_WINDOW=1   # 1=do the one-time recovery retry; 0=just report
RETRY_GRACE_MIN=20            # reset within this many min => OLD window (retry)
RETRY_AFTER_RESET_SEC=60      # wait this long past the reset before re-pinging
FRESH_MIN_MIN=270             # internal: reset >= this many min away => FRESH (~4.5h)
# shellcheck disable=SC1090
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
# Clamp to sane ranges in case aligner.config was hand-edited (mirrors aligner.sh).
case "$RETRY_AFTER_ACTIVE_WINDOW" in 0|1) ;; *) RETRY_AFTER_ACTIVE_WINDOW=1 ;; esac
case "$RETRY_GRACE_MIN" in *[!0-9]*|'') RETRY_GRACE_MIN=20 ;; esac
[ "$RETRY_GRACE_MIN" -lt 1 ]  && RETRY_GRACE_MIN=1
[ "$RETRY_GRACE_MIN" -gt 60 ] && RETRY_GRACE_MIN=60
case "$RETRY_AFTER_RESET_SEC" in *[!0-9]*|'') RETRY_AFTER_RESET_SEC=60 ;; esac
[ "$RETRY_AFTER_RESET_SEC" -lt 0 ]   && RETRY_AFTER_RESET_SEC=0
[ "$RETRY_AFTER_RESET_SEC" -gt 600 ] && RETRY_AFTER_RESET_SEC=600

# launchd/cron run with a tiny PATH that usually does NOT include where
# npm/homebrew put the `claude` binary. Add the common locations.
export PATH="/opt/homebrew/bin:/usr/local/bin:${HOME}/.local/bin:${HOME}/.npm-global/bin:${HOME}/node_modules/.bin:${PATH}"

MODEL="haiku"

# Write a timestamped line to the log AND to the screen.
log() {
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$1" | tee -a "$LOG_FILE"
}

# Find the claude binary (absolute path), trying PATH first then common spots.
find_claude() {
  if command -v claude >/dev/null 2>&1; then
    command -v claude
    return 0
  fi
  for candidate in \
    "/opt/homebrew/bin/claude" \
    "/usr/local/bin/claude" \
    "${HOME}/.local/bin/claude" \
    "${HOME}/.claude/local/claude"; do
    if [ -x "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

CLAUDE_BIN="$(find_claude)" || {
  log "FAILURE: 'claude' command not found. Install Claude Code and run it once to log in."
  exit 1
}

if ! command -v expect >/dev/null 2>&1; then
  log "FAILURE: 'expect' not found (needed for the interactive ping). On macOS it lives at /usr/bin/expect."
  exit 1
fi

if [ ! -f "$EXP_SCRIPT" ]; then
  log "FAILURE: missing ${EXP_SCRIPT}. Reinstall the session-aligner files."
  exit 1
fi

# Outer timeout guard (the expect script also has its own internal timeout).
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout 180"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout 180"
fi

# Parse the /usage "Resets H[:MM]am/pm" clock time out of $1 into an epoch.
# Echoes an epoch on success, NOTHING on any failure (callers treat empty as
# "couldn't confirm"). Handles "Resets3:10pm", missing minutes, the trailing
# "(TZ)", am/pm casing, after-midnight reset (parsed time < now => +1 day), and
# rejects anything more than ~7h out as suspicious so we never wait for hours.
parse_reset_epoch() {
  local clean="$1" raw clock ampm hm epoch now
  raw="$(printf '%s' "$clean" | grep -ioE 'resets[[:space:]]*[0-9]{1,2}(:[0-9]{2})?[[:space:]]*[ap]m' | head -1)"
  [ -z "$raw" ] && return 0
  clock="$(printf '%s' "$raw" | sed -E 's/^[Rr]esets[[:space:]]*//; s/[[:space:]]//g')"
  ampm="$(printf '%s' "$clock" | grep -ioE '[ap]m' | tr '[:lower:]' '[:upper:]')"
  hm="$(printf '%s' "$clock" | sed -E 's/[aApPmM]+$//')"
  case "$hm" in *:*) : ;; *) hm="${hm}:00" ;; esac
  now="$(date +%s)"
  epoch="$(date -j -f "%Y-%m-%d %I:%M%p" "$(date '+%Y-%m-%d') ${hm}${ampm}" +%s 2>/dev/null)"
  [ -z "$epoch" ] && return 0
  [ "$epoch" -lt "$now" ] && epoch=$((epoch + 86400))
  [ "$epoch" -gt $((now + 7 * 3600)) ] && return 0
  printf '%s' "$epoch"
}

# Run ONE ping and classify it. Sets globals so it can be called twice (initial
# ping + at most one retry) without duplicating logic:
#   PING_OUTCOME  FRESH | OLD | USED | UNCONFIRMED | FAIL_TIMEOUT | FAIL_LOGIN
#                 | FAIL_NET | FAIL_START
#   EXIT_CODE     suggested process exit code for this attempt
#   RESET_EPOCH RESET_HHMM  (reset info when parsed)
#   MINS_LEFT_FROM_START  minutes from PING START to reset (classification basis)
#   MINS_LEFT             minutes from now/parse time to reset (display only)
#   PING_START_EPOCH PING_END_EPOCH PING_DURATION_SEC  (timing)
#   SESSION_LINE PCT SNIPPET TOKENS_LINE  (proof/details for logging)
# Classification uses PING START time, not completion/parse time: a slow ping (a
# busy Mac, a long Claude reply) can finish many minutes after it began, and a
# window that was fresh at start would otherwise be misread as "used existing".
# Honours test hooks: FAKE_CLEAN (skip the real spawn, use it as the output),
# FORCE_RESET_EPOCH (bypass the parser with a fixed epoch), and FORCE_START_EPOCH
# (pretend the ping started at this epoch, for late-parse / long-duration tests).
run_one_ping() {
  PING_OUTCOME=""; EXIT_CODE=0
  RESET_EPOCH=""; RESET_HHMM=""; MINS_LEFT=""; MINS_LEFT_FROM_START=""
  PING_START_EPOCH=""; PING_END_EPOCH=""; PING_DURATION_SEC=0
  SESSION_LINE=""; PCT=""; SNIPPET=""; TOKENS_LINE=""
  local OUTPUT CLEAN STATUS

  # Stamp the START time immediately before launching the ping (this attempt's
  # own start, so a retry classifies from when the retry began).
  PING_START_EPOCH="${FORCE_START_EPOCH:-$(date +%s)}"

  if [ -n "${FAKE_CLEAN:-}" ]; then
    CLEAN="$FAKE_CLEAN"; STATUS=0
  else
    # Drive the interactive TUI. Run inside the project folder so the per-folder
    # trust prompt (if any) is answered once and remembered for next time.
    OUTPUT="$(cd "$SCRIPT_DIR" && $TIMEOUT_BIN expect "$EXP_SCRIPT" "$CLAUDE_BIN" 2>&1)"
    STATUS=$?
    # Strip ANSI escape codes and control chars so the logged snippet is readable.
    # (perl handles \e/\a and hex classes consistently across macOS/Linux; BSD sed
    # does not.)
    if command -v perl >/dev/null 2>&1; then
      CLEAN="$(printf '%s' "$OUTPUT" | LC_ALL=C perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g; s/\e\][^\a]*\a//g; s/[\x00-\x08\x0b\x0c\x0e-\x1f]//g')"
    else
      CLEAN="$(printf '%s' "$OUTPUT" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')"
    fi
  fi
  # Stamp the END time once the Claude/expect interaction has finished.
  PING_END_EPOCH="$(date +%s)"
  PING_DURATION_SEC=$(( PING_END_EPOCH - PING_START_EPOCH ))
  [ "$PING_DURATION_SEC" -lt 0 ] && PING_DURATION_SEC=0
  SNIPPET="$(printf '%s' "$CLEAN" | tr '\n' ' ' | tr -s ' ' | cut -c1-160)"

  # --- Proof extraction (best-effort) -------------------------------------
  # Session/reset line from the captured /usage panel. The TUI strips spaces
  # when it renders, so match loosely on "Resets ..." and "NN% used".
  SESSION_LINE="$(printf '%s' "$CLEAN" | grep -ioE 'resets[^|]{0,40}' | head -1 | tr -s ' ')"
  PCT="$(printf '%s' "$CLEAN" | grep -ioE '[0-9]+% ?used' | head -1)"

  # Exact token usage from the transcript this ping just created. The numbers
  # are NOT in /usage; they live in the session JSONL as a `usage` field.
  local PROJ
  PROJ="${HOME}/.claude/projects/$(printf '%s' "$SCRIPT_DIR" | sed 's#/#-#g')"
  if [ -z "${FAKE_CLEAN:-}" ] && command -v python3 >/dev/null 2>&1; then
    TOKENS_LINE="$(python3 - "$PROJ" <<'PY' 2>/dev/null
import sys, os, glob, json
proj = sys.argv[1]
files = sorted(glob.glob(os.path.join(proj, '*.jsonl')), key=os.path.getmtime) if os.path.isdir(proj) else []
if not files:
    base = os.path.expanduser('~/.claude/projects')
    files = sorted(glob.glob(os.path.join(base, '*', '*.jsonl')), key=os.path.getmtime)
if not files:
    sys.exit(0)
usage = None
reply = ''
for line in open(files[-1]):
    try:
        o = json.loads(line)
    except Exception:
        continue
    if o.get('type') != 'assistant':
        continue
    msg = o.get('message', {}) if isinstance(o.get('message'), dict) else {}
    u = msg.get('usage')
    c = msg.get('content')
    txt = ''
    if isinstance(c, list):
        for b in c:
            if isinstance(b, dict) and b.get('type') == 'text':
                txt += b.get('text', '')
    if u:
        usage = u
    if txt.strip():
        reply = txt.strip()
if not usage:
    sys.exit(0)
def g(k):
    try:
        return int(usage.get(k, 0) or 0)
    except Exception:
        return 0
reply = reply.replace('\n', ' ')[:80]
print('input=%d output=%d cache_read=%d cache_write=%d | reply: "%s"' % (
    g('input_tokens'), g('output_tokens'),
    g('cache_read_input_tokens'), g('cache_creation_input_tokens'), reply))
PY
)"
  fi

  # --- Failure detection (unchanged rules) --------------------------------
  if [ "$STATUS" -eq 124 ]; then
    PING_OUTCOME="FAIL_TIMEOUT"; EXIT_CODE=124; return
  elif printf '%s' "$CLEAN" | grep -qiE 'sign ?in|please log ?in|/login|not authenticated|unauthor|authenticate your'; then
    PING_OUTCOME="FAIL_LOGIN"; EXIT_CODE=1; return
  elif printf '%s' "$CLEAN" | grep -qiE 'network error|offline|could not connect|getaddrinfo|enotfound|dns'; then
    PING_OUTCOME="FAIL_NET"; EXIT_CODE=1; return
  elif printf '%s' "$CLEAN" | grep -qiE 'claude exited before prompt|ERROR: missing path'; then
    PING_OUTCOME="FAIL_START"; EXIT_CODE=1; return
  fi

  # --- Claude replied: classify the window from the /usage reset time -----
  if [ -n "${FORCE_RESET_EPOCH:-}" ]; then
    local now2; now2="$(date +%s)"
    if [ "$FORCE_RESET_EPOCH" -gt $((now2 + 7 * 3600)) ]; then RESET_EPOCH=""
    else RESET_EPOCH="$FORCE_RESET_EPOCH"; fi
  else
    RESET_EPOCH="$(parse_reset_epoch "$CLEAN")"
  fi

  if [ -z "$RESET_EPOCH" ]; then
    PING_OUTCOME="UNCONFIRMED"; EXIT_CODE=0; return
  fi

  local now; now="$(date +%s)"
  RESET_HHMM="$(date -j -f %s "$RESET_EPOCH" '+%-I:%M%p' 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  # Minutes from now/parse time to reset - kept for reference/display only.
  MINS_LEFT=$(( (RESET_EPOCH - now + 59) / 60 ))
  [ "$MINS_LEFT" -lt 0 ] && MINS_LEFT=0
  # Minutes from PING START to reset - the basis for classification (round up).
  MINS_LEFT_FROM_START=$(( (RESET_EPOCH - PING_START_EPOCH + 59) / 60 ))
  [ "$MINS_LEFT_FROM_START" -lt 0 ] && MINS_LEFT_FROM_START=0

  if   [ "$MINS_LEFT_FROM_START" -le "$RETRY_GRACE_MIN" ]; then PING_OUTCOME="OLD"
  elif [ "$MINS_LEFT_FROM_START" -ge "$FRESH_MIN_MIN" ];   then PING_OUTCOME="FRESH"
  else PING_OUTCOME="USED"; fi
  EXIT_CODE=0
}

# Record last known-good auth. A FRESH/OLD/USED outcome means Claude replied and
# we read /usage, so authentication definitely worked just now. Written as a
# shell-safe key=value file (read with grep, never sourced).
record_auth_ok() {
  {
    echo "LAST_AUTH_OK_EPOCH=\"$(date +%s)\""
    echo "LAST_AUTH_OK_TEXT=\"${PING_OUTCOME} (resets at ${RESET_HHMM:-unknown})\""
  } > "$STATE_FILE" 2>/dev/null || true
}

# Human-readable duration: 45s, 4m12s, 34m.
fmt_duration() {
  local s="$1" m
  if [ "$s" -ge 60 ]; then
    m=$(( s / 60 )); s=$(( s % 60 ))
    if [ "$s" -eq 0 ]; then echo "${m}m"; else echo "${m}m${s}s"; fi
  else
    echo "${s}s"
  fi
}

# Log the result of the most recent run_one_ping. $1 (optional) is a prefix tag,
# e.g. "RETRY ", used to label the second attempt's lines.
log_outcome() {
  local tag="${1:-}"
  [ -n "$SESSION_LINE" ] && log "SESSION: ${SESSION_LINE}${PCT:+ | ${PCT}}"
  # A slow ping finishes long after it began; classification uses the START time,
  # so flag it when the gap is large enough to matter (and could mislead a reader
  # comparing the log timestamp to the reset time).
  if [ "${PING_DURATION_SEC:-0}" -gt 180 ]; then
    log "${tag}WARNING: ping took $(fmt_duration "$PING_DURATION_SEC") to complete; classification based on ping start time"
  fi
  # Any successful classification proves auth worked - stamp the known-good marker.
  case "$PING_OUTCOME" in FRESH|OLD|USED) record_auth_ok ;; esac
  local detail=""
  [ -n "$TOKENS_LINE" ] && detail=" TOKENS: ${TOKENS_LINE}"
  case "$PING_OUTCOME" in
    FRESH)
      log "${tag}FRESH WINDOW STARTED: resets at ${RESET_HHMM} (in ${MINS_LEFT_FROM_START}m from ping start).${detail}" ;;
    OLD)
      if [ "$RETRY_AFTER_ACTIVE_WINDOW" = "1" ]; then
        local retry_hhmm
        retry_hhmm="$(date -j -f %s $((RESET_EPOCH + RETRY_AFTER_RESET_SEC)) '+%-I:%M%p' 2>/dev/null | tr '[:upper:]' '[:lower:]')"
        log "${tag}OLD WINDOW ACTIVE: current window resets at ${RESET_HHMM} (in ${MINS_LEFT_FROM_START}m from ping start); scheduling retry for ${retry_hhmm}"
      else
        log "${tag}OLD WINDOW ACTIVE: current window resets at ${RESET_HHMM} (in ${MINS_LEFT_FROM_START}m from ping start); retry disabled (RETRY_AFTER_ACTIVE_WINDOW=0)"
      fi ;;
    USED)
      log "${tag}USED EXISTING WINDOW: current window resets at ${RESET_HHMM} (in ${MINS_LEFT_FROM_START}m from ping start); no retry (mid-window)" ;;
    UNCONFIRMED)
      log "${tag}PING SENT (UNCONFIRMED): Claude replied but could not read /usage reset time. Verify with /usage. Snippet: ${SNIPPET:-(none)}" ;;
    FAIL_TIMEOUT)
      log "${tag}FAILURE: timed out (network problem, or the TUI did not respond). Output: ${SNIPPET}" ;;
    FAIL_LOGIN)
      log "${tag}FAILURE: not logged in. Open a terminal, run 'claude', then '/login'. Output: ${SNIPPET}" ;;
    FAIL_NET)
      log "${tag}FAILURE: network error. Check your internet connection. Output: ${SNIPPET}" ;;
    FAIL_START)
      log "${tag}FAILURE: could not start the interactive session. Output: ${SNIPPET}" ;;
  esac
}

log "INFO: sending interactive ping via ${CLAUDE_BIN} (model: ${MODEL})"

run_one_ping
log_outcome

# One-time recovery retry: only when the OLD window is still active and about to
# reset, and only if enabled. Straight-line - never loops, never re-schedules.
if [ "$PING_OUTCOME" = "OLD" ] && [ "$RETRY_AFTER_ACTIVE_WINDOW" = "1" ]; then
  target=$(( RESET_EPOCH + RETRY_AFTER_RESET_SEC ))
  now="$(date +%s)"
  wait_secs=$(( target - now ))
  [ "$wait_secs" -lt 0 ] && wait_secs=0
  # Bound the wait so a bad parse can never sleep for hours.
  cap=$(( RETRY_GRACE_MIN * 60 + RETRY_AFTER_RESET_SEC + 120 ))
  [ "$wait_secs" -gt "$cap" ] && wait_secs="$cap"

  log "RETRYING AFTER RESET: holding awake ${wait_secs}s, then re-pinging (window should reset at ${RESET_HHMM})"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "DRY: caffeinate -dimsu -t ${wait_secs}; then one re-ping"
  else
    # Keep the Mac fully awake through the wait (mirrors preflight-awake.sh).
    caffeinate -dimsu -t "$wait_secs" 2>/dev/null || sleep "$wait_secs"
    run_one_ping            # the SINGLE retry; its result is logged honestly
    log_outcome "RETRY: "   # and we stop, even if it is still not FRESH
  fi
fi

exit "${EXIT_CODE:-0}"
